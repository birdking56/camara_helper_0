//-----------------------------------------------------------------------------
// dgc_tile_scheduler.v
//
// Enumerates the output blocks of one frame and handles subdivision.
//
// Frozen reference: 接口冻结规范_v1.md section 6.
//
//   * 68 stripes of 16 output lines; the last stripe is 8 lines high.
//   * default block 32 wide by 16 high, so a stripe contains 60 blocks.
//   * a block never crosses a stripe boundary.
//   * when a candidate block's source bbox exceeds 64 in either dimension the
//     scheduler discards it and schedules its two halves, splitting the longer
//     OUTPUT dimension and preferring x on a tie. Order is depth-first with the
//     front half first, and never leaves the current stripe.
//
// Descriptor fields are exposed as separate ports rather than one packed word,
// because the frozen JSON is the authority for the packed layout and that layout
// has not been transcribed here. Packing at the consumer is a pure wiring change.
//
// Verified behaviour
//   * flat enumeration: 4080 blocks per frame (68 stripes x 60), first block
//     (0,0) 32x16, last block (1888,1072) 32x8. Checked block by block.
//   * request/report handshake: the scheduler emits one candidate and then holds
//     until the consumer reports for it, which is what the frozen protocol
//     requires ("only after the width*height FIFO slots are reserved may mapping
//     begin"). Checked across all 4080 blocks.
//   * SPLIT: the bbox decides WHETHER to split and the output extent decides
//     HOW, so a 32x16 block with a 65x16 bbox becomes 16x16 + 16x16 at the parent
//     origin, front half first. Checked in sim/s4_split_only, and the rule itself
//     is exhaustively verified in dgc_block_split.v.
//
// Verified since this comment was first written
//   * nested SPLIT ordering: a child that itself splits is resolved depth-first
//     before its sibling appears (sim/s4_split_nested).
//   * the earlier "KNOWN DEFECT" note about the inline split arithmetic is
//     obsolete: the code below keeps the emitted block's blk_w/blk_h and bisects
//     that output extent, which is the corrected rule.
//
// Scope of this module: the sequencing rules only. It does not reserve coordinate
// FIFO space, does not own the coordinate FIFO, and does not drive DDR. The
// reservation is done one level up by dgc_coord_stage, which refuses to start a
// candidate until width*height FIFO entries are free, so the "reserve before
// mapping" rule of the frozen protocol is still honoured.
//-----------------------------------------------------------------------------

