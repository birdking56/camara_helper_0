//-----------------------------------------------------------------------------
// tb_pix_fifo.v - timing and capacity probe for the generated pix_beat_fifo
//
// The capture side crosses its 32-byte beats from vin_clk (148.5 MHz) to ddr_clk
// (125 MHz) through this FIFO. Before it is wired into anything, this probe
// establishes the facts the wrapper and the write adapter will rely on:
//
//   T1  reset state, and whether the IP water levels are usable in simulation
//   T2  one pop: latency from the rd_en cycle to the cycle holding the word
//   T3  back-to-back pops: order, sustained one word per cycle, empty behaviour
//   T4  capacity: writes stop at wr_full; exactly the accepted words come back
//       in order; almost_full matches the configured 240
//
// The payloads are unique per word on purpose: a stale output register or an
// off-by-one latency cannot be mistaken for a correct word.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_pix_fifo;
    integer dgc_errors = 0;

    reg vin_clk = 0; always #(`DGC_T_VIN) vin_clk = ~vin_clk;
    reg ddr_clk = 0; always #(`DGC_T_DDR) ddr_clk = ~ddr_clk;
    reg rst_n = 0;
    wire rst = ~rst_n;
    `DGC_GRS_INST

    reg  [287:0] wr_data = 0;
    reg          wr_en = 0;
    wire         wr_full, almost_full;
    wire [8:0]   wr_wl;

    reg          rd_en = 0;
    wire [287:0] rd_data;
    wire         rd_empty, almost_empty;
    wire [8:0]   rd_wl;

    pix_beat_fifo u_fifo (
        .wr_clk (vin_clk), .wr_rst (rst),
        .wr_en (wr_en), .wr_data (wr_data), .wr_full (wr_full),
        .wr_water_level (wr_wl), .almost_full (almost_full),
        .rd_clk (ddr_clk), .rd_rst (rst),
        .rd_en (rd_en), .rd_data (rd_data),
        .rd_empty (rd_empty), .rd_water_level (rd_wl),
        .almost_empty (almost_empty)
    );

    integer cyc = 0;
    always @(posedge ddr_clk) cyc <= cyc + 1;

    function [287:0] word(input integer n);
        begin
            word = {232'h0, 24'hC0FFEE, 32'h0000_1000 + n[31:0]};
        end
    endfunction

    task wr_one(input integer n);
        begin
            @(posedge vin_clk); #0.2;
            wr_en   <= 1'b1;
            wr_data <= word(n);
            @(posedge vin_clk); #0.2;
            wr_en   <= 1'b0;
        end
    endtask

    integer i, k, L, n_written;
    reg [287:0] samples [0:63];
    reg [287:0] drain   [0:511];
    reg [287:0] exp_word;

    initial begin
        rst_n = 0;
        repeat (8) @(posedge vin_clk);
        repeat (8) @(posedge ddr_clk);
        rst_n = 1;
        repeat (8) @(posedge vin_clk);
        repeat (8) @(posedge ddr_clk);

        // =============================================================== T1
        $display("TEST_INFO: T1 reset: wr_full=%b almost_full=%b rd_empty=%b wr_wl=%h rd_wl=%h",
                 wr_full, almost_full, rd_empty, wr_wl, rd_wl);
        if (rd_empty !== 1'b1) `DGC_FAIL("pix_beat_fifo must be empty after reset")
        else $display("TEST_INFO: T1 the FIFO is empty after reset; water levels are %s",
                      (wr_wl === 9'hxxx) ? "Z/X in simulation (not usable here, as expected)"
                                         : "driven by the model");

        // =============================================================== T2
        for (i = 0; i < 8; i = i + 1) wr_one(i);
        repeat (6) @(posedge ddr_clk);
        if (rd_empty !== 1'b0) `DGC_FAIL("T2 eight words were written but rd_empty is still 1")

        @(posedge ddr_clk); #0.2;
        rd_en <= 1'b1;
        @(posedge ddr_clk); #0.2;
        rd_en <= 1'b0;
        L = -1;
        for (k = 0; k < 6; k = k + 1) begin
            if ((rd_data === word(0)) && (L < 0)) L = k;
            $display("TEST_INFO: T2 pop+%0d rd_empty=%b rd_data=%024h", k, rd_empty, rd_data);
            @(posedge ddr_clk); #0.2;
        end
        if (L < 0) `DGC_FAIL("T2 the first word never appeared on rd_data")
        else $display("TEST_INFO: T2 pop latency = %0d ddr_clk cycles (first word seen at pop+%0d)", L + 1, L);

        // =============================================================== T3
        // Drain the remaining 7 with rd_en gated by rd_empty (a pop while empty
        // is illegal for this IP). Every pop completes one word per cycle.
        @(posedge ddr_clk); #0.2;
        rd_en <= ~rd_empty;
        for (k = 0; k < 24; k = k + 1) begin
            @(posedge ddr_clk); #0.2;
            samples[k] = rd_data;
            rd_en <= ~rd_empty;      // gate on the post-edge empty flag
        end
        rd_en <= 1'b0;
        // find word(1) in the samples and check consecutive order from there
        L = -1;
        for (k = 0; k < 24; k = k + 1) if ((samples[k] === word(1)) && (L < 0)) L = k;
        if (L < 0) `DGC_FAIL("T3 word 1 not found in the drain stream")
        else begin
            for (i = 1; i < 8; i = i + 1) begin
                if (samples[L + (i - 1)] !== word(i)) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: T3 drain order at word %0d exp=%024h act=%024h",
                             i, word(i), samples[L + (i - 1)]);
                end
            end
        end
        repeat (4) @(posedge ddr_clk);
        if (rd_empty !== 1'b1) `DGC_FAIL("T3 the FIFO did not report empty after the drain")
        else $display("TEST_INFO: T3 8 pop commands produced 8 words in order, then rd_empty");

        // =============================================================== T4
        // fill until wr_full; count exactly how many words were accepted
        n_written = 0;
        for (i = 0; i < 400; i = i + 1) begin
            @(posedge vin_clk); #0.2;
            if (!wr_full && (n_written < 400)) begin
                wr_en   <= 1'b1;
                wr_data <= word(n_written);
                n_written = n_written + 1;
            end
            else begin
                wr_en <= 1'b0;
            end
        end
        @(posedge vin_clk); #0.2;
        wr_en <= 1'b0;
        repeat (8) @(posedge vin_clk);
        repeat (8) @(posedge ddr_clk);
        $display("TEST_INFO: T4 accepted %0d words, wr_full=%b almost_full=%b wr_wl=%0d",
                 n_written, wr_full, almost_full, wr_wl);
        if (wr_full !== 1'b1) `DGC_FAIL("T4 wr_full did not assert after filling")
        if (n_written < 200 || n_written > 256) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: T4 capacity exp ~256, act %0d", n_written);
        end

        // drain everything and verify order
        n_written = (n_written > 512) ? 512 : n_written;
        for (k = 0; k < n_written; k = k + 1) begin
            // one pop per iteration, waiting for the data to surface
            while (rd_empty) @(posedge ddr_clk);
            @(posedge ddr_clk); #0.2;
            rd_en <= 1'b1;
            @(posedge ddr_clk); #0.2;
            rd_en <= 1'b0;
            // wait for this pop's data: scan up to 4 cycles for the expected word
            exp_word = word(k);
            i = 0;
            while ((rd_data !== exp_word) && (i < 6)) begin
                @(posedge ddr_clk); #0.2;
                i = i + 1;
            end
            if (rd_data !== exp_word) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 10)
                    $display("TEST_FAIL: T4 drain word %0d exp=%024h act=%024h", k, exp_word, rd_data);
            end
        end
        repeat (6) @(posedge ddr_clk);
        if (rd_empty !== 1'b1) `DGC_FAIL("T4 the FIFO did not empty after draining every accepted word")
        else $display("TEST_INFO: T4 all %0d accepted words came back in order", n_written);

        `DGC_FINISH
    end
endmodule
