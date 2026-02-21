////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_gradient_simple
// Description: Focused testbench for SMALL_THRESHOLD feature validation
////////////////////////////////////////////////////////////////////////////////

module tb_gradient_simple;

    // Parameters
    parameter THRESHOLD = 32'sd100;
    parameter SMALL_THRESHOLD = 32'sd25;
    
    // Clock and reset
    logic clock;
    logic reset;
    
    // DUT interface
    logic        in_valid;
    logic        in_ready;
    logic [31:0] in_addr;
    logic signed [15:0] in_grad;
    
    logic        dram_valid;
    logic        dram_ready;
    logic [31:0] dram_addr;
    logic signed [31:0] dram_value;
    
    logic        flush;
    logic        idle;
    
    // Test tracking
    int error_count;
    int dram_write_count;
    
    ////////////////////////////////////////////////////////////////////////////////
    // DUT Instantiation
    ////////////////////////////////////////////////////////////////////////////////
    gradient_compressor_top #(
        .ADDR_WIDTH(32),
        .GRAD_WIDTH(16),
        .INDEX_BITS(4),
        .NUM_WAYS(2),
        .MAX_UPDATES(8),
        .THRESHOLD(THRESHOLD),
        .SMALL_THRESHOLD(SMALL_THRESHOLD),
        .WCB_ENTRIES(4),
        .FIFO_DEPTH(16),
        .BURST_SIZE(4)
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
    // DRAM model - count writes
    ////////////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clock) begin
        if (reset) begin
            dram_write_count = 0;
        end else if (dram_valid && dram_ready) begin
            dram_write_count = dram_write_count + 1;
            $display("LOG: %0t : INFO : dram_model : dram_addr=0x%h : expected_value: valid_write actual_value: value=%0d", 
                     $time, dram_addr, dram_value);
        end
    end
    
    assign dram_ready = 1'b1;
    
    ////////////////////////////////////////////////////////////////////////////////
    // Helper task
    ////////////////////////////////////////////////////////////////////////////////
    task send_grad(input logic [31:0] addr, input logic signed [15:0] grad);
        @(posedge clock);
        in_valid = 1'b1;
        in_addr = addr;
        in_grad = grad;
        @(posedge clock);
        while (!in_ready) @(posedge clock);
        in_valid = 1'b0;
    endtask
    
    ////////////////////////////////////////////////////////////////////////////////
    // Main test
    ////////////////////////////////////////////////////////////////////////////////
    initial begin
        $display("TEST START");
        $display("THRESHOLD=%0d, SMALL_THRESHOLD=%0d", THRESHOLD, SMALL_THRESHOLD);
        
        error_count = 0;
        clock = 0;
        reset = 1;
        in_valid = 0;
        in_addr = 0;
        in_grad = 0;
        flush = 0;
        
        // Reset
        repeat(10) @(posedge clock);
        reset = 0;
        repeat(5) @(posedge clock);
        
        $display("\n=== TEST 1: Tiny MISS DROP ===");
        // Send 5 tiny gradients to unique addresses (all MISS, all DROP)
        send_grad(32'h1000, 16'sd10);  // abs=10 < 25
        send_grad(32'h1010, 16'sd15);  // abs=15 < 25
        send_grad(32'h1020, 16'sd5);   // abs=5 < 25
        send_grad(32'h1030, -16'sd20); // abs=20 < 25
        send_grad(32'h1040, 16'sd24);  // abs=24 < 25
        repeat(200) @(posedge clock);
        
        if (dram_write_count == 0) begin
            $display("PASS: No DRAM writes (all tiny MISSes dropped)");
        end else begin
            $display("LOG: %0t : ERROR : test1 : dram_write_count : expected_value: 0 actual_value: %0d", 
                     $time, dram_write_count);
            error_count++;
        end
        
        $display("\n=== TEST 2: Tiny HIT accumulate ===");
        // Allocate with normal gradient
        send_grad(32'h2000, 16'sd30);  // abs=30 >= 25, allocates
        // Send tiny gradients to SAME address (HIT - should accumulate)
        send_grad(32'h2000, 16'sd10);  // HIT, accumulates
        send_grad(32'h2000, 16'sd10);  // HIT, accumulates  
        send_grad(32'h2000, 16'sd10);  // HIT, accumulates
        send_grad(32'h2000, 16'sd10);  // HIT, accumulates
        send_grad(32'h2000, 16'sd10);  // HIT, accumulates
        send_grad(32'h2000, 16'sd10);  // HIT, accumulates
        send_grad(32'h2000, 16'sd10);  // Total=100, should trigger push
        repeat(200) @(posedge clock);
        
        if (dram_write_count == 1) begin
            $display("PASS: Tiny HITs accumulated and pushed (cumulative count=%0d)", dram_write_count);
        end else begin
            $display("LOG: %0t : ERROR : test2 : dram_write_count : expected_value: 1 actual_value: %0d", 
                     $time, dram_write_count);
            error_count++;
        end
        
        $display("\n=== TEST 3: Direct trigger ===");
        // Send large gradient >= THRESHOLD
        send_grad(32'h3000, 16'sd150);  // abs=150 >= 100, direct trigger
        send_grad(32'h3010, -16'sd200); // abs=200 >= 100, direct trigger
        repeat(200) @(posedge clock);
        
        if (dram_write_count == 3) begin
            $display("PASS: Direct triggers pushed (cumulative count=%0d)", dram_write_count);
        end else begin
            $display("LOG: %0t : ERROR : test3 : dram_write_count : expected_value: 3 actual_value: %0d", 
                     $time, dram_write_count);
            error_count++;
        end
        
        $display("\n=== TEST 4: Normal MISS allocate ===");
        // Send gradient: SMALL_THRESHOLD <= abs < THRESHOLD
        send_grad(32'h4000, 16'sd50);  // abs=50, allocates
        send_grad(32'h4000, 16'sd51);  // HIT, accumulates to 101 >= THRESHOLD
        repeat(200) @(posedge clock);
        
        if (dram_write_count == 4) begin
            $display("PASS: Normal allocation and threshold push (cumulative count=%0d)", dram_write_count);
        end else begin
            $display("LOG: %0t : ERROR : test4 : dram_write_count : expected_value: 4 actual_value: %0d", 
                     $time, dram_write_count);
            error_count++;
        end
        
        $display("\n=== TEST 5: Boundary test ===");
        send_grad(32'h5000, 16'sd24);  // abs=24 < 25, DROP
        send_grad(32'h5010, 16'sd25);  // abs=25 == 25, allocate
        send_grad(32'h5020, 16'sd99);  // abs=99 < 100, allocate  
        send_grad(32'h5030, 16'sd100); // abs=100 >= 100, direct trigger
        repeat(200) @(posedge clock);
        
        if (dram_write_count == 5) begin
            $display("PASS: Only direct trigger pushed immediately (cumulative count=%0d)", dram_write_count);
        end else begin
            $display("LOG: %0t : ERROR : test5 : dram_write_count : expected_value: 5 actual_value: %0d", 
                     $time, dram_write_count);
            error_count++;
        end
        
        // Wait for all pending L2/WCB/FIFO writes to drain
        $display("\n=== Waiting for L2 buffer to drain ===");
        repeat(1000) @(posedge clock);
        $display("Final DRAM write count: %0d", dram_write_count);
        
        // Final summary
        $display("\n========================================");
        if (error_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED with %0d errors", error_count);
        end
        $display("========================================");
        
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #50000;
        $display("\nTEST FAILED - Timeout");
        $finish;
    end
    
    // Waveform dump
    initial begin
        $dumpfile("dumpfile.fst");
        $dumpvars(0);
    end

endmodule
