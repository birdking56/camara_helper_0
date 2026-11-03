`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_x;
  integer dgc_errors = 0;
  reg clk = 0; always #5 clk = ~clk;
  initial begin
    $display("TEST_INFO: step one reached");
    $display("TEST_INFO: step two reached");
    `DGC_FAIL("deliberate failure to exercise the runner")
    `DGC_FINISH
  end
endmodule
