`timescale 1ns / 1ps

module processing_element (
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire load_weight,

    // Daisy-chain connections from adjacent PEs
    input  wire signed [7:0]  ifmap_in,
    input  wire signed [23:0] psum_in,
    input  wire signed [7:0]  weight_in,

    // Daisy-chain connections to adjacent PEs
    output reg  signed [7:0]  ifmap_out,
    output reg  signed [23:0] psum_out,
    output reg  signed [7:0]  weight_out
);

    // Internal Register for Weight-Stationary Dataflow
    reg signed [7:0] internal_weight;

    // -------------------------------------------------------------------------
    // 1. RADIX-4 MODIFIED BOOTH ENCODING (Generates 4 Partial Products)
    // -------------------------------------------------------------------------
    wire [8:0] booth_y = {ifmap_in, 1'b0};
    wire signed [15:0] M       = {{8{internal_weight[7]}}, internal_weight};
    wire signed [15:0] neg_M   = -M;
    wire signed [15:0] M_2     = M << 1;
    wire signed [15:0] neg_M_2 = neg_M << 1;

    reg signed [15:0] pp [0:3];
    integer i;

    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
            case (booth_y[2*i +: 3])
                3'b000, 3'b111: pp[i] = 16'd0;
                3'b001, 3'b010: pp[i] = M << (2*i);
                3'b011:         pp[i] = M_2 << (2*i);
                3'b100:         pp[i] = neg_M_2 << (2*i);
                3'b101, 3'b110: pp[i] = neg_M << (2*i);
                default:        pp[i] = 16'd0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 2. WALLACE TREE REDUCTION WITH 4:2 COMPRESSORS
    // -------------------------------------------------------------------------
    wire [15:0] wallace_sum;
    wire [15:0] wallace_carry;
    
    genvar j;
    generate
        for (j = 0; j < 16; j = j + 1) begin : compressor_4to2
            wire w_xor1 = pp[0][j] ^ pp[1][j];
            wire w_xor2 = pp[2][j] ^ pp[3][j];
            assign wallace_sum[j]   = w_xor1 ^ w_xor2;
            assign wallace_carry[j] = (w_xor1 & w_xor2) | (~w_xor1 & pp[3][j]); 
        end
    endgenerate

    // Final Vector-Merging Adder
    wire signed [15:0] product;
    assign product = wallace_sum + (wallace_carry << 1);

    // -------------------------------------------------------------------------
    // 3. SEQUENTIAL LOGIC & DAISY CHAINING
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            internal_weight <= 8'd0;
            weight_out      <= 8'd0;
            ifmap_out       <= 8'd0;
            psum_out        <= 24'd0;
        end else if (en) begin
            // Feature maps always flow horizontally
            ifmap_out <= ifmap_in;

            if (load_weight) begin
                // Phase 1: Load Weights vertically down the columns
                internal_weight <= weight_in;
                weight_out      <= weight_in;
                psum_out        <= psum_in; // Pass zeros
            end else begin
                // Phase 2: Compute MAC and pass partial sums vertically
                psum_out <= psum_in + {{8{product[15]}}, product};
            end
        end
    end

endmodule
