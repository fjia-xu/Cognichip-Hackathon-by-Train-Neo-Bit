`timescale 1ns/1ps

// ================================================================
// Stress Testbench for gradient_compressor_top (WCB+FIFO + L1 + tiny-miss drop)
// - No associative arrays, no queues, no foreach (lint/Verilator friendly)
// - Reference L1 model produces expected push sums per address
// - Observes DUT wb_push_fire via hierarchy: dut.u_accumulator.wb_push_*
// - After flush barrier + idle: expected_push == dut_push == dut_dram (per addr, mod 32b)
// ================================================================

module tb_template #(
  // DUT params
  parameter int ADDR_WIDTH      = 32,
  parameter int GRAD_WIDTH      = 16,
  parameter int INDEX_BITS      = 8,
  parameter int NUM_WAYS        = 4,
  parameter int MAX_UPDATES     = 255,
  parameter logic signed [31:0] THRESHOLD       = 32'sd50,
  parameter logic signed [31:0] SMALL_THRESHOLD = (THRESHOLD >>> 2),
  parameter int WCB_ENTRIES     = 16,
  parameter int FIFO_DEPTH      = 128,
  parameter int BURST_SIZE      = 8,

  // Test shape
  parameter int HOTSET_SIZE     = 64,
  parameter int LAYER_COUNT     = 24,

  // Scoreboard (fixed hash table size)
  parameter int SB_SIZE         = 32768,  // must be power-of-two for fast hash&mask

  // Defaults (can override via plusargs)
  parameter int DEFAULT_STEPS           = 2,
  parameter int DEFAULT_MICROBATCHES    = 3,
  parameter int DEFAULT_UPDATES_PER_MB  = 800
)();

  // --------------------
  // Clock / Reset
  // --------------------
  logic clock, reset;
  initial begin
    clock = 1'b0;
    forever #5 clock = ~clock;
  end

  task automatic do_reset();
    begin
      reset = 1'b1;
      repeat (8) @(posedge clock);
      reset = 1'b0;
      repeat (8) @(posedge clock);
    end
  endtask

  // --------------------
  // DUT I/O
  // --------------------
  logic                         in_valid;
  logic                         in_ready;
  logic [ADDR_WIDTH-1:0]        in_addr;
  logic signed [GRAD_WIDTH-1:0] in_grad;

  logic                         dram_valid;
  logic                         dram_ready;
  logic [31:0]                  dram_addr;
  logic signed [31:0]           dram_value;

  logic                         flush;
  logic                         idle;

  gradient_compressor_top #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .GRAD_WIDTH(GRAD_WIDTH),
    .INDEX_BITS(INDEX_BITS),
    .NUM_WAYS(NUM_WAYS),
    .MAX_UPDATES(MAX_UPDATES),
    .THRESHOLD(THRESHOLD),
    .SMALL_THRESHOLD(SMALL_THRESHOLD),
    .WCB_ENTRIES(WCB_ENTRIES),
    .FIFO_DEPTH(FIFO_DEPTH),
    .BURST_SIZE(BURST_SIZE)
  ) dut (
    .clock(clock),
    .reset(reset),
    .in_valid(in_valid),
    .in_ready(in_ready),
    .in_addr(in_addr),
    .in_grad(in_grad),
    .dram_valid(dram_valid),
    .dram_ready(dram_ready),
    .dram_addr(dram_addr),
    .dram_value(dram_value),
    .flush(flush),
    .idle(idle)
  );

  // --------------------
  // Hierarchical taps (L1->L2 push interface inside wrapper)
  // --------------------
  wire        wb_push_valid = dut.u_accumulator.wb_push_valid;
  wire        wb_push_ready = dut.u_accumulator.wb_push_ready;
  wire [31:0] wb_push_addr  = dut.u_accumulator.wb_push_addr;
  wire signed [31:0] wb_push_value = dut.u_accumulator.wb_push_value;

  wire wb_push_fire = wb_push_valid && wb_push_ready;
  wire dram_fire    = dram_valid && dram_ready;

  // --------------------
  // PRNG (LFSR)
  // --------------------
  logic [31:0] prng;

  function automatic [31:0] prng_next(input [31:0] s);
    prng_next = {s[30:0], s[31]^s[21]^s[1]^s[0]};
  endfunction

  always_ff @(posedge clock or posedge reset) begin
    if (reset) prng <= 32'h1ACE_B00C;
    else       prng <= prng_next(prng);
  end

  function automatic int unsigned urand_range(input int unsigned lo, input int unsigned hi);
    int unsigned span;
    begin
      span = (hi >= lo) ? (hi - lo + 1) : 1;
      urand_range = lo + (prng % span);
    end
  endfunction

  function automatic bit rand_bit();
    rand_bit = prng[0];
  endfunction

  // --------------------
  // Helper math
  // --------------------
  function automatic logic signed [31:0] sx16(input logic signed [15:0] x);
    sx16 = {{16{x[15]}}, x};
  endfunction

  function automatic logic signed [31:0] abs32(input logic signed [31:0] x);
    abs32 = (x < 0) ? -x : x;
  endfunction

  function automatic logic signed [15:0] clamp16(input int signed x);
    if (x >  32767) clamp16 =  32767;
    else if (x < -32768) clamp16 = -32768;
    else clamp16 = logic'(x[15:0]);
  endfunction

  function automatic logic signed [31:0] trunc32(input longint signed x);
    trunc32 = logic'($signed(x[31:0]));
  endfunction

  // --------------------
  // DRAM backpressure (bursty stalls)
  // --------------------
  int unsigned ready_pct;
  int unsigned stall_left;
  int unsigned stall_max;

  task automatic config_dram_ready(input int unsigned pct, input int unsigned stallmax);
    begin
      ready_pct = pct;
      stall_max = stallmax;
      stall_left = 0;
    end
  endtask

  always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
      dram_ready <= 1'b1;
      stall_left <= 0;
    end else begin
      if (stall_left != 0) begin
        dram_ready <= 1'b0;
        stall_left <= stall_left - 1;
      end else begin
        // occasionally start a long stall burst
        if ((prng % 1000) < 15) begin
          stall_left <= urand_range(20, stall_max);
          dram_ready <= 1'b0;
        end else begin
          dram_ready <= ((prng % 100) < ready_pct);
        end
      end
    end
  end

  // --------------------
  // Fixed-size hash-table scoreboard: addr -> longint sum
  // (No associative arrays)
  // --------------------
  logic        exp_valid [0:SB_SIZE-1];
  logic [31:0] exp_addr  [0:SB_SIZE-1];
  longint signed exp_sum [0:SB_SIZE-1];

  logic        dutp_valid [0:SB_SIZE-1];
  logic [31:0] dutp_addr  [0:SB_SIZE-1];
  longint signed dutp_sum [0:SB_SIZE-1];

  logic        dutd_valid [0:SB_SIZE-1];
  logic [31:0] dutd_addr  [0:SB_SIZE-1];
  longint signed dutd_sum [0:SB_SIZE-1];

  function automatic int unsigned sb_hash(input logic [31:0] a);
    // Knuth multiplicative hash, then mask
    logic [31:0] h;
    begin
      h = a * 32'h9E37_79B1;
      sb_hash = h & (SB_SIZE-1);
    end
  endfunction

  task automatic sb_clear_all();
    int i;
    begin
      for (i=0; i<SB_SIZE; i++) begin
        exp_valid[i]  = 1'b0; exp_addr[i]  = '0; exp_sum[i]  = 0;
        dutp_valid[i] = 1'b0; dutp_addr[i] = '0; dutp_sum[i] = 0;
        dutd_valid[i] = 1'b0; dutd_addr[i] = '0; dutd_sum[i] = 0;
      end
    end
  endtask

  task automatic sb_add_exp(input logic [31:0] a, input logic signed [31:0] v);
    int unsigned idx;
    int unsigned k;
    begin
      idx = sb_hash(a);
      for (k=0; k<SB_SIZE; k++) begin
        if (!exp_valid[idx]) begin
          exp_valid[idx] = 1'b1;
          exp_addr[idx]  = a;
          exp_sum[idx]   = $signed(v);
          return;
        end else if (exp_addr[idx] == a) begin
          exp_sum[idx] += $signed(v);
          return;
        end else begin
          idx = (idx + 1) & (SB_SIZE-1);
        end
      end
      $fatal(1, "EXP scoreboard full (increase SB_SIZE)");
    end
  endtask

  task automatic sb_add_dutp(input logic [31:0] a, input logic signed [31:0] v);
    int unsigned idx;
    int unsigned k;
    begin
      idx = sb_hash(a);
      for (k=0; k<SB_SIZE; k++) begin
        if (!dutp_valid[idx]) begin
          dutp_valid[idx] = 1'b1;
          dutp_addr[idx]  = a;
          dutp_sum[idx]   = $signed(v);
          return;
        end else if (dutp_addr[idx] == a) begin
          dutp_sum[idx] += $signed(v);
          return;
        end else begin
          idx = (idx + 1) & (SB_SIZE-1);
        end
      end
      $fatal(1, "DUT-PUSH scoreboard full (increase SB_SIZE)");
    end
  endtask

  task automatic sb_add_dutd(input logic [31:0] a, input logic signed [31:0] v);
    int unsigned idx;
    int unsigned k;
    begin
      idx = sb_hash(a);
      for (k=0; k<SB_SIZE; k++) begin
        if (!dutd_valid[idx]) begin
          dutd_valid[idx] = 1'b1;
          dutd_addr[idx]  = a;
          dutd_sum[idx]   = $signed(v);
          return;
        end else if (dutd_addr[idx] == a) begin
          dutd_sum[idx] += $signed(v);
          return;
        end else begin
          idx = (idx + 1) & (SB_SIZE-1);
        end
      end
      $fatal(1, "DUT-DRAM scoreboard full (increase SB_SIZE)");
    end
  endtask

  function automatic bit sb_find_dutp(input logic [31:0] a, output longint signed s);
    int unsigned idx;
    int unsigned k;
    begin
      idx = sb_hash(a);
      for (k=0; k<SB_SIZE; k++) begin
        if (!dutp_valid[idx]) begin
          s = 0;
          return 1'b0;
        end else if (dutp_addr[idx] == a) begin
          s = dutp_sum[idx];
          return 1'b1;
        end else idx = (idx + 1) & (SB_SIZE-1);
      end
      s = 0;
      return 1'b0;
    end
  endfunction

  function automatic bit sb_find_dutd(input logic [31:0] a, output longint signed s);
    int unsigned idx;
    int unsigned k;
    begin
      idx = sb_hash(a);
      for (k=0; k<SB_SIZE; k++) begin
        if (!dutd_valid[idx]) begin
          s = 0;
          return 1'b0;
        end else if (dutd_addr[idx] == a) begin
          s = dutd_sum[idx];
          return 1'b1;
        end else idx = (idx + 1) & (SB_SIZE-1);
      end
      s = 0;
      return 1'b0;
    end
  endfunction

  // --------------------
  // Reference L1 model (set-assoc + rr_ptr + upd_cnt + tiny-drop-on-miss)
  // --------------------
  localparam int NUM_SETS = (1 << INDEX_BITS);
  localparam int WAY_W    = (NUM_WAYS <= 1) ? 1 : $clog2(NUM_WAYS);

  bit                 ref_valid [0:NUM_SETS-1][0:NUM_WAYS-1];
  logic [31:0]        ref_tag   [0:NUM_SETS-1][0:NUM_WAYS-1];
  logic signed [31:0] ref_acc   [0:NUM_SETS-1][0:NUM_WAYS-1];
  int unsigned        ref_upd   [0:NUM_SETS-1][0:NUM_WAYS-1];
  int unsigned        ref_rrptr [0:NUM_SETS-1];

  task automatic ref_clear();
    int s,w;
    begin
      for (s=0; s<NUM_SETS; s++) begin
        ref_rrptr[s] = 0;
        for (w=0; w<NUM_WAYS; w++) begin
          ref_valid[s][w] = 1'b0;
          ref_tag[s][w]   = '0;
          ref_acc[s][w]   = '0;
          ref_upd[s][w]   = 0;
        end
      end
    end
  endtask

  task automatic ref_record_push(input logic [31:0] a, input logic signed [31:0] v);
    begin
      sb_add_exp(a, v);
    end
  endtask

  task automatic ref_process_input(input logic [31:0] a, input logic signed [15:0] g16);
    logic signed [31:0] g;
    logic signed [31:0] ag;
    int s,w;
    bit hit;
    int hitw;
    bit has_free;
    int freew;
    int vicw;
    logic signed [31:0] new_acc;
    int unsigned upd_next;
    begin
      g  = sx16(g16);
      ag = abs32(g);
      s  = a[INDEX_BITS-1:0];

      // direct trigger
      if (ag >= THRESHOLD) begin
        ref_record_push(a, g);
        return;
      end

      // hit scan (match DUT behavior: last match wins, no break)
      hit = 0; hitw = 0;
      for (w=0; w<NUM_WAYS; w++) begin
        if (ref_valid[s][w] && ref_tag[s][w] == a) begin
          hit = 1; hitw = w;
        end
      end

      if (hit) begin
        new_acc = ref_acc[s][hitw] + g;
        upd_next = (ref_upd[s][hitw] < MAX_UPDATES) ? (ref_upd[s][hitw] + 1) : MAX_UPDATES;

        if (abs32(new_acc) >= THRESHOLD || (upd_next == MAX_UPDATES)) begin
          ref_record_push(a, new_acc);
          ref_valid[s][hitw] = 1'b0;
          ref_acc[s][hitw]   = '0;
          ref_upd[s][hitw]   = 0;
        end else begin
          ref_acc[s][hitw] = new_acc;
          ref_upd[s][hitw] = upd_next;
        end
        return;
      end

      // miss: tiny drop only on miss
      if (ag < SMALL_THRESHOLD) begin
        return;
      end

      // allocate if free
      has_free = 0; freew = 0;
      for (w=0; w<NUM_WAYS; w++) begin
        if (!ref_valid[s][w]) begin
          has_free = 1; freew = w; break;
        end
      end

      if (has_free) begin
        ref_valid[s][freew] = 1'b1;
        ref_tag[s][freew]   = a;
        ref_acc[s][freew]   = g;
        ref_upd[s][freew]   = 1;
      end else begin
        // evict rr victim
        vicw = ref_rrptr[s] % NUM_WAYS;
        ref_record_push(ref_tag[s][vicw], ref_acc[s][vicw]);

        // overwrite
        ref_valid[s][vicw] = 1'b1;
        ref_tag[s][vicw]   = a;
        ref_acc[s][vicw]   = g;
        ref_upd[s][vicw]   = 1;

        ref_rrptr[s] = (ref_rrptr[s] + 1) % NUM_WAYS;
      end
    end
  endtask

  bit ref_flush_seen;
  task automatic ref_flush_drain();
    int s,w;
    begin
      for (s=0; s<NUM_SETS; s++) begin
        for (w=0; w<NUM_WAYS; w++) begin
          if (ref_valid[s][w]) begin
            ref_record_push(ref_tag[s][w], ref_acc[s][w]);
            ref_valid[s][w] = 1'b0;
            ref_acc[s][w]   = '0;
            ref_upd[s][w]   = 0;
          end
        end
      end
    end
  endtask

  // reference updates on accepted input & flush rising edge
  always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
      ref_flush_seen <= 1'b0;
    end else begin
      if (flush && !ref_flush_seen) begin
        ref_flush_seen <= 1'b1;
        ref_flush_drain();
      end else if (!flush) begin
        ref_flush_seen <= 1'b0;
      end

      if (in_valid && in_ready) begin
        ref_process_input({{(32-ADDR_WIDTH){1'b0}}, in_addr}, sx16(in_grad[15:0]));
      end
    end
  end

  // --------------------
  // Stall stability assertions (wb_push and dram)
  // --------------------
  logic wb_stall;
  logic [31:0] wb_hold_addr;
  logic signed [31:0] wb_hold_val;

  logic dram_stall;
  logic [31:0] dram_hold_addr;
  logic signed [31:0] dram_hold_val;

  always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
      wb_stall   <= 1'b0;
      dram_stall <= 1'b0;
    end else begin
      if (wb_push_valid && !wb_push_ready) begin
        if (!wb_stall) begin
          wb_stall <= 1'b1;
          wb_hold_addr <= wb_push_addr;
          wb_hold_val  <= wb_push_value;
        end else begin
          assert (wb_push_addr == wb_hold_addr) else $fatal(1, "WB addr changed while stalled");
          assert (wb_push_value == wb_hold_val) else $fatal(1, "WB value changed while stalled");
        end
      end else begin
        wb_stall <= 1'b0;
      end

      if (dram_valid && !dram_ready) begin
        if (!dram_stall) begin
          dram_stall <= 1'b1;
          dram_hold_addr <= dram_addr;
          dram_hold_val  <= dram_value;
        end else begin
          assert (dram_addr == dram_hold_addr) else $fatal(1, "DRAM addr changed while stalled");
          assert (dram_value == dram_hold_val) else $fatal(1, "DRAM value changed while stalled");
        end
      end else begin
        dram_stall <= 1'b0;
      end

      // observe DUT push/dram fires into scoreboards
      if (wb_push_fire) sb_add_dutp(wb_push_addr, wb_push_value);
      if (dram_fire)    sb_add_dutd(dram_addr, dram_value);
    end
  end

  // --------------------
  // Address tables (LLM-like)
  // --------------------
  logic [31:0] layer_base [0:LAYER_COUNT-1];
  logic [31:0] hot_addr   [0:HOTSET_SIZE-1];
  integer i;

  task automatic init_addr_tables();
    begin
      for (i=0; i<LAYER_COUNT; i++) begin
        layer_base[i] = 32'h1000_0000 + (i * 32'h0001_0000);
      end
      for (i=0; i<HOTSET_SIZE; i++) begin
        int layer;
        layer = i % LAYER_COUNT;
        hot_addr[i] = layer_base[layer] + (i * 4);
      end
    end
  endtask

  function automatic logic [ADDR_WIDTH-1:0] gen_addr_llm();
    int mode;
    int layer;
    logic [31:0] a;
    begin
      mode = prng % 100;
      if (mode < 80) begin
        a = hot_addr[urand_range(0, HOTSET_SIZE-1)];
        a = a + (urand_range(0, 63) * 4);
      end else begin
        layer = urand_range(0, LAYER_COUNT-1);
        a = layer_base[layer] + (urand_range(0, 8191) * 4);
      end
      gen_addr_llm = a[ADDR_WIDTH-1:0];
    end
  endfunction

  function automatic logic [ADDR_WIDTH-1:0] gen_addr_conflict_set(input int fixed_set);
    logic [31:0] hi;
    logic [31:0] a;
    begin
      hi = {prng[31:INDEX_BITS], {INDEX_BITS{1'b0}}};
      a  = hi | logic'(fixed_set[INDEX_BITS-1:0]);
      gen_addr_conflict_set = a[ADDR_WIDTH-1:0];
    end
  endfunction

  function automatic logic signed [GRAD_WIDTH-1:0] gen_grad_heavytail();
    int r;
    int mag;
    int sgn;
    int t2, t1;
    begin
      t2 = (SMALL_THRESHOLD < 1) ? 1 : SMALL_THRESHOLD;
      t1 = (THRESHOLD < t2+1) ? (t2+1) : THRESHOLD;

      r = prng % 1000;
      if (r < 850) begin
        mag = urand_range(0, t2-1);                 // tiny
      end else if (r < 990) begin
        mag = urand_range(t2, t1-1);                // small
      end else begin
        mag = urand_range(t1, t1*4 + 1);            // spike
      end

      sgn = rand_bit() ? 1 : -1;
      gen_grad_heavytail = clamp16(sgn * mag);
    end
  endfunction

  // --------------------
  // Handshake driver: send one update (holds stable until accepted)
  // --------------------
  task automatic send_one(input logic [ADDR_WIDTH-1:0] a, input logic signed [GRAD_WIDTH-1:0] g);
    begin
      in_valid <= 1'b1;
      in_addr  <= a;
      in_grad  <= g;

      // hold until accepted
      while (!(in_valid && in_ready)) begin
        @(posedge clock);
      end

      @(posedge clock); // advance one cycle after acceptance
      in_valid <= 1'b0;
    end
  endtask

  // --------------------
  // Flush barrier: hold flush high until idle (with timeout)
  // --------------------
  task automatic do_flush_barrier(input int unsigned timeout_cycles);
    int unsigned t;
    begin
      flush <= 1'b1;
      t = 0;
      while (!idle) begin
        @(posedge clock);
        t++;
        if (t > timeout_cycles) $fatal(1, "Timeout waiting for idle under flush");
      end
      // keep flush asserted a bit
      repeat (3) @(posedge clock);
      flush <= 1'b0;
      repeat (3) @(posedge clock);
    end
  endtask

  // --------------------
  // Scoreboard compare after final drain
  // --------------------
  task automatic compare_scoreboards();
    int idx;
    int mism;
    longint signed sp, sd;
    bit foundp, foundd;
    begin
      mism = 0;

      // exp -> dut_push/dut_dram
      for (idx=0; idx<SB_SIZE; idx++) begin
        if (exp_valid[idx]) begin
          foundp = sb_find_dutp(exp_addr[idx], sp);
          foundd = sb_find_dutd(exp_addr[idx], sd);

          if (!foundp) begin
            $display("[MISM] missing DUT push addr=%08x exp=%0d", exp_addr[idx], trunc32(exp_sum[idx]));
            mism++;
          end else if (trunc32(sp) !== trunc32(exp_sum[idx])) begin
            $display("[MISM] push sum addr=%08x exp=%0d dut=%0d", exp_addr[idx], trunc32(exp_sum[idx]), trunc32(sp));
            mism++;
          end

          if (!foundd) begin
            $display("[MISM] missing DRAM addr=%08x exp=%0d", exp_addr[idx], trunc32(exp_sum[idx]));
            mism++;
          end else if (trunc32(sd) !== trunc32(exp_sum[idx])) begin
            $display("[MISM] dram sum addr=%08x exp=%0d dram=%0d", exp_addr[idx], trunc32(exp_sum[idx]), trunc32(sd));
            mism++;
          end
        end
      end

      // detect extra dut_push entries
      for (idx=0; idx<SB_SIZE; idx++) begin
        if (dutp_valid[idx]) begin
          // find in exp
          // brute probe: lookup by trying sb_find on exp isn't implemented; so linear scan exp table
          // (SB_SIZE is moderate; ok for TB)
          int j;
          bit found;
          found = 0;
          for (j=0; j<SB_SIZE; j++) begin
            if (exp_valid[j] && exp_addr[j] == dutp_addr[idx]) begin found = 1; break; end
          end
          if (!found && (trunc32(dutp_sum[idx]) !== 0)) begin
            $display("[MISM] extra DUT push addr=%08x dut=%0d", dutp_addr[idx], trunc32(dutp_sum[idx]));
            mism++;
          end
        end
      end

      // detect extra dut_dram entries
      for (idx=0; idx<SB_SIZE; idx++) begin
        if (dutd_valid[idx]) begin
          int j;
          bit found;
          found = 0;
          for (j=0; j<SB_SIZE; j++) begin
            if (exp_valid[j] && exp_addr[j] == dutd_addr[idx]) begin found = 1; break; end
          end
          if (!found && (trunc32(dutd_sum[idx]) !== 0)) begin
            $display("[MISM] extra DRAM addr=%08x dram=%0d", dutd_addr[idx], trunc32(dutd_sum[idx]));
            mism++;
          end
        end
      end

      if (mism != 0) $fatal(1, "Scoreboard FAIL: %0d mismatches", mism);
      else $display("Scoreboard PASS: expected push == dut push == dut dram (per addr sum)");
    end
  endtask

  // --------------------
  // Tests
  // --------------------
  task automatic test_smoke();
    int n;
    begin
      $display("\n=== TEST: smoke ===");
      for (n=0; n<500; n++) begin
        send_one(gen_addr_llm(), gen_grad_heavytail());
      end
      do_flush_barrier(500000);
      compare_scoreboards();
    end
  endtask

  task automatic test_tiny_miss_drop_storm();
    int n;
    int fixed_set;
    begin
      $display("\n=== TEST: tiny-miss drop storm (should NOT allocate/evict) ===");
      fixed_set = urand_range(0, NUM_SETS-1);
      for (n=0; n<2000; n++) begin
        // force missy pattern by generating many unique addrs in same set
        logic [ADDR_WIDTH-1:0] a;
        a = gen_addr_conflict_set(fixed_set) + (n * 4);
        send_one(a, clamp16(1)); // tiny
      end
      do_flush_barrier(800000);
      compare_scoreboards();
    end
  endtask

  task automatic test_conflict_eviction_storm();
    int n;
    int fixed_set;
    begin
      $display("\n=== TEST: conflict eviction storm (same set) ===");
      fixed_set = urand_range(0, NUM_SETS-1);

      for (n=0; n<(NUM_WAYS*80); n++) begin
        logic [ADDR_WIDTH-1:0] a;
        logic signed [GRAD_WIDTH-1:0] g;
        int lo;
        int hi;
        int mag;
        a = gen_addr_conflict_set(fixed_set) + (n * 4);

        // ensure it's not tiny and not direct: [SMALL_THRESHOLD+1 .. THRESHOLD-1]
        lo = (SMALL_THRESHOLD < (THRESHOLD-2)) ? (SMALL_THRESHOLD + 1) : (THRESHOLD-2);
        hi = (THRESHOLD > (lo+1)) ? (THRESHOLD - 1) : (lo+1);
        mag = urand_range(lo, hi);
        g = clamp16((rand_bit()?1:-1) * mag);

        send_one(a, g);

        // sprinkle tiny misses that should be dropped
        if ((n % 7) == 0) begin
          send_one(gen_addr_conflict_set(fixed_set) + ((n+1000)*4), clamp16(1));
        end
      end

      do_flush_barrier(1200000);
      compare_scoreboards();
    end
  endtask

  task automatic test_direct_trigger_flood();
    int n;
    begin
      $display("\n=== TEST: direct-trigger flood + DRAM stalls ===");
      for (n=0; n<2000; n++) begin
        int mag = THRESHOLD + urand_range(0, THRESHOLD*3 + 1);
        send_one(gen_addr_llm(), clamp16((rand_bit()?1:-1) * mag));
      end
      do_flush_barrier(2000000);
      compare_scoreboards();
    end
  endtask

  task automatic test_max_updates_hammer();
    int n;
    logic [ADDR_WIDTH-1:0] a;
    begin
      $display("\n=== TEST: max-updates hammer (forces flush by upd_cnt) ===");
      a = gen_addr_llm();

      // allocate with non-tiny, non-direct
      send_one(a, clamp16(SMALL_THRESHOLD + 1));

      // then hammer tiny hits (still must count updates + flush at MAX_UPDATES)
      for (n=0; n<(MAX_UPDATES + 10); n++) begin
        send_one(a, clamp16(1));
      end

      do_flush_barrier(1200000);
      compare_scoreboards();
    end
  endtask

  task automatic test_training_like();
    int steps, mbs, upd;
    int s, mb, u;
    begin
      $display("\n=== TEST: training-like steps (flush barrier each step) ===");

      steps = DEFAULT_STEPS;
      mbs   = DEFAULT_MICROBATCHES;
      upd   = DEFAULT_UPDATES_PER_MB;

      void'($value$plusargs("STEPS=%d", steps));
      void'($value$plusargs("MBS=%d", mbs));
      void'($value$plusargs("UPD=%d", upd));

      for (s=0; s<steps; s++) begin
        for (mb=0; mb<mbs; mb++) begin
          for (u=0; u<upd; u++) begin
            send_one(gen_addr_llm(), gen_grad_heavytail());

            // occasional conflict burst
            if ((u % 257) == 0) begin
              int fixed_set = urand_range(0, NUM_SETS-1);
              send_one(gen_addr_conflict_set(fixed_set), clamp16(SMALL_THRESHOLD + 2));
            end
          end
        end
        do_flush_barrier(2500000);
      end

      compare_scoreboards();
    end
  endtask

  // --------------------
  // Main
  // --------------------
  initial begin
    int unsigned pct;
    int unsigned stmax;
    
    in_valid = 1'b0;
    in_addr  = '0;
    in_grad  = '0;
    flush    = 1'b0;

    init_addr_tables();
    sb_clear_all();
    ref_clear();

    // Configure DRAM ready (override via plusargs)
    pct = 70;
    stmax = 200;
    void'($value$plusargs("DRAM_READY_PCT=%d", pct));
    void'($value$plusargs("STALL_MAX=%d", stmax));
    config_dram_ready(pct, stmax);

    do_reset();
    sb_clear_all();
    ref_clear();

    // Run suite
    test_smoke();

    do_reset(); sb_clear_all(); ref_clear();
    test_tiny_miss_drop_storm();

    do_reset(); sb_clear_all(); ref_clear();
    test_conflict_eviction_storm();

    do_reset(); sb_clear_all(); ref_clear();
    test_direct_trigger_flood();

    do_reset(); sb_clear_all(); ref_clear();
    test_max_updates_hammer();

    do_reset(); sb_clear_all(); ref_clear();
    test_training_like();

    $display("\nALL TESTS PASSED");
    $finish(0); // fixes -Wfinish-num
  end

endmodule

// ================================================================
// Choose one top as simulation root
// ================================================================

// Small resources => hits eviction/backpressure/flush corner cases quickly
module tb_small_params;
  tb_template #(
    .INDEX_BITS(3),              // 8 sets
    .NUM_WAYS(2),
    .MAX_UPDATES(7),
    .THRESHOLD(32'sd20),
    .SMALL_THRESHOLD(32'sd5),
    .WCB_ENTRIES(4),
    .FIFO_DEPTH(8),
    .BURST_SIZE(4),
    .SB_SIZE(8192),
    .DEFAULT_STEPS(2),
    .DEFAULT_MICROBATCHES(2),
    .DEFAULT_UPDATES_PER_MB(400)
  ) t();
endmodule

// Default-ish
module tb_default_params;
  tb_template #(
    .INDEX_BITS(8),
    .NUM_WAYS(4),
    .MAX_UPDATES(255),
    .THRESHOLD(32'sd50),
    .SMALL_THRESHOLD(32'sd12),
    .WCB_ENTRIES(16),
    .FIFO_DEPTH(128),
    .BURST_SIZE(8),
    .SB_SIZE(32768),
    .DEFAULT_STEPS(2),
    .DEFAULT_MICROBATCHES(3),
    .DEFAULT_UPDATES_PER_MB(800)
  ) t();
endmodule
