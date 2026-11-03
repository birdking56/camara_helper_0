//-----------------------------------------------------------------------------
// dgc_clock_reset.v
//
// Clock generation, initialisation gating and per-domain resets for the
// distortion-correction top level.
//
// Clock plan (frozen specification section 2, all derived from the 27 MHz board
// oscillator unless noted):
//   vin_clk      148.5 MHz  from the HDMI receiver       (supplied by the board)
//   ddr_clk      125 MHz    ddr3_test.core_clk           (supplied by the DDR IP)
//   proc_clk     225 MHz    pll_proc.clkout3
//   vout_clk     148.5 MHz  pll_hdmi.clkout2
//   vout_clk_5x  742.5 MHz  pll_hdmi.clkout1
//   cfg_clk       10 MHz    pll_cfg.clkout0
//
// Reset plan
//   * every domain reset is asynchronous-assert / synchronously released by a
//     three-stage dgc_rst_sync (frozen specification section 2);
//   * the configuration domain waits for its own PLL lock AND the vendor demo's
//     1 ms (0x2710 cfg clocks) settle before the HDMI chips are released. The
//     first version released it after only the synchroniser cycles; on the board
//     the MS7210 then NAKed its I2C ID read (T=02FF) and the MS7200 came up
//     unconfigured, which presented as a 132 MHz garbage raster rather than
//     1080p. The demo's exactly verified window is restored here;
//   * the DDR controller is released after all PLLs lock and a 1 ms settling
//     window has elapsed (same 0x2710 count at 10 MHz as the verified baseline);
//   * the processing, output and 5x domains additionally wait for
//     ddr_init_done, so no data task can start before DDR is usable;
//   * any lock loss or DDR re-initialisation re-asserts the data-domain reset
//     asynchronously, which aborts the whole processing session as required by
//     "任一视频处理域丢锁或 DDR 重新初始化时，中止整个处理会话".
//-----------------------------------------------------------------------------

