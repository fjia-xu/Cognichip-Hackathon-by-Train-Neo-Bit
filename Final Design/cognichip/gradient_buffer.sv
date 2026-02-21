// FILE: gradient_buffer.sv
// Set-Associative Gradient Buffer
// - NUM_WAYS: number of ways per set (associativity), default 4
// - DEPTH: total entries = NUM_SETS * NUM_WAYS (must be divisible)
// - NUM_SETS = DEPTH / NUM_WAYS (compile-time computed)
// - SET_INDEX_WIDTH = $clog2(NUM_SETS)
//  Single cycle
// Storage Organization: [NUM_SETS][NUM_WAYS]
// - valid[set][way]: entry valid bit
// - tag[set][way]: full 32-bit address tag
// - accum[set][way]: accumulated gradient value (signed 32-bit)
// - upd_cnt[set][way]: update counter for force-flush (8-bit saturating)
// 
// Replacement Policy:
// - rr_ptr[set]: round-robin victim pointer per set
// - Increments on eviction, wraps at NUM_WAYS
// 
// Read Interface:
// - Input: rd_set_index (set to read)
// - Output: entire set's ways (rd_valid[NUM_WAYS], rd_tag[NUM_WAYS][32], ...)
// - Output: rd_rr_ptr (current victim pointer for this set)
// 
// Write Interface:
// - Input: wr_set_index, wr_way (specific location to write)
// - Input: wr_valid, wr_tag, wr_accum, wr_upd_cnt (data to write)
// - Input: wr_rr_ptr_incr (increment rr_ptr after write)

module gradient_buffer #(
    parameter int DEPTH = 256,
    parameter int NUM_WAYS = 4,//can become bigger
    parameter int MAX_UPDATES = 255
) (
    input  logic                     clk,
    input  logic                     rst_n,
    
    // Read interface (combinational) - returns entire set
    input  logic [$clog2(DEPTH/NUM_WAYS)-1:0] rd_set_index,
    output logic [NUM_WAYS-1:0]              rd_valid,
    output logic [31:0]                      rd_tag [NUM_WAYS],
    output logic signed [31:0]               rd_accum [NUM_WAYS],
    output logic [7:0]                       rd_upd_cnt [NUM_WAYS],
    output logic [$clog2(NUM_WAYS)-1:0]      rd_rr_ptr,
    
    // Write interface (synchronous) - writes to specific (set, way)
    input  logic                               wr_en,
    input  logic [$clog2(DEPTH/NUM_WAYS)-1:0]  wr_set_index,
    input  logic [$clog2(NUM_WAYS)-1:0]        wr_way,
    input  logic                               wr_valid,
    input  logic [31:0]                        wr_tag,
    input  logic signed [31:0]                 wr_accum,
    input  logic [7:0]                         wr_upd_cnt,
    input  logic                               wr_rr_ptr_incr
);

    // Compile-time parameters
    localparam int NUM_SETS = DEPTH / NUM_WAYS;
    localparam int SET_INDEX_WIDTH = $clog2(NUM_SETS);
    localparam int WAY_INDEX_WIDTH = $clog2(NUM_WAYS);
    
    // Compile-time check: DEPTH must be divisible by NUM_WAYS
    initial begin
        if (DEPTH % NUM_WAYS != 0) begin
            $fatal(1, "ERROR: DEPTH (%0d) must be divisible by NUM_WAYS (%0d)", DEPTH, NUM_WAYS);
        end
    end
    
    // Set-associative storage arrays [NUM_SETS][NUM_WAYS]
    // - valid: entry valid bit
    // - tag: full 32-bit address tag (no need to split tag/index, store complete address)
    // - accum: accumulated gradient value (signed 32-bit)
    // - upd_cnt: update counter for force-flush mechanism
    //   * Increments on each accumulate update
    //   * Saturates at MAX_UPDATES
    //   * Triggers force-flush when maxed out but below threshold
    logic                    valid [NUM_SETS][NUM_WAYS];
    logic [31:0]             tag [NUM_SETS][NUM_WAYS];
    logic signed [31:0]      accum [NUM_SETS][NUM_WAYS];
    logic [7:0]              upd_cnt [NUM_SETS][NUM_WAYS];
    
    // Round-robin victim pointer for each set
    // - rr_ptr[set]: points to next victim way in the set
    // - Increments on eviction (when wr_rr_ptr_incr asserted)
    // - Wraps around at NUM_WAYS for fair replacement
    logic [WAY_INDEX_WIDTH-1:0] rr_ptr [NUM_SETS];
    
    // Combinational read - return all ways of the requested set
    always_comb begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            rd_valid[w]   = valid[rd_set_index][w];
            rd_tag[w]     = tag[rd_set_index][w];
            rd_accum[w]   = accum[rd_set_index][w];
            rd_upd_cnt[w] = upd_cnt[rd_set_index][w];
        end
        rd_rr_ptr = rr_ptr[rd_set_index];
    end
    
    // Synchronous write and reset
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset: clear all valid bits, reset counters and rr_ptr
            for (int s = 0; s < NUM_SETS; s++) begin
                for (int w = 0; w < NUM_WAYS; w++) begin
                    valid[s][w]   <= 1'b0;
                    tag[s][w]     <= 32'b0;
                    accum[s][w]   <= 32'sb0;
                    upd_cnt[s][w] <= 8'b0;
                end
                rr_ptr[s] <= '0;
            end
        end else if (wr_en) begin
            // Write to specific (set, way) location
            valid[wr_set_index][wr_way]   <= wr_valid;
            tag[wr_set_index][wr_way]     <= wr_tag;
            accum[wr_set_index][wr_way]   <= wr_accum;
            upd_cnt[wr_set_index][wr_way] <= wr_upd_cnt;
            
            // Update round-robin pointer if requested
            // - Increment to next way (wraps around at NUM_WAYS)
            // - Only increment on eviction (all ways valid, need to replace victim)
            if (wr_rr_ptr_incr) begin
                if (rr_ptr[wr_set_index] == WAY_INDEX_WIDTH'(NUM_WAYS - 1)) begin
                    rr_ptr[wr_set_index] <= '0;
                end else begin
                    rr_ptr[wr_set_index] <= rr_ptr[wr_set_index] + 1'b1;
                end
            end
        end
    end

endmodule
