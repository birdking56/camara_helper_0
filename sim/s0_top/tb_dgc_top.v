//-----------------------------------------------------------------------------
// tb_dgc_top.v - S0 acceptance: top-level integration (elaboration + bring-up)
//
// Division of labour with the other S0 tests:
//   * sim/s0_clock_reset  proves the clock domains and reset gating,
//   * sim/s0_out_timing   proves the 1080p60 timing numbers exactly,
//   * sim/s0_rd_port      proves the DRM / FIFO read wrappers,
//   * sim/s0_rst_mbox     proves the reset synchroniser and the mailbox.
//
// This test therefore only proves that the *whole top level* builds and comes
// up: every module resolves, the PLLs lock inside the hierarchy, the domain
// resets release, every clock is toggling, the output scan engine produces line
// sync, and the TMDS encoder is driven by live pixel data.
//
// REAL: dgc_top, dgc_clock_reset, the three PLL IP models, sync_vg,
//       dgc_s0_pattern, rgb2tmds, the TMDS encoder, ms72xx_ctl and the TMDS
//       serialisers through the real GTP_OUTBUFDS / GTP_OSERDES_E2 models.
//
// STUBBED: ddr3_test (sim/s0_top/ddr3_test_sim_stub.v). The vendor PHY is
//       IEEE-1735 encrypted with a key this Questa installation does not have,
//       so it cannot be elaborated here. The stub keeps the exact port list and
//       supplies core_clk / pll_lock / ddr_init_done. DDR3 functional
//       verification is an explicit S2 deliverable and is listed as open in the
//       S0 report - it is NOT claimed by this test.
//
// Checks
//   I1  every PLL locks inside dgc_top
//   I2  ddr_init_done gates the data-domain resets and they then release
//   I3  all six clocks are toggling
//   I4  the output scan engine produces HS pulses
//   I5  the TMDS encoder is running on live pixel data
//   I6  input pixels reach the vin domain
//   I7  forcing the session reset source asserts every data-domain reset
//       immediately
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_dgc_top;

    integer dgc_errors = 0;

    // ------------------------------------------------------------ board clocks
    reg sys_clk = 0;
    always #18.5185 sys_clk = ~sys_clk;        // 27 MHz

    reg  clk_p = 0;
    always #4.0 clk_p = ~clk_p;                // 125 MHz DDR reference
    wire clk_n = ~clk_p;

    reg rst_in = 0;

    // -------------------------------------------------------------- HDMI input
    reg pixclk_in = 0;
    always #3.3670 pixclk_in = ~pixclk_in;     // 148.5 MHz

    reg        vs_in = 0, hs_in = 0, de_in = 0;
    reg [7:0]  r_in = 0, g_in = 0, b_in = 0;

    // ------------------------------------------------------------- board wires
    wire        mem_rst_n, mem_ck, mem_ck_n, mem_cke, mem_cs_n;
    wire        mem_ras_n, mem_cas_n, mem_we_n, mem_odt;
    wire [14:0] mem_a;
    wire [2:0]  mem_ba;
    wire [3:0]  mem_dqs, mem_dqs_n, mem_dm;
    wire [31:0] mem_dq;

    wire        rstn_out, hd_scl, hdmi_int_led;
    wire        hd_sda;
    pullup (hd_sda);

    wire        tmds_clk_p, tmds_clk_n;
    wire [2:0]  tmds_data_p, tmds_data_n;
    wire        heart_beat_led, ddr_init_done_o;

    `DGC_GRS_INST

    // ------------------------------------------------------------------ DUT
    dgc_top #(
        .SETTLE_CYCLES (16'd40)               // 4 us instead of 1 ms
    ) u_dut (
        .sys_clk        (sys_clk),
        .clk_p          (clk_p),
        .clk_n          (clk_n),
        .rst_in         (rst_in),
        .mem_rst_n      (mem_rst_n),
        .mem_ck         (mem_ck),
        .mem_ck_n       (mem_ck_n),
        .mem_cke        (mem_cke),
        .mem_cs_n       (mem_cs_n),
        .mem_ras_n      (mem_ras_n),
        .mem_cas_n      (mem_cas_n),
        .mem_we_n       (mem_we_n),
        .mem_odt        (mem_odt),
        .mem_a          (mem_a),
        .mem_ba         (mem_ba),
        .mem_dqs        (mem_dqs),
        .mem_dqs_n      (mem_dqs_n),
        .mem_dq         (mem_dq),
        .mem_dm         (mem_dm),
        .rstn_out       (rstn_out),
        .hd_scl         (hd_scl),
        .hd_sda         (hd_sda),
        .hdmi_int_led   (hdmi_int_led),
        .pixclk_in      (pixclk_in),
        .vs_in          (vs_in),
        .hs_in          (hs_in),
        .de_in          (de_in),
        .r_in           (r_in),
        .g_in           (g_in),
        .b_in           (b_in),
        .tmds_clk_p     (tmds_clk_p),
        .tmds_clk_n     (tmds_clk_n),
        .tmds_data_p    (tmds_data_p),
        .tmds_data_n    (tmds_data_n),
        .heart_beat_led (heart_beat_led),
        .ddr_init_done_o(ddr_init_done_o)
    );

    // ------------------------------------------------------- input generation
    // Reduced active region: enough to prove the vin domain captures pixels
    // without simulating 1080 input lines.
    localparam IN_H_TOTAL = 100;
    localparam IN_H_ACT   = 64;
    localparam IN_V_TOTAL = 12;
    localparam IN_V_ACT   = 8;

    integer ih = 0, iv = 0;

    always @(posedge pixclk_in) begin
        if (ih == IN_H_TOTAL - 1) begin
            ih <= 0;
            iv <= (iv == IN_V_TOTAL - 1) ? 0 : iv + 1;
        end
        else begin
            ih <= ih + 1;
        end

        vs_in <= (iv >= IN_V_ACT);
        hs_in <= (ih < 8);
        de_in <= (iv < IN_V_ACT) && (ih < IN_H_ACT);
        r_in  <= ih[7:0];
        g_in  <= iv[7:0];
        b_in  <= ih[7:0] ^ iv[7:0];
    end

    // ------------------------------------------------------------ measurement
    integer n_proc = 0, n_cfg = 0, n_vout = 0, n_5x = 0, n_vin = 0, n_ddr = 0;
    always @(posedge u_dut.proc_clk)     n_proc = n_proc + 1;
    always @(posedge u_dut.cfg_clk)      n_cfg  = n_cfg  + 1;
    always @(posedge u_dut.vout_clk)     n_vout = n_vout + 1;
    always @(posedge u_dut.vout_clk_5x)  n_5x   = n_5x   + 1;
    always @(posedge pixclk_in)          n_vin  = n_vin  + 1;
    always @(posedge u_dut.ddr_core_clk) n_ddr  = n_ddr  + 1;

    wire hs_o = u_dut.hs_o_r;
    reg  hs_d = 0;
    integer hs_pulses = 0;
    integer enc_toggles = 0;
    reg  enc_d = 0;

    always @(posedge u_dut.vout_clk) begin
        hs_d <= hs_o;
        if (hs_o && !hs_d) hs_pulses <= hs_pulses + 1;
        if (u_dut.u_rgb2tmds.pdataoutraw[0] !== enc_d) enc_toggles <= enc_toggles + 1;
        enc_d <= u_dut.u_rgb2tmds.pdataoutraw[0];
    end

    integer waited;
    integer p0, c0, v0, x0, vi0, d0;

    // -------------------------------------------------------------------- main
    initial begin
        rst_in = 1;
        repeat (10) @(posedge sys_clk);
        rst_in = 0;

        // ================================================================ I1/I2
        waited = 0;
        while (ddr_init_done_o !== 1'b1 && waited < 200000) begin
            @(posedge u_dut.ddr_core_clk);
            waited = waited + 1;
        end
        if (ddr_init_done_o !== 1'b1) `DGC_FAIL("I2: stub ddr_init_done never asserted")
        else $display("TEST_INFO: I2 ddr_init_done asserted after %0d DDR clocks", waited);

        if (u_dut.plls_lock !== 1'b1) `DGC_FAIL("I1: not all PLLs locked inside dgc_top")
        else $display("TEST_INFO: I1 all four PLLs locked inside dgc_top");

        waited = 0;
        while ((u_dut.proc_rst_n !== 1'b1 || u_dut.vout_rst_n !== 1'b1 ||
                u_dut.vout5x_rst_n !== 1'b1 || u_dut.cfg_rst_n !== 1'b1) &&
               waited < 200000) begin
            @(posedge sys_clk); waited = waited + 1;
        end
        if (u_dut.proc_rst_n !== 1'b1)   `DGC_FAIL("I2: proc domain reset stuck")
        if (u_dut.vout_rst_n !== 1'b1)   `DGC_FAIL("I2: vout domain reset stuck")
        if (u_dut.vout5x_rst_n !== 1'b1) `DGC_FAIL("I2: 5x domain reset stuck")
        if (u_dut.cfg_rst_n !== 1'b1)    `DGC_FAIL("I2: cfg domain reset stuck")
        $display("TEST_INFO: I2 all domain resets released after %0d sys clocks", waited);

        // ================================================================ I3
        p0 = n_proc; c0 = n_cfg; v0 = n_vout; x0 = n_5x; vi0 = n_vin; d0 = n_ddr;
        repeat (2000) @(posedge sys_clk);

        $display("TEST_INFO: I3 edges in 74.074 us - proc=%0d cfg=%0d vout=%0d 5x=%0d vin=%0d ddr=%0d",
                 n_proc - p0, n_cfg - c0, n_vout - v0, n_5x - x0, n_vin - vi0, n_ddr - d0);
        // 180 MHz proc (regenerated 2026-10-27 for timing closure) gives about
        // 13,333 edges in this window; exact frequency is asserted in
        // s0_clock_reset, this test only proves the domain is toggling.
        if ((n_proc - p0) < 12000)  `DGC_FAIL("I3: proc clock not running")
        if ((n_cfg  - c0) < 700)    `DGC_FAIL("I3: cfg clock not running")
        if ((n_vout - v0) < 11000)  `DGC_FAIL("I3: vout clock not running")
        if ((n_5x   - x0) < 55000)  `DGC_FAIL("I3: 5x clock not running")
        if ((n_vin  - vi0) < 11000) `DGC_FAIL("I3: input pixel clock not running")
        if ((n_ddr  - d0) < 9200)   `DGC_FAIL("I3: DDR clock not running")
        $display("TEST_INFO: I3 all six clock domains are toggling");

        // ================================================================ I4
        waited = 0;
        while (hs_pulses < 2 && waited < 100000) begin
            @(posedge u_dut.vout_clk); waited = waited + 1;
        end
        if (hs_pulses < 2) `DGC_FAIL("I4: output scan engine produced fewer than 2 HS pulses")
        else $display("TEST_INFO: I4 output HS pulses observed = %0d", hs_pulses);

        // ================================================================ I5
        if (enc_toggles < 100) `DGC_FAIL("I5: TMDS encoder is not running")
        else $display("TEST_INFO: I5 TMDS encoder transitions = %0d", enc_toggles);

        // ================================================================ I6
        if (u_dut.vin_pixel_cnt == 0) `DGC_FAIL("I6: no input pixels captured in vin domain")
        else $display("TEST_INFO: I6 input pixels captured = %0d", u_dut.vin_pixel_cnt);

        // ================================================================ I7
        force u_dut.u_clock_reset.data_arst_n = 1'b0;
        #0.5;
        if (u_dut.proc_rst_n !== 1'b0)   `DGC_FAIL("I7: proc reset not asserted asynchronously")
        if (u_dut.vout_rst_n !== 1'b0)   `DGC_FAIL("I7: vout reset not asserted asynchronously")
        if (u_dut.vout5x_rst_n !== 1'b0) `DGC_FAIL("I7: 5x reset not asserted asynchronously")
        if (dgc_errors == 0) $display("TEST_INFO: I7 asynchronous session reset asserts all data domains immediately");
        release u_dut.u_clock_reset.data_arst_n;
        repeat (20) @(posedge sys_clk);

        $display("TEST_INFO: top-level integration test finished at %0t", $time);
        `DGC_FINISH
    end

endmodule
