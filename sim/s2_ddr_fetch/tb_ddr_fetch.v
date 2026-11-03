//-----------------------------------------------------------------------------
// tb_ddr_fetch.v - functional path only, straight-line and state driven
//   G1  single 3-beat row: one request, araddr and arlen, back to IDLE
//   G2  crossing row: split into 1 + 3 beats, second at the next page
// The error path (an early rlast halting the sequencer) is NOT covered here and is
// recorded as unverified in docs section 12.12.
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
    wire busy, halt, credit_bad; wire [31:0] cnt_err; reg job_restart = 0;

    dgc_ddr_fetch u_dut (.clk(clk), .rst_n(rst_n), .row_valid(row_valid),
        .row_ready(row_ready), .aligned_addr(aligned_addr), .beats(beats),
        .wr_level(wr_level), .ar_valid(ar_valid), .ar_ready(ar_ready),
        .ar_addr(ar_addr), .ar_len(ar_len), .r_valid(r_valid), .r_last(r_last),
        .r_id(r_id), .r_taken(r_taken), .busy(busy), .halt(halt),
        .credit_bad(credit_bad), .cnt_err(cnt_err), .job_restart(job_restart));

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
        wait_st(3'd2);
        if (ar_len !== 4'd2) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G1 arlen exp=2 act=%0d", ar_len); end
        wait_st(3'd3);
        beat(0); beat(0); beat(1);
        wait_st(3'd0);
        if (n_ar !== 1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G1 expected 1 request, got %0d", n_ar); end
        else if (a1 !== 28'h0040_0010) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G1 araddr exp=00400010 act=%07h", a1); end
        else $display("TEST_INFO: G1 single row -> one request araddr=%07h arlen=%0d, back to IDLE", a1, l1);
        if (halt) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G1 halted unexpectedly"); end

        // ============================================================== G2
        n_ar = 0;
        start_row(32'h0100_0FE0, 5'd4);
        wait_st(3'd2);
        if (ar_len !== 4'd0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G2 first half exp 1 beat, arlen=%0d", ar_len); end
        wait_st(3'd3);
        beat(1);
        wait_st(3'd2);
        if (ar_len !== 4'd2) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G2 second half exp 3 beats, arlen=%0d", ar_len); end
        if (ar_addr !== 28'h0040_0400) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G2 second araddr exp=00400400 act=%07h", ar_addr); end
        wait_st(3'd3);
        beat(0); beat(0); beat(1);
        wait_st(3'd0);
        if (n_ar !== 2) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G2 expected 2 requests, got %0d", n_ar); end
        else $display("TEST_INFO: G2 crossing row split 1 + 3 beats at the next page");
        if (halt || credit_bad) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: G2 halted or credit flag raised"); end

        $display("TEST_INFO: G functional path verified; the error path is unverified (docs 12.12)");
        `DGC_FINISH
    end
endmodule
