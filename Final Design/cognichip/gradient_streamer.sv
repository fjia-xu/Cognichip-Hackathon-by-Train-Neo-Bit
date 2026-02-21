// FILE: gradient_streamer.sv
// Gradient Streamer - preprocessing stage for set-associative accumulator
// - Sign-extends input gradient from 16-bit to 32-bit
// - Extracts set index from address (for set-associative buffer)
// - Checks if gradient directly triggers threshold (bypass buffer)
//
// Key Changes for Set-Associative:
// - NUM_WAYS parameter added
// - req_index → req_set_index
// - SET_INDEX_WIDTH = $clog2(DEPTH/NUM_WAYS) instead of $clog2(DEPTH)

module gradient_streamer #(
    parameter int DEPTH = 256,
    parameter int NUM_WAYS = 4,
    parameter logic signed [31:0] THRESHOLD = 32'sd1000
) (
    input  logic                in_valid,
    input  logic [31:0]         in_addr,
    input  logic signed [15:0]  in_grad,
    
    output logic                req_valid,
    output logic [31:0]         req_addr,
    output logic [$clog2(DEPTH/NUM_WAYS)-1:0] req_set_index,
    output logic signed [31:0]  req_grad_ext,
    output logic                req_direct_trigger
);

    localparam int NUM_SETS = DEPTH / NUM_WAYS;
    localparam int SET_INDEX_WIDTH = $clog2(NUM_SETS);
    
    // Sign-extend input gradient to 32-bit
    assign req_grad_ext = {{16{in_grad[15]}}, in_grad};
    
    // Extract set index from address
    // For set-associative buffer, only need set index (not total entry index)
    assign req_set_index = in_addr[SET_INDEX_WIDTH-1:0];
    
    // Pass through address and valid
    assign req_addr = in_addr;
    assign req_valid = in_valid;
    
    // Compute absolute values for threshold comparison
    logic signed [31:0] abs_in_grad;
    logic signed [31:0] abs_threshold;
    
    assign abs_in_grad = (req_grad_ext < 0) ? -req_grad_ext : req_grad_ext;
    assign abs_threshold = (THRESHOLD < 0) ? -THRESHOLD : THRESHOLD;
    
    // Check if input gradient meets threshold
    // If true, bypass buffer and writeback directly (push to FIFO)
    assign req_direct_trigger = (abs_in_grad >= abs_threshold);

endmodule
