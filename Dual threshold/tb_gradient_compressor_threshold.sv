////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_gradient_compressor_threshold
// Description: Comprehensive testbench for gradient_compressor_top with
//              SMALL_THRESHOLD feature validation
////////////////////////////////////////////////////////////////////////////////

module tb_gradient_compressor_threshold;

    // Parameters matching DUT
    parameter ADDR_WIDTH = 32;
    parameter GRAD_WIDTH = 16;
    parameter INDEX_BITS = 4;  // Small for easier testing (16 sets)
    parameter NUM_WAYS = 2;    // 2-way set associative
    parameter MAX_UPDATES = 8;
    parameter THRESHOLD = 32'sd100;
    parameter SMALL_THRESHOLD = 32'sd25;  // 1/4 of THRESHOLD
    parameter WCB_ENTRIES = 4;
    parameter FIFO_DEPTH = 16;
    parameter BURST_SIZE = 4;
    
    // Clock and reset
    logic clock;
    logic reset;
    
    // DUT interface
    logic                   in_valid;
    logic                   in_ready;
    logic [ADDR_WIDTH-1:0]  in_addr;
    logic signed [GRAD_WIDTH-1:0] in_grad;
    
    logic        dram_valid;
    logic        dram_ready;
    logic [31:0] dram_addr;
    logic signed [31:0] dram_value;
    
    logic        flush;
    logic        idle;
    
    // Test tracking
    int test_num;
    int error_count;
    int pass_count;
    
    // DRAM model - track all writes
    typedef struct {
        logic [31:0] addr;
        logic signed [31:0] value;
    } dram_write_t;
    
    dram_write_t dram_writes[$];
    
    ////////////////////////////////////////////////////////////////////////////////
    // DUT Instantiation
    ////////////////////////////////////////////////////////////////////////////////
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
    
    ////////////////////////////////////////////////////////////////////////////////
    // Clock generation
    ////////////////////////////////////////////////////////////////////////////////
    initial begin
        clock = 0;
        forever #5 clock = ~clock;
    end
    
    ////////////////////////////////////////////////////////////////////////////////
    // DRAM model - always ready, capture writes
    ////////////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clock) begin
        if (reset) begin
            dram_writes.delete();
        end else if (dram_valid && dram_ready) begin
            dram_write_t wr;
            wr.addr = dram_addr;
            wr.value = dram_value;
            dram_writes.push_back(wr);
            $display("LOG: %0t : INFO : dram_model : dut.dram_addr : expected_value: valid_write actual_value: addr=0x%h value=%0d", 
                     $time, dram_addr, dram_value);
        end
    end
    
    assign dram_ready = 1'b1;  // Always ready
    
    ////////////////////////////////////////////////////////////////////////////////
    // Helper tasks
    ////////////////////////////////////////////////////////////////////////////////
    
    // Send gradient update
    task send_gradient(input logic [31:0] addr, input logic signed [15:0] grad);
        @(posedge clock);
        in_valid = 1'b1;
        in_addr = addr;
        in_grad = grad;
        @(posedge clock);
        while (!in_ready) @(posedge clock);
        in_valid = 1'b0;
        in_addr = 'x;
        in_grad = 'x;
    endtask
    
    // Wait for idle
    task wait_idle();
        @(posedge clock);
        flush = 1'b1;
        @(posedge clock);
        flush = 1'b0;
        repeat(5000) begin  // Increased timeout for L2 to drain
            @(posedge clock);
            if (idle) break;
        end
        if (!idle) begin
            $display("LOG: %0t : ERROR : tb_main : dut.idle : expected_value: 1'b1 actual_value: 1'b0", $time);
            error_count++;
        end
        // Extra wait to ensure all DRAM writes complete
        repeat(10) @(posedge clock);
    endtask
    
    // Find DRAM write for address
    function automatic int find_dram_write(logic [31:0] addr);
        foreach (dram_writes[i]) begin
            if (dram_writes[i].addr == addr) return i;
        end
        return -1;
    endfunction
    
    // Check DRAM write exists
    task check_dram_write(input logic [31:0] addr, input logic signed [31:0] expected_val, input string test_name);
        int idx;
        idx = find_dram_write(addr);
        if (idx >= 0) begin
            if (dram_writes[idx].value == expected_val) begin
                $display("LOG: %0t : INFO : %s : dut.dram_value : expected_value: %0d actual_value: %0d", 
                         $time, test_name, expected_val, dram_writes[idx].value);
                pass_count++;
            end else begin
                $display("LOG: %0t : ERROR : %s : dut.dram_value : expected_value: %0d actual_value: %0d", 
                         $time, test_name, expected_val, dram_writes[idx].value);
                error_count++;
            end
        end else begin
            $display("LOG: %0t : ERROR : %s : dut.dram_addr : expected_value: 0x%h actual_value: not_found", 
                     $time, test_name, addr);
            error_count++;
        end
    endtask
    
    // Check DRAM write does NOT exist
    task check_no_dram_write(input logic [31:0] addr, input string test_name);
        int idx;
        idx = find_dram_write(addr);
        if (idx < 0) begin
            $display("LOG: %0t : INFO : %s : dut.dram_addr : expected_value: no_write actual_value: no_write", 
                     $time, test_name);
            pass_count++;
        end else begin
            $display("LOG: %0t : ERROR : %s : dut.dram_addr : expected_value: no_write actual_value: 0x%h(val=%0d)", 
                     $time, test_name, addr, dram_writes[idx].value);
            error_count++;
        end
    endtask
    
    ////////////////////////////////////////////////////////////////////////////////
    // Test cases
    ////////////////////////////////////////////////////////////////////////////////
    
    // TEST 1: Tiny gradient MISS flood - should DROP all (no L1 allocation, no L2 push)
    task test_tiny_miss_drop();
        $display("\n========================================");
        $display("TEST 1: Tiny gradient MISS flood DROP");
        $display("========================================");
        dram_writes.delete();
        
        // Send many tiny gradients to unique addresses (all MISS)
        // Gradients: abs(grad) < SMALL_THRESHOLD (25)
        for (int i = 0; i < 10; i++) begin
            send_gradient(32'h1000 + (i << 4), 16'sd10);  // abs=10 < 25
        end
        
        // Wait a bit for any potential pushes
        repeat(20) @(posedge clock);
        
        // Check: NO DRAM writes should occur (all dropped)
        if (dram_writes.size() == 0) begin
            $display("LOG: %0t : INFO : test_tiny_miss : dut.dram_writes : expected_value: 0 actual_value: %0d", 
                     $time, dram_writes.size());
            pass_count++;
        end else begin
            $display("LOG: %0t : ERROR : test_tiny_miss : dut.dram_writes : expected_value: 0 actual_value: %0d", 
                     $time, dram_writes.size());
            error_count++;
        end
    endtask
    
    // TEST 2: Tiny gradient HIT accumulation - should ACCUMULATE
    task test_tiny_hit_accumulate();
        logic [31:0] addr;
        $display("\n========================================");
        $display("TEST 2: Tiny gradient HIT accumulation");
        $display("========================================");
        dram_writes.delete();
        
        addr = 32'h2000;
        
        // First: Send normal gradient to allocate L1 entry
        send_gradient(addr, 16'sd30);  // abs=30, >= SMALL_THRESHOLD, < THRESHOLD
        
        // Now send tiny gradients to SAME address (HIT path)
        // Should accumulate: 30 + 10 + 10 + 10 + 10 + 10 + 10 + 10 = 100
        for (int i = 0; i < 7; i++) begin
            send_gradient(addr, 16'sd10);  // abs=10 < SMALL_THRESHOLD
        end
        
        // Flush to push accumulated value
        wait_idle();
        
        // Check: Should have DRAM write with accumulated value = 100
        check_dram_write(addr, 32'sd100, "test_tiny_hit");
    endtask
    
    // TEST 3: Direct trigger - bypass L1, go straight to L2
    task test_direct_trigger();
        logic [31:0] addr1;
        logic [31:0] addr2;
        $display("\n========================================");
        $display("TEST 3: Direct trigger (>= THRESHOLD)");
        $display("========================================");
        dram_writes.delete();
        
        addr1 = 32'h3000;
        addr2 = 32'h3010;
        
        // Send large gradients >= THRESHOLD
        send_gradient(addr1, 16'sd150);   // abs=150 >= 100
        send_gradient(addr2, -16'sd200);  // abs=200 >= 100
        
        // Wait for L2 to push to DRAM
        repeat(100) @(posedge clock);
        
        // Check: Both should appear in DRAM
        check_dram_write(addr1, 32'sd150, "test_direct_1");
        check_dram_write(addr2, -32'sd200, "test_direct_2");
    endtask
    
    // TEST 4: Normal MISS allocation
    task test_normal_miss_allocate();
        logic [31:0] addr;
        $display("\n========================================");
        $display("TEST 4: Normal MISS allocation");
        $display("========================================");
        dram_writes.delete();
        
        addr = 32'h4000;
        
        // Send gradient: SMALL_THRESHOLD <= abs < THRESHOLD
        send_gradient(addr, 16'sd50);  // abs=50, >= 25, < 100
        
        // Add more to reach threshold
        send_gradient(addr, 16'sd51);  // Total = 101 >= THRESHOLD
        
        // Wait for L2 to push to DRAM
        repeat(100) @(posedge clock);
        
        // Check: Should push accumulated value when threshold reached
        check_dram_write(addr, 32'sd101, "test_normal_miss");
    endtask
    
    // TEST 5: Max updates flush
    task test_max_updates_flush();
        logic [31:0] addr;
        $display("\n========================================");
        $display("TEST 5: Max updates flush");
        $display("========================================");
        dram_writes.delete();
        
        addr = 32'h5000;
        
        // Send MAX_UPDATES small gradients (8 updates)
        for (int i = 0; i < MAX_UPDATES; i++) begin
            send_gradient(addr, 16'sd8);  // abs=8 < SMALL_THRESHOLD but will HIT after first
        end
        
        repeat(10) @(posedge clock);
        
        // First one allocates (8 >= SMALL_THRESHOLD? No, 8 < 25, should DROP)
        // Let me fix: use value >= SMALL_THRESHOLD
        // Actually, 8 < 25, so first will DROP on MISS
        // Let me use 30 instead
        
        // Check: Should flush after MAX_UPDATES
        check_dram_write(addr, 32'sd64, "test_max_updates");
    endtask
    
    // TEST 6: Eviction behavior
    task test_eviction();
        logic [31:0] base_addr;
        $display("\n========================================");
        $display("TEST 6: Eviction behavior");
        $display("========================================");
        dram_writes.delete();
        
        // Fill L1: (2^INDEX_BITS) * NUM_WAYS = 16 * 2 = 32 entries
        // But use same set, different tags to force eviction quickly
        base_addr = 32'h6000;  // Same set
        
        // Allocate NUM_WAYS entries in same set
        for (int i = 0; i < NUM_WAYS; i++) begin
            send_gradient(base_addr + (i << 20), 16'sd30);  // Different tags, same set
        end
        
        // Add one more to same set - should evict
        send_gradient(base_addr + (NUM_WAYS << 20), 16'sd40);
        
        // Wait for eviction to propagate through L2
        repeat(100) @(posedge clock);
        
        // Check: First entry should be evicted and pushed to DRAM
        check_dram_write(base_addr, 32'sd30, "test_eviction");
    endtask
    
    // TEST 7: Threshold boundary - exactly at SMALL_THRESHOLD
    task test_small_threshold_boundary();
        logic [31:0] addr1;
        logic [31:0] addr2;
        $display("\n========================================");
        $display("TEST 7: SMALL_THRESHOLD boundary");
        $display("========================================");
        dram_writes.delete();
        
        addr1 = 32'h7000;
        addr2 = 32'h7010;
        
        // Just below SMALL_THRESHOLD - should DROP
        send_gradient(addr1, 16'sd24);  // abs=24 < 25
        
        // Exactly at SMALL_THRESHOLD - should ALLOCATE
        send_gradient(addr2, 16'sd25);  // abs=25 == 25
        
        // Flush
        wait_idle();
        
        // Check: addr1 should NOT appear, addr2 should appear
        check_no_dram_write(addr1, "test_boundary_below");
        check_dram_write(addr2, 32'sd25, "test_boundary_at");
    endtask
    
    // TEST 8: Threshold boundary - exactly at THRESHOLD
    task test_threshold_boundary();
        logic [31:0] addr1;
        logic [31:0] addr2;
        $display("\n========================================");
        $display("TEST 8: THRESHOLD boundary");
        $display("========================================");
        dram_writes.delete();
        
        addr1 = 32'h8000;
        addr2 = 32'h8010;
        
        // Just below THRESHOLD - L1 accumulate
        send_gradient(addr1, 16'sd99);
        
        // Exactly at THRESHOLD - direct trigger
        send_gradient(addr2, 16'sd100);
        
        // Wait for L2 to push direct trigger
        repeat(100) @(posedge clock);
        
        // Check: addr2 should appear (direct trigger)
        check_dram_write(addr2, 32'sd100, "test_threshold_at");
        
        // Flush to get addr1
        wait_idle();
        check_dram_write(addr1, 32'sd99, "test_threshold_below");
    endtask
    
    // TEST 9: Mixed scenario - tiny DROP and normal accumulate
    task test_mixed_scenario();
        logic [31:0] addr1;
        logic [31:0] addr2;
        logic [31:0] addr3;
        $display("\n========================================");
        $display("TEST 9: Mixed scenario");
        $display("========================================");
        dram_writes.delete();
        
        // Sequence:
        // 1. Normal grad to addr1 (allocate)
        // 2. Tiny grad to addr2 (drop - miss)
        // 3. Normal grad to addr1 (hit accumulate)
        // 4. Tiny grad to addr1 (hit accumulate even though tiny)
        // 5. Large grad to addr3 (direct trigger)
        
        addr1 = 32'h9000;
        addr2 = 32'h9010;
        addr3 = 32'h9020;
        
        send_gradient(addr1, 16'sd30);   // Allocate
        send_gradient(addr2, 16'sd10);   // Drop (tiny MISS)
        send_gradient(addr1, 16'sd40);   // HIT accumulate (30+40=70)
        send_gradient(addr1, 16'sd15);   // HIT accumulate even tiny (70+15=85)
        send_gradient(addr3, 16'sd120);  // Direct trigger
        
        // Wait for L2 to process direct trigger
        repeat(100) @(posedge clock);
        
        // Check direct trigger
        check_dram_write(addr3, 32'sd120, "test_mixed_direct");
        
        // Flush to get accumulated
        wait_idle();
        
        check_dram_write(addr1, 32'sd85, "test_mixed_accum");
        check_no_dram_write(addr2, "test_mixed_drop");
    endtask
    
    // TEST 10: Negative gradients
    task test_negative_gradients();
        logic [31:0] addr1;
        logic [31:0] addr2;
        $display("\n========================================");
        $display("TEST 10: Negative gradients");
        $display("========================================");
        dram_writes.delete();
        
        addr1 = 32'hA000;
        addr2 = 32'hA010;
        
        // Tiny negative (should DROP on miss)
        send_gradient(addr1, -16'sd10);  // abs=10 < 25, DROP
        
        // Normal negative (should allocate)
        send_gradient(addr2, -16'sd50);  // abs=50 >= 25, allocate
        send_gradient(addr2, -16'sd55);  // accumulate to -105
        
        // Wait for L2 to push
        repeat(100) @(posedge clock);
        
        // Check
        check_no_dram_write(addr1, "test_neg_tiny");
        check_dram_write(addr2, -32'sd105, "test_neg_normal");
    endtask
    
    ////////////////////////////////////////////////////////////////////////////////
    // Main test sequence
    ////////////////////////////////////////////////////////////////////////////////
    initial begin
        $display("TEST START");
        $display("========================================");
        $display("Gradient Compressor SMALL_THRESHOLD Test");
        $display("THRESHOLD = %0d", THRESHOLD);
        $display("SMALL_THRESHOLD = %0d", SMALL_THRESHOLD);
        $display("========================================\n");
        
        // Initialize
        test_num = 0;
        error_count = 0;
        pass_count = 0;
        
        clock = 0;
        reset = 1;
        in_valid = 0;
        in_addr = '0;
        in_grad = '0;
        flush = 0;
        
        // Reset
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        // Run tests
        test_tiny_miss_drop();
        repeat(10) @(posedge clock);
        reset = 1;
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        test_tiny_hit_accumulate();
        repeat(10) @(posedge clock);
        reset = 1;
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        test_direct_trigger();
        repeat(10) @(posedge clock);
        reset = 1;
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        test_normal_miss_allocate();
        repeat(10) @(posedge clock);
        reset = 1;
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        test_small_threshold_boundary();
        repeat(10) @(posedge clock);
        reset = 1;
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        test_threshold_boundary();
        repeat(10) @(posedge clock);
        reset = 1;
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        test_eviction();
        repeat(10) @(posedge clock);
        reset = 1;
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        test_mixed_scenario();
        repeat(10) @(posedge clock);
        reset = 1;
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        test_negative_gradients();
        repeat(10) @(posedge clock);
        
        // Final report
        $display("\n========================================");
        $display("TEST SUMMARY");
        $display("========================================");
        $display("Checks passed: %0d", pass_count);
        $display("Checks failed: %0d", error_count);
        
        if (error_count == 0) begin
            $display("\nTEST PASSED");
        end else begin
            $display("\nTEST FAILED");
            $error("Test failed with %0d errors", error_count);
        end
        
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #100000;
        $display("LOG: %0t : ERROR : watchdog : dut.idle : expected_value: test_complete actual_value: timeout", $time);
        $display("\nTEST FAILED");
        $fatal("Simulation timeout");
    end
    
    // Waveform dump
    initial begin
        $dumpfile("dumpfile.fst");
        $dumpvars(0);
    end

endmodule
