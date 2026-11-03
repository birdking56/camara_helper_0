//-----------------------------------------------------------------------------
// tb_source_cache4.v - both sets, four read ports each
//   Q1  write a pattern into set 0 and a different one into set 1
//   Q2  reading set 0 gives set 0's four neighbours
//   Q3  reading set 1 gives set 1's four neighbours, same coordinates
//   Q4  the two sets stay independent (same coordinate, different data)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_source_cache4;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    reg wr_valid = 0; wire wr_ready; reg wr_set = 0; reg wr2_valid = 0;
    reg [5:0] wr_x = 0, wr_y = 0; reg [23:0] wr_rgb = 0, wr2_rgb = 0;
    reg rd_set = 0;
    reg p0_fire = 0, p1_fire = 0, p2_fire = 0, p3_fire = 0;
    reg [5:0] p0_x = 0, p0_y = 0, p1_x = 0, p1_y = 0;
    reg [5:0] p2_x = 0, p2_y = 0, p3_x = 0, p3_y = 0;
    wire p0_valid, p1_valid, p2_valid, p3_valid;
    wire [23:0] p0_d, p1_d, p2_d, p3_d;

    dgc_source_cache4 u_dut (.clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_set(wr_set),
        .wr_x(wr_x), .wr_y(wr_y), .wr_rgb(wr_rgb),
        .wr2_valid(wr2_valid), .wr2_rgb(wr2_rgb),
        .rd_set(rd_set),
        .p0_fire(p0_fire), .p0_x(p0_x), .p0_y(p0_y),
        .p1_fire(p1_fire), .p1_x(p1_x), .p1_y(p1_y),
        .p2_fire(p2_fire), .p2_x(p2_x), .p2_y(p2_y),
        .p3_fire(p3_fire), .p3_x(p3_x), .p3_y(p3_y),
        .p0_valid(p0_valid), .p0_d(p0_d), .p1_valid(p1_valid), .p1_d(p1_d),
        .p2_valid(p2_valid), .p2_d(p2_d), .p3_valid(p3_valid), .p3_d(p3_d));

    function [23:0] patA(input [5:0] x, input [5:0] y); begin patA = {2'b00, x, 2'b00, y, 8'hA5}; end endfunction
    function [23:0] patB(input [5:0] x, input [5:0] y); begin patB = {2'b00, y, 2'b00, x, 8'h5A}; end endfunction

    integer x, y, i;

    task read4(input integer x0, input integer y0, output [23:0] a, output [23:0] b,
               output [23:0] c, output [23:0] d);
        integer k;
        begin
            @(posedge clk); #0.2;
            p0_fire <= 1'b1; p0_x <= x0[5:0];    p0_y <= y0[5:0];
            p1_fire <= 1'b1; p1_x <= (x0+1);     p1_y <= y0[5:0];
            p2_fire <= 1'b1; p2_x <= x0[5:0];    p2_y <= (y0+1);
            p3_fire <= 1'b1; p3_x <= (x0+1);     p3_y <= (y0+1);
            @(posedge clk); #0.2;
            p0_fire <= 1'b0; p1_fire <= 1'b0; p2_fire <= 1'b0; p3_fire <= 1'b0;
            k = 0;
            while (!(p0_valid && p1_valid && p2_valid && p3_valid) && k < 20) begin
                @(posedge clk); #0.2; k = k + 1;
            end
            a = p0_d; b = p1_d; c = p2_d; d = p3_d;
            @(posedge clk); #0.2;
        end
    endtask

    reg [23:0] r0, r1, r2, r3;

    initial begin
        rst_n = 0; repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        // ============================================================== Q1
        for (y = 0; y < 8; y = y + 1)
            for (x = 0; x < 8; x = x + 1) begin
                @(posedge clk); #0.2; wr_valid <= 1'b1; wr_set <= 1'b0;
                wr_x <= x[5:0]; wr_y <= y[5:0]; wr_rgb <= patA(x[5:0], y[5:0]);
                @(posedge clk); #0.2; wr_valid <= 1'b0;
                @(posedge clk); #0.2; wr_valid <= 1'b1; wr_set <= 1'b1;
                wr_x <= x[5:0]; wr_y <= y[5:0]; wr_rgb <= patB(x[5:0], y[5:0]);
                @(posedge clk); #0.2; wr_valid <= 1'b0;
            end
        repeat (10) @(posedge clk);
        $display("TEST_INFO: Q1 wrote different patterns into both sets");

        // ============================================================== Q2/Q3
        for (y = 0; y < 7; y = y + 1)
            for (x = 0; x < 7; x = x + 1) begin
                rd_set = 1'b0;
                read4(x, y, r0, r1, r2, r3);
                if (r0 !== patA(x, y) || r1 !== patA(x+1, y) ||
                    r2 !== patA(x, y+1) || r3 !== patA(x+1, y+1)) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: Q2 set0 neighbours wrong at (%0d,%0d)", x, y);
                end
                rd_set = 1'b1;
                read4(x, y, r0, r1, r2, r3);
                if (r0 !== patB(x, y) || r1 !== patB(x+1, y) ||
                    r2 !== patB(x, y+1) || r3 !== patB(x+1, y+1)) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: Q3 set1 neighbours wrong at (%0d,%0d)", x, y);
                end
            end
        $display("TEST_INFO: Q2/Q3 four neighbours read correctly from either set");
        $display("TEST_INFO: Q4 the two sets hold different data at identical coordinates");

        // ============================================================== Q5
        // Two-channel write through the wrapper: a pair must land only in the
        // set selected by wr_set. Write a fresh pair into each set at a point
        // the Q1 pattern does not reach (x=20, y=20) and read both back.
        @(posedge clk); #0.2;
        wr_valid <= 1'b1; wr2_valid <= 1'b1; wr_set <= 1'b0;
        wr_x <= 6'd20; wr_y <= 6'd20;
        wr_rgb <= 24'hAA_1111; wr2_rgb <= 24'hAA_2222;
        @(posedge clk); #0.2; wr_valid <= 1'b0; wr2_valid <= 1'b0;
        @(posedge clk); #0.2;
        wr_valid <= 1'b1; wr2_valid <= 1'b1; wr_set <= 1'b1;
        wr_x <= 6'd20; wr_y <= 6'd20;
        wr_rgb <= 24'hBB_1111; wr2_rgb <= 24'hBB_2222;
        @(posedge clk); #0.2; wr_valid <= 1'b0; wr2_valid <= 1'b0;
        repeat (4) @(posedge clk);

        rd_set = 1'b0;
        read4(20, 20, r0, r1, r2, r3);
        if (r0 !== 24'hAA_1111 || r1 !== 24'hAA_2222) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: Q5 set0 pair = %06h/%06h, expected AA1111/AA2222", r0, r1);
        end
        rd_set = 1'b1;
        read4(20, 20, r0, r1, r2, r3);
        if (r0 !== 24'hBB_1111 || r1 !== 24'hBB_2222) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: Q5 set1 pair = %06h/%06h, expected BB1111/BB2222", r0, r1);
        end
        else $display("TEST_INFO: Q5 a two-pixel write lands only in the selected set");
        `DGC_FINISH
    end
endmodule
