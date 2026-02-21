// =============================================================================
// Module: gradient_system_top
// Description: 
//   Top-level integration module for the gradient noise filtering and caching
//   system. Instantiates and connects four sub-modules:
//   1. dynamic_threshold_controller - Computes adaptive threshold via EMA
//   2. gradient_noise_filter - Routes gradients based on magnitude
//   3. direct_mapped_cache - Accumulates low-magnitude gradients
//   4. memory_write_arbiter - Arbitrates memory writes
//
// Architecture:
//   Gradients → [Threshold Controller] → Dynamic Threshold
//            ↓                                 ↓
//   Gradients → [Noise Filter] ← Dynamic Threshold
//            ↓                ↓
//      Path A (high)    Path B (low)
//            ↓                ↓
//            |          [Cache] ← Dynamic Threshold
//            |                ↓
//            |          Evictions
//            ↓                ↓
//         [Arbiter] ← Path A & Evictions
//            ↓
//      Memory Writes
// =============================================================================

module gradient_system_top #(
    parameter int ADDR_WIDTH = 32,  // Address bus width
    parameter int GRAD_WIDTH = 16   // Gradient data width
) (
    // Clock and Reset
    input  logic                        clock,
    input  logic                        reset,
    
    // Input Interface
    input  logic [ADDR_WIDTH-1:0]       Address_In,
    input  logic signed [GRAD_WIDTH-1:0] Gradient_In,
    input  logic                        valid_in,
    
    // Memory Interface
    input  logic                        mem_ready,
    output logic [ADDR_WIDTH-1:0]       mem_address,
    output logic signed [GRAD_WIDTH-1:0] mem_value,
    output logic                        mem_valid
);

    // =========================================================================
    // Internal Wiring: Dynamic Threshold Signal
    // =========================================================================
    
    // Dynamic threshold computed by the threshold controller
    logic [GRAD_WIDTH-1:0] current_dynamic_threshold;
    
    // =========================================================================
    // Internal Wiring: Path A Signals (Filter → Arbiter)
    // =========================================================================
    
    // High-magnitude gradients that bypass the cache
    logic [ADDR_WIDTH-1:0]       path_a_address;
    logic signed [GRAD_WIDTH-1:0] path_a_gradient;
    logic                        path_a_valid;
    
    // =========================================================================
    // Internal Wiring: Path B Signals (Filter → Cache)
    // =========================================================================
    
    // Low-magnitude gradients sent to the cache for accumulation
    logic [ADDR_WIDTH-1:0]       path_b_address;
    logic signed [GRAD_WIDTH-1:0] path_b_gradient;
    logic                        path_b_valid;
    
    // =========================================================================
    // Internal Wiring: Cache Eviction Signals (Cache → Arbiter)
    // =========================================================================
    
    // Evicted accumulated gradients from the cache
    logic [ADDR_WIDTH-1:0]       cache_evict_address;
    logic signed [GRAD_WIDTH-1:0] cache_evict_value;
    logic                        cache_evict_valid;
    
    // =========================================================================
    // Module Instantiation: Dynamic Threshold Controller
    // =========================================================================
    
    dynamic_threshold_controller #(
        .GRAD_WIDTH  (GRAD_WIDTH),
        .SHIFT_BITS  (4)           // EMA weight alpha = 1/16
    ) u_threshold_controller (
        .clock             (clock),
        .reset             (reset),
        .valid_in          (valid_in),
        .Gradient_In       (Gradient_In),
        .Dynamic_Threshold (current_dynamic_threshold)
    );
    
    // =========================================================================
    // Module Instantiation: Gradient Noise Filter
    // =========================================================================
    
    gradient_noise_filter #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .GRAD_WIDTH (GRAD_WIDTH)
    ) u_noise_filter (
        .clock       (clock),
        .reset       (reset),
        .Address_In  (Address_In),
        .Gradient_In (Gradient_In),
        .valid_in    (valid_in),
        .Threshold   (current_dynamic_threshold),
        // Path A outputs (high magnitude)
        .Address_A   (path_a_address),
        .Gradient_A  (path_a_gradient),
        .Valid_A     (path_a_valid),
        // Path B outputs (low magnitude)
        .Address_B   (path_b_address),
        .Gradient_B  (path_b_gradient),
        .Valid_B     (path_b_valid)
    );
    
    // =========================================================================
    // Module Instantiation: Direct-Mapped Cache
    // =========================================================================
    
    direct_mapped_cache #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .GRAD_WIDTH (GRAD_WIDTH),
        .INDEX_BITS (8)            // 256 cache entries (2^8)
    ) u_cache (
        .clock         (clock),
        .reset         (reset),
        .Address_In    (path_b_address),
        .Gradient_In   (path_b_gradient),
        .valid_in      (path_b_valid),
        .Threshold     (current_dynamic_threshold),
        // Eviction outputs
        .evict_valid   (cache_evict_valid),
        .evict_address (cache_evict_address),
        .evict_value   (cache_evict_value)
    );
    
    // =========================================================================
    // Module Instantiation: Memory Write Arbiter
    // =========================================================================
    
    memory_write_arbiter #(
        .ADDR_WIDTH  (ADDR_WIDTH),
        .VALUE_WIDTH (GRAD_WIDTH)
    ) u_arbiter (
        .clock           (clock),
        .reset           (reset),
        // Path A inputs (direct from filter)
        .path_a_address  (path_a_address),
        .path_a_value    (path_a_gradient),
        .path_a_valid    (path_a_valid),
        // Eviction path inputs (from cache)
        .evict_address   (cache_evict_address),
        .evict_value     (cache_evict_value),
        .evict_valid     (cache_evict_valid),
        // Memory interface
        .mem_ready       (mem_ready),
        .mem_address     (mem_address),
        .mem_value       (mem_value),
        .mem_valid       (mem_valid)
    );

endmodule
