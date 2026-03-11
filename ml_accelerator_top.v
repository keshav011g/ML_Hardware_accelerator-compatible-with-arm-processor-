`timescale 1ns / 1ps

/*
 * Module: ml_accelerator_top
 * Description:
 * - Top Level IP Core for ML Accelerator.
 * - Integrates AXI-Lite (CPU Control) and AXI-Master (DMA).
 * - FSM supports Weight-Stationary Dataflow and Batch Processing.
 */

module ml_accelerator_top #
(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 6,
    parameter integer C_M_AXI_ADDR_WIDTH = 32,
    parameter integer C_M_AXI_DATA_WIDTH = 32
)
(
    // --- Global Signals ---
    input wire  clk,
    input wire  rst_n,

    // --- AXI4-Lite Slave (CPU Interface) ---
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] s_axi_awaddr,
    input wire  s_axi_awvalid,
    output wire s_axi_awready,
    input wire [C_S_AXI_DATA_WIDTH-1 : 0] s_axi_wdata,
    input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] s_axi_wstrb,
    input wire  s_axi_wvalid,
    output wire s_axi_wready,
    output wire [1 : 0] s_axi_bresp,
    output wire s_axi_bvalid,
    input wire  s_axi_bready,
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] s_axi_araddr,
    input wire  s_axi_arvalid,
    output wire s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1 : 0] s_axi_rdata,
    output wire [1 : 0] s_axi_rresp,
    output wire s_axi_rvalid,
    input wire  s_axi_rready,

    // --- AXI4-Master (DMA Interface) ---
    output wire [C_M_AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,
    input  wire m_axi_arready,
    input  wire [C_M_AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire m_axi_rlast,
    input  wire m_axi_rvalid,
    output wire m_axi_rready,

    // --- Interrupt ---
    output reg  irq_done
);

    // =========================================================================
    // 1. INTERCONNECT WIRES
    // =========================================================================
    
    // Config Registers (Driven by AXI Lite Interface)
    wire [31:0] reg_ctrl;
    wire [31:0] reg_m_size;
    wire [31:0] reg_k_size;
    wire [31:0] reg_n_size;
    wire [31:0] reg_wgt_base;
    wire [31:0] reg_inp_base;
    
    // Status Register (Driven by Logic, Read by AXI Lite)
    reg  [31:0] reg_status;

    // DMA Signals
    reg         dma_start;
    reg  [31:0] dma_addr;
    reg  [31:0] dma_len;
    wire        dma_done;
    wire [31:0] dma_stream_data;
    wire        dma_stream_valid;

    // Core Control Signals
    wire sys_start     = reg_ctrl[0];
    wire reuse_weights = reg_ctrl[1]; // Bit 1 for batch processing
    reg  sys_busy;
    reg  sys_done;

    // =========================================================================
    // 2. INSTANTIATE SUB-MODULES
    // =========================================================================

    // --- CPU Interface ---
    axi_lite_interface #(
        .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
    ) u_cpu_if (
        .clk(clk),
        .rst_n(rst_n),
        .awaddr(s_axi_awaddr), .awvalid(s_axi_awvalid), .awready(s_axi_awready),
        .wdata(s_axi_wdata),   .wvalid(s_axi_wvalid),   .wready(s_axi_wready),
        .bresp(s_axi_bresp),   .bvalid(s_axi_bvalid),   .bready(s_axi_bready),
        .araddr(s_axi_araddr), .arvalid(s_axi_arvalid), .arready(s_axi_arready),
        .rdata(s_axi_rdata),   .rresp(s_axi_rresp),     .rvalid(s_axi_rvalid), .rready(s_axi_rready),
        .reg_ctrl(reg_ctrl),
        .reg_m_size(reg_m_size),
        .reg_k_size(reg_k_size),
        .reg_n_size(reg_n_size),
        .reg_wgt_base(reg_wgt_base),
        .reg_inp_base(reg_inp_base),
        .reg_status(reg_status)
    );

    // --- DMA Controller ---
    dma_controller #(
        .C_M_AXI_ADDR_WIDTH(C_M_AXI_ADDR_WIDTH),
        .C_M_AXI_DATA_WIDTH(C_M_AXI_DATA_WIDTH)
    ) u_dma (
        .clk(clk),
        .rst_n(rst_n),
        .start(dma_start),
        .base_addr(dma_addr),
        .transfer_length(dma_len),
        .done(dma_done),
        .stream_data(dma_stream_data),
        .stream_valid(dma_stream_valid),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    // =========================================================================
    // 3. ON-CHIP SRAM BUFFERS
    // =========================================================================
    
    reg [7:0] weight_buffer [0:255]; 
    reg [7:0] input_buffer  [0:511]; // Expanded for multiple batches
    reg [8:0] wgt_idx; 
    reg [8:0] inp_idx;

    always @(posedge clk) begin
        if (dma_stream_valid) begin
            if (state == S_FETCH_WEIGHTS) 
                weight_buffer[wgt_idx] <= dma_stream_data[7:0]; 
            else if (state == S_FETCH_INPUTS)
                input_buffer[inp_idx] <= dma_stream_data[7:0];
        end
    end

    // =========================================================================
    // 4. MAIN CONTROL FSM
    // =========================================================================
    
    localparam S_IDLE          = 3'd0;
    localparam S_FETCH_WEIGHTS = 3'd1;
    localparam S_LOAD_WEIGHTS  = 3'd2;
    localparam S_FETCH_INPUTS  = 3'd3;
    localparam S_COMPUTE       = 3'd4;
    localparam S_WRITE_BACK    = 3'd5;
    localparam S_DONE          = 3'd6;

    reg [2:0] state;
    reg array_load_weight;
    reg array_en;
    reg [4:0] load_counter;
    reg [5:0] compute_counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            sys_busy <= 0; sys_done <= 0; irq_done <= 0;
            dma_start <= 0; array_load_weight <= 0; array_en <= 0;
            wgt_idx <= 0; inp_idx <= 0;
            load_counter <= 0; compute_counter <= 0;
        end else begin
            reg_status <= {30'd0, sys_done, sys_busy};

            case (state)
                S_IDLE: begin
                    sys_done <= 0; irq_done <= 0;
                    if (sys_start) begin
                        sys_busy <= 1;
                        
                        if (reuse_weights) begin
                            // BATCH PROCESSING: Skip weight loading, jump to inputs
                            state <= S_FETCH_INPUTS;
                            dma_addr <= reg_inp_base;
                            dma_len <= 256;
                            dma_start <= 1;
                            inp_idx <= 0;
                        end else begin
                            // STANDARD RUN: Fetch weights first
                            state <= S_FETCH_WEIGHTS; 
                            dma_addr <= reg_wgt_base;
                            dma_len <= 256; 
                            dma_start <= 1;
                            wgt_idx <= 0;
                        end
                    end
                end

                S_FETCH_WEIGHTS: begin
                    dma_start <= 0;
                    if (dma_stream_valid) wgt_idx <= wgt_idx + 1;
                    if (dma_done) begin
                        state <= S_LOAD_WEIGHTS;
                        load_counter <= 0;
                    end
                end

                S_LOAD_WEIGHTS: begin
                    array_load_weight <= 1;
                    array_en <= 1;
                    if (load_counter == 15) begin
                        state <= S_FETCH_INPUTS;
                        array_en <= 0;
                        array_load_weight <= 0;
                        dma_addr <= reg_inp_base;
                        dma_len <= 256;
                        dma_start <= 1;
                        inp_idx <= 0;
                    end else begin
                        load_counter <= load_counter + 1;
                    end
                end

                S_FETCH_INPUTS: begin
                    dma_start <= 0;
                    if (dma_stream_valid) inp_idx <= inp_idx + 1;
                    if (dma_done) begin
                        state <= S_COMPUTE;
                        compute_counter <= 0;
                    end
                end

                S_COMPUTE: begin
                    array_load_weight <= 0;
                    array_en <= 1;
                    // Run compute cycles (16 to fill array + 16 to flush partial sums out)
                    if (compute_counter == 31) begin 
                        state <= S_WRITE_BACK;
                        array_en <= 0;
                    end else begin
                        compute_counter <= compute_counter + 1;
                    end
                end

                S_WRITE_BACK: begin
                    // Placeholder for Master Write logic back to RAM
                    state <= S_DONE;
                end

                S_DONE: begin
                    sys_busy <= 0;
                    sys_done <= 1;
                    irq_done <= 1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // 5. CORE INSTANTIATION & DATA PACKING
    // =========================================================================
    
    wire [127:0] flat_ifmap;
    wire [127:0] flat_weight;

    // Pack 16 bytes of input data into the 128-bit flat_ifmap bus
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_ifmap_pack
            assign flat_ifmap[(i*8)+7 : i*8] = input_buffer[compute_counter*16 + i];
        end
    endgenerate

    // Pack 16 bytes of weight data into the 128-bit flat_weight bus
    genvar w;
    generate
        for (w = 0; w < 16; w = w + 1) begin : gen_weight_pack
            assign flat_weight[(w*8)+7 : w*8] = weight_buffer[load_counter*16 + w];
        end
    endgenerate

    // Instantiate the Systolic Array Core (Must match module name in systolic_array_core16x16.v)
    systolic_array_16x16 u_core (
        .clk(clk),
        .rst_n(rst_n), 
        .en(array_en),
        .load_weight(array_load_weight),
        .flat_ifmap_in(flat_ifmap), 
        .flat_weight_in(flat_weight),
        .flat_psum_in({384{1'b0}}), // Initial partial sums are zero
        .flat_psum_out() // Routed to AXI write-back logic in a full system
    );

endmodule
