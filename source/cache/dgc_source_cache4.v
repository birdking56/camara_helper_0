//-----------------------------------------------------------------------------
// dgc_source_cache4.v - both cache sets, four simultaneous read ports
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//   set 0 -> src_tile_bank_0..3, set 1 -> src_tile_bank_4..7
//   Four neighbours read in one cycle from the set being sampled; the other set is
//   free for filling, which is the whole point of having two.
//
// Built from verified parts: dgc_cache_set4 is proven on real DRAM for four
// simultaneous ports, and dgc_cache_owner is proven separately. This module is the
// wiring between them, which is why ownership is a port here rather than being
// folded in: the two concerns were verified apart.
//
// Ownership note: a set may be filled while the other is sampled, but this module
// does not decide that - `wr_set` and `rd_set` come from the owner.
//-----------------------------------------------------------------------------

module dgc_source_cache4 #(
    // Read latency of one set (DRM wrapper with OUTPUT_REG: address -> data).
    // The output mux must use the set that was selected when the read was *fired*,
    // not the current one, so the select is delayed by this many cycles. That is
    // what lets the core switch to the next block's set on the very cycle the last
    // record is accepted instead of waiting for the whole read pipeline to drain.
    parameter integer LAT = 3
) (
    input  wire        clk, rst_n,

    input  wire        wr_valid,
    output wire        wr_ready,
    input  wire        wr_set,
    input  wire [5:0]  wr_x, wr_y,
    input  wire [23:0] wr_rgb,
    // second pixel of a two-pixel unpack record (x+1, same row)
    input  wire        wr2_valid,
    input  wire [23:0] wr2_rgb,

    input  wire        rd_set,
    input  wire        p0_fire, input wire [5:0] p0_x, p0_y,
    input  wire        p1_fire, input wire [5:0] p1_x, p1_y,
    input  wire        p2_fire, input wire [5:0] p2_x, p2_y,
    input  wire        p3_fire, input wire [5:0] p3_x, p3_y,

    output wire        p0_valid, output wire [23:0] p0_d,
    output wire        p1_valid, output wire [23:0] p1_d,
    output wire        p2_valid, output wire [23:0] p2_d,
    output wire        p3_valid, output wire [23:0] p3_d
);

    wire r0, r1;
    wire v0a, v0b, v0c, v0d;
    wire v1a, v1b, v1c, v1d;
    wire [23:0] d0a, d0b, d0c, d0d;
    wire [23:0] d1a, d1b, d1c, d1d;

    dgc_cache_set4 u_set0 (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid && !wr_set), .wr_ready(r0),
        .wr_x(wr_x), .wr_y(wr_y), .wr_rgb(wr_rgb),
        .wr2_valid(wr2_valid && !wr_set), .wr2_rgb(wr2_rgb),
        .p0_fire(p0_fire), .p0_x(p0_x), .p0_y(p0_y),
        .p1_fire(p1_fire), .p1_x(p1_x), .p1_y(p1_y),
        .p2_fire(p2_fire), .p2_x(p2_x), .p2_y(p2_y),
        .p3_fire(p3_fire), .p3_x(p3_x), .p3_y(p3_y),
        .p0_valid(v0a), .p0_d(d0a), .p1_valid(v0b), .p1_d(d0b),
        .p2_valid(v0c), .p2_d(d0c), .p3_valid(v0d), .p3_d(d0d));

    dgc_cache_set4 u_set1 (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid && wr_set), .wr_ready(r1),
        .wr_x(wr_x), .wr_y(wr_y), .wr_rgb(wr_rgb),
        .wr2_valid(wr2_valid && wr_set), .wr2_rgb(wr2_rgb),
        .p0_fire(p0_fire), .p0_x(p0_x), .p0_y(p0_y),
        .p1_fire(p1_fire), .p1_x(p1_x), .p1_y(p1_y),
        .p2_fire(p2_fire), .p2_x(p2_x), .p2_y(p2_y),
        .p3_fire(p3_fire), .p3_x(p3_x), .p3_y(p3_y),
        .p0_valid(v1a), .p0_d(d1a), .p1_valid(v1b), .p1_d(d1b),
        .p2_valid(v1c), .p2_d(d1c), .p3_valid(v1d), .p3_d(d1d));

    assign wr_ready = wr_set ? r1 : r0;

    // ---------------------------------------------------------- delayed select
    // 2026-11-02 (c): the mux used the *current* rd_set, so the core had to keep
    // rd_set (and the block's bbox) stable for LAT cycles after the last fire -
    // the reason C_DRAIN costs 16 cycles per block (4080 blocks x 16 = 0.38 ms per
    // frame, the margin we still need for 60 fps). Delaying the select by LAT lets
    // the core switch the set immediately: each returning beat remembers which set
    // it was read from.
    reg [LAT-1:0] set_pipe;
    integer si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) set_pipe <= {LAT{1'b0}};
        else begin
            set_pipe[0] <= rd_set;
            for (si = 1; si < LAT; si = si + 1) set_pipe[si] <= set_pipe[si-1];
        end
    end
    wire rd_set_d = set_pipe[LAT-1];

    assign p0_valid = rd_set_d ? v1a : v0a;
    assign p0_d     = rd_set_d ? d1a : d0a;
    assign p1_valid = rd_set_d ? v1b : v0b;
    assign p1_d     = rd_set_d ? d1b : d0b;
    assign p2_valid = rd_set_d ? v1c : v0c;
    assign p2_d     = rd_set_d ? d1c : d0c;
    assign p3_valid = rd_set_d ? v1d : v0d;
    assign p3_d     = rd_set_d ? d1d : d0d;

endmodule
