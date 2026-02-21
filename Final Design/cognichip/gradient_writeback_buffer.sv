// FILE: gradient_writeback_buffer.sv
// Writeback FIFO Buffer (L2 Write-Combining Layer)
//
// Purpose:
// - Decouple accumulator writeback from DRAM bandwidth
// - Buffer multiple writebacks before issuing DRAM transactions
// - Burst writebacks when FIFO reaches BURST_SIZE
//
// Parameters:
// - FIFO_DEPTH: total FIFO entries (default 32)
// - BURST_SIZE: trigger DRAM burst when count >= BURST_SIZE (default 16)
//
// Behavior:
// - Push from accumulator: wb_push_valid + wb_push_addr + wb_push_value
// - wb_push_ready=0 when FIFO full (backpressure to accumulator)
// - DRAM side: dram_valid asserted when ready to send and dram_ready=1
// - Burst trigger: when FIFO count >= BURST_SIZE, start draining to DRAM

module gradient_writeback_buffer #(
    parameter int FIFO_DEPTH = 32,
    parameter int BURST_SIZE = 16
) (
    input  logic                clk,
    input  logic                rst_n,
    
    // Push interface from accumulator
    input  logic                wb_push_valid,
    input  logic [31:0]         wb_push_addr,
    input  logic signed [31:0]  wb_push_value,
    output logic                wb_push_ready,
    
    // DRAM interface
    output logic                dram_valid,
    output logic [31:0]         dram_addr,
    output logic signed [31:0]  dram_value,
    input  logic                dram_ready,
    
    // Debug signals for waveform analysis
    output logic [5:0]          debug_fifo_count,
    output logic                debug_burst_ready,
    output logic                debug_fifo_full,
    output logic                debug_draining
);

    localparam int PTR_WIDTH = $clog2(FIFO_DEPTH);
    
    // FIFO storage arrays
    logic [31:0]         fifo_addr [FIFO_DEPTH];
    logic signed [31:0]  fifo_value [FIFO_DEPTH];
    
    // FIFO pointers
    logic [PTR_WIDTH:0]  wr_ptr;  // Write pointer (extra bit for full/empty detection)
    logic [PTR_WIDTH:0]  rd_ptr;  // Read pointer
    logic [PTR_WIDTH:0]  count;   // Number of entries in FIFO
    
    // FIFO status flags
    logic fifo_full;
    logic fifo_empty;
    logic burst_ready;
    
    assign fifo_full = (count == FIFO_DEPTH);
    assign fifo_empty = (count == 0);
    assign burst_ready = (count >= BURST_SIZE);
    
    // Push ready: FIFO not full
    assign wb_push_ready = !fifo_full;
    
    // DRAM valid: trigger burst writeback
    // Strategy: Only start writing when we have enough data (BURST_SIZE)
    //           OR when FIFO is full (backpressure prevention)
    //           Once started, drain until empty
    logic draining;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            draining <= 1'b0;
        end else begin
            if (burst_ready || fifo_full) begin
                draining <= 1'b1;  // Start burst drain
            end else if (fifo_empty) begin
                draining <= 1'b0;  // Stop when empty
            end
        end
    end
    
    assign dram_valid = draining && !fifo_empty;
    
    // DRAM outputs from FIFO read pointer
    assign dram_addr = fifo_addr[rd_ptr[PTR_WIDTH-1:0]];
    assign dram_value = fifo_value[rd_ptr[PTR_WIDTH-1:0]];
    
    // Push and pop control
    logic do_push;
    logic do_pop;
    
    assign do_push = wb_push_valid && wb_push_ready;
    assign do_pop = dram_valid && dram_ready;
    
    // FIFO pointer and count management
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            // Update write pointer
            if (do_push) begin
                if (wr_ptr[PTR_WIDTH-1:0] == PTR_WIDTH'(FIFO_DEPTH - 1)) begin
                    wr_ptr <= {~wr_ptr[PTR_WIDTH], {PTR_WIDTH{1'b0}}};
                end else begin
                    wr_ptr <= wr_ptr + 1'b1;
                end
            end
            
            // Update read pointer
            if (do_pop) begin
                if (rd_ptr[PTR_WIDTH-1:0] == PTR_WIDTH'(FIFO_DEPTH - 1)) begin
                    rd_ptr <= {~rd_ptr[PTR_WIDTH], {PTR_WIDTH{1'b0}}};
                end else begin
                    rd_ptr <= rd_ptr + 1'b1;
                end
            end
            
            // Update count
            case ({do_push, do_pop})
                2'b10: count <= count + 1'b1;  // Push only
                2'b01: count <= count - 1'b1;  // Pop only
                default: count <= count;        // Both or neither
            endcase
        end
    end
    
    // FIFO data storage
    always_ff @(posedge clk) begin
        if (do_push) begin
            fifo_addr[wr_ptr[PTR_WIDTH-1:0]]  <= wb_push_addr;
            fifo_value[wr_ptr[PTR_WIDTH-1:0]] <= wb_push_value;
        end
    end
    
    // Debug signal outputs
    assign debug_fifo_count = count;
    assign debug_burst_ready = burst_ready;
    assign debug_fifo_full = fifo_full;
    assign debug_draining = draining;

endmodule
