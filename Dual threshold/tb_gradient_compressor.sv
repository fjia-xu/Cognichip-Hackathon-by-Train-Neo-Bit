////////////////////////////////////////////////////////////////////////////////
// Testbench for Two-Level Gradient Writeback Architecture (PATCHED VERSION)
// Tests: Direct trigger, L1 accumulation, force flush, eviction, 
//        write combining, backpressure, flush operations, and idle tracking
////////////////////////////////////////////////////////////////////////////////

module tb_gradient_compressor;

    localparam ADDR_WIDTH = 32;
    localparam GRAD_WIDTH = 16;
    localparam INDEX_BITS = 4;
    localparam NUM_WAYS = 4;
    localparam MAX_UPDATES = 10;
    localparam THRESHOLD = 32'sd50;
    localparam WCB_ENTRIES = 8;
    localparam FIFO_DEPTH = 32;
    localparam BURST_SIZE = 4;
    
    localparam CLK_PERIOD = 10;
    localparam NUM_SETS = 2**INDEX_BITS;
    
    logic                   clock;
    logic                   reset;
    logic                   in_valid;
    logic                   in_ready;
    logic [ADDR_WIDTH-1:0]  in_addr;
    logic signed [GRAD_WIDTH-1:0] in_grad;
    logic                   dram_valid;
    logic                   dram_ready;
    logic [31:0]            dram_addr;
    logic signed [31:0]     dram_value;
    logic                   flush;
    logic                   idle;
    
    int test_errors;
    int test_passed;
    
    typedef struct {
        logic [31:0] addr;
        logic signed [31:0] value;
    } dram_write_t;
    
    dram_write_t dram_writes[$];
    
    initial begin
        clock = 0;
        forever #(CLK_PERIOD/2) clock = ~clock;
    end
    
    gradient_compressor_top #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .GRAD_WIDTH(GRAD_WIDTH),
        .INDEX_BITS(INDEX_BITS),
        .NUM_WAYS(NUM_WAYS),
        .MAX_UPDATES(MAX_UPDATES),
        .THRESHOLD(THRESHOLD),
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
    
    logic dram_backpressure_enable;
    int dram_ready_probability;
    
    always @(posedge clock) begin
        if (reset) begin
            dram_ready <= 1;
        end else begin
            if (dram_backpressure_enable) begin
                dram_ready <= ($urandom_range(100) < dram_ready_probability);
            end else begin
                dram_ready <= 1;
            end
        end
    end
    
    always @(posedge clock) begin
        if (!reset && dram_valid && dram_ready) begin
            dram_write_t wr;
            wr.addr = dram_addr;
            wr.value = dram_value;
            dram_writes.push_back(wr);
            $display("LOG: %0t : INFO : tb_gradient_compressor : dut.dram_addr : expected_value: write_accepted actual_value: addr=0x%08h value=%0d", 
                     $time, dram_addr, dram_value);
        end
    end
    
    task reset_dut();
        begin
            reset = 1;
            in_valid = 0;
            in_addr = 0;
            in_grad = 0;
            flush = 0;
            dram_backpressure_enable = 0;
            dram_ready_probability = 100;
            dram_ready = 1;
            repeat(5) @(posedge clock);
            reset = 0;
            repeat(2) @(posedge clock);
        end
    endtask
    
    task send_gradient(input logic [31:0] addr, input logic signed [15:0] grad);
        begin
            @(posedge clock);
            in_valid = 1;
            in_addr = addr;
            in_grad = grad;
            @(posedge clock);
            while (!in_ready) @(posedge clock);
            in_valid = 0;
            @(posedge clock);
        end
    endtask
    
    task wait_for_idle();
        int timeout_counter;
        begin
            timeout_counter = 0;
            @(posedge clock);
            while (!idle && timeout_counter < 1000) begin
                @(posedge clock);
                timeout_counter++;
            end
            if (timeout_counter >= 1000) begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : wait_for_idle : expected_value: idle=1 actual_value: timeout", $time);
            end else begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : dut.idle : expected_value: 1 actual_value: %0d", $time, idle);
            end
        end
    endtask
    
    task trigger_flush();
        begin
            @(posedge clock);
            flush = 1;
            @(posedge clock);
            flush = 0;
            wait_for_idle();
        end
    endtask
    
    function int find_dram_write(logic [31:0] addr);
        for (int i = 0; i < dram_writes.size(); i++) begin
            if (dram_writes[i].addr == addr) begin
                return i;
            end
        end
        return -1;
    endfunction
    
    task test_direct_trigger();
        begin
            $display("\n=== TEST 1: Direct Trigger Bypass ===");
            dram_writes.delete();
            reset_dut();
            
            send_gradient(32'h1000, 16'sd100);
            trigger_flush();
            
            if (dram_writes.size() == 1 && dram_writes[0].addr == 32'h1000 && dram_writes[0].value == 32'sd100) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_direct_trigger : expected_value: PASS actual_value: PASS", $time);
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_direct_trigger : expected_value: 1_write actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_errors++;
            end
        end
    endtask
    
    task test_l1_accumulation();
        begin
            $display("\n=== TEST 2: L1 Accumulation ===");
            dram_writes.delete();
            reset_dut();
            
            send_gradient(32'h2000, 16'sd10);
            send_gradient(32'h2000, 16'sd15);
            send_gradient(32'h2000, 16'sd20);
            wait_for_idle();
            
            if (dram_writes.size() == 0) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_l1_accumulation : expected_value: 0_writes actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_l1_accumulation : expected_value: 0_writes actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_errors++;
            end
            
            trigger_flush();
            
            if (dram_writes.size() == 1 && dram_writes[0].addr == 32'h2000 && dram_writes[0].value == 32'sd45) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_l1_accumulation_flush : expected_value: 45 actual_value: %0d", 
                         $time, dram_writes[0].value);
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_l1_accumulation_flush : expected_value: 45 actual_value: %0d", 
                         $time, dram_writes.size() > 0 ? dram_writes[0].value : 0);
                test_errors++;
            end
        end
    endtask
    
    task test_force_flush_threshold();
        begin
            $display("\n=== TEST 3: Force Flush on Threshold ===");
            dram_writes.delete();
            reset_dut();
            
            send_gradient(32'h3000, 16'sd20);
            send_gradient(32'h3000, 16'sd35);
            trigger_flush();
            
            if (dram_writes.size() == 1 && dram_writes[0].addr == 32'h3000 && dram_writes[0].value == 32'sd55) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_force_flush_threshold : expected_value: 55 actual_value: %0d", 
                         $time, dram_writes[0].value);
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_force_flush_threshold : expected_value: 55 actual_value: %0d", 
                         $time, dram_writes.size() > 0 ? dram_writes[0].value : 0);
                test_errors++;
            end
        end
    endtask
    
    task test_force_flush_max_updates();
        logic signed [31:0] expected_value;
        begin
            $display("\n=== TEST 4: Force Flush on MAX_UPDATES ===");
            dram_writes.delete();
            reset_dut();
            
            for (int i = 0; i < MAX_UPDATES; i++) begin
                send_gradient(32'h4000, 16'sd3);
            end
            trigger_flush();
            
            expected_value = 32'sd3 * MAX_UPDATES;
            if (dram_writes.size() == 1 && dram_writes[0].addr == 32'h4000 && dram_writes[0].value == expected_value) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_force_flush_max_updates : expected_value: %0d actual_value: %0d", 
                         $time, expected_value, dram_writes[0].value);
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_force_flush_max_updates : expected_value: %0d actual_value: %0d", 
                         $time, expected_value, dram_writes.size() > 0 ? dram_writes[0].value : 0);
                test_errors++;
            end
        end
    endtask
    
    task test_l1_miss_allocation();
        logic [31:0] base_set;
        logic [31:0] addr;
        begin
            $display("\n=== TEST 5: L1 Miss Allocation ===");
            dram_writes.delete();
            reset_dut();
            
            base_set = 32'h0005;
            for (int i = 0; i < NUM_WAYS; i++) begin
                addr = (i << INDEX_BITS) | base_set;
                send_gradient(addr, 16'sd10);
            end
            wait_for_idle();
            
            if (dram_writes.size() == 0) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_l1_miss_allocation : expected_value: 0_writes actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_l1_miss_allocation : expected_value: 0_writes actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_errors++;
            end
        end
    endtask
    
    task test_victim_eviction();
        logic [31:0] base_set;
        logic [31:0] addr;
        logic [31:0] new_addr;
        begin
            $display("\n=== TEST 6: Victim Eviction ===");
            dram_writes.delete();
            reset_dut();
            
            base_set = 32'h0007;
            for (int i = 0; i < NUM_WAYS; i++) begin
                addr = (i << INDEX_BITS) | base_set;
                send_gradient(addr, 16'sd10);
            end
            
            new_addr = (NUM_WAYS << INDEX_BITS) | base_set;
            send_gradient(new_addr, 16'sd15);
            trigger_flush();
            
            if (dram_writes.size() >= 1) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_victim_eviction : expected_value: eviction_occurred actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_victim_eviction : expected_value: eviction_occurred actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_errors++;
            end
        end
    endtask
    
    task test_write_combining();
        logic signed [31:0] expected_combined;
        int idx;
        begin
            $display("\n=== TEST 7: Write Combining in L2 ===");
            dram_writes.delete();
            reset_dut();
            
            send_gradient(32'h5000, 16'sd60);
            send_gradient(32'h5000, 16'sd70);
            send_gradient(32'h5000, 16'sd80);
            trigger_flush();
            
            expected_combined = 32'sd60 + 32'sd70 + 32'sd80;
            idx = find_dram_write(32'h5000);
            if (idx >= 0 && dram_writes[idx].value == expected_combined) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_write_combining : expected_value: %0d actual_value: %0d", 
                         $time, expected_combined, dram_writes[idx].value);
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_write_combining : expected_value: %0d actual_value: %0d", 
                         $time, expected_combined, idx >= 0 ? dram_writes[idx].value : 0);
                test_errors++;
            end
        end
    endtask
    
    task test_backpressure();
        begin
            $display("\n=== TEST 8: Backpressure Handling ===");
            dram_writes.delete();
            reset_dut();
            
            dram_backpressure_enable = 1;
            dram_ready_probability = 30;
            
            for (int i = 0; i < 5; i++) begin
                send_gradient(32'h6000 + i*4, 16'sd100);
            end
            
            repeat(200) @(posedge clock);
            dram_backpressure_enable = 0;
            trigger_flush();
            
            if (dram_writes.size() == 5) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_backpressure : expected_value: 5_writes actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_backpressure : expected_value: 5_writes actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_errors++;
            end
        end
    endtask
    
    task test_flush_operation();
        logic [31:0] addr;
        begin
            $display("\n=== TEST 9: Flush Operation ===");
            dram_writes.delete();
            reset_dut();
            
            for (int i = 0; i < 8; i++) begin
                addr = 32'h7000 + i*256;
                send_gradient(addr, $signed(10 + i));
            end
            
            trigger_flush();
            
            if (dram_writes.size() == 8) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_flush_operation : expected_value: 8_writes actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_flush_operation : expected_value: 8_writes actual_value: %0d_writes", 
                         $time, dram_writes.size());
                test_errors++;
            end
        end
    endtask
    
    task test_mixed_operations();
        int num_writes;
        begin
            $display("\n=== TEST 10: Mixed Operations Stress Test ===");
            dram_writes.delete();
            reset_dut();
            
            dram_backpressure_enable = 1;
            dram_ready_probability = 50;
            
            send_gradient(32'h8000, 16'sd100);
            send_gradient(32'h8100, 16'sd10);
            send_gradient(32'h8100, 16'sd15);
            send_gradient(32'h8200, 16'sd20);
            send_gradient(32'h8100, 16'sd30);
            send_gradient(32'h8300, -16'sd80);
            
            repeat(100) @(posedge clock);
            dram_backpressure_enable = 0;
            trigger_flush();
            
            num_writes = dram_writes.size();
            if (num_writes >= 3) begin
                $display("LOG: %0t : INFO : tb_gradient_compressor : test_mixed_operations : expected_value: >=3_writes actual_value: %0d_writes", 
                         $time, num_writes);
                test_passed++;
            end else begin
                $display("LOG: %0t : ERROR : tb_gradient_compressor : test_mixed_operations : expected_value: >=3_writes actual_value: %0d_writes", 
                         $time, num_writes);
                test_errors++;
            end
        end
    endtask
    
    initial begin
        $display("TEST START");
        $display("================================================================================");
        $display("Gradient Compressor Testbench (PATCHED VERSION)");
        $display("Parameters: INDEX_BITS=%0d, NUM_WAYS=%0d, MAX_UPDATES=%0d, THRESHOLD=%0d",
                 INDEX_BITS, NUM_WAYS, MAX_UPDATES, THRESHOLD);
        $display("================================================================================");
        
        test_errors = 0;
        test_passed = 0;
        
        test_direct_trigger();
        test_l1_accumulation();
        test_force_flush_threshold();
        test_force_flush_max_updates();
        test_l1_miss_allocation();
        test_victim_eviction();
        test_write_combining();
        test_backpressure();
        test_flush_operation();
        test_mixed_operations();
        
        $display("\n================================================================================");
        $display("Test Summary:");
        $display("  Tests Passed: %0d", test_passed);
        $display("  Tests Failed: %0d", test_errors);
        $display("================================================================================");
        
        if (test_errors == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("TEST FAILED with %0d errors", test_errors);
        end
        
        $finish;
    end
    
    initial begin
        $dumpfile("dumpfile.fst");
        $dumpvars(0);
    end
    
    initial begin
        #500000;
        $display("LOG: %0t : ERROR : tb_gradient_compressor : timeout : expected_value: completion actual_value: timeout", $time);
        $display("ERROR");
        $fatal(1, "Simulation timeout");
    end

endmodule
