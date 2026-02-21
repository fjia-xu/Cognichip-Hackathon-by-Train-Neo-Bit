`timescale 1ns/1ps

// =============================================================================
// Testbench: tb_gradient_system_top
// Description: 完全适配 gradient_system_top 最新接口的测试平台
// =============================================================================

module tb_gradient_system_top;

    // =========================================================================
    // Parameters - 严格匹配顶层设计
    // =========================================================================
    localparam int ADDR_WIDTH = 32;  // 注意：32位地址宽度
    localparam int GRAD_WIDTH = 16;
    localparam int CLK_PERIOD = 10;

    // =========================================================================
    // Signal Declarations - 精确匹配端口定义
    // =========================================================================
    logic                        clock;
    logic                        reset;
    
    // DUT 输入信号 (严格按照 gradient_system_top 端口命名)
    logic [ADDR_WIDTH-1:0]       Address_In;
    logic signed [GRAD_WIDTH-1:0] Gradient_In;
    logic                        valid_in;
    logic                        mem_ready;
    
    // DUT 输出信号
    logic [ADDR_WIDTH-1:0]       mem_address;
    logic signed [GRAD_WIDTH-1:0] mem_value;
    logic                        mem_valid;

    // =========================================================================
    // DUT Instantiation - 顶层模块例化
    // =========================================================================
    gradient_system_top #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .GRAD_WIDTH(GRAD_WIDTH)
        // 注意：没有 INDEX_BITS 参数
    ) dut (
        // 使用精确命名端口连接
        .clock(clock),
        .reset(reset),
        .Address_In(Address_In),      // 正确端口名
        .Gradient_In(Gradient_In),    // 正确端口名
        .valid_in(valid_in),          // 正确端口名
        .mem_ready(mem_ready),
        .mem_address(mem_address),
        .mem_value(mem_value),
        .mem_valid(mem_valid)
    );

    // =========================================================================
    // Performance Monitor Instantiation - 性能监控器例化
    // =========================================================================
    bandwidth_perf_monitor #(
        .DATA_BYTES(4)
    ) perf_mon (
        .clock(clock),
        .reset(reset),
        .valid_in(valid_in),          // 共享测试信号
        .mem_valid(mem_valid),        // 共享测试信号
        .mem_ready(mem_ready)         // 共享测试信号
    );

    // =========================================================================
    // Clock Generation
    // =========================================================================
    initial begin
        clock = 0;
        forever #(CLK_PERIOD/2) clock = ~clock;
    end

    // =========================================================================
    // CSV Data Logging
    // =========================================================================
    always_ff @(posedge clock) begin
        if (!reset && valid_in) begin
            $display("[CSV_IN_LOG] %0t,%08x,%0d", $time, Address_In, Gradient_In);
        end
        if (!reset && mem_valid && mem_ready) begin
            $display("[CSV_OUT_LOG] %0t,%08x,%0d", $time, mem_address, mem_value);
        end
    end

    // =========================================================================
    // Test Stimulus Tasks
    // =========================================================================
    
    // 发送单个梯度 (无反压握手，直接发送)
    task automatic send_gradient(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic signed [GRAD_WIDTH-1:0] grad
    );
        @(posedge clock);
        Address_In = addr;
        Gradient_In = grad;
        valid_in = 1'b1;
        @(posedge clock);
        valid_in = 1'b0;
    endtask

    // 等待流水线排空
    task automatic drain_pipeline(input int max_cycles = 200);
        automatic int idle_count = 0;
        valid_in = 1'b0;
        
        while (idle_count < 20 && max_cycles > 0) begin
            @(posedge clock);
            if (mem_valid && mem_ready) begin
                idle_count = 0;
            end else begin
                idle_count++;
            end
            max_cycles--;
        end
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        $display("===========================================");
        $display("   Gradient System Comprehensive Test     ");
        $display("===========================================");
        
        // 初始化信号
        reset = 1;
        Address_In = 0;
        Gradient_In = 0;
        valid_in = 0;
        mem_ready = 1;  // 始终准备好接收
        
        repeat(5) @(posedge clock);
        reset = 0;
        repeat(2) @(posedge clock);

        // =====================================================================
        // Phase 1: 纯累加测试
        // =====================================================================
        $display("\n[PHASE 1] Pure Accumulation Test");
        for (int i = 0; i < 10; i++) begin
            for (int j = 0; j < 32; j++) begin
                send_gradient(32'h00000100 + j, 16'sd4);
            end
        end
        drain_pipeline(200);

        // =====================================================================
        // Phase 2: 高幅度旁路测试
        // =====================================================================
        $display("\n[PHASE 2] High-Magnitude Bypass Test");
        for (int i = 0; i < 320; i++) begin
            send_gradient(32'h00001000 + i, 16'sd100);
        end
        drain_pipeline(400);

        // =====================================================================
        // Phase 3: 混合累加与阈值交叉
        // =====================================================================
        $display("\n[PHASE 3] Mixed Accumulation + Threshold Crossing");
        for (int i = 0; i < 32; i++) begin
            send_gradient(32'h00000200 + i, 16'sd10);
        end
        for (int i = 0; i < 32; i++) begin
            send_gradient(32'h00000200 + i, 16'sd15);
        end
        for (int i = 0; i < 32; i++) begin
            send_gradient(32'h00000200 + i, 16'sd40);
        end
        drain_pipeline(200);

        // =====================================================================
        // Phase 4: 直接映射缓存冲突缺失测试
        // =====================================================================
        $display("\n[PHASE 4] Direct-Mapped Cache Conflict Miss Test");
        // 测试同一个索引，不同标签的地址冲突
        for (int tag = 0; tag < 8; tag++) begin
            for (int rep = 0; rep < 5; rep++) begin
                // 地址格式：[31:8]=tag, [7:0]=index
                send_gradient({24'(tag), 8'h50}, 16'sd8);
            end
        end
        drain_pipeline(200);

        // =====================================================================
        // Phase 5: EMA 动态阈值收敛测试
        // =====================================================================
        $display("\n[PHASE 5] EMA Dynamic Threshold Convergence Test");
        // 发送500个随机梯度，测试阈值自适应
        for (int i = 0; i < 500; i++) begin
            logic [ADDR_WIDTH-1:0] rand_addr;
            logic signed [GRAD_WIDTH-1:0] rand_grad;
            
            rand_addr = 32'h00002000 + $urandom_range(0, 4095);
            
            // 混合大小的梯度值
            case ($urandom_range(2))
                0: rand_grad = $urandom_range(1, 10);      // 小
                1: rand_grad = $urandom_range(20, 50);     // 中
                2: rand_grad = $urandom_range(80, 150);    // 大
                default: rand_grad = 16'sd10;
            endcase
            
            // 随机正负号
            if ($urandom_range(1) == 1) rand_grad = -rand_grad;
            
            send_gradient(rand_addr, rand_grad);
        end
        drain_pipeline(600);

        // =====================================================================
        // 最终排空
        // =====================================================================
        drain_pipeline(500);
        repeat(50) @(posedge clock);
        
        $display("\nTEST PASSED");
        $finish;
    end

    // =========================================================================
    // Performance Report
    // =========================================================================
    final begin
        real compression_ratio;
        real bw_reduction_pct;
        
        if (perf_mon.compressed_output_tx_count > 0)
            compression_ratio = $itor(perf_mon.raw_input_tx_count) / 
                               $itor(perf_mon.compressed_output_tx_count);
        else
            compression_ratio = 0.0;
            
        if (perf_mon.raw_input_tx_count > 0)
            bw_reduction_pct = (1.0 - ($itor(perf_mon.compressed_output_tx_count) / 
                                       $itor(perf_mon.raw_input_tx_count))) * 100.0;
        else
            bw_reduction_pct = 0.0;

        $display("\n===========================================");
        $display("   Gradient System Performance Report      ");
        $display("===========================================");
        $display("Raw Input Transactions  : %0d (%0d Bytes)", 
                 perf_mon.raw_input_tx_count, perf_mon.get_raw_bytes());
        $display("Output Writes to Memory : %0d (%0d Bytes)", 
                 perf_mon.compressed_output_tx_count, perf_mon.get_compressed_bytes());
        $display("-------------------------------------------");
        $display("Bandwidth Reduction     : %0.2f %%", bw_reduction_pct);
        $display("Compression Ratio       : %0.2f x", compression_ratio);
        $display("===========================================\n");
    end

    // =========================================================================
    // Waveform Dump
    // =========================================================================
    initial begin
        $dumpfile("dumpfile.fst");
        $dumpvars(0);
    end

endmodule
