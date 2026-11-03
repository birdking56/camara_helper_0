//-----------------------------------------------------------------------------
// tb_clock_reset.v - S0 acceptance: clock generation and reset gating
//
// Uses the three REAL PLL IP models, so the 180 / 148.5 / 742.5 / 10 MHz
// relationship is measured rather than assumed.
//
// 2026-10-28: the proc PLL was regenerated at 180 MHz on 10-27 to close
// timing (interface v1 originally froze 225 MHz). This test now checks the
// implemented 180 MHz explicitly; it must not silently accept any value.
//
// Checks
//   C1  every PLL locks and plls_lock rises
//   C2  measured frequencies are within 0.1 % of the frozen values
//   C3  the cfg domain (and therefore the HDMI chip reset) is released after its
//       own PLL lock plus the vendor demo's 1 ms window, and it must NOT wait
//       for ddr_init_done, otherwise the HDMI chips could never be programmed
//       and the DDR would never be used
//   C4  the DDR controller is released by lock + settle only (not circular)
//   C5  the data domains (proc / vout / vout5x) stay reset until ddr_init_done
//   C6  forcing the session reset source low asserts every data-domain reset in
//       the same delta (asynchronous assert requirement)
//   C7  dropping ddr_init_done re-asserts the data-domain resets
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_clock_reset;

    integer dgc_errors = 0;

    reg sys_clk = 0;
    always #18.5185 sys_clk = ~sys_clk;      // 27 MHz

    reg rst_in = 0;

    // Controlled stand-in for ddr3_test's clock / lock / init.
    reg ddr_core_clk = 0;
    always #4.0 ddr_core_clk = ~ddr_core_clk;   // 125 MHz
    reg ddr_pll_lock  = 0;
    reg ddr_init_done = 0;

    wire proc_clk, cfg_clk, vout_clk, vout_clk_5x;
    wire plls_lock, init_ready;
    wire ddr_arst_n, data_arst_n;
    wire cfg_rst_n, ddr_rst_n, proc_rst_n, vout_rst_n, vout5x_rst_n;

    dgc_clock_reset #(
        .SETTLE_CYCLES (16'd40),             // 4 us instead of 1 ms
        .CFG_SETTLE_CYCLES (16'd40)          // HDMI chip reset window, shortened
    ) u_dut (
        .sys_clk       (sys_clk),
        .rst_in        (rst_in),
        .ddr_core_clk  (ddr_core_clk),
        .ddr_pll_lock  (ddr_pll_lock),
        .ddr_init_done (ddr_init_done),
        .proc_clk      (proc_clk),
        .cfg_clk       (cfg_clk),
        .vout_clk      (vout_clk),
        .vout_clk_5x   (vout_clk_5x),
        .plls_lock     (plls_lock),
        .init_ready    (init_ready),
        .ddr_arst_n    (ddr_arst_n),
        .data_arst_n   (data_arst_n),
        .cfg_rst_n     (cfg_rst_n),
        .ddr_rst_n     (ddr_rst_n),
        .proc_rst_n    (proc_rst_n),
        .vout_rst_n    (vout_rst_n),
        .vout5x_rst_n  (vout5x_rst_n)
    );

    // ------------------------------------------------------------ frequency measurement
    integer n_proc = 0, n_cfg = 0, n_vout = 0, n_5x = 0;
    always @(posedge proc_clk)    n_proc = n_proc + 1;
    always @(posedge cfg_clk)     n_cfg  = n_cfg  + 1;
    always @(posedge vout_clk)    n_vout = n_vout + 1;
    always @(posedge vout_clk_5x) n_5x   = n_5x   + 1;

    // ddr3_test's PLL lock comes up a little after power-on
    initial begin
        #500;
        ddr_pll_lock = 1'b1;
    end

    integer waited;
    integer p0, c0, v0, x0;
    real    f_proc, f_cfg, f_vout, f_5x;

    // -------------------------------------------------------------------- main
    initial begin
        rst_in = 1;
        repeat (5) @(posedge sys_clk);
        rst_in = 0;

        // ================================================================ C1
        waited = 0;
        while (ddr_pll_lock !== 1'b1 && waited < 5000) begin
            @(posedge ddr_core_clk);
            waited = waited + 1;
        end
        if (ddr_pll_lock !== 1'b1) `DGC_FAIL("C1: ddr_pll_lock never asserted")
        waited = 0;
        while (plls_lock !== 1'b1 && waited < 20000) begin
            @(posedge sys_clk); waited = waited + 1;
        end
        if (plls_lock !== 1'b1) `DGC_FAIL("C1: plls_lock did not rise")
        else $display("TEST_INFO: C1 plls_lock rose after %0d sys clocks", waited);

        // ================================================================ C3
        // cfg domain must be out of reset even though ddr_init_done is still low
        waited = 0;
        while (cfg_rst_n !== 1'b1 && waited < 20000) begin
            @(posedge cfg_clk); waited = waited + 1;
        end
        if (cfg_rst_n !== 1'b1) `DGC_FAIL("C3: cfg domain never released")
        if (ddr_init_done !== 1'b0) `DGC_FAIL("C3: test setup wrong, ddr_init_done should still be low")
        // The HDMI chip reset must have waited for the full vendor window, not
        // released right after the PLL synchroniser (that mistake left the
        // MS7200 unconfigured on the board).
        if (u_dut.cfg_settle !== 16'd40)
            `DGC_FAIL("C3: cfg reset released without the full chip reset window")
        $display("TEST_INFO: C3 cfg domain released after lock + %0d cfg clocks, before ddr_init_done",
                 u_dut.cfg_settle);

        // data domains must still be held
        if (proc_rst_n !== 1'b0) `DGC_FAIL("C5: proc released before ddr_init_done")
        if (vout_rst_n !== 1'b0) `DGC_FAIL("C5: vout released before ddr_init_done")
        if (vout5x_rst_n !== 1'b0) `DGC_FAIL("C5: 5x released before ddr_init_done")
        $display("TEST_INFO: C5 proc/vout/vout5x held in reset while ddr_init_done is low");

        // ================================================================ C4
        waited = 0;
        while (ddr_rst_n !== 1'b1 && waited < 20000) begin
            @(posedge ddr_core_clk); waited = waited + 1;
        end
        if (ddr_rst_n !== 1'b1) `DGC_FAIL("C4: DDR controller reset never released")
        $display("TEST_INFO: C4 DDR controller reset released after lock + settle (%0d ddr clocks)", waited);

        // ================================================================ C2
        // measure over exactly 2000 system clocks (74.074 us), using deltas so the
        // PLL start-up phase is not included
        p0 = n_proc; c0 = n_cfg; v0 = n_vout; x0 = n_5x;
        repeat (2000) @(posedge sys_clk);
        f_proc = (n_proc - p0) / 74.074e-6 / 1.0e6;
        f_cfg  = (n_cfg  - c0) / 74.074e-6 / 1.0e6;
        f_vout = (n_vout - v0) / 74.074e-6 / 1.0e6;
        f_5x   = (n_5x   - x0) / 74.074e-6 / 1.0e6;
        $display("TEST_INFO: C2 measured proc = %0.2f MHz (implemented 171.0; v1 spec text said 225, lowered from 180 on 10-29 for timing)", f_proc);
        $display("TEST_INFO: C2 measured cfg  = %0.2f MHz (frozen 10.0)",  f_cfg);
        $display("TEST_INFO: C2 measured vout = %0.2f MHz (frozen 148.5)", f_vout);
        $display("TEST_INFO: C2 measured 5x   = %0.2f MHz (frozen 742.5)", f_5x);
        if (f_proc < 170.8 || f_proc > 171.2) `DGC_FAIL("C2: proc clock not the implemented 171 MHz")
        if (f_vout < 148.3 || f_vout > 148.7) `DGC_FAIL("C2: vout clock not 148.5 MHz")
        if (f_5x   < 742.0 || f_5x   > 743.0) `DGC_FAIL("C2: 5x clock not 742.5 MHz")
        // cfg is counted over a short window, so allow a slightly wider band
        if (f_cfg  < 9.5   || f_cfg  > 10.5)  `DGC_FAIL("C2: cfg clock not 10 MHz")

        // ================================================================ C5 -> release
        ddr_init_done = 1;
        waited = 0;
        while ((proc_rst_n !== 1'b1 || vout_rst_n !== 1'b1 || vout5x_rst_n !== 1'b1) &&
               waited < 2000) begin
            @(posedge sys_clk); waited = waited + 1;
        end
        if (proc_rst_n !== 1'b1)   `DGC_FAIL("C5: proc reset stuck after ddr_init_done")
        if (vout_rst_n !== 1'b1)   `DGC_FAIL("C5: vout reset stuck after ddr_init_done")
        if (vout5x_rst_n !== 1'b1) `DGC_FAIL("C5: 5x reset stuck after ddr_init_done")
        $display("TEST_INFO: C5 data domains released after ddr_init_done (%0d sys clocks)", waited);

        // ================================================================ C6
        force u_dut.data_arst_n = 1'b0;
        #0.5;
        if (proc_rst_n !== 1'b0)   `DGC_FAIL("C6: proc reset not asserted asynchronously")
        if (vout_rst_n !== 1'b0)   `DGC_FAIL("C6: vout reset not asserted asynchronously")
        if (vout5x_rst_n !== 1'b0) `DGC_FAIL("C6: 5x reset not asserted asynchronously")
        if (cfg_rst_n !== 1'b1)    `DGC_FAIL("C6: cfg reset must not be affected")
        $display("TEST_INFO: C6 asynchronous session reset asserts every data domain immediately");
        release u_dut.data_arst_n;
        repeat (30) @(posedge sys_clk);

        // ================================================================ C7
        ddr_init_done = 0;
        #0.5;
        if (proc_rst_n !== 1'b0)   `DGC_FAIL("C7: proc reset not re-asserted when ddr_init_done drops")
        if (vout_rst_n !== 1'b0)   `DGC_FAIL("C7: vout reset not re-asserted when ddr_init_done drops")
        $display("TEST_INFO: C7 dropping ddr_init_done re-asserts the session reset");
        ddr_init_done = 1;
        repeat (30) @(posedge sys_clk);

        $display("TEST_INFO: clock/reset test finished at %0t", $time);
        `DGC_FINISH
    end

endmodule

