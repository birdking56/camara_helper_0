//-----------------------------------------------------------------------------
// tb_video_reader.v - stripe offer/release, raster order, underflow and discard
//
// A dramatically scaled raster is used (16 active pixels per line, still 1080
// lines and 68 stripes) so that the stripe logic runs exactly as it will on the
// board - stripe boundaries are 16 lines, the last stripe is 8 - while a whole
// frame costs about 27k clocks instead of 2.5M.
//
//   V1  stripes 0 and 1 published: lines 0..31 show their pixels, the rest of
//       the frame is black and underflow is counted once
//   V2  no offers at all: the whole frame is black, underflow counted once more
//   V3  stripes 0..2 published plus a stale stripe 5: 48 good lines, the stale
//       descriptor is discarded (status 2), never displayed
//   V4  stripe 0 arriving after the first active line: it cannot be shown, the
//       frame stays black and the late descriptor is returned
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_video_reader;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_VOUT) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    localparam integer H_ACT = 16;
    localparam integer H_TOTAL = 24;
    localparam integer V_ACT = 1080;
    localparam integer V_TOTAL = 1112;
    localparam integer RD_LAT = 2;
    localparam integer BLANK_PUB = V_ACT + 10;   // inside blanking, after vs_fall

    // ------------------------------------------------------------- raster
    integer hc = 0, vc = V_ACT + 4;
    reg raster_en = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) begin hc <= 0; vc <= V_ACT + 4; end
        else if (!raster_en) begin hc <= hc; vc <= vc; end
        else begin
            if (hc == H_TOTAL - 1) begin
                hc <= 0;
                vc <= (vc == V_TOTAL - 1) ? 0 : vc + 1;
            end
            else hc <= hc + 1;
        end
    end

    wire [11:0] x_act = hc[11:0];
    wire [11:0] y_act = vc[11:0];
    wire de_in = (hc < H_ACT) && (vc < V_ACT);
    wire hs_in = (hc == 0);
    wire vs_in = (vc >= V_ACT + 4) && (vc < V_ACT + 9);

    // ------------------------------------------------------------- DUT nets
    reg         offer_valid = 0;
    wire        offer_ready;
    reg  [63:0] offer_data = 0;
    wire        release_valid;
    wire        release_ready = 1'b1;
    wire [63:0] release_data;
    wire [14:0] r0_addr, r1_addr, r2_addr, r3_addr;
    wire [23:0] r0_data, r1_data, r2_data, r3_data;
    wire [23:0] rgb;
    wire        de_out, hs_out, vs_out;
    wire [31:0] cnt_underflow, cnt_frames, cnt_discard;
    wire        frame_black;

    // one memory per bank, both write and read ports on the same instance
    reg        wr_en = 0;
    reg  [1:0] wr_bank = 2'd0;
    reg [14:0] wr_addr = 0;
    reg [23:0] wr_data = 0;
    wire rst = ~rst_n;

    out_stripe_ram u_ram0 (
        .wr_data(wr_data), .wr_addr(wr_addr), .wr_en(wr_en & (wr_bank == 2'd0)),
        .wr_clk(clk), .wr_rst(rst),
        .rd_data(r0_data), .rd_addr(r0_addr), .rd_clk(clk), .rd_rst(rst));
    out_stripe_ram_1 u_ram1 (
        .wr_data(wr_data), .wr_addr(wr_addr), .wr_en(wr_en & (wr_bank == 2'd1)),
        .wr_clk(clk), .wr_rst(rst),
        .rd_data(r1_data), .rd_addr(r1_addr), .rd_clk(clk), .rd_rst(rst));
    out_stripe_ram u_ram2 (
        .wr_data(wr_data), .wr_addr(wr_addr), .wr_en(wr_en & (wr_bank == 2'd2)),
        .wr_clk(clk), .wr_rst(rst),
        .rd_data(r2_data), .rd_addr(r2_addr), .rd_clk(clk), .rd_rst(rst));
    out_stripe_ram_1 u_ram3 (
        .wr_data(wr_data), .wr_addr(wr_addr), .wr_en(wr_en & (wr_bank == 2'd3)),
        .wr_clk(clk), .wr_rst(rst),
        .rd_data(r3_data), .rd_addr(r3_addr), .rd_clk(clk), .rd_rst(rst));
    dgc_video_reader #(.RD_LAT(RD_LAT)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .de_in(de_in), .hs_in(hs_in), .vs_in(vs_in),
        .x_in(x_act), .y_in(y_act),
        .offer_valid(offer_valid), .offer_ready(offer_ready), .offer_data(offer_data),
        .release_valid(release_valid), .release_ready(release_ready),
        .release_data(release_data),
        .ram0_rd_addr(r0_addr), .ram0_rd_data(r0_data),
        .ram1_rd_addr(r1_addr), .ram1_rd_data(r1_data),
        .ram2_rd_addr(r2_addr), .ram2_rd_data(r2_data),
        .ram3_rd_addr(r3_addr), .ram3_rd_data(r3_data),
        .rgb(rgb), .de_out(de_out), .hs_out(hs_out), .vs_out(vs_out),
        .cnt_underflow(cnt_underflow), .cnt_frames(cnt_frames),
        .cnt_discard(cnt_discard), .frame_black(frame_black));

    // ------------------------------------------------------------- pattern
    function [23:0] pat(input [6:0] s, input [3:0] line, input [10:0] x);
        begin
            pat = {1'b0, s, line, x};
        end
    endfunction

    // --------------------------------------------------------- offer driver
    task publish(input [6:0] s, input [31:0] job);
        reg [1:0] pb;
        begin
            while (!offer_ready) @(posedge clk);
            pb = s[1:0];
            offer_data  <= {1'b0, pb[1], 1'b0, 5'd16, pb[0], s, 16'd1, job};
            offer_valid <= 1'b1;
            @(posedge clk); #0.2;
            offer_valid <= 1'b0;
        end
    endtask

    task wait_pos(input integer yy, input integer xx);
        begin
            while (!(vc == yy && hc == xx)) @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------- preload
    task load_stripe(input [6:0] s);
        integer i;
        begin
            for (i = 0; i < 16 * 16; i = i + 1) begin
                @(posedge clk); #0.2;
                wr_en   <= 1'b1;
                wr_bank <= s[1:0];
                wr_addr <= ((i / 16) * 2048 + (i % 16));
                wr_data <= pat(s, ((i / 16) % 16), (i % 16));
            end
            @(posedge clk); #0.2;
            wr_en <= 1'b0;
        end
    endtask

    // ------------------------------------------------------------- checker
    reg [1:0]  frame_no = 0;
    reg        good [0:63];
    integer    n_rel = 0;
    integer    n_rel_before = 0;
    integer    n_checked = 0;
    integer    rel_ids [0:31];

    always @(posedge clk) if (rst_n && release_valid && release_ready) begin
        if (n_rel < 32) rel_ids[n_rel] = release_data[54:48];
        n_rel = n_rel + 1;
    end

    reg [11:0] xd [0:RD_LAT-1];
    reg [11:0] yd [0:RD_LAT-1];
    integer k;
    always @(posedge clk) begin
        xd[0] <= x_act; yd[0] <= y_act;
        for (k = 1; k < RD_LAT; k = k + 1) begin
            xd[k] <= xd[k-1]; yd[k] <= yd[k-1];
        end
    end
    wire [11:0] x_dl = xd[RD_LAT-1];
    wire [11:0] y_dl = yd[RD_LAT-1];

    wire [6:0] sid_dl  = y_dl[10:4];
    wire [3:0] line_dl = y_dl[3:0];
    reg  [23:0] exp_rgb;

    always @(*) begin
        if (de_out && (sid_dl < 7'd68) && good[sid_dl])
            exp_rgb = pat(sid_dl, line_dl, x_dl[10:0]);
        else
            exp_rgb = 24'd0;
    end

    always @(posedge clk) begin
        if (rst_n && de_out) begin
            n_checked = n_checked + 1;
            if (rgb !== exp_rgb) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 15)
                    $display("TEST_FAIL: pixel (%0d,%0d) exp=%06h act=%06h frame=%0d",
                             x_dl, y_dl, exp_rgb, rgb, frame_no);
            end
        end
    end

    integer i, s;


    initial begin
        rst_n = 0;
        for (i = 0; i < 64; i = i + 1) good[i] = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // =============================================================== V1
        // Preload while the raster is frozen in the vertical blanking, then let
        // it run: stripe 0 must be published during the blanking and stripe 1
        // while stripe 0 is being scanned.
        frame_no = 1;
        good[0] = 1'b1; good[1] = 1'b1;
        load_stripe(7'd0);
        load_stripe(7'd1);
        raster_en = 1'b1;
        wait_pos(BLANK_PUB, 0);
        publish(7'd0, 32'hAAAA_0001);
        wait_pos(1, 0);
        publish(7'd1, 32'hAAAA_0001);
        wait_pos(BLANK_PUB, 0);
        if (cnt_underflow !== 32'd1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: V1 underflow exp=1 act=%0d", cnt_underflow); end
        else $display("TEST_INFO: V1 stripes 0/1 displayed, lines 32.. are black, one underflow");

        // =============================================================== V2
        // no offers at all; advance into the next frame first, otherwise the
        // wait below would see the position V1 already stopped at
        frame_no = 2;
        n_rel_before = n_rel;
        for (i = 0; i < 64; i = i + 1) good[i] = 1'b0;
        wait_pos(0, 0);
        wait_pos(BLANK_PUB, 0);
        if (cnt_underflow !== 32'd2) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: V2 underflow exp=2 act=%0d", cnt_underflow); end
        // A missing stripe was never owned by this reader, so it must NOT send a
        // release: that would free the bank the writer is still filling.
        if (n_rel !== n_rel_before) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: V2 released %0d banks without owning a stripe",
                     n_rel - n_rel_before);
        end
        else $display("TEST_INFO: V2 no stripe offered: whole frame black, no release");

        // =============================================================== V3
        // freeze in the blanking, preload stripes 0 and 1, resume. Stripe 2 goes
        // into bank 0 only after stripe 0 has been released (end of line 15),
        // which is exactly how the writer is allowed to use the other bank.
        frame_no = 3;
        good[0] = 1'b1; good[1] = 1'b1;
        raster_en = 1'b0;
        load_stripe(7'd0);
        load_stripe(7'd1);
        raster_en = 1'b1;
        publish(7'd0, 32'hBBBB_0002);
        wait_pos(1, 0);
        publish(7'd1, 32'hBBBB_0002);
        wait_pos(16, 0);
        load_stripe(7'd2);              // bank 0 is free from here on
        wait_pos(30, 0);
        good[2] = 1'b1;
        publish(7'd2, 32'hBBBB_0002);
        wait_pos(33, 0);
        publish(7'd5, 32'hBBBB_0002);   // stale: must be discarded
        wait_pos(BLANK_PUB, 0);
        if (cnt_discard !== 32'd1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: V3 discard exp=1 act=%0d", cnt_discard); end
        else $display("TEST_INFO: V3 stripes 0..2 displayed, a stale stripe 5 was discarded");
        if (cnt_underflow !== 32'd3) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: V3 underflow exp=3 act=%0d", cnt_underflow); end

        // =============================================================== V4
        frame_no = 4;
        good[0] = 1'b0; good[1] = 1'b0; good[2] = 1'b0;
        wait_pos(1, 0);                  // the frame has already started
        publish(7'd0, 32'hCCCC_0003);
        wait_pos(BLANK_PUB, 0);
        if (cnt_underflow !== 32'd4) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: V4 underflow exp=4 act=%0d", cnt_underflow); end
        else $display("TEST_INFO: V4 a late stripe 0 cannot be shown, the frame stays black");

        $display("TEST_INFO: releases=%0d checked_pixels=%0d discards=%0d underflows=%0d",
                 n_rel, n_checked, cnt_discard, cnt_underflow);
        `DGC_FINISH
    end
endmodule




