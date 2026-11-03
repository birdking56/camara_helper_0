//-----------------------------------------------------------------------------
// tb_neighbour_calc.v
//   N1  sx1/sy1 follow min(x+1, last)
//   N2  the right/bottom edge duplicates the neighbour instead of dropping it
//   N3  local coordinates follow the block origin
//   N4  active follows sample_ok
//   N5  exhaustive over all x at the right edge and all y at the bottom edge
//   N6  a full identity sweep: every pixel of the 1920x1080 frame with a 32x16
//       block origin gives neighbours inside the block
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_neighbour_calc;
    integer dgc_errors = 0;

    reg  [10:0] sx0 = 0, sy0 = 0, bbox_x = 0, bbox_y = 0;
    reg         sample_ok = 1;
    wire [10:0] sx1, sy1;
    wire [5:0]  lx0, ly0, lx1, ly1;
    wire        edge_x, edge_y, active, in_block;

    dgc_neighbour_calc u_dut (
        .sx0(sx0), .sy0(sy0), .bbox_x(bbox_x), .bbox_y(bbox_y),
        .sample_ok(sample_ok),
        .sx1(sx1), .sy1(sy1), .lx0(lx0), .ly0(ly0), .lx1(lx1), .ly1(ly1),
        .edge_x(edge_x), .edge_y(edge_y), .active(active), .in_block(in_block));

    integer x, y, bx, by;
    integer exp1;

    initial begin
        // ============================================================== N1/N2
        sx0 = 11'd100; sy0 = 11'd200; bbox_x = 11'd96; bbox_y = 11'd192;
        sample_ok = 1; #0;
        if (sx1 !== 11'd101 || sy1 !== 11'd201) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: N1 interior neighbours sx1=%0d sy1=%0d", sx1, sy1);
        end
        if (edge_x !== 1'b0 || edge_y !== 1'b0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: N1 interior wrongly flagged as an edge");
        end
        $display("TEST_INFO: N1 interior point gives x+1 and y+1");

        sx0 = 11'd1919; sy0 = 11'd1079; bbox_x = 11'd1888; bbox_y = 11'd1072; #0;
        if (sx1 !== 11'd1919 || sy1 !== 11'd1079) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: N2 the last pixel must duplicate its neighbour");
        end
        if (edge_x !== 1'b1 || edge_y !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: N2 edge flags not set");
        end
        $display("TEST_INFO: N2 the right/bottom edge duplicates the neighbour rather than losing it");

        // ============================================================== N3
        sx0 = 11'd131; sy0 = 11'd75; bbox_x = 11'd128; bbox_y = 11'd64; #0;
        if (lx0 !== 6'd3 || ly0 !== 6'd11 || lx1 !== 6'd4 || ly1 !== 6'd12) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: N3 local coords (%0d,%0d)-(%0d,%0d)", lx0, ly0, lx1, ly1);
        end
        else $display("TEST_INFO: N3 local coordinates are relative to the block origin");

        // ============================================================== N4
        sample_ok = 0; #0;
        if (active !== 1'b0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: N4 sample_ok=0 must deassert active");
        end
        sample_ok = 1; #0;
        if (active !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: N4 sample_ok=1 must assert active");
        end
        $display("TEST_INFO: N4 active follows sample_ok");

        // ============================================================== N5
        // every x against the right edge, every y against the bottom edge
        bbox_x = 11'd0; bbox_y = 11'd0;
        for (x = 0; x <= 1919; x = x + 1) begin
            sx0 = x[10:0]; sy0 = 11'd0; #0;
            exp1 = (x >= 1919) ? 1919 : (x + 1);
            if (sx1 !== exp1[10:0]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: N5 sx1 wrong at x=%0d", x);
            end
            if (edge_x !== ((x == 1919) ? 1'b1 : 1'b0)) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: N5 edge_x wrong at x=%0d", x);
            end
        end
        for (y = 0; y <= 1079; y = y + 1) begin
            sx0 = 11'd0; sy0 = y[10:0]; #0;
            exp1 = (y >= 1079) ? 1079 : (y + 1);
            if (sy1 !== exp1[10:0]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: N5 sy1 wrong at y=%0d", y);
            end
        end
        $display("TEST_INFO: N5 exhaustive over 1920 x values and 1080 y values");

        // ============================================================== N6
        // 32x16 blocks: every pixel inside a block must stay inside that block
        for (by = 0; by < 1080; by = by + 16)
        for (bx = 0; bx < 1920; bx = bx + 32) begin
            bbox_x = bx[10:0]; bbox_y = by[10:0];
            for (y = by; y < by + 16 && y < 1080; y = y + 1)
            for (x = bx; x < bx + 32 && x < 1920; x = x + 1) begin
                sx0 = x[10:0]; sy0 = y[10:0]; #0;
                if (!in_block) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8)
                    $display("TEST_FAIL: N6 (%0d,%0d) escaped block at (%0d,%0d)", x, y, bx, by);
                end
            end
        end
        $display("TEST_INFO: N6 every pixel's neighbours stay inside its 32x16 block");
        `DGC_FINISH
    end
endmodule
