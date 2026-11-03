//-----------------------------------------------------------------------------
// tb_input_timing.v
//
// Directed test for dgc_input_timing:
//   T1  a small raster (64 x 8) reports line_px=64, frame_lines=8
//   T2  a real 1920-wide line reports line_px=1920
//   T3  a real 1080-line frame reports frame_lines=1080
//   T4  fclk_cnt equals the number of pixel clocks between two gate edges
//   T5  de_seen / vs_seen stick after the first activity
//   T6  before any activity every output is 0
//
// The raster is generated with the same counter style as sync_vg: DE is high
// for exactly LINE cycles, VS is a 2-line pulse placed after the active lines
// so the falling edge latches the completed frame height.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_input_timing;

    integer dgc_errors = 0;

    reg pixclk = 0;
    always #3.367 pixclk = ~pixclk;      // 148.5 MHz

    reg rst_n = 0;

    // raster parameters (changed between phases)
    integer LINE    = 64;
    integer LINES   = 8;
    integer H_TOTAL = 100;
    integer V_TOTAL = 40;

    integer hc = 0, vc = 0;

    reg de, vs;
    reg gate_tgl = 0;

    // VS is placed after the active lines: [V_ACT_START, V_ACT_START+LINES)
    localparam integer V_ACT_START = 5;

    always @(*) begin
        de = (vc >= V_ACT_START) && (vc < V_ACT_START + LINES) && (hc < LINE);
        vs = (vc >= V_ACT_START + LINES) && (vc < V_ACT_START + LINES + 2);
    end

    always @(posedge pixclk) begin
        if (hc == H_TOTAL - 1) begin
            hc = 0;
            vc = (vc == V_TOTAL - 1) ? 0 : vc + 1;
        end
        else hc = hc + 1;
    end

    wire [23:0] fclk_cnt;
    wire [11:0] line_px, frame_lines;
    wire        de_seen, vs_seen;

    dgc_input_timing u_dut (
        .pixclk      (pixclk),
        .rst_n       (rst_n),
        .de          (de),
        .vs          (vs),
        .gate_tgl    (gate_tgl),
        .fclk_cnt    (fclk_cnt),
        .line_px     (line_px),
        .frame_lines (frame_lines),
        .de_seen     (de_seen),
        .vs_seen     (vs_seen)
    );

    task run_one_frame;
        input integer line;
        input integer lines;
        input integer htotal;
        input integer vtotal;
        begin
            LINE    = line;
            LINES   = lines;
            H_TOTAL = htotal;
            V_TOTAL = vtotal;
            hc = 0;
            vc = 0;
            // one complete frame plus the VS pulse that closes it
            repeat (htotal * vtotal + 2 * htotal) @(posedge pixclk);
        end
    endtask

    integer n;
    integer e0;

    initial begin
        rst_n = 0;
        repeat (5) @(posedge pixclk);
        rst_n = 1;

        // ---------------------------------------------------------------- T6
        @(posedge pixclk);
        if (fclk_cnt !== 24'd0)   `DGC_FAIL("T6 fclk_cnt not zero before a gate edge")
        if (line_px !== 12'd0)    `DGC_FAIL("T6 line_px not zero before any DE")
        if (frame_lines !== 12'd0)`DGC_FAIL("T6 frame_lines not zero before any VS")
        if (de_seen !== 1'b0)     `DGC_FAIL("T6 de_seen set before any DE")
        if (vs_seen !== 1'b0)     `DGC_FAIL("T6 vs_seen set before any VS")
        $display("TEST_INFO: T6 all outputs are zero before the first frame");

        // ---------------------------------------------------------------- T1
        run_one_frame(64, 8, 100, V_ACT_START + 8 + 8);
        $display("TEST_INFO: T1 line_px=%0d frame_lines=%0d de_seen=%0d vs_seen=%0d",
                 line_px, frame_lines, de_seen, vs_seen);
        if (line_px !== 12'd64)     `DGC_FAIL("T1 line_px should be 64")
        if (frame_lines !== 12'd8)  `DGC_FAIL("T1 frame_lines should be 8")
        if (!de_seen || !vs_seen)   `DGC_FAIL("T1 activity flags not sticky")

        // ---------------------------------------------------------------- T2
        run_one_frame(1920, 4, 2200, V_ACT_START + 4 + 8);
        $display("TEST_INFO: T2 line_px=%0d (expect 1920)", line_px);
        if (line_px !== 12'd1920)   `DGC_FAIL("T2 line_px should be 1920")

        // ---------------------------------------------------------------- T3
        run_one_frame(64, 1080, 100, V_ACT_START + 1080 + 8);
        $display("TEST_INFO: T3 frame_lines=%0d (expect 1080)", frame_lines);
        if (frame_lines !== 12'd1080) `DGC_FAIL("T3 frame_lines should be 1080")

        // ---------------------------------------------------------------- T4
        // Two gate edges exactly 777 pixel clocks apart. Both are synchronised
        // through the same 2-flop path, so the measured count is 777 +- 2.
        gate_tgl = 1'b1;
        repeat (777) @(posedge pixclk);
        gate_tgl = 1'b0;
        repeat (10) @(posedge pixclk);
        n = fclk_cnt;
        $display("TEST_INFO: T4 fclk_cnt between gate edges = %0d (expect 777 +- 2)", n);
        if (n < 775 || n > 779) `DGC_FAIL("T4 fclk_cnt does not measure the gate window")

        if (dgc_errors == 0) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d", dgc_errors);
        $finish;
    end

endmodule
