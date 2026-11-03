// Isolated split test: no enumeration checks, so a failure here can only be the
// split path.
`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_split_only;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    reg frame_start = 0;
    wire        blk_valid;
    reg         blk_ready = 1;
    wire [15:0] blk_tag;
    wire [6:0]  blk_stripe;
    wire [10:0] blk_x0, blk_y0;
    wire [6:0]  blk_w, blk_h;
    reg         rpt_valid = 0;
    reg         split_valid = 0;
    reg  [15:0] split_tag = 0;
    reg  [6:0]  split_w = 0, split_h = 0;
    wire        frame_done;
    wire [15:0] cnt_blocks;
    wire [31:0] cnt_split;
    wire [15:0] next_tag;

    dgc_tile_scheduler u_dut (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start),
        .blk_valid(blk_valid), .blk_ready(blk_ready), .blk_tag(blk_tag),
        .blk_stripe(blk_stripe), .blk_x0(blk_x0), .blk_y0(blk_y0),
        .blk_w(blk_w), .blk_h(blk_h), .rpt_valid(rpt_valid),
        .split_valid(split_valid), .split_tag(split_tag),
        .split_w(split_w), .split_h(split_h),
        .frame_done(frame_done), .cnt_blocks(cnt_blocks), .cnt_split(cnt_split),
        .next_tag(next_tag));

    integer n = 0;
    integer sx, sy;
    integer c1_x, c1_y, c1_w, c1_h;
    integer c2_x, c2_y, c2_w, c2_h;
    reg     got1 = 0, got2 = 0;

    always @(posedge clk) begin
        rpt_valid   <= 1'b0;
        split_valid <= 1'b0;
        if (rst_n && blk_valid && blk_ready) begin
            n = n + 1;
            if (n == 3) begin
                sx = blk_x0; sy = blk_y0;
                rpt_valid   <= 1'b1;
                split_valid <= 1'b1;
                split_w     <= 7'd65;   // wider than 64 -> must bisect x
                split_h     <= 7'd16;
                split_tag   <= blk_tag;
            end
            else begin
                rpt_valid <= 1'b1;
                if (n == 4) begin
                    got1 = 1;
                    c1_x = blk_x0; c1_y = blk_y0; c1_w = blk_w; c1_h = blk_h;
                end
                if (n == 5) begin
                    got2 = 1;
                    c2_x = blk_x0; c2_y = blk_y0; c2_w = blk_w; c2_h = blk_h;
                end
            end
        end
    end

    integer i;
    initial begin
        rst_n = 0; blk_ready = 1;
        repeat (8) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        @(posedge clk); #0.2; frame_start <= 1'b1;
        @(posedge clk); #0.2; frame_start <= 1'b0;
        i = 0;
        while (!got2 && i < 500) begin @(posedge clk); i = i + 1; end
        repeat (10) @(posedge clk);

        $display("TEST_INFO: blocks emitted=%0d, split origin=%0d,%0d, cnt_split=%0d", n, sx, sy, cnt_split);
        if (!got1 || !got2) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E2 children never appeared (got1=%0d got2=%0d n=%0d)", got1, got2, n);
        end
        else begin
            $display("TEST_INFO: E2 child1 = %0d,%0d %0dx%0d", c1_x, c1_y, c1_w, c1_h);
            $display("TEST_INFO: E2 child2 = %0d,%0d %0dx%0d", c2_x, c2_y, c2_w, c2_h);
            if (c1_x != sx || c1_y != sy || c1_w != 16 || c1_h != 16) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: E2 front child expected %0d,%0d 16x16", sx, sy);
            end
            if (c2_x != (sx + 16) || c2_y != sy || c2_w != 16 || c2_h != 16) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: E2 back child expected %0d,%0d 16x16", sx+16, sy);
            end
            if (dgc_errors == 0)
                $display("TEST_INFO: E2 a 65x16 bbox bisects the 32-wide output into 16x16 + 16x16, front first");
        end
        `DGC_FINISH
    end
endmodule
