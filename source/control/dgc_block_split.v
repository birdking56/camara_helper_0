//-----------------------------------------------------------------------------
// dgc_block_split.v
//
// The output-block subdivision rule from the frozen spec section 6:
//
//   "默认输出块 32x16 ... bbox 宽/高超过 64 时，沿较长的输出维度二分，
//    宽度相同时先分 x；一维为 1 时分另一维。"
//
// Reading this correctly matters, and the first implementation got it wrong:
//
//   * the BBOX decides WHETHER a block is split (its mapped source region no
//     longer fits the 64x64 cache container);
//   * the OUTPUT block is what gets bisected. The children are halves of the
//     parent's output extent, and their own bboxes are only known after they are
//     mapped again.
//
// Bisecting the bbox instead produces children LARGER than the parent's output
// block - a 32x16 block with a 65x16 bbox would yield 32x16 + 33x16, which
// overflows the parent's 32-pixel-wide output area and overlaps its neighbour.
// That is why the earlier version was wrong even though its tests passed.
//
// AMBIGUITY, flagged rather than hidden
//   The spec does not say which half takes the remainder when the split output
//   dimension is odd. This implementation gives the floor to the front half and
//   the remainder to the back half, because "深度优先、前半块优先" then makes the
//   left spine shallower. If the intended convention is the other way round,
//   only the two assignments below change.
//-----------------------------------------------------------------------------

module dgc_block_split (
    input  wire [10:0] ow,           // output block width  (32 by default)
    input  wire [10:0] oh,           // output block height (16, or 8 in the last stripe)
    input  wire [6:0]  bw,           // mapped source bbox width
    input  wire [6:0]  bh,           // mapped source bbox height
    output wire        split,        // 0 = the bbox already fits in 64x64
    output wire        split_x,      // 1 = bisect width, 0 = bisect height
    output wire [10:0] a_w, a_h,     // front child output extent
    output wire [10:0] b_w, b_h      // back child output extent
);

    // The bbox decides whether, the output extent decides how. A 1x1 output block
    // cannot be subdivided at all; its bbox can be at most 2x2 because it samples
    // two neighbours per axis, so that case cannot arise from a real mapping and
    // the guard only keeps the arithmetic well defined.
    assign split = ((bw > 7'd64) || (bh > 7'd64)) && ((ow > 11'd1) || (oh > 11'd1));

    // "longer output dimension"; a tie goes to x; a dimension of 1 forces the other
    wire axis_x = (oh == 11'd1) ? 1'b1 :
                  (ow == 11'd1) ? 1'b0 :
                  (ow >= oh)    ? 1'b1 : 1'b0;

    assign split_x = axis_x;

    assign a_w = axis_x ? (ow >> 1)       : ow;
    assign b_w = axis_x ? (ow - (ow >> 1)) : ow;
    assign a_h = axis_x ? oh              : (oh >> 1);
    assign b_h = axis_x ? oh              : (oh - (oh >> 1));

endmodule
