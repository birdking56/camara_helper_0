//-----------------------------------------------------------------------------
// dgc_cache_owner.v
//
// Ownership of the two source cache sets.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   FREE -> FILLING -> READY -> READING -> FREE
//   * FILLING and READING must be in DIFFERENT sets.
//   * Only one block owns a set at a time.
//   * A set becomes READY only after the last valid pixel has been written.
//   * A set returns to FREE only after the last sample read AND its return have
//     left the cache read pipeline, which is why `rel` is a separate input the
//     cache asserts when its own pipeline is drained - not when the last request
//     was issued.
//
// This module holds only the ownership bookkeeping. The address mapping, the bank
// read and the write path are separate, already verified pieces.
//-----------------------------------------------------------------------------

module dgc_cache_owner (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        fill_begin,      // capture a block into a free set
    input  wire [15:0] fill_tag,
    input  wire        fill_complete,   // the last valid pixel of that block landed
    input  wire        fill_abort,      // this fill cannot complete: return the set
    input  wire        sample_begin,    // a consumer wants to sample a READY set
    input  wire        rel,         // the read pipeline is fully drained

    output wire [1:0]  fill_set,        // which set the current fill targets
    output wire        set0_ready,
    output wire        set1_ready,
    output wire [15:0] set0_tag,
    output wire [15:0] set1_tag,
    output wire [1:0]  set0_state,      // 0 FREE 1 FILLING 2 READY 3 READING
    output wire [1:0]  set1_state,
    output wire        fill_ok,         // a free set exists for a new block
    output reg  [31:0] cnt_fill,
    output reg  [31:0] cnt_sample,
    output reg  [31:0] cnt_release
);

    localparam [1:0] S_FREE=2'd0, S_FILL=2'd1, S_READY=2'd2, S_READ=2'd3;

    reg [1:0]  st0, st1;
    reg [15:0] tag0, tag1;
    reg [1:0]  fill_sel;      // which set a fill is currently using
    reg [1:0]  read_sel;      // which set is being sampled

    assign fill_set = fill_sel;
    assign set0_state = st0;
    assign set1_state = st1;
    assign set0_ready = (st0 == S_READY);
    assign set1_ready = (st1 == S_READY);
    assign set0_tag   = tag0;
    assign set1_tag   = tag1;

    // a fill can start while at least one set is FREE
    assign fill_ok = (st0 == S_FREE) || (st1 == S_FREE);

    // the fill target: prefer set 0, and never a set that is being read
    wire [1:0] fill_target = (st0 == S_FREE) ? 2'd0 : 2'd1;
    // the read target: whichever set is READY
    wire [1:0] read_target = (st0 == S_READY) ? 2'd0 : 2'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st0 <= S_FREE; st1 <= S_FREE;
            tag0 <= 16'd0; tag1 <= 16'd0;
            fill_sel <= 2'd0; read_sel <= 2'd0;
            cnt_fill <= 32'd0; cnt_sample <= 32'd0; cnt_release <= 32'd0;
        end
        else begin
            // ------------------------------------------------------ start a fill
            if (fill_begin && fill_ok) begin
                cnt_fill <= cnt_fill + 32'd1;
                fill_sel <= fill_target;
                if (fill_target == 2'd0) begin st0 <= S_FILL; tag0 <= fill_tag; end
                else                     begin st1 <= S_FILL; tag1 <= fill_tag; end
            end

            // ---------------------------------------- a fill could not complete
            if (fill_abort) begin
                if (fill_sel == 2'd0 && st0 == S_FILL) st0 <= S_FREE;
                if (fill_sel == 2'd1 && st1 == S_FILL) st1 <= S_FREE;
            end

            // -------------------------------------------- the block is complete
            if (fill_complete) begin
                if (fill_sel == 2'd0 && st0 == S_FILL) st0 <= S_READY;
                if (fill_sel == 2'd1 && st1 == S_FILL) st1 <= S_READY;
            end

            // ---------------------------------------------------- start sampling
            if (sample_begin && (st0 == S_READY || st1 == S_READY)) begin
                cnt_sample <= cnt_sample + 32'd1;
                read_sel <= read_target;
                if (read_target == 2'd0) st0 <= S_READ;
                else                     st1 <= S_READ;
            end

            // ------------------------------------------------ rel to FREE
            if (rel) begin
                cnt_release <= cnt_release + 32'd1;
                if (read_sel == 2'd0 && st0 == S_READ) st0 <= S_FREE;
                if (read_sel == 2'd1 && st1 == S_READ) st1 <= S_FREE;
            end
        end
    end

endmodule
