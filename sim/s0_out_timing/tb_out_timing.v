//-----------------------------------------------------------------------------
// tb_out_timing.v - S0 acceptance: 1080p60 output timing generator
//
// sync_vg is the frozen, reused output timing block. This test pins down the
// numbers the pipeline will be scheduled against:
//
//   H_TOTAL = 2200, H_SYNC = 44, H_BP = 148, H_FP = 88, H_ACT = 1920
//   V_TOTAL = 1125, V_SYNC = 5,  V_BP = 36,  V_FP = 4,  V_ACT = 1080
//
// Checks
//   O1  line period is exactly 2200 clocks
//   O2  HS pulse width is exactly 44 clocks
//   O3  DE width is exactly 1920 pixels on every active line
//   O4  active lines per frame is exactly 1080
//   O5  frame period is exactly 1125 lines
//   O6  VS pulse width is exactly 5 lines (11000 clocks)
//
// O4/O5 need one full frame (2.475 M clocks) at 148.5 MHz, so the test runs for
// about 17 ms of simulated time with a single clock - a few seconds of CPU.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_out_timing;

    integer dgc_errors = 0;

    reg clk = 0;
    always #3.3670 clk = ~clk;          // 148.5 MHz

    reg rst_n = 0;

    wire        vs, hs, de, de_re;
    wire [11:0] x_act, y_act;

    sync_vg #(
        .X_BITS  (12),
        .Y_BITS  (12),
        .V_TOTAL (12'd1125),
        .V_FP    (12'd4),
        .V_BP    (12'd36),
        .V_SYNC  (12'd5),
        .V_ACT   (12'd1080),
        .H_TOTAL (12'd2200),
        .H_FP    (12'd88),
        .H_BP    (12'd148),
        .H_SYNC  (12'd44),
        .H_ACT   (12'd1920)
    ) u_sync_vg (
        .clk    (clk),
        .rstn   (rst_n),
        .vs_out (vs),
        .hs_out (hs),
        .de_out (de),
        .de_re  (de_re),
        .x_act  (x_act),
        .y_act  (y_act)
    );

    // ------------------------------------------------------------- measurement
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg hs_d = 0, vs_d = 0, de_d = 0;

    integer line_cyc      = 0;
    integer line_de       = 0;
    integer lines         = 0;
    integer frames        = 0;
    integer active_lines  = 0;
    integer hs_width      = 0;
    integer vs_width_lines = 0;

    integer last_hs_cyc   = 0;
    integer last_frame_line = 0;
    integer measured_line_period = -1;
    integer measured_de   = -1;
    integer measured_hs   = -1;
    integer measured_act_lines = -1;
    integer measured_frame_lines = -1;
    integer measured_vs_lines = -1;

    always @(posedge clk) begin
        cyc     <= cyc + 1;
        hs_d    <= hs;
        vs_d    <= vs;

        // HS pulse width in clocks
        if (hs && !hs_d) hs_width <= 1;
        else if (hs)     hs_width <= hs_width + 1;
        if (!hs && hs_d) measured_hs <= hs_width;

        // line accounting
        if (hs && !hs_d) begin
            lines <= lines + 1;
            measured_line_period <= cyc - last_hs_cyc;
            last_hs_cyc <= cyc;
            if (line_de != 0) begin
                measured_de <= line_de;
                active_lines <= active_lines + 1;
            end
            line_de <= 0;
        end
        else if (de) begin
            line_de <= line_de + 1;
        end

        // VS pulse width in lines
        if (vs && !vs_d) vs_width_lines <= 1;
        else if (vs)     vs_width_lines <= vs_width_lines + 1;
        if (!vs && vs_d) measured_vs_lines <= vs_width_lines;

        // frame accounting
        if (vs && !vs_d) begin
            measured_act_lines  <= active_lines;
            measured_frame_lines <= lines - last_frame_line;
            last_frame_line <= lines;
            active_lines <= 0;
            frames <= frames + 1;
        end
    end

    integer waited;

    initial begin
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;

        // run for two full frames so that every measurement has completed at
        // least once with a full frame behind it
        waited = 0;
        while (frames < 2 && waited < 5000000) begin
            @(posedge clk);
            waited = waited + 1;
        end
        if (frames < 2) `DGC_FAIL("O5: fewer than two frames completed")

        $display("TEST_INFO: O1 line period       = %0d clocks (expected 2200)", measured_line_period);
        $display("TEST_INFO: O2 HS width          = %0d clocks (expected 44)",   measured_hs);
        $display("TEST_INFO: O3 DE width          = %0d pixels (expected 1920)",   measured_de);
        $display("TEST_INFO: O4 active lines      = %0d       (expected 1080)",   measured_act_lines);
        $display("TEST_INFO: O5 frame period      = %0d lines  (expected 1125)",   measured_frame_lines);
        $display("TEST_INFO: O6 VS width          = %0d clocks (expected 11000 = 5 lines)", measured_vs_lines);

        if (measured_line_period  != 2200) `DGC_FAIL("O1: line period mismatch")
        if (measured_hs           != 44)   `DGC_FAIL("O2: HS width mismatch")
        if (measured_de           != 1920) `DGC_FAIL("O3: DE width mismatch")
        if (measured_act_lines    != 1080) `DGC_FAIL("O4: active line count mismatch")
        if (measured_frame_lines  != 1125) `DGC_FAIL("O5: frame line count mismatch")
        if (measured_vs_lines     != 11000) `DGC_FAIL("O6: VS width mismatch")   // 5 lines x 2200

        $display("TEST_INFO: output timing test finished at %0t", $time);
        `DGC_FINISH
    end

endmodule
