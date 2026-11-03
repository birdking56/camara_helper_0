`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_mul;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    reg ce = 1;
    reg signed [31:0] a = 0;
    reg signed [39:0] b = 0;
    wire signed [71:0] p, pc;

    dgc_mul_pipe #(.AW(32), .BW(40)) u_dut (
        .clk(clk), .rst_n(rst_n), .ce(ce),
        .a(a), .b(b), .p(p), .p_comb(pc)
    );

    reg signed [31:0] a32 = 0, b32 = 0;
    wire signed [63:0] p32, pc32;
    dgc_mul_pipe #(.AW(32), .BW(32)) u32 (
        .clk(clk), .rst_n(rst_n), .ce(ce),
        .a(a32), .b(b32), .p(p32), .p_comb(pc32)
    );

    reg signed [25:0] a26 = 0;
    reg signed [17:0] b26 = 0;
    wire signed [43:0] p26, pc26;
    dgc_mul_pipe #(.AW(26), .BW(18)) u26 (
        .clk(clk), .rst_n(rst_n), .ce(ce),
        .a(a26), .b(b26), .p(p26), .p_comb(pc26)
    );

    task check32(input signed [31:0] aa, input signed [31:0] bb);
        begin
            @(negedge clk); a32 = aa; b32 = bb;
            @(posedge clk); #0.1;
            if (pc32 !== (aa * bb)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: p32_comb a=%0d b=%0d exp=%0d act=%0d", aa, bb, aa*bb, pc32);
            end
            @(posedge clk); #0.1;
            if (p32 !== (aa * bb)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: p32 a=%0d b=%0d exp=%0d act=%0d", aa, bb, aa*bb, p32);
            end
        end
    endtask

    task check26(input signed [25:0] aa, input signed [17:0] bb);
        begin
            @(negedge clk); a26 = aa; b26 = bb;
            @(posedge clk); #0.1;
            if (pc26 !== (aa * bb)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: p26_comb a=%0d b=%0d exp=%0d act=%0d", aa, bb, aa*bb, pc26);
            end
            @(posedge clk); #0.1;
            if (p26 !== (aa * bb)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: p26 a=%0d b=%0d exp=%0d act=%0d", aa, bb, aa*bb, p26);
            end
        end
    endtask

    task check(input signed [31:0] aa, input signed [39:0] bb);
        begin
            @(negedge clk); a = aa; b = bb;
            @(posedge clk); #0.1;
            if (pc !== (aa * bb)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: p_comb a=%0d b=%0d exp=%0d act=%0d", aa, bb, aa*bb, pc);
            end
            @(posedge clk); #0.1;
            if (p !== (aa * bb)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: p a=%0d b=%0d exp=%0d act=%0d", aa, bb, aa*bb, p);
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);
        check(32'sd1, 40'sd1);
        check(32'sd2, 40'sd3);
        check(-32'sd5, 40'sd7);
        check(32'sd137377855, 40'sd0);
        check(32'sd137377855, 40'sd1);
        check(32'sd137377855, -40'sd65536);
        check(32'sd123456789, 40'sd987654321);
        check(-32'sd123456789, -40'sd987654321);
        check32(32'sd1, 32'sd1);
        check32(32'sd2, 32'sd3);
        check32(-32'sd5, 32'sd7);
        check32(32'sd123456789, 32'sd987654321);
        check32(-32'sd123456789, -32'sd987654321);
        check26(26'sd1, 18'sd1);
        check26(26'sd16777215, 18'sd65535);
        check26(26'sd16777215, 18'sd65536);
        check26(26'sd12345678, 18'sd54321);
        check26(26'sd33554431, 18'sd131071);
        check26(26'h0FEFF67, 18'h0FFFF);
        check26(26'h0FEFF67, 18'h00001);
        `DGC_FINISH
    end
endmodule
