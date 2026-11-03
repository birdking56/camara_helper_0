//-----------------------------------------------------------------------------
// tb_sys_compile.v - elaboration / wiring smoke test for dgc_core_sys
//
// It drives idle inputs for a few thousand cycles in every clock domain and
// checks that nothing turns into X on the control paths. The functional
// end-to-end run is sim/s5_sys.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_sys_compile;
    integer dgc_errors = 0;

    reg vin_clk = 0;  always #(`DGC_T_VIN) vin_clk = ~vin_clk;
    reg ddr_clk = 0;  always #(`DGC_T_DDR) ddr_clk = ~ddr_clk;
    reg proc_clk = 0; always #(`DGC_T_PROC) proc_clk = ~proc_clk;
    reg vout_clk = 0; always #(`DGC_T_VOUT) vout_clk = ~vout_clk;

    reg rst_n = 0;
    `DGC_GRS_INST

    reg  vs_in = 0, hs_in = 0, de_in = 0;
    reg  [23:0] rgb_in = 0;

    wire [27:0] awaddr; wire [3:0] awlen; wire awvalid;
    wire [255:0] wdata; wire [31:0] wstrb;
    wire [27:0] araddr; wire [3:0] arlen; wire arvalid;
    reg  [255:0] rdata = 0; reg rvalid = 0, rlast = 0; reg [3:0] rid = 0;

    reg  [11:0] x_tg = 0, y_tg = 0;
    wire [23:0] rgb_out; wire de_out, hs_out, vs_out;
    wire [31:0] st_wr, st_proc, st_uf, st_drop, st_err;
    wire frame_black;

    dgc_core_sys u_sys (
        .vin_clk (vin_clk), .vin_rst_n (rst_n),
        .ddr_clk (ddr_clk), .ddr_rst_n (rst_n),
        .proc_clk (proc_clk), .proc_rst_n (rst_n),
        .vout_clk (vout_clk), .vout_rst_n (rst_n),
        .vs_in (vs_in), .hs_in (hs_in), .de_in (de_in), .rgb_in (rgb_in),
        .axi_awaddr (awaddr), .axi_awlen (awlen), .axi_awvalid (awvalid),
        .axi_awready (1'b1),
        .axi_wdata (wdata), .axi_wstrb (wstrb), .axi_wready (1'b1),
        .axi_wusero_id (4'd0), .axi_wusero_last (1'b0),
        .axi_araddr (araddr), .axi_arlen (arlen), .axi_arvalid (arvalid),
        .axi_arready (1'b1),
        .axi_rdata (rdata), .axi_rvalid (rvalid), .axi_rlast (rlast), .axi_rid (rid),
        .cfg_mode (2'd0),
        .cfg_m00 (32'sd67108864), .cfg_m01 (32'sd0), .cfg_m02 (32'sd0),
        .cfg_m10 (32'sd0), .cfg_m11 (32'sd67108864), .cfg_m12 (32'sd0),
        .cfg_fx (32'sd137377855), .cfg_fy (32'sd138692973),
        .cfg_cx (32'sd64030536), .cfg_cy (32'sd34085643),
        .cfg_k1 (-32'sd129279204), .cfg_k2 (32'sd74679738),
        .cfg_norm_abs_max (32'h08000000), .gamma_mode (2'd0),
        .de_tg (de_in), .hs_tg (hs_in), .vs_tg (vs_in),
        .x_tg (x_tg), .y_tg (y_tg),
        .rgb_out (rgb_out), .de_out (de_out), .hs_out (hs_out), .vs_out (vs_out),
        .stat_frames_written (st_wr), .stat_frames_processed (st_proc),
        .stat_stripes_underflow (st_uf), .stat_frames_dropped (st_drop),
        .stat_ddr_errors (st_err), .frame_black (frame_black)
    );

    integer i;
    initial begin
        rst_n = 0;
        repeat (20) @(posedge proc_clk);
        rst_n = 1;
        for (i = 0; i < 4000; i = i + 1) @(posedge proc_clk);

        if (((^st_wr) === 1'bx) || ((^st_proc) === 1'bx) || ((^st_uf) === 1'bx) ||
            ((^st_drop) === 1'bx) || ((^st_err) === 1'bx) || (de_out === 1'bx) ||
            (hs_out === 1'bx) || (vs_out === 1'bx) || (frame_black === 1'bx)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: an X reached the status/control outputs");
        end
        else $display("TEST_INFO: all four domains elaborated; status outputs are clean after %0d proc cycles", 4000);
        `DGC_FINISH
    end
endmodule
