// -----------------------------------------------------------------------------
// Module: bandwidth_perf_monitor
// -----------------------------------------------------------------------------
module bandwidth_perf_monitor #(
    parameter int DATA_BYTES = 6 
)(
    input logic clock,
    input logic reset,
    
    // Raw Input Interface 
    input logic valid_in,
    
    // Compressed Output Interface 
    input logic mem_valid,
    input logic mem_ready
);

    longint total_cycles;
    longint raw_input_tx_count;
    longint compressed_output_tx_count;

    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            total_cycles <= 0;
            raw_input_tx_count <= 0;
            compressed_output_tx_count <= 0;
        end else begin
            total_cycles <= total_cycles + 1;
            if (valid_in) begin
                raw_input_tx_count <= raw_input_tx_count + 1;
            end
            if (mem_valid && mem_ready) begin
                compressed_output_tx_count <= compressed_output_tx_count + 1;
            end
        end
    end

    function longint get_raw_bytes();
        return raw_input_tx_count * DATA_BYTES;
    endfunction

    function longint get_compressed_bytes();
        return compressed_output_tx_count * DATA_BYTES;
    endfunction

endmodule