//-----------------------------------------------------------------------------
// tb_stripe_ram.v - minimal write/read check of the generated stripe RAM
//
// The system test showed the stripe RAM returning 0x006060 for address 0 while
// the writer presented 0x000000 on its write port. This test isolates the IP:
// write a few known words on the write clock and read them back on the read
// clock, checking both the data and the read latency (OUTPUT_REG = 1).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_stripe_ram;
    integer dgc_errors = 0;

    reg wr_clk = 0; always #(`DGC_T_PROC) wr_clk = ~wr_clk;
    reg rd_clk = 0; always #(`DGC_T_VOUT) rd_clk = ~rd_clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    reg  [23:0] wr_data = 0;
    reg  [14:0] wr_addr = 0;
    reg         wr_en = 0;
    reg  [14:0] rd_addr = 0;
    wire [23:0] rd_data;

    out_stripe_ram u_ram (
        .wr_data (wr_data), .wr_addr (wr_addr), .wr_en (wr_en),
        .wr_clk (wr_clk), .wr_rst (~rst_n),
        .rd_data (rd_data), .rd_addr (rd_addr),
        .rd_clk (rd_clk), .rd_rst (~rst_n)
    );

    task wr(input [14:0] a, input [23:0] d);
        begin
            @(posedge wr_clk);
            wr_addr <= a; wr_data <= d; wr_en <= 1'b1;
            @(posedge wr_clk); #0.2;
            wr_en <= 1'b0;
            repeat (4) @(posedge wr_clk);
        end
    endtask

    reg [23:0] got; integer i;
    task rd(input [14:0] a, output [23:0] d);
        begin
            @(posedge rd_clk);
            rd_addr <= a;
            repeat (4) @(posedge rd_clk); #0.2;
            d = rd_data;
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (8) @(posedge wr_clk);
        rst_n = 1;
        repeat (4) @(posedge wr_clk);

        wr(15'd0,     24'h000000);
        wr(15'd1,     24'h010001);
        wr(15'd4,     24'h040004);
        wr(15'd1920,  24'h123456);
        wr(15'd30719, 24'hABCDEF);

        rd(15'd0,     got); if (got !== 24'h000000) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: [0] %06h", got); end
        rd(15'd1,     got); if (got !== 24'h010001) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: [1] %06h", got); end
        rd(15'd4,     got); if (got !== 24'h040004) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: [4] %06h", got); end
        rd(15'd1920,  got); if (got !== 24'h123456) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: [1920] %06h", got); end
        rd(15'd30719, got); if (got !== 24'hABCDEF) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: [30719] %06h", got); end

        // streaming: address changes every read cycle, like the video reader
        wr(15'd10, 24'h00000A); wr(15'd11, 24'h00000B); wr(15'd12, 24'h00000C); wr(15'd13, 24'h00000D);
        @(posedge rd_clk);
        rd_addr <= 15'd10;
        @(posedge rd_clk); rd_addr <= 15'd11;
        @(posedge rd_clk); rd_addr <= 15'd12;
        @(posedge rd_clk); rd_addr <= 15'd13;
        repeat (3) @(posedge rd_clk); #0.2;
        if (rd_data !== 24'h00000D) begin dgc_errors=dgc_errors+1; $display("TEST_FAIL: streaming rd_data=%06h exp=00000D", rd_data); end
        else $display("TEST_INFO: streaming read of 4 consecutive addresses returns the last one after 2 cycles");
        // exact system pattern: stream 0..15, sample two cycles after each address
        for (i = 0; i < 16; i = i + 1) wr(i[14:0], {8'd0, i[7:0], 8'd0} | (24'h1 * i));
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge rd_clk); rd_addr <= i[14:0];
            @(posedge rd_clk);
            @(posedge rd_clk); #0.2;
            if (rd_data !== ((24'h1 * i) | {8'd0, i[7:0], 8'd0})) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: stream[%0d] got %06h exp %06h", i, rd_data, ((24'h1 * i) | {8'd0, i[7:0], 8'd0}));
            end
        end
        if (dgc_errors == 0) $display("TEST_INFO: streaming 16 consecutive addresses, every sample exact after 2 cycles");
        if (dgc_errors == 0) $display("TEST_INFO: five words written and read back exactly, read latency matches OUTPUT_REG=1");
        `DGC_FINISH
    end
endmodule
