//-----------------------------------------------------------------------------
// dgc_source_cache.v - both cache sets, single-point read
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//   set 0 -> src_tile_bank_0..3, set 1 -> src_tile_bank_4..7, and a block in one
//   set must never be visible from the other.
//
// Built by expanding the verified single-set module rather than writing eight
// banks at once: dgc_cache_set is proven on real DRAM, so this level is only set
// selection and muxing.
//
// The read side is still ONE point per cycle. The four-neighbour read is the next
// increment and is deliberately not mixed in here: both earlier attempts at this
// module failed by adding the eight-bank wiring, the ownership and the four ports
// in one step.
//-----------------------------------------------------------------------------

module dgc_source_cache (
    input  wire        clk, rst_n,

    // fill side, one pixel per beat for now
    input  wire        wr_valid,
    input  wire        wr_set,
    input  wire [5:0]  wr_x, wr_y,
    input  wire [23:0] wr_rgb,
    output wire        wr_ready,

    // single-point read
    input  wire        rd_set,
    input  wire        rd_fire,
    input  wire [5:0]  rd_x, rd_y,
    output wire        rd_valid,
    output wire [23:0] rd_rgb,
    output wire        rd_ready
);

    wire r0, r1, v0, v1;
    wire [23:0] q0, q1;

    dgc_cache_set u_set0 (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid && !wr_set), .wr_ready(r0),
        .wr_x(wr_x), .wr_y(wr_y), .wr_rgb(wr_rgb),
        .rd_fire(rd_fire), .rd_ready(), .rd_x(rd_x), .rd_y(rd_y),
        .rd_valid(v0), .rd_rgb(q0));

    dgc_cache_set u_set1 (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid && wr_set), .wr_ready(r1),
        .wr_x(wr_x), .wr_y(wr_y), .wr_rgb(wr_rgb),
        .rd_fire(rd_fire), .rd_ready(), .rd_x(rd_x), .rd_y(rd_y),
        .rd_valid(v1), .rd_rgb(q1));

    assign wr_ready = wr_set ? r1 : r0;
    assign rd_ready = 1'b1;
    assign rd_valid = rd_set ? v1 : v0;
    assign rd_rgb   = rd_set ? q1 : q0;

endmodule
