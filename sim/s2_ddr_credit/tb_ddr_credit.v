//-----------------------------------------------------------------------------
// tb_ddr_credit.v - U+O+P+B+16 <= 1024
//   C1  the predicate boundary is exact: allowed at the limit, refused one over
//   C2  reserve then handshake moves beats from P to O
//   C3  every return retires exactly one outstanding beat
//   C4  many requests never push U+O+P past depth-margin
//   C5  a reservation is refused when the FIFO is nearly full
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_ddr_credit;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_DDR) clk = ~clk;
    reg rst_n = 0;

    reg  [10:0] wr_level = 0;
    reg         reserve = 0;
    reg  [4:0]  reserve_beats = 0;
    wire        reserve_ok;
    reg         ar_fire = 0;
    reg  [4:0]  ar_beats = 0;
    reg         r_fire = 0;
    wire [11:0] outstanding, reserved;
    wire [12:0] headroom;
    wire        overflow_seen;

    dgc_ddr_credit u_dut (
        .clk(clk), .rst_n(rst_n), .wr_level(wr_level),
        .reserve(reserve), .reserve_beats(reserve_beats), .reserve_ok(reserve_ok),
        .ar_fire(ar_fire), .ar_beats(ar_beats), .r_fire(r_fire),
        .outstanding(outstanding), .reserved(reserved),
        .headroom(headroom), .overflow_seen(overflow_seen));

    integer u, b, thr;
    integer k;

    task do_reserve(input [4:0] nb);
        begin
            @(posedge clk); #0.2;
            reserve <= 1'b1; reserve_beats <= nb;
            @(posedge clk); #0.2;
            reserve <= 1'b0;
            repeat (1) @(posedge clk);
        end
    endtask

    task do_ar(input [4:0] nb);
        begin
            @(posedge clk); #0.2;
            ar_fire <= 1'b1; ar_beats <= nb;
            @(posedge clk); #0.2;
            ar_fire <= 1'b0;
            repeat (1) @(posedge clk);
        end
    endtask

    task do_r;
        begin
            @(posedge clk); #0.2;
            r_fire <= 1'b1;
            @(posedge clk); #0.2;
            r_fire <= 1'b0;
            repeat (1) @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // ============================================================== C1
        // with O=P=0 the boundary is U <= 1024-16-B
        for (b = 1; b <= 7; b = b + 1) begin
            thr = 1024 - 16 - b;
            wr_level = thr[10:0]; reserve_beats = b[4:0]; reserve = 1'b0; #0;
            if (!reserve_ok) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: C1 must allow U=%0d B=%0d", thr, b);
            end
            wr_level = (thr + 1); #0;
            if (reserve_ok) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: C1 must refuse U=%0d B=%0d", thr+1, b);
            end
        end
        $display("TEST_INFO: C1 the boundary U+O+P+B+16 = 1024 is exact for every B in 1..7");

        // ============================================================== C2
        wr_level = 11'd0;
        do_reserve(5'd4);
        if (reserved !== 12'd4) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C2 reserved exp=4 act=%0d", reserved); end
        do_ar(5'd4);
        if (outstanding !== 12'd4 || reserved !== 12'd0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C2 handshake O=%0d P=%0d", outstanding, reserved); end
        else $display("TEST_INFO: C2 reserved beats moved to outstanding on the handshake");

        // ============================================================== C3
        do_r;
        if (outstanding !== 12'd3) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C3 return did not retire one beat (%0d)", outstanding); end
        else $display("TEST_INFO: C3 each return retires exactly one beat");

        // ============================================================== C4
        // drain, then push many small requests while returns trickle in
        while (outstanding != 0) do_r;
        wr_level = 11'd600;
        for (k = 0; k < 40; k = k + 1) begin
            reserve_beats = 5'd7; reserve = 1'b1; #0;
            if (!reserve_ok && k >= 0) begin
                // refusal is fine, just record it
            end
            @(posedge clk); #0.2; reserve = 1'b0;
            @(posedge clk); #0.2;
            do_ar(5'd7);
            do_r; do_r;
            if ((wr_level + outstanding + reserved) > 1024 - 16) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: C4 invariant broken U=%0d O=%0d P=%0d", wr_level, outstanding, reserved);
            end
        end
        if (overflow_seen) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C4 the sticky overflow flag was raised");
        end
        $display("TEST_INFO: C4 40 pipelined requests never broke U+O+P <= 1024-16");

        // ============================================================== C5
        while (outstanding != 0) do_r;
        wr_level = 11'd1015;
        reserve_beats = 5'd7; reserve = 1'b0; #0;
        if (reserve_ok) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C5 a 7-beat request must not fit at U=1015");
        end
        wr_level = 11'd1001;
        #0;
        if (!reserve_ok) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C5 a 7-beat request must fit at U=1001");
        end
        else $display("TEST_INFO: C5 a nearly full FIFO refuses, the exact limit still fits");

        $display("TEST_INFO: C final O=%0d P=%0d headroom=%0d", outstanding, reserved, headroom);
        `DGC_FINISH
    end
endmodule
