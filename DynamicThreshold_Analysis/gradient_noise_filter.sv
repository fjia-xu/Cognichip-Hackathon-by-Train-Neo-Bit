// Gradient Noise Filter Module
// Function: Filters noise by routing gradients to different paths based on magnitude
// Path A: High-magnitude gradients (immediate processing - Packer)
// Path B: Low-magnitude gradients (buffering - Accumulator)

module gradient_noise_filter #(
    parameter int ADDR_WIDTH = 32,
    parameter int GRAD_WIDTH = 16,
    parameter int DEFAULT_THRESHOLD = 100  // Default threshold value
) (
    // Clock and Reset
    input  logic                      clock,
    input  logic                      reset,
    
    // Input Bus
    input  logic [ADDR_WIDTH-1:0]     Address_In,
    input  logic signed [GRAD_WIDTH-1:0] Gradient_In,
    input  logic                      valid_in,      // Input data valid signal
    
    // Threshold Configuration
    input  logic [GRAD_WIDTH-1:0]     Threshold,     // Configurable threshold
    
    // Path A Outputs (Packer - High magnitude gradients)
    output logic [ADDR_WIDTH-1:0]     Address_A,
    output logic signed [GRAD_WIDTH-1:0] Gradient_A,
    output logic                      Valid_A,
    
    // Path B Outputs (Accumulator - Low magnitude gradients)
    output logic [ADDR_WIDTH-1:0]     Address_B,
    output logic signed [GRAD_WIDTH-1:0] Gradient_B,
    output logic                      Valid_B
);

    // Internal Signals
    logic [GRAD_WIDTH-1:0] Abs_Gradient;  // Absolute value of gradient
    logic                  path_select;   // 0: Path B, 1: Path A
    
    //===========================================
    // Absolute Value Logic (ABS)
    //===========================================
    // Converts negative numbers to positive using two's complement
    // if (Gradient_In < 0) return (~Gradient_In + 1); else return Gradient_In;
    
    always_comb begin
        if (Gradient_In < 0) begin
            // Two's complement for negative numbers
            Abs_Gradient = (~Gradient_In) + 1'b1;
        end else begin
            // Positive numbers remain unchanged
            Abs_Gradient = Gradient_In;
        end
    end
    
    //===========================================
    // Comparator (Magnitude)
    //===========================================
    // Compares absolute gradient with threshold
    // if (Abs_Gradient > Threshold) -> Path A; else -> Path B
    
    always_comb begin
        if (Abs_Gradient > Threshold) begin
            path_select = 1'b1;  // Path A (High magnitude)
        end else begin
            path_select = 1'b0;  // Path B (Low magnitude)
        end
    end
    
    //===========================================
    // Path Mux (Router) - 1-to-2 Demultiplexer
    //===========================================
    // Routes {Address, Gradient} pair to either Path A or Path B
    
    always_ff @(posedge clock) begin
        if (reset) begin
            // Reset all outputs
            Address_A  <= '0;
            Gradient_A <= '0;
            Valid_A    <= 1'b0;
            
            Address_B  <= '0;
            Gradient_B <= '0;
            Valid_B    <= 1'b0;
            
        end else begin
            if (valid_in) begin
                if (path_select) begin
                    // Route to Path A (Packer)
                    Address_A  <= Address_In;
                    Gradient_A <= Gradient_In;
                    Valid_A    <= 1'b1;
                    
                    // Clear Path B
                    Address_B  <= '0;
                    Gradient_B <= '0;
                    Valid_B    <= 1'b0;
                    
                end else begin
                    // Route to Path B (Accumulator)
                    Address_B  <= Address_In;
                    Gradient_B <= Gradient_In;
                    Valid_B    <= 1'b1;
                    
                    // Clear Path A
                    Address_A  <= '0;
                    Gradient_A <= '0;
                    Valid_A    <= 1'b0;
                end
            end else begin
                // No valid input, clear all outputs
                Address_A  <= '0;
                Gradient_A <= '0;
                Valid_A    <= 1'b0;
                
                Address_B  <= '0;
                Gradient_B <= '0;
                Valid_B    <= 1'b0;
            end
        end
    end

endmodule
