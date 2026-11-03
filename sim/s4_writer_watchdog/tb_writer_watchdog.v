//-----------------------------------------------------------------------------
// tb_writer_watchdog.v - reader-ownership watchdog (DGC5, 4 banks 2026-11-01)
//
// Reproduces the board's black-screen precondition in isolation: the writer
// offers a stripe, the reader accepts it (so the writer sets `reading`), and the
// reader then goes black without ever sending a release. Without a recovery path
// the writer never accepts another pixel for that bank.
//
// The natural pixel stream fills stripes 0..3 into banks 0..3; the test accepts
// only stripe 0's offer, so banks 1..3 end up READY and bank 0 stays READING.
// Stripe 4 (4 % 4 = 0) needs bank 0 and therefore blocks - the deadlock - until the watchdog
// reclaims bank 0 after RD_TIMEOUT cycles (100,000 here, 4.2M = 24.56 ms on the
// board).
//
// Cases
//   D1  the stranded bank stays READING past a full stripe time, watchdog silent
//   D2  at the deadline it self-clears: reading=0, cnt=0, sticky=1, count=1,
//       and the blocked stream resumes
//   D3  the freed bank accepts a complete new stripe (30720 pixels, READY)
//   D4  a release that arrives just before the deadline is a normal release and
//       is not counted as a second reclamation
//   D5  job_restart still does not free a reader-owned bank
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_writer_watchdog;
    integer dgc_errors = 0;
    localparam integer TO = 100000;

    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg  [31:0] job_id = 32'h0000_00C5;
    reg  [15:0] epoch  = 16'h0007;
    reg         job_restart = 0;
    reg         job_abort   = 0;

    reg  [15:0] pix_idx = 16'd0;
    reg  [6:0]  pix_sid = 7'd0;
    wire [10:0] tb_dx = pix_idx % 11'd1920;
    wire [10:0] tb_dy = {pix_sid, 4'd0} + (pix_idx / 11'd1920);
    reg  [63:0] px_data = 64'd0;
    wire        px_ready;
    reg         px_valid = 1'b0;
    // D6 pauses the stream so the bank registers can be inspected after an abort
    // without a new stripe starting in the meantime.
    reg         px_pause = 1'b0;

    wire [3:0]  bank_busy;
    wire [11:0] bank_state;
    wire [6:0]  cur_sid0_out;
    reg         rel = 0;
    reg  [1:0]  rel_bank = 2'd0;
    reg         rel_bad = 0;
    wire        offer_valid;
    reg         offer_ready = 0;
    wire [63:0] offer_data;
    wire [31:0] cnt_stripes, cnt_pixels;
    wire        dbg_rd_timeout;
    wire [15:0] cnt_rd_timeout;

    wire [14:0] ram0_rd_addr = 15'd0, ram1_rd_addr = 15'd0, ram2_rd_addr = 15'd0, ram3_rd_addr = 15'd0;
    wire [23:0] ram0_rd_data, ram1_rd_data, ram2_rd_data, ram3_rd_data;

    dgc_stripe_writer #(.RD_TIMEOUT(TO)) u_dut (
        .clk (clk), .rst_n (rst_n),
        .job_id (job_id), .config_epoch (epoch), .job_restart (job_restart),
        .job_abort (job_abort),
        .px_valid (px_valid), .px_ready (px_ready), .px_data (px_data),
        .bank_busy (bank_busy), .bank0_busy (), .bank1_busy (),
        .bank_state (bank_state), .cur_sid0_out (cur_sid0_out),
        .rel (rel), .release_bank (rel_bank), .release_status_bad (rel_bad),
        .offer_valid (offer_valid), .offer_ready (offer_ready), .offer_data (offer_data),
        .ram_rd_clk (clk), .ram_rd_rst_n (rst_n),
        .ram0_rd_addr (ram0_rd_addr), .ram0_rd_data (ram0_rd_data),
        .ram1_rd_addr (ram1_rd_addr), .ram1_rd_data (ram1_rd_data),
        .ram2_rd_addr (ram2_rd_addr), .ram2_rd_data (ram2_rd_data),
        .ram3_rd_addr (ram3_rd_addr), .ram3_rd_data (ram3_rd_data),
        .cnt_stripes_done (cnt_stripes), .cnt_pixels_written (cnt_pixels),
        .dbg_rd_timeout (dbg_rd_timeout), .cnt_rd_timeout (cnt_rd_timeout)
    );

    wire wr_fire = px_valid & px_ready;
    wire [1:0] off_bank = {offer_data[62], offer_data[55]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_idx <= 16'd0; pix_sid <= 7'd0;
            px_valid <= 1'b0; px_data <= 64'd0;
        end
        else begin
            px_valid <= ~px_pause;
            px_data  <= {2'b00, 16'd0, tb_dy, tb_dx,
                         24'h5A_0000 | {16'd0, pix_idx[7:0]}};
            if (wr_fire) begin
                if (pix_idx == 16'd30719) begin
                    pix_idx <= 16'd0;
                    pix_sid <= pix_sid + 7'd1;
                end
                else pix_idx <= pix_idx + 16'd1;
            end
        end
    end

    task accept_offer;
        begin
            @(negedge clk);
            offer_ready = 1'b1;
            @(negedge clk);
            offer_ready = 1'b0;
        end
    endtask

    task do_release(input integer bank);
        begin
            @(negedge clk);
            rel = 1'b1; rel_bank = bank[1:0];
            @(negedge clk);
            rel = 1'b0;
        end
    endtask

    task wait_pixels(input integer n);
        integer guard;
        begin
            guard = 0;
            while ((cnt_pixels < n) && (guard < 600000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (cnt_pixels < n) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: pixel count stuck at %0d (wanted %0d) state=%b ready=%b",
                         cnt_pixels, n, bank_state, px_ready);
            end
        end
    endtask

    initial begin
        $display("TEST_INFO: writer watchdog test start (4 banks, RD_TIMEOUT=%0d)", TO);
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ---- stripe 0 accepted into bank 0 and then stranded -----------------
        wait_pixels(30720);
        repeat (2) @(posedge clk);
        if (!offer_valid) `DGC_FAIL("D0 no offer for stripe 0")
        accept_offer();
        repeat (2) @(posedge clk);
        if (u_dut.reading[0] !== 1'b1) `DGC_FAIL("D0 bank0 not READING after the handshake")

        // ---- stripes 1..3 fill banks 1..3 and stay READY ---------------------
        // (their offers are left unaccepted: only bank 0 is a reader owner)
        wait_pixels(122880);
        repeat (2) @(posedge clk);
        if ((u_dut.ready[1] !== 1'b1) || (u_dut.ready[2] !== 1'b1) || (u_dut.ready[3] !== 1'b1))
            `DGC_FAIL("D0 the three other banks did not complete")
        if (px_ready !== 1'b0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D1 the stream is not blocked on the stranded bank (sid=%0d)", pix_sid);
        end
        if (dbg_rd_timeout) `DGC_FAIL("D1 watchdog fired before its deadline")
        repeat (2000) @(posedge clk);
        if (!u_dut.reading[0]) `DGC_FAIL("D1 the stranded bank did not stay READING")
        $display("TEST_INFO: D1 bank0 stranded for %0d cycles, stream blocked at stripe %0d",
                 u_dut.rd_age[0], pix_sid);

        // ---- D2: wait for the deadline --------------------------------------
        while (!dbg_rd_timeout) @(posedge clk);
        // just after the reclamation edge, before the next pixel is accepted
        if (u_dut.reading[0] !== 1'b0) `DGC_FAIL("D2 watchdog did not clear bank0")
        if (u_dut.cnt[0] !== 32'd0) `DGC_FAIL("D2 watchdog did not clear cnt[0]")
        if (cnt_rd_timeout !== 16'd1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D2 reclamation count exp=1 act=%0d", cnt_rd_timeout);
        end
        $display("TEST_INFO: D2 watchdog reclaimed bank0 at the deadline");

        // ---- D3: the freed bank accepts a complete stripe --------------------
        wait_pixels(122880 + 30720);   // stripe 4 complete in bank 0
        repeat (2) @(posedge clk);
        if ((u_dut.ready[0] !== 1'b1) || (u_dut.cnt[0] !== 32'd30720)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D3 the freed bank did not complete a stripe (ready=%b cnt=%0d)",
                     u_dut.ready[0], u_dut.cnt[0]);
        end
        $display("TEST_INFO: D3 bank0 accepted a full stripe after the recovery");

        // ---- D4: release just before the deadline ---------------------------
        // The oldest pending offer is stripe 1 in bank 1.
        if (!offer_valid) `DGC_FAIL("D4 no pending offer")
        if (offer_data[54:48] !== 7'd1 || off_bank !== 2'd1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D4 oldest pending offer is sid=%0d bank=%0d (expected 1/1)",
                     offer_data[54:48], off_bank);
        end
        accept_offer();
        repeat (2) @(posedge clk);
        if (u_dut.reading[1] !== 1'b1) `DGC_FAIL("D4 bank1 not READING")
        while (u_dut.rd_age[1] < (TO - 3)) @(posedge clk);
        do_release(1);
        repeat (4) @(posedge clk);
        if (u_dut.reading[1] !== 1'b0) `DGC_FAIL("D4 bank1 not released")
        if (cnt_rd_timeout !== 16'd1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D4 the normal release was counted as a timeout (%0d)", cnt_rd_timeout);
        end
        $display("TEST_INFO: D4 release before the deadline counts as a release");

        // ---- D5: job_restart keeps a reader-owned bank -----------------------
        // Next pending offer is stripe 2 in bank 2.
        if (!offer_valid) `DGC_FAIL("D5 no pending offer")
        accept_offer();
        repeat (2) @(posedge clk);
        if (u_dut.reading[2] !== 1'b1) `DGC_FAIL("D5 bank2 not READING")
        @(negedge clk);
        job_restart = 1'b1;
        @(negedge clk);
        job_restart = 1'b0;
        repeat (2) @(posedge clk);
        if (u_dut.reading[2] !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D5 job_restart freed a reader-owned bank (state=%b)", bank_state);
        end
        $display("TEST_INFO: D5 job_restart keeps the reader-owned bank");

        // ---- D6: job_abort returns EVERY bank, the reader-owned one included --
        // This is the contract the job watchdog relies on (2026-11-02): the reader
        // that went black never sends a release, so job_restart alone would leave
        // the bank READING and the next job would stall on it forever.
        if (u_dut.reading[2] !== 1'b1) `DGC_FAIL("D6 precondition: bank2 is not reader-owned")
        @(negedge clk);
        px_pause = 1'b1;                  // no new pixel may start a stripe
        repeat (2) @(posedge clk);
        job_abort = 1'b1;
        @(posedge clk);
        @(negedge clk);
        job_abort = 1'b0;
        repeat (2) @(posedge clk);
        if (bank_state !== 12'd0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D6 job_abort left bank state %b", bank_state);
        end
        if ((u_dut.cnt[0] !== 32'd0) || (u_dut.cnt[1] !== 32'd0) ||
            (u_dut.cnt[2] !== 32'd0) || (u_dut.cnt[3] !== 32'd0) ||
            (u_dut.rd_age[0] !== 24'd0) || (u_dut.rd_age[1] !== 24'd0) ||
            (u_dut.rd_age[2] !== 24'd0) || (u_dut.rd_age[3] !== 24'd0)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D6 job_abort left counts/ages behind (cnt=%0d/%0d/%0d/%0d age=%0d/%0d/%0d/%0d)",
                     u_dut.cnt[0], u_dut.cnt[1], u_dut.cnt[2], u_dut.cnt[3],
                     u_dut.rd_age[0], u_dut.rd_age[1], u_dut.rd_age[2], u_dut.rd_age[3]);
        end
        $display("TEST_INFO: D6 job_abort freed every bank (reading included)");
        @(negedge clk);
        px_pause = 1'b0;
        repeat (2) @(posedge clk);

        // ---- D7: after the abort the writer still completes a full stripe -----
        // The next job must not inherit any ownership; the pixel stream simply
        // starts a fresh stripe (a torn stripe is the accepted cost of the abort).
        // The abort lands mid-stripe, so the bank that was current keeps a partial
        // count and can never complete; the next stripe's bank reaches 30720 first.
        begin : d7
            integer target;
            target = cnt_pixels + 61440;
            wait_pixels(target);
            repeat (2) @(posedge clk);
            if ((u_dut.cnt[0] != 32'd30720) && (u_dut.cnt[1] != 32'd30720) &&
                (u_dut.cnt[2] != 32'd30720) && (u_dut.cnt[3] != 32'd30720)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: D7 no full stripe after the abort (cnt=%0d/%0d/%0d/%0d)",
                         u_dut.cnt[0], u_dut.cnt[1], u_dut.cnt[2], u_dut.cnt[3]);
            end
            $display("TEST_INFO: D7 the stream completed a full stripe after the abort");
        end

        if (dgc_errors == 0) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d", dgc_errors);
        $finish;
    end

    initial begin
        #50_000_000;
        dgc_errors = dgc_errors + 1;
        $display("TEST_FAIL: timeout at %0t (pixels=%0d sid=%0d state=%b)", $time, cnt_pixels, pix_sid, bank_state);
        $finish;
    end

endmodule





