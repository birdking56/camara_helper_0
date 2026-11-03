`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_trace;
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

    integer i;
    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
        $display("TEST_INFO: cross=%b first=%0d second=%0d saddr=%08h ok=%b",
                 u_dut.cross, u_dut.fb, u_dut.sb, u_dut.saddr, u_dut.split_ok);
        aligned_addr = 32'h0100_0FE0; beats = 5'd4;
        $display("TEST_INFO: after load: cross=%b first=%0d second=%0d saddr=%08h ok=%b",
                 u_dut.cross, u_dut.fb, u_dut.sb, u_dut.saddr, u_dut.split_ok);
        @(posedge clk); #0.2; row_valid <= 1'b1;
        @(posedge clk); #0.2; row_valid <= 1'b0;
        ar_ready <= 1'b1;
        for (i = 0; i < 12; i = i + 1) begin
            @(posedge clk); #0.2;
            $display("TEST_INFO: c%0d st=%0d arv=%b arl=%0d second=%b rem=%0d resv=%b",
                     i, u_dut.st, ar_valid, ar_len, u_dut.second, u_dut.remaining, u_dut.reserve_ok);
        end
        `DGC_FINISH
    end
endmodule
