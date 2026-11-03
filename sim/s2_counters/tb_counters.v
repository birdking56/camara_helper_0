//-----------------------------------------------------------------------------
// tb_counters.v - eight saturating counters
//   X1  reset clears every counter
//   X2  an increment adds exactly its amount
//   X3  a counter saturates at the ceiling instead of wrapping
//   X4  once saturated, further increments leave it at the ceiling
//   X5  counters are independent: one increment does not move the others
//   X6  a zero-amount increment is harmless
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_counters;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg  [7:0]         inc_en = 0;
    reg  [8*8-1:0]     inc_val = 0;
    wire [8*8-1:0]     cnt;

    // 8-bit counters so the ceiling is reachable in a few cycles
    dgc_counters #(.WIDTH(8), .INC_W(8)) u_dut (
        .clk(clk), .rst_n(rst_n), .inc_en(inc_en), .inc_val(inc_val), .cnt(cnt));


    // simpler: set the whole inc_val explicitly
    reg [63:0] val_hold;
    task add(input integer which, input [7:0] amt);
        begin
            val_hold = 64'd0;
            @(posedge clk); #0.2;
            inc_val[which*8 +: 8] <= amt;
            inc_en <= (8'd1 << which);
            @(posedge clk); #0.2;
            inc_en <= 8'd0;
            @(posedge clk); #0.2;
            inc_val <= 64'd0;
            repeat (1) @(posedge clk);
        end
    endtask

    integer i;
    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // ============================================================== X1
        if (cnt !== 64'd0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X1 reset did not clear the counters (%0h)", cnt);
        end
        else $display("TEST_INFO: X1 reset clears all eight counters");

        // ============================================================== X2
        add(0, 8'd5);
        if (cnt[7:0] !== 8'd5) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X2 counter 0 exp=5 act=%0d", cnt[7:0]);
        end
        else $display("TEST_INFO: X2 an increment adds its exact amount");

        // ============================================================== X3/X4
        add(0, 8'd250);
        if (cnt[7:0] !== 8'd255) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X3 counter 0 must saturate at 255, got %0d", cnt[7:0]);
        end
        else $display("TEST_INFO: X3 5 + 250 saturates at 255 instead of wrapping to 255-256");

        add(0, 8'd1);
        add(0, 8'd200);
        if (cnt[7:0] !== 8'd255) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X4 a saturated counter moved (%0d)", cnt[7:0]);
        end
        else $display("TEST_INFO: X4 a saturated counter stays at the ceiling");

        // ============================================================== X5
        add(3, 8'd7);
        if (cnt[7:0] !== 8'd255) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X5 counter 0 disturbed by another counter");
        end
        if (cnt[3*8 +: 8] !== 8'd7) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X5 counter 3 exp=7 act=%0d", cnt[3*8 +: 8]);
        end
        for (i = 1; i < 8; i = i + 1)
            if (i != 3 && cnt[i*8 +: 8] !== 8'd0) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: X5 counter %0d should still be 0", i);
            end
        $display("TEST_INFO: X5 the eight counters are independent");

        // ============================================================== X6
        add(3, 8'd0);
        if (cnt[3*8 +: 8] !== 8'd7) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: X6 a zero increment changed the counter");
        end
        else $display("TEST_INFO: X6 a zero-amount increment is harmless");

        $display("TEST_INFO: X counters = %0h", cnt);
        `DGC_FINISH
    end
endmodule