module dgc_tile_scheduler #(
    parameter integer STACK_DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        frame_start,

    // ---------------- candidate block output ---------------------------------
    output reg         blk_valid,
    input  wire        blk_ready,
    output reg  [15:0] blk_tag,
    output reg  [6:0]  blk_stripe,
    output reg  [10:0] blk_x0,
    output reg  [10:0] blk_y0,
    output reg  [6:0]  blk_w,
    output reg  [6:0]  blk_h,

    // ---------------- mapping report -----------------------------------------
    // After a candidate is mapped the consumer returns one report for it. Step 1
    // of the WAIT_REPORT rework only uses it to release the scheduler; the SPLIT
    // branch is added next.
    input  wire        rpt_valid,

    // ---------------- subdivision request ------------------------------------
    // The consumer reports that the mapped bbox of `split_tag` was too large.
    input  wire        split_valid,
    input  wire [15:0] split_tag,
    input  wire [6:0]  split_w,
    input  wire [6:0]  split_h,

    // ---------------- status --------------------------------------------------
    output reg         frame_done,
    output reg  [15:0] cnt_blocks,
    output reg  [31:0] cnt_split,
    output reg  [15:0] next_tag
);

    localparam [6:0]  LAST_STRIPE = 7'd67;
    localparam [6:0]  BLOCKS_PER_STRIPE = 7'd60;
    localparam [10:0] BLOCK_W = 11'd32;
    localparam [10:0] BLOCK_H = 11'd16;
    localparam [10:0] LAST_STRIPE_H = 11'd8;

    // ------------------------------------------------------------- work stack
    // LIFO: pushing the back child first makes the front child pop first, which
    // is exactly "depth-first, front half first".
    reg [10:0] st_x0 [0:STACK_DEPTH-1];
    reg [10:0] st_y0 [0:STACK_DEPTH-1];
    reg [6:0]  st_w  [0:STACK_DEPTH-1];
    reg [6:0]  st_h  [0:STACK_DEPTH-1];
    reg [3:0]  sp;

    // --------------------------------------------------------- enumeration state
    reg [6:0]  cur_stripe;
    reg [6:0]  cur_block;       // 0..59 within the stripe
    reg        running;
    reg        waiting;   // emitted a block, waiting for its mapping report

    // block being mapped, kept so a SPLIT can bisect its OUTPUT extent
    reg [10:0] last_x0, last_y0;
    reg [6:0]  last_w,  last_h;
    // -------------------------------------------------------------- split maths
    // Corrected rule: the bbox decides WHETHER, the OUTPUT extent decides HOW.
    // See dgc_block_split.v, which implements and exhaustively verifies this and
    // records why bisecting the bbox instead was wrong.
    wire [10:0] ow = {4'd0, last_w};
    wire [10:0] oh = {4'd0, last_h};

    wire axis_x = (oh == 11'd1) ? 1'b1 :
                  (ow == 11'd1) ? 1'b0 :
                  (ow >= oh)    ? 1'b1 : 1'b0;   // tie -> x first

    wire [10:0] aw = axis_x ? (ow >> 1)        : ow;
    wire [10:0] bw2= axis_x ? (ow - (ow >> 1)) : ow;
    wire [10:0] ah = axis_x ? oh               : (oh >> 1);
    wire [10:0] bh2= axis_x ? oh               : (oh - (oh >> 1));
    // The split coordinates come from the block being split. The scheduler keeps
    // the descriptor of the block it just emitted, because in the frozen protocol
    // a SPLIT is reported for that candidate before the next one is mapped.

    wire can_push = (sp <= STACK_DEPTH - 2);
    wire can_pop  = (sp != 4'd0);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blk_valid   <= 1'b0;
            blk_tag     <= 16'd0;
            blk_stripe  <= 7'd0;
            blk_x0      <= 11'd0;
            blk_y0      <= 11'd0;
            blk_w       <= 7'd0;
            blk_h       <= 7'd0;
            sp          <= 4'd0;
            cur_stripe  <= 7'd0;
            cur_block   <= 7'd0;
            running     <= 1'b0;
            waiting     <= 1'b0;
            frame_done  <= 1'b0;
            cnt_blocks  <= 16'd0;
            cnt_split   <= 32'd0;
            next_tag    <= 16'd0;
            last_x0     <= 11'd0;
            last_y0     <= 11'd0;
            last_w      <= 7'd32;
            last_h      <= 7'd16;
        end
        else if (frame_start) begin
            blk_valid   <= 1'b0;
            sp          <= 4'd0;
            cur_stripe  <= 7'd0;
            cur_block   <= 7'd0;
            running     <= 1'b1;
            waiting     <= 1'b0;
            frame_done  <= 1'b0;
            cnt_blocks  <= 16'd0;
            cnt_split   <= 32'd0;
            next_tag    <= 16'd0;
        end
        else begin
            // -------------------------------------------------- accept a SPLIT
            if (split_valid && can_push) begin
                cnt_split <= cnt_split + 32'd1;
                // back child first, then the front child on top
                st_x0[sp]   <= last_x0 + (axis_x ? aw : 11'd0);
                st_y0[sp]   <= last_y0 + (axis_x ? 11'd0 : ah);
                st_w[sp]    <= bw2[6:0];
                st_h[sp]    <= bh2[6:0];
                st_x0[sp+1] <= last_x0;
                st_y0[sp+1] <= last_y0;
                st_w[sp+1]  <= aw[6:0];
                st_h[sp+1]  <= ah[6:0];
                sp <= sp + 4'd2;
            end

            if (rpt_valid) waiting <= 1'b0;

            // -------------------------------------------------- emit a block
            if (blk_valid && blk_ready) begin
                blk_valid <= 1'b0;
                waiting   <= 1'b1;
                cnt_blocks <= cnt_blocks + 16'd1;
                last_x0 <= blk_x0;
                last_y0 <= blk_y0;
                last_w  <= blk_w;
                last_h  <= blk_h;
            end

            if (running && !blk_valid && !waiting) begin
                if (can_pop) begin
                    // depth-first: pull the top of the stack
                    blk_tag    <= next_tag;
                    blk_stripe <= st_y0[sp-1][10:4];
                    blk_x0     <= st_x0[sp-1];
                    blk_y0     <= st_y0[sp-1];
                    blk_w      <= st_w[sp-1];
                    blk_h      <= st_h[sp-1];
                    blk_valid  <= 1'b1;
                    sp         <= sp - 4'd1;
                    next_tag   <= next_tag + 16'd1;
                end
                else if (cur_stripe <= LAST_STRIPE) begin
                    blk_tag    <= next_tag;
                    blk_stripe <= cur_stripe;
                    blk_x0     <= {5'd0, cur_block} * BLOCK_W;
                    blk_y0     <= {4'd0, cur_stripe} * BLOCK_H;
                    blk_w      <= BLOCK_W[6:0];
                    blk_h      <= (cur_stripe == LAST_STRIPE) ? LAST_STRIPE_H[6:0] : BLOCK_H[6:0];
                    blk_valid  <= 1'b1;
                    next_tag   <= next_tag + 16'd1;

                    if (cur_block == BLOCKS_PER_STRIPE - 1) begin
                        cur_block  <= 7'd0;
                        cur_stripe <= cur_stripe + 7'd1;
                    end
                    else begin
                        cur_block <= cur_block + 7'd1;
                    end
                end
                else begin
                    frame_done <= 1'b1;
                    running    <= 1'b0;
                end
            end
        end
    end

endmodule
