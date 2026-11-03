//-----------------------------------------------------------------------------
// tb_ddr_fetch_err.v - early rlast must halt the sequencer
//   Isolated from the functional test: one block, one request, then a beat with
//   rlast too early. Kept separate because mixing error cases into the functional
//   testbench is what made the earlier attempt unreadable.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_ddr_fetch_err;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_DDR) clk = ~clk;
    reg rst_n = 0;
    reg row_valid = 0; wire row_ready;
    reg [31:0] aligned_addr = 0; reg [4:0] beats = 0; reg [10:0] wr_level = 0;
    wire ar_valid; reg ar_ready = 1; wire [27:0] ar_addr; wire [3:0] ar_len;
    reg r_valid = 0, r_last = 0; reg [3:0] r_id = 0; wire r_taken;
    wire busy, halt, credit_bad; wire [31:0] cnt_err; reg job_restart = 0;

    dgc_ddr_fetch u_dut (.clk(clk), .rst_n(rst_n), .row_valid(row_valid),
        .row_ready(row_ready), .aligned_addr(aligned_addr), .beats(beats),
        .wr_level(wr_level), .ar_valid(ar_valid), .ar_ready(ar_ready),
        .ar_addr(ar_addr), .ar_len(ar_len), .r_valid(r_valid), .r_last(r_last),
        .r_id(r_id), .r_taken(r_taken), .busy(busy), .halt(halt),
        .credit_bad(credit_bad), .cnt_err(cnt_err), .job_restart(job_restart));

    integer k;

    task wait_st(input [2:0] want);
        begin
            k = 0;
            while (u_dut.st !== want && k < 100) begin @(posedge clk); #0.2; k = k + 1; end
            if (u_dut.st !== want) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: wanted state %0d, got %0d", want, u_dut.st);
            end
        end
    endtask

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        @(posedge clk); #0.2;
        aligned_addr <= 32'h0100_2000; beats <= 5'd4; row_valid <= 1'b1;
        @(posedge clk); #0.2; row_valid <= 1'b0;

        wait_st(3'd2);            // AR
        $display("TEST_INFO: reached AR, ar_len=%0d remaining=%0d", ar_len, u_dut.remaining);
        wait_st(3'd3);            // WAIT
        $display("TEST_INFO: reached WAIT, remaining=%0d", u_dut.remaining);

        @(posedge clk); #0.2; r_valid <= 1'b1; r_last <= 1'b1;
        @(posedge clk); #0.2; r_valid <= 1'b0; r_last <= 1'b0;
        repeat (4) @(posedge clk);

        $display("TEST_INFO: after the early rlast: st=%0d halt=%b cnt_err=%0d", u_dut.st, halt, cnt_err);
        if (!halt) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: an early rlast must halt");
        end
        else $display("TEST_INFO: E1 early rlast halts the sequencer");

        if (cnt_err < 32'd1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E2 the error was not counted");
        end
        else $display("TEST_INFO: E2 the error is counted");

        job_restart = 1; @(posedge clk); #0.2; job_restart = 0;
        repeat (2) @(posedge clk);
        if (halt) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E3 job_restart did not clear the halt");
        end
        else $display("TEST_INFO: E3 job_restart clears the halt");
        `DGC_FINISH
    end
endmodule
