// ml_accelerator_top.v
// Top-level module for a DMA-enabled ML Accelerator
// This connects to CPU via AXI-Lite and to RAM via AXI-Master.

module ml_accelerator_top #(
    // AXI-Lite (Control) Parameters
    parameter C_S_AXI_LITE_DATA_WIDTH = 32,
    parameter C_S_AXI_LITE_ADDR_WIDTH = 6, // Example: 64 bytes of register space

    // AXI-Master (DMA Data) Parameters
    parameter C_M_AXI_DATA_WIDTH = 128, // High-bandwidth data path
    parameter C_M_AXI_ADDR_WIDTH = 32   // 4GB address space
)(
    // Global Signals
    input  wire                                 clk,
    input  wire                                 rst_n,

    // --- AXI-Lite Slave Interface (for CPU Control) ---
    // (AW/W/B/AR/R channel signals, omitted for brevity but standard AXI-Lite)
    // ... all AXI-Lite signals here (refer to previous examples) ...
    input  wire [C_S_AXI_LITE_ADDR_WIDTH-1:0]    s_axi_lite_awaddr,
    input  wire                                 s_axi_lite_awvalid,
    output wire                                 s_axi_lite_awready,
    input  wire [C_S_AXI_LITE_DATA_WIDTH-1:0]    s_axi_lite_wdata,
    input  wire                                 s_axi_lite_wvalid,
    output wire                                 s_axi_lite_wready,
    output wire [1:0]                           s_axi_lite_bresp,
    output wire                                 s_axi_lite_bvalid,
    input  wire                                 s_axi_lite_bready,
    input  wire [C_S_AXI_LITE_ADDR_WIDTH-1:0]    s_axi_lite_araddr,
    input  wire                                 s_axi_lite_arvalid,
    output wire                                 s_axi_lite_arready,
    output wire [C_S_AXI_LITE_DATA_WIDTH-1:0]    s_axi_lite_rdata,
    output wire [1:0]                           s_axi_lite_rresp,
    output wire                                 s_axi_lite_rvalid,
    input  wire                                 s_axi_lite_rready,

    // --- AXI-Master Interface (for DMA to External RAM) ---
    // (AW/W/B/AR/R channel signals, omitted for brevity but standard AXI)
    // This is the DMA output to RAM
    // ... all AXI-Master signals here ...
    output wire [C_M_AXI_ADDR_WIDTH-1:0]         m_axi_awaddr,
    output wire [7:0]                            m_axi_awlen,
    output wire                                  m_axi_awvalid,
    input  wire                                  m_axi_awready,
    output wire [C_M_AXI_DATA_WIDTH-1:0]         m_axi_wdata,
    output wire [C_M_AXI_DATA_WIDTH/8-1:0]       m_axi_wstrb,
    output wire                                  m_axi_wvalid,
    input  wire                                  m_axi_wready,
    input  wire [1:0]                            m_axi_bresp,
    input  wire                                  m_axi_bvalid,
    output wire                                  m_axi_bready,
    output wire [C_M_AXI_ADDR_WIDTH-1:0]         m_axi_araddr,
    output wire [7:0]                            m_axi_arlen,
    output wire                                  m_axi_arvalid,
    input  wire                                  m_axi_arready,
    input  wire [C_M_AXI_DATA_WIDTH-1:0]         m_axi_rdata,
    input  wire [1:0]                            m_axi_rresp,
    input  wire                                  m_axi_rvalid,
    output wire                                  m_axi_rready,

    // Interrupt to CPU
    output wire                                 interrupt
);

    // --- Internal Register Addresses (for CPU via AXI-Lite) ---
    localparam ADDR_CONTROL_REG      = 6'h00; // Bit 0: Start, Bit 1: Reset Core
    localparam ADDR_STATUS_REG       = 6'h04; // Bit 0: Busy, Bit 1: Done, Bit 2: Error
    localparam ADDR_WGT_BASE_ADDR    = 6'h10; // Start address of weights in external RAM
    localparam ADDR_WGT_SIZE         = 6'h14; // Size of weights in bytes
    localparam ADDR_INPUT_BASE_ADDR  = 6'h18; // Start address of input data in external RAM
    localparam ADDR_INPUT_SIZE       = 6'h1C; // Size of input data in bytes
    localparam ADDR_OUTPUT_BASE_ADDR = 6'h20; // Start address for results in external RAM
    localparam ADDR_OUTPUT_SIZE      = 6'h24; // Size of output results
    localparam ADDR_OP_CODE_REG      = 6'h28; // Operation code (e.g., 0=CONV, 1=FC, 2=RELU)
    localparam ADDR_OP_PARAMS_REG_0  = 6'h2C; // Parameters for operation (e.g., filter size, stride)
    localparam ADDR_OP_PARAMS_REG_1  = 6'h30; // More parameters

    // --- Internal Register Storage ---
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] control_reg       = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] status_reg        = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] wgt_base_addr_reg = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] wgt_size_reg      = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] input_base_addr_reg = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] input_size_reg    = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] output_base_addr_reg = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] output_size_reg   = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] op_code_reg       = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] op_params_reg_0   = 32'b0;
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] op_params_reg_1   = 32'b0;

    // --- Signals for CPU Interaction ---
    wire cpu_start_accel;
    wire cpu_reset_core;

    assign cpu_start_accel = control_reg[0];
    assign cpu_reset_core  = control_reg[1];

    // --- Internal State Machine Control ---
    localparam FSM_IDLE             = 3'b000;
    localparam FSM_DMA_READ_WEIGHTS = 3'b001;
    localparam FSM_DMA_READ_INPUT   = 3'b010;
    localparam FSM_COMPUTE          = 3'b011;
    localparam FSM_DMA_WRITE_OUTPUT = 3'b100;
    localparam FSM_DONE             = 3'b101;
    localparam FSM_ERROR            = 3'b110;

    reg [2:0] current_state = FSM_IDLE;
    reg [2:0] next_state    = FSM_IDLE;

    // FSM transitions
    always @(posedge clk) begin
        if (!rst_n || cpu_reset_core) begin
            current_state <= FSM_IDLE;
        end else begin
            current_state <= next_state;
        end
    end

    // FSM next state logic
    always @(*) begin
        next_state = current_state; // Default to self-loop

        case (current_state)
            FSM_IDLE: begin
                if (cpu_start_accel) begin
                    next_state = FSM_DMA_READ_WEIGHTS;
                end
            end
            FSM_DMA_READ_WEIGHTS: begin
                if (dma_weights_done) begin // Signal from DMA controller
                    next_state = FSM_DMA_READ_INPUT;
                end
            end
            FSM_DMA_READ_INPUT: begin
                if (dma_input_done) begin // Signal from DMA controller
                    next_state = FSM_COMPUTE;
                end
            end
            FSM_COMPUTE: begin
                if (ml_core_done) begin // Signal from ML Processing Unit
                    next_state = FSM_DMA_WRITE_OUTPUT;
                end
            end
            FSM_DMA_WRITE_OUTPUT: begin
                if (dma_output_done) begin // Signal from DMA controller
                    next_state = FSM_DONE;
                end
            end
            FSM_DONE: begin
                next_state = FSM_IDLE; // Automatically return to IDLE after signaling done
            end
            FSM_ERROR: begin
                next_state = FSM_IDLE; // Return to IDLE after error
            end
        endcase
    end

    // --- Status Register Logic ---
    always @(posedge clk) begin
        if (!rst_n || cpu_reset_core) begin
            status_reg <= 32'b0;
        end else begin
            status_reg[0] <= (current_state != FSM_IDLE); // Busy
            status_reg[1] <= (current_state == FSM_DONE); // Done
            status_reg[2] <= (current_state == FSM_ERROR); // Error
        end
    end

    // --- Interrupt Generation ---
    assign interrupt = status_reg[1] | status_reg[2]; // Interrupt on done or error


    // --- DMA Controller Interface Signals ---
    wire dma_read_weights_req;
    wire dma_read_input_req;
    wire dma_write_output_req;
    wire dma_weights_done;
    wire dma_input_done;
    wire dma_output_done;
    wire dma_read_error;
    wire dma_write_error;

    assign dma_read_weights_req = (current_state == FSM_DMA_READ_WEIGHTS);
    assign dma_read_input_req   = (current_state == FSM_DMA_READ_INPUT);
    assign dma_write_output_req = (current_state == FSM_DMA_WRITE_OUTPUT);

    // --- Data Stream between DMA and ML Core ---
    // AXI-Stream for efficient data transfer between DMA and ML Core
    wire [C_M_AXI_DATA_WIDTH-1:0] dma_to_ml_data_tdata;
    wire                          dma_to_ml_data_tvalid;
    wire                          dma_to_ml_data_tready;

    wire [C_M_AXI_DATA_WIDTH-1:0] ml_to_dma_result_tdata;
    wire                          ml_to_dma_result_tvalid;
    wire                          ml_to_dma_result_tready;

    // --- ML Processing Unit Control ---
    wire ml_core_start;
    wire ml_core_done;
    wire ml_core_error;

    assign ml_core_start = (current_state == FSM_COMPUTE);
    // (Other control signals to ML core based on op_code_reg and op_params_regs)

    // --- INSTANTIATE SUB-MODULES ---

    // 1. AXI-Lite Slave Interface (CPU Control)
    axi_lite_interface #(
        .C_S_AXI_LITE_DATA_WIDTH(C_S_AXI_LITE_DATA_WIDTH),
        .C_S_AXI_LITE_ADDR_WIDTH(C_S_AXI_LITE_ADDR_WIDTH)
    ) axi_lite_inst (
        .clk(clk),
        .rst_n(rst_n),
        // AXI-Lite signals ...
        .s_axi_lite_awaddr(s_axi_lite_awaddr),
        .s_axi_lite_awvalid(s_axi_lite_awvalid),
        .s_axi_lite_awready(s_axi_lite_awready),
        .s_axi_lite_wdata(s_axi_lite_wdata),
        .s_axi_lite_wvalid(s_axi_lite_wvalid),
        .s_axi_lite_wready(s_axi_lite_wready),
        .s_axi_lite_bresp(s_axi_lite_bresp),
        .s_axi_lite_bvalid(s_axi_lite_bvalid),
        .s_axi_lite_bready(s_axi_lite_bready),
        .s_axi_lite_araddr(s_axi_lite_araddr),
        .s_axi_lite_arvalid(s_axi_lite_arvalid),
        .s_axi_lite_arready(s_axi_lite_arready),
        .s_axi_lite_rdata(s_axi_lite_rdata),
        .s_axi_lite_rresp(s_axi_lite_rresp),
        .s_axi_lite_rvalid(s_axi_lite_rvalid),
        .s_axi_lite_rready(s_axi_lite_rready),

        // Register access
        .control_reg_wdata(control_reg),
        .status_reg_rdata(status_reg),
        .wgt_base_addr_reg_wdata(wgt_base_addr_reg),
        .wgt_size_reg_wdata(wgt_size_reg),
        .input_base_addr_reg_wdata(input_base_addr_reg),
        .input_size_reg_wdata(input_size_reg),
        .output_base_addr_reg_wdata(output_base_addr_reg),
        .output_size_reg_wdata(output_size_reg),
        .op_code_reg_wdata(op_code_reg),
        .op_params_reg_0_wdata(op_params_reg_0),
        .op_params_reg_1_wdata(op_params_reg_1)
    );

    // 2. DMA Controller (AXI Master)
    dma_controller #(
        .C_M_AXI_DATA_WIDTH(C_M_AXI_DATA_WIDTH),
        .C_M_AXI_ADDR_WIDTH(C_M_AXI_ADDR_WIDTH)
    ) dma_inst (
        .clk(clk),
        .rst_n(rst_n),
        // AXI-Master signals ...
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),

        // DMA control from FSM
        .read_weights_req(dma_read_weights_req),
        .read_input_req(dma_read_input_req),
        .write_output_req(dma_write_output_req),
        .wgt_base_addr(wgt_base_addr_reg),
        .wgt_size(wgt_size_reg),
        .input_base_addr(input_base_addr_reg),
        .input_size(input_size_reg),
        .output_base_addr(output_base_addr_reg),
        .output_size(output_size_reg),
        .dma_weights_done(dma_weights_done),
        .dma_input_done(dma_input_done),
        .dma_output_done(dma_output_done),
        .dma_read_error(dma_read_error),
        .dma_write_error(dma_write_error),

        // Data stream to/from ML Core
        .m_axis_read_data_tdata(dma_to_ml_data_tdata),
        .m_axis_read_data_tvalid(dma_to_ml_data_tvalid),
        .m_axis_read_data_tready(dma_to_ml_data_tready),

        .s_axis_write_data_tdata(ml_to_dma_result_tdata),
        .s_axis_write_data_tvalid(ml_to_dma_result_tvalid),
        .s_axis_write_data_tready(ml_to_dma_result_tready)
    );

    // 3. ML Processing Unit (The Core Engine)
    ml_processing_unit #(
        .DATA_WIDTH(C_M_AXI_DATA_WIDTH)
    ) ml_core_inst (
        .clk(clk),
        .rst_n(rst_n || cpu_reset_core), // Core reset can be external or via CPU
        
        .start(ml_core_start),
        .done(ml_core_done),
        .error(ml_core_error),

        // Configuration
        .op_code(op_code_reg),
        .op_params_0(op_params_reg_0),
        .op_params_1(op_params_reg_1),

        // Data Input Stream (from DMA)
        .s_axis_data_tdata(dma_to_ml_data_tdata),
        .s_axis_data_tvalid(dma_to_ml_data_tvalid),
        .s_axis_data_tready(dma_to_ml_data_tready),

        // Result Output Stream (to DMA)
        .m_axis_result_tdata(ml_to_dma_result_tdata),
        .m_axis_result_tvalid(ml_to_dma_result_tvalid),
        .m_axis_result_tready(ml_to_dma_result_tready)
    );

endmodule
