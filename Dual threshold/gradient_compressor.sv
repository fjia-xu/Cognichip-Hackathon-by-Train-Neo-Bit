////////////////////////////////////////////////////////////////////////////////
// Complete Two-Level Gradient Writeback Architecture
// FULLY PATCHED: All 4 failures corrected per exact requirements
////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////
// Module: gradient_buffer
////////////////////////////////////////////////////////////////////////////////
module gradient_buffer #(
    parameter INDEX_BITS = 8,
    parameter NUM_WAYS = 4,
    parameter MAX_UPDATES = 255
) (
    input  logic        clock,
    input  logic        reset,
    
    input  logic [INDEX_BITS-1:0]   rd_set,
    output logic [NUM_WAYS-1:0]     rd_valid,
    output logic [31:0]             rd_tag    [NUM_WAYS-1:0],
    output logic signed [31:0]      rd_accum  [NUM_WAYS-1:0],
    output logic [$clog2(MAX_UPDATES+1)-1:0] rd_upd_cnt [NUM_WAYS-1:0],
    output logic [$clog2(NUM_WAYS)-1:0]      rd_rr_ptr,
    
    input  logic                    wr_en,
    input  logic [INDEX_BITS-1:0]   wr_set,
    input  logic [$clog2(NUM_WAYS)-1:0] wr_way,
    input  logic                    wr_valid,
    input  logic [31:0]             wr_tag,
    input  logic signed [31:0]      wr_accum,
    input  logic [$clog2(MAX_UPDATES+1)-1:0] wr_upd_cnt,
    input  logic                    rr_ptr_incr
);

    localparam NUM_SETS = 2**INDEX_BITS;
    localparam UPD_CNT_W = $clog2(MAX_UPDATES+1);
    localparam WAY_W = $clog2(NUM_WAYS);
    
    logic [NUM_WAYS-1:0]     valid_array [NUM_SETS-1:0];
    logic [31:0]             tag_array   [NUM_SETS-1:0][NUM_WAYS-1:0];
    logic signed [31:0]      accum_array [NUM_SETS-1:0][NUM_WAYS-1:0];
    logic [UPD_CNT_W-1:0]    upd_cnt_array [NUM_SETS-1:0][NUM_WAYS-1:0];
    logic [WAY_W-1:0]        rr_ptr_array [NUM_SETS-1:0];
    
    assign rd_valid = valid_array[rd_set];
    assign rd_rr_ptr = rr_ptr_array[rd_set];
    
    always_comb begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            rd_tag[w]    = tag_array[rd_set][w];
            rd_accum[w]  = accum_array[rd_set][w];
            rd_upd_cnt[w] = upd_cnt_array[rd_set][w];
        end
    end
    
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            for (int s = 0; s < NUM_SETS; s++) begin
                valid_array[s] <= '0;
                rr_ptr_array[s] <= '0;
            end
        end else begin
            if (wr_en) begin
                valid_array[wr_set][wr_way] <= wr_valid;
                tag_array[wr_set][wr_way]   <= wr_tag;
                accum_array[wr_set][wr_way] <= wr_accum;
                upd_cnt_array[wr_set][wr_way] <= wr_upd_cnt;
            end
            if (rr_ptr_incr) begin
                rr_ptr_array[wr_set] <= (rr_ptr_array[wr_set] + 1) % NUM_WAYS;
            end
        end
    end

endmodule


