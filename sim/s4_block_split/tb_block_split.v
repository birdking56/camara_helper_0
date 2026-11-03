`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_block_split;
    integer dgc_errors = 0;
    reg  [10:0] ow = 32, oh = 16;
    reg  [6:0]  bw = 1, bh = 1;
    wire        split, split_x;
    wire [10:0] a_w, a_h, b_w, b_h;

    dgc_block_split u_dut (.ow(ow), .oh(oh), .bw(bw), .bh(bh),
                           .split(split), .split_x(split_x),
                           .a_w(a_w), .a_h(a_h), .b_w(b_w), .b_h(b_h));

    integer i, j, k, m, nsplit;
    reg [6:0] bb [0:5];
    initial begin
        bb[0]=1; bb[1]=63; bb[2]=64; bb[3]=65; bb[4]=100; bb[5]=127;
        nsplit = 0;
        for (i = 1; i <= 32; i = i + 1)
        for (j = 1; j <= 16; j = j + 1)
        for (k = 0; k < 6; k = k + 1)
        for (m = 0; m < 6; m = m + 1) begin
            ow = i[10:0]; oh = j[10:0];
            bw = bb[k];   bh = bb[m];
            #0;
            // Q1 the bbox decides whether to split
            if (split !== (((bb[k] > 64) || (bb[m] > 64)) && ((i > 1) || (j > 1)))) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: Q1 split flag wrong ow=%0d oh=%0d bbox=%0dx%0d", i, j, bb[k], bb[m]);
            end
            if (split) begin
                nsplit = nsplit + 1;
                // Q2 children are halves of the OUTPUT extent, never larger than the parent
                if (a_w > i || b_w > i || a_h > j || b_h > j) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: Q2 child larger than parent ow=%0d oh=%0d", i, j);
                end
                // Q3 children are non-empty and sum back to the parent
                if (split_x) begin
                    if (a_w < 1 || b_w < 1 || (a_w + b_w) !== i || a_h !== j || b_h !== j) begin
                        dgc_errors = dgc_errors + 1;
                        if (dgc_errors < 8) $display("TEST_FAIL: Q3 x-split geometry wrong ow=%0d oh=%0d", i, j);
                    end
                end
                else begin
                    if (a_h < 1 || b_h < 1 || (a_h + b_h) !== j || a_w !== i || b_w !== i) begin
                        dgc_errors = dgc_errors + 1;
                        if (dgc_errors < 8) $display("TEST_FAIL: Q3 y-split geometry wrong ow=%0d oh=%0d", i, j);
                    end
                end
                // Q4 split along the longer OUTPUT dimension, tie to x, 1 forces the other
                if (j == 1 && split_x !== 1'b1) begin dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: Q4 oh==1 must split x"); end
                if (i == 1 && j != 1 && split_x !== 1'b0) begin dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: Q4 ow==1 must split y"); end
                if (i > j && j != 1 && split_x !== 1'b1) begin dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: Q4 wider output must split x"); end
                if (j > i && i != 1 && split_x !== 1'b0) begin dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: Q4 taller output must split y"); end
                if (i == j && i != 1 && split_x !== 1'b1) begin dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: Q4 tie must split x"); end
            end
        end
        $display("TEST_INFO: Q1 the bbox decides whether to split");
        $display("TEST_INFO: Q2/Q3 children are halves of the output extent, non-empty, sum to parent");
        $display("TEST_INFO: Q4 axis follows the longer OUTPUT dimension, tie x, 1 forces the other");
        $display("TEST_INFO: combinations exercised = %0d, of which split = %0d", 32*16*36, nsplit);

        // the concrete case that exposed the earlier misreading
        ow = 11'd32; oh = 11'd16; bw = 7'd65; bh = 7'd16; #0;
        $display("TEST_INFO: 32x16 output with a 65x16 bbox -> %0dx%0d + %0dx%0d (split_x=%0d)",
                 a_w, a_h, b_w, b_h, split_x);
        if (a_w !== 11'd16 || b_w !== 11'd16) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: the 65x16 bbox must bisect the 32-wide output into 16 + 16");
        end
        `DGC_FINISH
    end
endmodule
