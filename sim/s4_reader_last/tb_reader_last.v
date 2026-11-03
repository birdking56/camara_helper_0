//-----------------------------------------------------------------------------
// tb_reader_last.v - stripe 67 / frame boundary ownership (DGC5, 2026-10-31)
//
// The reader used to release stripe 67 at `frame_last` and then release the same
// bank *again* at vs_fall, because `cur_ok` was left set. The second release
// arrives during vertical blanking, exactly when the writer may have started the
// next frame's stripe in that bank, and clears its `reading` bit. From then on
// the reader and the writer disagree about who owns the bank, which is the
// precondition of the 2026-10-31 black screen.
//
// This test drives DE/VS directly (no raster) and scans a complete 68-stripe
// frame:
//
//   L1  every stripe is released exactly once, in order, with status 0
//   L2  frame_last (stripe 67, 8 lines) does not release the bank twice
//   L3  the following vs_fall pushes nothing (cur_ok was cleared at frame_last)
//   L4  a stripe-0 offer accepted on the same edge as vs_fall takes ownership
//       and does not release the bank it just took (priority: new ownership wins)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_reader_last;

    integer dgc_errors = 0;

    reg clk = 0;
    always #3.367 clk = ~clk;

    reg rst_n = 0;

    reg        de_in = 0, hs_in = 0, vs_in = 0;
    reg [11:0] x_in = 0, y_in = 0;

    reg         offer_valid = 0;
    wire        offer_ready;
    reg  [63:0] offer_data = 0;
    wire        release_valid;
    wire [63:0] release_data;
    wire [14:0] r0_addr, r1_addr;
    wire [23:0] rgb;
    wire        de_out, hs_out, vs_out;
    wire [31:0] cnt_underflow, cnt_frames, cnt_discard, cnt_offers, cnt_releases;
    wire [15:0] cnt_rel_drop;
    wire        frame_black;

    dgc_video_reader #(.RD_LAT(2)) u_dut (
        .clk (clk), .rst_n (rst_n),
        .de_in (de_in), .hs_in (hs_in), .vs_in (vs_in),
        .x_in (x_in), .y_in (y_in),
        .offer_valid (offer_valid), .offer_ready (offer_ready),
        .offer_data (offer_data),
        .release_valid (release_valid), .release_ready (1'b1),
        .release_data (release_data),
        .ram0_rd_addr (r0_addr), .ram0_rd_data (24'd0),
        .ram1_rd_addr (r1_addr), .ram1_rd_data (24'd0),
        .ram2_rd_addr (), .ram2_rd_data (24'd0),
        .rgb (rgb), .de_out (de_out), .hs_out (hs_out), .vs_out (vs_out),
        .cnt_underflow (cnt_underflow), .cnt_frames (cnt_frames),
        .cnt_discard (cnt_discard), .cnt_offers (cnt_offers),
        .cnt_releases (cnt_releases), .cnt_rel_drop (cnt_rel_drop),
        .frame_black (frame_black),
        .dbg_cur_stripe (), .dbg_frame_ok (), .dbg_cur_ok (),
        .dbg_waiting_first (), .dbg_have_next (),
        .dbg_cur_bank (), .dbg_next_bank (),
        .dbg_events (), .dbg_vs_discard ()
    );

    // ------------------------------------------------------- release monitor
    integer n_rel = 0;
    integer bad_status = 0, bad_bank = 0, bad_stripe = 0;
    integer last_stripe = -1;
    wire [6:0] rel_stripe = release_data[38:32];
    wire [1:0] rel_bank   = {release_data[42], release_data[39]};

    always @(posedge clk) begin
        if (rst_n && release_valid) begin
            n_rel = n_rel + 1;
            if (release_data[41:40] !== 2'd0) bad_status = bad_status + 1;
            if (rel_stripe !== (last_stripe + 1)) bad_stripe = bad_stripe + 1;
            if (rel_bank !== rel_stripe[1:0]) bad_bank = bad_bank + 1;
            last_stripe = last_stripe + 1;
        end
    end

    function [63:0] offer_word(input [6:0] s, input [1:0] b, input [31:0] job);
        begin
            offer_word = {1'b0, b[1], 1'b0, 5'd16, b[0], s, 16'd0, job};
        end
    endfunction

    // one offer, accepted on the next edge (offer_ready is tied to the reader's
    // always-ready port; drive valid for exactly one cycle)
    task publish(input [6:0] s, input [1:0] b, input [31:0] job);
        begin
            @(negedge clk);
            offer_valid = 1'b1;
            offer_data  = offer_word(s, b, job);
            @(negedge clk);
            offer_valid = 1'b0;
            offer_data  = 64'd0;
        end
    endtask

    // one active line: 4 cycles DE high, 4 low (x/y do not matter here)
    task one_line;
        begin
            @(negedge clk); de_in = 1'b1;
            repeat (3) @(negedge clk);
            de_in = 1'b0;
            repeat (3) @(negedge clk);
        end
    endtask

    task vs_pulse;
        begin
            @(negedge clk); vs_in = 1'b1;
            repeat (3) @(negedge clk);
            vs_in = 1'b0;
            repeat (3) @(negedge clk);
        end
    endtask

    integer s, l;
    integer rel_before;
    reg [63:0] rel_word;
    reg        rel_seen;

    initial begin
        $display("TEST_INFO: reader last-stripe test start");
        rst_n = 0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ---------------------------------------------------------- L1/L2
        vs_pulse();                       // waiting_first
        publish(7'd0, 2'd0, 32'h11);      // stripe 0 -> bank 0, take_first
        repeat (2) @(posedge clk);
        if (u_dut.cur_ok !== 1'b1) `DGC_FAIL("L1 stripe 0 not taken")
        if (u_dut.frame_ok !== 1'b1) `DGC_FAIL("L1 frame not ok after stripe 0")

        for (s = 0; s < 68; s = s + 1) begin
            if (s != 67) publish(s[6:0] + 7'd1, (s + 1) & 3, 32'h11);   // prefetch next (bank = id[1:0])
            for (l = 0; l < ((s == 67) ? 8 : 16); l = l + 1) one_line();
            repeat (2) @(posedge clk);
        end

        repeat (4) @(posedge clk);
        $display("TEST_INFO: L1 releases=%0d frames=%0d underflows=%0d discards=%0d",
                 n_rel, cnt_frames, cnt_underflow, cnt_discard);
        if (n_rel != 68) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: L1 expected 68 releases (one per stripe), got %0d", n_rel);
        end
        if (bad_status != 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: L1 %0d releases did not carry status 0", bad_status);
        end
        if (bad_stripe != 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: L1 %0d releases were out of stripe order", bad_stripe);
        end
        if (bad_bank != 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: L1 %0d releases used the wrong bank", bad_bank);
        end
        if (cnt_underflow != 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: L1 unexpected underflow (%0d)", cnt_underflow);
        end

        // ------------------------------------------------------------- L3
        rel_before = n_rel;
        vs_pulse();
        repeat (4) @(posedge clk);
        if (n_rel != rel_before) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: L3 vs_fall released %0d more bank(s) after frame_last",
                     n_rel - rel_before);
        end
        $display("TEST_INFO: L3 vs_fall after the last stripe released nothing");

        // ------------------------------------------------------------- L4
        // Same-edge priority: a stripe-0 offer accepted on the very edge of
        // vs_fall must survive the frame reset (waiting_first/cur_ok are cleared
        // by the vs_fall branch and set again by the take_first branch; the set
        // must win, otherwise the new frame is black even though its stripe 0
        // was available). At this point waiting_first=1 and nothing is owned,
        // which is the only state in which this overlap is reachable.
        rel_before = n_rel;
        @(negedge clk);
        vs_in = 1'b1;
        @(negedge clk);
        vs_in = 1'b0;
        offer_valid = 1'b1;
        offer_data  = offer_word(7'd0, 2'd0, 32'h23);
        @(negedge clk);
        offer_valid = 1'b0;
        offer_data  = 64'd0;
        repeat (3) @(posedge clk);

        if (n_rel != rel_before) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: L4 released %0d bank(s) at the frame boundary", n_rel - rel_before);
        end
        if (u_dut.cur_ok !== 1'b1) `DGC_FAIL("L4 stripe 0 of the new frame was not taken")
        if (u_dut.frame_ok !== 1'b1) `DGC_FAIL("L4 new frame not ok")
        if (u_dut.cur_bank !== 1'b0) `DGC_FAIL("L4 stripe 0 did not take bank 0")
        $display("TEST_INFO: L4 same-edge vs_fall + stripe 0 keeps the new ownership");

        // ---------------------------------------------------------- P1/P2/P3
        // "Park the stripe 0 of a later job" (pf) - gated to the frame tail of a
        // healthy frame since 2026-11-02. Without the gate, parking the stripe 0
        // of the job the writer is currently producing starves it for a whole
        // output frame: bank = stripe_id[1:0], so the writer needs the parked bank
        // again at stripe 4/8/... (s5_jobs froze at exactly 4 x 30720 pixels).
        //
        //   P1  healthy frame, cur_stripe = 65: a stripe-0 offer of another job is
        //       parked (pf_valid, bank 0) and releases nothing
        //   P2  the following vs_fall promotes it to the new frame's stripe 0 and
        //       still releases nothing for it
        //   P3  black frame (frame_ok = 0): the same offer must NOT be parked, it
        //       is discarded and its bank returned with status 2 - this is the case
        //       that used to hang the writer mid-frame
        //
        // Scan the frame that L4 started up to stripe 64 so the reader is in the
        // tail; prefetch every following stripe so frame_ok stays set.
        for (s = 0; s < 65; s = s + 1) begin
            publish(s[6:0] + 7'd1, (s + 1) & 3, 32'h23);
            for (l = 0; l < 16; l = l + 1) one_line();
        end
        repeat (2) @(posedge clk);
        if (u_dut.cur_stripe !== 7'd65) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P1 reader reached stripe %0d instead of 65", u_dut.cur_stripe);
        end
        if (u_dut.frame_ok !== 1'b1) `DGC_FAIL("P1 frame is not healthy before parking")

        rel_before = n_rel;
        publish(7'd0, 2'd0, 32'h33);          // later job's stripe 0, bank 0
        repeat (2) @(posedge clk);
        if (u_dut.pf_valid !== 1'b1) `DGC_FAIL("P1 stripe 0 of the later job was not parked")
        if (u_dut.pf_bank !== 2'd0)  `DGC_FAIL("P1 parked bank is not bank 0")
        if (n_rel != rel_before) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P1 parking pushed %0d release(s)", n_rel - rel_before);
        end
        $display("TEST_INFO: P1 parked stripe 0 of job 33 in bank 0 without releasing it");

        // finish the frame: stripes 65, 66 (16 lines) and 67 (8 lines)
        publish(7'd66, 2'd2, 32'h23);
        for (l = 0; l < 16; l = l + 1) one_line();
        publish(7'd67, 2'd3, 32'h23);
        for (l = 0; l < 16; l = l + 1) one_line();
        for (l = 0; l < 8; l = l + 1) one_line();
        repeat (2) @(posedge clk);

        rel_before = n_rel;
        vs_pulse();
        repeat (3) @(posedge clk);
        if (u_dut.pf_valid !== 1'b0) `DGC_FAIL("P2 the parked stripe survived the frame boundary")
        if (u_dut.cur_ok !== 1'b1)   `DGC_FAIL("P2 the parked stripe did not become the current one")
        if (u_dut.cur_bank !== 2'd0) `DGC_FAIL("P2 the parked bank did not become current")
        if (u_dut.job_l !== 32'h33)  `DGC_FAIL("P2 the new frame did not lock job 33")
        if (u_dut.frame_ok !== 1'b1) `DGC_FAIL("P2 the new frame is not healthy")
        if (n_rel != rel_before) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P2 the boundary released %0d bank(s) of the parked stripe",
                     n_rel - rel_before);
        end
        $display("TEST_INFO: P2 vs_fall promoted the parked stripe 0 to the new frame");

        // ------------------------------------------------------------- P3
        // Black frame in the frame tail: frame_ok=0 must win over cur_stripe.
        // Scan the new frame up to stripe 65 and then stop prefetching, so the
        // reader underflows at 65->66 and clears frame_ok while cur_stripe is
        // already in the tail. A stripe 0 of another job arriving now belongs to
        // the job the writer is still producing and must be discarded.
        for (s = 0; s < 65; s = s + 1) begin
            publish(s[6:0] + 7'd1, (s + 1) & 3, 32'h33);
            for (l = 0; l < 16; l = l + 1) one_line();
        end
        for (l = 0; l < 16; l = l + 1) one_line();      // no prefetch -> underflow
        repeat (2) @(posedge clk);
        if (u_dut.frame_ok !== 1'b0) `DGC_FAIL("P3 the frame did not go black after the underflow")
        if (u_dut.cur_stripe < 7'd64) `DGC_FAIL("P3 the underflow did not leave the reader in the tail")

        rel_before = n_rel;
        publish(7'd0, 2'd0, 32'h44);
        // the discard release appears on the port in the cycle after the offer;
        // capture it before release_ready pops it, then let the monitor count it.
        rel_word = release_data;
        rel_seen = release_valid;
        if (u_dut.pf_valid !== 1'b0) `DGC_FAIL("P3 a stripe 0 of a black frame was parked")
        repeat (2) @(posedge clk);
        if (n_rel != rel_before + 1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P3 the refused stripe 0 pushed %0d release(s), expected 1",
                     n_rel - rel_before);
        end
        else begin
            if (!rel_seen) `DGC_FAIL("P3 the refused stripe 0 produced no release port beat")
            if (rel_word[41:40] !== 2'd2) `DGC_FAIL("P3 the refused stripe 0 was not status 2")
            if ({rel_word[42], rel_word[39]} !== 2'b00) `DGC_FAIL("P3 wrong bank returned")
            if (rel_word[38:32] !== 7'd0) `DGC_FAIL("P3 wrong stripe returned")
        end
        $display("TEST_INFO: P3 black-frame stripe 0 in the frame tail discarded, bank returned");

        // ------------------------------------------------------------- P4
        // Healthy frame but early: parking there would starve the writer four
        // stripes later (the parked bank is needed again by the running job), so
        // the frame-tail bound alone must also refuse it.
        vs_pulse();
        publish(7'd0, 2'd0, 32'h55);            // new frame, taken as stripe 0
        repeat (2) @(posedge clk);
        if (u_dut.frame_ok !== 1'b1) `DGC_FAIL("P4 the new frame did not become healthy")
        for (s = 0; s < 10; s = s + 1) begin
            publish(s[6:0] + 7'd1, (s + 1) & 3, 32'h55);
            for (l = 0; l < 16; l = l + 1) one_line();
        end
        repeat (2) @(posedge clk);
        if (u_dut.cur_stripe >= 7'd64) `DGC_FAIL("P4 the reader is already in the tail")

        rel_before = n_rel;
        publish(7'd0, 2'd0, 32'h66);
        rel_word = release_data;
        rel_seen = release_valid;
        if (u_dut.pf_valid !== 1'b0) `DGC_FAIL("P4 an early stripe 0 was parked")
        repeat (2) @(posedge clk);
        if (n_rel != rel_before + 1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P4 the refused stripe 0 pushed %0d release(s), expected 1",
                     n_rel - rel_before);
        end
        else if (rel_word[41:40] !== 2'd2) `DGC_FAIL("P4 the refused stripe 0 was not status 2")
        $display("TEST_INFO: P4 early stripe 0 of another job discarded (frame-tail bound)");

        if (dgc_errors == 0) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d", dgc_errors);
        $finish;
    end

    initial begin
        #5_000_000;
        dgc_errors = dgc_errors + 1;
        $display("TEST_FAIL: timeout at %0t (releases=%0d stripe=%0d)", $time, n_rel, u_dut.cur_stripe);
        $finish;
    end

endmodule