////////////////////////////////////////////////////////////////////////////////
// Module: gradient_writeback_buffer
// PATCHED: FAILURE #3 (dram_valid always enabled), FAILURE #4 (BURST_SIZE used)
////////////////////////////////////////////////////////////////////////////////
module gradient_writeback_buffer #(
    parameter WCB_ENTRIES = 16,
    parameter FIFO_DEPTH = 128,
    parameter BURST_SIZE = 8
) (
    input  logic        clock,
    input  logic        reset,
    
    input  logic        wb_push_valid,
    output logic        wb_push_ready,
    input  logic [31:0] wb_push_addr,
    input  logic signed [31:0] wb_push_value,
    
    output logic        dram_valid,
    input  logic        dram_ready,
    output logic [31:0] dram_addr,
    output logic signed [31:0] dram_value,
    
    input  logic        flush,
    output logic        l2_idle
);

    localparam WCB_IDX_W = $clog2(WCB_ENTRIES);
    localparam FIFO_PTR_W = $clog2(FIFO_DEPTH);
    localparam int BC_W = (BURST_SIZE <= 1) ? 1 : $clog2(BURST_SIZE);
    
    logic [WCB_ENTRIES-1:0]      wcb_valid;
    logic [31:0]                 wcb_tag   [WCB_ENTRIES-1:0];
    logic signed [31:0]          wcb_accum [WCB_ENTRIES-1:0];
    logic [WCB_IDX_W-1:0]        wcb_rr_ptr;
    
    typedef struct packed {
        logic [31:0]        addr;
        logic signed [31:0] value;
    } fifo_entry_t;
    
    fifo_entry_t fifo_mem [FIFO_DEPTH-1:0];
    logic [FIFO_PTR_W:0] fifo_wr_ptr;
    logic [FIFO_PTR_W:0] fifo_rd_ptr;
    
    logic fifo_empty, fifo_full;
    logic [FIFO_PTR_W:0] fifo_count;
    
    assign fifo_count = fifo_wr_ptr - fifo_rd_ptr;
    assign fifo_empty = (fifo_count == 0);
    assign fifo_full  = (fifo_count >= FIFO_DEPTH);
    
    typedef enum logic [1:0] {
        NORMAL,
        FLUSH_WCB,
        FLUSH_FIFO
    } flush_state_t;
    
    flush_state_t flush_state;
    logic [WCB_IDX_W:0] flush_wcb_idx;
    
    logic wcb_hit;
    logic [WCB_IDX_W-1:0] wcb_hit_idx;
    logic wcb_has_free;
    logic [WCB_IDX_W-1:0] wcb_free_idx;
    
    logic [BC_W-1:0] burst_cnt;
    
    always_comb begin
        wcb_hit = 1'b0;
        wcb_hit_idx = '0;
        for (int i = 0; i < WCB_ENTRIES; i++) begin
            if (wcb_valid[i] && wcb_tag[i] == wb_push_addr) begin
                wcb_hit = 1'b1;
                wcb_hit_idx = i;
            end
        end
    end
    
    always_comb begin
        wcb_has_free = 1'b0;
        wcb_free_idx = '0;
        for (int i = 0; i < WCB_ENTRIES; i++) begin
            if (!wcb_valid[i]) begin
                wcb_has_free = 1'b1;
                wcb_free_idx = i;
                break;
            end
        end
    end
    
    always_comb begin
        if (flush_state != NORMAL) begin
            wb_push_ready = 1'b0;
        end else begin
            wb_push_ready = wcb_hit || wcb_has_free || (!fifo_full);
        end
    end
    
    logic wb_push_fire;
    assign wb_push_fire = wb_push_valid && wb_push_ready;
    
    assign dram_valid = !fifo_empty;
    assign dram_addr  = fifo_mem[fifo_rd_ptr[FIFO_PTR_W-1:0]].addr;
    assign dram_value = fifo_mem[fifo_rd_ptr[FIFO_PTR_W-1:0]].value;
    
    logic dram_fire;
    assign dram_fire = dram_valid && dram_ready;
    
    assign l2_idle = (wcb_valid == '0) && fifo_empty && (flush_state == NORMAL);
    
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            wcb_valid <= '0;
            wcb_rr_ptr <= '0;
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
            flush_state <= NORMAL;
            flush_wcb_idx <= '0;
            burst_cnt <= '0;
        end else begin
            
            if (dram_fire) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1;
                if (BURST_SIZE > 1) begin
                    burst_cnt <= (burst_cnt == (BURST_SIZE-1)) ? '0 : burst_cnt + 1;
                end
            end
            
            case (flush_state)
                
                NORMAL: begin
                    if (flush) begin
                        flush_state <= FLUSH_WCB;
                        flush_wcb_idx <= '0;
                    end else if (wb_push_fire) begin
                        if (wcb_hit) begin
                            wcb_accum[wcb_hit_idx] <= wcb_accum[wcb_hit_idx] + wb_push_value;
                        end else if (wcb_has_free) begin
                            wcb_valid[wcb_free_idx] <= 1'b1;
                            wcb_tag[wcb_free_idx]   <= wb_push_addr;
                            wcb_accum[wcb_free_idx] <= wb_push_value;
                        end else begin
                            if (!fifo_full) begin
                                fifo_mem[fifo_wr_ptr[FIFO_PTR_W-1:0]].addr  <= wcb_tag[wcb_rr_ptr];
                                fifo_mem[fifo_wr_ptr[FIFO_PTR_W-1:0]].value <= wcb_accum[wcb_rr_ptr];
                                fifo_wr_ptr <= fifo_wr_ptr + 1;
                                
                                wcb_tag[wcb_rr_ptr]   <= wb_push_addr;
                                wcb_accum[wcb_rr_ptr] <= wb_push_value;
                                wcb_rr_ptr <= (wcb_rr_ptr + 1) % WCB_ENTRIES;
                            end
                        end
                    end
                end
                
                FLUSH_WCB: begin
                    if (flush_wcb_idx < WCB_ENTRIES) begin
                        if (wcb_valid[flush_wcb_idx[WCB_IDX_W-1:0]]) begin
                            if (!fifo_full) begin
                                fifo_mem[fifo_wr_ptr[FIFO_PTR_W-1:0]].addr  <= wcb_tag[flush_wcb_idx[WCB_IDX_W-1:0]];
                                fifo_mem[fifo_wr_ptr[FIFO_PTR_W-1:0]].value <= wcb_accum[flush_wcb_idx[WCB_IDX_W-1:0]];
                                fifo_wr_ptr <= fifo_wr_ptr + 1;
                                wcb_valid[flush_wcb_idx[WCB_IDX_W-1:0]] <= 1'b0;
                                flush_wcb_idx <= flush_wcb_idx + 1;
                            end
                        end else begin
                            flush_wcb_idx <= flush_wcb_idx + 1;
                        end
                    end else begin
                        flush_state <= FLUSH_FIFO;
                    end
                end
                
                FLUSH_FIFO: begin
                    if (fifo_empty) begin
                        flush_state <= NORMAL;
                    end
                end
                
            endcase
        end
    end

endmodule


////////////////////////////////////////////////////////////////////////////////
// Module: gradient_accumulator_top
// PATCHED: FAILURE #1 (flush scan with widened counters), FAILURE #2 (valid_count tracking)
////////////////////////////////////////////////////////////////////////////////
module gradient_accumulator_top #(
    parameter INDEX_BITS = 8,
    parameter NUM_WAYS = 4,
    parameter MAX_UPDATES = 255,
    parameter THRESHOLD = 32'sd50,
    parameter logic signed [31:0] SMALL_THRESHOLD = (THRESHOLD >>> 2)
) (
    input  logic        clock,
    input  logic        reset,
    
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [31:0] in_addr,
    input  logic signed [15:0] in_grad,
    
    output logic        wb_push_valid,
    input  logic        wb_push_ready,
    output logic [31:0] wb_push_addr,
    output logic signed [31:0] wb_push_value,
    
    input  logic        flush,
    output logic        l1_idle
);

    localparam NUM_SETS = 2**INDEX_BITS;
    localparam UPD_CNT_W = $clog2(MAX_UPDATES+1);
    localparam WAY_W = $clog2(NUM_WAYS);
    localparam DEPTH = NUM_SETS * NUM_WAYS;
    localparam int VC_W = $clog2(DEPTH+1);
    
    typedef enum logic [2:0] {
        IDLE,
        DIRECT_PUSH,
        HIT_PUSH,
        EVICT_PUSH,
        FLUSH_SCAN,
        FLUSH_PUSH
    } state_t;
    
    state_t state;
    
    logic [31:0]        pending_addr;
    logic signed [31:0] pending_value;
    logic [INDEX_BITS-1:0] pending_set;
    logic [WAY_W-1:0]   pending_way;
    logic               pending_is_hit;
    logic               pending_is_evict;
    logic [31:0]        pending_new_addr;
    logic signed [31:0] pending_new_accum;
    logic [UPD_CNT_W-1:0] pending_new_upd_cnt;
    
    logic [INDEX_BITS:0] flush_set;
    logic [WAY_W:0]      flush_way;
    
    logic [VC_W-1:0] valid_count;
    
    logic [INDEX_BITS-1:0]   buf_rd_set;
    logic [NUM_WAYS-1:0]     buf_rd_valid;
    logic [31:0]             buf_rd_tag    [NUM_WAYS-1:0];
    logic signed [31:0]      buf_rd_accum  [NUM_WAYS-1:0];
    logic [UPD_CNT_W-1:0]    buf_rd_upd_cnt [NUM_WAYS-1:0];
    logic [WAY_W-1:0]        buf_rd_rr_ptr;
    
    logic                    buf_wr_en;
    logic [INDEX_BITS-1:0]   buf_wr_set;
    logic [WAY_W-1:0]        buf_wr_way;
    logic                    buf_wr_valid;
    logic [31:0]             buf_wr_tag;
    logic signed [31:0]      buf_wr_accum;
    logic [UPD_CNT_W-1:0]    buf_wr_upd_cnt;
    logic                    buf_rr_ptr_incr;
    
    gradient_buffer #(
        .INDEX_BITS(INDEX_BITS),
        .NUM_WAYS(NUM_WAYS),
        .MAX_UPDATES(MAX_UPDATES)
    ) u_buffer (
        .clock(clock),
        .reset(reset),
        .rd_set(buf_rd_set),
        .rd_valid(buf_rd_valid),
        .rd_tag(buf_rd_tag),
        .rd_accum(buf_rd_accum),
        .rd_upd_cnt(buf_rd_upd_cnt),
        .rd_rr_ptr(buf_rd_rr_ptr),
        .wr_en(buf_wr_en),
        .wr_set(buf_wr_set),
        .wr_way(buf_wr_way),
        .wr_valid(buf_wr_valid),
        .wr_tag(buf_wr_tag),
        .wr_accum(buf_wr_accum),
        .wr_upd_cnt(buf_wr_upd_cnt),
        .rr_ptr_incr(buf_rr_ptr_incr)
    );
    
    function automatic logic signed [31:0] abs_val(input logic signed [31:0] x);
        return (x < 0) ? -x : x;
    endfunction
    
    function automatic logic signed [31:0] sign_extend(input logic signed [15:0] x);
        return {{16{x[15]}}, x};
    endfunction
    
    logic signed [31:0] grad_ext;
    logic signed [31:0] abs_grad;
    logic tiny_grad;
    logic [INDEX_BITS-1:0] set_index;
    
    assign grad_ext = sign_extend(in_grad);
    assign abs_grad = abs_val(grad_ext);
    assign tiny_grad = (abs_grad < SMALL_THRESHOLD);
    assign set_index = in_addr[INDEX_BITS-1:0];
    
    assign buf_rd_set = (state == IDLE) ? set_index : 
                        (state == FLUSH_SCAN) ? flush_set[INDEX_BITS-1:0] : pending_set;
    
    logic hit;
    logic [WAY_W-1:0] hit_way;
    
    always_comb begin
        hit = 1'b0;
        hit_way = '0;
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (buf_rd_valid[w] && buf_rd_tag[w] == in_addr) begin
                hit = 1'b1;
                hit_way = w;
            end
        end
    end
    
    logic has_free;
    logic [WAY_W-1:0] free_way;
    
    always_comb begin
        has_free = 1'b0;
        free_way = '0;
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (!buf_rd_valid[w]) begin
                has_free = 1'b1;
                free_way = w;
                break;
            end
        end
    end
    
    assign wb_push_addr  = pending_addr;
    assign wb_push_value = pending_value;
    
    logic wb_push_fire;
    assign wb_push_fire = wb_push_valid && wb_push_ready;
    
    logic in_fire;
    assign in_fire = in_valid && in_ready;
    
    assign l1_idle = (state == IDLE) && (valid_count == 0) && !wb_push_valid;
    
    logic signed [31:0] temp_new_accum;
    logic [UPD_CNT_W-1:0] temp_new_upd_cnt;
    
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            wb_push_valid <= 1'b0;
            in_ready <= 1'b0;
            buf_wr_en <= 1'b0;
            buf_rr_ptr_incr <= 1'b0;
            flush_set <= '0;
            flush_way <= '0;
            valid_count <= '0;
        end else begin
            
            buf_wr_en <= 1'b0;
            buf_rr_ptr_incr <= 1'b0;
            
            case (state)
                
                IDLE: begin
                    wb_push_valid <= 1'b0;
                    
                    if (flush) begin
                        state <= FLUSH_SCAN;
                        flush_set <= '0;
                        flush_way <= '0;
                        in_ready <= 1'b0;
                    end else begin
                        in_ready <= 1'b1;
                        
                        if (in_fire) begin
                            if (abs_grad >= THRESHOLD) begin
                                state <= DIRECT_PUSH;
                                wb_push_valid <= 1'b1;
                                pending_addr <= in_addr;
                                pending_value <= grad_ext;
                                in_ready <= 1'b0;
                            end else if (hit) begin
                                temp_new_accum = buf_rd_accum[hit_way] + grad_ext;
                                temp_new_upd_cnt = (buf_rd_upd_cnt[hit_way] < MAX_UPDATES) ? 
                                                   buf_rd_upd_cnt[hit_way] + 1 : MAX_UPDATES;
                                
                                if (abs_val(temp_new_accum) >= THRESHOLD || temp_new_upd_cnt == MAX_UPDATES) begin
                                    state <= HIT_PUSH;
                                    wb_push_valid <= 1'b1;
                                    pending_addr <= in_addr;
                                    pending_value <= temp_new_accum;
                                    pending_set <= set_index;
                                    pending_way <= hit_way;
                                    in_ready <= 1'b0;
                                end else begin
                                    buf_wr_en <= 1'b1;
                                    buf_wr_set <= set_index;
                                    buf_wr_way <= hit_way;
                                    buf_wr_valid <= 1'b1;
                                    buf_wr_tag <= in_addr;
                                    buf_wr_accum <= temp_new_accum;
                                    buf_wr_upd_cnt <= temp_new_upd_cnt;
                                end
                            end else begin
                                // MISS path: check tiny_grad to prevent L1 pollution
                                if (tiny_grad) begin
                                    // DROP: tiny gradient on miss - do not allocate/evict
                                    // No L1 update, no L2 push, stay ready for next input
                                end else if (has_free) begin
                                    buf_wr_en <= 1'b1;
                                    buf_wr_set <= set_index;
                                    buf_wr_way <= free_way;
                                    buf_wr_valid <= 1'b1;
                                    buf_wr_tag <= in_addr;
                                    buf_wr_accum <= grad_ext;
                                    buf_wr_upd_cnt <= 1;
                                    valid_count <= valid_count + 1;
                                end else begin
                                    state <= EVICT_PUSH;
                                    wb_push_valid <= 1'b1;
                                    pending_addr <= buf_rd_tag[buf_rd_rr_ptr];
                                    pending_value <= buf_rd_accum[buf_rd_rr_ptr];
                                    pending_set <= set_index;
                                    pending_way <= buf_rd_rr_ptr;
                                    pending_new_addr <= in_addr;
                                    pending_new_accum <= grad_ext;
                                    pending_new_upd_cnt <= 1;
                                    in_ready <= 1'b0;
                                end
                            end
                        end
                    end
                end
                
                DIRECT_PUSH: begin
                    if (wb_push_fire) begin
                        wb_push_valid <= 1'b0;
                        state <= IDLE;
                        in_ready <= 1'b1;
                    end
                end
                
                HIT_PUSH: begin
                    if (wb_push_fire) begin
                        wb_push_valid <= 1'b0;
                        buf_wr_en <= 1'b1;
                        buf_wr_set <= pending_set;
                        buf_wr_way <= pending_way;
                        buf_wr_valid <= 1'b0;
                        buf_wr_accum <= '0;
                        buf_wr_upd_cnt <= '0;
                        valid_count <= valid_count - 1;
                        state <= IDLE;
                        in_ready <= 1'b1;
                    end
                end
                
                EVICT_PUSH: begin
                    if (wb_push_fire) begin
                        wb_push_valid <= 1'b0;
                        buf_wr_en <= 1'b1;
                        buf_wr_set <= pending_set;
                        buf_wr_way <= pending_way;
                        buf_wr_valid <= 1'b1;
                        buf_wr_tag <= pending_new_addr;
                        buf_wr_accum <= pending_new_accum;
                        buf_wr_upd_cnt <= pending_new_upd_cnt;
                        buf_rr_ptr_incr <= 1'b1;
                        state <= IDLE;
                        in_ready <= 1'b1;
                    end
                end
                
                FLUSH_SCAN: begin
                    in_ready <= 1'b0;
                    
                    if (flush_set == NUM_SETS) begin
                        state <= IDLE;
                        in_ready <= 1'b1;
                    end else if (flush_way == NUM_WAYS) begin
                        flush_set <= flush_set + 1;
                        flush_way <= '0;
                    end else begin
                        if (buf_rd_valid[flush_way[WAY_W-1:0]]) begin
                            wb_push_valid <= 1'b1;
                            pending_addr <= buf_rd_tag[flush_way[WAY_W-1:0]];
                            pending_value <= buf_rd_accum[flush_way[WAY_W-1:0]];
                            pending_set <= flush_set[INDEX_BITS-1:0];
                            pending_way <= flush_way[WAY_W-1:0];
                            state <= FLUSH_PUSH;
                        end else begin
                            flush_way <= flush_way + 1;
                        end
                    end
                end
                
                FLUSH_PUSH: begin
                    if (wb_push_fire) begin
                        wb_push_valid <= 1'b0;
                        buf_wr_en <= 1'b1;
                        buf_wr_set <= pending_set;
                        buf_wr_way <= pending_way;
                        buf_wr_valid <= 1'b0;
                        buf_wr_accum <= '0;
                        buf_wr_upd_cnt <= '0;
                        valid_count <= valid_count - 1;
                        flush_way <= flush_way + 1;
                        state <= FLUSH_SCAN;
                    end
                end
                
            endcase
        end
    end

