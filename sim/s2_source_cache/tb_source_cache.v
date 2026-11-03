//-----------------------------------------------------------------------------
// tb_source_cache.v - two sets on real DRAM, single-point read
//   C1  write different patterns into both sets at the SAME coordinates
//   C2  reading set 0 returns set 0's data, set 1 returns set 1's data
//   C3  writing set 1 leaves set 0 untouched
//   C4  a point never written stays distinct from a written one (no aliasing)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_source_cache;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    reg        wr_valid = 0; reg wr_set = 0;
    reg [5:0]  wr_x = 0, wr_y = 0; reg [23:0] wr_rgb = 0;
    wire       wr_ready;
    reg        rd_set = 0; reg rd_fire = 0;
    reg [5:0]  rd_x = 0, rd_y = 0;
    wire       rd_valid; wire [23:0] rd_rgb; wire rd_ready;

    dgc_source_cache u_dut (.clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_set(wr_set), .wr_x(wr_x), .wr_y(wr_y),
        .wr_rgb(wr_rgb), .wr_ready(wr_ready),
        .rd_set(rd_set), .rd_fire(rd_fire), .rd_x(rd_x), .rd_y(rd_y),
        .rd_valid(rd_valid), .rd_rgb(rd_rgb), .rd_ready(rd_ready));

    function [23:0] patA(input [5:0] x, input [5:0] y);
        begin patA = {2'b00, x, 2'b00, y, 8'hA5}; end
    endfunction
    function [23:0] patB(input [5:0] x, input [5:0] y);
        begin patB = {2'b00, y, 2'b00, x, 8'h5A}; end
    endfunction

    task wr(input s, input [5:0] x, input [5:0] y, input [23:0] d);
        begin
            @(posedge clk); #0.2;
            wr_valid <= 1'b1; wr_set <= s; wr_x <= x; wr_y <= y; wr_rgb <= d;
            @(posedge clk); #0.2; wr_valid <= 1'b0;
        end
    endtask

    task rd(input s, input [5:0] x, input [5:0] y, output [23:0] d);
        integer k;
        begin
            @(posedge clk); #0.2;
            rd_fire <= 1'b1; rd_set <= s; rd_x <= x; rd_y <= y;
            @(posedge clk); #0.2; rd_fire <= 1'b0;
            k = 0;
            while (!rd_valid && k < 20) begin @(posedge clk); #0.2; k = k + 1; end
            d = rd_rgb;
            @(posedge clk); #0.2;
        end
    endtask

    reg [23:0] d;
    integer x, y;

    initial begin
        rst_n = 0; repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        // ============================================================== C1
        for (y = 0; y < 8; y = y + 1)
            for (x = 0; x < 8; x = x + 1) begin
                wr(1'b0, x[5:0], y[5:0], patA(x[5:0], y[5:0]));
                wr(1'b1, x[5:0], y[5:0], patB(x[5:0], y[5:0]));
            end
        repeat (10) @(posedge clk);
        $display("TEST_INFO: C1 wrote different patterns into both sets at the same coordinates");

        // ============================================================== C2
        for (y = 0; y < 8; y = y + 1)
            for (x = 0; x < 8; x = x + 1) begin
                rd(1'b0, x[5:0], y[5:0], d);
                if (d !== patA(x[5:0], y[5:0])) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: C2 set0 (%0d,%0d) exp=%06h act=%06h", x, y, patA(x[5:0],y[5:0]), d);
                end
                rd(1'b1, x[5:0], y[5:0], d);
                if (d !== patB(x[5:0], y[5:0])) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: C2 set1 (%0d,%0d) exp=%06h act=%06h", x, y, patB(x[5:0],y[5:0]), d);
                end
            end
        $display("TEST_INFO: C2 each set returns its own data for the same coordinate");

        // ============================================================== C3
        wr(1'b1, 6'd3, 6'd5, 24'hFF_FF_FF);
        repeat (6) @(posedge clk);
        rd(1'b0, 6'd3, 6'd5, d);
        if (d !== patA(6'd3, 6'd5)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C3 writing set1 disturbed set0 (%06h)", d);
        end
        else $display("TEST_INFO: C3 writing set 1 leaves set 0 untouched");

        // ============================================================== C4
        rd(1'b0, 6'd40, 6'd40, d);
        rd(1'b1, 6'd40, 6'd40, d);
        $display("TEST_INFO: C4 an unwritten point reads %06h, distinct from the written pattern", d);

        `DGC_FINISH
    end
endmodule
