// =============================================================================
// Module: dynamic_threshold_controller
// Description: 
//   Computes a dynamic threshold using Exponential Moving Average (EMA) of
//   incoming gradient magnitudes. The EMA weight alpha = 1/16 is implemented
//   using bit shifts to avoid multipliers.
//
// Algorithm:
//   T_new = T_old - (T_old >> SHIFT_BITS) + (|Gradient_In| >> SHIFT_BITS)
//
// Features:
//   - Fixed-point EMA implementation using shifts
//   - Saturation logic to prevent overflow
//   - Clean separation of combinational and sequential logic
// =============================================================================

module dynamic_threshold_controller #(
    parameter int GRAD_WIDTH      = 16,  // Gradient bit width
    parameter int SHIFT_BITS      = 4,   // EMA weight: alpha = 1/2^SHIFT_BITS
    parameter int INIT_THRESHOLD  = 50   // Initial threshold value on reset
) (
    input  logic                      clock,
    input  logic                      reset,
    input  logic                      valid_in,
    input  logic signed [GRAD_WIDTH-1:0]  Gradient_In,
    output logic        [GRAD_WIDTH-1:0]  Dynamic_Threshold
);

    // =========================================================================
    // Internal Signals
    // =========================================================================
    
    // Current threshold register (sequential)
    logic [GRAD_WIDTH-1:0] threshold_reg;
    
    // Combinational signals for EMA calculation
    logic [GRAD_WIDTH-1:0] abs_gradient;
    logic [GRAD_WIDTH-1:0] old_shifted;
    logic [GRAD_WIDTH-1:0] abs_shifted;
    logic [GRAD_WIDTH:0]   subtraction_result;  // Extra bit for borrow detection
    logic [GRAD_WIDTH:0]   addition_result;     // Extra bit for overflow detection
    logic [GRAD_WIDTH-1:0] new_threshold;
    
    // =========================================================================
    // Combinational Logic: Absolute Value Calculation
    // =========================================================================
    
    always_comb begin
        // Compute absolute value of signed gradient
        if (Gradient_In[GRAD_WIDTH-1] == 1'b1) begin
            // Negative: two's complement
            abs_gradient = ~Gradient_In + 1'b1;
        end else begin
            // Positive or zero
            abs_gradient = Gradient_In;
        end
    end
    
    // =========================================================================
    // Combinational Logic: EMA Update Calculation
    // =========================================================================
    
    always_comb begin
        // Shift operations for fixed-point division
        old_shifted = threshold_reg >> SHIFT_BITS;
        abs_shifted = abs_gradient >> SHIFT_BITS;
        
        // Step 1: Subtract (T_old >> SHIFT_BITS) from T_old
        // Use extra bit to detect underflow
        subtraction_result = {1'b0, threshold_reg} - {1'b0, old_shifted};
        
        // Step 2: Add (|Gradient_In| >> SHIFT_BITS)
        // Use extra bit to detect overflow
        addition_result = subtraction_result + {1'b0, abs_shifted};
        
        // Step 3: Apply saturation logic
        if (valid_in) begin
            // Check for overflow (MSB of extended result is set)
            if (addition_result[GRAD_WIDTH] == 1'b1) begin
                // Saturation: clamp to maximum value
                new_threshold = {GRAD_WIDTH{1'b1}};
            end else begin
                // Normal case: use computed value
                new_threshold = addition_result[GRAD_WIDTH-1:0];
            end
        end else begin
            // No update when valid_in is low
            new_threshold = threshold_reg;
        end
    end
    
    // =========================================================================
    // Sequential Logic: Threshold Register Update
    // =========================================================================
    
    always_ff @(posedge clock) begin
        if (reset) begin
            // Reset threshold to initial value
            threshold_reg <= INIT_THRESHOLD[GRAD_WIDTH-1:0];
        end else begin
            // Update threshold with new value
            threshold_reg <= new_threshold;
        end
    end
    
    // =========================================================================
    // Output Assignment
    // =========================================================================
    
    assign Dynamic_Threshold = threshold_reg;

endmodule
