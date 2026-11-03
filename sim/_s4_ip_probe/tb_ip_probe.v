`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_ip_probe;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    wire rst = ~rst_n;
    `DGC_GRS_INST

    reg  [23:0] wd = 0; reg [14:0] wa = 0; reg we = 0;
    wire [23:0] q0, q1;
    reg  [14:0] ra = 0;

    out_stripe_ram u0 (.wr_data(wd), .wr_addr(wa), .wr_en(we), .wr_clk(clk), .wr_rst(rst),
                       .rd_data(q0), .rd_addr(ra), .rd_clk(clk), .rd_rst(rst));
    out_stripe_ram_1 u1 (.wr_data(wd), .wr_addr(wa), .wr_en(we), .wr_clk(clk), .wr_rst(rst),
                         .rd_data(q1), .rd_addr(ra), .rd_clk(clk), .rd_rst(rst));

    integer i;
    initial begin
        $display("TEST_INFO: start t=%0t", $time);
        rst_n = 0; repeat (10) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
        $display("TEST_INFO: reset done t=%0t", $time);
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk); we <= 1; wa <= i[14:0]; wd <= 24'hAA0000 + i;
        end
        @(posedge clk); we <= 0;
        repeat (5) @(posedge clk);
        $display("TEST_INFO: wrote 64 t=%0t", $time);
        ra <= 15'd10;
        repeat (6) @(posedge clk);
        $display("TEST_INFO: read bank0 addr10 = %06h (expect aa000a) t=%0t", q0, $time);
        $display("TEST_INFO: read bank1 addr10 = %06h (expect aa000a) t=%0t", q1, $time);
        $display("TEST_INFO: done");
        `DGC_FINISH
    end
endmodule
