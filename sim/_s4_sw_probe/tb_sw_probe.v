`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_sw_probe;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    reg  [31:0] job_id = 32'h1;
    reg  [15:0] epoch  = 16'h2;
    reg         job_restart = 0;
    reg         px_valid = 0;
    wire        px_ready;
    reg  [63:0] px_data = 0;
    wire        bank0_busy, bank1_busy;
    reg         rel = 0, rel_bank = 0, rel_bad = 0;
    wire        offer_valid;
    reg         offer_ready = 1;
    wire [63:0] offer_data;
    wire [31:0] cnt_stripes, cnt_pixels;

    dgc_stripe_writer u_dut (
        .clk(clk), .rst_n(rst_n), .job_id(job_id), .config_epoch(epoch),
        .job_restart(job_restart),
        .job_abort  (1'b0),
        .px_valid(px_valid), .px_ready(px_ready), .px_data(px_data),
        .bank0_busy(bank0_busy), .bank1_busy(bank1_busy),
        .rel(rel), .release_bank(rel_bank), .release_status_bad(rel_bad),
        .offer_valid(offer_valid), .offer_ready(offer_ready), .offer_data(offer_data),
        .ram_rd_clk(clk), .ram_rd_rst_n(rst_n),
        .ram0_rd_addr(15'd0), .ram1_rd_addr(15'd0),
        .cnt_stripes_done(cnt_stripes), .cnt_pixels_written(cnt_pixels));

    integer i;
    initial begin
        $display("TEST_INFO: probe start");
        rst_n = 0; repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);
        $display("TEST_INFO: after reset px_ready=%b bank0_busy=%b bank1_busy=%b offer_valid=%b",
                 px_ready, bank0_busy, bank1_busy, offer_valid);
        $display("TEST_INFO: DUT internals ready0=%b ready1=%b writing0=%b writing1=%b cnt0=%0d",
                 u_dut.ready[0], u_dut.ready[1], u_dut.writing[0], u_dut.writing[1], u_dut.cnt[0]);
        $display("TEST_INFO: decoded in_active=%b wr_bank=%b sid=%0d dx=%0d dy=%0d",
                 u_dut.in_active, u_dut.wr_bank, u_dut.sid, u_dut.dx, u_dut.dy);
        // drive one pixel at (0,0)
        @(posedge clk); #0.2;
        px_valid <= 1'b1;
        px_data  <= {1'b0, 1'b0, 16'h0, 11'd0, 11'd0, 24'h123456};
        for (i = 0; i < 5; i = i + 1) begin
            @(posedge clk); #0.2;
            $display("TEST_INFO: cyc %0d px_ready=%b cnt0=%0d cntpix=%0d", i, px_ready, u_dut.cnt[0], cnt_pixels);
        end
        px_valid <= 1'b0;
        @(posedge clk); #0.2;
        $display("TEST_INFO: done cnt0=%0d px_ready=%b", u_dut.cnt[0], px_ready);
        `DGC_FINISH
    end
endmodule
