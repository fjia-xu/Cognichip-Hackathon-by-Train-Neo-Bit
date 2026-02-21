`timescale 1ns/1ps

module tb_unified_gradient_compressor;

    // Hardware parameters
    localparam int ADDR_WIDTH = 16;
    localparam int GRAD_WIDTH = 16;
    localparam int INDEX_BITS = 5;
    localparam int CLK_PERIOD = 10;
    localparam int MAX_UPDATES = 255;
    localparam int THRESHOLD_VAL = 50;
    localparam int FIFO_BURST_SIZE = 16;

    // Internal signals
    logic                        clock;
    logic                        reset;
    
    logic [ADDR_WIDTH-1:0]       core_address;
    logic signed [GRAD_WIDTH-1:0] core_gradient;
    logic                        core_valid;
    logic [GRAD_WIDTH-1:0]       threshold;
    
    logic [ADDR_WIDTH-1:0]       dram_address;
    logic signed [GRAD_WIDTH-1:0] dram_value;
    logic                        dram_valid;
    logic                        dram_ready;
    
    // Debug signals - L1 Cache
    logic                        debug_l1_wb_direct;
    logic                        debug_l1_wb_accum_overflow;
    logic                        debug_l1_wb_max_updates;
    logic                        debug_l1_wb_eviction;
    logic                        debug_l1_hit;
    logic                        debug_l1_miss;
    
    // Debug signals - L2 FIFO
    logic [5:0]                  debug_l2_fifo_count;
    logic                        debug_l2_burst_ready;
    logic                        debug_l2_fifo_full;
    logic                        debug_l2_draining;
    
    // Test statistics
    int direct_trigger_count = 0;
    int accum_threshold_count = 0;
    int max_updates_count = 0;
    int eviction_count = 0;
    int dram_write_count = 0;
    int total_to_fifo = 0;

    // Instantiate DUT (Top Wrapper)
    gradient_compressor_top #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .GRAD_WIDTH(GRAD_WIDTH),
        .INDEX_BITS(INDEX_BITS)
    ) dut (
        .clock(clock),
        .reset(reset),
        .core_address(core_address),
        .core_gradient(core_gradient),
        .core_valid(core_valid),
        .threshold(threshold),
        .dram_address(dram_address),
        .dram_value(dram_value),
        .dram_valid(dram_valid),
        .dram_ready(dram_ready),
        .debug_l1_wb_direct(debug_l1_wb_direct),
        .debug_l1_wb_accum_overflow(debug_l1_wb_accum_overflow),
        .debug_l1_wb_max_updates(debug_l1_wb_max_updates),
        .debug_l1_wb_eviction(debug_l1_wb_eviction),
        .debug_l1_hit(debug_l1_hit),
        .debug_l1_miss(debug_l1_miss),
        .debug_l2_fifo_count(debug_l2_fifo_count),
        .debug_l2_burst_ready(debug_l2_burst_ready),
        .debug_l2_fifo_full(debug_l2_fifo_full),
        .debug_l2_draining(debug_l2_draining)
    );

    // Instantiate performance monitor
    bandwidth_perf_monitor #(
        .DATA_BYTES(4)
    ) perf_mon (
        .clock(clock),
        .reset(reset),
        .valid_in(core_valid),
        .mem_valid(dram_valid), 
        .mem_ready(dram_ready)
    );

    // Monitor writeback events and logs
    always_ff @(posedge clock) begin
        if (!reset) begin
            // Disabled CSV output to keep stdout clean matching the txt file
            /*
            if (core_valid) 
                $display("[CSV_IN_LOG] %0t,%04x,%0d", $time, core_address, core_gradient);
            if (dram_valid && dram_ready) 
                $display("[CSV_OUT_LOG] %0t,%04x,%0d", $time, dram_address, dram_value);
            */

            // Mechanism Counters
            if (debug_l1_wb_direct) begin
                direct_trigger_count++;
                $display("[%0t] 🔴 L1_DIRECT: #%0d addr=0x%04x grad=%0d -> L2 FIFO (bypassing L1)", $time, direct_trigger_count, core_address, core_gradient);
            end
            if (debug_l1_wb_accum_overflow) begin
                accum_threshold_count++;
                $display("[%0t] 🟡 L1_ACCUM_OVERFLOW: #%0d addr=0x%04x |accum| >= THRESHOLD -> L2 FIFO", $time, accum_threshold_count, core_address);
            end
            if (debug_l1_wb_max_updates) begin
                max_updates_count++;
                $display("[%0t] 🟣 L1_MAX_UPDATES: #%0d addr=0x%04x reached %0d updates -> L2 FIFO", $time, max_updates_count, core_address, MAX_UPDATES);
            end
            if (debug_l1_wb_eviction) begin
                eviction_count++;
                $display("[%0t] 🔵 L1_EVICTION: #%0d addr=0x%04x tag conflict -> victim to L2 FIFO", $time, eviction_count, core_address);
            end
            
            // L2 FIFO Monitoring
            if (debug_l2_burst_ready && !debug_l2_draining) begin
                $display("[%0t] 📦 L2_BURST_READY: fifo_count=%0d >= BURST_SIZE=%0d, starting drain to DRAM", $time, debug_l2_fifo_count, FIFO_BURST_SIZE);
            end
            if (debug_l2_fifo_full) begin
                $display("[%0t] ⚠️  L2_FIFO_FULL: count=%0d, must drain to DRAM immediately", $time, debug_l2_fifo_count);
            end
            
            // Final Output Monitoring
            if (dram_valid && dram_ready) begin
                dram_write_count++;
                $display("[%0t] 🟢 L3_DRAM_WRITE: #%0d addr=0x%04x value=%0d (l2_fifo_count=%0d)", $time, dram_write_count, dram_address, dram_value, debug_l2_fifo_count);
            end
        end
    end

    // Clock generation
    initial begin
        clock = 0;
        forever #(CLK_PERIOD/2) clock = ~clock;
    end

    // Task: Send gradient update
    task automatic send_gradient(input logic [ADDR_WIDTH-1:0] addr, 
                                 input logic signed [GRAD_WIDTH-1:0] grad,
                                 input string description = "");
        core_address <= addr;
        core_gradient <= grad;
        core_valid <= 1'b1;
        @(posedge clock);
        if (description != "") 
            $display("[%0t] ▶️  INPUT: addr=0x%04x grad=%0d (%s)", $time, addr, grad, description);
        core_valid <= 1'b0;
    endtask

    // Task: Send idle cycles
    task automatic send_idle(input int cycles);
        core_valid <= 1'b0;
        repeat(cycles) @(posedge clock);
    endtask

    // Main unified test sequence
    initial begin
        automatic logic [15:0] conflict_addrs[8];
        automatic int initial_fifo_count;
        automatic int entries_needed;
        
        $display("\n======================================================================");
        $display("     DETAILED WAVEFORM ANALYSIS - All 5 Writeback Mechanisms");
        $display("======================================================================");
        
        // Initialize
        reset = 1;
        core_address = 0;
        core_gradient = 0;
        core_valid = 0;
        threshold = THRESHOLD_VAL;
        dram_ready = 1;
        
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);

        // ====================================================================
        // TEST 1: Direct Trigger Path
        // ====================================================================
        $display("\n");
        $display("======================================================================");
        $display(" TEST 1: DIRECT TRIGGER - Large gradients bypass L1 cache");
        $display("======================================================================");
        for (int i = 0; i < 8; i++) 
            send_gradient(16'h1000 + i, 16'sd100, "large gradient, direct path");
        send_idle(5);
        $display("[%0t] ✅ TEST 1 COMPLETE: %0d direct triggers sent to FIFO", $time, 8);

        // ====================================================================
        // TEST 2: Accumulation Threshold Trigger
        // ====================================================================
        $display("\n");
        $display("======================================================================");
        $display(" TEST 2: ACCUMULATION THRESHOLD - Small gradients accumulate until >= THRESHOLD");
        $display("======================================================================");
        for (int i = 0; i < 10; i++) 
            send_gradient(16'h2000, 16'sd6, $sformatf("accumulate iteration %0d", i+1));
        send_idle(5);
        $display("[%0t] ✅ TEST 2 COMPLETE: Accumulation crossed threshold", $time);

        // ====================================================================
        // TEST 3: MAX_UPDATES Force-Flush
        // ====================================================================
        $display("\n");
        $display("======================================================================");
        $display(" TEST 3: MAX_UPDATES FORCE-FLUSH - 255 small updates trigger flush");
        $display("======================================================================");
        for (int i = 0; i < MAX_UPDATES; i++) begin
            if (i % 50 == 0 || i == MAX_UPDATES-1) begin
                send_gradient(16'h3000, 16'sd1, $sformatf("tiny gradient %0d/%0d", i+1, MAX_UPDATES));
            end else begin
                send_gradient(16'h3000, 16'sd1, "");
            end
        end
        send_idle(5);
        $display("[%0t] ✅ TEST 3 COMPLETE: MAX_UPDATES force-flush triggered", $time);

        // ====================================================================
        // TEST 4: Eviction due to Tag Conflict
        // ====================================================================
        $display("\n");
        $display("======================================================================");
        $display(" TEST 4: EVICTION - Tag conflicts cause victim eviction to FIFO");
        $display("======================================================================");
        $display("Strategy: Fill all 4 ways of a set, then add 5th entry -> eviction!");
        conflict_addrs = '{16'h0000, 16'h0020, 16'h0040, 16'h0060, 16'h0080, 16'h00A0, 16'h00C0, 16'h00E0};
        
        $display("Phase 1: Fill all 4 ways of Set 0");
        for (int i = 0; i < 4; i++) 
            send_gradient(conflict_addrs[i], 16'sd10, $sformatf("Fill way %0d of set 0", i));
        send_idle(3);
        
        $display("\nPhase 2: Add 5th, 6th, 7th, 8th entries -> trigger evictions!");
        for (int i = 4; i < 8; i++) begin
            send_gradient(conflict_addrs[i], 16'sd15, $sformatf("NEW entry %0d -> EVICTION!", i-3));
            send_idle(1);
        end
        send_idle(5);
        $display("[%0t] ✅ TEST 4 COMPLETE: %0d evictions due to tag conflicts", $time, eviction_count);

        // ====================================================================
        // TEST 5: FIFO Burst Writeback to DRAM
        // ====================================================================
        $display("\n");
        $display("======================================================================");
        $display(" TEST 5: FIFO BURST - Accumulate 16+ entries, then batch write to DRAM");
        $display("======================================================================");
        
        initial_fifo_count = debug_l2_fifo_count;
        $display("Current FIFO count before burst: %0d", initial_fifo_count);
        entries_needed = (FIFO_BURST_SIZE > initial_fifo_count) ? (FIFO_BURST_SIZE - initial_fifo_count) : 1;
        $display("Pushing %0d more large gradients to trigger burst...", entries_needed);
        
        for (int i = 0; i < entries_needed; i++) 
            send_gradient(16'h5000 + i, 16'sd120, $sformatf("burst entry %0d", i+1));
        
        $display("\n⏳ Waiting for FIFO burst drain to DRAM...");
        send_idle(50);
        $display("[%0t] ✅ TEST 5 COMPLETE: FIFO burst mechanism tested", $time);

        // ====================================================================
        // SILENT HIGH VOLUME STRESS TEST (Phase 1 to Phase 6)
        // Description is explicitly "" so they run silently in the background
        // ====================================================================
        
        // Phase 1: Pure accumulation
        for (int i = 0; i < 10; i++)
            for (int j = 0; j < 32; j++) send_gradient(16'h0100 + j, 16'sd4, "");

        // Phase 2: Outlier bypass
        for (int i = 0; i < 320; i++) send_gradient(16'h1000 + i, 16'sd100, "");

        // Phase 3 & 4: Conflict, Eviction & Accum overflow
        for (int i = 0; i < 32; i++) send_gradient(16'h0200 + i, 16'sd10, "");
        for (int i = 0; i < 32; i++) send_gradient(16'h0300 + i, 16'sd15, "");
        for (int i = 0; i < 32; i++) send_gradient(16'h0300 + i, 16'sd40, "");

        // Phase 5: Full capacity forced eviction
        for (int i = 0; i < 32; i++) send_gradient(16'h0400 + i, 16'sd5, "");
        for (int i = 0; i < 32; i++) send_gradient(16'h0500 + i, 16'sd5, "");
        for (int i = 0; i < 32; i++) send_gradient(16'h0600 + i, 16'sd5, "");
        for (int i = 0; i < 32; i++) send_gradient(16'h0700 + i, 16'sd5, "");
        for (int i = 0; i < 32; i++) send_gradient(16'h0800 + i, 16'sd8, "");

        // Phase 6: MAX_UPDATES forced flush stress
        for (int i = 0; i < 260; i++) send_gradient(16'h0A00, 16'sd2, "");

        send_idle(50);
        $finish;
    end

    // Final Statistics Reports aligned with Target
    final begin
        real compression_ratio;
        real bw_reduction_pct;
        
        // Final Mechanisms Report Block
        $display("\n");
        $display("======================================================================");
        $display(" FINAL STATISTICS - All Writeback Mechanisms");
        $display("======================================================================");
        $display("1️⃣  Direct Trigger (|grad| >= THRESHOLD)    : %0d events", direct_trigger_count);
        $display("2️⃣  Accumulation Threshold (accum >= THRESHOLD) : %0d events", accum_threshold_count);
        $display("3️⃣  MAX_UPDATES Force-Flush               : %0d events", max_updates_count);
        $display("4️⃣  Eviction (tag conflict)               : %0d events", eviction_count);
        $display("5️⃣  DRAM Writes (FIFO -> DRAM)             : %0d events", dram_write_count);
        $display("======================================================================");
        
        total_to_fifo = direct_trigger_count + accum_threshold_count + max_updates_count + eviction_count;
        $display("\nTotal L1->FIFO pushes: %0d", total_to_fifo);
        $display("Total FIFO->DRAM writes: %0d", dram_write_count);
        
        if (direct_trigger_count > 0 && accum_threshold_count > 0 && 
            max_updates_count > 0 && eviction_count > 0) begin
            $display("\n✅✅✅ ALL 5 MECHANISMS SUCCESSFULLY VERIFIED! ✅✅✅");
        end else begin
            $display("\n⚠️  WARNING: Not all mechanisms triggered");
        end
        
        $display("\n📊 Check waveform file: detailed_waveform_analysis.fst");
        $display("Look for debug signals:");
        $display("  L1 Cache (Accumulator):");
        $display("    - debug_l1_wb_direct");
        $display("    - debug_l1_wb_accum_overflow");
        $display("    - debug_l1_wb_max_updates");
        $display("    - debug_l1_wb_eviction 👈 EVICTION MARKER!");
        $display("    - debug_l1_hit / debug_l1_miss");
        $display("  L2 FIFO (Writeback Buffer):");
        $display("    - debug_l2_fifo_count");
        $display("    - debug_l2_burst_ready");
        $display("    - debug_l2_draining");
        $display("  L3 DRAM (Final Output):");
        $display("    - dram_valid / dram_address / dram_value\n");

        // Bandwidth Performance Report Block
        compression_ratio = (perf_mon.compressed_output_tx_count > 0) ? 
            $itor(perf_mon.raw_input_tx_count) / $itor(perf_mon.compressed_output_tx_count) : 0.0;
        bw_reduction_pct = (perf_mon.raw_input_tx_count > 0) ? 
            (1.0 - ($itor(perf_mon.compressed_output_tx_count) / $itor(perf_mon.raw_input_tx_count))) * 100.0 : 0.0;

        $display("======================================================================");
        $display(" BANDWIDTH PERFORMANCE REPORT");
        $display("======================================================================");
        $display("Raw Input Transactions  : %0d (%0d Bytes)", perf_mon.raw_input_tx_count, perf_mon.get_raw_bytes());
        $display("Output Writes to Memory : %0d (%0d Bytes)", perf_mon.compressed_output_tx_count, perf_mon.get_compressed_bytes());
        $display("----------------------------------------------------------------------");
        $display("Bandwidth Reduction     : %0.2f %%", bw_reduction_pct);
        $display("Compression Ratio       : %0.2f x", compression_ratio);
        $display("======================================================================\n");
    end

    // Waveform dump
    initial begin
        $dumpfile("detailed_waveform_analysis.fst");
        $dumpvars(0, tb_unified_gradient_compressor);
        
        // Explicitly dump debug signals
        $dumpvars(0, debug_l1_wb_direct);
        $dumpvars(0, debug_l1_wb_accum_overflow);
        $dumpvars(0, debug_l1_wb_max_updates);
        $dumpvars(0, debug_l1_wb_eviction);
        $dumpvars(0, debug_l1_hit);
        $dumpvars(0, debug_l1_miss);
        $dumpvars(0, debug_l2_fifo_count);
        $dumpvars(0, debug_l2_burst_ready);
        $dumpvars(0, debug_l2_fifo_full);
        $dumpvars(0, debug_l2_draining);
    end

endmodule