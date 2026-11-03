//-----------------------------------------------------------------------------
// tb_stripe_owner.v - stripe RAM bank ownership across the offer/release cycle
//
// Regression for a real defect found while re-checking s5_sys: the writer
// treated a bank as free as soon as the stripe_offer handshake completed, so it
// started the stripe two later into the same RAM while the video reader was
// still scanning the first one. s5_sys showed it as a systematic "+0x60" on the
// G/B bytes (0x60 is the first pixel of stripe 6, i.e. a later stripe had
// overwritten the bank).
//
// The frozen ownership is FREE -> WRITING -> READY -> READING -> FREE, and the
// write side must wait for stripe_release before it may reuse a bank.
//
// Cases
//   O1  fill stripe 0, offer appears, bank 0 stays busy after the handshake
//   O2  a pixel of stripe 4 (4 % 4 = 0, same bank) is not accepted while bank 0 is READING
//   O3  release bank 0 -> the stalled stripe 4 pixel is accepted
//   O4  job_restart does not free a bank the reader still owns
//   O5  the read port returns the written word (behavioural RAM, 2-cycle read)
//   O6  job_abort does free every bank, the reader-owned one included
//
// The behavioural stripe RAM model is used instead of the Pango DRM so 30,720
// pixels per stripe cost milliseconds; the generated IP itself is covered by
// s4_stripe_ram.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_stripe_owner;
    integer dgc_errors = 0;

    reg clk = 0;  always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg  [31:0] job_id = 32'h0000_00A5;
    reg  [15:0] epoch  = 16'h0011;
    reg         job_restart = 0;
    reg         job_abort   = 0;

    reg         px_valid = 0;
    wire        px_ready;
    reg  [63:0] px_data = 0;

    wire        bank0_busy, bank1_busy;
    reg         rel = 0, rel_bad = 0;
    reg  [1:0]  rel_bank = 2'd0;
    wire        offer_valid;
    reg         offer_ready = 0;
    wire [63:0] offer_data;
    wire [31:0] cnt_stripes, cnt_pixels;

    reg  [14:0] ram0_rd_addr = 0, ram1_rd_addr = 0;
    wire [23:0] ram0_rd_data, ram1_rd_data;

    dgc_stripe_writer u_dut (
        .clk (clk), .rst_n (rst_n),
        .job_id (job_id), .config_epoch (epoch), .job_restart (job_restart),
        .job_abort (job_abort),
        .px_valid (px_valid), .px_ready (px_ready), .px_data (px_data),
        .bank0_busy (bank0_busy), .bank1_busy (bank1_busy),
        .rel (rel), .release_bank (rel_bank), .release_status_bad (rel_bad),
        .offer_valid (offer_valid), .offer_ready (offer_ready), .offer_data (offer_data),
        .ram_rd_clk (clk), .ram_rd_rst_n (rst_n),
        .ram0_rd_addr (ram0_rd_addr), .ram0_rd_data (ram0_rd_data),
        .ram1_rd_addr (ram1_rd_addr), .ram1_rd_data (ram1_rd_data),
        .cnt_stripes_done (cnt_stripes), .cnt_pixels_written (cnt_pixels)
    );

    // pixel value is a function of the absolute position so a stale word from
    // another stripe can never compare equal by accident
    function [23:0] pix(input integer x, input integer y);
        begin
            pix = {x[7:0], y[7:0], (x[7:0] ^ y[7:0])};
        end
    endfunction

    integer n_wait = 0;
    // Present the payload first and keep px_valid low until the bank is ready.
    // Holding px_valid high while polling would accept the same pixel at every
    // intervening posedge (the first version of this test did exactly that and
    // counted each pixel twice).
    task push(input integer x, input integer y);
        begin
            @(negedge clk);
            px_data  = {1'b0, 1'b0, 16'h0, y[10:0], x[10:0], pix(x, y)};
            px_valid = 1'b0;
            #0.1;
            while (!px_ready) begin
                @(negedge clk);
                #0.1;
                n_wait = n_wait + 1;
            end
            px_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            px_valid = 1'b0;
            px_data  = 64'd0;
        end
    endtask

    task fill_stripe(input integer sid);
        integer i;
        begin
            for (i = 0; i < 30720; i = i + 1)
                push(i % 1920, sid * 16 + (i / 1920));
        end
    endtask

    task try_offer(output accepted);
        begin
            @(negedge clk);
            offer_ready = 1'b1;
            @(posedge clk);
            accepted = offer_valid;
            @(negedge clk);
            offer_ready = 1'b0;
        end
    endtask

    task do_release(input integer bank);
        begin
            @(negedge clk);
            rel      = 1'b1;
            rel_bank = bank[1:0];
            rel_bad  = 1'b0;
            @(posedge clk);
            @(negedge clk);
            rel = 1'b0;
        end
    endtask

    // a pixel must be rejected for a number of cycles; the counter must not move
    task expect_blocked(input integer x, input integer y, input integer cycles);
        integer i;
        reg     saw_ready;
        reg [31:0] px_before;
        begin
            px_before = cnt_pixels;
            saw_ready = 0;
            @(negedge clk);
            px_data  = {1'b0, 1'b0, 16'h0, y[10:0], x[10:0], pix(x, y)};
            px_valid = 1'b0;          // observe only: never hand a pixel over
            #0.1;
            for (i = 0; i < cycles; i = i + 1) begin
                if (px_ready) saw_ready = 1;
                @(negedge clk);
                #0.1;
            end
            if (px_ready) saw_ready = 1;
            px_data  = 64'd0;
            if (saw_ready) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: bank accepted a pixel while the reader owned it (O2/O4)");
            end
            if (cnt_pixels !== px_before) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: pixel counter moved while blocked %0d -> %0d",
                         px_before, cnt_pixels);
            end
        end
    endtask

    reg [23:0] rd_q;
    task read_word(input integer bank, input [14:0] addr, output [23:0] data);
        begin
            @(negedge clk);
            if (bank == 0) ram0_rd_addr = addr;
            else           ram1_rd_addr = addr;
            @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            data = (bank == 0) ? ram0_rd_data : ram1_rd_data;
        end
    endtask

    reg accepted;
    integer ii;
    integer total_wr = 0;
    always @(posedge clk) if (rst_n && u_dut.wr_fire) total_wr = total_wr + 1;
    initial begin
        $display("TEST_INFO: stripe owner test start");
        rst_n = 0;
        px_valid = 0;
        offer_ready = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ============================================================== O1
        fill_stripe(0);
        repeat (4) @(posedge clk);
        if (cnt_pixels !== 32'd30720) `DGC_FAIL("O1 pixel count != 30720")
        if (!offer_valid)            `DGC_FAIL("O1 no offer after a full stripe")
        if (offer_valid && (offer_data[54:48] !== 7'd0)) `DGC_FAIL("O1 wrong stripe id")
        if (offer_valid && (offer_data[55] !== 1'b0))    `DGC_FAIL("O1 wrong bank")
        if (!bank0_busy)             `DGC_FAIL("O1 bank 0 not busy before offer")

        // ============================================================== O5
        // read back the first and the last word of stripe 0 before it is released
        read_word(0, 15'd0, rd_q);
        if (rd_q !== pix(0, 0)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O5 read addr 0 exp=%06h act=%06h", pix(0, 0), rd_q);
        end
        read_word(0, {4'd15, 11'd1919}, rd_q);
        if (rd_q !== pix(1919, 15)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O5 read addr last exp=%06h act=%06h",
                     pix(1919, 15), rd_q);
        end
        $display("TEST_INFO: O1/O5 full stripe offered, read port exact");

        // ============================================================== O2
        // acceptable the offer: bank 0 goes READY -> READING, not FREE
        try_offer(accepted);
        if (!accepted) `DGC_FAIL("O2 offer was not accepted")
        repeat (2) @(posedge clk);
        if (!bank0_busy) `DGC_FAIL("O2 bank 0 released itself after the offer handshake")
        expect_blocked(0, 64, 12);      // first pixel of stripe 4 (4 % 4 = 0: bank 0 again)
        $display("TEST_INFO: O2 stripe 4 blocked while bank 0 is READING");

        // ============================================================== O3
        do_release(0);
        repeat (2) @(posedge clk);
        if (bank0_busy) `DGC_FAIL("O3 bank 0 still busy after release")
        push(0, 64);
        if (cnt_pixels !== 32'd30721) `DGC_FAIL("O3 stripe 4 pixel not accepted after release")
        if (!bank0_busy) `DGC_FAIL("O3 bank 0 did not start the next stripe")
        $display("TEST_INFO: O3 stripe 4 starts only after release");

        // ============================================================== O4
        // finish stripe 4 and 1, accept both offers, then restart the job. A
        // job restart may abandon pending stripes but may not free either bank
        // that the display still owns.
        for (ii = 1; ii < 30720; ii = ii + 1) begin
            push(ii % 1920, 64 + (ii / 1920));
            if ((ii % 4000) == 0)
                $display("TEST_INFO: filling stripe 4 ii=%0d t=%0t waits=%0d px_ready=%b cnt=%0d sid=%0d w=%b r=%b rd=%b",
                         ii, $time, n_wait, px_ready, u_dut.cnt[0], u_dut.cur_sid[0],
                         u_dut.writing[0], u_dut.ready[0], u_dut.reading[0]);
        end
        fill_stripe(1);
        repeat (4) @(posedge clk);
        try_offer(accepted);
        if (!accepted) `DGC_FAIL("O4 no offer for the first bank")
        try_offer(accepted);
        if (!accepted) `DGC_FAIL("O4 no offer for the second bank")
        repeat (2) @(posedge clk);
        if (!bank0_busy || !bank1_busy) `DGC_FAIL("O4 both banks should be READING")

        @(negedge clk); job_restart = 1'b1;
        @(posedge clk);
        @(negedge clk); job_restart = 1'b0;
        repeat (2) @(posedge clk);
        if (!bank0_busy || !bank1_busy) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O4 job_restart freed a bank still owned by the reader");
        end
        expect_blocked(0, 0, 12);       // new job's stripe 0, bank 0 still reading
        do_release(0);
        repeat (2) @(posedge clk);
        push(0, 0);
        // cnt_pixels is a per-job counter and job_restart clears it, so use the
        // testbench's own total to prove every accepted pixel was written once.
        if (total_wr !== 92161) begin
            // 30720 (stripe 0) + 1 (O3) + 30719 (rest of stripe 2)
            // + 30720 (stripe 1) + 1 (new job after release)
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O4 total writes exp=92161 act=%0d", total_wr);
        end
        $display("TEST_INFO: O4 job_restart keeps reader-owned banks busy");

        // ============================================================== O6
        // A job abort (the job watchdog fired) must return EVERY bank, including the
        // one the reader still owns. That is the difference to job_restart: after an
        // abort the reader will never release, so keeping `reading` set would make
        // the next job stall on that bank forever (board 2026-11-02: black until
        // power cycle). bank1 is still reader-owned here, bank0 is writing the new
        // job's first stripe.
        if (!u_dut.reading[1]) `DGC_FAIL("O6 precondition: bank1 is not reader-owned")
        if (!bank0_busy)       `DGC_FAIL("O6 precondition: bank0 is not writing")
        @(negedge clk); job_abort = 1'b1;
        @(posedge clk);
        @(negedge clk); job_abort = 1'b0;
        repeat (2) @(posedge clk);
        if (bank0_busy || bank1_busy) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O6 job_abort left a bank busy (b0=%b b1=%b)",
                     bank0_busy, bank1_busy);
        end
        if (u_dut.reading[1] !== 1'b0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O6 job_abort left the reader-owned bank READING");
        end
        $display("TEST_INFO: O6 job_abort returns reader-owned banks");

        if (dgc_errors == 0) $display("TEST_INFO: stripe ownership exact");
        `DGC_FINISH
    end

    // no write may reach a bank while it is READING
    always @(posedge clk) begin
        if (rst_n && u_dut.reading[0] && u_dut.wr_fire && (u_dut.wr_bank == 1'b0)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: write to bank 0 while READING (addr=%0d)", u_dut.waddr);
        end
        if (rst_n && u_dut.reading[1] && u_dut.wr_fire && (u_dut.wr_bank == 1'b1)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: write to bank 1 while READING (addr=%0d)", u_dut.waddr);
        end
    end

endmodule




