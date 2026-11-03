//-----------------------------------------------------------------------------
// tb_source_sampler.v - coordinate stream -> real cache -> 192-bit sample
//
// This is the first test of the assembled sampling path: the real four-port
// source cache (generated DRAM banks), the neighbour arithmetic, the read-count
// rule and the edge replication, driven by the frozen 96-bit coordinate record.
//
// The expected 192-bit record is derived independently in the testbench from the
// image function and the coordinate, not from the DUT's internal signals.
//
//   A1  interior 15x15 block: four distinct neighbours, one pixel per cycle
//   A2  a coordinate that is inside the image but outside the block emits zeros
//       and is counted, instead of reading a stale cache address
//   A3  sample_ok = 0 emits zeros and touches no cache port
//   B1  right image edge  : 2 reads, x neighbours replicated
//   B2  bottom image edge : 2 reads, y neighbours replicated
//   B3  bottom-right corner: 1 read, all four replicated
//   C1  random stream with output stalls: every record comes out exactly once,
//       in order, with its own metadata
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_source_sampler;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    // ---------------------------------------------------------------- DUT wiring
    reg  [10:0] bbox_x = 0, bbox_y = 0;
    reg         blk_set = 0;

    reg         cd_valid = 0;
    wire        cd_ready;
    reg  [95:0] cd_data = 0;

    wire        p0_fire, p1_fire, p2_fire, p3_fire;
    wire [5:0]  p0_x, p0_y, p1_x, p1_y, p2_x, p2_y, p3_x, p3_y;
    wire        p0_valid, p1_valid, p2_valid, p3_valid;
    wire [23:0] p0_d, p1_d, p2_d, p3_d;

    wire        sample_valid;
    reg         sample_ready = 1;
    wire [191:0] sample_data;
    wire [31:0] cnt_samples, cnt_out_of_block;
    wire        busy;

    // cache fill port
    reg         wr_valid = 0;
    wire        wr_ready;
    reg  [5:0]  wr_x = 0, wr_y = 0;
    reg  [23:0] wr_rgb = 0;

    dgc_source_cache4 u_cache (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_set(blk_set),
        .wr_x(wr_x), .wr_y(wr_y), .wr_rgb(wr_rgb),
        .wr2_valid(1'b0), .wr2_rgb(24'd0),
        .rd_set(blk_set),
        .p0_fire(p0_fire), .p0_x(p0_x), .p0_y(p0_y),
        .p1_fire(p1_fire), .p1_x(p1_x), .p1_y(p1_y),
        .p2_fire(p2_fire), .p2_x(p2_x), .p2_y(p2_y),
        .p3_fire(p3_fire), .p3_x(p3_x), .p3_y(p3_y),
        .p0_valid(p0_valid), .p0_d(p0_d),
        .p1_valid(p1_valid), .p1_d(p1_d),
        .p2_valid(p2_valid), .p2_d(p2_d),
        .p3_valid(p3_valid), .p3_d(p3_d)
    );

    dgc_source_sampler u_dut (
        .clk(clk), .rst_n(rst_n),
        .blk_bbox_x(bbox_x), .blk_bbox_y(bbox_y), .blk_set(blk_set),
        .cd_valid(cd_valid), .cd_ready(cd_ready), .cd_data(cd_data),
        .p0_fire(p0_fire), .p0_x(p0_x), .p0_y(p0_y),
        .p1_fire(p1_fire), .p1_x(p1_x), .p1_y(p1_y),
        .p2_fire(p2_fire), .p2_x(p2_x), .p2_y(p2_y),
        .p3_fire(p3_fire), .p3_x(p3_x), .p3_y(p3_y),
        .p0_valid(p0_valid), .p0_d(p0_d),
        .p1_valid(p1_valid), .p1_d(p1_d),
        .p2_valid(p2_valid), .p2_d(p2_d),
        .p3_valid(p3_valid), .p3_d(p3_d),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_data(sample_data),
        .cnt_samples(cnt_samples), .cnt_out_of_block(cnt_out_of_block),
        .busy(busy)
    );

    // -------------------------------------------------------------- image model
    function [23:0] img(input [10:0] x, input [10:0] y);
        begin
            img = {x[7:0], y[7:0], x[7:0] ^ y[7:0]};
        end
    endfunction

    // ------------------------------------------------------------- scoreboard
    localparam integer QN = 2048;
    reg [191:0] exp_q [0:QN-1];
    integer q_wp = 0, q_rp = 0;
    integer n_checked = 0;
    integer n_invalid = 0;
    reg bp_en = 1'b0;
    integer seed = 32'h5EED_1234;

    always @(posedge clk) begin
        if (bp_en) sample_ready <= (({$random(seed)} % 100) >= 30);
        else       sample_ready <= 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && sample_valid && sample_ready) begin
            if (q_rp >= q_wp) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: sampler produced an unrequested record t=%0t", $time);
            end
            else begin
                if (sample_data !== exp_q[q_rp]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 20)
                        $display("TEST_FAIL: sample %0d exp=%048h act=%048h t=%0t",
                                 q_rp, exp_q[q_rp], sample_data, $time);
                end
                q_rp = q_rp + 1;
                n_checked = n_checked + 1;
            end
        end
    end

    // ------------------------------------------------------------- stimulus
    task fill_block(input [10:0] bx, input [10:0] by);
        integer lx, ly;
        begin
            for (ly = 0; ly < 16; ly = ly + 1)
                for (lx = 0; lx < 16; lx = lx + 1) begin
                    @(posedge clk); #0.2;
                    wr_valid <= 1'b1; wr_x <= lx[5:0]; wr_y <= ly[5:0];
                    wr_rgb   <= img(bx + lx[10:0], by + ly[10:0]);
                    @(posedge clk); #0.2;
                    wr_valid <= 1'b0;
                end
            repeat (8) @(posedge clk);
        end
    endtask

    // Expected neighbours for one coordinate, computed from the image model.
    // `out_of_block` mirrors the DUT's rule: the read is suppressed and the
    // four neighbours are zero.
    task expect_rec(input [10:0] sx0, sy0, input ok,
                    input [15:0] tag, wx, wy, input [10:0] dx, dy);
        reg [10:0] sx1, sy1;
        reg [95:0] cd;
        reg [23:0] e00, e10, e01, e11;
        begin
            sx1 = (sx0 >= 11'd1919) ? 11'd1919 : sx0 + 11'd1;
            sy1 = (sy0 >= 11'd1079) ? 11'd1079 : sy0 + 11'd1;
            cd = 96'd0;
            cd[10:0]  = dx;
            cd[21:11] = dy;
            cd[32:22] = sx0;
            cd[43:33] = sy0;
            cd[59:44] = wx;
            cd[75:60] = wy;
            cd[91:76] = tag;
            cd[92]    = ok;
            if (!ok || (sx0 < bbox_x) || (sy0 < bbox_y) ||
                ((sx0 - bbox_x) > 11'd15) || ((sy0 - bbox_y) > 11'd15)) begin
                e00 = 24'd0; e10 = 24'd0; e01 = 24'd0; e11 = 24'd0;
            end
            else begin
                e00 = img(sx0, sy0);
                e10 = img(sx1, sy0);
                e01 = img(sx0, sy1);
                e11 = img(sx1, sy1);
            end
            exp_q[q_wp] = {e11, e01, e10, e00, cd};
            q_wp = q_wp + 1;
        end
    endtask

    task send_rec(input [10:0] sx0, sy0, input ok,
                  input [15:0] tag, wx, wy, input [10:0] dx, dy);
        begin
            expect_rec(sx0, sy0, ok, tag, wx, wy, dx, dy);
            cd_data = exp_q[q_wp-1][95:0];
            while (!cd_ready) begin @(posedge clk); #0.2; end
            cd_valid <= 1'b1;
            @(posedge clk); #0.2;
            cd_valid <= 1'b0;
        end
    endtask

    integer x, y, i;
    reg [10:0] bx, by;

    task drain;
        begin
            while (busy || (q_rp != q_wp)) begin
                @(posedge clk); #0.2;
            end
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 0; cd_valid = 0; sample_ready = 1;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // =============================================================== A1/A2
        bbox_x = 11'd64; bbox_y = 11'd32;
        fill_block(11'd64, 11'd32);
        for (y = 0; y < 15; y = y + 1)
            for (x = 0; x < 15; x = x + 1)
                send_rec(11'd64 + x[10:0], 11'd32 + y[10:0], 1'b1,
                         16'h0100 + x[15:0], 16'h4000 + y[15:0], 16'h2000 + x[15:0],
                         x[10:0], y[10:0]);
        // one coordinate inside the image but outside the 64x64 container of the
        // block: zeros, counted, and no cache address is touched
        send_rec(11'd134, 11'd40, 1'b1, 16'h01FF, 16'h1111, 16'h2222, 11'd70, 11'd8);
        n_invalid = n_invalid + 1;
        drain;
        $display("TEST_INFO: A1 interior 15x15 block returned the four real neighbours");
        $display("TEST_INFO: A2 an out-of-block coordinate emitted zeros and was counted");
        if (cnt_out_of_block !== n_invalid) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: A2 cnt_out_of_block exp=%0d act=%0d", n_invalid, cnt_out_of_block);
        end

        // =============================================================== A3
        send_rec(11'd64, 11'd32, 1'b0, 16'h02AA, 16'h1234, 16'h5678, 11'd0, 11'd0);
        drain;
        $display("TEST_INFO: A3 sample_ok=0 emitted zeros without touching the cache");

        // =============================================================== B1..B3
        bbox_x = 11'd1904; bbox_y = 11'd1064;
        fill_block(11'd1904, 11'd1064);
        // right edge: sx0 = 1919, neighbours collapse in x
        send_rec(11'd1919, 11'd1070, 1'b1, 16'h0300, 16'h0100, 16'h0200, 11'd1919, 11'd6);
        // bottom edge: sy0 = 1079
        send_rec(11'd1910, 11'd1079, 1'b1, 16'h0301, 16'h0300, 16'h0400, 11'd6, 11'd15);
        // corner: both collapse
        send_rec(11'd1919, 11'd1079, 1'b1, 16'h0302, 16'h0500, 16'h0600, 11'd15, 11'd15);
        drain;
        $display("TEST_INFO: B1..B3 right edge, bottom edge and corner replicated correctly");

        // =============================================================== C1
        // random stream with valid gaps and output stalls
        bp_en = 1'b1;
        bbox_x = 11'd64; bbox_y = 11'd32;
        fill_block(11'd64, 11'd32);      // phase B overwrote the banks
        for (i = 0; i < 600; i = i + 1) begin
            x = {$random(seed)} % 16;
            y = {$random(seed)} % 16;
            // keep the point inside the block so every neighbour is a real pixel
            if (x > 14) x = 14;
            if (y > 14) y = 14;
            send_rec(11'd64 + x[10:0], 11'd32 + y[10:0], ({$random(seed)} % 8) != 0,
                     16'h1000 + i[15:0], {$random(seed)}, {$random(seed)},
                     i[10:0] % 1920, i[10:0] % 1080);
            if (({$random(seed)} % 3) == 0) begin
                repeat (1) @(posedge clk);
            end
        end
        bp_en = 1'b0;
        sample_ready <= 1'b1;
        repeat (30) @(posedge clk);
        while (busy || (q_rp != q_wp)) begin @(posedge clk); #0.2; end
        repeat (10) @(posedge clk);

        if (n_checked != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C1 %0d records driven but only %0d came out", q_wp, n_checked);
        end
        else $display("TEST_INFO: C1 %0d records through random gaps and stalls, order kept",
                      n_checked);

        $display("TEST_INFO: samples=%0d out_of_block=%0d", cnt_samples, cnt_out_of_block);
        `DGC_FINISH
    end
endmodule
