//-----------------------------------------------------------------------------
// tb_sampler_path.v - neighbour_calc + sample_dedup, checked against an image
//
// The two halves of the sampling path are verified on their own; this wires them
// together and checks that the four neighbours really are the pixels at the
// neighbour coordinates of a gradient image, with edge replication applied.
//
// The expected neighbours are computed independently here from the image function,
// not from the DUT's coordinates, so a wiring mistake shows up as a mismatch.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_sampler_path;
    integer dgc_errors = 0;

    reg  [10:0] sx0 = 0, sy0 = 0, bbox_x = 0, bbox_y = 0;
    reg         sample_ok = 1;
    wire [10:0] sx1, sy1;
    wire [5:0]  lx0, ly0, lx1, ly1;
    wire        edge_x, edge_y, active, in_block;

    dgc_neighbour_calc u_nb (.sx0(sx0), .sy0(sy0), .bbox_x(bbox_x), .bbox_y(bbox_y),
        .sample_ok(sample_ok), .sx1(sx1), .sy1(sy1), .lx0(lx0), .ly0(ly0),
        .lx1(lx1), .ly1(ly1), .edge_x(edge_x), .edge_y(edge_y),
        .active(active), .in_block(in_block));

    // the image the "cache" would return, addressed by absolute coordinates
    function [23:0] img(input [10:0] x, input [10:0] y);
        begin
            img = {x[7:0], y[7:0], (x[7:0] ^ y[7:0])};
        end
    endfunction

    // the cache hands back the four points; at an edge the duplicate is filled
    // with the same value, which is what a one-read cache would do
    wire [23:0] r00 = img(sx0, sy0);
    wire [23:0] r10 = img(sx1, sy0);
    wire [23:0] r01 = img(sx0, sy1);
    wire [23:0] r11 = img(sx1, sy1);

    wire [23:0] p00, p10, p01, p11;
    wire [2:0]  need, dup;
    wire [23:0] q00, q10, q01, q11;

    dgc_sample_dedup u_dd (.edge_x(edge_x), .edge_y(edge_y),
        .r00(r00), .r10(r10), .r01(r01), .r11(r11),
        .p00(q00), .p10(q10), .p01(q01), .p11(q11), .need(need), .dup(dup));

    // at an edge the sampler reads once and replicates, so the value delivered for
    // the duplicated position is the same point's value
    assign p00 = q00; assign p10 = q10; assign p01 = q01; assign p11 = q11;

    integer x, y, bx, by, i;
    reg [23:0] e00, e10, e01, e11;

    initial begin
        // ============================================================== S1
        // interior points of a 32x16 block
        for (by = 0; by < 1080; by = by + 240)
        for (bx = 0; bx < 1920; bx = bx + 240) begin
            bbox_x = bx[10:0]; bbox_y = by[10:0];
            for (i = 0; i < 16; i = i + 1) begin
                x = bx + ((i * 37) % 32);
                y = by + ((i * 11) % 16);
                if (x > 1919) x = 1919;
                if (y > 1079) y = 1079;
                sx0 = x[10:0]; sy0 = y[10:0];
                #0;
                e00 = img(x, y);
                e10 = img((x >= 1919) ? 1919 : x + 1, y);
                e01 = img(x, (y >= 1079) ? 1079 : y + 1);
                e11 = img((x >= 1919) ? 1919 : x + 1, (y >= 1079) ? 1079 : y + 1);
                if (p00 !== e00 || p10 !== e10 || p01 !== e01 || p11 !== e11) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8)
                    $display("TEST_FAIL: S1 neighbours wrong at (%0d,%0d)", x, y);
                end
                if (need + dup !== 3'd4) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: S1 need+dup != 4");
                end
            end
        end
        $display("TEST_INFO: S1 the four neighbours are the pixels at the neighbour coordinates");

        // ============================================================== S2
        // the last column and row: neighbours must still be real pixels, not zero
        sx0 = 11'd1919; sy0 = 11'd500; bbox_x = 11'd1888; bbox_y = 11'd496; #0;
        if (p10 !== img(11'd1919, 11'd500) || p11 !== img(11'd1919, 11'd501)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: S2 right edge did not replicate");
        end
        if (edge_x !== 1'b1 || need !== 3'd2) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: S2 right edge should need 2 points");
        end
        else $display("TEST_INFO: S2 at the right edge two distinct points are read and replicated");

        sx0 = 11'd900; sy0 = 11'd1079; bbox_x = 11'd896; bbox_y = 11'd1072; #0;
        if (p01 !== img(11'd900, 11'd1079) || p11 !== img(11'd901, 11'd1079)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: S2 bottom edge did not replicate");
        end
        else $display("TEST_INFO: S2 at the bottom edge the same");

        sx0 = 11'd1919; sy0 = 11'd1079; bbox_x = 11'd1888; bbox_y = 11'd1072; #0;
        if (need !== 3'd1 || p11 !== img(11'd1919, 11'd1079)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: S2 corner should need one point and replicate it");
        end
        else $display("TEST_INFO: S2 at the corner one point fills all four");

        `DGC_FINISH
    end
endmodule
