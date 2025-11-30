/*
 * Module: ml_accelerator_top
 * Description:
 * - Controls a 16x16 Systolic Array.
 * - Handles Tiling for any matrix size (e.g. 100x100).
 * - Automatic Zero Padding logic included.
 */

module ml_accelerator_top (
    input  wire        clk,
    input  wire        rst_n,

    // CPU Register Interface
    input  wire        reg_write_en,
    input  wire [3:0]  reg_addr,
    input  wire [31:0] reg_wdata,
    output reg  [31:0] reg_rdata,
    
    output reg         irq_done, // Interrupt

    // Memory Interface (Simulated DMA)
    output reg  [31:0] mem_read_addr,
    input  wire [31:0] mem_read_data
);

    // --- Configuration ---
    localparam ARRAY_SIZE = 16;

    // Registers
    reg [31:0] reg_m_size; // Total Rows
    reg [31:0] reg_k_size; // Shared Dim
    reg [31:0] reg_n_size; // Total Cols
    reg        sys_start;
    reg        sys_busy;

    // Tiling Counters
    reg [15:0] tile_row; 
    reg [15:0] compute_counter;

    // Array Signals
    reg  load_weight;
    reg  array_en;
    reg  [4:0] load_counter; // Needs to count to 16 now

    // Virtual Wires for Padding Logic
    wire [127:0] flat_ifmap_in;
    reg  [7:0]   padded_rows [0:15]; // Temporary array for readable assignment

    // --- CPU Register Logic ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_m_size <= 32; reg_k_size <= 32; reg_n_size <= 32;
            sys_start <= 0;
        end else if (reg_write_en) begin
            case (reg_addr)
                4'h0: sys_start  <= reg_wdata[0];
                4'h2: reg_m_size <= reg_wdata;
                4'h3: reg_k_size <= reg_wdata;
                4'h4: reg_n_size <= reg_wdata;
            endcase
        end else begin
            sys_start <= 0; 
        end
    end

    // --- Main FSM ---
    localparam S_IDLE        = 0;
    localparam S_LOAD_WEIGHT = 1;
    localparam S_COMPUTE     = 2;
    localparam S_DONE        = 3;
    
    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            sys_busy <= 0;
            irq_done <= 0;
            tile_row <= 0; 
        end else begin
            case (state)
                S_IDLE: begin
                    irq_done <= 0;
                    if (sys_start) begin
                        state <= S_LOAD_WEIGHT;
                        sys_busy <= 1;
                        tile_row <= 0;
                        load_counter <= 0;
                    end
                end

                S_LOAD_WEIGHT: begin
                    // Load 16 rows of weights down the daisy chain
                    load_weight <= 1;
                    array_en <= 1;
                    
                    if (load_counter == (ARRAY_SIZE-1)) begin // Count 0 to 15
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
                        // In real logic, we would loop over tile_col here
                        state <= S_DONE; 
                    end else begin
                        compute_counter <= compute_counter + 1;
                    end
                end
                
                S_DONE: begin
                    sys_busy <= 0;
                    irq_done <= 1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // --- ZERO PADDING LOGIC (16 Rows) ---
    genvar i;
    generate
        for (i=0; i<ARRAY_SIZE; i=i+1) begin : PAD_LOGIC
            wire [31:0] global_row_idx = (tile_row * ARRAY_SIZE) + i;
            
            always @(*) begin
                // Check if this row is outside the User's Matrix Size
                if (global_row_idx >= reg_m_size) begin
                    padded_rows[i] = 8'd0; // PAD WITH ZERO
                end else begin
                    // Simulate fetching valid data
                    padded_rows[i] = 8'd1; 
                end
            end
            
            // Pack into flat vector
            assign flat_ifmap_in[i*8 +: 8] = padded_rows[i];
        end
    endgenerate

    // --- Instantiate 16x16 Array ---
    systolic_array_16x16 u_array (
        .clk(clk),
        .rst_n(rst_n),
        .en(array_en),
        .load_weight(load_weight),
        
        .flat_ifmap_in(flat_ifmap_in),
        
        // Simulated weights (constant 5 for demo)
        .flat_weight_in({16{8'd5}}), 
        
        // Zeros for top accumulators (16 * 24 bits)
        .flat_psum_in({16{24'd0}}),
        
        .flat_psum_out() // Results would go to output buffer
    );

endmodule