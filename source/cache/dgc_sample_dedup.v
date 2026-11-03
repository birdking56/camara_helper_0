//-----------------------------------------------------------------------------
// dgc_sample_dedup.v
//
// Maps the (up to four) cache read results back onto the four bilinear
// neighbours, replicating where an edge made two neighbours the same point.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   sx1 = min(sx0+1,1919), sy1 = min(sy0+1,1079), so at the extreme right or
//   bottom the two neighbours on that axis are the SAME point.
//
// Two consequences the hardware must respect:
//
//   1. That point is read ONCE. Reading it twice would send two different
//      addresses to the same parity bank in one cycle, which the cache cannot
//      serve - it has one address per bank per cycle.
//   2. The single result is replicated to both neighbours before interpolation.
//      Replicating is also what keeps an identity mapping from losing the last
//      row or column: with wx = 0 the (1-wx) weight carries the whole value.
//
// This module is the replication half; `need` tells the sampler how many distinct
// points to fetch, and `dup` tells the checker how many results are reused.
//-----------------------------------------------------------------------------

module dgc_sample_dedup (
    input  wire        edge_x,      // sx1 == sx0
    input  wire        edge_y,      // sy1 == sy0

    input  wire [23:0] r00,         // distinct results, as fetched
    input  wire [23:0] r10,
    input  wire [23:0] r01,
    input  wire [23:0] r11,

    output wire [23:0] p00,
    output wire [23:0] p10,
    output wire [23:0] p01,
    output wire [23:0] p11,
    output wire [2:0]  need,        // distinct points to fetch: 1, 2 or 4
    output wire [2:0]  dup          // reused results: 0, 2 or 3
);

    // 4 distinct points when neither axis is at the edge
    // 2 when one axis collapses, 1 when both do
    assign need = (edge_x && edge_y) ? 3'd1 :
                  (edge_x || edge_y) ? 3'd2 : 3'd4;
    assign dup  = 3'd4 - need;

    // replicate along x first, then along y; the two are independent so the order
    // does not matter, but writing it this way makes that obvious
    wire [23:0] m00 = r00;
    wire [23:0] m10 = edge_x ? r00 : r10;
    wire [23:0] m01 = r01;
    wire [23:0] m11 = edge_x ? r01 : r11;

    assign p00 = m00;
    assign p10 = m10;
    assign p01 = edge_y ? m00 : m01;
    assign p11 = edge_y ? m10 : m11;

endmodule
