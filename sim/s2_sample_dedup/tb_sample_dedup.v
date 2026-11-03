//-----------------------------------------------------------------------------
// tb_sample_dedup.v - edge replication
//   D1  no edge: four distinct results pass through unchanged
//   D2  right edge: x neighbours replicate, y still distinct
//   D3  bottom edge: y neighbours replicate, x still distinct
//   D4  both edges: a single point fills all four
//   D5  need/dup are consistent: need+dup == 4, need in {1,2,4}
//   D6  exhaustive over all four edge combinations x 100 value sets
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_sample_dedup;
    integer dgc_errors = 0;

    reg        edge_x = 0, edge_y = 0;
    reg [23:0] r00 = 0, r10 = 0, r01 = 0, r11 = 0;
    wire [23:0] p00, p10, p01, p11;
    wire [2:0] need, dup;

    dgc_sample_dedup u_dut (.edge_x(edge_x), .edge_y(edge_y),
        .r00(r00), .r10(r10), .r01(r01), .r11(r11),
        .p00(p00), .p10(p10), .p01(p01), .p11(p11), .need(need), .dup(dup));

    reg [23:0] a, b, c, e;
    integer ex, ey, k, seed;

    initial begin
        a = 24'h11_22_33; b = 24'h44_55_66; c = 24'h77_88_99; e = 24'hAA_BB_CC;

        // ============================================================== D1
        edge_x = 0; edge_y = 0; r00 = a; r10 = b; r01 = c; r11 = e; #0;
        if (p00 !== a || p10 !== b || p01 !== c || p11 !== e) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D1 four distinct results were altered");
        end
        else $display("TEST_INFO: D1 with no edge the four results pass through unchanged");

        // ============================================================== D2
        edge_x = 1; edge_y = 0; #0;
        if (p00 !== a || p10 !== a || p01 !== c || p11 !== c) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D2 right-edge replication wrong");
        end
        else $display("TEST_INFO: D2 at the right edge x neighbours replicate");

        // ============================================================== D3
        edge_x = 0; edge_y = 1; #0;
        if (p00 !== a || p10 !== b || p01 !== a || p11 !== b) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D3 bottom-edge replication wrong");
        end
        else $display("TEST_INFO: D3 at the bottom edge y neighbours replicate");

        // ============================================================== D4
        edge_x = 1; edge_y = 1; #0;
        if (p00 !== a || p10 !== a || p01 !== a || p11 !== a) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: D4 both edges must fill all four from one point");
        end
        else $display("TEST_INFO: D4 at the corner one result fills all four neighbours");

        // ============================================================== D5/D6
        seed = 7;
        for (ex = 0; ex <= 1; ex = ex + 1)
        for (ey = 0; ey <= 1; ey = ey + 1)
        for (k = 0; k < 100; k = k + 1) begin
            edge_x = ex[0]; edge_y = ey[0];
            r00 = $random(seed); r10 = $random(seed);
            r01 = $random(seed); r11 = $random(seed);
            #0;
            if (need + dup !== 3'd4) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: D5 need+dup != 4");
            end
            if (need !== 3'd1 && need !== 3'd2 && need !== 3'd4) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: D5 need not in {1,2,4} (%0d)", need);
            end
            // the replicated positions must equal the point they copy
            if (!ex && !ey) begin
                if (p00 !== r00 || p10 !== r10 || p01 !== r01 || p11 !== r11) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: D6 passthrough wrong");
                end
            end
            if (ex && !ey) begin
                if (p00 !== r00 || p10 !== r00 || p01 !== r01 || p11 !== r01) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: D6 x replication wrong");
                end
            end
            if (!ex && ey) begin
                if (p00 !== r00 || p10 !== r10 || p01 !== r00 || p11 !== r10) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: D6 y replication wrong");
                end
            end
            if (ex && ey) begin
                if (p00 !== r00 || p10 !== r00 || p01 !== r00 || p11 !== r00) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: D6 corner replication wrong");
                end
            end
        end
        $display("TEST_INFO: D5 need+dup == 4 and need is 1, 2 or 4");
        $display("TEST_INFO: D6 exhaustive over 4 edge combinations x 100 random value sets");
        `DGC_FINISH
    end
endmodule
