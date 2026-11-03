//-----------------------------------------------------------------------------
// tb_cache_set4.v - four simultaneous read ports on one cache set
//   P1  write a 16x16 pattern, then read the four neighbours of a point at once
//   P2  every port returns the pixel at its own coordinate
//   P3  all four parities are exercised across the sweep
//   P4  interior points only: this test does NOT duplicate neighbours, which is
//       the sampler's job (dgc_sample_dedup), so each port owns one bank
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_cache_set4;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    reg        wr_valid = 0; wire wr_ready;
    reg        wr2_valid = 0;
    reg [5:0]  wr_x = 0, wr_y = 0; reg [23:0] wr_rgb = 0, wr2_rgb = 0;

    reg p0_fire = 0, p1_fire = 0, p2_fire = 0, p3_fire = 0;
    reg [5:0] p0_x = 0, p0_y = 0, p1_x = 0, p1_y = 0;
    reg [5:0] p2_x = 0, p2_y = 0, p3_x = 0, p3_y = 0;
    wire p0_valid, p1_valid, p2_valid, p3_valid;
    wire [23:0] p0_d, p1_d, p2_d, p3_d;

    dgc_cache_set4 u_dut (.clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_x(wr_x), .wr_y(wr_y), .wr_rgb(wr_rgb),
        .wr2_valid(wr2_valid), .wr2_rgb(wr2_rgb),
        .p0_fire(p0_fire), .p0_x(p0_x), .p0_y(p0_y),
        .p1_fire(p1_fire), .p1_x(p1_x), .p1_y(p1_y),
        .p2_fire(p2_fire), .p2_x(p2_x), .p2_y(p2_y),
        .p3_fire(p3_fire), .p3_x(p3_x), .p3_y(p3_y),
        .p0_valid(p0_valid), .p0_d(p0_d),
        .p1_valid(p1_valid), .p1_d(p1_d),
        .p2_valid(p2_valid), .p2_d(p2_d),
        .p3_valid(p3_valid), .p3_d(p3_d));

    function [23:0] pat(input [5:0] x, input [5:0] y);
        begin pat = {2'b00, x, 2'b00, y, x ^ y}; end
    endfunction

    // self-describing data for the two-channel write test: the coordinate is
    // part of the value, so a mis-addressed or overwritten pixel cannot pass.
    function [23:0] pair_pat(input [5:0] u, input [5:0] v);
        begin pair_pat = {6'h15, u, 6'h2A, v}; end
    endfunction

    integer x, y, i;

    initial begin
        rst_n = 0; repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        for (y = 0; y < 16; y = y + 1)
            for (x = 0; x < 16; x = x + 1) begin
                @(posedge clk); #0.2;
                wr_valid <= 1'b1; wr_x <= x[5:0]; wr_y <= y[5:0]; wr_rgb <= pat(x[5:0], y[5:0]);
                @(posedge clk); #0.2; wr_valid <= 1'b0;
            end
        repeat (10) @(posedge clk);
        $display("TEST_INFO: P1 wrote a 16x16 pattern");

        // ============================================================== P2
        // interior points: the four neighbours are (x,y) (x+1,y) (x,y+1) (x+1,y+1)
        for (y = 0; y < 15; y = y + 1)
            for (x = 0; x < 15; x = x + 1) begin
                @(posedge clk); #0.2;
                p0_fire <= 1'b1; p0_x <= x[5:0];     p0_y <= y[5:0];
                p1_fire <= 1'b1; p1_x <= (x+1);      p1_y <= y[5:0];
                p2_fire <= 1'b1; p2_x <= x[5:0];     p2_y <= (y+1);
                p3_fire <= 1'b1; p3_x <= (x+1);      p3_y <= (y+1);
                @(posedge clk); #0.2;
                p0_fire <= 1'b0; p1_fire <= 1'b0; p2_fire <= 1'b0; p3_fire <= 1'b0;
                i = 0;
                while (!(p0_valid && p1_valid && p2_valid && p3_valid) && i < 20) begin
                    @(posedge clk); #0.2; i = i + 1;
                end
                if (p0_d !== pat(x, y)) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: P2 p0 (%0d,%0d) exp=%06h act=%06h", x, y, pat(x,y), p0_d);
                end
                if (p1_d !== pat(x+1, y)) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: P2 p1 (%0d,%0d) exp=%06h act=%06h", x+1, y, pat(x+1,y), p1_d);
                end
                if (p2_d !== pat(x, y+1)) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: P2 p2 (%0d,%0d) exp=%06h act=%06h", x, y+1, pat(x,y+1), p2_d);
                end
                if (p3_d !== pat(x+1, y+1)) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: P2 p3 (%0d,%0d) exp=%06h act=%06h", x+1, y+1, pat(x+1,y+1), p3_d);
                end
                @(posedge clk); #0.2;
            end
        $display("TEST_INFO: P2 all four ports returned their own neighbour simultaneously");
        $display("TEST_INFO: P3 the sweep covers x and y of both parities, so all four banks");

        // ============================================================== P4
        // Two write channels in one cycle: pixel x on channel 0 and x+1 on
        // channel 1. Both an even start x and an odd start x are exercised: for
        // an odd x the two pixels sit at different addresses (x>>1 vs (x+1)>>1)
        // as well as different parity banks, which a naive "shared address"
        // implementation would corrupt.
        // Data carries its own coordinate, so an overwritten or mis-addressed
        // pixel can never look correct by accident.
        for (y = 0; y < 4; y = y + 1) begin
            for (x = (y < 2 ? 0 : 1); x < 15; x = x + 2) begin
                @(posedge clk); #0.2;
                wr_valid  <= 1'b1; wr_x  <= x[5:0]; wr_y <= y[5:0];
                wr_rgb    <= pair_pat(x[5:0], y[5:0]);
                wr2_valid <= 1'b1; wr2_rgb <= pair_pat(x[5:0] + 6'd1, y[5:0]);
                @(posedge clk); #0.2;
                wr_valid <= 1'b0; wr2_valid <= 1'b0;
            end
        end
        repeat (4) @(posedge clk);

        for (y = 0; y < 4; y = y + 1) begin
            // rows 0..1 were written from even starts (0..15 covered); rows 2..3
            // from odd starts (1,2)..(13,14), so x=0 and x=15 keep the old P1 data
            for (x = (y < 2 ? 0 : 1); x < (y < 2 ? 16 : 15); x = x + 1) begin
                @(posedge clk); #0.2;
                p0_fire <= 1'b1; p0_x <= x[5:0]; p0_y <= y[5:0];
                @(posedge clk); #0.2; p0_fire <= 1'b0;
                i = 0;
                while (!p0_valid && i < 20) begin @(posedge clk); #0.2; i = i + 1; end
                if (p0_d !== pair_pat(x[5:0], y[5:0])) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 16)
                        $display("TEST_FAIL: P4 pixel (%0d,%0d) exp=%06h act=%06h",
                                 x, y, pair_pat(x[5:0], y[5:0]), p0_d);
                end
                @(posedge clk); #0.2;
            end
        end
        $display("TEST_INFO: P4 two-pixel single-cycle writes read back exactly (even and odd x)");
        `DGC_FINISH
    end
endmodule
