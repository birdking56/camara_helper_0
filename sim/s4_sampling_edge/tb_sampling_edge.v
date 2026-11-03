//-----------------------------------------------------------------------------
// tb_sampling_edge.v - the sampling chain at the image edge
//   Fills the edge block (1888,1072)-(1919,1079), then samples edge points.
//   The fire signals are gated with a request pulse, because dgc_cache_set4 samples
//   its fire inputs every cycle and its outputs lag by three cycles: holding fire
//   high and sampling straight after a coordinate change reads a stale point.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_sampling_edge;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    reg [10:0] sx0 = 0, sy0 = 0;
    wire [10:0] sx1, sy1;
    wire [5:0]  lx0, ly0, lx1, ly1;
    wire        edge_x, edge_y, active, in_block;

    dgc_neighbour_calc u_nb (.sx0(sx0), .sy0(sy0), .bbox_x(11'd1888), .bbox_y(11'd1072),
        .sample_ok(1'b1), .sx1(sx1), .sy1(sy1), .lx0(lx0), .ly0(ly0),
        .lx1(lx1), .ly1(ly1), .edge_x(edge_x), .edge_y(edge_y),
        .active(active), .in_block(in_block));

    wire f0, f1, f2, f3;
    wire [2:0] reads;
    dgc_read_issue u_ri (.edge_x(edge_x), .edge_y(edge_y),
        .p0_fire(f0), .p1_fire(f1), .p2_fire(f2), .p3_fire(f3), .reads(reads));

    reg        req = 0;                 // one-cycle request pulse
    reg        wr_valid = 0; wire wr_ready;
    reg [5:0]  wr_x = 0, wr_y = 0; reg [23:0] wr_rgb = 0;
    wire p0_valid, p1_valid, p2_valid, p3_valid;
    wire [23:0] p0_d, p1_d, p2_d, p3_d;

    dgc_cache_set4 u_cache (.clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_x(wr_x), .wr_y(wr_y), .wr_rgb(wr_rgb),
        .wr2_valid(1'b0), .wr2_rgb(24'd0),
        .p0_fire(f0 && req), .p0_x(lx0), .p0_y(ly0),
        .p1_fire(f1 && req), .p1_x(lx1), .p1_y(ly0),
        .p2_fire(f2 && req), .p2_x(lx0), .p2_y(ly1),
        .p3_fire(f3 && req), .p3_x(lx1), .p3_y(ly1),
        .p0_valid(p0_valid), .p0_d(p0_d), .p1_valid(p1_valid), .p1_d(p1_d),
        .p2_valid(p2_valid), .p2_d(p2_d), .p3_valid(p3_valid), .p3_d(p3_d));

    wire [23:0] q00, q10, q01, q11;
    wire [2:0] need, dup;
    dgc_sample_dedup u_dd (.edge_x(edge_x), .edge_y(edge_y),
        .r00(p0_d), .r10(p1_d), .r01(p2_d), .r11(p3_d),
        .p00(q00), .p10(q10), .p01(q01), .p11(q11), .need(need), .dup(dup));

    function [23:0] img(input [10:0] x, input [11:0] y);
        begin img = {2'b00, x[5:0], 2'b00, y[5:0], x[5:0] ^ y[5:0]}; end
    endfunction

    integer x, y, k;
    reg [23:0] e00, e10, e01, e11;

    task sample;
        begin
            @(posedge clk); #0.2; req <= 1'b1;
            @(posedge clk); #0.2; req <= 1'b0;
            k = 0;
            while (!p0_valid && k < 20) begin @(posedge clk); #0.2; k = k + 1; end
            @(posedge clk); #0.2;
        end
    endtask

    initial begin
        rst_n = 0; repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        for (y = 0; y < 8; y = y + 1)
            for (x = 0; x < 32; x = x + 1) begin
                @(posedge clk); #0.2;
                wr_valid <= 1'b1; wr_x <= x[5:0]; wr_y <= y[5:0];
                wr_rgb <= img(11'd1888 + x, 12'd1072 + y);
                @(posedge clk); #0.2; wr_valid <= 1'b0;
            end
        repeat (10) @(posedge clk);
        $display("TEST_INFO: filled the edge block at 1888,1072");

        // X1 right edge: lx = 31, ly = 4
        sx0 = 11'd1919; sy0 = 11'd1076; #0;
        $display("TEST_INFO: X1 edge_x=%b edge_y=%b reads=%0d", edge_x, edge_y, reads);
        sample;
        e00 = img(11'd1919, 12'd1076);
        e01 = img(11'd1919, 12'd1077);
        $display("TEST_INFO: X1 exp %06h %06h | act %06h %06h %06h %06h", e00, e01, q00, q10, q01, q11);
        if (q00 !== e00 || q10 !== e00 || q01 !== e01 || q11 !== e01) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X1 right edge wrong");
        end
        else $display("TEST_INFO: X1 right edge: two reads, x neighbours replicated");

        // X2 bottom edge: lx = 12, ly = 7
        sx0 = 11'd1900; sy0 = 11'd1079; #0;
        $display("TEST_INFO: X2 edge_x=%b edge_y=%b reads=%0d", edge_x, edge_y, reads);
        sample;
        e00 = img(11'd1900, 12'd1079);
        e10 = img(11'd1901, 12'd1079);
        if (q00 !== e00 || q01 !== e00 || q10 !== e10 || q11 !== e10) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X2 bottom edge wrong");
        end
        else $display("TEST_INFO: X2 bottom edge: two reads, y neighbours replicated");

        // X3 corner
        sx0 = 11'd1919; sy0 = 11'd1079; #0;
        $display("TEST_INFO: X3 edge_x=%b edge_y=%b reads=%0d", edge_x, edge_y, reads);
        sample;
        e00 = img(11'd1919, 12'd1079);
        if (q00 !== e00 || q10 !== e00 || q01 !== e00 || q11 !== e00) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X3 corner wrong");
        end
        else $display("TEST_INFO: X3 corner: one read fills all four neighbours");

        `DGC_FINISH
    end
endmodule
