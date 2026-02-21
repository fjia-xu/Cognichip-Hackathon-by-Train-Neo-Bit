// FILE: gradient_accumulator.sv
// Wrapper module for two-level gradient accumulator with FIFO writeback
// 
// Architecture:
// - L1: gradient_accumulator_top (set-associative accumulator)
// - L2: gradient_writeback_buffer (FIFO for write-combining)
// - L3: DRAM (external interface: dram_valid/dram_addr/dram_value/dram_ready)
//
// This wrapper:
// - Instantiates accumulator_top with set-associative support
// - Instantiates writeback FIFO buffer
// - Connects accumulator writebacks to FIFO push interface
// - Exposes DRAM interface for external memory controller

module gradient_accumulator #(
    parameter int DEPTH = 256,
    parameter int NUM_WAYS = 4,
    parameter logic signed [31:0] THRESHOLD = 32'sd1000,
    parameter int MAX_UPDATES = 255,
    parameter int FIFO_DEPTH = 32,
    parameter int BURST_SIZE = 16
) (
    input  logic                clk,
    input  logic                rst_n,
    
    // Input interface
    input  logic                in_valid,
    input  logic [31:0]         in_addr,
    input  logic signed [15:0]  in_grad,
    
    // DRAM interface (replaces out_* with buffered DRAM interface)
    output logic                dram_valid,
    output logic [31:0]         dram_addr,
    output logic signed [31:0]  dram_value,
    input  logic                dram_ready,
    
    // Debug signals for waveform analysis
    output logic                debug_wb_direct,
    output logic                debug_wb_accum_threshold,
    output logic                debug_wb_max_updates,
    output logic                debug_wb_eviction,
    output logic                debug_hit,
    output logic                debug_miss,
    output logic [5:0]          debug_fifo_count,
    output logic                debug_burst_ready,
    output logic                debug_fifo_full,
    output logic                debug_draining
);

    // Internal connection: accumulator_top -> writeback_buffer
    logic                wb_push_valid;
    logic [31:0]         wb_push_addr;
    logic signed [31:0]  wb_push_value;
    logic                wb_push_ready;
    
    // Internal debug signals
    logic                int_debug_wb_direct;
    logic                int_debug_wb_accum_threshold;
    logic                int_debug_wb_max_updates;
    logic                int_debug_wb_eviction;
    logic                int_debug_hit;
    logic                int_debug_miss;
    logic [5:0]          int_debug_fifo_count;
    logic                int_debug_burst_ready;
    logic                int_debug_fifo_full;
    logic                int_debug_draining;
    
    // Instantiate L1: Set-Associative Gradient Accumulator
    gradient_accumulator_top #(
        .DEPTH(DEPTH),
        .NUM_WAYS(NUM_WAYS),
        .THRESHOLD(THRESHOLD),
        .MAX_UPDATES(MAX_UPDATES)
    ) u_accumulator_top (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_addr(in_addr),
        .in_grad(in_grad),
        .wb_push_valid(wb_push_valid),
        .wb_push_addr(wb_push_addr),
        .wb_push_value(wb_push_value),
        .wb_push_ready(wb_push_ready),
        .debug_wb_direct(int_debug_wb_direct),
        .debug_wb_accum_threshold(int_debug_wb_accum_threshold),
        .debug_wb_max_updates(int_debug_wb_max_updates),
        .debug_wb_eviction(int_debug_wb_eviction),
        .debug_hit(int_debug_hit),
        .debug_miss(int_debug_miss)
    );
    
    // Instantiate L2: Writeback FIFO Buffer
    gradient_writeback_buffer #(
        .FIFO_DEPTH(FIFO_DEPTH),
        .BURST_SIZE(BURST_SIZE)
    ) u_writeback_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wb_push_valid(wb_push_valid),
        .wb_push_addr(wb_push_addr),
        .wb_push_value(wb_push_value),
        .wb_push_ready(wb_push_ready),
        .dram_valid(dram_valid),
        .dram_addr(dram_addr),
        .dram_value(dram_value),
        .dram_ready(dram_ready),
        .debug_fifo_count(int_debug_fifo_count),
        .debug_burst_ready(int_debug_burst_ready),
        .debug_fifo_full(int_debug_fifo_full),
        .debug_draining(int_debug_draining)
    );
    
    // Connect internal debug signals to outputs
    assign debug_wb_direct = int_debug_wb_direct;
    assign debug_wb_accum_threshold = int_debug_wb_accum_threshold;
    assign debug_wb_max_updates = int_debug_wb_max_updates;
    assign debug_wb_eviction = int_debug_wb_eviction;
    assign debug_hit = int_debug_hit;
    assign debug_miss = int_debug_miss;
    assign debug_fifo_count = int_debug_fifo_count;
    assign debug_burst_ready = int_debug_burst_ready;
    assign debug_fifo_full = int_debug_fifo_full;
    assign debug_draining = int_debug_draining;

endmodule
