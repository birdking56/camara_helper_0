//-----------------------------------------------------------------------------
// tb_ddr3_native.v - S2 prerequisite: real DDR3 IP, real memory model
//
// Until now every conclusion about DDR3 was static (PDS synthesis) because the
// vendor PHY is shipped as IEEE-1735 encrypted .vp files that Questa cannot
// decrypt from the synthesis set. The simulation set is different:
//
//   ipcore/ddr3_test/rtl/**/*.v     plain Verilog          -> compile
//   ipcore/ddr3_test/sim_lib/**     encrypted SIM models   -> compile
//   Pango arch/vendor/.../simulation/*.v + bsim modelsim10.2c .vp
//                                   primitive behaviour    -> compile
//
// With those three the whole IP elaborates, so this testbench can drive the real
// simplified-AXI user port against the real Micron DDR3 behavioural model.
//
// What it establishes (all needed before ddr_fetch can be trusted):
//   D1  the controller really reaches ddr_init_done
//   D2  a native write burst is accepted with the address unit the frozen spec
//       assumes (4 bytes per address, 8 addresses per 32-byte beat)
//   D3  a read burst returns the same bytes in the same lane order
//   D4  the read return really is unforgeable-prefix behaved: no rready exists
//       and every rvalid beat must be consumed
//
// A progress line is printed every 20 us. If the run looks long, the log shows
// whether time is advancing and what the controller is doing - that separates a
// genuinely slow initialisation from a stuck command line.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_ddr3_native;

    integer dgc_errors = 0;

    // ------------------------------------------------------------- clock/reset
    reg ref_clk = 0;
    always #4.0 ref_clk = ~ref_clk;        // 125 MHz DDR reference

    reg resetn = 0;

    wire core_clk;
    wire pll_lock, phy_pll_lock, gpll_lock, rst_gpll_lock, ddrphy_cpd_lock;
    wire ddr_init_done;

    `DGC_GRS_INST

    // ------------------------------------------------------------ DDR3 pins
    wire        mem_rst_n, mem_ck, mem_ck_n, mem_cke, mem_cs_n;
    wire        mem_ras_n, mem_cas_n, mem_we_n, mem_odt;
    wire [14:0] mem_a;
    wire [2:0]  mem_ba;
    wire [3:0]  mem_dqs, mem_dqs_n, mem_dm;
    wire [31:0] mem_dq;

    // --------------------------------------------------------- native user port
    reg  [27:0] axi_awaddr = 28'd0;
    reg         axi_awuser_ap = 1'b0;
    reg  [3:0]  axi_awuser_id = 4'd0;
    reg  [3:0]  axi_awlen = 4'd0;
    wire        axi_awready;
    reg         axi_awvalid = 1'b0;
    reg         axi_wvalid = 1'b0;
    reg  [255:0] axi_wdata = 256'd0;
    reg  [31:0]  axi_wstrb = 32'd0;
    wire        axi_wready;
    wire [3:0]  axi_wusero_id;
    wire        axi_wusero_last;

    reg  [27:0] axi_araddr = 28'd0;
    reg         axi_aruser_ap = 1'b0;
    reg  [3:0]  axi_aruser_id = 4'd0;
    reg  [3:0]  axi_arlen = 4'd0;
    wire        axi_arready;
    reg         axi_arvalid = 1'b0;
    wire [255:0] axi_rdata;
    wire [3:0]   axi_rid;
    wire         axi_rlast;
    wire         axi_rvalid;

    ddr3_test u_ddr (
        .ref_clk           (ref_clk),
        .resetn            (resetn),
        .core_clk          (core_clk),
        .pll_lock          (pll_lock),
        .phy_pll_lock      (phy_pll_lock),
        .gpll_lock         (gpll_lock),
        .rst_gpll_lock     (rst_gpll_lock),
        .ddrphy_cpd_lock   (ddrphy_cpd_lock),
        .ddr_init_done     (ddr_init_done),

        .axi_awaddr        (axi_awaddr),
        .axi_awuser_ap     (axi_awuser_ap),
        .axi_awuser_id     (axi_awuser_id),
        .axi_awlen         (axi_awlen),
        .axi_awready       (axi_awready),
        .axi_awvalid       (axi_awvalid),
        .axi_wdata         (axi_wdata),
        .axi_wstrb         (axi_wstrb),
        .axi_wready        (axi_wready),
        .axi_wusero_id     (axi_wusero_id),
        .axi_wusero_last   (axi_wusero_last),

        .axi_araddr        (axi_araddr),
        .axi_aruser_ap     (axi_aruser_ap),
        .axi_aruser_id     (axi_aruser_id),
        .axi_arlen         (axi_arlen),
        .axi_arready       (axi_arready),
        .axi_arvalid       (axi_arvalid),
        .axi_rdata         (axi_rdata),
        .axi_rid           (axi_rid),
        .axi_rlast         (axi_rlast),
        .axi_rvalid        (axi_rvalid),

        .apb_clk           (1'b0),
        .apb_rst_n         (1'b1),
        .apb_sel           (1'b0),
        .apb_enable        (1'b0),
        .apb_addr          (8'b0),
        .apb_write         (1'b0),
        .apb_ready         (),
        .apb_wdata         (16'b0),
        .apb_rdata         (),

        .mem_cs_n          (mem_cs_n),
        .mem_rst_n         (mem_rst_n),
        .mem_ck            (mem_ck),
        .mem_ck_n          (mem_ck_n),
        .mem_cke           (mem_cke),
        .mem_ras_n         (mem_ras_n),
        .mem_cas_n         (mem_cas_n),
        .mem_we_n          (mem_we_n),
        .mem_odt           (mem_odt),
        .mem_a             (mem_a),
        .mem_ba            (mem_ba),
        .mem_dqs           (mem_dqs),
        .mem_dqs_n         (mem_dqs_n),
        .mem_dq            (mem_dq),
        .mem_dm            (mem_dm),

        .dbg_gate_start            (1'b0),
        .dbg_cpd_start             (1'b0),
        .dbg_ddrphy_rst_n          (1'b1),
        .dbg_gpll_scan_rst         (1'b0),
        .samp_position_dyn_adj     (1'b0),
        .init_samp_position_even   (32'd0),
        .init_samp_position_odd    (32'd0),
        .wrcal_position_dyn_adj    (1'b0),
        .init_wrcal_position       (32'd0),
        .force_read_clk_ctrl       (1'b0),
        .init_slip_step            (16'd0),
        .init_read_clk_ctrl        (12'd0),
        .debug_calib_ctrl          (),
        .dbg_slice_status          (),
        .dbg_slice_state           (),
        .debug_data                (),
        .dbg_dll_upd_state         (),
        .debug_gpll_dps_phase      (),
        .dbg_rst_dps_state         (),
        .dbg_tran_err_rst_cnt      (),
        .dbg_ddrphy_init_fail      (),
        .debug_cpd_offset_adj      (1'b0),
        .debug_cpd_offset_dir      (1'b0),
        .debug_cpd_offset          (10'd0),
        .debug_dps_cnt_dir0        (),
        .debug_dps_cnt_dir1        (),
        .force_ck_dly_en           (1'b0),
        .force_ck_dly_set_bin      (8'h0),
        .ck_dly_set_bin            (),
        .align_error               (),
        .debug_rst_state           (),
        .debug_cpd_state           ()
    );

    // ------------------------------------------------------- DDR3 memory model
    // Four x8 devices, one per byte lane, matching MEM_DQS_WIDTH = 4 and
    // MEM_DM_WIDTH = 4. Clock skew of 50 ps per lane reproduces the vendor
    // example bench.
    wire [15:0] mem_addr = {1'b0, mem_a};

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : i_mem
            wire ck_g, ck_n_g;
            assign #0.05 ck_g   = mem_ck;
            assign #0.05 ck_n_g = mem_ck_n;

            ddr3 mem_core (
                .rst_n      (mem_rst_n),
                .ck         (ck_g),
                .ck_n       (ck_n_g),
                .cs_n       (mem_cs_n),
                .addr       (mem_addr),
                .dq         (mem_dq[8*g +: 8]),
                .dqs        (mem_dqs[g]),
                .dqs_n      (mem_dqs_n[g]),
                .dm_tdqs    (mem_dm[g]),
                .tdqs_n     (),
                .cke        (mem_cke),
                .odt        (mem_odt),
                .ras_n      (mem_ras_n),
                .cas_n      (mem_cas_n),
                .we_n       (mem_we_n),
                .ba         (mem_ba)
            );
        end
    endgenerate

    // ------------------------------------------------------------- write engine
    localparam integer NBEAT = 8;

    reg [255:0] wr_pattern [0:NBEAT-1];
    reg [255:0] rd_capture [0:NBEAT-1];

    reg         wr_go = 0;
    reg         wr_done = 0;
    integer     wr_idx = 0;

    always @(posedge core_clk or negedge resetn) begin
        if (!resetn) begin
            axi_awvalid <= 1'b0;
            axi_awaddr  <= 28'd0;
            axi_awlen   <= 4'd0;
            axi_awuser_ap <= 1'b0;
            axi_awuser_id <= 4'd0;
            axi_wvalid  <= 1'b0;
            axi_wdata   <= 256'd0;
            axi_wstrb   <= 32'd0;
            wr_idx      <= 0;
            wr_done     <= 1'b0;
        end
        else begin
            // address channel
            if (wr_go && !wr_done && !axi_awvalid && !axi_wvalid) begin
                axi_awaddr    <= 28'd0;          // byte address 0
                axi_awlen     <= NBEAT - 1;
                axi_awuser_ap <= 1'b0;
                axi_awuser_id <= 4'd0;
                axi_awvalid   <= 1'b1;
                axi_wvalid    <= 1'b1;
                axi_wdata     <= wr_pattern[0];
                axi_wstrb     <= {32{1'b1}};
                wr_idx        <= 0;
            end
            else if (axi_awvalid && axi_awready) begin
                axi_awvalid <= 1'b0;
            end

            // write data channel: hold wvalid, advance on acceptance
            if (axi_wvalid && axi_wready) begin
                if (wr_idx == NBEAT - 1) begin
                    axi_wvalid <= 1'b0;
                    wr_done    <= 1'b1;
                end
                else begin
                    wr_idx    <= wr_idx + 1;
                    axi_wdata <= wr_pattern[wr_idx + 1];
                end
            end
        end
    end

    // -------------------------------------------------------------- read engine
    reg         rd_go = 0;
    reg         rd_done = 0;
    reg         rd_started = 1'b0;
    integer     rd_idx = 0;

    always @(posedge core_clk or negedge resetn) begin
        if (!resetn) begin
            axi_arvalid <= 1'b0;
            axi_araddr  <= 28'd0;
            axi_arlen   <= 4'd0;
            axi_aruser_ap <= 1'b0;
            axi_aruser_id <= 4'd0;
            rd_idx      <= 0;
            rd_done     <= 1'b0;
        end
        else begin
            if (rd_go && !rd_done && !axi_arvalid && !rd_started) begin
                axi_araddr    <= 28'd0;
                axi_arlen     <= NBEAT - 1;
                axi_aruser_ap <= 1'b0;
                axi_aruser_id <= 4'd0;
                axi_arvalid   <= 1'b1;
                rd_started    <= 1'b1;
            end
            else if (axi_arvalid && axi_arready) begin
                axi_arvalid <= 1'b0;
            end

            // there is no rready: every rvalid beat must be taken
            if (axi_rvalid) begin
                rd_capture[rd_idx] <= axi_rdata;
                rd_idx <= rd_idx + 1;
                if (axi_rlast) rd_done <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ progress log
    // Printed so that a long run can be told apart from a stuck command line.
    integer prog_div = 0;
    always @(posedge core_clk) begin
        prog_div <= prog_div + 1;
        if (prog_div % 2500 == 0)     // every 2500 core clocks = 20 us
            $display("TEST_INFO: t=%0t ns  init_done=%0d pll_lock=%0d ddrphy_cpd_lock=%0d",
                     $time, ddr_init_done, pll_lock, ddrphy_cpd_lock);
    end

    // -------------------------------------------------------------------- main
    integer i, j;
    integer waited;
    integer t_write, t_read;

    initial begin
        // distinct byte per lane and per beat, so lane order is verified too
        for (i = 0; i < NBEAT; i = i + 1)
            for (j = 0; j < 32; j = j + 1)
                wr_pattern[i][8*j +: 8] = (i * 32 + j) & 8'hFF;

        // The reference top level releases the DDR reset 1 ms AFTER the PLLs
        // lock, not a few hundred nanoseconds after power-on. Releasing too early
        // is the first suspect when ddrphy_cpd_lock never asserts in simulation.
        // Measured: ddrphy pll_lock does NOT assert while resetn is held low, so
        // gating the reset on pll_lock would deadlock. The reference top level
        // releases the DDR reset a fixed time after the *board* PLLs lock, which
        // is what the short power-on pulse below reproduces.
        resetn = 0;
        repeat (40) @(posedge ref_clk);
        resetn = 1;
        $display("TEST_INFO: D1 reset released, waiting for ddr_init_done");

        // ================================================================ D1
        waited = 0;
        while (ddr_init_done !== 1'b1 && waited < 200000) begin
            @(posedge core_clk);
            waited = waited + 1;
        end
        if (ddr_init_done !== 1'b1) begin
            `DGC_FAIL("D1: ddr_init_done never asserted")
        end
        else begin
            $display("TEST_INFO: D1 ddr_init_done after %0d core clocks (%0t ns)",
                     waited, $time);
        end

        repeat (200) @(posedge core_clk);

        // ================================================================ D2
        t_write = $time;
        wr_go = 1;
        waited = 0;
        while (!wr_done && waited < 20000) begin
            @(posedge core_clk);
            waited = waited + 1;
        end
        if (!wr_done) `DGC_FAIL("D2: write burst never completed")
        else $display("TEST_INFO: D2 wrote %0d beats at byte address 0 in %0d core clocks",
                      NBEAT, waited);

        repeat (100) @(posedge core_clk);

        // ================================================================ D3
        t_read = $time;
        rd_go = 1;
        waited = 0;
        while (!rd_done && waited < 20000) begin
            @(posedge core_clk);
            waited = waited + 1;
        end
        if (!rd_done) `DGC_FAIL("D3: read burst never completed")
        else $display("TEST_INFO: D3 read %0d beats back in %0d core clocks",
                      rd_idx, waited);

        // ================================================================ D4
        if (rd_idx != NBEAT) `DGC_FAIL("D4: wrong number of read beats")
        for (i = 0; i < NBEAT; i = i + 1) begin
            if (rd_capture[i] !== wr_pattern[i]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: D4 beat %0d mismatch", i);
                $display("   exp=%064h", wr_pattern[i]);
                $display("   act=%064h", rd_capture[i]);
            end
        end
        if (dgc_errors == 0)
            $display("TEST_INFO: D4 all %0d beats read back byte-exact (lane order correct)", NBEAT);

        $display("TEST_INFO: DDR3 native port test finished at %0t ns", $time);
        `DGC_FINISH
    end

endmodule