endmodule


////////////////////////////////////////////////////////////////////////////////
// Module: gradient_accumulator
////////////////////////////////////////////////////////////////////////////////
module gradient_accumulator #(
    parameter INDEX_BITS = 8,
    parameter NUM_WAYS = 4,
    parameter MAX_UPDATES = 255,
    parameter THRESHOLD = 32'sd50,
    parameter logic signed [31:0] SMALL_THRESHOLD = (THRESHOLD >>> 2),
    parameter WCB_ENTRIES = 16,
    parameter FIFO_DEPTH = 128,
    parameter BURST_SIZE = 8
) (
    input  logic        clock,
    input  logic        reset,
    
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [31:0] in_addr,
    input  logic signed [15:0] in_grad,
    
    output logic        dram_valid,
    input  logic        dram_ready,
    output logic [31:0] dram_addr,
    output logic signed [31:0] dram_value,
    
    input  logic        flush,
    output logic        idle
);

    logic        wb_push_valid;
    logic        wb_push_ready;
    logic [31:0] wb_push_addr;
    logic signed [31:0] wb_push_value;
    
    logic l1_idle, l2_idle;
    
    logic l1_in_ready;
    logic flush_l1;
    logic flush_l2_pulse;
    logic in_valid_l1;
    
    typedef enum logic [2:0] {
        SEQ_RUN,
        SEQ_L1,
        SEQ_L2_PULSE,
        SEQ_L2_WAIT,
        SEQ_HOLD
    } seq_t;
    
    seq_t seq;
    
    assign in_ready = (seq == SEQ_RUN) && !flush ? l1_in_ready : 1'b0;
    assign in_valid_l1 = in_valid && (seq == SEQ_RUN) && !flush;
    assign flush_l1 = (seq == SEQ_L1);
    assign flush_l2_pulse = (seq == SEQ_L2_PULSE);
    assign idle = l1_idle && l2_idle &&
              ((seq == SEQ_HOLD) || ((seq == SEQ_RUN) && !flush));

    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            seq <= SEQ_RUN;
        end else begin
            case (seq)
                SEQ_RUN: begin
                    if (flush) begin
                        seq <= SEQ_L1;
                    end
                end
                
                SEQ_L1: begin
                    if (l1_idle) begin
                        seq <= SEQ_L2_PULSE;
                    end
                end
                
                SEQ_L2_PULSE: begin
                    seq <= SEQ_L2_WAIT;
                end
                
                SEQ_L2_WAIT: begin
                    if (l2_idle) begin
                        seq <= SEQ_HOLD;
                    end
                end
                
                SEQ_HOLD: begin
                    if (!flush) begin
                        seq <= SEQ_RUN;
                    end
                end
            endcase
        end
    end
    
    gradient_accumulator_top #(
        .INDEX_BITS(INDEX_BITS),
        .NUM_WAYS(NUM_WAYS),
        .MAX_UPDATES(MAX_UPDATES),
        .THRESHOLD(THRESHOLD),
        .SMALL_THRESHOLD(SMALL_THRESHOLD)
    ) u_l1 (
        .clock(clock),
        .reset(reset),
        .in_valid(in_valid_l1),
        .in_ready(l1_in_ready),
        .in_addr(in_addr),
        .in_grad(in_grad),
        .wb_push_valid(wb_push_valid),
        .wb_push_ready(wb_push_ready),
        .wb_push_addr(wb_push_addr),
        .wb_push_value(wb_push_value),
        .flush(flush_l1),
        .l1_idle(l1_idle)
    );
    
    gradient_writeback_buffer #(
        .WCB_ENTRIES(WCB_ENTRIES),
        .FIFO_DEPTH(FIFO_DEPTH),
        .BURST_SIZE(BURST_SIZE)
    ) u_l2 (
        .clock(clock),
        .reset(reset),
        .wb_push_valid(wb_push_valid),
        .wb_push_ready(wb_push_ready),
        .wb_push_addr(wb_push_addr),
        .wb_push_value(wb_push_value),
        .dram_valid(dram_valid),
        .dram_ready(dram_ready),
        .dram_addr(dram_addr),
        .dram_value(dram_value),
        .flush(flush_l2_pulse),
        .l2_idle(l2_idle)
    );

