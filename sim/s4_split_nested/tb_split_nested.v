// Nested split: a child that itself splits must be resolved depth-first before
// its sibling appears. Independent of the enumeration test.
//
// Expected order, starting at enumeration block 3 = (64,0) 32x16:
//   3 (64,0) 32x16      <- split with bbox 65x16
//   4 (64,0) 16x16      front child  <- split with bbox 65x8 (16x16 ties on x)
//   5 (64,0)  8x16      front grandchild
//   6 (72,0)  8x16      back grandchild
//   7 (80,0) 16x16      back child of the first split
//   8 (96,0) 32x16      enumeration resumes
`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_split_nested;
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
    integer qx [0:15], qy [0:15], qw [0:15], qh [0:15];

    always @(posedge clk) begin
        rpt_valid   <= 1'b0;
        split_valid <= 1'b0;
        if (rst_n && blk_valid && blk_ready) begin
            n = n + 1;
            if (n <= 15) begin
                qx[n] = blk_x0; qy[n] = blk_y0; qw[n] = blk_w; qh[n] = blk_h;
            end
            if (n == 3) begin
                rpt_valid <= 1'b1; split_valid <= 1'b1;
                split_w <= 7'd65; split_h <= 7'd16; split_tag <= blk_tag;
            end
            else if (n == 4) begin
                rpt_valid <= 1'b1; split_valid <= 1'b1;
                split_w <= 7'd65; split_h <= 7'd8; split_tag <= blk_tag;
            end
            else rpt_valid <= 1'b1;
        end
    end

    task chk(input integer idx, input integer ex, ey, ew, eh);
        begin
            if (qx[idx] != ex || qy[idx] != ey || qw[idx] != ew || qh[idx] != eh) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: N block %0d exp=%0d,%0d %0dx%0d act=%0d,%0d %0dx%0d",
                         idx, ex, ey, ew, eh, qx[idx], qy[idx], qw[idx], qh[idx]);
            end
        end
    endtask

    integer i;
    initial begin
        rst_n = 0; blk_ready = 1;
        repeat (8) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        @(posedge clk); #0.2; frame_start <= 1'b1;
        @(posedge clk); #0.2; frame_start <= 1'b0;
        i = 0;
        while (n < 8 && i < 500) begin @(posedge clk); i = i + 1; end
        repeat (10) @(posedge clk);

        $display("TEST_INFO: N emitted=%0d cnt_split=%0d", n, cnt_split);
        chk(3, 64, 0, 32, 16);
        chk(4, 64, 0, 16, 16);
        chk(5, 64, 0,  8, 16);
        chk(6, 72, 0,  8, 16);
        chk(7, 80, 0, 16, 16);
        chk(8, 96, 0, 32, 16);
        if (dgc_errors == 0)
            $display("TEST_INFO: N depth-first order held: front grandchild, back grandchild, back child, then enumeration");
        `DGC_FINISH
    end
endmodule
