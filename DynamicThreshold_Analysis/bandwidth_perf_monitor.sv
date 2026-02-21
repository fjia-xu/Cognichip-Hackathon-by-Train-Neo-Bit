// =============================================================================
// Module: bandwidth_perf_monitor
// Description: 
//   Performance monitoring module for tracking bandwidth utilization and
//   compression efficiency in the gradient system. Counts input transactions
//   and output memory writes to calculate compression ratios.
//
// Features:
//   - Real-time transaction counting
//   - Bandwidth calculation in bytes
//   - Compression ratio and reduction metrics
//   - Functions for easy testbench access
// =============================================================================

module bandwidth_perf_monitor #(
    parameter int DATA_BYTES = 4  // Bytes per transaction (address + gradient)
) (
    input  logic clock,
    input  logic reset,
    input  logic valid_in,     // Input gradient valid signal
    input  logic mem_valid,    // Memory write valid signal
    input  logic mem_ready     // Memory ready signal
);

    // =========================================================================
    // Performance Counters
    // =========================================================================
    
    // Count of raw input transactions (gradient inputs to the system)
    int unsigned raw_input_tx_count;
    
    // Count of compressed output transactions (actual memory writes)
    int unsigned compressed_output_tx_count;
    
    // =========================================================================
    // Transaction Counting Logic
    // =========================================================================
    
    always_ff @(posedge clock) begin
        if (reset) begin
            // Reset all counters
            raw_input_tx_count <= 0;
            compressed_output_tx_count <= 0;
        end else begin
            // Count input transactions when valid_in is asserted
            if (valid_in) begin
                raw_input_tx_count <= raw_input_tx_count + 1;
            end
            
            // Count output transactions when memory write completes
            // (mem_valid asserted AND mem_ready asserted)
            if (mem_valid && mem_ready) begin
                compressed_output_tx_count <= compressed_output_tx_count + 1;
            end
        end
    end
    
    // =========================================================================
    // Bandwidth Calculation Functions
    // =========================================================================
    
    // Calculate total raw input bandwidth in bytes
    function automatic int unsigned get_raw_bytes();
        return raw_input_tx_count * DATA_BYTES;
    endfunction
    
    // Calculate total compressed output bandwidth in bytes
    function automatic int unsigned get_compressed_bytes();
        return compressed_output_tx_count * DATA_BYTES;
    endfunction
    
    // Calculate compression ratio (raw / compressed)
    function automatic real get_compression_ratio();
        if (compressed_output_tx_count > 0)
            return $itor(raw_input_tx_count) / $itor(compressed_output_tx_count);
        else
            return 0.0;
    endfunction
    
    // Calculate bandwidth reduction percentage
    function automatic real get_bandwidth_reduction_pct();
        if (raw_input_tx_count > 0)
            return (1.0 - ($itor(compressed_output_tx_count) / $itor(raw_input_tx_count))) * 100.0;
        else
            return 0.0;
    endfunction
    
    // =========================================================================
    // Runtime Monitoring (Optional Debug Output)
    // =========================================================================
    
    // Uncomment for real-time monitoring during simulation
    /*
    always_ff @(posedge clock) begin
        if (!reset && valid_in) begin
            $display("[PERF] Time=%0t | Input TX: %0d | Output TX: %0d | Ratio: %0.2fx",
                     $time, raw_input_tx_count + 1, compressed_output_tx_count,
                     get_compression_ratio());
        end
    end
    */

endmodule
