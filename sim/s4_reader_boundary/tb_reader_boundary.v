//-----------------------------------------------------------------------------
// tb_reader_boundary.v
//
// Directed regression for the 2026-10-29 reader bank leak:
//
//   A frame that ends while the reader still owns banks must return them.
//   Before the fix, vs_fall cleared cur_ok/have_next without pushing any
//   release, so the writer's `reading[bank]` stayed set forever and px_ready
//   stayed low -> bilinear stalled -> core deadlocked in C_SAMPLE.
//   Board signature: bank0_busy=1, px_ready=0, samp_busy=1, sample_left=497.
//
// Stimulus (short raster, 8 active lines so no stripe_end can occur):
//   1. reset, wait for vs_fall -> waiting_first
//   2. in blanking publish stripe 0 -> take_first  (owns bank 0)
//   3. publish stripe 1           -> take_prefetch (owns bank 1)
//   4. next active frame is only 8 lines -> no stripe_end
//   5. next vs_fall: BOTH banks must be released with status 2 (discarded)
//
// Checks: exactly two releases, banks {0,1}, stripes {0,1}, status 2, before
// the reader accepts anything of the following frame.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_reader_boundary;

    integer dgc_errors = 0;

    reg clk = 0;
    always #3.367 clk = ~clk;

    reg rst_n = 0;

    // ------------------------------------------------------------- raster
    localparam integer H_TOTAL = 64;
    localparam integer H_ACT   = 32;
    localparam integer V_TOTAL = 60;
    localparam integer V_ACT   = 8;      // fewer than 16 lines -> no stripe_end
    localparam integer VS0     = 20;
    localparam integer VS1     = 24;

    integer hc = 0, vc = 0;
    always @(posedge clk) begin
        if (!rst_n) begin hc <= 0; vc <= 0; end
        else begin
            if (hc == H_TOTAL-1) begin
                hc <= 0;
                vc <= (vc == V_TOTAL-1) ? 0 : vc + 1;
            end
            else hc <= hc + 1;
        end
    end

    wire vs_in = (vc >= VS0) && (vc < VS1);
    wire de_in = (vc < V_ACT) && (hc < H_ACT);
    wire hs_in = (hc < 4);

    // ------------------------------------------------------------- DUT nets
    reg         offer_valid = 0;
    wire        offer_ready;
    reg  [63:0] offer_data = 0;
    wire        release_valid;
    wire        release_ready = 1'b1;
    wire [63:0] release_data;
    wire [14:0] r0_addr, r1_addr;
    wire [23:0] rgb;
    wire        de_out, hs_out, vs_out;
    wire [31:0] cnt_underflow, cnt_frames, cnt_discard;
    wire        frame_black;

    dgc_video_reader #(.RD_LAT(2)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .de_in(de_in), .hs_in(hs_in), .vs_in(vs_in),
        .x_in(hc[11:0]), .y_in(vc[11:0]),
        .offer_valid(offer_valid), .offer_ready(offer_ready), .offer_data(offer_data),
        .release_valid(release_valid), .release_ready(release_ready),
        .release_data(release_data),
        .ram0_rd_addr(r0_addr), .ram0_rd_data(24'd0),
        .ram1_rd_addr(r1_addr), .ram1_rd_data(24'd0),
        .ram2_rd_addr(), .ram2_rd_data(24'd0),
        .ram3_rd_addr(), .ram3_rd_data(24'd0),
        .rgb(rgb), .de_out(de_out), .hs_out(hs_out), .vs_out(vs_out),
        .cnt_underflow(cnt_underflow), .cnt_frames(cnt_frames),
        .cnt_discard(cnt_discard), .frame_black(frame_black));

    // ------------------------------------------------------- release monitor
    integer   n_rel = 0;
    integer   rel_bank0 = 0, rel_bank1 = 0;
    integer   rel_str0 = 0, rel_str1 = 0;
    integer   rel_status2 = 0;

    always @(posedge clk) begin
        if (rst_n && release_valid && release_ready) begin
            n_rel = n_rel + 1;
            // release_data = {22'd0, status[1:0], bank, stripe[6:0], job[31:0]}
            if (release_data[39] == 1'b0) begin
                rel_bank0 = rel_bank0 + 1;
                if (release_data[38:32] == 7'd0) rel_str0 = rel_str0 + 1;
            end
            else begin
                rel_bank1 = rel_bank1 + 1;
                if (release_data[38:32] == 7'd1) rel_str1 = rel_str1 + 1;
            end
            if (release_data[41:40] == 2'd2) rel_status2 = rel_status2 + 1;
            $display("TEST_INFO: release bank=%0d stripe=%0d status=%0d",
                     release_data[39], release_data[38:32], release_data[41:40]);
        end
    end

    function [63:0] offer_word(input [6:0] s, input [1:0] b, input [31:0] job);
        begin
            offer_word = {1'b0, b[1], 1'b0, 5'd16, b[0], s, 16'd0, job};
        end
    endfunction

    task publish(input [6:0] s, input [1:0] b, input [31:0] job);
        begin
            @(posedge clk);
            offer_valid <= 1'b1;
            offer_data  <= offer_word(s, b, job);
            @(posedge clk);
            offer_valid <= 1'b0;
            offer_data  <= 64'd0;
        end
    endtask

    // wait for a vs_fall (vc passes the VS window end)
    task wait_vs_fall;
        begin
            @(posedge clk);
            while (!((vc == VS1) && (hc == 0))) @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // 1. reach a vs_fall so waiting_first is set
        wait_vs_fall();
        @(posedge clk);   // let the reader's vs_fall update settle before sampling
        $display("TEST_INFO: V5 after first vs_fall, waiting_first=%0d", u_dut.waiting_first);
        if (u_dut.waiting_first !== 1'b1) `DGC_FAIL("V5 waiting_first not set after vs_fall")

        // 2/3. own bank 0 (first) and bank 1 (prefetch) during blanking
        publish(7'd0, 2'd0, 32'h0000_0007);
        @(posedge clk);
        if (u_dut.cur_ok !== 1'b1) `DGC_FAIL("V5 stripe 0 was not taken as first")
        if (u_dut.cur_bank !== 1'b0) `DGC_FAIL("V5 stripe 0 bank mismatch")
        publish(7'd1, 2'd1, 32'h0000_0007);
        @(posedge clk);
        if (u_dut.have_next !== 1'b1) `DGC_FAIL("V5 stripe 1 was not prefetched")
        if (u_dut.next_bank !== 1'b1) `DGC_FAIL("V5 stripe 1 bank mismatch")
        $display("TEST_INFO: V5 reader owns bank0 (first) and bank1 (prefetch)");

        // 4/5. the coming frame has only 8 active lines; its vs_fall must release both
        wait_vs_fall();
        repeat (4) @(posedge clk);

        $display("TEST_INFO: V5 releases: total=%0d bank0=%0d(stripe0=%0d) bank1=%0d(stripe1=%0d) status2=%0d",
                 n_rel, rel_bank0, rel_str0, rel_bank1, rel_str1, rel_status2);
        if (n_rel != 2)           `DGC_FAIL("V5 bank leak: expected exactly 2 releases at the frame boundary")
        if (rel_bank0 != 1)       `DGC_FAIL("V5 bank0 was not released")
        if (rel_str0 != 1)        `DGC_FAIL("V5 stripe0 release missing")
        if (rel_bank1 != 1)       `DGC_FAIL("V5 bank1 was not released")
        if (rel_str1 != 1)        `DGC_FAIL("V5 stripe1 release missing")
        if (rel_status2 != 2)     `DGC_FAIL("V5 frame-boundary releases must carry status 2")

        if (dgc_errors == 0) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d", dgc_errors);
        $finish;
    end

endmodule





