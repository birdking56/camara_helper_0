`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_ip_probe_var;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    wire rst = ~rst_n;
    `DGC_GRS_INST

    reg  [23:0] wd = 0;
    reg  [14:0] wa = 0;
    reg         we = 0;
    wire [23:0] q0, q1;
    // variable read address, the way stripe_writer drives it
    reg  [14:0] ly = 0, lx = 0;
    wire [14:0] ra = {ly[3:0], lx[10:0]};

    out_stripe_ram u0 (.wr_data(wd), .wr_addr(wa), .wr_en(we), .wr_clk(clk), .wr_rst(rst),
                       .rd_data(q0), .rd_addr(ra), .rd_clk(clk), .rd_rst(rst));
    out_stripe_ram_1 u1 (.wr_data(wd), .wr_addr(wa), .wr_en(we), .wr_clk(clk), .wr_rst(rst),
                         .rd_data(q1), .rd_addr(ra), .rd_clk(clk), .rd_rst(rst));

    integer i;
    initial begin
        $display("TEST_INFO: probe_var start");
        rst_n = 0; repeat (10) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
        $display("TEST_INFO: probe_var reset done");
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk); we <= 1; wa <= i[14:0]; wd <= 24'hAA0000 + i;
        end
        @(posedge clk); we <= 0;
        repeat (5) @(posedge clk);
        $display("TEST_INFO: probe_var wrote 64");
        // advance the variable read address like a raster scan
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk);
            lx <= lx + 15'd1;
            if (lx == 15'd1919) begin lx <= 0; ly <= ly + 15'd1; end
        end
        repeat (6) @(posedge clk);
        $display("TEST_INFO: probe_var read bank0 = %06h bank1 = %06h", q0, q1);
        $display("TEST_INFO: probe_var done");
        `DGC_FINISH
    end
endmodule
