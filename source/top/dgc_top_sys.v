//-----------------------------------------------------------------------------
// dgc_top_sys.v - integrated HDMI-in / HDMI-out distortion-correction top
//
// This is the S4/S5 board top. It keeps the verified S0 board plumbing:
//   * real board pinout, PLLs and per-domain resets;
//   * localised DDR3 IP as u_ddr3_test_h;
//   * HDMI chip configuration, 1080p60 timing and TMDS serialisers;
// and replaces the S0 test pattern with dgc_core_sys:
//
//   HDMI in -> capture -> DDR3 (3 slots) -> frame_manager
//           -> scheduler/map -> fill/cache -> sampler -> gamma/bilinear
//           -> stripe RAM -> video_reader -> TMDS
//
// `dgc_top.v` is kept unchanged as the S0 bring-up top (test pattern, DDR
// parked) so the existing s0_top regression still proves the board plumbing.
// PDS must synthesise `dgc_top_sys`, not `dgc_top`, for the real system.
//
// Configuration
//   MODE=0 is identity (bring-up); MODE=1 is static k1/k2 correction using the
//   real calibration constants below. The config_manager/UART path is the next
//   step; this top deliberately uses constants so the data path can be proven
//   on the board first.
//-----------------------------------------------------------------------------

module dgc_top_sys #(
    parameter MEM_ROW_ADDR_WIDTH = 15,
    parameter MEM_COL_ADDR_WIDTH = 10,
    parameter MEM_BADDR_WIDTH    = 3,
    parameter MEM_DQ_WIDTH       = 32,
    parameter MEM_DQS_WIDTH      = 32 / 8,
    parameter [15:0] SETTLE_CYCLES = 16'h2710,  // 1 ms at 10 MHz; overridden in simulation
    parameter [15:0] CFG_SETTLE_CYCLES = 16'h2710, // HDMI chip reset width, 1 ms
    parameter integer MODE = 1                   // 0 identity, 1 static k1/k2 (board default)
) (
    input  wire                              sys_clk,          // 27 MHz
    input  wire                              clk_p,            // 125 MHz DDR ref
    input  wire                              clk_n,
    input  wire                              rst_in,           // board C22 rstn, active low

    // ---------------------------------------------------------------- DDR3
    output wire                              mem_rst_n,
    output wire                              mem_ck,
    output wire                              mem_ck_n,
    output wire                              mem_cke,
    output wire                              mem_cs_n,
    output wire                              mem_ras_n,
    output wire                              mem_cas_n,
    output wire                              mem_we_n,
    output wire                              mem_odt,
    output wire [MEM_ROW_ADDR_WIDTH-1:0]     mem_a,
    output wire [MEM_BADDR_WIDTH-1:0]        mem_ba,
    inout  wire [MEM_DQS_WIDTH-1:0]          mem_dqs,
    inout  wire [MEM_DQS_WIDTH-1:0]          mem_dqs_n,
    inout  wire [MEM_DQ_WIDTH-1:0]           mem_dq,
    output wire [MEM_DQ_WIDTH/8-1:0]         mem_dm,

    // ------------------------------------------------------------ HDMI chips
    output wire                              rstn_out,
    output wire                              hd_scl,
    inout  wire                              hd_sda,
    output wire                              hdmi_int_led,
    // LED1 on the MINI board is C19 = the demo's init_over_rx (HDMI RX config
    // done). The manual numbers LED0..3 as A20/C19/C18/E18; the old demo log's
    // table was wrong. Drive it so LED1 reflects the RX configuration.
    output wire                              hdmi_rx_cfg_done_o,

    // --------------------------------------------------------------- HDMI in
    input  wire                              pixclk_in,
    input  wire                              vs_in,
    input  wire                              hs_in,
    input  wire                              de_in,
    input  wire [7:0]                        r_in,
    input  wire [7:0]                        g_in,
    input  wire [7:0]                        b_in,

    // -------------------------------------------------------------- HDMI out
    output wire                              tmds_clk_p,
    output wire                              tmds_clk_n,
    output wire [2:0]                        tmds_data_p,
    output wire [2:0]                        tmds_data_n,

    // ---------------------------------------------------------------- debug
    output wire                              heart_beat_led,
    output wire                              ddr_init_done_o,
    output wire                              debug_uart_tx
);

    // ============================================================== parameters
    localparam CTRL_ADDR_WIDTH = MEM_ROW_ADDR_WIDTH + MEM_BADDR_WIDTH + MEM_COL_ADDR_WIDTH; // 28

    // 1080p60 timing (frozen: 2200 x 1125, 148.5 MHz pixel, 742.5 MHz serial)
    localparam H_ACT   = 12'd1920;
    localparam H_FP    = 12'd88;
    localparam H_SYNC  = 12'd44;
    localparam H_BP    = 12'd148;
    localparam V_ACT   = 12'd1080;
    localparam V_FP    = 12'd4;
    localparam V_SYNC  = 12'd5;
    localparam V_BP    = 12'd36;
    localparam V_TOTAL = 12'd1125;
    localparam H_TOTAL = 12'd2200;

    // ================================================================ clocks
    wire clk_125Mhz;
    wire proc_clk, cfg_clk, vout_clk, vout_clk_5x;

    wire plls_lock, init_ready;
    wire ddr_arst_n, data_arst_n;
    wire cfg_rst_n, ddr_rst_n, proc_rst_n, vout_rst_n, vout5x_rst_n;
    wire pll_proc_lock, pll_cfg_lock, pll_hdmi_lock;

    GTP_INBUFGDS #(
        .IOSTANDARD ("DEFAULT"),
        .TERM_DIFF  ("ON")
    ) u_ddr_ref_buf (
        .O  (clk_125Mhz),
        .I  (clk_p),
        .IB (clk_n)
    );

    wire ddr_core_clk;
    wire ddr_pll_lock;
    wire ddr_init_done;

    dgc_clock_reset #(
        .SETTLE_CYCLES (SETTLE_CYCLES),
        .CFG_SETTLE_CYCLES (CFG_SETTLE_CYCLES)
    ) u_clock_reset (
        .sys_clk        (sys_clk),
        // Board pin C22 is the active-low rstn used by the vendor LED/key demos
        // (led_test/key_led_test); dgc_clock_reset expects active-high rst_in.
        // The previous direct connection held every domain in reset whenever
        // the button was not pressed (C22 high), which is the first-board
        // "LED0 steady / no HDMI / no DDR" symptom.
        .rst_in         (~rst_in),
        .ddr_core_clk   (ddr_core_clk),
        .ddr_pll_lock   (ddr_pll_lock),
        .ddr_init_done  (ddr_init_done),
        .proc_clk       (proc_clk),
        .cfg_clk        (cfg_clk),
        .vout_clk       (vout_clk),
        .vout_clk_5x    (vout_clk_5x),
        .plls_lock      (plls_lock),
        .init_ready     (init_ready),
        .pll_proc_lock_o(pll_proc_lock),
        .pll_cfg_lock_o (pll_cfg_lock),
        .pll_hdmi_lock_o(pll_hdmi_lock),
        .ddr_arst_n     (ddr_arst_n),
        .data_arst_n    (data_arst_n),
        .cfg_rst_n      (cfg_rst_n),
        .ddr_rst_n      (ddr_rst_n),
        .proc_rst_n     (proc_rst_n),
        .vout_rst_n     (vout_rst_n),
        .vout5x_rst_n   (vout5x_rst_n)
    );

    // =============================================================== HDMI cfg
    // The I2C programmer lives in the 10 MHz domain and is released as soon as
    // that PLL locks. It does not touch the pixel path.
    wire hdmi_cfg_done;
    wire hdmi_rx_cfg_done;
    wire [5:0] dbg_tx_state;
    wire [7:0] dbg_tx_data_out;

    ms72xx_ctl u_ms72xx_ctl (
        .clk          (cfg_clk),
        .rst_n        (cfg_rst_n),
        .init_over_rx (hdmi_rx_cfg_done),
        .init_over    (hdmi_cfg_done),
        .iic_scl      (hd_scl),
        .iic_sda      (hd_sda),
        .dbg_tx_state (dbg_tx_state),
        .dbg_tx_dri   (),
        .dbg_tx_cmd   (),
        .dbg_tx_data_out (dbg_tx_data_out),
        .dbg_tx_busy  ()
    );

    assign rstn_out     = cfg_rst_n;
    assign hdmi_int_led = hdmi_cfg_done;
    assign hdmi_rx_cfg_done_o = hdmi_rx_cfg_done;

    // ============================================================ DDR3 memory
    // Native simplified-AXI user port. One and only one module may drive it.
    wire [CTRL_ADDR_WIDTH-1:0] axi_awaddr;
    wire                       axi_awuser_ap;
    wire [3:0]                 axi_awuser_id;
    wire [3:0]                 axi_awlen;
    wire                       axi_awready;
    wire                       axi_awvalid;
    wire [MEM_DQ_WIDTH*8-1:0]  axi_wdata;
    wire [MEM_DQ_WIDTH-1:0]    axi_wstrb;
    wire                       axi_wready;
    wire [3:0]                 axi_wusero_id;
    wire                       axi_wusero_last;
    wire [CTRL_ADDR_WIDTH-1:0] axi_araddr;
    wire                       axi_aruser_ap;
    wire [3:0]                 axi_aruser_id;
    wire [3:0]                 axi_arlen;
    wire                       axi_arready;
    wire                       axi_arvalid;
    wire [MEM_DQ_WIDTH*8-1:0]  axi_rdata;
    wire [3:0]                 axi_rid;
    wire                       axi_rlast;
    wire                       axi_rvalid;

    wire phy_pll_lock, gpll_lock, rst_gpll_lock, ddrphy_cpd_lock;

    ddr3_test #(
        .MEM_ROW_WIDTH    (MEM_ROW_ADDR_WIDTH),
        .MEM_COLUMN_WIDTH (MEM_COL_ADDR_WIDTH),
        .MEM_BANK_WIDTH   (MEM_BADDR_WIDTH),
        .MEM_DQ_WIDTH     (MEM_DQ_WIDTH),
        .MEM_DM_WIDTH     (MEM_DQ_WIDTH / 8),
        .MEM_DQS_WIDTH    (MEM_DQS_WIDTH),
        .CTRL_ADDR_WIDTH  (CTRL_ADDR_WIDTH)
    ) u_ddr3_test_h (
        .ref_clk           (clk_125Mhz),
        .resetn            (ddr_arst_n),
        .core_clk          (ddr_core_clk),
        .pll_lock          (ddr_pll_lock),
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
        .init_samp_position_even   ({8*MEM_DQS_WIDTH{1'b0}}),
        .init_samp_position_odd    ({8*MEM_DQS_WIDTH{1'b0}}),
        .wrcal_position_dyn_adj    (1'b0),
        .init_wrcal_position       ({8*MEM_DQS_WIDTH{1'b0}}),
        .force_read_clk_ctrl       (1'b0),
        .init_slip_step            ({4*MEM_DQS_WIDTH{1'b0}}),
        .init_read_clk_ctrl        ({3*MEM_DQS_WIDTH{1'b0}}),
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

    assign ddr_init_done_o = ddr_init_done;

    // The simplified-AXI user side has no user_ap/user_id support in the new
    // adapters; the DDR IP requires them tied low. All other native signals are
    // driven by dgc_core_sys below (exactly one driver for each channel).
    assign axi_awuser_ap = 1'b0;
    assign axi_awuser_id = 4'd0;
    assign axi_aruser_ap = 1'b0;
    assign axi_aruser_id = 4'd0;

    // ============================================================ HDMI input
    // Vin domain. The captured pixels are registered and counted at S0; S2's
    // capture_writer consumes exactly this bus.
    wire vin_rst_n;
    dgc_rst_sync #(.STAGES(3)) u_rst_vin (
        .clk         (pixclk_in),
        .rst_async_n (data_arst_n),
        .rst_n       (vin_rst_n)
    );

    reg        vs_in_r, hs_in_r, de_in_r;
    reg [23:0] rgb_in_r;

    always @(posedge pixclk_in or negedge vin_rst_n) begin
        if (!vin_rst_n) begin
            vs_in_r <= 1'b0;
            hs_in_r <= 1'b0;
            de_in_r <= 1'b0;
            rgb_in_r <= 24'd0;
        end
        else begin
            vs_in_r  <= vs_in;
            hs_in_r  <= hs_in;
            de_in_r  <= de_in;
            rgb_in_r <= {r_in, g_in, b_in};
        end
    end

    // Input frame / pixel counters: the S0 evidence that pixels really arrive,
    // and the hook that capture_writer statistics will replace at S2.
    reg [31:0] vin_frame_cnt;
    reg [31:0] vin_pixel_cnt;

    always @(posedge pixclk_in or negedge vin_rst_n) begin
        if (!vin_rst_n) begin
            vin_frame_cnt <= 32'd0;
            vin_pixel_cnt <= 32'd0;
        end
        else begin
            if (vs_in_r) vin_frame_cnt <= vin_frame_cnt + 32'd1;
            if (de_in_r) vin_pixel_cnt <= vin_pixel_cnt + 32'd1;
        end
    end

    // =============================================================== HDMI out
    // Output timing (vout domain).
    wire        vs_o, hs_o, de_o;
    wire [11:0] x_o, y_o;

    sync_vg #(
        .X_BITS   (12),
        .Y_BITS   (12),
        .V_TOTAL  (V_TOTAL),
        .V_FP     (V_FP),
        .V_BP     (V_BP),
        .V_SYNC   (V_SYNC),
        .V_ACT    (V_ACT),
        .H_TOTAL  (H_TOTAL),
        .H_FP     (H_FP),
        .H_BP     (H_BP),
        .H_SYNC   (H_SYNC),
        .H_ACT    (H_ACT),
        .HV_OFFSET(12'd0)
    ) u_sync_vg (
        .clk    (vout_clk),
        .rstn   (vout_rst_n),
        .vs_out (vs_o),
        .hs_out (hs_o),
        .de_out (de_o),
        .de_re  (),
        .x_act  (x_o),
        .y_act  (y_o)
    );

    // ======================================================= integrated system
    // DDR-domain reset that waits for ddr_init_done. ddr_rst_n from the clock
    // block is released as soon as the PLLs are stable (before DDR training);
    // the frame manager / adapters must not run until the controller is ready.
    wire ddr_data_rst_n;
    dgc_rst_sync #(.STAGES(3)) u_rst_ddr_data (
        .clk         (ddr_core_clk),
        .rst_async_n (data_arst_n),
        .rst_n       (ddr_data_rst_n)
    );

    // Output frame boundary (vout vs_fall) as a single-bit toggle, synchronised
    // into proc_clk. `dgc_core_sys` uses this to start each job exactly at the
    // display frame boundary.
    reg  vs_o_d;
    reg  tick_tgl;
    reg  [2:0] tick_sync;
    always @(posedge vout_clk or negedge vout_rst_n) begin
        if (!vout_rst_n) vs_o_d <= 1'b0;
        else             vs_o_d <= vs_o;
    end
    wire vs_fall = vs_o_d & ~vs_o;
    always @(posedge vout_clk or negedge vout_rst_n) begin
        if (!vout_rst_n)        tick_tgl <= 1'b0;
        else if (vs_fall)       tick_tgl <= ~tick_tgl;
    end
    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) tick_sync <= 3'b000;
        else             tick_sync <= {tick_sync[1:0], tick_tgl};
    end
    wire frame_tick = tick_sync[2] ^ tick_sync[1];

    // ------------------------------------------------------ active parameters
    // Real calibration (calib_round3_nolamp/calib.json) in the frozen encodings.
    // MODE=0 ignores all of these and passes the output coordinate through;
    // MODE=1 runs the radtan model with the default K-derived matrix.
    localparam signed [31:0] CFG_FX  = 32'sd137377855;   // 2096.2197 in F16
    localparam signed [31:0] CFG_FY  = 32'sd138692973;   // 2116.2868
    localparam signed [31:0] CFG_CX  = 32'sd64030536;    //  977.0284
    localparam signed [31:0] CFG_CY  = 32'sd34085643;    //  520.1056
    localparam signed [31:0] CFG_K1  = -32'sd129279204;  // -0.4816026 in F28
    localparam signed [31:0] CFG_K2  = 32'sd74679738;    //  0.2782037
    localparam signed [31:0] CFG_M00 = 32'sd32014;
    localparam signed [31:0] CFG_M02 = -32'sd31278815;
    localparam signed [31:0] CFG_M11 = 32'sd31711;
    localparam signed [31:0] CFG_M12 = -32'sd16492896;
    localparam        [31:0] CFG_NRM = 32'd134217728;    // 2.0 in F26

    wire [23:0] rgb_out;
    wire        de_out, hs_out, vs_out;
    wire [31:0] st_wr, st_proc, st_uf, st_drop, st_err;
    wire        frame_black;
    wire        dbg_core_busy;
    wire [1:0]  dbg_job_state;
    wire [15:0] dbg_cap_frames, dbg_cap_aborted, dbg_write_done, dbg_drop, dbg_core_blocks;
    wire [15:0] dbg_wa_frames, dbg_wa_aborts, dbg_fm_alloc, dbg_fm_drop;
    wire [15:0] dbg_fm_acquire, dbg_fm_release, dbg_reader_flags, dbg_offers;
wire [15:0] dbg_job_fid;
    wire [10:0] dbg_cap_rows;
    wire [7:0]  dbg_slot_state;
    wire [2:0]  dbg_cstate;
    wire        dbg_fill_busy, dbg_samp_busy, dbg_next_valid;
    wire [15:0] dbg_no_pend_us, dbg_tick_skip;   // 2026-11-03: G0/G1 scheduling counters
    wire [7:0]  dbg_acq_req, dbg_acq_got;        // 2026-11-03: K0 acquire request/response
    wire [15:0] dbg_pix_seen;
    wire [2:0]  dbg_wr_busy;
    wire [11:0] dbg_wr_state;
    wire [15:0] dbg_job_us;
    wire [6:0]  dbg_pix_sid;
    wire [6:0]  dbg_cur_sid0;
    wire [3:0]  dbg_reading;
    wire        dbg_rd_timeout;
    wire [1:0]  dbg_cur_bank, dbg_next_bank;
    wire        dbg_aux_busy, dbg_rel_drop, dbg_vs_discard;
    wire [7:0]  dbg_pix_over;
    wire [7:0]  dbg_fill_flags;
    wire [6:0]  dbg_gap_max;
    wire [6:0]  dbg_uf_stripe;
    wire        dbg_uf_first;
    // DGC3 performance report bundles and the snapshot latch pulses that make
    // their accumulators publish and restart on the same edge as the holds.
    wire [127:0] dbg_perf_proc;
    wire [63:0]  dbg_perf_ddr;
    wire [63:0]  dbg_perf_vout;
    wire         proc_snap_latch, ddr_snap_latch, vout_snap_latch;

    dgc_core_sys #(
        .FRAME_BYTES      (6220800),
        // Frame alignment restored; the ALIGN_TO_FRAME=0 experiment did not
        // change the board behaviour (core still stopped mid-frame).
        .ALIGN_TO_FRAME   (1)   // 2026-11-02: keep the boundary align; a late start is
                                 // absorbed by the reader's pending-first stripe instead
    ) u_core_sys (
        .vin_clk        (pixclk_in),
        .vin_rst_n      (vin_rst_n),
        .ddr_clk        (ddr_core_clk),
        .ddr_rst_n      (ddr_data_rst_n),
        .proc_clk       (proc_clk),
        .proc_rst_n     (proc_rst_n),
        .vout_clk       (vout_clk),
        .vout_rst_n     (vout_rst_n),

        .vs_in          (vs_in_r),
        .hs_in          (hs_in_r),
        .de_in          (de_in_r),
        .rgb_in         (rgb_in_r),

        .axi_awaddr     (axi_awaddr),
        .axi_awlen      (axi_awlen),
        .axi_awvalid    (axi_awvalid),
        .axi_awready    (axi_awready),
        .axi_wdata      (axi_wdata),
        .axi_wstrb      (axi_wstrb),
        .axi_wready     (axi_wready),
        .axi_wusero_id  (axi_wusero_id),
        .axi_wusero_last(axi_wusero_last),

        .axi_araddr     (axi_araddr),
        .axi_arlen      (axi_arlen),
        .axi_arvalid    (axi_arvalid),
        .axi_arready    (axi_arready),
        .axi_rdata      (axi_rdata),
        .axi_rvalid     (axi_rvalid),
        .axi_rlast      (axi_rlast),
        .axi_rid        (axi_rid),

        .cfg_mode       (MODE[1:0]),
        .cfg_m00        (CFG_M00), .cfg_m01 (32'sd0), .cfg_m02 (CFG_M02),
        .cfg_m10        (32'sd0),  .cfg_m11 (CFG_M11), .cfg_m12 (CFG_M12),
        .cfg_fx         (CFG_FX),  .cfg_fy  (CFG_FY),
        .cfg_cx         (CFG_CX),  .cfg_cy  (CFG_CY),
        .cfg_k1         (CFG_K1),  .cfg_k2  (CFG_K2),
        .cfg_norm_abs_max (CFG_NRM),
        .gamma_mode     (2'd0),

        .frame_tick     (frame_tick),
        .de_tg          (de_o), .hs_tg (hs_o), .vs_tg (vs_o),
        .x_tg           (x_o),  .y_tg  (y_o),

        .rgb_out        (rgb_out), .de_out (de_out),
        .hs_out         (hs_out),  .vs_out (vs_out),

        .stat_frames_written   (st_wr),
        .stat_frames_processed (st_proc),
        .stat_stripes_underflow(st_uf),
        .stat_frames_dropped   (st_drop),
        .stat_ddr_errors       (st_err),
        .frame_black           (frame_black),
        .dbg_core_busy         (dbg_core_busy),
        .dbg_job_state         (dbg_job_state),
        .dbg_cap_frames        (dbg_cap_frames),
        .dbg_cap_aborted       (dbg_cap_aborted),
        .dbg_cap_rows          (dbg_cap_rows),
        .dbg_write_done        (dbg_write_done),
        .dbg_wa_frames         (dbg_wa_frames),
        .dbg_wa_aborts         (dbg_wa_aborts),
        .dbg_drop              (dbg_drop),
        .dbg_slot_state        (dbg_slot_state),
        .dbg_fm_alloc          (dbg_fm_alloc),
        .dbg_fm_drop           (dbg_fm_drop),
        .dbg_fm_acquire        (dbg_fm_acquire),
        .dbg_fm_release        (dbg_fm_release),
        .dbg_core_blocks       (dbg_core_blocks),
        .dbg_cstate            (dbg_cstate),
        .dbg_fill_busy         (dbg_fill_busy),
        .dbg_samp_busy         (dbg_samp_busy),
        .dbg_next_valid        (dbg_next_valid),
        .dbg_no_pend_us        (dbg_no_pend_us),
        .dbg_tick_skip         (dbg_tick_skip),
        .dbg_acq_req           (dbg_acq_req),
        .dbg_acq_got           (dbg_acq_got),
        .dbg_pix_seen          (dbg_pix_seen),
        .dbg_wr_busy           (dbg_wr_busy),
        .dbg_aux_busy          (dbg_aux_busy),
        .dbg_wr_state          (dbg_wr_state),
        .dbg_job_us            (dbg_job_us),
        .dbg_pix_sid           (dbg_pix_sid),
        .dbg_cur_sid0          (dbg_cur_sid0),
        .dbg_reading           (dbg_reading),
        .dbg_rd_timeout        (dbg_rd_timeout),
        .dbg_pix_over          (dbg_pix_over),
        .dbg_fill_flags        (dbg_fill_flags),
        .dbg_gap_max           (dbg_gap_max),
        .dbg_uf_stripe         (dbg_uf_stripe),
        .dbg_uf_first          (dbg_uf_first),
        .dbg_reader_flags      (dbg_reader_flags),
        .dbg_offers            (dbg_offers),
        .dbg_cur_bank          (dbg_cur_bank),
        .dbg_next_bank         (dbg_next_bank),
        .dbg_rel_drop          (dbg_rel_drop),
        .dbg_vs_discard        (dbg_vs_discard),
        .dbg_job_fid           (dbg_job_fid),
        .dbg_proc_latch        (proc_snap_latch),
        .dbg_ddr_latch         (ddr_snap_latch),
        .dbg_vout_latch        (vout_snap_latch),
        .dbg_perf_proc         (dbg_perf_proc),
        .dbg_perf_ddr          (dbg_perf_ddr),
        .dbg_perf_vout         (dbg_perf_vout)
    );

    // One register stage aligns RGB/DE/HS/VS with the registered DE that the
    // TMDS encoder samples. All four signals are delayed together.
    reg        de_o_r, hs_o_r, vs_o_r;
    reg [23:0] rgb_o_r;

    always @(posedge vout_clk or negedge vout_rst_n) begin
        if (!vout_rst_n) begin
            de_o_r <= 1'b0;
            hs_o_r <= 1'b0;
            vs_o_r <= 1'b0;
            rgb_o_r <= 24'd0;
        end
        else begin
            de_o_r <= de_out;
            hs_o_r <= hs_out;
            vs_o_r <= vs_out;
            rgb_o_r <= rgb_out;
        end
    end

    rgb2tmds u_rgb2tmds (
        .tmds_clk_p  (tmds_clk_p),
        .tmds_clk_n  (tmds_clk_n),
        .tmds_data_p (tmds_data_p),
        .tmds_data_n (tmds_data_n),
        .rstn        (vout5x_rst_n),
        .vid_pdata   (rgb_o_r),
        .vid_pvde    (de_o_r),
        .vid_phsync  (hs_o_r),
        .vid_pvsync  (vs_o_r),
        .pixelclk    (vout_clk),
        .serialclk   (vout_clk_5x)
    );

    // ================================================================ debug
    // DGC2 reporter: 27 MHz domain, board-reset-only. It works even while
    // DDR/HDMI/video are still in reset and prints one coherent, versioned
    // snapshot per second instead of reading live buses mid-transmission.
    //
    //   DGC2 S=...  status / capture
    //   DGC2 I=...  input raster (this is what tells us whether the camera is
    //               really 1920x1080, which the capture path assumes)
    //   DGC2 W=...  write frames good vs aborted (never mixed again)
    //   DGC2 J=...  jobs / core blocks / job flags / slot states
    //   DGC2 G=...  full 10-bit record counters and reader flags
    //   DGC2 K=...  acquire/release, stripe offers, sticky event flags
    reg [7:0] pix_div;
    reg       pix_tgl;

    always @(posedge pixclk_in or negedge rst_in) begin
        if (!rst_in) begin
            pix_div <= 8'd0;
            pix_tgl <= 1'b0;
        end
        else if (pix_div == 8'hFF) begin
            pix_div <= 8'd0;
            pix_tgl <= ~pix_tgl;
        end
        else begin
            pix_div <= pix_div + 8'd1;
        end
    end

    // ------------------------------------------------------ input raster probe
    // One window marker every 2^21 sys clocks (77.67 ms at 27 MHz).
    reg [20:0] gate_cnt;
    reg        gate_tgl;

    always @(posedge sys_clk or negedge rst_in) begin
        if (!rst_in) begin
            gate_cnt <= 21'd0;
            gate_tgl <= 1'b0;
        end
        else if (gate_cnt == 21'h1FFFFF) begin
            gate_cnt <= 21'd0;
            gate_tgl <= ~gate_tgl;
        end
        else begin
            gate_cnt <= gate_cnt + 21'd1;
        end
    end

    wire [23:0] it_fclk_cnt;
    wire [11:0] it_line_px, it_frame_lines;
    wire        it_de_seen, it_vs_seen;

    dgc_input_timing u_input_timing (
        .pixclk      (pixclk_in),
        .rst_n       (vin_rst_n),
        .de          (de_in),
        .vs          (vs_in),
        .gate_tgl    (gate_tgl),
        .fclk_cnt    (it_fclk_cnt),
        .line_px     (it_line_px),
        .frame_lines (it_frame_lines),
        .de_seen     (it_de_seen),
        .vs_seen     (it_vs_seen)
    );

    // ------------------------------------------------------ status snapshots
    // All fields below are observation-only; nothing here feeds the datapath.
    //
    // 2026-11-02 22:45: W2/W3 carry the input/output RGB rolling sums again. They
    // were removed on 10-31 15:55 in favour of a core-FSM snapshot and a fill-start
    // counter, but those two are now redundant (J2 already reports cstate,
    // fill_busy, samp_busy, next_valid, px_ready and every bank-busy bit), while the
    // board has a black screen with a *healthy* stripe pipeline (G3 frame_black=0,
    // cur_ok=1, cur_stripe=46, V0=V3=3400). The only remaining question is whether
    // the pixel *content* flows, and these two sums answer it in one capture:
    //   input sum changing, output sum frozen -> the black is in the output / stripe
    //   data (or in what the job read from DDR);
    //   both frozen                           -> the black is in the capture / DDR
    //   write / frame base.
    //
    // The accumulator is 32 bits and only its upper half is printed, because a
    // 16-bit sum can read *constant* for a flat source: one frame is 2,073,600 =
    // 2^10 x 2025 valid pixels, so a frame whose per-pixel R+G+B is a multiple of 64
    // adds a multiple of 65536 and the low 16 bits never move. The upper half cannot
    // alias: it would need a per-pixel sum of 2^22. Both are one 32-bit adder per
    // domain, registered, in the same domain as the pixels they count.
    reg [31:0] in_rgb_sum;
    always @(posedge pixclk_in or negedge vin_rst_n)
        if (!vin_rst_n) in_rgb_sum <= 32'd0;
        else if (de_in_r) in_rgb_sum <= in_rgb_sum + {8'd0, rgb_in_r[23:16]}
                                                   + {8'd0, rgb_in_r[15:8]}
                                                   + {8'd0, rgb_in_r[7:0]};

    // 2026-11-03 timing: the single-cycle version was the worst vout path of the
    // 07:48 P&R (out_rgb_sum[28] -0.093, [24] -0.003, group WNS -0.084): one 32-bit
    // carry chain behind a three-byte adder tree does not fit 148.5 MHz after the
    // placement moved. Split it into two pipeline stages - the byte sum is
    // registered, the 32-bit accumulate happens on the next cycle - which keeps the
    // same rolling sum (only the count of a pixel is delayed by one cycle, which is
    // irrelevant for a rolling sum) and leaves each stage with one short adder.
    reg [9:0] out_rgb_b;
    reg       out_rgb_bv;
    always @(posedge vout_clk or negedge vout_rst_n)
        if (!vout_rst_n) begin
            out_rgb_b  <= 10'd0;
            out_rgb_bv <= 1'b0;
        end
        else begin
            out_rgb_bv <= de_out;
            if (de_out) out_rgb_b <= {2'b0, rgb_out[23:16]}
                                   + {2'b0, rgb_out[15:8]}
                                   + {2'b0, rgb_out[7:0]};
        end

    reg [31:0] out_rgb_sum;
    always @(posedge vout_clk or negedge vout_rst_n)
        if (!vout_rst_n) out_rgb_sum <= 32'd0;
        else if (out_rgb_bv) out_rgb_sum <= out_rgb_sum + {22'd0, out_rgb_b};

    wire [127:0] vin_status = {
        in_rgb_sum[31:16],                      // w7 W2 input RGB rolling sum, upper half
        {4'd0, it_frame_lines},                 // w6
        {4'd0, it_line_px},                     // w5
        {8'd0, it_fclk_cnt[23:16]},             // w4
        it_fclk_cnt[15:0],                      // w3
        {5'd0, dbg_cap_rows},                   // w2
        dbg_cap_aborted,                        // w1
        dbg_cap_frames                          // w0
    };

    wire [239:0] ddr_status = {
        dbg_fm_drop,                            // w14 M3 allocation drops
        dbg_fm_release,                         // w13 M2 releases
        dbg_fm_alloc,                           // w12 M1 capture frame counter
        dbg_perf_ddr,                           // w4..w7 DGC3 R line
        {8'd0, dbg_slot_state},                 // w7 (4 slots x 2 bits)
        16'd0,                                  // w6
        dbg_fm_release,                         // w5
        dbg_fm_acquire,                         // w4
        dbg_fm_drop,                            // w3
        dbg_fm_alloc,                           // w2
        dbg_wa_aborts,                          // w1
        dbg_wa_frames                           // w0
    };

    // frame_black deliberately NOT included: it lives in the vout domain and
    // pulling it into this proc-domain bundle created a real -3.285 ns CDC path
    // into u_snap_proc/hold. It is already reported in the G line's reader
    // flags (bit 10), sampled in its own domain.
    wire [15:0] job_flags16 = {
        dbg_wr_busy, dbg_rd_timeout, dbg_next_valid, dbg_samp_busy, dbg_fill_busy, dbg_cstate,
        (st_err != 32'd0), (st_drop != 32'd0), dbg_aux_busy,
        dbg_core_busy, dbg_job_state
    };

    // 2026-11-02 22:45: the two top words (core-FSM snapshot, fill starts per
    // interval) are gone; W2/W3 now come from the vin/vout bundles, and every bit
    // of the core FSM they carried is still in J2 (cstate, fill_busy, samp_busy,
    // next_valid, px_ready, bank busy, core_busy, job_state).
    // Explicit per-word assignment (2026-11-03). This bundle used to be one big
    // concatenation, and when one field grew - the K0 word carried a 23-bit
    // expression instead of 16 - the total silently exceeded the wire, the top 7
    // bits were truncated and every word above K0 (K0/K1/K2, P, Q, M0) shifted by 7
    // bits. On the board that read as "K1 is a constant 56319" (= {job_us[8:0],
    // gap_max[6:0]}). Assigning word by word makes any future width mistake a
    // warning on that line instead of a silent shift of everything above it.
    wire [271:0] proc_status;
    assign proc_status[ 15:  0] = st_proc[15:0];                         // w0  jobs
    assign proc_status[ 31: 16] = dbg_core_blocks;                       // w1  blocks
    assign proc_status[ 47: 32] = job_flags16;                           // w2  job flags
    // w3/w4: 2026-11-03 replaced the per-block recs_total/sample_left snapshot
    // (already covered by J blocks and K1) with the two scheduling counters.
    assign proc_status[ 63: 48] = dbg_no_pend_us;                        // w3  G0 wait-for-frame us
    assign proc_status[ 79: 64] = dbg_tick_skip;                         // w4  G1 lost boundaries
    // w5: 2026-11-03 acquire request/response counters (they replaced gap_max/pix_over/
    // fill_flags - gap_max was saturated at 31.75 ms and the other two are covered by J2/K2).
    assign proc_status[ 95: 80] = {dbg_acq_req, dbg_acq_got};             // w5  K0
    assign proc_status[111: 96] = dbg_job_us;                            // w6  K1 job us
    assign proc_status[127:112] = {dbg_pix_sid, dbg_cur_sid0,
                                   dbg_reading[1:0]};                    // w7  K2
    assign proc_status[255:128] = dbg_perf_proc;                         // w8..w15 P/Q
    assign proc_status[271:256] = dbg_job_fid;                           // w16 M0

    // DGC5: words 4..7 are the reader interval counters (offers / discards /
    // frames / releases since the previous snapshot); they are published on the
    // same edge as the hold, so they line up with u_snap_vout's latch_evt.
    // 2026-11-02: V2 (the third event counter, vs_fall) is replaced by the starve
    // report: {8'd0, first, stripe[6:0]}.  0 = no starvation in the window,
    // bit7 = stripe 0 missed the porch, bits[6:0] = stripe index where the frame
    // died.  vs_fall is a constant 60/s and is not worth a word.
    wire [63:0] vout_perf_pub = { dbg_perf_vout[63:48], {8'd0, dbg_uf_first, dbg_uf_stripe},
                                  dbg_perf_vout[31:16], dbg_perf_vout[15:0] };
    wire [143:0] vout_status = {
        out_rgb_sum[31:16],                     // w8 W3 output RGB rolling sum, upper half
        vout_perf_pub,                          // w4..w7 DGC5 reader counters (V2 = starve)
        {14'd0, dbg_vs_discard, dbg_rel_drop},  // w3 DGC5 reader anomaly stickies
        dbg_offers,                             // w2
        dbg_reader_flags,                       // w1
        st_uf[15:0]                             // w0
    };

    wire [127:0] vin_hold;
    wire [239:0] ddr_hold;
    wire [271:0] proc_hold;
    wire [143:0] vout_hold;
    wire         vin_ack, ddr_ack, proc_ack, vout_ack;
    wire         snap_req;
    wire [703:0] st_words;
    wire         snap_start, snap_done;

    // 2026-10-30 timing: each status bus is a wide combinational mux of live
    // counters, and its path into the snapshot hold reappeared as the slowest
    // proc/vout path after every placement change (e.g. reader/cnt_offers[8] ->
    // u_snap_vout/hold[39]). One register stage per domain shortens that path;
    // the 1 Hz report then shows the values of one clock earlier, which is
    // irrelevant for telemetry and does not touch any functional path.

    dgc_snapshot_src #(.W(128)) u_snap_vin (
        .clk (pixclk_in), .rst_n (vin_rst_n),
        .req_tgl (snap_req), .data (vin_status),
        .hold (vin_hold), .latch_evt (), .ack_tgl (vin_ack)
    );

    dgc_snapshot_src #(.W(240)) u_snap_ddr (
        .clk (ddr_core_clk), .rst_n (ddr_rst_n),
        .req_tgl (snap_req), .data (ddr_status),
        .hold (ddr_hold), .latch_evt (ddr_snap_latch), .ack_tgl (ddr_ack)
    );

    dgc_snapshot_src #(.W(272)) u_snap_proc (
        .clk (proc_clk), .rst_n (proc_rst_n),
        .req_tgl (snap_req), .data (proc_status),
        .hold (proc_hold), .latch_evt (proc_snap_latch), .ack_tgl (proc_ack)
    );

    dgc_snapshot_src #(.W(144)) u_snap_vout (
        .clk (vout_clk), .rst_n (vout_rst_n),
        .req_tgl (snap_req), .data (vout_status),
        .hold (vout_hold), .latch_evt (vout_snap_latch), .ack_tgl (vout_ack)
    );

    // S status word (unchanged bit layout from the 10-26 reporter, except that
    // the "pixel activity" bit is now cleared by each completed snapshot).
    reg [1:0] pix_sync;
    reg       pix_prev;
    reg       pix_seen;

    always @(posedge sys_clk or negedge rst_in) begin
        if (!rst_in) begin
            pix_sync <= 2'd0;
            pix_prev <= 1'b0;
            pix_seen <= 1'b0;
        end
        else begin
            pix_sync <= {pix_sync[0], pix_tgl};
            if (pix_sync[1] != pix_prev) begin
                pix_prev <= pix_sync[1];
                pix_seen <= 1'b1;
            end
            if (snap_done) pix_seen <= 1'b0;
        end
    end

    // ------------------------------------------- S-line event latches (DGC3)
    // The 2026-10-30 board runs twice lost the input link (I=0000, jobs=0) and
    // the display intermittently reported "no signal", but the 1 Hz snapshot
    // cannot see a short lock loss or a re-asserted reset. These three sticky
    // bits make such an event survive until the next query, using bits that
    // DGC2 documented as "reserved = 0", so a normal board still reads 1FFD:
    //   [15] a PLL lock dropped after all four locks had been seen
    //   [14] a domain reset re-asserted after all domains had been released
    //   [13] hdmi_rx_cfg_done (MS7200) dropped after it had been seen
    // They are set by a level missing for at least one 27 MHz cycle, which is
    // far shorter than any real PLL unlock, and never cleared except by reset.
    wire all_locks = ddr_pll_lock & pll_hdmi_lock & pll_cfg_lock & pll_proc_lock;
    wire all_rst_n = vout5x_rst_n & vout_rst_n & proc_rst_n & ddr_rst_n & cfg_rst_n;

    reg seen_locks, seen_rst_rel, seen_rx_cfg;
    reg pll_lost_sticky, rst_drop_sticky, rx_cfg_lost_sticky;

    always @(posedge sys_clk or negedge rst_in) begin
        if (!rst_in) begin
            seen_locks <= 1'b0; seen_rst_rel <= 1'b0; seen_rx_cfg <= 1'b0;
            pll_lost_sticky <= 1'b0; rst_drop_sticky <= 1'b0;
            rx_cfg_lost_sticky <= 1'b0;
        end
        else begin
            if (all_locks)  seen_locks   <= 1'b1;
            if (all_rst_n)  seen_rst_rel <= 1'b1;
            if (hdmi_rx_cfg_done) seen_rx_cfg <= 1'b1;
            if (seen_locks   && !all_locks)         pll_lost_sticky <= 1'b1;
            if (seen_rst_rel && !all_rst_n)         rst_drop_sticky <= 1'b1;
            if (seen_rx_cfg  && !hdmi_rx_cfg_done)  rx_cfg_lost_sticky <= 1'b1;
        end
    end

    wire [15:0] s_status16 = {
        pll_lost_sticky, rst_drop_sticky, rx_cfg_lost_sticky,
        {ddr_pll_lock, pll_hdmi_lock, pll_cfg_lock, pll_proc_lock},
        {vout5x_rst_n, vout_rst_n, proc_rst_n, ddr_rst_n, cfg_rst_n},
        ddr_init_done, hdmi_rx_cfg_done, hdmi_cfg_done, pix_seen
    };

    wire [15:0] t_status16 = {2'b00, dbg_tx_state, dbg_tx_data_out};

    dgc_snapshot_hub u_snapshot_hub (
        .clk (sys_clk), .rst_n (rst_in), .start (snap_start),
        .s_status (s_status16), .t_status (t_status16),
        .vin_hold (vin_hold), .ddr_hold (ddr_hold),
        .proc_hold (proc_hold), .vout_hold (vout_hold),
        .vin_ack (vin_ack), .ddr_ack (ddr_ack),
        .proc_ack (proc_ack), .vout_ack (vout_ack),
        .req_tgl (snap_req), .words (st_words), .done (snap_done)
    );

    dgc_debug_uart u_debug_uart (
        .clk        (sys_clk),
        .rst_n      (rst_in),
        .words      (st_words),
        .snap_done  (snap_done),
        .snap_start (snap_start),
        .uart_tx    (debug_uart_tx)
    );

    // Heartbeat in the DDR clock domain: blinks when DDR is initialised.
    localparam TH_1S = 27'd33000000;   // not a real 1 s at 125 MHz; bring-up only

    reg [26:0] hb_cnt;
    reg        hb_q;

    always @(posedge ddr_core_clk or negedge ddr_rst_n) begin
        if (!ddr_rst_n) begin
            hb_cnt <= 27'd0;
            hb_q   <= 1'b1;
        end
        else if (!ddr_init_done) begin
            hb_cnt <= 27'd0;
            hb_q   <= 1'b1;
        end
        else if (hb_cnt >= TH_1S) begin
            hb_cnt <= 27'd0;
            hb_q   <= ~hb_q;
        end
        else begin
            hb_cnt <= hb_cnt + 27'd1;
        end
    end

    assign heart_beat_led = hb_q;

    // Status nets kept alive so that PDS does not optimise the S0 counters away
    // and so that S2 can attach them to config_manager without touching the top.
    wire [31:0] s0_status_unused = {vin_frame_cnt[15:0], vin_pixel_cnt[15:0]};

endmodule











