/*
 * Module: ml_accelerator_top
 * Description:
 * - Top Level IP Core wrapping the Systolic Array.
 * - Implements AXI4-Lite Slave Interface for ARM Compatibility.
 * - Maps ARM memory writes to internal configuration registers.
 */

module ml_accelerator_top 
(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 6 // 64 bytes address space
)
(
    // --- Global Signals ---
    input wire  s_axi_aclk,
    input wire  s_axi_aresetn, // Active Low Reset

    // --- AXI4-Lite Slave Interface (Connects to ARM Interconnect) ---
    
    // Write Address Channel
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] s_axi_awaddr,
    input wire  s_axi_awvalid,
    output wire s_axi_awready,

    // Write Data Channel
    input wire [C_S_AXI_DATA_WIDTH-1 : 0] s_axi_wdata,
    input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] s_axi_wstrb,
    input wire  s_axi_wvalid,
    output wire s_axi_wready,

    // Write Response Channel
    output wire [1 : 0] s_axi_bresp,
    output wire s_axi_bvalid,
    input wire  s_axi_bready,

    // Read Address Channel
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] s_axi_araddr,
    input wire  s_axi_arvalid,
    output wire s_axi_arready,

    // Read Data Channel
    output wire [C_S_AXI_DATA_WIDTH-1 : 0] s_axi_rdata,
    output wire [1 : 0] s_axi_rresp,
    output wire s_axi_rvalid,
    input wire  s_axi_rready,

    // --- Interrupt ---
    output reg  irq_done
);

    // --- Register Map Addresses (Byte Offsets) ---
    localparam ADDR_CTRL   = 6'h00; // Control (Bit 0 = Start)
    localparam ADDR_STATUS = 6'h04; // Status  (Bit 0 = Busy, Bit 1 = Done)
    localparam ADDR_M_SIZE = 6'h08; // Rows
    localparam ADDR_K_SIZE = 6'h0C; // Shared Dim
    localparam ADDR_N_SIZE = 6'h10; // Cols

    // --- Internal Registers ---
    reg [31:0] reg_ctrl;
    reg [31:0] reg_status; // Read-only from logic
    reg [31:0] reg_m_size;
    reg [31:0] reg_k_size;
    reg [31:0] reg_n_size;

    // --- AXI State Machine Signals ---
    reg axi_awready;
    reg axi_wready;
    reg [1:0] axi_bresp;
    reg axi_bvalid;
    reg axi_arready;
    reg [31:0] axi_rdata;
    reg [1:0] axi_rresp;
    reg axi_rvalid;

    // --- Core Logic Signals ---
    wire sys_start;
    reg  sys_busy;
    reg  sys_done;
    
    // Assign AXI Outputs
    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bresp   = axi_bresp;
    assign s_axi_bvalid  = axi_bvalid;
    assign s_axi_arready = axi_arready;
    assign s_axi_rdata   = axi_rdata;
    assign s_axi_rresp   = axi_rresp;
    assign s_axi_rvalid  = axi_rvalid;

    // AXI Write Logic
    always @(posedge s_axi_aclk) begin
        if (s_axi_aresetn == 1'b0) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b0;
            reg_ctrl    <= 32'd0;
            reg_m_size  <= 32'd16; // Default
            reg_k_size  <= 32'd16;
            reg_n_size  <= 32'd16;
        end else begin
            // Handshake for Write Address
            if (~axi_awready && s_axi_awvalid && s_axi_wvalid) begin
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
            end else begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
            end

            // Write Data to Registers
            if (axi_awready && s_axi_awvalid && axi_wready && s_axi_wvalid) begin
                case (s_axi_awaddr[5:2]) // Decode Address (Ignore lower 2 bits for 4-byte align)
                    4'h0: reg_ctrl   <= s_axi_wdata;
                    // 4'h1 is Status (Read Only)
                    4'h2: reg_m_size <= s_axi_wdata;
                    4'h3: reg_k_size <= s_axi_wdata;
                    4'h4: reg_n_size <= s_axi_wdata;
                    default: ; 
                endcase
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b0; // OKAY
            end else begin
                if (s_axi_bready && axi_bvalid) begin
                    axi_bvalid <= 1'b0;
                    // Self-clearing start bit
                    reg_ctrl[0] <= 1'b0; 
                end
            end
        end
    end

    // AXI Read Logic
    always @(posedge s_axi_aclk) begin
        if (s_axi_aresetn == 1'b0) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 2'b0;
            axi_rdata   <= 32'd0;
        end else begin
            if (~axi_arready && s_axi_arvalid) begin
                axi_arready <= 1'b1;
                axi_rvalid  <= 1'b1;
                
                // Read Mux
                case (s_axi_araddr[5:2])
                    4'h0: axi_rdata <= reg_ctrl;
                    4'h1: axi_rdata <= {30'd0, sys_done, sys_busy}; // Status Register
                    4'h2: axi_rdata <= reg_m_size;
                    4'h3: axi_rdata <= reg_k_size;
                    4'h4: axi_rdata <= reg_n_size;
                    default: axi_rdata <= 32'd0;
                endcase
            end else begin
                axi_arready <= 1'b0;
                if (axi_rvalid && s_axi_rready) begin
                    axi_rvalid <= 1'b0;
                end
            end
        end
    end

    // --- ACCELERATOR CORE LOGIC ---
    
    assign sys_start = reg_ctrl[0]; // Start signal triggers FSM

    // FSM State Definitions
    localparam S_IDLE        = 0;
    localparam S_LOAD_WEIGHT = 1;
    localparam S_COMPUTE     = 2;
    localparam S_DONE        = 3;
    
    reg [2:0] state;
    reg [4:0] load_counter;   
    reg [15:0] compute_counter;
    reg array_en;
    reg load_weight;
    
    // Tiling Logic Wires
    wire [127:0] flat_ifmap_in;
    reg  [7:0]   padded_rows [0:15];
    reg  [15:0]  tile_row;

    // Main Compute FSM
    always @(posedge s_axi_aclk) begin
        if (s_axi_aresetn == 1'b0) begin
            state <= S_IDLE;
            sys_busy <= 0;
            sys_done <= 0;
            irq_done <= 0;
            tile_row <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    irq_done <= 0;
                    sys_done <= 0;
                    if (sys_start) begin
                        state <= S_LOAD_WEIGHT;
                        sys_busy <= 1;
                        tile_row <= 0;
                        load_counter <= 0;
                    end
                end

                S_LOAD_WEIGHT: begin
                    load_weight <= 1;
                    array_en <= 1;
                    
                    if (load_counter == 15) begin
                        state <= S_COMPUTE;
                        load_counter <= 0;
                        compute_counter <= 0;
                    end else begin
                        load_counter <= load_counter + 1;
                    end
                end

                S_COMPUTE: begin
                    load_weight <= 0;
                    if (compute_counter == (reg_k_size-1)) begin
                        state <= S_DONE;
                    end else begin
                        compute_counter <= compute_counter + 1;
                    end
                end
                
                S_DONE: begin
                    sys_busy <= 0;
                    sys_done <= 1;
                    irq_done <= 1; // Pulse Interrupt
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // --- ZERO PADDING LOGIC ---
    genvar i;
    generate
        for (i=0; i<16; i=i+1) begin : PAD_LOGIC
            wire [31:0] global_row_idx = (tile_row * 16) + i;
            always @(*) begin
                if (global_row_idx >= reg_m_size) 
                    padded_rows[i] = 8'd0; 
                else 
                    padded_rows[i] = 8'd1; // Simplified data fetch
            end
            assign flat_ifmap_in[i*8 +: 8] = padded_rows[i];
        end
    endgenerate

    // --- CORE INSTANTIATION ---
    systolic_array_16x16 u_array (
        .clk(s_axi_aclk),
        .rst_n(s_axi_aresetn),
        .en(array_en),
        .load_weight(load_weight),
        .flat_ifmap_in(flat_ifmap_in),
        .flat_weight_in({16{8'd5}}), // Simulated weights
        .flat_psum_in({16{24'd0}}),
        .flat_psum_out()
    );

endmodule