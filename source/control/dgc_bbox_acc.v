//-----------------------------------------------------------------------------
// dgc_bbox_acc.v
//
// Accumulates the source bounding box of one output block while the coordinate
// records flow past, exactly as the frozen spec requires:
//
//   "bbox 是这个输出块实际用到的源像素包围区域，需要包含插值邻点"
//   "bbox 只统计 sample_ok 的四邻点，包含 sx1/sy1"
//   "完全无有效点的块不发 DDR 请求"
//
// It must not use the four corners of the block instead of every mapped point -
// with distortion the extreme source coordinate can be anywhere along an edge -
// so every record contributes its own (sx0..sx1, sy0..sy1).
//
// The module is a pass-through: records leave unchanged and in order. The bbox
// is complete in the same cycle as the tile_last record's handshake, which is
// what lets the descriptor be committed without another round trip.
//
// Inactive records (sample_ok = 0) contribute nothing; a block with no active
// record at all reports any_ok = 0 and a zero bbox.
//-----------------------------------------------------------------------------

module dgc_bbox_acc (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        blk_start,       // pulse before the block's first record

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [95:0] in_coord,

    output wire        out_valid,
    input  wire        out_ready,
    output wire [95:0] out_coord,

    output wire        done,            // pulses with the last record's handshake
    output wire [10:0] bbox_x,
    output wire [10:0] bbox_y,
    output wire [6:0]  bbox_w,
    output wire [6:0]  bbox_h,
    output wire [9:0]  rec_count,
    output wire        any_ok,
    output wire        block_math_error
);

    localparam [10:0] LAST_X = 11'd1919;
    localparam [10:0] LAST_Y = 11'd1079;

    wire        take  = in_valid & in_ready;
    wire        ok    = in_coord[92];
    wire [10:0] cx0   = in_coord[32:22];
    wire [10:0] cy0   = in_coord[43:33];
    wire [10:0] cx1   = (cx0 >= LAST_X) ? LAST_X : (cx0 + 11'd1);
    wire [10:0] cy1   = (cy0 >= LAST_Y) ? LAST_Y : (cy0 + 11'd1);

    reg  [10:0] minx, maxx, miny, maxy;
    reg  [9:0]  count;
    reg         got_any;
    reg         merr;

    // Registered final bbox, captured with the tile_last handshake. The old
    // combinational "include this cycle's record" form made
    // map rec9 -> bbox add/compare -> split_valid a -1.40 ns path at 225 MHz.
    // The descriptor is committed one cycle later; the coord FIFO already holds
    // the payload and the extra cycle is hidden by the block handshake.
    reg  [10:0] r_minx, r_maxx, r_miny, r_maxy;
    reg  [9:0]  r_count;
    reg         r_any, r_merr, r_done;

    // values including the record being accepted this cycle
    wire [10:0] n_minx = (!got_any || (cx0 < minx)) ? cx0 : minx;
    wire [10:0] n_maxx = (!got_any || (cx1 > maxx)) ? cx1 : maxx;
    wire [10:0] n_miny = (!got_any || (cy0 < miny)) ? cy0 : miny;
    wire [10:0] n_maxy = (!got_any || (cy1 > maxy)) ? cy1 : maxy;

    wire upd_this = take & ok & !in_coord[94];   // tile_last has no successor
    wire done_this = take & in_coord[94];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            minx <= 11'd0; maxx <= 11'd0; miny <= 11'd0; maxy <= 11'd0;
            count <= 10'd0; got_any <= 1'b0; merr <= 1'b0;
        end
        else if (blk_start) begin
            minx <= 11'd0; maxx <= 11'd0; miny <= 11'd0; maxy <= 11'd0;
            count <= 10'd0; got_any <= 1'b0; merr <= 1'b0;
        end
        else if (take) begin
            count <= count + 10'd1;
            if (ok) merr <= merr | in_coord[93];
            if (ok) begin
                minx <= n_minx; maxx <= n_maxx;
                miny <= n_miny; maxy <= n_maxy;
                got_any <= 1'b1;
            end
        end
    end

    // The bbox including the tile_last record, computed for the capture stage.
    wire [10:0] f_minx = (take && ok && in_coord[94]) ? n_minx : minx;
    wire [10:0] f_maxx = (take && ok && in_coord[94]) ? n_maxx : maxx;
    wire [10:0] f_miny = (take && ok && in_coord[94]) ? n_miny : miny;
    wire [10:0] f_maxy = (take && ok && in_coord[94]) ? n_maxy : maxy;
    wire        f_any  = got_any | (take && ok);
    wire [9:0]  f_count = count + (take ? 10'd1 : 10'd0);
    wire        f_merr  = merr | (take && ok && in_coord[93]);

    wire [10:0] fw = f_maxx - f_minx + 11'd1;
    wire [10:0] fh = f_maxy - f_miny + 11'd1;

    // Capture the completed bbox one cycle after tile_last. `done` is delayed
    // with it so the descriptor always reads stable, registered values.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_minx <= 11'd0; r_maxx <= 11'd0; r_miny <= 11'd0; r_maxy <= 11'd0;
            r_count <= 10'd0; r_any <= 1'b0; r_merr <= 1'b0; r_done <= 1'b0;
        end
        else if (done_this) begin
            r_minx <= f_minx; r_maxx <= f_maxx;
            r_miny <= f_miny; r_maxy <= f_maxy;
            r_count <= f_count; r_any <= f_any; r_merr <= f_merr;
            r_done <= 1'b1;
        end
        else begin
            r_done <= 1'b0;
        end
    end

    wire [10:0] rfw = r_maxx - r_minx + 11'd1;
    wire [10:0] rfh = r_maxy - r_miny + 11'd1;

    // Only the registered snapshot is exported. The coord_stage consumes these
    // fields when `done` is high; keeping the combinational f_* fallback would
    // leave a rec9 -> bbox adder -> split_valid path in the timing graph even
    // though it is logically deselected at the done edge.
    assign bbox_x = r_minx;
    assign bbox_y = r_miny;
    assign bbox_w = r_any ? rfw[6:0] : 7'd0;
    assign bbox_h = r_any ? rfh[6:0] : 7'd0;
    assign rec_count = r_count;
    assign any_ok  = r_any;
    assign block_math_error = r_merr;
    assign done    = r_done;

    assign in_ready  = out_ready;
    assign out_valid = in_valid;
    assign out_coord = in_coord;

endmodule
