//-----------------------------------------------------------------------------
// tb_perf_ctr.v
//
// Directed + constrained-random test for dgc_perf_ctr, the DGC3 interval
// accumulator. The board measurement depends on three properties that are easy
// to get subtly wrong, so each is checked explicitly:
//
//   T1  reset publishes zero
//   T2  the value published on a latch edge is (accumulated + the latch-cycle
//       event) >> SHIFT, and the accumulator restarts from zero afterwards
//   T3  the published value does NOT move while counting between latches
//       (it must be the frozen interval, not a free-running counter)
//   T4  a random sequence of 64 intervals with random events and random lengths
//       matches a reference model exactly, for all three counters at once
//   T5  SHIFT=0 saturates at 0xFFFF instead of wrapping (the "missing snapshot"
//       case must look pinned, never plausible)
//
// The reference model repeats the DGC formula independently: cnt counts posedges
// with ev high since the last latch; on the latch edge it publishes
// (cnt + ev) >> SHIFT and clears. Any one-cycle offset (for example publishing
// the previous interval) makes T2/T4 fail immediately.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_perf_ctr;

    integer dgc_errors = 0;

    reg clk = 0;
    always #5 clk = ~clk;            // 100 MHz, unrelated to any real domain

    reg        rst_n  = 0;
    reg        latch  = 0;
    reg  [2:0] ev     = 3'b000;
    wire [47:0] value;

    dgc_perf_ctr #(.N(3), .SHIFT(2)) u_main (
        .clk (clk), .rst_n (rst_n), .latch (latch), .ev (ev), .value (value)
    );

    // SHIFT=0 instance used by T5 to reach the 16-bit ceiling quickly.
    reg         latch0 = 0;
    reg         ev0    = 0;
    wire [15:0] value0;

    dgc_perf_ctr #(.N(1), .SHIFT(0)) u_sat (
        .clk (clk), .rst_n (rst_n), .latch (latch0), .ev (ev0), .value (value0)
    );

    // ---------------------------------------------------------- reference model
    integer cnt [0:2];
    integer pub [0:2];
    integer m;

    always @(posedge clk) begin
        for (m = 0; m < 3; m = m + 1) begin
            if (latch) begin
                pub[m] <= (cnt[m] + ev[m]) >> 2;
                cnt[m] <= 0;
            end
            else if (ev[m]) begin
                cnt[m] <= cnt[m] + 1;
            end
        end
    end

    task pulse_latch;
        begin
            @(negedge clk) latch = 1'b1;
            @(negedge clk) latch = 1'b0;
            @(negedge clk);
        end
    endtask

    task check_value(input [8*8-1:0] tag);
        integer k;
        begin
            for (k = 0; k < 3; k = k + 1) begin
                if (value[k*16 +: 16] !== pub[k][15:0]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: %0s counter %0d = %0d, model %0d (cnt was %0d)",
                             tag, k, value[k*16 +: 16], pub[k], cnt[k]);
                end
            end
        end
    endtask

    integer i, n, seed, before;
    integer fail_base;

    initial begin
        for (i = 0; i < 3; i = i + 1) begin cnt[i] = 0; pub[i] = 0; end
        seed = 32'h1029_1030;

        rst_n = 0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        // ---------------------------------------------------------------- T1
        if (value !== 48'd0) `DGC_FAIL("T1 reset did not publish zero")
        if (value0 !== 16'd0) `DGC_FAIL("T1 reset did not publish zero (sat instance)")
        $display("TEST_INFO: T1 reset publishes zero");

        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---------------------------------------------------------------- T2
        // 40 cycles with only counters 0 and 2 enabled: 40>>2 = 10, 0, 10.
        @(negedge clk) ev = 3'b101;
        repeat (40) @(negedge clk);
        pulse_latch();
        check_value("T2");
        if (value[15:0] !== 16'd10 || value[31:16] !== 16'd0 || value[47:32] !== 16'd10)
            `DGC_FAIL("T2 expected 10/0/10 with SHIFT=2 after 40 cycles")
        $display("TEST_INFO: T2 40 cycles of ev=101 published 10/0/10");

        // ---------------------------------------------------------------- T3
        // Keep counting with a different pattern; the published value must stay
        // frozen until the next latch.
        @(negedge clk) ev = 3'b111;
        repeat (7) @(negedge clk);
        if (value[15:0] !== 16'd10) `DGC_FAIL("T3 published value moved between latches")
        pulse_latch();
        // 7 counted cycles + 1 latch-cycle event, then >>2 = (7+1)>>2 = 2
        check_value("T3");
        if (value[15:0] !== 16'd2) `DGC_FAIL("T3 expected 2 after 8 counted cycles")
        $display("TEST_INFO: T3 value frozen between latches, then (7+1)>>2 = 2");

        // ---------------------------------------------------------------- T4
        // Random intervals. Every counter is checked against the model each time.
        fail_base = dgc_errors;
        for (n = 0; n < 64; n = n + 1) begin
            @(negedge clk) ev = $random(seed);
            i = ({$random(seed)} % 40) + 1;     // 1..40 cycles, never zero
            repeat (i) @(negedge clk);
            pulse_latch();
            check_value("T4");
        end
        if (dgc_errors == fail_base)
            $display("TEST_INFO: T4 64 random intervals matched the reference model");

        // ---------------------------------------------------------------- T5
        // 70,000 counted cycles with SHIFT=0 must publish 0xFFFF, not wrap.
        @(negedge clk) ev0 = 1'b1;
        repeat (70000) @(negedge clk);
        @(negedge clk) latch0 = 1'b1;
        @(negedge clk) latch0 = 1'b0;
        @(negedge clk);
        if (value0 !== 16'hFFFF) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: T5 expected saturation 0xFFFF, got 0x%04h", value0);
        end
        else $display("TEST_INFO: T5 70000 cycles saturate at 0xFFFF");

        if (dgc_errors == 0) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d", dgc_errors);
        $finish;
    end

    // A stuck simulation would otherwise only be caught by the runner timeout.
    initial begin
        #2_000_000;
        dgc_errors = dgc_errors + 1;
        $display("TEST_FAIL: timeout: simulation did not finish");
        $finish;
    end

endmodule
