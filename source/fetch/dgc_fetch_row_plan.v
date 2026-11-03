//-----------------------------------------------------------------------------
// dgc_fetch_row_plan.v
//
// Per-row fetch arithmetic for one source block. Combinational: the planner walks
// local_y and asks this module for each row's descriptor.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   start        = frame_base + sy*stride_bytes + 3*bbox_x
//   aligned_addr = start rounded DOWN to 32 bytes
//   head_skip    = start - aligned_addr, so 0..31
//   valid_bytes  = 3 * bbox_width
//   beats_total  = ceil((head_skip + valid_bytes) / 32), and the spec bounds it
//                  to 1..7 because a block is at most 64 wide (192 bytes) and the
//                  head skip is at most 31, so 223 bytes is the worst case
//
// A request must not cross a 4 KiB boundary; that split is the adapter's job, not
// this module's, because it depends on the native burst rules rather than on the
// block geometry.
//-----------------------------------------------------------------------------

module dgc_fetch_row_plan #(
    parameter integer STRIDE_BYTES = 5760
) (
    input  wire [31:0] frame_base,
    input  wire [10:0] bbox_x,        // sx0 of the block
    input  wire [10:0] bbox_y,        // sy0 of the block
    input  wire [6:0]  bbox_w,
    input  wire [6:0]  bbox_h,
    input  wire [5:0]  local_y,       // 0 .. bbox_h-1

    output wire [31:0] start_byte,
    output wire [31:0] aligned_addr,  // 32-byte aligned byte address
    output wire [4:0]  head_skip,
    output wire [7:0]  valid_bytes,
    output wire [4:0]  beats_total,
    output wire        row_last,
    output wire        geom_ok        // 0 if the block exceeds the 1..7 beat bound
);

    // row start byte: frame_base + (bbox_y + local_y) * stride + 3 * bbox_x
    //
    // 2026-10-29 timing: the placed design reported
    //   u_walk/local_y[1] -> row_pack_q[26]  -0.304 ns @180 MHz
    // because bbox_y+local_y fed an 11-bit constant multiply. Distributing it
    // keeps the same arithmetic but shortens the local_y path to a 6-bit
    // constant multiply plus adds:
    //   start = (frame_base + bbox_y*stride + 3*bbox_x) + local_y*stride
    // bbox_y/bbox_x are stable for the whole block, so their product is not on
    // the per-row critical path. s2_fetch_row sweeps every head offset and block
    // width, so the equivalence is checked exhaustively rather than argued.
    wire [31:0] base_off = ({21'd0, bbox_y} * STRIDE_BYTES[31:0]) +
                           ({21'd0, bbox_x} * 32'd3);
    wire [31:0] row_off  = ({26'd0, local_y} * STRIDE_BYTES[31:0]);

    assign start_byte   = frame_base + base_off + row_off;
    assign aligned_addr = {start_byte[31:5], 5'd0};
    assign head_skip    = start_byte[4:0];

    // 3 bytes per pixel. Keep the product in 10 bits: bbox_w is allowed to be
    // larger than 64 at the port (the caller must reject it), and computing the
    // product in 8 bits would silently wrap for w > 85 and make an illegal block
    // look legal.
    wire [9:0] valid_bytes_wide = {3'd0, bbox_w} * 10'd3;
    assign valid_bytes = valid_bytes_wide[7:0];

    // beats = ceil(total / 32) = (total + 31) >> 5
    wire [9:0] total = {2'd0, head_skip} + valid_bytes_wide;
    wire [9:0] beats = (total + 10'd31) >> 5;

    assign beats_total = beats[4:0];
    assign row_last    = (local_y == bbox_h - 6'd1);

    // the frozen bound is 1..7 beats per row, and a source block is at most 64
    // wide and 64 high; anything outside that is reported, never truncated
    assign geom_ok = (bbox_w <= 7'd64) && (bbox_h <= 7'd64) &&
                     (beats >= 10'd1) && (beats <= 10'd7);

endmodule
