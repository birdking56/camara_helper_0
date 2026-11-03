//-----------------------------------------------------------------------------
// tb_ddr_fetch.v - straight-line flow driven by the state machine, not by counts
// Waiting on a fixed repeat(N) was what broke the earlier attempt; every step here
// waits for the state it needs before acting.
//   G1  single 3-beat row: reserve, one request, araddr/arlen, back to IDLE
//   G2  crossing row: 1 beat then 3 beats at the next page
//   G3  early rlast halts and counts
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_ddr_fetch;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_DDR) clk = ~clk;
    reg rst_n = 0;
    reg row_valid = 0; wire row_ready;
    reg [31:0] aligned_addr = 0; reg [4:0] beats = 0; reg [10:0] wr_level = 0;
    wire ar_valid; reg ar_ready = 0; wire [27:0] ar_addr; wire [3:0] ar_len;
    reg r_valid = 0, r_last = 0; reg [3:0] r_id = 0; wire r_taken;
    wire busy, halt; wire [31:0] cnt_err; reg job_restart = 0;

    dgc_ddr_fetch u_dut (.clk(clk), .rst_n(rst_n), .row_valid(row_valid),
        .row_ready(row_ready), .aligned_addr(aligned_addr), .beats(beats),
        .wr_level(wr_level), .ar_valid(ar_valid), .ar_ready(ar_ready),
        .ar_addr(ar_addr), .ar_len(ar_len), .r_valid(r_valid), .r_last(r_last),
        .r_id(r_id), .r_taken(r_taken), .busy(busy), .halt(halt),
        .cnt_err(cnt_err), .job_restart(job_restart));

    integer n_ar = 0;
    reg [27:0] a1 = 0, a2 = 0; reg [3:0] l1 = 0, l2 = 0;
    always @(posedge clk) if (rst_n && ar_valid && ar_ready) begin
        n_ar = n_ar + 1;
        if (n_ar == 1) begin a1 = ar_addr; l1 = ar_len; end
        else           begin a2 = ar_addr; l2 = ar_len; end
    end

    task wait_st(input [2:0] want);
        integer k; begin
            k = 0;
            while (u_dut.st !== want && k < 100) begin @(posedge clk); #0.2; k = k + 1; end
            if (u_dut.st !== want) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: state stuck, wanted %0d got %0d", want, u_dut.st);
            end
        end
    endtask

    task start_row(input [31:0] addr, input [4:0] nb);
        begin
            @(posedge clk); #0.2;
            aligned_addr <= addr; beats <= nb; row_valid <= 1'b1;
            @(posedge clk); #0.2; row_valid <= 1'b0;
        end
    endtask

    task beat(input last);
        begin
            @(posedge clk); #0.2;
            r_valid <= 1'b1; r_last <= last;
            @(posedge clk); #0.2;
            r_valid <= 1'b0; r_last <= 1'b0;
        end
    endtask

    initial begin
        rst_n = 0; ar_ready = 1;
        repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // ============================================================== G1
        start_row(32'h0100_0040, 5'd3);
        wait_st(3'd2);                       // AR
        if (ar_len !== 4'd2) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G1 arlen exp=2 act=%0d", ar_len); end
        wait_st(3'd3);                       // WAIT
        beat(0); beat(0); beat(1);
        wait_st(3'd0);                       // IDLE
        if (n_ar !== 1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G1 expected 1 request, got %0d", n_ar); end
        else if (a1 !== 28'h0040_0010) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G1 araddr exp=00400010 act=%07h", a1); end
        else $display("TEST_INFO: G1 single row: 1 request, araddr=%07h arlen=%0d", a1, l1);

        // ============================================================== G2
        n_ar = 0;
        start_row(32'h0100_0FE0, 5'd4);      // 128 bytes from 0xFE0 crosses a page
        wait_st(3'd2);
        if (ar_len !== 4'd0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G2 first half exp 1 beat, arlen=%0d", ar_len); end
        wait_st(3'd3);
        beat(1);
        wait_st(3'd2);                       // second request
        if (ar_len !== 4'd2) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G2 second half exp 3 beats, arlen=%0d", ar_len); end
        if (ar_addr !== 28'h0040_0400) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G2 second araddr exp=00400400 act=%07h", ar_addr); end
        wait_st(3'd3);
        beat(0); beat(0); beat(1);
        wait_st(3'd0);
        if (n_ar !== 2) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G2 expected 2 requests, got %0d", n_ar); end
        else $display("TEST_INFO: G2 crossing row split into 1 + 3 beats at the next page");

        // ============================================================== G3
        job_restart = 1; @(posedge clk); #0.2; job_restart = 0;
        repeat (2) @(posedge clk);
        n_ar = 0;
        start_row(32'h0100_2000, 5'd4);
        wait_st(3'd2);
        wait_st(3'd3);
        ("TEST_INFO: G3 before the early rlast: st=%0d remaining=%0d cur_beats=%0d resv=%0d", u_dut.st, u_dut.remaining, u_dut.cur_beats, u_dut.reserve_ok);
        beat(1);                             // rlast on the first of four: early
        repeat (4) @(posedge clk);
        $display("TEST_INFO: G3 after the early rlast: st=%0d halt=%b cnt_err=%0d", u_dut.st, halt, cnt_err);
        if (!halt) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G3 an early rlast must halt"); end
        else if (cnt_err < 32'd1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G3 error not counted"); end
        else $display("TEST_INFO: G3 early rlast halts the sequencer and is counted");

        job_restart = 1; @(posedge clk); #0.2; job_restart = 0;
        repeat (2) @(posedge clk);
        if (halt) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G3 job_restart did not clear the halt"); end
        else $display("TEST_INFO: G3 job_restart clears the halt");

        `DGC_FINISH
    end
endmodule
