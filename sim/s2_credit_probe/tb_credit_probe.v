`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_credit_probe;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_DDR) clk = ~clk;
    reg rst_n = 0;
    reg [10:0] wr_level = 0;
    reg reserve = 0; reg [4:0] reserve_beats = 0;
    wire reserve_ok;
    reg ar_fire = 0; reg [4:0] ar_beats = 0; reg r_fire = 0;
    wire [11:0] outstanding, reserved; wire [12:0] headroom; wire overflow_seen;

    dgc_ddr_credit u_dut (.clk(clk), .rst_n(rst_n), .wr_level(wr_level),
        .reserve(reserve), .reserve_beats(reserve_beats), .reserve_ok(reserve_ok),
        .ar_fire(ar_fire), .ar_beats(ar_beats), .r_fire(r_fire),
        .outstanding(outstanding), .reserved(reserved),
        .headroom(headroom), .overflow_seen(overflow_seen));

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // reserve 4 for exactly one clock
        @(posedge clk); #0.2; reserve <= 1'b1; reserve_beats <= 5'd4;
        @(posedge clk); #0.2; reserve <= 1'b0;
        repeat (2) @(posedge clk);
        if (reserved !== 12'd4) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: after reserve P exp=4 act=%0d", reserved);
        end
        $display("TEST_INFO: after a one-cycle reserve: O=%0d P=%0d headroom=%0d",
                 outstanding, reserved, headroom);

        // handshake those 4 beats
        @(posedge clk); #0.2; ar_fire <= 1'b1; ar_beats <= 5'd4;
        @(posedge clk); #0.2; ar_fire <= 1'b0;
        repeat (2) @(posedge clk);
        if (reserved !== 12'd0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: after handshake P exp=0 act=%0d", reserved);
        end
        if (outstanding !== 12'd4) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: after handshake O exp=4 act=%0d", outstanding);
        end
        if (dgc_errors == 0)
            $display("TEST_INFO: after the handshake: O=%0d P=%0d headroom=%0d (P correctly returned to 0)",
                     outstanding, reserved, headroom);

        // retire them
        repeat (4) begin
            @(posedge clk); #0.2; r_fire <= 1'b1;
            @(posedge clk); #0.2; r_fire <= 1'b0;
        end
        repeat (2) @(posedge clk);
        $display("TEST_INFO: after 4 returns: O=%0d P=%0d", outstanding, reserved);
        if (outstanding !== 12'd0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O did not return to 0");
        end
        `DGC_FINISH
    end
endmodule
