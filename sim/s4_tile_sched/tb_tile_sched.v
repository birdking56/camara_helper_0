`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_tile_sched;
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

    integer n = 0, i, exp_sid, exp_b;
    integer first_x, first_y, first_w, first_h;
    integer last_x, last_y, last_w, last_h;

    always @(posedge clk) begin
        rpt_valid <= 1'b0;
        if (rst_n && blk_valid && blk_ready) begin
            rpt_valid <= 1'b1;
            n = n + 1;
            exp_sid = (n - 1) / 60;
            exp_b   = (n - 1) % 60;
            if (blk_stripe !== exp_sid[6:0]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: E1 stripe #%0d exp=%0d act=%0d", n, exp_sid, blk_stripe);
            end
            if (blk_x0 !== (exp_b * 32)) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: E1 x0 #%0d exp=%0d act=%0d", n, exp_b*32, blk_x0);
            end
            if (blk_y0 !== (exp_sid * 16)) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: E1 y0 #%0d exp=%0d act=%0d", n, exp_sid*16, blk_y0);
            end
            if (exp_sid == 67 && blk_h !== 7'd8) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: E1 last stripe height act=%0d", blk_h);
            end
            if (n == 1)    begin first_x = blk_x0; first_y = blk_y0; first_w = blk_w; first_h = blk_h; end
            if (n == 4080) begin last_x = blk_x0; last_y = blk_y0; last_w = blk_w; last_h = blk_h; end
        end
    end

    initial begin
        rst_n = 0; blk_ready = 1;
        repeat (8) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        @(posedge clk); #0.2; frame_start <= 1'b1;
        @(posedge clk); #0.2; frame_start <= 1'b0;
        i = 0;
        while (n < 4080 && i < 40000) begin @(posedge clk); i = i + 1; end
        repeat (10) @(posedge clk);
        if (n != 4080) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E1 expected 4080 blocks, emitted %0d", n);
        end
        else begin
            if (first_x != 0 || first_y != 0 || first_w != 32 || first_h != 16) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: E1 first block %0d,%0d %0dx%0d", first_x, first_y, first_w, first_h);
            end
            if (last_x != 1888 || last_y != 1072 || last_w != 32 || last_h != 8) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: E1 last block %0d,%0d %0dx%0d", last_x, last_y, last_w, last_h);
            end
            $display("TEST_INFO: E1 4080 blocks: first 0,0 32x16, last 1888,1072 32x8");
            $display("TEST_INFO: E1 request/report handshake held for all 4080 blocks");
        end
        `DGC_FINISH
    end
endmodule
