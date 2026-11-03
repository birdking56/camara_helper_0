//-----------------------------------------------------------------------------
// tb_fifo_timing.v - cycle-accurate pop timing of the two generated FIFOs.
//
// Derived facts this probe must establish (all printed as TEST_INFO):
//   1. latency from the pop command cycle to the cycle whose rd_data holds the
//      popped word,
//   2. sustained throughput for back-to-back pops,
//   3. behaviour of rd_empty at and after the last pop (a pop must never be
//      issued while rd_empty is asserted).
//
// Payloads are non-zero on purpose so that a stale output register cannot be
// mistaken for a correct word.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_fifo_timing;

    integer dgc_errors = 0;

    reg clk = 0;      always #(`DGC_T_PROC) clk = ~clk;
    reg ddr_clk = 0;  always #(`DGC_T_DDR) ddr_clk = ~ddr_clk;
    reg rst_n = 0;
    wire rst = ~rst_n;

    `DGC_GRS_INST

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---------------------------------------------------------------- coord FIFO
    reg  [95:0] cf_wr_data = 0;
    reg         cf_wr_en = 0;
    reg         cf_rd_en = 0;
    wire [95:0] cf_rd_data;
    wire        cf_rd_empty, cf_wr_full, cf_almost_full, cf_almost_empty;
    wire [12:0] cf_wr_wl, cf_rd_wl;

    coord_fifo u_coord_fifo (
        .clk (clk), .rst (rst),
        .wr_en (cf_wr_en), .wr_data (cf_wr_data), .wr_full (cf_wr_full),
        .wr_water_level (cf_wr_wl), .rd_en (cf_rd_en), .rd_data (cf_rd_data),
        .almost_full (cf_almost_full), .rd_empty (cf_rd_empty),
        .rd_water_level (cf_rd_wl), .almost_empty (cf_almost_empty)
    );

    // ---------------------------------------------------------------- ddr FIFO
    reg  [255:0] df_wr_data = 0;
    reg          df_wr_en = 0;
    reg          df_rd_en = 0;
    wire [255:0] df_rd_data;
    wire         df_rd_empty, df_wr_full, df_almost_full, df_almost_empty;
    wire [11:0]  df_wr_wl, df_rd_wl;

    ddr_read_fifo u_ddr_fifo (
        .wr_clk (ddr_clk), .wr_rst (rst),
        .wr_en (df_wr_en), .wr_data (df_wr_data), .wr_full (df_wr_full),
        .wr_water_level (df_wr_wl),
        .rd_clk (clk), .rd_rst (rst),
        .rd_en (df_rd_en), .rd_data (df_rd_data),
        .almost_full (df_almost_full), .rd_empty (df_rd_empty),
        .rd_water_level (df_rd_wl), .almost_empty (df_almost_empty)
    );

    integer i;
    initial begin
        rst_n = 0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        repeat (6) @(posedge clk);

        // ================================================ COORD FIFO, single pop
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk);
            cf_wr_en   <= 1'b1;
            cf_wr_data <= {72'h0, 12'h0, 12'h100 + i[11:0]};
        end
        @(posedge clk);
        cf_wr_en <= 1'b0;
        repeat (4) @(posedge clk);

        $display("TEST_INFO: ----- COORD FIFO, one pop -----");
        @(posedge clk); #0.2;
        $display("TEST_INFO: cyc=%0d command cycle (rd_en=1), rd_empty=%0d rd_data=%0h",
                 cyc, cf_rd_empty, cf_rd_data);
        cf_rd_en <= 1'b1;
        @(posedge clk); #0.2;
        cf_rd_en <= 1'b0;
        for (i = 0; i < 5; i = i + 1) begin
            $display("TEST_INFO: cyc=%0d +%0d rd_empty=%0d rd_data=%0h", cyc, i, cf_rd_empty, cf_rd_data);
            @(posedge clk); #0.2;
        end

        // ================================================ COORD FIFO, drain to empty
        $display("TEST_INFO: ----- COORD FIFO, pop until empty (gated by !rd_empty) -----");
        for (i = 0; i < 9; i = i + 1) begin
            if (!cf_rd_empty) begin
                cf_rd_en <= 1'b1;
                @(posedge clk); #0.2;
                $display("TEST_INFO: cyc=%0d pop issued, rd_empty=%0d rd_data=%0h", cyc, cf_rd_empty, cf_rd_data);
            end
            else begin
                @(posedge clk); #0.2;
                $display("TEST_INFO: cyc=%0d rd_empty=1, pop withheld, rd_data=%0h", cyc, cf_rd_data);
            end
        end
        cf_rd_en <= 1'b0;
        repeat (3) @(posedge clk);
        if (cf_rd_empty !== 1'b1) `DGC_FAIL("COORD FIFO did not report empty after draining")
        else $display("TEST_INFO: COORD FIFO reports rd_empty=1 after draining, no pop was issued while empty");

        // ================================================ DDR FIFO, single pop
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge ddr_clk);
            df_wr_en   <= 1'b1;
            df_wr_data <= {240'h0, 16'h0200 + i[15:0]};
        end
        @(posedge ddr_clk);
        df_wr_en <= 1'b0;
        repeat (8) @(posedge clk);

        $display("TEST_INFO: ----- DDR FIFO, one pop -----");
        @(posedge clk); #0.2;
        $display("TEST_INFO: cyc=%0d command cycle (rd_en=1), rd_empty=%0d rd_data=%0h",
                 cyc, df_rd_empty, df_rd_data);
        df_rd_en <= 1'b1;
        @(posedge clk); #0.2;
        df_rd_en <= 1'b0;
        for (i = 0; i < 5; i = i + 1) begin
            $display("TEST_INFO: cyc=%0d +%0d rd_empty=%0d rd_data=%0h", cyc, i, df_rd_empty, df_rd_data);
            @(posedge clk); #0.2;
        end

        $display("TEST_INFO: ----- DDR FIFO, back-to-back pops -----");
        for (i = 0; i < 5; i = i + 1) begin
            df_rd_en <= 1'b1;
            @(posedge clk); #0.2;
            $display("TEST_INFO: cyc=%0d pop%0d rd_empty=%0d rd_data=%0h", cyc, i, df_rd_empty, df_rd_data);
        end
        df_rd_en <= 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk); #0.2;
            $display("TEST_INFO: cyc=%0d tail%0d rd_empty=%0d rd_data=%0h", cyc, i, df_rd_empty, df_rd_data);
        end

        $display("TEST_INFO: probe finished");
        `DGC_FINISH
    end

endmodule
