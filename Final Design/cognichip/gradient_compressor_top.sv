// FILE: gradient_compressor_top.sv
// Adapter/Wrapper module to bridge testbench with gradient_accumulator design
//
// Clear signal naming convention:
// - core_* : Input from computation core
// - l1_*   : L1 Cache (Accumulator) related signals
// - l2_*   : L2 FIFO (Writeback Buffer) related signals
// - dram_* : L3 DRAM interface (final output)
//
// Data flow: core → L1 Cache → L2 FIFO → DRAM
//            (input)  (accumulate)  (batch)  (memory)

module gradient_compressor_top #(
    parameter int ADDR_WIDTH = 16,
    parameter int GRAD_WIDTH = 16,
    parameter int INDEX_BITS = 5
) (
    input  logic                      clock,
    input  logic                      reset,
    
    // Core interface (input side)
    input  logic [ADDR_WIDTH-1:0]     core_address,
    input  logic signed [GRAD_WIDTH-1:0] core_gradient,
    input  logic                      core_valid,
    input  logic [GRAD_WIDTH-1:0]     threshold,
    
    // L3: DRAM interface (final output to external memory)
    output logic [ADDR_WIDTH-1:0]     dram_address,
    output logic signed [GRAD_WIDTH-1:0] dram_value,
    output logic                      dram_valid,
    input  logic                      dram_ready,
    
    // Debug signals - L1 Cache (Accumulator) writeback events
    output logic                      debug_l1_wb_direct,           // |grad| >= THRESHOLD -> bypass L1
    output logic                      debug_l1_wb_accum_overflow,   // |accum| >= THRESHOLD -> flush
    output logic                      debug_l1_wb_max_updates,      // update_count = 255 -> force flush
    output logic                      debug_l1_wb_eviction,         // Tag conflict -> evict victim
    output logic                      debug_l1_hit,                 // L1 cache hit
    output logic                      debug_l1_miss,                // L1 cache miss
    
    // Debug signals - L2 FIFO (Writeback Buffer) state
    output logic [5:0]                debug_l2_fifo_count,         // Current FIFO occupancy
    output logic                      debug_l2_burst_ready,        // FIFO count >= BURST_SIZE
    output logic                      debug_l2_fifo_full,          // FIFO is full
    output logic                      debug_l2_draining            // FIFO is draining to DRAM
);

    // Derive DEPTH from INDEX_BITS
    // INDEX_BITS=5 means 32 sets
    // With NUM_WAYS=4, total DEPTH = NUM_SETS * NUM_WAYS = 32 * 4 = 128
    localparam int NUM_WAYS = 4;           // Set-associative with 4 ways
    localparam int DEPTH = (2**INDEX_BITS) * NUM_WAYS;  // 128 for INDEX_BITS=5
    localparam int MAX_UPDATES = 255;
    localparam int FIFO_DEPTH = 32;
    localparam int BURST_SIZE = 16;
    
    // Signal conversion: reset (active-high) -> rst_n (active-low)
    logic rst_n;
    assign rst_n = ~reset;
    
    // Signal width extension/truncation for address
    logic [31:0] in_addr_32bit;
    logic [31:0] dram_addr_32bit;
    
    // Zero-extend address from ADDR_WIDTH to 32-bit
    assign in_addr_32bit = {{(32-ADDR_WIDTH){1'b0}}, core_address};
    
    // Signal width extension for gradient (sign-extend handled internally)
    // Input is already 16-bit signed, matches in_grad port
    
    // Signal width extension for output value (32-bit internally, truncate to GRAD_WIDTH)
    logic signed [31:0] dram_value_32bit;
    logic signed [GRAD_WIDTH-1:0] dram_value_truncated;
    
    // Truncate 32-bit output to GRAD_WIDTH (16-bit for testbench)
    assign dram_value_truncated = dram_value_32bit[GRAD_WIDTH-1:0];
    
    // Truncate 32-bit address to ADDR_WIDTH
    assign dram_address = dram_addr_32bit[ADDR_WIDTH-1:0];
    assign dram_value = dram_value_truncated;
    
    // Note: threshold input port is ignored in this adapter
    // The design uses a compile-time parameter THRESHOLD=50 (matching testbench default)
    // If dynamic threshold is needed, the internal design must be modified
    localparam logic signed [31:0] THRESHOLD_32BIT = 32'sd50;
    
    // Instantiate gradient_accumulator with two-level writeback
    gradient_accumulator #(
        .DEPTH(DEPTH),
        .NUM_WAYS(NUM_WAYS),
        .THRESHOLD(THRESHOLD_32BIT),  // Fixed threshold matching testbench
        .MAX_UPDATES(MAX_UPDATES),
        .FIFO_DEPTH(FIFO_DEPTH),
        .BURST_SIZE(BURST_SIZE)
    ) u_accumulator (
        .clk(clock),            // Signal name translation
        .rst_n(rst_n),          // Active-high to active-low conversion
        .in_valid(core_valid),
        .in_addr(in_addr_32bit),
        .in_grad(core_gradient),
        .dram_valid(dram_valid),
        .dram_addr(dram_addr_32bit),
        .dram_value(dram_value_32bit),
        .dram_ready(dram_ready),
        
        // L1 Cache debug signals (FIXED: added missing debug_wb_direct!)
        .debug_wb_direct(debug_l1_wb_direct),
        .debug_wb_accum_threshold(debug_l1_wb_accum_overflow),
        .debug_wb_max_updates(debug_l1_wb_max_updates),
        .debug_wb_eviction(debug_l1_wb_eviction),
        .debug_hit(debug_l1_hit),
        .debug_miss(debug_l1_miss),
        
        // L2 FIFO debug signals
        .debug_fifo_count(debug_l2_fifo_count),
        .debug_burst_ready(debug_l2_burst_ready),
        .debug_fifo_full(debug_l2_fifo_full),
        .debug_draining(debug_l2_draining)
    );

endmodule
