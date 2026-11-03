`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_stripe_scan;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_VOUT) clk = ~clk;
    reg rst_n = 0;

    reg         start = 0;
    reg  [6:0]  stripe_id = 0;
    reg  [4:0]  valid_lines = 16;
    wire [14:0] slot_addr;
    wire [10:0] dst_x, dst_y;
    wire        de, active, done;

    dgc_stripe_scan u_dut (.clk(clk), .rst_n(rst_n), .start(start),
        .stripe_id(stripe_id), .valid_lines(valid_lines),
        .slot_addr(slot_addr), .dst_x(dst_x), .dst_y(dst_y),
        .de(de), .active(active), .done(done));

    integer n = 0, exp_x, exp_y, exp_ly;
    integer errs_local = 0;

    always @(posedge clk) begin
        if (rst_n && de) begin
            exp_ly = n / 1920;
            exp_x  = n % 1920;
            exp_y  = stripe_id * 16 + exp_ly;
            if (dst_x !== exp_x[10:0] || dst_y !== exp_y[10:0]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8)
                $display("TEST_FAIL: S dot %0d exp (%0d,%0d) act (%0d,%0d)", n, exp_x, exp_y, dst_x, dst_y);
            end
            if (slot_addr !== {exp_ly[3:0], exp_x[10:0]}) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8)
                $display("TEST_FAIL: S addr dot %0d exp %04h act %04h", n, {exp_ly[3:0], exp_x[10:0]}, slot_addr);
            end
            n = n + 1;
        end
    end

    task run_stripe(input [6:0] sid, input [4:0] lines, input integer expect_pixels);
        integer i;
        begin
            n = 0;
            stripe_id = sid; valid_lines = lines;
            @(posedge clk); #0.2; start <= 1'b1;
            @(posedge clk); #0.2; start <= 1'b0;
            i = 0;
            while (n < expect_pixels && i < expect_pixels + 100) begin @(posedge clk); i = i + 1; end
            repeat (6) @(posedge clk);
            if (n != expect_pixels) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: S stripe %0d expected %0d pixels, emitted %0d", sid, expect_pixels, n);
            end
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (6) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        run_stripe(7'd0, 5'd16, 30720);
        $display("TEST_INFO: S1 stripe 0 scanned 30720 pixels at addresses {ly[3:0],x[10:0]}");
        run_stripe(7'd67, 5'd8, 15360);
        $display("TEST_INFO: S2 stripe 67 scanned 15360 pixels, 8 lines");
        run_stripe(7'd5, 5'd16, 30720);
        $display("TEST_INFO: S3 stripe 5 base y = 80 checked");
        if (dgc_errors == 0)
            $display("TEST_INFO: S every address and coordinate matched the expected raster");
        `DGC_FINISH
    end
endmodule
