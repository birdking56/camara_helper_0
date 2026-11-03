//-----------------------------------------------------------------------------
// ddr3_test_sim_stub.v  --  SIMULATION ONLY, NEVER SYNTHESISED
//
// Why this file exists
//   The real DDR3 PHY under ipcore/ddr3_test/rtl is delivered as IEEE-1735
//   encrypted `.vp` sources protected with Pango's RSA key. This Questa 10.6c
//   installation has no Pango decryption key, so vlog reports
//   "syntax error in protected region" and the IP cannot be elaborated.
//   PDS has the key and synthesises the real IP; the simulation hierarchy needs
//   a stand-in that keeps the *exact* port list so that dgc_top's instantiation
//   is still fully checked.
//
// What it models
//   * core_clk           125 MHz, generated locally
//   * pll_lock           asserted after 60 core clocks
//   * ddr_init_done      asserted after 400 core clocks (and whenever
//                        ddr_init_hold_n is high)
//   * all AXI channels   quiescent: no ready, no read data. At S0 the top parks
//                        the native port, so nothing can be lost.
//
// It does NOT model DDR3 behaviour. DDR3 initialisation and native read/write
// transactions must be verified at S2 on a machine that can decrypt the IP, or
// with the vendor's own example simulation.
//-----------------------------------------------------------------------------

