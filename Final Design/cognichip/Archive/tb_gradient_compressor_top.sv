`timescale 1ns/1ps

module tb_gradient_compressor_top;

    // Hardware parameters updated per requirements
    localparam int ADDR_WIDTH = 16;
    localparam int GRAD_WIDTH = 16;
    localparam int INDEX_BITS = 5;
    localparam int CLK_PERIOD = 10;
    
    // Derived DUT parameters to match original compressor
    localparam int NUM_WAYS = 4;
    localparam int DEPTH = (2**INDEX_BITS) * NUM_WAYS; // 128
    localparam int MAX_UPDATES = 255;
    localparam int THRESHOLD_VAL = 50;
    localparam int FIFO_DEPTH = 32;
    localparam int BURST_SIZE = 16;

    // Internal signals
    logic                        clock;
    logic                        reset;
    logic [ADDR_WIDTH-1:0]       core_address;
    logic signed [GRAD_WIDTH-1:0] core_gradient;
    logic                        core_valid;
    logic [GRAD_WIDTH-1:0]       threshold;
    
    logic [ADDR_WIDTH-1:0]       mem_address;
    logic signed [GRAD_WIDTH-1:0] mem_value;
    logic                        mem_valid;
    logic                        mem_ready;

    // --- NEW: Wrapper adaptation logic moved to TB ---
    logic rst_n;
    assign rst_n = ~reset;

    logic [31:0] in_addr_32bit;
    assign in_addr_32bit = {{(32-ADDR_WIDTH){1'b0}}, core_address};

    logic [31:0] mem_addr_32bit;
    logic signed [31:0] mem_value_32bit;
    assign mem_address = mem_addr_32bit[ADDR_WIDTH-1:0];
    assign mem_value = mem_value_32bit[GRAD_WIDTH-1:0];
    // -------------------------------------------------

    // Instantiate directly to top-level accumulator
    gradient_accumulator #(
        .DEPTH(DEPTH),
        .NUM_WAYS(NUM_WAYS),
        .THRESHOLD(32'(THRESHOLD_VAL)),
        .MAX_UPDATES(MAX_UPDATES),
        .FIFO_DEPTH(FIFO_DEPTH),
        .BURST_SIZE(BURST_SIZE)
    ) dut (
        .clk(clock),
        .rst_n(rst_n),
        .in_valid(core_valid),
        .in_addr(in_addr_32bit),
        .in_grad(core_gradient),
        
        .dram_valid(mem_valid),
        .dram_addr(mem_addr_32bit),
        .dram_value(mem_value_32bit),
        .dram_ready(mem_ready),
        
        // Debug ports left unconnected for this general TB
        .debug_wb_direct(),
        .debug_wb_accum_threshold(),
        .debug_wb_max_updates(),
        .debug_wb_eviction(),
        .debug_hit(),
        .debug_miss(),
        .debug_fifo_count(),
        .debug_burst_ready(),
        .debug_fifo_full(),
        .debug_draining()
    );

    // Instantiate performance monitor
    bandwidth_perf_monitor #(
        .DATA_BYTES(4)
    ) perf_mon (
        .clock(clock),
        .reset(reset),
        .valid_in(core_valid), // Count all valid input transactions
        .mem_valid(mem_valid),
        .mem_ready(mem_ready)
    );

    // Data logging module
    always_ff @(posedge clock) begin
        if (!reset && core_valid) begin
            $display("[CSV_IN_LOG] %0t,%04x,%0d", $time, core_address, core_gradient);
        end
        if (!reset && mem_valid && mem_ready) begin
            $display("[CSV_OUT_LOG] %0t,%04x,%0d", $time, mem_address, mem_value);
        end
    end

    // Clock and driver tasks
    initial begin
        clock = 0;
        forever #(CLK_PERIOD/2) clock = ~clock;
    end

    // Send gradient task (simplified without backpressure)
    task automatic send_gradient(input logic [ADDR_WIDTH-1:0] addr, input logic signed [GRAD_WIDTH-1:0] grad);
        core_address <= addr;
        core_gradient <= grad;
        core_valid <= 1'b1;
        @(posedge clock);
        core_valid <= 1'b0;
    endtask

    task automatic send_idle(input int cycles);
        core_valid <= 1'b0;
        repeat(cycles) @(posedge clock);
    endtask

    // Main test sequence
    initial begin
        $display("===========================================");
        $display("   Starting High-Volume Stress Testbench   ");
        $display("===========================================");
        
        reset = 1;
        core_address = 0;
        core_gradient = 0;
        core_valid = 0;
        threshold = 16'd50; 
        mem_ready = 1;
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);
        
        // Phase 1: Pure accumulation phase
        for (int i = 0; i < 10; i++) begin
            for (int j = 0; j < 32; j++) begin
                send_gradient(16'h0100 + j, 16'sd4);
            end
        end

        // Phase 2: Outlier bypass phase
        for (int i = 0; i < 320; i++) begin
            send_gradient(16'h1000 + i, 16'sd100);
        end

        // Phase 3: Address conflict and eviction phase
        for (int i = 0; i < 32; i++) begin
            send_gradient(16'h0200 + i, 16'sd10);
        end
        for (int i = 0; i < 32; i++) begin
            send_gradient(16'h0300 + i, 16'sd15);
        end

        // Phase 4: Accumulation overflow eviction phase
        for (int i = 0; i < 32; i++) begin
            send_gradient(16'h0300 + i, 16'sd40);
        end

        // Phase 5: Full capacity and forced eviction phase
        // 目标：对全部 32 个 Set，每个 Set 分别写入 5 个不同 Tag 的地址，强制触发 Round-Robin 驱逐。
        
        // 第 1 轮：填满所有 Set 的 Way 0
        for (int i = 0; i < 32; i++) begin
            send_gradient(16'h0400 + i, 16'sd5);
        end
        // 第 2 轮：填满所有 Set 的 Way 1
        for (int i = 0; i < 32; i++) begin
            send_gradient(16'h0500 + i, 16'sd5);
        end
        // 第 3 轮：填满所有 Set 的 Way 2
        for (int i = 0; i < 32; i++) begin
            send_gradient(16'h0600 + i, 16'sd5);
        end
        // 第 4 轮：填满所有 Set 的 Way 3 (此时 Buffer 达到 100% 满载)
        for (int i = 0; i < 32; i++) begin
            send_gradient(16'h0700 + i, 16'sd5);
        end
        
        // 第 5 轮：Cache 容量达到上限，此轮写入必然触发 Eviction (驱逐 Way 0 旧数据入队 FIFO)
        for (int i = 0; i < 32; i++) begin
            send_gradient(16'h0800 + i, 16'sd8);
        end

        // Phase 6: MAX_UPDATES forced flush phase
        // 目标：连续累加超过 MAX_UPDATES (255次)，观察第 255 次清空 Entry 后，系统的重建能力。
        for (int i = 0; i < 260; i++) begin
            send_gradient(16'h0A00, 16'sd2);
        end

        // Drain pipeline
        send_idle(20);
        $finish;
    end

    // Performance report generation
    final begin
        real compression_ratio;
        real bw_reduction_pct;
        
        if (perf_mon.compressed_output_tx_count > 0)
            compression_ratio = $itor(perf_mon.raw_input_tx_count) / $itor(perf_mon.compressed_output_tx_count);
        else
            compression_ratio = 0.0;
            
        if (perf_mon.raw_input_tx_count > 0)
            bw_reduction_pct = (1.0 - ($itor(perf_mon.compressed_output_tx_count) / $itor(perf_mon.raw_input_tx_count))) * 100.0;
        else
            bw_reduction_pct = 0.0;

        $display("\n===========================================");
        $display("   Gradient Compressor Performance Report  ");
        $display("===========================================");
        $display("Raw Input Transactions  : %0d (%0d Bytes)", perf_mon.raw_input_tx_count, perf_mon.get_raw_bytes());
        $display("Output Writes to Memory : %0d (%0d Bytes)", perf_mon.compressed_output_tx_count, perf_mon.get_compressed_bytes());
        $display("-------------------------------------------");
        $display("Bandwidth Reduction     : %0.2f %%", bw_reduction_pct);
        $display("Compression Ratio       : %0.2f x", compression_ratio);
        $display("===========================================\n");
    end

    initial begin
        $dumpfile("./Archive/t2/top_sim.fst");
        $dumpvars(0, tb_gradient_compressor_top);
    end

endmodule