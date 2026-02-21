// Simple debug testbench to check basic handshake
module tb_gradient_debug;

    localparam CLK_PERIOD = 10;
    
    logic clock;
    logic reset;
    logic in_valid;
    logic in_ready;
    logic [31:0] in_addr;
    logic signed [15:0] in_grad;
    logic dram_valid;
    logic dram_ready;
    logic [31:0] dram_addr;
    logic signed [31:0] dram_value;
    logic flush;
    logic idle;
    
    // Clock
    initial begin
        clock = 0;
        forever #(CLK_PERIOD/2) clock = ~clock;
    end
    
    // DUT
    gradient_compressor_top #(
        .ADDR_WIDTH(32),
        .GRAD_WIDTH(16),
        .INDEX_BITS(4),
        .NUM_WAYS(4),
        .MAX_UPDATES(10),
        .THRESHOLD(32'sd50),
        .WCB_ENTRIES(8),
        .FIFO_DEPTH(32),
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
    
    // DRAM always ready
    assign dram_ready = 1'b1;
    
    // Test
    initial begin
        $display("TEST START");
        $display("Debug Testbench - Checking basic handshake");
        
        // Init
        reset = 1;
        in_valid = 0;
        in_addr = 0;
        in_grad = 0;
        flush = 0;
        
        // Reset
        repeat(5) @(posedge clock);
        reset = 0;
        $display("Time %0t: Reset released", $time);
        
        repeat(2) @(posedge clock);
        $display("Time %0t: After reset, in_ready=%b", $time, in_ready);
        
        // Try to send data
        @(posedge clock);
        in_valid = 1;
        in_addr = 32'h1000;
        in_grad = 16'sd100;  // Large gradient - direct trigger
        $display("Time %0t: Setting in_valid=1", $time);
        
        // Wait and check
        repeat(10) begin
            @(posedge clock);
            $display("Time %0t: in_ready=%b in_valid=%b dram_valid=%b state=%0d", 
                     $time, in_ready, in_valid, dram_valid, dut.u_accumulator.u_l1.state);
            if (in_ready) begin
                $display("Time %0t: HANDSHAKE SUCCESS - in_ready went high!", $time);
                in_valid = 0;
                break;
            end
        end
        
        if (!in_ready) begin
            $display("ERROR: in_ready never went high!");
            $display("ERROR");
            $fatal(1, "Handshake failed");
        end
        
        // Wait for completion
        repeat(50) @(posedge clock);
        
        if (dram_valid || dut.u_accumulator.u_l2.fifo_count > 0) begin
            $display("SUCCESS: Data propagated to L2/DRAM");
            $display("TEST PASSED");
        end else begin
            $display("ERROR: Data did not propagate");
            $display("ERROR");
        end
        
        $finish;
    end
    
    // Waveform dump
    initial begin
        $dumpfile("dumpfile.fst");
        $dumpvars(0);
    end
    
    // Timeout
    initial begin
        #10000;
        $display("ERROR: Timeout");
        $fatal(1, "Simulation timeout");
    end

endmodule