module ddr3_test #(
    // Parameters identical to the real IP so that dgc_top overrides resolve.
    parameter MEM_ROW_WIDTH    = 15,
    parameter MEM_COLUMN_WIDTH = 10,
    parameter MEM_BANK_WIDTH   = 3,
    parameter MEM_DQ_WIDTH     = 32,
    parameter MEM_DM_WIDTH     = 4,
    parameter MEM_DQS_WIDTH    = 4,
    parameter CTRL_ADDR_WIDTH  = 28
) (
    input  wire         ref_clk,
    input  wire         resetn,
    output wire         core_clk,
    output wire         pll_lock,
    output wire         phy_pll_lock,
    output wire         gpll_lock,
    output wire         rst_gpll_lock,
    output wire         ddrphy_cpd_lock,
    output wire         ddr_init_done,

    input  wire [27:0]  axi_awaddr,
    input  wire         axi_awuser_ap,
    input  wire [3:0]   axi_awuser_id,
    input  wire [3:0]   axi_awlen,
    output wire         axi_awready,
    input  wire         axi_awvalid,
    input  wire [255:0] axi_wdata,
    input  wire [31:0]  axi_wstrb,
    output wire         axi_wready,
    output wire [3:0]   axi_wusero_id,
    output wire         axi_wusero_last,
    input  wire [27:0]  axi_araddr,
    input  wire         axi_aruser_ap,
    input  wire [3:0]   axi_aruser_id,
    input  wire [3:0]   axi_arlen,
    output wire         axi_arready,
    input  wire         axi_arvalid,
    output wire [255:0] axi_rdata,
    output wire [3:0]   axi_rid,
    output wire         axi_rlast,
    output wire         axi_rvalid,

    input  wire         apb_clk,
    input  wire         apb_rst_n,
    input  wire         apb_sel,
    input  wire         apb_enable,
    input  wire [7:0]   apb_addr,
    input  wire         apb_write,
    output wire         apb_ready,
    input  wire [15:0]  apb_wdata,
    output wire [15:0]  apb_rdata,

    output wire         mem_cs_n,
    output wire         mem_rst_n,
    output wire         mem_ck,
    output wire         mem_ck_n,
    output wire         mem_cke,
    output wire         mem_ras_n,
    output wire         mem_cas_n,
    output wire         mem_we_n,
    output wire         mem_odt,
    output wire [14:0]  mem_a,
    output wire [2:0]   mem_ba,
    inout  wire [3:0]   mem_dqs,
    inout  wire [3:0]   mem_dqs_n,
    inout  wire [31:0]  mem_dq,
    output wire [3:0]   mem_dm,

    input  wire         dbg_gate_start,
    input  wire         dbg_cpd_start,
    input  wire         dbg_ddrphy_rst_n,
    input  wire         dbg_gpll_scan_rst,
    input  wire         samp_position_dyn_adj,
    input  wire [31:0]  init_samp_position_even,
    input  wire [31:0]  init_samp_position_odd,
    input  wire         wrcal_position_dyn_adj,
    input  wire [31:0]  init_wrcal_position,
    input  wire         force_read_clk_ctrl,
    input  wire [15:0]  init_slip_step,
    input  wire [11:0]  init_read_clk_ctrl,
    output wire [33:0]  debug_calib_ctrl,
    output wire [67:0]  dbg_slice_status,
    output wire [87:0]  dbg_slice_state,
    output wire [275:0] debug_data,
    output wire [1:0]   dbg_dll_upd_state,
    output wire [8:0]   debug_gpll_dps_phase,
    output wire [2:0]   dbg_rst_dps_state,
    output wire [5:0]   dbg_tran_err_rst_cnt,
    output wire         dbg_ddrphy_init_fail,
    input  wire         debug_cpd_offset_adj,
    input  wire         debug_cpd_offset_dir,
    input  wire [9:0]   debug_cpd_offset,
    output wire [9:0]   debug_dps_cnt_dir0,
    output wire [9:0]   debug_dps_cnt_dir1,
    input  wire         force_ck_dly_en,
    input  wire [7:0]   force_ck_dly_set_bin,
    output wire [7:0]   ck_dly_set_bin,
    output wire         align_error,
    output wire [3:0]   debug_rst_state,
    output wire [3:0]   debug_cpd_state
);

    reg     core      = 1'b0;
    always #4.0 core = ~core;                 // 125 MHz

    reg     lock_r    = 1'b0;
    reg     init_r    = 1'b0;
    integer core_cnt  = 0;

    always @(posedge core) begin
        core_cnt <= core_cnt + 1;
        if (core_cnt == 60)  lock_r <= 1'b1;
        if (core_cnt == 400) init_r <= 1'b1;
    end

    assign core_clk        = core;
    assign pll_lock        = lock_r;
    assign phy_pll_lock    = lock_r;
    assign gpll_lock       = lock_r;
    assign rst_gpll_lock   = lock_r;
    assign ddrphy_cpd_lock = lock_r;
    assign ddr_init_done   = init_r;

    // -------- native user port: quiescent, nothing is ever accepted ----------
    assign axi_awready = 1'b0;
    assign axi_wready  = 1'b0;
    assign axi_arready = 1'b0;
    assign axi_rdata   = 256'd0;
    assign axi_rid     = 4'd0;
    assign axi_rlast   = 1'b0;
    assign axi_rvalid  = 1'b0;
    assign axi_wusero_id   = 4'd0;
    assign axi_wusero_last = 1'b0;
    assign apb_ready = 1'b1;
    assign apb_rdata = 16'd0;

    // -------- DRAM pins: idle -------------------------------------------------
    assign mem_cs_n  = 1'b1;
    assign mem_rst_n = 1'b1;
    assign mem_ck    = 1'b0;
    assign mem_ck_n  = 1'b1;
    assign mem_cke   = 1'b0;
    assign mem_ras_n = 1'b1;
    assign mem_cas_n = 1'b1;
    assign mem_we_n  = 1'b1;
    assign mem_odt   = 1'b0;
    assign mem_a     = 15'd0;
    assign mem_ba    = 3'd0;
    assign mem_dm    = 4'd0;

    // -------- debug ports -----------------------------------------------------
    assign debug_calib_ctrl     = 34'd0;
    assign dbg_slice_status     = 68'd0;
    assign dbg_slice_state      = 88'd0;
    assign debug_data           = 276'd0;
    assign dbg_dll_upd_state    = 2'd0;
    assign debug_gpll_dps_phase = 9'd0;
    assign dbg_rst_dps_state    = 3'd0;
    assign dbg_tran_err_rst_cnt = 6'd0;
    assign dbg_ddrphy_init_fail = 1'b0;
    assign debug_dps_cnt_dir0   = 10'd0;
    assign debug_dps_cnt_dir1   = 10'd0;
    assign ck_dly_set_bin       = 8'd0;
    assign align_error          = 1'b0;
    assign debug_rst_state      = 4'd0;
    assign debug_cpd_state      = 4'd0;

endmodule
