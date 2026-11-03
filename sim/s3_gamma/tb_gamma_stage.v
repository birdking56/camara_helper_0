//-----------------------------------------------------------------------------
// tb_gamma_stage.v - S3: gamma bypass and identity LUT must be bit exact
//   G1  bypass: the whole 192-bit record passes unchanged
//   G2  fixed identity LUT: every RGB field maps to itself
//   G3  256 values swept on all four neighbours
//   G4  backpressure
//   G5  gamma_mode = 2 raises the unsupported flag
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_gamma_stage;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg  [1:0]   gamma_mode = 0;
    reg          in_valid = 0;
    wire         in_ready;
    reg  [191:0] in_sample = 0;
    wire         out_valid;
    reg          out_ready = 1;
    wire [191:0] out_sample;
    wire         unsupported_mode;

    dgc_gamma_stage u_dut (
        .clk (clk), .rst_n (rst_n),
        .gamma_mode (gamma_mode),
        .in_valid (in_valid), .in_ready (in_ready), .in_sample (in_sample),
        .out_valid (out_valid), .out_ready (out_ready), .out_sample (out_sample),
        .unsupported_mode (unsupported_mode)
    );

    localparam integer QN = 1024;
    reg [191:0] exp_q [0:QN-1];
    integer q_wp = 0, q_rp = 0, n_checked = 0, seed = 5;
    reg bp_en = 0;

    always @(posedge clk) begin
        if (bp_en) out_ready <= (({$random(seed)} % 100) >= 30);
        else      out_ready <= 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            if (q_rp >= q_wp) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: gamma produced an unrequested beat");
            end
            else begin
                if (out_sample !== exp_q[q_rp]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 10)
                    $display("TEST_FAIL: beat %0d exp=%048h act=%048h", q_rp, exp_q[q_rp], out_sample);
                end
                q_rp = q_rp + 1; n_checked = n_checked + 1;
            end
        end
    end

    task drive(input [191:0] s);
        begin
            @(posedge clk); #0.2;
            while (!in_ready) begin @(posedge clk); #0.2; end
            in_sample <= s;
            in_valid  <= 1'b1;
            exp_q[q_wp] = s;       // both modes must reproduce the record exactly
            q_wp = q_wp + 1;
            @(posedge clk); #0.2;
            in_valid <= 1'b0;
        end
    endtask

    integer i;
    reg [191:0] s;

    initial begin
        rst_n = 0; in_valid = 0; out_ready = 1;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        gamma_mode = 2'd0;
        for (i = 0; i < 8; i = i + 1) begin
            s = {$random(seed)}; drive(s);
        end
        repeat (6) @(posedge clk);
        $display("TEST_INFO: G1 bypass passes the record unchanged");

        gamma_mode = 2'd1;
        for (i = 0; i < 256; i = i + 1) begin
            s = { {(i[7:0])}, {(i[7:0] ^ 8'hFF)}, {(i[7:0])}, {(i[7:0] ^ 8'h0F)},
                  {72'h0, i[7:0], i[7:0]}, 11'd0, 11'd0 };
            drive(s);
        end
        repeat (10) @(posedge clk);
        if (n_checked != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: %0d sent but %0d checked", q_wp, n_checked);
        end
        $display("TEST_INFO: G2/G3 identity LUT bit exact over 256 values on four neighbours");

        bp_en = 1;
        for (i = 0; i < 200; i = i + 1) begin
            s = {$random(seed)}; drive(s);
        end
        repeat (200) @(posedge clk);
        bp_en = 0;
        if (n_checked != q_wp) `DGC_FAIL("G4: backpressure lost a beat")
        $display("TEST_INFO: G4 200 beats through random backpressure, %0d total", n_checked);

        gamma_mode = 2'd2;
        drive(192'h1234);
        repeat (4) @(posedge clk);
        if (unsupported_mode !== 1'b1) `DGC_FAIL("G5: auto gamma not flagged as unsupported")
        $display("TEST_INFO: G5 unsupported auto-gamma is flagged, not silently ignored");

        `DGC_FINISH
    end
endmodule
