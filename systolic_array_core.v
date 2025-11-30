/*
 * Module: systolic_array_4x4
 * Description: 
 * A 4x4 grid of processing elements.
 * * - Weights are loaded serially (or parallel depending on complexity).
 * Here, we assume we load column-by-column or simply use a dedicated 
 * loading network. For simplicity in this example, we expose all weight
 * inputs, and the controller handles the broadcasting.
 * * - Inputs (IFMAPS) enter from the LEFT side (col 0).
 * - Partial Sums (PSUMS) enter from the TOP side (row 0), usually 0.
 * - Results exit from the BOTTOM side (row 3).
 */

module systolic_array_4x4 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire        load_weight,

    // Array Inputs (Left edge of the array)
    // 4 rows of 8-bit inputs
    input  wire signed [7:0]  ifmap_in_0,
    input  wire signed [7:0]  ifmap_in_1,
    input  wire signed [7:0]  ifmap_in_2,
    input  wire signed [7:0]  ifmap_in_3,

    // Weight Inputs (For loading phase)
    // In a real optimized ASIC, you might daisy-chain these to save wiring area.
    // For clarity here, we provide a bus for each PE.
    input  wire signed [7:0]  weight_in [0:3][0:3], 

    // Array Outputs (Bottom edge of the array)
    // 4 cols of 24-bit results
    output wire signed [23:0] psum_out_0,
    output wire signed [23:0] psum_out_1,
    output wire signed [23:0] psum_out_2,
    output wire signed [23:0] psum_out_3
);

    // ----------------------------------------------------------------------
    // Internal Wires for Inter-PE Connections
    // ----------------------------------------------------------------------
    // ifmap_wires[row][col+1] carries data from PE[row][col] to PE[row][col+1]
    wire signed [7:0]  ifmap_wires [0:3][0:4]; 
    
    // psum_wires[row+1][col] carries data from PE[row][col] to PE[row+1][col]
    wire signed [23:0] psum_wires  [0:4][0:3];


    // ----------------------------------------------------------------------
    // Wire Assignments for Boundary Conditions
    // ----------------------------------------------------------------------
    
    // Connect Module Inputs to the Left-most wires (Column 0)
    assign ifmap_wires[0][0] = ifmap_in_0;
    assign ifmap_wires[1][0] = ifmap_in_1;
    assign ifmap_wires[2][0] = ifmap_in_2;
    assign ifmap_wires[3][0] = ifmap_in_3;

    // Connect Zeros to the Top-most wires (Row 0) 
    // (Unless you are cascading arrays, the top sum starts at 0)
    assign psum_wires[0][0] = 24'd0;
    assign psum_wires[0][1] = 24'd0;
    assign psum_wires[0][2] = 24'd0;
    assign psum_wires[0][3] = 24'd0;

    // Connect Bottom-most wires (Row 4) to Module Outputs
    assign psum_out_0 = psum_wires[4][0];
    assign psum_out_1 = psum_wires[4][1];
    assign psum_out_2 = psum_wires[4][2];
    assign psum_out_3 = psum_wires[4][3];


    // ----------------------------------------------------------------------
    // Generate the 4x4 Grid
    // ----------------------------------------------------------------------
    genvar r, c;
    generate
        for (r = 0; r < 4; r = r + 1) begin : ROW
            for (c = 0; c < 4; c = c + 1) begin : COL
                
                processing_element pe (
                    .clk         (clk),
                    .rst_n       (rst_n),
                    .en          (en),
                    .load_weight (load_weight),
                    
                    // Inputs
                    .weight_in   (weight_in[r][c]),
                    .ifmap_in    (ifmap_wires[r][c]),   // From Left
                    .psum_in     (psum_wires[r][c]),    // From Top
                    
                    // Outputs
                    .ifmap_out   (ifmap_wires[r][c+1]), // To Right
                    .psum_out    (psum_wires[r+1][c])   // To Bottom
                );
                
            end
        end
    endgenerate

endmodule