//-----------------------------------------------------------------------------
// tb_stripe_writer.v - stripe writer functional test (4 banks, 2026-11-01)
//
// Streams one pixel per clock from a counter that advances on the accepted
// handshake, so a 30720-pixel stripe costs 30720 clocks. The behavioural stripe
// RAM is used (the generated IP is covered by s4_stripe_ram). The offer is held
// until the test has checked the payload, then accepted, which is what the real
// mailbox handshake does.
//
// The 2026-11-01 change rotates stripes over FOUR banks (bank = stripe_id[1:0])
// and allows at most two banks in READING (the scanned stripe plus its single
// prefetch). Both properties are checked here, because they are what lets the
// write side run two stripes ahead of the display.
//
// Cases
//   W1  one full stripe: exactly 30720 accepted pixels, offer only at the end
//   W2  offer payload: job_id, epoch, stripe 0, bank 0, 16 lines, reserved 0
//   W3  accepting the offer leaves the bank busy (READING)
//   W4  stripe 1 goes to bank 1 and is offered (one bank reading)
//   W5  stripe 2 completes into bank 2 but is NOT offered while two banks are
//       reading (the in-flight cap)
//   W6  releasing bank 0 offers the OLDEST ready stripe (stripe 2, bank 2)
//   W7  releasing bank 1 offers the next one (stripe 3, bank 3: 4 banks)
//   W8  job_restart abandons pending stripes but keeps reader-owned banks busy
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_stripe_writer;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg  [31:0] job_id = 32'hCAFE_0001;
    reg  [15:0] epoch  = 16'h0042;
    reg         job_restart = 0;

    // pixel source: one pixel per cycle, index advances on the handshake
    reg  [15:0] pix_idx = 16'd0;
    reg  [6:0]  pix_sid = 7'd0;
    wire [10:0] tb_dx = pix_idx % 11'd1920;
    wire [10:0] tb_dy = {pix_sid, 4'd0} + (pix_idx / 11'd1920);
    reg  [63:0] px_data = 64'd0;
    wire        px_ready;
    reg         px_valid = 1'b0;

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

    dgc_stripe_writer u_dut (
        .clk (clk), .rst_n (rst_n),
        .job_id (job_id), .config_epoch (epoch), .job_restart (job_restart),
        .job_abort (1'b0),
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
            px_valid <= 1'b1;
            px_data  <= {2'b00, 16'd0, tb_dy, tb_dx,
                         24'hA5_0000 | {16'd0, pix_idx[7:0]}};
            if (wr_fire) begin
                if (pix_idx == 16'd30719) begin
                    pix_idx <= 16'd0;
                    pix_sid <= pix_sid + 7'd1;
                end
                else pix_idx <= pix_idx + 16'd1;
            end
        end
    end

    integer n_offer = 0;
    always @(posedge clk) if (rst_n && offer_valid && offer_ready) n_offer = n_offer + 1;

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
            while ((cnt_pixels < n) && (guard < 400000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (cnt_pixels < n) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: pixel count stuck at %0d (wanted %0d) ready=%b sid=%0d state=%b",
                         cnt_pixels, n, px_ready, pix_sid, bank_state);
            end
        end
    endtask

    task expect_no_offer;
        begin
            repeat (4) @(posedge clk);
            if (offer_valid) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: unexpected offer (sid=%0d bank=%0d) while the cap should hold it", offer_data[54:48], off_bank);
            end
        end
    endtask

    initial begin
        $display("TEST_INFO: stripe writer functional test start (4 banks)");
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ------------------------------------------------------------ W1/W2
        wait_pixels(30720);
        repeat (4) @(posedge clk);
        if (!offer_valid) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W1 no offer after 30720 pixels");
        end
        else begin
            if (offer_data[31:0]  !== job_id) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W2 job_id"); end
            if (offer_data[47:32] !== epoch)  begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W2 epoch"); end
            if (offer_data[54:48] !== 7'd0)   begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W2 stripe id %0d", offer_data[54:48]); end
            if (off_bank !== 2'd0)            begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W2 bank %0d", off_bank); end
            if (offer_data[60:56] !== 5'd16)  begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W2 lines %0d", offer_data[60:56]); end
            if (offer_data[63] !== 1'b0)      begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W2 reserved bit63"); end
            $display("TEST_INFO: W1/W2 30720 pixels, offer sid=0 bank=0 lines=16");
        end

        // --------------------------------------------------------------- W3
        accept_offer();
        repeat (2) @(posedge clk);
        if (u_dut.reading[0] !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W3 bank0 is not READING after the handshake (state=%b)", bank_state);
        end
        if (!bank_busy[0]) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W3 bank0 not busy"); end

        // --------------------------------------------------------------- W4
        wait_pixels(61440);
        repeat (4) @(posedge clk);
        if (!offer_valid) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W4 no offer for stripe 1");
        end
        else begin
            if (offer_data[54:48] !== 7'd1) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W4 sid %0d", offer_data[54:48]); end
            if (off_bank !== 2'd1)          begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W4 bank %0d", off_bank); end
            $display("TEST_INFO: W4 stripe 1 offered from bank 1 (one bank reading)");
        end
        accept_offer();
        repeat (2) @(posedge clk);
        if (u_dut.reading[1] !== 1'b1) `DGC_FAIL("W4 bank1 not READING")

        // --------------------------------------------------------------- W5
        // stripe 2 must complete, but with two banks READING it must be held
        wait_pixels(92160);
        expect_no_offer();
        if (u_dut.ready[2] !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W5 stripe 2 is not READY in bank2 (state=%b)", bank_state);
        end
        $display("TEST_INFO: W5 stripe 2 held READY in bank 2 (two banks reading)");

        // --------------------------------------------------------------- W6
        do_release(0);
        repeat (4) @(posedge clk);
        if (!offer_valid) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W6 no offer after releasing bank0");
        end
        else begin
            if (offer_data[54:48] !== 7'd2) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W6 offered sid %0d (expected the oldest, 2)", offer_data[54:48]); end
            if (off_bank !== 2'd2)          begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W6 offered bank %0d", off_bank); end
            $display("TEST_INFO: W6 releasing bank0 offers the oldest ready stripe (2/bank2)");
        end
        accept_offer();
        repeat (2) @(posedge clk);
        if (u_dut.reading[2] !== 1'b1) `DGC_FAIL("W6 bank2 not READING")

        // --------------------------------------------------------------- W7
        // Stripe 3 fills bank 3 while banks 1/2 are reading; wait until it is
        // complete, then releasing bank1 must offer it.
        wait_pixels(122880);
        do_release(1);
        repeat (4) @(posedge clk);
        if (!offer_valid) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W7 no offer after releasing bank1");
        end
        else begin
            if (offer_data[54:48] !== 7'd3) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W7 offered sid %0d (expected 3)", offer_data[54:48]); end
            if (off_bank !== 2'd3)          begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: W7 offered bank %0d", off_bank); end
            $display("TEST_INFO: W7 releasing bank1 offers stripe 3 from bank 3 (4 banks)");
        end
        accept_offer();
        repeat (2) @(posedge clk);
        if (u_dut.reading[3] !== 1'b1) `DGC_FAIL("W7 bank3 not READING")

        // --------------------------------------------------------------- W8
        @(negedge clk);
        job_restart = 1'b1;
        @(negedge clk);
        job_restart = 1'b0;
        repeat (2) @(posedge clk);
        if ((u_dut.reading[3] !== 1'b1) || (u_dut.reading[2] !== 1'b1)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W8 job_restart freed a reader-owned bank (state=%b)", bank_state);
        end
        if (dbg_rd_timeout !== 1'b0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W8 watchdog fired in a healthy stream");
        end
        $display("TEST_INFO: W8 job_restart keeps the reader-owned banks busy");

        if (dgc_errors == 0) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d", dgc_errors);
        $finish;
    end

    // the watchdog must never fire with the default deadline in this test
    always @(posedge clk) begin
        if (rst_n && dbg_rd_timeout) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: reader watchdog fired unexpectedly (t=%0t)", $time);
        end
    end

    initial begin
        #20_000_000;   // wall-clock guard for the simulation
        dgc_errors = dgc_errors + 1;
        $display("TEST_FAIL: timeout, cnt_pixels=%0d sid=%0d bank_state=%b", cnt_pixels, pix_sid, bank_state);
        $finish;
    end

endmodule







