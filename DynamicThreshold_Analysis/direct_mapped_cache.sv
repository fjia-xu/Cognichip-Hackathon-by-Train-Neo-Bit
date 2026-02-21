// Direct-Mapped Cache with Read-Modify-Write Operation
// Performs gradient accumulation with overflow-based eviction in single cycle

module direct_mapped_cache #(
    parameter int ADDR_WIDTH = 32,
    parameter int GRAD_WIDTH = 16,
    parameter int INDEX_BITS = 10,  // 1024 cache entries
    parameter int TAG_BITS = ADDR_WIDTH - INDEX_BITS  // Remaining bits for tag
) (
    // Clock and Reset
    input  logic                        clock,
    input  logic                        reset,
    
    // Input Interface
    input  logic [ADDR_WIDTH-1:0]       Address_In,
    input  logic signed [GRAD_WIDTH-1:0] Gradient_In,
    input  logic                        valid_in,
    
    // Threshold for Overflow Detection
    input  logic [GRAD_WIDTH-1:0]       Threshold,
    
    // Eviction Output Interface
    output logic                        evict_valid,
    output logic [ADDR_WIDTH-1:0]       evict_address,
    output logic signed [GRAD_WIDTH-1:0] evict_value
);

    // Cache storage dimensions
    localparam int CACHE_SIZE = 2**INDEX_BITS;  // 1024 entries
    
    // Cache entry structure
    typedef struct packed {
        logic                        valid;
        logic [TAG_BITS-1:0]         tag;
        logic signed [GRAD_WIDTH-1:0] accumulated_value;
    } cache_entry_t;
    
    // Memory array (array of registers for single-cycle access)
    cache_entry_t cache_mem [CACHE_SIZE-1:0];
    
    // Address decomposition
    logic [INDEX_BITS-1:0] index;
    logic [TAG_BITS-1:0]   tag;
    
    // Cache read outputs (combinational)
    cache_entry_t read_entry;
    
    // Tag comparator output
    logic cache_hit;
    logic cache_miss;
    
    // Integer adder output
    logic signed [GRAD_WIDTH-1:0] sum;
    
    // Overflow check signals
    logic signed [GRAD_WIDTH-1:0] value_to_check;  // Value to check for overflow
    logic [GRAD_WIDTH-1:0] abs_sum;
    logic overflow;
    
    // Write logic signals
    logic signed [GRAD_WIDTH-1:0] write_data;
    logic                        write_enable;
    
    //===========================================
    // Address Decomposition
    //===========================================
    // Extract index (lower bits) and tag (upper bits) from address
    always_comb begin
        index = Address_In[INDEX_BITS-1:0];
        tag   = Address_In[ADDR_WIDTH-1:INDEX_BITS];
    end
    
    //===========================================
    // Memory Array Read (Combinational)
    //===========================================
    // Single-cycle read from cache
    always_comb begin
        read_entry = cache_mem[index];
    end
    
    //===========================================
    // Tag Comparator (Equality Checker)
    //===========================================
    // Compares stored tag with incoming address tag
    // Hit: Valid entry with matching tag
    // Miss: Invalid entry or tag mismatch
    always_comb begin
        cache_hit  = read_entry.valid && (read_entry.tag == tag);
        cache_miss = !cache_hit;
    end
    
    //===========================================
    // Integer Adder (ALU)
    //===========================================
    // Performs accumulation: Sum = Gradient_In + Stored_Value
    // Only valid on cache hit
    always_comb begin
        sum = Gradient_In + read_entry.accumulated_value;
    end
    
    //===========================================
    // Absolute Value Logic (for Overflow Check)
    //===========================================
    // Computes |Sum| or |Gradient_In| using two's complement
    // On cache miss: Check |Gradient_In|
    // On cache hit: Check |Sum|
    
    always_comb begin
        // On cache miss, check the initial gradient value
        // On cache hit, check the accumulated sum
        value_to_check = cache_miss ? Gradient_In : sum;
        
        if (value_to_check < 0) begin
            abs_sum = (~value_to_check) + 1'b1;
        end else begin
            abs_sum = value_to_check;
        end
    end
    
    //===========================================
    // Overflow Check (Comparator)
    //===========================================
    // Checks if |value_to_check| > Threshold
    // If true, eviction is required (only on cache hit)
    // Overflow is only relevant on cache hits
    always_comb begin
        overflow = cache_hit && (abs_sum > Threshold);
    end
    
    //===========================================
    // Write Logic (Data Mux)
    //===========================================
    // Decides what to write into cache slot:
    // - Cache Miss: Write Gradient_In (initial value)
    // - Cache Hit without Overflow: Write Sum (accumulated value)
    // - Cache Hit with Overflow: Invalidate entry (evict)
    always_comb begin
        write_enable = valid_in;  // Write on valid input
        
        if (cache_miss) begin
            // Miss: Store new gradient as initial value
            write_data = Gradient_In;
        end else begin
            // Hit: Store accumulated sum
            write_data = sum;
        end
    end
    
    //===========================================
    // Memory Write (Sequential)
    //===========================================
    // Updates cache memory on clock edge
    always_ff @(posedge clock) begin
        if (reset) begin
            // Clear all cache entries on reset
            for (int i = 0; i < CACHE_SIZE; i++) begin
                cache_mem[i].valid <= 1'b0;
                cache_mem[i].tag   <= '0;
                cache_mem[i].accumulated_value <= '0;
            end
        end else if (write_enable) begin
            if (cache_hit && overflow) begin
                // Overflow: Invalidate the entry (eviction happens via output)
                cache_mem[index].valid <= 1'b0;
                cache_mem[index].tag   <= '0;
                cache_mem[index].accumulated_value <= '0;
            end else begin
                // Normal write: Update cache entry
                cache_mem[index].valid <= 1'b1;
                cache_mem[index].tag   <= tag;
                cache_mem[index].accumulated_value <= write_data;
            end
        end
    end
    
    //===========================================
    // Eviction Output Logic
    //===========================================
    // When overflow occurs, output the evicted value
    always_ff @(posedge clock) begin
        if (reset) begin
            evict_valid   <= 1'b0;
            evict_address <= '0;
            evict_value   <= '0;
        end else begin
            if (valid_in && cache_hit && overflow) begin
                // Eviction triggered
                evict_valid   <= 1'b1;
                evict_address <= Address_In;
                evict_value   <= sum;  // Evict the accumulated sum
            end else begin
                // No eviction
                evict_valid   <= 1'b0;
                evict_address <= '0;
                evict_value   <= '0;
            end
        end
    end

endmodule
