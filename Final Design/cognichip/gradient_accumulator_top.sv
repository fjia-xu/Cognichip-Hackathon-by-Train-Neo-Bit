// FILE: gradient_accumulator_top.sv
// Set-Associative Gradient Accumulator with Two-Level Writeback
// 
// Features:
// - Set-associative L1 cache with NUM_WAYS ways per set
// - Direct trigger: |grad| >= THRESHOLD -> push to L2 FIFO (no L1 allocation)
// - Accumulation trigger: |new_accum| >= THRESHOLD -> push to L2 FIFO, clear L1 entry
// - MAX_UPDATES force-flush: upd_cnt reaches MAX_UPDATES -> push to L2 FIFO, clear entry
// - Eviction: replace victim in full set -> push old entry to L2 FIFO
// - Backpressure: stall when wb_push_ready=0 (no data loss, no invalid state)

module gradient_accumulator_top #(
    parameter int DEPTH = 256,
    parameter int NUM_WAYS = 4,
    parameter logic signed [31:0] THRESHOLD = 32'sd1000,
    parameter int MAX_UPDATES = 255
) (
    input  logic                clk,
    input  logic                rst_n,
    
    // Input interface
    input  logic                in_valid,
    input  logic [31:0]         in_addr,
    input  logic signed [15:0]  in_grad,
    
    // L2 FIFO push interface (replaces direct DRAM output)
    output logic                wb_push_valid,
    output logic [31:0]         wb_push_addr,
    output logic signed [31:0]  wb_push_value,
    input  logic                wb_push_ready,
    
    // Debug signals for waveform analysis
    output logic                debug_wb_direct,
    output logic                debug_wb_accum_threshold,
    output logic                debug_wb_max_updates,
    output logic                debug_wb_eviction,
    output logic                debug_hit,
    output logic                debug_miss
);

    // Compile-time parameters
    localparam int NUM_SETS = DEPTH / NUM_WAYS;
    localparam int SET_INDEX_WIDTH = $clog2(NUM_SETS);
    localparam int WAY_INDEX_WIDTH = $clog2(NUM_WAYS);
    
    // Extract set index from address
    function automatic logic [SET_INDEX_WIDTH-1:0] get_set_index(input logic [31:0] addr);
        return addr[SET_INDEX_WIDTH-1:0];
    endfunction
    
    // ========================================================================
    // STAGE 1: Streamer - Sign-extend gradient and check direct trigger
    // ========================================================================
    
    logic                     req_valid;
    logic [31:0]              req_addr;
    logic [SET_INDEX_WIDTH-1:0] req_set_index;
    logic signed [31:0]       req_grad_ext;
    logic                     req_direct_trigger;
    
    // Streamer logic (inlined)
    logic signed [31:0] abs_grad;
    logic signed [31:0] abs_threshold;
    logic signed [31:0] in_grad_ext_for_abs;
    
    // CRITICAL FIX: Explicitly sign-extend BEFORE taking absolute value
    assign in_grad_ext_for_abs = {{16{in_grad[15]}}, in_grad};
    assign abs_grad = (in_grad_ext_for_abs < 32'sd0) ? -in_grad_ext_for_abs : in_grad_ext_for_abs;
    assign abs_threshold = (THRESHOLD < 32'sd0) ? -THRESHOLD : THRESHOLD;
    assign req_direct_trigger = (abs_grad >= abs_threshold);
    
    // Sign-extend gradient from 16-bit to 32-bit
    assign req_grad_ext = {{16{in_grad[15]}}, in_grad};
    assign req_addr = in_addr;
    assign req_set_index = get_set_index(in_addr);
    assign req_valid = in_valid;
    
    // ========================================================================
    // STAGE 2: Buffer Read - Get entire set (all ways)
    // ========================================================================
    
    logic [NUM_WAYS-1:0]              entry_valid;
    logic [31:0]                      entry_tag [NUM_WAYS];
    logic signed [31:0]               entry_accum [NUM_WAYS];
    logic [7:0]                       entry_upd_cnt [NUM_WAYS];
    logic [WAY_INDEX_WIDTH-1:0]       entry_rr_ptr;
    
    // Buffer write interface
    logic                               wr_en;
    logic [SET_INDEX_WIDTH-1:0]         wr_set_index;
    logic [WAY_INDEX_WIDTH-1:0]         wr_way;
    logic                               wr_valid;
    logic [31:0]                        wr_tag;
    logic signed [31:0]                 wr_accum;
    logic [7:0]                         wr_upd_cnt;
    logic                               wr_rr_ptr_incr;
    
    // Instantiate set-associative buffer
    gradient_buffer #(
        .DEPTH(DEPTH),
        .NUM_WAYS(NUM_WAYS),
        .MAX_UPDATES(MAX_UPDATES)
    ) u_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .rd_set_index(req_set_index),
        .rd_valid(entry_valid),
        .rd_tag(entry_tag),
        .rd_accum(entry_accum),
        .rd_upd_cnt(entry_upd_cnt),
        .rd_rr_ptr(entry_rr_ptr),
        .wr_en(wr_en),
        .wr_set_index(wr_set_index),
        .wr_way(wr_way),
        .wr_valid(wr_valid),
        .wr_tag(wr_tag),
        .wr_accum(wr_accum),
        .wr_upd_cnt(wr_upd_cnt),
        .wr_rr_ptr_incr(wr_rr_ptr_incr)
    );
    
    // ========================================================================
    // STAGE 3: Tag Match and Way Selection
    // ========================================================================
    
    logic [NUM_WAYS-1:0] way_match;
    logic                hit;
    logic [WAY_INDEX_WIDTH-1:0] hit_way;
    
    // Tag comparison for all ways
    always_comb begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            way_match[w] = entry_valid[w] && (entry_tag[w] == req_addr);
        end
    end
    
    // Hit detection and way selection (priority encoder)
    always_comb begin
        hit = 1'b0;
        hit_way = '0;
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (way_match[w]) begin
                hit = 1'b1;
                hit_way = WAY_INDEX_WIDTH'(w);
            end
        end
    end
    
    // Find empty way (priority encoder)
    logic                empty_found;
    logic [WAY_INDEX_WIDTH-1:0] empty_way;
    
    always_comb begin
        empty_found = 1'b0;
        empty_way = '0;
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (!entry_valid[w]) begin
                empty_found = 1'b1;
                empty_way = WAY_INDEX_WIDTH'(w);
            end
        end
    end
    
    // Check if set is full
    logic set_full;
    assign set_full = &entry_valid;  // All ways valid
    
    // Victim selection for eviction (round-robin)
    logic [WAY_INDEX_WIDTH-1:0] victim_way;
    assign victim_way = entry_rr_ptr;
    
    // ========================================================================
    // STAGE 4: Accumulation Logic
    // ========================================================================
    
    logic signed [31:0] new_accum;
    logic signed [31:0] abs_new_accum;
    logic signed [31:0] new_abs_threshold;
    logic               accum_threshold_trigger;
    logic [7:0]         new_upd_cnt;
    logic               max_updates_trigger;
    
    // Compute new accumulated value (for hit case)
    assign new_accum = entry_accum[hit_way] + req_grad_ext;
    assign abs_new_accum = (new_accum < 0) ? -new_accum : new_accum;
    assign new_abs_threshold = (THRESHOLD < 0) ? -THRESHOLD : THRESHOLD;
    assign accum_threshold_trigger = (abs_new_accum >= new_abs_threshold);
    
    // Compute new update count (saturating increment)
    assign new_upd_cnt = (entry_upd_cnt[hit_way] >= MAX_UPDATES) ? 
                         8'(MAX_UPDATES) : 
                         entry_upd_cnt[hit_way] + 8'd1;
    
    // Check if update count reached MAX_UPDATES
    assign max_updates_trigger = (new_upd_cnt >= MAX_UPDATES);
    
    // ========================================================================
    // STAGE 5: Writeback Decision and L1 Update Logic
    // ========================================================================
    
    // Writeback conditions
    logic wb_direct;
    logic wb_accum_threshold;
    logic wb_max_updates;
    logic wb_eviction;
    logic wb_needed;
    
    assign wb_direct = req_valid && req_direct_trigger;
    assign wb_accum_threshold = req_valid && !req_direct_trigger && hit && accum_threshold_trigger;
    assign wb_max_updates = req_valid && !req_direct_trigger && hit && !accum_threshold_trigger && max_updates_trigger;
    assign wb_eviction = req_valid && !req_direct_trigger && !hit && set_full;
    assign wb_needed = wb_direct || wb_accum_threshold || wb_max_updates || wb_eviction;
    
    // Stall condition: need to push but FIFO not ready
    logic stall;
    assign stall = wb_needed && !wb_push_ready;
    
    // Writeback output logic (combinational)
    always_comb begin
        wb_push_valid = 1'b0;
        wb_push_addr  = 32'b0;
        wb_push_value = 32'sb0;
        
        if (wb_needed && !stall) begin
            wb_push_valid = 1'b1;
            
            if (wb_direct) begin
                // Direct trigger: push gradient to L2 FIFO
                wb_push_addr  = req_addr;
                wb_push_value = req_grad_ext;
            end else if (wb_accum_threshold) begin
                // Accumulation threshold: push new_accum to L2 FIFO
                wb_push_addr  = req_addr;
                wb_push_value = new_accum;
            end else if (wb_max_updates) begin
                // MAX_UPDATES force-flush: push new_accum to L2 FIFO
                wb_push_addr  = req_addr;
                wb_push_value = new_accum;
            end else if (wb_eviction) begin
                // Eviction: push victim's old data to L2 FIFO
                wb_push_addr  = entry_tag[victim_way];
                wb_push_value = entry_accum[victim_way];
            end
        end
    end
    
    // L1 buffer write logic (combinational)
    always_comb begin
        wr_en           = 1'b0;
        wr_set_index    = req_set_index;
        wr_way          = '0;
        wr_valid        = 1'b0;
        wr_tag          = 32'b0;
        wr_accum        = 32'sb0;
        wr_upd_cnt      = 8'b0;
        wr_rr_ptr_incr  = 1'b0;
        
        if (req_valid && !stall) begin
            if (req_direct_trigger) begin
                // Direct trigger: no L1 allocation, no write
                wr_en = 1'b0;
                
            end else if (hit) begin
                // Hit case
                if (accum_threshold_trigger || max_updates_trigger) begin
                    // Clear entry: set valid=0, accum=0, upd_cnt=0
                    wr_en      = 1'b1;
                    wr_way     = hit_way;
                    wr_valid   = 1'b0;
                    wr_tag     = entry_tag[hit_way];
                    wr_accum   = 32'sb0;
                    wr_upd_cnt = 8'b0;
                    wr_rr_ptr_incr = 1'b0;
                end else begin
                    // Update entry: accumulate and increment upd_cnt
                    wr_en      = 1'b1;
                    wr_way     = hit_way;
                    wr_valid   = 1'b1;
                    wr_tag     = entry_tag[hit_way];
                    wr_accum   = new_accum;
                    wr_upd_cnt = new_upd_cnt;
                    wr_rr_ptr_incr = 1'b0;
                end
                
            end else begin
                // Miss case
                if (empty_found) begin
                    // Allocate in empty way
                    wr_en      = 1'b1;
                    wr_way     = empty_way;
                    wr_valid   = 1'b1;
                    wr_tag     = req_addr;
                    wr_accum   = req_grad_ext;
                    wr_upd_cnt = 8'd1;  // First update
                    wr_rr_ptr_incr = 1'b0;
                end else begin
                    // Evict victim and allocate
                    wr_en      = 1'b1;
                    wr_way     = victim_way;
                    wr_valid   = 1'b1;
                    wr_tag     = req_addr;
                    wr_accum   = req_grad_ext;
                    wr_upd_cnt = 8'd1;  // First update
                    wr_rr_ptr_incr = 1'b1;  // Advance round-robin pointer
                end
            end
        end
    end
    
    // ========================================================================
    // Debug Signal Outputs
    // ========================================================================
    
    assign debug_wb_direct = wb_direct && !stall;
    assign debug_wb_accum_threshold = wb_accum_threshold && !stall;
    assign debug_wb_max_updates = wb_max_updates && !stall;
    assign debug_wb_eviction = wb_eviction && !stall;
    
    // Sequential logic for debug_hit and debug_miss (delayed by 1 cycle)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debug_hit  <= 1'b0;
            debug_miss <= 1'b0;
        end else begin
            debug_hit  <= req_valid && !req_direct_trigger && hit;
            debug_miss <= req_valid && !req_direct_trigger && !hit;
        end
    end

endmodule
