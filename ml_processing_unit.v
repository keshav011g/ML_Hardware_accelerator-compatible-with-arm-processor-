// ml_processing_unit.v
// This is the core ML engine, a 'mini-NPU'.
// It performs specific ML operations based on op_code and op_params.
// This is where the custom parallel hardware for "minimum clock cycle" lives.

module ml_processing_unit #(
    parameter DATA_WIDTH = 128 // Width of input/output data (e.g., 8x16-bit or 16x8-bit values)
)(
    input  wire clk,
    input  wire rst_n, // Includes CPU-initiated reset

    input  wire                                 start, // Start computation
    output reg                                  done,  // Computation finished
    output reg                                  error, // Computation error

    // Configuration for the current ML operation
    input  wire [31:0]                          op_code,   // e.g., 0=CONV, 1=FC, 2=RELU, 3=POOL
    input  wire [31:0]                          op_params_0, // e.g., filter_size, stride
    input  wire [31:0]                          op_params_1, // e.g., input_channels, output_channels

    // Data Input Stream (from DMA) - combined weights and input for simplicity here
    input  wire [DATA_WIDTH-1:0]                s_axis_data_tdata,
    input  wire                                 s_axis_data_tvalid,
    output wire                                 s_axis_data_tready,

    // Result Output Stream (to DMA)
    output wire [DATA_WIDTH-1:0]                m_axis_result_tdata,
    output wire                                 m_axis_result_tvalid,
    input  wire                                 m_axis_result_tready
);

    // --- Internal State Machine for this Unit ---
    localparam CORE_IDLE    = 2'b00;
    localparam CORE_PROCESS = 2'b01;
    localparam CORE_FINISH  = 2'b10;

    reg [1:0] core_state = CORE_IDLE;
    reg [31:0] compute_cycles_left = 32'd0; // Dummy cycle counter for simulation

    // **********************************************************************
    // *** THIS IS THE HEART OF THE ACCELERATOR ***
    //
    // A REAL ml_processing_unit would contain:
    //
    // 1.  **Instruction Decoder:** Interprets `op_code` and `op_params`.
    // 2.  **Internal BRAMs:** Fast on-chip memory to buffer data from the stream
    //     before computation (e.g., a few filter rows, input image patches).
    // 3.  **Systolic Array / Parallel MAC Units:** The actual "calculators"
    //     for matrix multiplications (e.g., for CONV or Fully Connected layers).
    //     This is where your 'minimum clock cycle' is achieved by doing
    //     many computations in parallel.
    // 4.  **Activation Units:** Small hardware blocks for ReLU, Sigmoid, etc.
    // 5.  **Pooling Units:** For Max/Average Pooling.
    // 6.  **Internal Control FSM:** Manages the data flow through these units
    //     for the *specific* operation (`op_code`).
    //
    // This unit will continuously pull data from `s_axis_data_tdata`
    // (weights and input, interleaved or separate streams) and push results
    // to `m_axis_result_tdata`.
    // **********************************************************************

    // --- Dummy Logic for Simulation ---
    assign s_axis_data_tready = (core_state == CORE_PROCESS) && (compute_cycles_left > 0);
    assign m_axis_result_tdata = s_axis_data_tdata; // Just pass through input as output for dummy
    assign m_axis_result_tvalid = (core_state == CORE_FINISH); // Valid when 'done' for dummy

    always @(posedge clk) begin
        if (!rst_n) begin
            core_state <= CORE_IDLE;
            done <= 1'b0;
            error <= 1'b0;
            compute_cycles_left <= 32'd0;
        end else begin
            done <= 1'b0; // Pulse for one cycle
            error <= 1'b0;

            case (core_state)
                CORE_IDLE: begin
                    if (start) begin
                        core_state <= CORE_PROCESS;
                        // For dummy: Assume compute time based on some params
                        compute_cycles_left <= 32'd1000; // Simulate 1000 cycles of work
                    end
                end
                CORE_PROCESS: begin
                    if (s_axis_data_tvalid && s_axis_data_tready) begin
                        // In real core, process input data here
                        // For dummy, just decrement counter
                        if (compute_cycles_left > 0) begin
                            compute_cycles_left <= compute_cycles_left - 1;
                        end
                    end
                    
                    if (compute_cycles_left == 0) begin // Finished processing
                        core_state <= CORE_FINISH;
                    end
                end
                CORE_FINISH: begin
                    done <= 1'b1; // Signal done
                    core_state <= CORE_IDLE;
                end
                default: core_state <= CORE_IDLE;
            endcase
        end
    end

endmodule
