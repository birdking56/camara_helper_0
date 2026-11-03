//-----------------------------------------------------------------------------
// dgc_read_issue.v
//
// Decides which of the four neighbour ports actually issue a cache read.
//
// Frozen reference: 接口冻结规范_v1.md section 8. At the extreme right or bottom
// the two neighbours on that axis are the same point. That point must be read ONCE:
// two ports would present two addresses to the same parity bank in one cycle, and
// the cache can only serve one address per bank.
//
//   no edge      -> p0 p1 p2 p3   (4 distinct points)
//   edge_x       -> p0 p2         (p1 duplicates p0)
//   edge_y       -> p0 p1         (p2 duplicates p0)
//   both         -> p0            (the corner pixel)
//
// The replicated results are restored to all four neighbours by dgc_sample_dedup,
// which is verified separately, so this module only controls the reads.
//-----------------------------------------------------------------------------

module dgc_read_issue (
    input  wire edge_x,
    input  wire edge_y,

    output wire p0_fire,
    output wire p1_fire,
    output wire p2_fire,
    output wire p3_fire,
    output wire [2:0] reads       // how many reads are issued: 1, 2 or 4
);

    assign p0_fire = 1'b1;
    assign p1_fire = ~edge_x;
    assign p2_fire = ~edge_y;
    assign p3_fire = ~edge_x & ~edge_y;

    assign reads = {2'b00, p0_fire} + {2'b00, p1_fire} + {2'b00, p2_fire} + {2'b00, p3_fire};

endmodule
