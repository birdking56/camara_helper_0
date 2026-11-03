//-----------------------------------------------------------------------------
// dgc_top.v
//
// Business top level for the HDMI-in / HDMI-out distortion-correction system.
//
// S0 scope (see docs/interface_v1/项目结构报告.md section 7):
//   * real board pinout, identical to the verified baseline;
//   * all six clock domains generated and reset per the frozen specification;
//   * the localised DDR3 IP instantiated as u_ddr3_test_h with its native
//     simplified-AXI user port brought out to top-level nets;
//   * HDMI receiver/transmitter chip configuration, 1080p60 output timing and
//     TMDS serialisers reused unchanged;
//   * a live S0 test pattern on the output so that the board can be brought up
//     and the clock/reset/TMDS path proven before any algorithm exists.
//
// Explicitly NOT implemented at S0 (must not be claimed as done):
//   * capture_writer / frame_manager / ddr_fetch (S2),
//   * map_pipeline (S1), source cache and sampler (S2), bilinear (S3),
//   * tile_scheduler / stripe_writer / video_reader (S4).
//
// The DDR native user port is therefore tied idle at S0. Exactly one module may
// drive it; that module will be ddr_fetch / capture_writer at S2. The tie-off is
// isolated in one clearly marked block so it cannot be forgotten.
//-----------------------------------------------------------------------------

module dgc_top #(
    parameter MEM_ROW_ADDR_WIDTH = 15,
    parameter MEM_COL_ADDR_WIDTH = 10,
    parameter MEM_BADDR_WIDTH    = 3,
    parameter MEM_DQ_WIDTH       = 32,
    parameter MEM_DQS_WIDTH      = 32 / 8,
    parameter [15:0] SETTLE_CYCLES = 16'h2710   // 1 ms at 10 MHz; overridden in simulation
) (
    input  wire                              sys_clk,          // 27 MHz
    input  wire                              clk_p,            // 125 MHz DDR ref
    input  wire                              clk_n,
    input  wire                              rst_in,           // board reset, active high

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
    output wire                              ddr_init_done_o
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

    dgc_clock_reset #(.SETTLE_CYCLES (SETTLE_CYCLES)) u_clock_reset (
        .sys_clk        (sys_clk),
        .rst_in         (rst_in),
        .ddr_core_clk   (ddr_core_clk),
        .ddr_pll_lock   (ddr_pll_lock),
        .ddr_init_done  (ddr_init_done),
        .proc_clk       (proc_clk),
        .cfg_clk        (cfg_clk),
        .vout_clk       (vout_clk),
        .vout_clk_5x    (vout_clk_5x),
        .plls_lock      (plls_lock),
        .init_ready     (init_ready),
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

    ms72xx_ctl u_ms72xx_ctl (
        .clk          (cfg_clk),
        .rst_n        (cfg_rst_n),
        .init_over_rx (hdmi_rx_cfg_done),
        .init_over    (hdmi_cfg_done),
        .iic_scl      (hd_scl),
        .iic_sda      (hd_sda)
    );

    assign rstn_out     = cfg_rst_n;
    assign hdmi_int_led = hdmi_cfg_done;

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

    // ------------------------------------------------------------------------
    // S0 DDR native port tie-off.
    //
    // At S0 there is no capture_writer and no ddr_fetch, so the native user
    // port must be parked. Both directions are quiescent and no beat can be
    // dropped: with arvalid/awvalid permanently low the controller never
    // returns read data, so the "no rready" hazard cannot occur.
    //
    // S2 REPLACES THIS ENTIRE BLOCK with capture_writer (write side) and
    // ddr_fetch (read side). Do not leave both drivers in place: the frozen
    // specification allows exactly one module to drive the DDR read channel.
    // ------------------------------------------------------------------------
    assign axi_awaddr    = {CTRL_ADDR_WIDTH{1'b0}};
    assign axi_awuser_ap = 1'b0;
    assign axi_awuser_id = 4'd0;
    assign axi_awlen     = 4'd0;
    assign axi_awvalid   = 1'b0;
    assign axi_wdata     = {(MEM_DQ_WIDTH*8){1'b0}};
    assign axi_wstrb     = {MEM_DQ_WIDTH{1'b0}};
    assign axi_araddr    = {CTRL_ADDR_WIDTH{1'b0}};
    assign axi_aruser_ap = 1'b0;
    assign axi_aruser_id = 4'd0;
    assign axi_arlen     = 4'd0;
    assign axi_arvalid   = 1'b0;
    // ------------------------------------------------------------------------

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

    wire [23:0] pattern_rgb;

    dgc_s0_pattern u_s0_pattern (
        .clk   (vout_clk),
        .rst_n (vout_rst_n),
        .de    (de_o),
        .x     (x_o),
        .y     (y_o),
        .vs    (vs_o),
        .rgb   (pattern_rgb)
    );

    // One register stage aligns the pattern with the registered DE that the
    // TMDS encoder samples, keeping RGB/DE/HS/VS on the same scan position.
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
            de_o_r <= de_o;
            hs_o_r <= hs_o;
            vs_o_r <= vs_o;
            rgb_o_r <= pattern_rgb;
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