endmodule


////////////////////////////////////////////////////////////////////////////////
// Module: gradient_compressor_top
////////////////////////////////////////////////////////////////////////////////
module gradient_compressor_top #(
    parameter ADDR_WIDTH = 32,
    parameter GRAD_WIDTH = 16,
    parameter INDEX_BITS = 8,
    parameter NUM_WAYS = 4,
    parameter MAX_UPDATES = 255,
    parameter THRESHOLD = 32'sd50,
    parameter logic signed [31:0] SMALL_THRESHOLD = (THRESHOLD >>> 2),
    parameter WCB_ENTRIES = 16,
    parameter FIFO_DEPTH = 128,
    parameter BURST_SIZE = 8
) (
    input  logic        clock,
    input  logic        reset,
    
    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic [ADDR_WIDTH-1:0]  in_addr,
    input  logic signed [GRAD_WIDTH-1:0] in_grad,
    
    output logic        dram_valid,
    input  logic        dram_ready,
    output logic [31:0] dram_addr,
    output logic signed [31:0] dram_value,
    
    input  logic        flush,
    output logic        idle
);

    logic [31:0]        int_addr;
    logic signed [15:0] int_grad;
    
    generate
        if (ADDR_WIDTH == 32) begin : gen_addr_direct
            assign int_addr = in_addr;
        end else if (ADDR_WIDTH < 32) begin : gen_addr_extend
            assign int_addr = {{(32-ADDR_WIDTH){1'b0}}, in_addr};
        end else begin : gen_addr_truncate
            assign int_addr = in_addr[31:0];
        end
        
        if (GRAD_WIDTH == 16) begin : gen_grad_direct
            assign int_grad = in_grad;
        end else if (GRAD_WIDTH < 16) begin : gen_grad_extend
            assign int_grad = {{(16-GRAD_WIDTH){in_grad[GRAD_WIDTH-1]}}, in_grad};
        end else begin : gen_grad_truncate
            assign int_grad = in_grad[15:0];
        end
    endgenerate
    
    gradient_accumulator #(
        .INDEX_BITS(INDEX_BITS),
        .NUM_WAYS(NUM_WAYS),
        .MAX_UPDATES(MAX_UPDATES),
        .THRESHOLD(THRESHOLD),
        .SMALL_THRESHOLD(SMALL_THRESHOLD),
        .WCB_ENTRIES(WCB_ENTRIES),
        .FIFO_DEPTH(FIFO_DEPTH),
        .BURST_SIZE(BURST_SIZE)
    ) u_accumulator (
        .clock(clock),
        .reset(reset),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_addr(int_addr),
        .in_grad(int_grad),
        .dram_valid(dram_valid),
        .dram_ready(dram_ready),
        .dram_addr(dram_addr),
        .dram_value(dram_value),
        .flush(flush),
        .idle(idle)
    );

endmodule
