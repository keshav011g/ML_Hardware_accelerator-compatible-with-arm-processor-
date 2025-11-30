/*
 * Module: processing_element
 * Description: 
 * - Weight Stationary PE.
 * - Supports Daisy-Chain loading.
 * - 8-bit Input, 8-bit Weight, 24-bit Accumulator.
 */
module processing_element (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          
    input  wire        load_weight, 

    // Data Inputs
    input  wire signed [7:0]  ifmap_in,   // From Left
    input  wire signed [23:0] psum_in,    // From Top
    input  wire signed [7:0]  weight_in,  // From Top (Daisy Chain)

    // Data Outputs
    output reg  signed [7:0]  ifmap_out,  // To Right
    output reg  signed [23:0] psum_out,   // To Bottom
    output reg  signed [7:0]  weight_out  // To Bottom (Daisy Chain)
);

    reg signed [7:0] weight_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_reg <= 8'd0;
            ifmap_out  <= 8'd0;
            psum_out   <= 24'd0;
            weight_out <= 8'd0;
        end else if (en) begin
            if (load_weight) begin
                // --- LOAD MODE ---
                weight_reg <= weight_in;
                weight_out <= weight_reg; // Daisy chain pass-through
                ifmap_out  <= 8'd0;
                psum_out   <= 24'd0;
            end else begin
                // --- COMPUTE MODE ---
                weight_reg <= weight_reg;
                weight_out <= weight_reg; 
                ifmap_out  <= ifmap_in;
                // MAC Operation
                psum_out   <= psum_in + (ifmap_in * weight_reg);
            end
        end
    end
endmodule