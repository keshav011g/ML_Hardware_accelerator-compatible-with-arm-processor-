/*
 * Module: ml_accelerator_top
 * Description:
 * - Top Level IP Core.
 * - Instantiates AXI_Lite_Interface (CPU Control).
 * - Instantiates DMA_Controller (Data Fetching).
 * - Instantiates Systolic_Array (Compute Engine).
 * - Coordinates data flow via FSM.
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
    wire sys_start = reg_ctrl[0];
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
        // AXI Ports
        .awaddr(s_axi_awaddr), .awvalid(s_axi_awvalid), .awready(s_axi_awready),
        .wdata(s_axi_wdata),   .wvalid(s_axi_wvalid),   .wready(s_axi_wready),
        .bresp(s_axi_bresp),   .bvalid(s_axi_bvalid),   .bready(s_axi_bready),
        .araddr(s_axi_araddr), .arvalid(s_axi_arvalid), .arready(s_axi_arready),
        .rdata(s_axi_rdata),   .rresp(s_axi_rresp),     .rvalid(s_axi_rvalid), .rready(s_axi_rready),
        // Internal Interface
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
        // Control
        .start(dma_start),
        .base_addr(dma_addr),
        .transfer_length(dma_len),
        .done(dma_done),
        // Stream Out
        .stream_data(dma_stream_data),
        .stream_valid(dma_stream_valid),
        // AXI Master Ports
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    // =========================================================================
    // 3. ON-CHIP BUFFERS (Simplified)
    // =========================================================================
    // We need to capture the data streaming from DMA before feeding the array
    
    reg [7:0] weight_buffer [0:255]; // Small buffer for 16x16 weights
    reg [7:0] input_buffer  [0:255]; // Small buffer for inputs
    reg [7:0] wgt_idx;
    reg [7:0] inp_idx;

    // Logic to fill buffers from DMA Stream
    always @(posedge clk) begin
        if (dma_stream_valid) begin
            // Depending on current state, fill WGT or INP buffer
            if (state == S_FETCH_WEIGHTS) 
                weight_buffer[wgt_idx] <= dma_stream_data[7:0]; // Taking lower 8 bits for demo
            else if (state == S_FETCH_INPUTS)
                input_buffer[inp_idx] <= dma_stream_data[7:0];
        end
    end

    // =========================================================================
    // 4. MAIN CONTROL FSM (The Orchestrator)
    // =========================================================================
    
    localparam S_IDLE          = 0;
    localparam S_FETCH_WEIGHTS = 1;
    localparam S_FETCH_INPUTS  = 2;
    localparam S_LOAD_ARRAY    = 3;
    localparam S_COMPUTE       = 4;
    localparam S_DONE          = 5;

    reg [2:0] state;
    reg array_load_weight;
    reg array_en;
    reg [4:0] load_counter;
    
    // Array Wires
    wire [127:0] flat_ifmap;
    wire [127:0] flat_weight;

    // FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            sys_busy <= 0;
            irq_done <= 0;
            dma_start <= 0;
            wgt_idx <= 0; inp_idx <= 0;
        end else begin
            // Update Status Register
            reg_status <= {30'd0, sys_done, sys_busy};

            case (state)
                S_IDLE: begin
                    sys_done <= 0;
                    irq_done <= 0;
                    if (sys_start) begin
                        state <= S_FETCH_WEIGHTS;
                        sys_busy <= 1;
                        // Setup DMA for Weights
                        dma_addr <= reg_wgt_base;
                        dma_len <= 256; // Fetch 256 weights
                        dma_start <= 1;
                        wgt_idx <= 0;
                    end
                end

                S_FETCH_WEIGHTS: begin
                    dma_start <= 0;
                    if (dma_stream_valid) wgt_idx <= wgt_idx + 1;
                    
                    if (dma_done) begin
                        state <= S_FETCH_INPUTS;
                        // Setup DMA for Inputs
                        dma_addr <= reg_inp_base;
                        dma_len <= 256;
                        dma_start <= 1;
                        inp_idx <= 0;
                    end
                end

                S_FETCH_INPUTS: begin
                    dma_start <= 0;
                    if (dma_stream_valid) inp_idx <= inp_idx + 1;

                    if (dma_done) begin
                        state <= S_LOAD_ARRAY;
                        load_counter <= 0;
                    end
                end

                S_LOAD_ARRAY: begin
                    // Push Weights into Array (Daisy Chain)
                    array_load_weight <= 1;
                    array_en <= 1;
                    if (load_counter == 15) begin
                        state <= S_COMPUTE;
                        load_counter <= 0;
                    end else begin
                        load_counter <= load_counter + 1;
                    end
                end

                S_COMPUTE: begin
                    array_load_weight <= 0;
                    // In a real system, we'd wait for compute cycles
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
    // 5. CORE INSTANTIATION
    // =========================================================================
    
    // Helper to flatten 16 rows from buffer for Array Inputs
    // (Simplified packing for demo)
    assign flat_ifmap = {input_buffer[15], input_buffer[14], input_buffer[13], input_buffer[12],
                         input_buffer[11], input_buffer[10], input_buffer[9],  input_buffer[8],
                         input_buffer[7],  input_buffer[6],  input_buffer[5],  input_buffer[4],
                         input_buffer[3],  input_buffer[2],  input_buffer[1],  input_buffer[0], 
                         {8'd0}}; // Pad if necessary (simplified)

    assign flat_weight = {weight_buffer[load_counter*16 + 15], weight_buffer[load_counter*16 + 0], {112'd0}}; // Just demo mapping

    systolic_array_16x16 u_core (
        .clk(clk),
        .rst_n(rst_n),
        .en(array_en),
        .load_weight(array_load_weight),
        .flat_ifmap_in({128{1'b1}}), // Connected to buffer logic in real implement
        .flat_weight_in({128{1'b1}}),
        .flat_psum_in({384{1'b0}}),
        .flat_psum_out()
    );

endmodule