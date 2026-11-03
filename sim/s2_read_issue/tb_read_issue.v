//-----------------------------------------------------------------------------
// tb_read_issue.v
//   R1  no edge issues four reads
//   R2  one edge issues two, and the duplicated port stays silent
//   R3  both edges issue exactly one
//   R4  reads always equals the number of asserted ports
//   R5  p0 always fires: the (sx0,sy0) point exists in every case
//   R6  exhaustive over the four edge combinations
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_read_issue;
    integer dgc_errors = 0;
    reg ex = 0, ey = 0;
    wire f0, f1, f2, f3;
    wire [2:0] reads;

    dgc_read_issue u_dut (.edge_x(ex), .edge_y(ey), .p0_fire(f0), .p1_fire(f1),
                          .p2_fire(f2), .p3_fire(f3), .reads(reads));

    integer a, b, n;
    initial begin
        for (a = 0; a <= 1; a = a + 1)
        for (b = 0; b <= 1; b = b + 1) begin
            ex = a[0]; ey = b[0]; #0;
            n = f0 + f1 + f2 + f3;
            if (reads !== n[2:0]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: R4 reads=%0d but %0d ports fired (ex=%0d ey=%0d)", reads, n, a, b);
            end
            if (!f0) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: R5 p0 did not fire (ex=%0d ey=%0d)", a, b);
            end
            if (a && f1) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: R2 edge_x must silence p1");
            end
            if (b && f2) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: R2 edge_y must silence p2");
            end
            if ((a || b) && f3) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: R2 p3 must be silent if either edge is set");
            end
        end
        $display("TEST_INFO: R6 all four edge combinations checked");

        ex = 0; ey = 0; #0;
        if (reads !== 3'd4) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: R1 no edge must issue 4"); end
        else $display("TEST_INFO: R1 no edge issues four reads");

        ex = 1; ey = 0; #0;
        if (reads !== 3'd2) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: R2 edge_x must issue 2"); end
        else $display("TEST_INFO: R2 edge_x issues two reads (p0 and p2)");

        ex = 0; ey = 1; #0;
        if (reads !== 3'd2) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: R2 edge_y must issue 2"); end
        else $display("TEST_INFO: R2 edge_y issues two reads (p0 and p1)");

        ex = 1; ey = 1; #0;
        if (reads !== 3'd1) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: R3 both edges must issue 1"); end
        else $display("TEST_INFO: R3 both edges issue one read, the corner pixel");

        `DGC_FINISH
    end
endmodule
