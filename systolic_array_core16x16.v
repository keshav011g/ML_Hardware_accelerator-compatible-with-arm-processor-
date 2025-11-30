/*
 * Module: systolic_array_16x16
 * Description: 
 * - A 16x16 grid of PEs (256 Total).
 * - Uses flattened vectors for clean I/O.
 */
module systolic_array_16x16 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,
    input  wire         load_weight,

    // Flattened Inputs (16 rows * 8 bits = 128 bits)
    // Row 0 is [7:0], Row 1 is [15:8], etc.
    input  wire [127:0] flat_ifmap_in, 

    // Flattened Weights (16 cols * 8 bits = 128 bits)
    // Only enters at the top (Daisy Chain)
    input  wire [127:0] flat_weight_in,

    // Flattened Partial Sums (16 cols * 24 bits = 384 bits)
    // Usually 0 from top
    input  wire [383:0] flat_psum_in,

    // Flattened Results (16 cols * 24 bits = 384 bits)
    output wire [383:0] flat_psum_out
);

    // Array Size Parameter
    localparam N = 16;

    // Internal Wires (Unpacked for ease of use in generate loops)
    wire signed [7:0]  w_ifmap [0:N-1][0:N]; // Horizontal
    wire signed [23:0] w_psum  [0:N][0:N-1]; // Vertical Sums
    wire signed [7:0]  w_wght  [0:N][0:N-1]; // Vertical Weights

    // Unpack Inputs to Row 0 / Col 0
    genvar i;
    generate
        for (i=0; i<N; i=i+1) begin : UNPACK
            assign w_ifmap[i][0] = flat_ifmap_in[i*8 +: 8];
            assign w_wght[0][i]  = flat_weight_in[i*8 +: 8];
            assign w_psum[0][i]  = flat_psum_in[i*24 +: 24];
            
            // Pack Outputs from Row N / Col N
            assign flat_psum_out[i*24 +: 24] = w_psum[N][i];
        end
    endgenerate

    // Generate the 16x16 Grid
    genvar r, c;
    generate
        for (r=0; r<N; r=r+1) begin : ROWS
            for (c=0; c<N; c=c+1) begin : COLS
                processing_element pe (
                    .clk         (clk),
                    .rst_n       (rst_n),
                    .en          (en),
                    .load_weight (load_weight),
                    
                    // Connection Logic
                    .ifmap_in    (w_ifmap[r][c]),
                    .psum_in     (w_psum[r][c]),
                    .weight_in   (w_wght[r][c]),
                    
                    .ifmap_out   (w_ifmap[r][c+1]),
                    .psum_out    (w_psum[r+1][c]),
                    .weight_out  (w_wght[r+1][c])
                );
            end
        end
    endgenerate

endmodule