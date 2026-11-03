//-----------------------------------------------------------------------------
// tb_sampling_chain.v - real cache + neighbour_calc + sample_dedup, integrated
//
// Each part is verified on its own; this checks the three together, which is the
// first real integration step for the sampling path:
//   coord record (sx0, sy0) -> neighbour_calc -> four cache reads -> dedupe -> P00..P11
//
// Interior points only: at an edge the neighbour is duplicated and the sampler must
// read once, which needs the read-count logic that is not wired here yet. The edge
// geometry itself is already covered by s2_neighbour and s2_sampler_path.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_sampling_chain;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    // ---- image under test
    reg [10:0] sx0 = 0, sy0 = 0, bbox_x = 0, bbox_y = 0;
    reg        sample_ok = 1;
    wire [10:0] sx1, sy1;
    wire [5:0]  lx0, ly0, lx1, ly1;
    wire        edge_x, edge_y, active, in_block;

    dgc_neighbour_calc u_nb (.sx0(sx0), .sy0(sy0), .bbox_x(bbox_x), .bbox_y(bbox_y),
        .sample_ok(sample_ok), .sx1(sx1), .sy1(sy1), .lx0(lx0), .ly0(ly0),
        .lx1(lx1), .ly1(ly1), .edge_x(edge_x), .edge_y(edge_y),
        .active(active), .in_block(in_block));

    // ---- cache
    reg        wr_valid = 0; wire wr_ready;
    reg [5:0]  wr_x = 0, wr_y = 0; reg [23:0] wr_rgb = 0;
    reg        p0_fire = 0, p1_fire = 0, p2_fire = 0, p3_fire = 0;
    wire       p0_valid, p1_valid, p2_valid, p3_valid;
    wire [23:0] p0_d, p1_d, p2_d, p3_d;

    dgc_cache_set4 u_cache (.clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_x(wr_x), .wr_y(wr_y), .wr_rgb(wr_rgb),
        .wr2_valid(1'b0), .wr2_rgb(24'd0),
        .p0_fire(p0_fire), .p0_x(lx0), .p0_y(ly0),
        .p1_fire(p1_fire), .p1_x(lx1), .p1_y(ly0),
        .p2_fire(p2_fire), .p2_x(lx0), .p2_y(ly1),
        .p3_fire(p3_fire), .p3_x(lx1), .p3_y(ly1),
        .p0_valid(p0_valid), .p0_d(p0_d), .p1_valid(p1_valid), .p1_d(p1_d),
        .p2_valid(p2_valid), .p2_d(p2_d), .p3_valid(p3_valid), .p3_d(p3_d));

    // ---- dedupe
    wire [23:0] q00, q10, q01, q11;
    wire [2:0]  need, dup;
    dgc_sample_dedup u_dd (.edge_x(edge_x), .edge_y(edge_y),
        .r00(p0_d), .r10(p1_d), .r01(p2_d), .r11(p3_d),
        .p00(q00), .p10(q10), .p01(q01), .p11(q11), .need(need), .dup(dup));

    function [23:0] img(input [10:0] x, input [11:0] y);
        begin img = {2'b00, x[5:0], 2'b00, y[5:0], x[5:0] ^ y[5:0]}; end
    endfunction

    integer x, y, i, k;
    reg [23:0] e00, e10, e01, e11;

    task read_pt;
        begin
            @(posedge clk); #0.2;
            p0_fire <= 1'b1; p1_fire <= 1'b1; p2_fire <= 1'b1; p3_fire <= 1'b1;
            @(posedge clk); #0.2;
            p0_fire <= 1'b0; p1_fire <= 1'b0; p2_fire <= 1'b0; p3_fire <= 1'b0;
            k = 0;
            while (!(p0_valid && p1_valid && p2_valid && p3_valid) && k < 20) begin
                @(posedge clk); #0.2; k = k + 1;
            end
        end
    endtask

    initial begin
        rst_n = 0; repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        // ---- fill an 8x8 block at the origin
        bbox_x = 11'd0; bbox_y = 11'd0;
        for (y = 0; y < 8; y = y + 1)
            for (x = 0; x < 8; x = x + 1) begin
                @(posedge clk); #0.2;
                wr_valid <= 1'b1; wr_x <= x[5:0]; wr_y <= y[5:0]; wr_rgb <= img(x, y);
                @(posedge clk); #0.2; wr_valid <= 1'b0;
            end
        repeat (10) @(posedge clk);
        $display("TEST_INFO: filled an 8x8 block into the cache");

        // ---- integrate over interior points
        for (y = 0; y < 7; y = y + 1)
            for (x = 0; x < 7; x = x + 1) begin
                sx0 = x[10:0]; sy0 = y[10:0]; #0;
                if (edge_x || edge_y || !in_block || !active) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: interior point (%0d,%0d) flagged as edge/outside", x, y);
                end
                read_pt;
                e00 = img(x, y); e10 = img(x+1, y); e01 = img(x, y+1); e11 = img(x+1, y+1);
                if (q00 !== e00 || q10 !== e10 || q01 !== e01 || q11 !== e11) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8)
                    $display("TEST_FAIL: chain (%0d,%0d) exp %06h %06h %06h %06h act %06h %06h %06h %06h",
                             x, y, e00, e10, e01, e11, q00, q10, q01, q11);
                end
                @(posedge clk); #0.2;
            end
        $display("TEST_INFO: coord -> neighbours -> cache -> dedupe returned the four image pixels");
        $display("TEST_INFO: 7x7 = 49 interior points verified through the whole chain");
        `DGC_FINISH
    end
endmodule
