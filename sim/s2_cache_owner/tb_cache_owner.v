//-----------------------------------------------------------------------------
// tb_cache_owner.v - A/B set ownership
//   O1  a fresh pair has both sets FREE and accepts a fill
//   O2  a fill makes its set FILLING, then READY on completion
//   O3  only a READY set may start sampling, and it becomes READING
//   O4  rel returns the sampled set to FREE
//   O5  filling set 1 while set 0 is being read keeps them in different sets
//   O6  a set that is READING is never chosen as a fill target
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_cache_owner;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    reg fill_begin = 0; reg [15:0] fill_tag = 0; reg fill_complete = 0;
    reg sample_begin = 0; reg rel = 0;
    wire set0_ready, set1_ready, fill_ok;
    wire [15:0] set0_tag, set1_tag;
    wire [1:0] set0_state, set1_state;
    wire [31:0] cnt_fill, cnt_sample, cnt_release;

    dgc_cache_owner u_dut (.clk(clk), .rst_n(rst_n),
        .fill_begin(fill_begin), .fill_tag(fill_tag), .fill_complete(fill_complete),
        .sample_begin(sample_begin), .rel(rel),
        .set0_ready(set0_ready), .set1_ready(set1_ready),
        .set0_tag(set0_tag), .set1_tag(set1_tag),
        .set0_state(set0_state), .set1_state(set1_state), .fill_ok(fill_ok),
        .cnt_fill(cnt_fill), .cnt_sample(cnt_sample), .cnt_release(cnt_release));

    task pulse_fill_begin(input [15:0] tg);
        begin @(posedge clk); #0.2; fill_begin <= 1'b1; fill_tag <= tg;
              @(posedge clk); #0.2; fill_begin <= 1'b0; repeat (1) @(posedge clk); end
    endtask
    task pulse_complete;
        begin @(posedge clk); #0.2; fill_complete <= 1'b1;
              @(posedge clk); #0.2; fill_complete <= 1'b0; repeat (1) @(posedge clk); end
    endtask
    task pulse_sample;
        begin @(posedge clk); #0.2; sample_begin <= 1'b1;
              @(posedge clk); #0.2; sample_begin <= 1'b0; repeat (1) @(posedge clk); end
    endtask
    task pulse_release;
        begin @(posedge clk); #0.2; rel <= 1'b1;
              @(posedge clk); #0.2; rel <= 1'b0; repeat (1) @(posedge clk); end
    endtask

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // ============================================================== O1
        if (set0_state !== 2'd0 || set1_state !== 2'd0 || !fill_ok) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O1 fresh pair is not FREE");
        end
        else $display("TEST_INFO: O1 a fresh pair has both sets FREE and accepts a fill");

        // ============================================================== O2
        pulse_fill_begin(16'hA001);
        if (set0_state !== 2'd1 || set0_tag !== 16'hA001) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O2 set0 not FILLING with the tag");
        end
        if (set0_ready) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O2 a FILLING set must not be READY");
        end
        pulse_complete;
        if (set0_state !== 2'd2 || !set0_ready) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O2 set0 did not become READY");
        end
        else $display("TEST_INFO: O2 fill completes into READY with its tag");

        // ============================================================== O3
        pulse_sample;
        if (set0_state !== 2'd3) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O3 sampling did not move set0 to READING");
        end
        if (set0_ready) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O3 a READING set must not be READY");
        end
        else $display("TEST_INFO: O3 sampling moves the set to READING and clears READY");

        // ============================================================== O6
        if (!fill_ok) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O6 set1 is FREE so a fill must be possible");
        end

        // ============================================================== O5
        pulse_fill_begin(16'hB002);
        if (set1_state !== 2'd1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O5 the second fill must land in set1, got state %0d", set1_state);
        end
        else $display("TEST_INFO: O5 fill and read occupy different sets (set0 READING, set1 FILLING)");
        if (set0_state !== 2'd3) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O5 set0 must still be READING");
        end

        pulse_complete;
        if (set1_state !== 2'd2) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O5 set1 did not become READY");
        end
        else $display("TEST_INFO: O5 set1 reached READY while set0 is still READING");

        // ============================================================== O4
        pulse_release;
        if (set0_state !== 2'd0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: O4 rel did not free set0");
        end
        else $display("TEST_INFO: O4 rel returns the sampled set to FREE");

        if (cnt_fill !== 32'd2 || cnt_sample !== 32'd1 || cnt_release !== 32'd1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: counts fill=%0d sample=%0d rel=%0d",
                     cnt_fill, cnt_sample, cnt_release);
        end
        `DGC_FINISH
    end
endmodule
