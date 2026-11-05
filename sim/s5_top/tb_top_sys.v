//-----------------------------------------------------------------------------
// tb_top_sys.v - integrated top elaboration / bring-up smoke test
//
// This does not replace s0_top or s5_sys. It proves that the *integrated* board
// top (dgc_top_sys, which contains dgc_core_sys) elaborates with every real
// generated IP and that the clocks, resets and DDR stub come up. The DDR stub is
// quiescent, so no pixel data is expected here; functional data is s5_sys.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_top_sys;
    integer dgc_errors = 0;

    reg sys_clk = 0;  always #18.5185 sys_clk = ~sys_clk;
    reg clk_p   = 0;  always #4.0     clk_p   = ~clk_p;
    wire clk_n  = ~clk_p;
    reg rst_in  = 0;

    reg pixclk_in = 0; always #3.3670 pixclk_in = ~pixclk_in;
    reg vs_in = 0, hs_in = 0, de_in = 0;
    reg [7:0] r_in = 0, g_in = 0, b_in = 0;

    wire mem_rst_n, mem_ck, mem_ck_n, mem_cke, mem_cs_n;
    wire mem_ras_n, mem_cas_n, mem_we_n, mem_odt;
    wire [14:0] mem_a;
    wire [2:0]  mem_ba;
    wire [3:0]  mem_dqs, mem_dqs_n, mem_dm;
    wire [31:0] mem_dq;

    wire rstn_out, hd_scl, hdmi_int_led;
    wire hd_sda;
    pullup (hd_sda);

    wire tmds_clk_p, tmds_clk_n;
    wire [2:0] tmds_data_p, tmds_data_n;
    wire heart_beat_led, ddr_init_done_o;

    `DGC_GRS_INST

    dgc_top_sys #(
        .SETTLE_CYCLES (16'd40),
        .CFG_SETTLE_CYCLES (16'd40),
        .MODE          (0)
    ) u_dut (
        .sys_clk (sys_clk), .clk_p (clk_p), .clk_n (clk_n), .rst_in (rst_in),
        .mem_rst_n (mem_rst_n), .mem_ck (mem_ck), .mem_ck_n (mem_ck_n),
        .mem_cke (mem_cke), .mem_cs_n (mem_cs_n), .mem_ras_n (mem_ras_n),
        .mem_cas_n (mem_cas_n), .mem_we_n (mem_we_n), .mem_odt (mem_odt),
        .mem_a (mem_a), .mem_ba (mem_ba), .mem_dqs (mem_dqs),
        .mem_dqs_n (mem_dqs_n), .mem_dq (mem_dq), .mem_dm (mem_dm),
        .rstn_out (rstn_out), .hd_scl (hd_scl), .hd_sda (hd_sda),
        .hdmi_int_led (hdmi_int_led),
        .pixclk_in (pixclk_in), .vs_in (vs_in), .hs_in (hs_in), .de_in (de_in),
        .r_in (r_in), .g_in (g_in), .b_in (b_in),
        .tmds_clk_p (tmds_clk_p), .tmds_clk_n (tmds_clk_n),
        .tmds_data_p (tmds_data_p), .tmds_data_n (tmds_data_n),
        .heart_beat_led (heart_beat_led), .ddr_init_done_o (ddr_init_done_o)
    );

    integer waited;
    integer sum_probe_i;
    reg [23:0] sum_probe_rgb = 0;
    reg sum_probe_de = 0;
    reg [31:0] sum_probe_expected;

    // 2026-11-03: the interval counters (G0/G1) are cleared on the same edge that
    // freezes the snapshot, so the word must be compared with the value *at* that
    // edge, not with the live signal afterwards.
    reg [15:0] cap_g0, cap_g1;
    reg [7:0]  cap_areq, cap_agot;
    always @(posedge u_dut.proc_clk) begin
        if (u_dut.proc_snap_latch) begin
            cap_g0 <= u_dut.dbg_no_pend_us;
            cap_g1 <= u_dut.dbg_tick_skip;
            cap_areq <= u_dut.dbg_acq_req;
            cap_agot <= u_dut.dbg_acq_got;
        end
    end
    initial begin
        // Board pin C22 is active-low rstn; the top inverts it internally.
        rst_in = 0;
        repeat (10) @(posedge sys_clk);
        rst_in = 1;

        waited = 0;
        while (ddr_init_done_o !== 1'b1 && waited < 200000) begin
            @(posedge u_dut.ddr_core_clk);
            waited = waited + 1;
        end
        if (ddr_init_done_o !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: ddr_init_done never asserted");
        end
        else $display("TEST_INFO: integrated top elaborated; ddr_init_done after %0d clocks", waited);

        if (u_dut.plls_lock !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: PLLs not locked");
        end
        else $display("TEST_INFO: all PLLs locked inside dgc_top_sys");

        repeat (2000) @(posedge sys_clk);
        if (u_dut.proc_rst_n !== 1'b1 || u_dut.vout_rst_n !== 1'b1 ||
            u_dut.vin_rst_n !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: a data-domain reset did not release");
        end
        else $display("TEST_INFO: vin/proc/vout resets released");

        // The diagnostic accumulator taps registered HDMI pixels. Check DE
        // gaps and changing RGB together, independently of its internal stages.
        sum_probe_expected = u_dut.out_rgb_sum;
        force u_dut.rgb_out = sum_probe_rgb;
        force u_dut.de_out = sum_probe_de;
        for (sum_probe_i = 0; sum_probe_i < 257; sum_probe_i = sum_probe_i + 1) begin
            @(negedge u_dut.vout_clk);
            sum_probe_rgb = {sum_probe_i[7:0], (sum_probe_i[7:0] ^ 8'ha5), ~sum_probe_i[7:0]};
            sum_probe_de = ((sum_probe_i % 5) != 0);
            if (sum_probe_de)
                sum_probe_expected = sum_probe_expected + sum_probe_rgb[23:16]
                                   + sum_probe_rgb[15:8] + sum_probe_rgb[7:0];
        end
        @(negedge u_dut.vout_clk); sum_probe_de = 0;
        repeat (5) @(posedge u_dut.vout_clk); #0.2;
        if (u_dut.out_rgb_sum !== sum_probe_expected)
            `DGC_FAIL("registered output RGB diagnostic sum lost/misaligned a pixel")
        else $display("TEST_INFO: diagnostic output sum exact across 257 pixels and DE gaps");
        release u_dut.rgb_out;
        release u_dut.de_out;

        // ------------------------------------------------ snapshot packing check
        // 2026-11-03: the proc snapshot bundle used to overflow by 7 bits - the K0
        // field carried an 8-bit pix_over instead of the 1-bit flag the layout
        // documents - so the top of the concatenation was truncated and every word
        // above it (K0/K1/K2, P, Q, M0) was read 7 bits off on the board. The tell was
        // K1 reading a constant 0xDBFF, which is exactly {job_us[8:0], gap_max[6:0]}.
        // Nothing in the unit tests could see it, because the snapshot hub is driven
        // with synthetic data there. Here one real snapshot is forced and the proc
        // words are compared with the live signals the bundle is built from.
        force u_dut.snap_start = 1'b1;
        repeat (2) @(posedge sys_clk);
        release u_dut.snap_start;
        waited = 0;
        while (!u_dut.snap_done && waited < 20000) begin
            @(posedge sys_clk);
            waited = waited + 1;
        end
        if (!u_dut.snap_done) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: forced snapshot never completed");
        end
        else begin
            if (u_dut.st_words[21*16 +: 16] !== u_dut.dbg_job_us) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: K1=%04h is not dbg_job_us (%04h) - bundle misaligned",
                         u_dut.st_words[21*16 +: 16], u_dut.dbg_job_us);
            end
            if (u_dut.st_words[20*16 +: 16] !== {cap_areq, cap_agot}) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: K0=%04h is not {acq_req,acq_got}",
                         u_dut.st_words[20*16 +: 16]);
            end
            if (u_dut.st_words[22*16 +: 16] !==
                {u_dut.dbg_pix_sid, u_dut.dbg_cur_sid0, u_dut.dbg_reading[1:0]}) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: K2=%04h is not {pix_sid,cur_sid0,reading}",
                         u_dut.st_words[22*16 +: 16]);
            end
            if (u_dut.st_words[36*16 +: 16] !== u_dut.dbg_job_fid) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: M0=%04h is not dbg_job_fid (%04h) - bundle misaligned",
                         u_dut.st_words[36*16 +: 16], u_dut.dbg_job_fid);
            end
            if (u_dut.st_words[24*16 +: 16] !== u_dut.dbg_perf_proc[15:0]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: P0 word is not the low perf word");
            end
            // 2026-11-03: G0/G1 carry interval counters, and interval counters are
            // cleared on the very edge that freezes the snapshot - so the live signal
            // reads 0 right after the snapshot. Capture them on the latch edge instead.
            if (u_dut.st_words[16*16 +: 16] !== cap_g0) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: G0=%04h is not dbg_no_pend_us at the latch edge (%04h)",
                         u_dut.st_words[16*16 +: 16], cap_g0);
            end
            if (u_dut.st_words[17*16 +: 16] !== cap_g1) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: G1=%04h is not dbg_tick_skip at the latch edge (%04h)",
                         u_dut.st_words[17*16 +: 16], cap_g1);
            end
            if (dgc_errors == 0)
                $display("TEST_INFO: snapshot proc words match the live signals (K0/K1/K2/M0/P0 aligned)");
        end

        // DGC3 S-line event latches: after a clean bring-up none of the three
        // "something dropped" bits may be set, and the S word must still read
        // the documented 1FFD (the bits used to be reserved zeros).
        repeat (100) @(posedge sys_clk);
        if (u_dut.pll_lost_sticky !== 1'b0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: pll_lost_sticky set on a clean bring-up");
        end
        if (u_dut.rst_drop_sticky !== 1'b0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: rst_drop_sticky set on a clean bring-up");
        end
        if (u_dut.s_status16[15:13] !== 3'b000) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: S sticky bits are %b on a clean bring-up",
                     u_dut.s_status16[15:13]);
        end
        else $display("TEST_INFO: S-line event latches clear (S=%04h)", u_dut.s_status16);

        // Positive check: a PLL lock that drops for a few 27 MHz cycles must be
        // latched and must NOT clear when the lock comes back. This is the
        // evidence the "no signal" investigation needs; a latch that can only
        // stay 0 would pass the check above while being useless.
        force u_dut.pll_proc_lock = 1'b0;
        repeat (4) @(posedge sys_clk);
        release u_dut.pll_proc_lock;
        repeat (4) @(posedge sys_clk);
        if (u_dut.pll_lost_sticky !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: a dropped PLL lock was not latched");
        end
        if (u_dut.s_status16[15] !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: S[15] does not report the latched PLL lock loss");
        end
        else $display("TEST_INFO: dropped PLL lock latched in S[15] and held after relock (S=%04h)",
                      u_dut.s_status16);

        if (dgc_errors == 0) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d", dgc_errors);
        $finish;
    end
endmodule
