//-----------------------------------------------------------------------------
// dgc_neighbour_calc.v
//
// The four bilinear neighbours of one sampled pixel, in block-local coordinates.
// Combinational so that it can be exhaustively verified.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   sx1 = min(sx0+1, 1919)     sy1 = min(sy0+1, 1079)
//   "最右/最下边界重复邻点，避免恒等映射丢掉边缘" - at the extreme right or
//   bottom edge the neighbour is duplicated rather than clamped away, so an
//   identity mapping keeps its edge pixels instead of losing them.
//
//   The four neighbours are (sx0,sy0) (sx1,sy0) (sx0,sy1) (sx1,sy1), addressed
//   relative to the block origin because that is how the source cache is laid out.
//
// A coordinate whose sample_ok is 0 must produce no neighbour at all: `active` is
// low and the caller must not touch the cache.
//
// The cache read discipline follows from this: when edge_x is set the two x
// neighbours are the same point, so the caller reads three distinct points, not
// four, and replicates. Sending the same bank two different addresses in one cycle
// would break the one-address-per-bank rule the cache relies on.
//-----------------------------------------------------------------------------

module dgc_neighbour_calc (
    input  wire [10:0] sx0,
    input  wire [10:0] sy0,
    input  wire [10:0] bbox_x,
    input  wire [10:0] bbox_y,
    input  wire        sample_ok,

    output wire [10:0] sx1,
    output wire [10:0] sy1,
    output wire [5:0]  lx0,
    output wire [5:0]  ly0,
    output wire [5:0]  lx1,
    output wire [5:0]  ly1,
    output wire        edge_x,
    output wire        edge_y,
    output wire        active,
    output wire        in_block
);

    localparam [10:0] LAST_X = 11'd1919;
    localparam [10:0] LAST_Y = 11'd1079;

    assign sx1 = (sx0 >= LAST_X) ? LAST_X : (sx0 + 11'd1);
    assign sy1 = (sy0 >= LAST_Y) ? LAST_Y : (sy0 + 11'd1);

    assign edge_x = (sx0 >= LAST_X);
    assign edge_y = (sy0 >= LAST_Y);

    wire [10:0] dx0 = sx0 - bbox_x;
    wire [10:0] dy0 = sy0 - bbox_y;
    wire [10:0] dx1 = sx1 - bbox_x;
    wire [10:0] dy1 = sy1 - bbox_y;

    assign lx0 = dx0[5:0];
    assign ly0 = dy0[5:0];
    assign lx1 = dx1[5:0];
    assign ly1 = dy1[5:0];

    assign active = sample_ok;

    // both neighbours must fall inside the 64x64 container, which is only true
    // when the block really contains this point
    assign in_block = (dx0 <= 11'd63) && (dy0 <= 11'd63) &&
                      (dx1 <= 11'd63) && (dy1 <= 11'd63);

endmodule
