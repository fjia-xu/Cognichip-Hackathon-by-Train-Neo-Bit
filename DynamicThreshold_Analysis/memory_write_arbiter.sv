// Memory Write Arbiter Module
// Function: Exit point that collects significant gradient updates and sends to main memory
// Arbitrates between Path A (high-magnitude gradients) and Eviction Path (cache overflow)

module memory_write_arbiter #(
    parameter int ADDR_WIDTH = 32,
    parameter int VALUE_WIDTH = 16
) (
    // Clock and Reset
    input  logic                         clock,
    input  logic                         reset,
    
    // Path A Input (High-Magnitude Gradients from Module 1)
    input  logic [ADDR_WIDTH-1:0]        path_a_address,
    input  logic signed [VALUE_WIDTH-1:0] path_a_value,
    input  logic                         path_a_valid,
    
    // Eviction Path Input (Cache Evictions from Module 2)
    input  logic [ADDR_WIDTH-1:0]        evict_address,
    input  logic signed [VALUE_WIDTH-1:0] evict_value,
    input  logic                         evict_valid,
    
    // Memory Controller Output Interface
    output logic [ADDR_WIDTH-1:0]        mem_address,
    output logic signed [VALUE_WIDTH-1:0] mem_value,
    output logic                         mem_valid,
    
    // Optional: Memory controller ready signal (for flow control)
    input  logic                         mem_ready
);

    //===========================================
    // Internal Signals
    //===========================================
    
    // Arbiter selected signals (combinational)
    logic [ADDR_WIDTH-1:0]        selected_address;
    logic signed [VALUE_WIDTH-1:0] selected_value;
    logic                         selected_valid;
    logic                         select_path_a;  // Arbitration decision
    
    //===========================================
    // Arbiter Logic (2-to-1 Multiplexer with Priority)
    //===========================================
    // Path A has priority over Eviction Path
    // If both are valid, Path A is selected
    
    always_comb begin
        // Priority logic: Path A > Eviction Path
        if (path_a_valid) begin
            // Path A has priority
            select_path_a     = 1'b1;
            selected_address  = path_a_address;
            selected_value    = path_a_value;
            selected_valid    = 1'b1;
        end else if (evict_valid) begin
            // Eviction path is selected only if Path A is not valid
            select_path_a     = 1'b0;
            selected_address  = evict_address;
            selected_value    = evict_value;
            selected_valid    = 1'b1;
        end else begin
            // No valid data on either path
            select_path_a     = 1'b0;
            selected_address  = '0;
            selected_value    = '0;
            selected_valid    = 1'b0;
        end
    end
    
    //===========================================
    // Output Buffer (Register)
    //===========================================
    // Holds the {Address, Value} pair and asserts Valid signal
    // Implements simple flow control with mem_ready signal
    
    always_ff @(posedge clock) begin
        if (reset) begin
            // Clear output buffer on reset
            mem_address <= '0;
            mem_value   <= '0;
            mem_valid   <= 1'b0;
        end else begin
            // Check if memory controller is ready to accept new data
            if (mem_ready || !mem_valid) begin
                // Buffer is empty or data was consumed, can accept new data
                if (selected_valid) begin
                    // Latch selected data into output buffer
                    mem_address <= selected_address;
                    mem_value   <= selected_value;
                    mem_valid   <= 1'b1;
                end else begin
                    // No valid data to buffer - clear outputs
                    mem_address <= '0;
                    mem_value   <= '0;
                    mem_valid   <= 1'b0;
                end
            end
            // else: mem_valid remains high, holding current data until mem_ready
        end
    end

endmodule
