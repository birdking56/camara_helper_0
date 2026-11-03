//-----------------------------------------------------------------------------
// tb_snapshot.v
//
// Directed test for dgc_snapshot_src + dgc_snapshot_hub:
//   P1  the 36 printed words exactly match the documented source map
//   P2  after a snapshot the words follow the source *hold* registers, not the
//       live (still changing) status bus - this is the anti-tearing property
//   P3  if one domain is held in reset the hub still finishes (ack timeout) and
//       sets sticky[15]
//   P4  sticky event bits accumulate across reports and are never cleared
//   P5  a second snapshot after the timeout works normally again
//   P6  latch_evt fires exactly once per request, and a dgc_perf_ctr clocked by
//       it publishes exactly the interval a reference model counts (the property
//       the DGC3 performance report relies on: same-edge publish and restart,
//       no one-interval lag, no extra pulse)
//
// Four independent clocks are used so the synchroniser paths are real.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_snapshot;

    integer dgc_errors = 0;

    reg sys_clk  = 0; always #18.5185 sys_clk  = ~sys_clk;   // 27 MHz
    reg vin_clk  = 0; always #3.3670  vin_clk  = ~vin_clk;   // 148.5 MHz
    reg ddr_clk  = 0; always #4.0     ddr_clk  = ~ddr_clk;   // 125 MHz
    reg proc_clk = 0; always #2.7778  proc_clk = ~proc_clk;  // 180 MHz
    reg vout_clk = 0; always #3.3670  vout_clk = ~vout_clk;  // 148.5 MHz

    reg rst_n      = 0;
    reg vout_rst_n = 0;

    // ------------------------------------------------------------- source data
    reg [127:0] vin_data;
    reg [239:0] ddr_data;
    reg [271:0] proc_data;
    reg [143:0] vout_data;

    // Replicated counters used by P2: every word of a group carries the same
    // value, so a non-coherent capture would immediately show up as a mismatch.
    reg [15:0] c_vin = 16'd0, c_ddr = 16'd0, c_proc = 16'd0, c_vout = 16'd0;
    always @(posedge vin_clk)  if (rst_n) c_vin  <= c_vin  + 16'd1;
    always @(posedge ddr_clk)  if (rst_n) c_ddr  <= c_ddr  + 16'd1;
    always @(posedge proc_clk) if (rst_n) c_proc <= c_proc + 16'd1;
    always @(posedge vout_clk) if (rst_n) c_vout <= c_vout + 16'd1;

    reg [15:0] s_status = 16'h1FFD;
    reg [15:0] t_status = 16'h02FF;

    // ------------------------------------------------------------- instances
    wire        snap_req;
    wire [127:0] vin_hold;
    wire [239:0] ddr_hold;
    wire [271:0] proc_hold;
    wire [143:0] vout_hold;
    wire         vin_ack, ddr_ack, proc_ack, vout_ack;
    wire         proc_latch;

    dgc_snapshot_src #(.W(128)) u_src_vin (
        .clk (vin_clk), .rst_n (rst_n), .req_tgl (snap_req),
        .data (vin_data), .hold (vin_hold), .ack_tgl (vin_ack)
    );
    dgc_snapshot_src #(.W(240)) u_src_ddr (
        .clk (ddr_clk), .rst_n (rst_n), .req_tgl (snap_req),
        .data (ddr_data), .hold (ddr_hold), .ack_tgl (ddr_ack)
    );
    dgc_snapshot_src #(.W(272)) u_src_proc (
        .clk (proc_clk), .rst_n (rst_n), .req_tgl (snap_req),
        .data (proc_data), .hold (proc_hold),
        .latch_evt (proc_latch), .ack_tgl (proc_ack)
    );
    dgc_snapshot_src #(.W(144)) u_src_vout (
        .clk (vout_clk), .rst_n (vout_rst_n), .req_tgl (snap_req),
        .data (vout_data), .hold (vout_hold), .ack_tgl (vout_ack)
    );

    reg         start_pulse = 0;
    wire [703:0] words;
    wire        done;

    dgc_snapshot_hub u_hub (
        .clk (sys_clk), .rst_n (rst_n), .start (start_pulse),
        .s_status (s_status), .t_status (t_status),
        .vin_hold (vin_hold), .ddr_hold (ddr_hold),
        .proc_hold (proc_hold), .vout_hold (vout_hold),
        .vin_ack (vin_ack), .ddr_ack (ddr_ack),
        .proc_ack (proc_ack), .vout_ack (vout_ack),
        .req_tgl (snap_req), .words (words), .done (done)
    );

    // ---------------------------------------------------------------- helpers
    integer i;
    integer waited;
    reg     seen_done;

    // -------------------------------------------------- P6: perf counter wiring
    // `ev` is tied high, so the published value must be (proc cycles in the
    // interval + 1) >> 4. The reference model below counts those cycles itself;
    // a publish-on-the-wrong-edge or a second latch pulse breaks the match.
    reg         perf_ev = 1'b1;
    wire [15:0] perf_val;
    dgc_perf_ctr #(.N(1), .SHIFT(4)) u_perf (
        .clk (proc_clk), .rst_n (rst_n), .latch (proc_latch),
        .ev (perf_ev), .value (perf_val)
    );
    integer perf_cnt  = 0;
    integer perf_pub  = 0;
    integer latch_cnt = 0;
    always @(posedge proc_clk) begin
        if (rst_n) begin
            if (proc_latch) begin
                perf_pub  <= (perf_cnt + 1) >> 4;
                perf_cnt  <= 0;
                latch_cnt <= latch_cnt + 1;
            end
            else perf_cnt <= perf_cnt + 1;
        end
    end

    task take_snapshot;
        begin
            @(posedge sys_clk);
            start_pulse <= 1'b1;
            @(posedge sys_clk);
            start_pulse <= 1'b0;

            seen_done = 0;
            waited    = 0;
            while (!seen_done && waited < 20000) begin
                @(posedge sys_clk);
                waited = waited + 1;
                if (done) seen_done = 1;
            end
            if (!seen_done) `DGC_FAIL("hub never asserted done")
        end
    endtask

    task compare_words;
        input [703:0] exp;
        begin
            for (i = 0; i < 44; i = i + 1) begin
                // M0 (36) is checked slice-by-slice in P2.
                if (i != 36) begin
                if (words[i*16 +: 16] !== exp[i*16 +: 16]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: word %0d = %04h, expected %04h",
                             i, words[i*16 +: 16], exp[i*16 +: 16]);
                end
                end
            end
        end
    endtask

    // ------------------------------------------------------------------- main
    wire [23:0] exp_fclk_raw = {vin_data[79:64], vin_data[63:48]};
    wire [15:0] exp_fclk     = (exp_fclk_raw * 32'd135) >> 20;

    initial begin
        // P1 fixed, uniquely identifiable source words.
        // The 128-bit DGC2 halves keep their old values (so P1 still proves the
        // DGC2 word positions did not move); the DGC3 halves get their own
        // recognizable pattern, one distinct value per word.
        vin_data  = {16'hA5A5, 16'h1234, 16'h0ABC, 16'h00AB,
                     16'h1234, 16'h0777, 16'h0111, 16'h0222};
        ddr_data  = {16'h000C, 16'h000B, 16'h000A, 16'h0009,   // R3..R0 (new)
                     16'h003F, 16'h0006, 16'h0005, 16'h0004,
                     16'h0003, 16'h0002, 16'h0001, 16'h0000};
        proc_data = {16'h0063,                                 // w16 M0 probe (new)
                       16'h0058, 16'h0057, 16'h0056, 16'h0055,   // Q3..Q0 (new)
                     16'h0054, 16'h0053, 16'h0052, 16'h0051,   // P3..P0 (new)
                     16'h0000, 16'h0000, 16'h0000, 16'h0014,
                     16'h0013, 16'h0012, 16'h0011, 16'h0010};
        vout_data = {16'h0028,                                 // w8 W3 probe (new)
                     16'h0027, 16'h0026, 16'h0025, 16'h0024,   // w7..w4 V line
                     16'h0000, 16'h0022, 16'h0021, 16'h0020};   // w3..w0 (w3 anomaly stickies = 0)

        rst_n      = 0;
        vout_rst_n = 0;
        repeat (10) @(posedge sys_clk);
        rst_n      = 1;
        vout_rst_n = 1;
        repeat (10) @(posedge sys_clk);

        take_snapshot();
        $display("TEST_INFO: P1 snapshot taken after %0d sys clocks", waited);
        compare_words({
            16'h0027, 16'h0026, 16'h0025, 16'h0024,   // p43..p40 V line (DGC5)
            16'h0000, 16'h0000, 16'h0000, 16'h0000,   // p39..p36 M3..M0 (ddr top words are zero; M0 is checked in P2)
            16'h000C, 16'h000B, 16'h000A, 16'h0009,   // p35..p32 R line
            16'h0058, 16'h0057, 16'h0056, 16'h0055,   // p31..p28 Q line
            16'h0054, 16'h0053, 16'h0052, 16'h0051,   // p27..p24 P line
            16'h03FE,                       // p23 sticky: bits 1..9 set
            16'h0000, 16'h0000, 16'h0000,   // p22(proc w7 bank state) p21(proc w6) p20(proc w5)
            16'h0021, 16'h0020, 16'h0014, 16'h0013,
            16'h003F, 16'h0012, 16'h0011, 16'h0010,
            16'h0028, 16'hA5A5, 16'h0001, 16'h0000,   // p11 W3 (vout w8), p10 W2 (vin w7)
            16'h1234, 16'h0ABC, exp_fclk,  16'h0777,
            16'h0111, 16'h0222, 16'h02FF, 16'h1FFD
        });
        if (dgc_errors == 0) $display("TEST_INFO: P1 all 44 words match the documented map");

        // ---------------------------------------------------------------- P2
        // Every group word is a live counter. Once done is high the hub must
        // have copied the hold registers, not the still-running counters.
        vin_data  = {8{c_vin}};
        ddr_data  = {12{c_ddr}};
        proc_data = {17{c_proc}};
        vout_data = {9{c_vout}};

        take_snapshot();
        if (words[8*16 +: 16]  !== ddr_hold[15:0])  `DGC_FAIL("P2 p8 is not the ddr hold")
        if (words[9*16 +: 16]  !== ddr_hold[31:16]) `DGC_FAIL("P2 p9 is not the ddr hold")
        if (words[10*16 +: 16] !== vin_hold[127:112])  `DGC_FAIL("P2 p10 is not the W2 (input sum) word")
        if (words[11*16 +: 16] !== vout_hold[143:128]) `DGC_FAIL("P2 p11 is not the W3 (output sum) word")
        if (words[12*16 +: 16] !== proc_hold[15:0]) `DGC_FAIL("P2 p12 is not the proc hold")
        if (words[18*16 +: 16] !== vout_hold[15:0]) `DGC_FAIL("P2 p18 is not the vout hold")
        if (words[15:0] !== s_status)               `DGC_FAIL("P2 p0 is not S")
        // DGC3 appended words: each must come from the documented hold slice.
        if (words[24*16 +: 16] !== proc_hold[143:128]) `DGC_FAIL("P2 p24 is not proc_hold[143:128]")
        if (words[25*16 +: 16] !== proc_hold[159:144]) `DGC_FAIL("P2 p25 is not proc_hold[159:144]")
        if (words[26*16 +: 16] !== proc_hold[175:160]) `DGC_FAIL("P2 p26 is not proc_hold[175:160]")
        if (words[27*16 +: 16] !== proc_hold[191:176]) `DGC_FAIL("P2 p27 is not proc_hold[191:176]")
        if (words[28*16 +: 16] !== proc_hold[207:192]) `DGC_FAIL("P2 p28 is not proc_hold[207:192]")
        if (words[29*16 +: 16] !== proc_hold[223:208]) `DGC_FAIL("P2 p29 is not proc_hold[223:208]")
        if (words[30*16 +: 16] !== proc_hold[239:224]) `DGC_FAIL("P2 p30 is not proc_hold[239:224]")
        if (words[31*16 +: 16] !== proc_hold[255:240]) `DGC_FAIL("P2 p31 is not proc_hold[255:240]")
        if (words[32*16 +: 16] !== ddr_hold[143:128])  `DGC_FAIL("P2 p32 is not ddr_hold[143:128]")
        if (words[33*16 +: 16] !== ddr_hold[159:144])  `DGC_FAIL("P2 p33 is not ddr_hold[159:144]")
        if (words[34*16 +: 16] !== ddr_hold[175:160])  `DGC_FAIL("P2 p34 is not ddr_hold[175:160]")
        if (words[35*16 +: 16] !== ddr_hold[191:176])  `DGC_FAIL("P2 p35 is not ddr_hold[191:176]")
        if (words[36*16 +: 16] !== proc_hold[271:256]) `DGC_FAIL("P2 p36 is not proc_hold[271:256]")
        if (words[37*16 +: 16] !== ddr_hold[207:192])  `DGC_FAIL("P2 p37 is not ddr_hold[207:192]")
        if (words[38*16 +: 16] !== ddr_hold[223:208])  `DGC_FAIL("P2 p38 is not ddr_hold[223:208]")
        if (words[39*16 +: 16] !== ddr_hold[239:224])  `DGC_FAIL("P2 p39 is not ddr_hold[239:224]")
        // DGC5 V line: four vout-domain interval counters.
        if (words[40*16 +: 16] !== vout_hold[79:64])   `DGC_FAIL("P2 p40 is not vout_hold[79:64]")
        if (words[41*16 +: 16] !== vout_hold[95:80])   `DGC_FAIL("P2 p41 is not vout_hold[95:80]")
        if (words[42*16 +: 16] !== vout_hold[111:96])  `DGC_FAIL("P2 p42 is not vout_hold[111:96]")
        if (words[43*16 +: 16] !== vout_hold[127:112]) `DGC_FAIL("P2 p43 is not vout_hold[127:112]")
        $display("TEST_INFO: P2 words follow the frozen holds (ddr hold=%04h)", ddr_hold[15:0]);

        // ---------------------------------------------------------------- P3
        // Hold the vout domain in reset: its ack cannot return, so the hub must
        // finish on the timeout path and report it in sticky[15].
        vout_rst_n = 0;
        repeat (5) @(posedge sys_clk);
        take_snapshot();
        if (words[23*16 + 15] !== 1'b1) `DGC_FAIL("P3 sticky[15] not set on ack timeout")
        $display("TEST_INFO: P3 timeout path completed, sticky=0x%04h", words[23*16 +: 16]);

        // ---------------------------------------------------------------- P4
        // Restore vout, clear ddr, snapshot again: the sticky bit for a good
        // write frame must survive even though the live counter is now zero.
        vout_rst_n = 1;
        ddr_data   = 128'd0;
        repeat (5) @(posedge sys_clk);
        take_snapshot();
        if (words[23*16 + 0] !== 1'b1) `DGC_FAIL("P4 sticky good-write bit was lost")
        if (words[23*16 + 15] !== 1'b1) `DGC_FAIL("P4 sticky timeout bit was lost")
        $display("TEST_INFO: P4 sticky survived a later zero report (0x%04h)", words[23*16 +: 16]);

        // ---------------------------------------------------------------- P5
        // A normal snapshot after the timeout must work again.
        vout_data[63:48] = 16'hBEEF;   // no longer part of the W line; kept as a don't-care
        repeat (5) @(posedge sys_clk);
        take_snapshot();
        if (words[8*16 +: 16] !== 16'h0000) `DGC_FAIL("P5 unexpected p8")
        if (words[9*16 +: 16] !== 16'h0000) `DGC_FAIL("P5 unexpected p9")
        if (words[10*16 +: 16] !== vin_hold[127:112])  `DGC_FAIL("P5 unexpected p10")
        if (words[11*16 +: 16] !== vout_hold[143:128]) `DGC_FAIL("P5 unexpected p11")
        $display("TEST_INFO: P5 the hub is usable after the timeout");

        // ---------------------------------------------------------------- P6
        // Exactly one latch pulse per request, and the perf counter's published
        // value equals the interval the reference model counted.
        begin : p6
            integer latches_before;
            latches_before = latch_cnt;
            repeat (37) @(posedge proc_clk);      // let the interval grow a bit
            take_snapshot();
            repeat (4) @(posedge proc_clk);
            if (latch_cnt !== latches_before + 1)
                `DGC_FAIL("P6 latch_evt did not fire exactly once per snapshot")
            if (perf_val !== perf_pub[15:0]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: P6 perf published %0d, model %0d",
                         perf_val, perf_pub);
            end
            $display("TEST_INFO: P6 latch pulses=%0d, perf interval word=%0d matches the model",
                     latch_cnt, perf_val);
        end

        // ---------------------------------------------------------------- P7
        // DGC5 anomaly stickies: the writer watchdog (proc J2 bit 12 =
        // proc_hold[44]) and the two video-reader flags (vout w3 bits 0/1 =
        // vout_hold[48]/[49]) must reach sticky bits 10..12 and stay there.
        begin : p7
            proc_data = 272'd0; proc_data[44] = 1'b1;
            vout_data = 144'd0;
            vout_data[48] = 1'b1;   // reader release-queue overflow
            vout_data[49] = 1'b1;   // reader discarded a bank at a frame boundary
            vin_data = 128'd0;
            ddr_data = 240'd0;
            repeat (5) @(posedge sys_clk);
            take_snapshot();
            if (words[23*16 + 10] !== 1'b1) `DGC_FAIL("P7 sticky[10] writer watchdog not latched")
            if (words[23*16 + 11] !== 1'b1) `DGC_FAIL("P7 sticky[11] reader release overflow not latched")
            if (words[23*16 + 12] !== 1'b1) `DGC_FAIL("P7 sticky[12] reader frame-boundary discard not latched")
            $display("TEST_INFO: P7 anomaly stickies latched (sticky=0x%04h)", words[23*16 +: 16]);
        end

        if (dgc_errors == 0) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d", dgc_errors);
        $finish;
    end

endmodule