module dgc_clock_reset #(
    // 1 ms at 10 MHz in hardware; overridden by testbenches so that simulation
    // does not have to run a full millisecond with the 742.5 MHz serial clock alive.
    parameter [15:0] SETTLE_CYCLES = 16'h2710,
    // HDMI chip reset width after the cfg PLL locks: same 1 ms window the
    // verified vendor demo uses before releasing rstn_out.
    parameter [15:0] CFG_SETTLE_CYCLES = 16'h2710
) (
    input  wire sys_clk,          // 27 MHz board oscillator
    input  wire rst_in,           // board reset, active high, asynchronous

    input  wire ddr_core_clk,     // ddr3_test.core_clk (125 MHz)
    input  wire ddr_pll_lock,     // ddr3_test.pll_lock
    input  wire ddr_init_done,    // ddr3_test.ddr_init_done

    output wire proc_clk,         // 225 MHz
    output wire cfg_clk,          // 10 MHz
    output wire vout_clk,         // 148.5 MHz
    output wire vout_clk_5x,      // 742.5 MHz

    output wire plls_lock,        // all four PLLs locked
    output wire init_ready,       // 1 ms elapsed after all PLLs locked
    output wire ddr_arst_n,       // asynchronous reset source for ddr3_test.resetn
    output wire data_arst_n,      // asynchronous session-reset source

    // Individual lock bits for the debug UART (U0/U1 observation only).
    output wire pll_proc_lock_o,
    output wire pll_cfg_lock_o,
    output wire pll_hdmi_lock_o,

    output wire cfg_rst_n,
    output wire ddr_rst_n,
    output wire proc_rst_n,
    output wire vout_rst_n,
    output wire vout5x_rst_n
);

    // ---------------------------------------------------------------- PLLs
    wire pll_proc_lock;
    wire pll_cfg_lock;
    wire pll_hdmi_lock;

    pll_proc u_pll_proc (
        .clkout3 (proc_clk),
        .clkin1  (sys_clk),
        .lock    (pll_proc_lock)
    );

    pll_cfg u_pll_cfg (
        .clkout0 (cfg_clk),
        .clkin1  (sys_clk),
        .lock    (pll_cfg_lock)
    );

    pll_hdmi u_pll_hdmi (
        .clkout1 (vout_clk_5x),
        .clkout2 (vout_clk),
        .clkin1  (sys_clk),
        .lock    (pll_hdmi_lock)
    );

    // DDR reset must NOT wait for ddr_pll_lock: the DDR PHY PLL can only lock
    // after its resetn is released, so gating resetn on it is a deadlock. The
    // vendor demo resets DDR after the main PLL + 1 ms only; ddr_init_done is
    // what gates the data domains afterwards.
    wire soc_plls_lock = pll_proc_lock & pll_cfg_lock & pll_hdmi_lock;
    assign plls_lock = soc_plls_lock & ddr_pll_lock;   // status / diagnostics
    assign pll_proc_lock_o = pll_proc_lock;
    assign pll_cfg_lock_o  = pll_cfg_lock;
    assign pll_hdmi_lock_o = pll_hdmi_lock;

    // ---------------------------------------------------------------- resets
    wire clk_arst_n = ~rst_in;

    // ------------------------------------------- configuration / HDMI chips
    // Free-running on the cfg clock (which only exists after its PLL locks), so
    // the counter is independent of the reset it is generating. This is the
    // vendor demo's rstn_1ms logic: 10,000 cfg clocks = 1 ms, then hold.
    reg [15:0] cfg_settle;

    always @(posedge cfg_clk or negedge clk_arst_n) begin
        if (!clk_arst_n)
            cfg_settle <= 16'd0;
        else if (!pll_cfg_lock)
            cfg_settle <= 16'd0;
        else if (cfg_settle != CFG_SETTLE_CYCLES)
            cfg_settle <= cfg_settle + 16'd1;
    end

    wire cfg_ready = (cfg_settle == CFG_SETTLE_CYCLES);

    dgc_rst_sync #(.STAGES(3)) u_rst_cfg (
        .clk         (cfg_clk),
        .rst_async_n (clk_arst_n & pll_cfg_lock & cfg_ready),
        .rst_n       (cfg_rst_n)
    );

    // ------------------------------------------------- 1 ms settling window
    // Counted in the always-available 10 MHz configuration domain so that the
    // window is independent of the PLLs it is gating.
    reg [15:0] settle_cnt;

    always @(posedge cfg_clk or negedge cfg_rst_n) begin
        if (!cfg_rst_n)
            settle_cnt <= 16'd0;
        else if (!soc_plls_lock)
            settle_cnt <= 16'd0;
        else if (settle_cnt != SETTLE_CYCLES)
            settle_cnt <= settle_cnt + 16'd1;
    end

    assign init_ready = (settle_cnt == SETTLE_CYCLES);

    // ------------------------------------------------- initialisation gates
    // The DDR controller is released by lock + settle only; requiring
    // ddr_init_done here would be circular.
    assign ddr_arst_n = clk_arst_n & init_ready;

    // Data domains additionally require a completed DDR initialisation.
    assign data_arst_n = clk_arst_n & init_ready & ddr_init_done;

    // ------------------------------------------------- per-domain release
    dgc_rst_sync #(.STAGES(3)) u_rst_ddr (
        .clk         (ddr_core_clk),
        .rst_async_n (ddr_arst_n),
        .rst_n       (ddr_rst_n)
    );

    dgc_rst_sync #(.STAGES(3)) u_rst_proc (
        .clk         (proc_clk),
        .rst_async_n (data_arst_n),
        .rst_n       (proc_rst_n)
    );

    dgc_rst_sync #(.STAGES(3)) u_rst_vout (
        .clk         (vout_clk),
        .rst_async_n (data_arst_n),
        .rst_n       (vout_rst_n)
    );

    dgc_rst_sync #(.STAGES(3)) u_rst_vout5x (
        .clk         (vout_clk_5x),
        .rst_async_n (data_arst_n),
        .rst_n       (vout5x_rst_n)
    );

endmodule
