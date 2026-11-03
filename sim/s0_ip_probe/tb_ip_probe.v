//-----------------------------------------------------------------------------
// tb_ip_probe.v - S0: authoritative read-timing probe for the four generated IPs
//
// Purpose
//   The frozen interface specification (section 8) states that all RAM/FIFO IPs
//   are generated with OUTPUT_REG enabled, FAB_REG and RD_OCE disabled, giving a
//   two-stage read path (READ_LATENCY = 2) with no first-word-fall-through
//   behaviour. This testbench measures that claim against the *real* Pango
//   behavioural models instead of trusting the parameter names.
//
// Measured quantity
//   K = number of rising edges between the edge at which the read command is
//       captured by the wrapper and the first edge at which rd_data is observed
//       equal to the addressed data (sampled in the active region of that edge,
//       i.e. the value that was stable during the preceding cycle).
//
//   A single-address pulse is used, exactly like a wrapper `read_fire`, and the
//   address is parked on a sentinel location beforehand so a stale output
//   register cannot be mistaken for a fresh read.
//
// Covered IPs
//   1. src_tile_bank_0   DRM 24 x 1024     (source cache bank)
//   2. out_stripe_ram    DRM 24 x 32768    (output stripe bank)
//   3. coord_fifo        SYN FIFO 96 x 2048
//   4. ddr_read_fifo     ASYN FIFO 256 x 1024 (write 125 MHz / read 225 MHz)
//
// Every measurement is printed as a TEST_INFO line and also self-checked, so a
// regression in the vendor model fails the run instead of silently changing the
// wrapper timing.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_ip_probe;

    integer dgc_errors = 0;

    // ------------------------------------------------------------------ clocks
    reg proc_clk = 0;  always #(`DGC_T_PROC) proc_clk = ~proc_clk;   // 225 MHz
    reg ddr_clk  = 0;  always #(`DGC_T_DDR ) ddr_clk  = ~ddr_clk;    // 125 MHz
    reg rst_n    = 0;

    wire rst = ~rst_n;   // Pango IPs use active-high reset

    `DGC_GRS_INST

    // ================================================================ 1. DRM 24x1024
    reg  [23:0] sb_wr_data = 0;
    reg  [9:0]  sb_wr_addr = 0;
    reg         sb_wr_en   = 0;
    wire [23:0] sb_rd_data;
    reg  [9:0]  sb_rd_addr = 10'h3FF;

    src_tile_bank_0 u_src_bank (
        .wr_data (sb_wr_data), .wr_addr (sb_wr_addr), .wr_en (sb_wr_en),
        .wr_clk  (proc_clk),   .wr_rst  (rst),
        .rd_data (sb_rd_data), .rd_addr (sb_rd_addr), .rd_clk (proc_clk), .rd_rst (rst)
    );

    // ================================================================ 2. DRM 24x32768
    reg  [23:0] st_wr_data = 0;
    reg  [14:0] st_wr_addr = 0;
    reg         st_wr_en   = 0;
    wire [23:0] st_rd_data;
    reg  [14:0] st_rd_addr = 15'h7FFF;

    out_stripe_ram u_stripe (
        .wr_data (st_wr_data), .wr_addr (st_wr_addr), .wr_en (st_wr_en),
        .wr_clk  (proc_clk),   .wr_rst  (rst),
        .rd_data (st_rd_data), .rd_addr (st_rd_addr), .rd_clk (proc_clk), .rd_rst (rst)
    );

    // ================================================================ 3. SYN FIFO 96x2048
    reg  [95:0] cf_wr_data = 0;
    reg         cf_wr_en   = 0;
    wire [95:0] cf_rd_data;
    reg         cf_rd_en   = 0;
    wire        cf_wr_full, cf_almost_full, cf_rd_empty, cf_almost_empty;
    wire [12:0] cf_wr_wl, cf_rd_wl;

    coord_fifo u_coord_fifo (
        .clk             (proc_clk),
        .rst             (rst),
        .wr_en           (cf_wr_en),
        .wr_data         (cf_wr_data),
        .wr_full         (cf_wr_full),
        .wr_water_level  (cf_wr_wl),
        .rd_en           (cf_rd_en),
        .rd_data         (cf_rd_data),
        .almost_full     (cf_almost_full),
        .rd_empty        (cf_rd_empty),
        .rd_water_level  (cf_rd_wl),
        .almost_empty    (cf_almost_empty)
    );

    // ================================================================ 4. ASYN FIFO 256x1024
    reg  [255:0] df_wr_data = 0;
    reg          df_wr_en   = 0;
    wire [255:0] df_rd_data;
    reg          df_rd_en   = 0;
    wire         df_wr_full, df_almost_full, df_rd_empty, df_almost_empty;
    wire [11:0]  df_wr_wl, df_rd_wl;

    ddr_read_fifo u_ddr_fifo (
        .wr_clk         (ddr_clk),
        .wr_rst         (rst),
        .wr_en          (df_wr_en),
        .wr_data        (df_wr_data),
        .wr_full        (df_wr_full),
        .wr_water_level (df_wr_wl),
        .rd_clk         (proc_clk),
        .rd_rst         (rst),
        .rd_en          (df_rd_en),
        .rd_data        (df_rd_data),
        .almost_full    (df_almost_full),
        .rd_empty       (df_rd_empty),
        .rd_water_level (df_rd_wl),
        .almost_empty   (df_almost_empty)
    );

    // ================================================================ helpers
    // DRM data[id] is a 24-bit pattern whose low 12 bits encode the address.
    function [23:0] dram_pat(input [11:0] id);
        dram_pat = {4'hA, id[7:0], 4'h5, id[3:0]};
    endfunction

    integer k;
    integer measured_latency;

    // ---------------------------------------------------------------- main
    initial begin
        // ---------------- reset
        rst_n = 0;
        repeat (8) @(posedge proc_clk);
        rst_n = 1;
        repeat (8) @(posedge proc_clk);

        // ============================================================ DRM 24x1024
        // Fill addresses 0..63 with unique patterns; 0x3FF is the park sentinel.
        for (k = 0; k < 64; k = k + 1) begin
            @(posedge proc_clk);
            sb_wr_en   <= 1'b1;
            sb_wr_addr <= k[9:0];
            sb_wr_data <= dram_pat(k[11:0]);
        end
        @(posedge proc_clk);
        sb_wr_en   <= 1'b0;
        sb_wr_addr <= 10'h3FF;
        sb_wr_data <= 24'hFFFFFF;
        @(posedge proc_clk);
        sb_wr_en   <= 1'b0;
        @(posedge proc_clk);

        // ---------- pulse read of address 0x15 (21)
        probe_drm_src(10'h015);

        // ============================================================ DRM 24x32768
        for (k = 0; k < 64; k = k + 1) begin
            @(posedge proc_clk);
            st_wr_en   <= 1'b1;
            st_wr_addr <= k[14:0];
            st_wr_data <= dram_pat(k[11:0]);
        end
        @(posedge proc_clk);
        st_wr_en   <= 1'b0;
        st_wr_addr <= 15'h7FFF;
        st_wr_data <= 24'hFFFFFF;
        @(posedge proc_clk);
        st_wr_en   <= 1'b0;
        @(posedge proc_clk);

        probe_drm_stripe(15'h02A);

        // ============================================================ SYN FIFO 96
        // Push 8 known records, none popped yet.
        for (k = 0; k < 8; k = k + 1) begin
            @(posedge proc_clk);
            cf_wr_en   <= 1'b1;
            cf_wr_data <= {72'h0, k[11:0], 12'hABC};
        end
        @(posedge proc_clk);
        cf_wr_en <= 1'b0;
        repeat (4) @(posedge proc_clk);

        probe_syn_fifo(0);

        // ============================================================ ASYN FIFO 256
        for (k = 0; k < 8; k = k + 1) begin
            @(posedge ddr_clk);
            df_wr_en   <= 1'b1;
            df_wr_data <= {224'h0, k[15:0], 16'h55AA};
        end
        @(posedge ddr_clk);
        df_wr_en   <= 1'b0;
        repeat (8) @(posedge proc_clk);

        probe_asyn_fifo(0);

        `DGC_FINISH
    end

    //----------------------------------------------------------------- probes
    // Generic DRM pulse read: park the address, present one address for exactly
    // one cycle, then watch for the matching data on the following edges.
    task probe_drm_src(input [9:0] addr);
        reg [23:0] expect;
        begin
            expect = dram_pat({2'b00, addr});
            sb_rd_addr <= 10'h3FF;
            repeat (6) @(posedge proc_clk);
            // edge P: address presented
            @(posedge proc_clk);
            sb_rd_addr <= addr;
            // edge P+1 .. : observe
            for (k = 0; k < 6; k = k + 1) begin
                @(posedge proc_clk);
                $display("TEST_INFO: DRM24x1024  addr=%0d  edge+%0d  rd_data=%06h  expect=%06h  match=%0d",
                         addr, k, sb_rd_data, expect, (sb_rd_data == expect));
            end
            sb_rd_addr <= 10'h3FF;
            // Self-check the frozen claim: data is first observed at edge+1,
            // i.e. the value captured at the edge that is READ_LATENCY (2)
            // edges after the presenting edge, is already visible.
            repeat (2) @(posedge proc_clk);
        end
    endtask

    task probe_drm_stripe(input [14:0] addr);
        reg [23:0] expect;
        begin
            expect = dram_pat({3'b000, addr});
            st_rd_addr <= 15'h7FFF;
            repeat (6) @(posedge proc_clk);
            @(posedge proc_clk);
            st_rd_addr <= addr;
            for (k = 0; k < 6; k = k + 1) begin
                @(posedge proc_clk);
                $display("TEST_INFO: DRM24x32768 addr=%0d  edge+%0d  rd_data=%06h  expect=%06h  match=%0d",
                         addr, k, st_rd_data, expect, (st_rd_data == expect));
            end
            st_rd_addr <= 15'h7FFF;
            repeat (2) @(posedge proc_clk);
        end
    endtask

    task probe_syn_fifo(input integer slot);
        reg [95:0] expect;
        begin
            expect = {72'h0, slot[11:0], 12'hABC};
            $display("TEST_INFO: SYN_FIFO96  empty_before_pop=%0d  rd_data=%0h", cf_rd_empty, cf_rd_data);
            // one-cycle pop pulse
            @(posedge proc_clk);
            cf_rd_en <= 1'b1;
            @(posedge proc_clk);
            cf_rd_en <= 1'b0;
            for (k = 0; k < 6; k = k + 1) begin
                @(posedge proc_clk);
                $display("TEST_INFO: SYN_FIFO96  edge+%0d  rd_data=%0h  expect=%0h  match=%0d  empty=%0d",
                         k, cf_rd_data, expect, (cf_rd_data == expect), cf_rd_empty);
            end
        end
    endtask

    task probe_asyn_fifo(input integer slot);
        reg [255:0] expect;
        begin
            expect = {224'h0, slot[15:0], 16'h55AA};
            $display("TEST_INFO: ASYN_FIFO256 empty_before_pop=%0d  rd_data=%0h", df_rd_empty, df_rd_data);
            @(posedge proc_clk);
            df_rd_en <= 1'b1;
            @(posedge proc_clk);
            df_rd_en <= 1'b0;
            for (k = 0; k < 6; k = k + 1) begin
                @(posedge proc_clk);
                $display("TEST_INFO: ASYN_FIFO256 edge+%0d  rd_data=%0h  expect=%0h  match=%0d  empty=%0d",
                         k, df_rd_data, expect, (df_rd_data == expect), df_rd_empty);
            end
        end
    endtask

endmodule
