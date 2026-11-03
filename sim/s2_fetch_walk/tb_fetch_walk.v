//-----------------------------------------------------------------------------
// tb_fetch_walk.v
//   W1  a block of height h produces exactly h rows, 0..h-1, in order
//   W2  row_last is set only on the final row
//   W3  done pulses once per block
//   W4  height 0 produces nothing
//   W5  abort stops the walk early
//   W6  exhaustive over heights 1..64
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_fetch_walk;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    reg start = 0; reg [6:0] bbox_h = 0;
    wire row_valid; reg row_ready = 0;
    wire [5:0] local_y; wire row_last;
    wire done; wire [6:0] rows_done; reg abort = 0;

    dgc_fetch_walk u_dut (.clk(clk), .rst_n(rst_n), .start(start), .bbox_h(bbox_h),
        .row_valid(row_valid), .row_ready(row_ready), .local_y(local_y),
        .row_last(row_last), .done(done), .rows_done(rows_done), .abort(abort));

    integer seen = 0, n_done = 0, bad = 0;
    integer h, k;
    always @(posedge clk) begin
        if (rst_n && row_valid && row_ready) begin
            if (local_y !== seen[5:0]) bad = bad + 1;
            if (row_last !== ((seen == (bbox_h - 1)) ? 1'b1 : 1'b0)) bad = bad + 1;
            seen = seen + 1;
        end
        if (rst_n && done) n_done = n_done + 1;
    end

    task run_block(input [6:0] hh);
        integer g;
        begin
            seen = 0; n_done = 0; bad = 0;
            bbox_h = hh;
            @(posedge clk); #0.2; start <= 1'b1;
            @(posedge clk); #0.2; start <= 1'b0;
            g = 0;
            while (n_done == 0 && g < 200) begin @(posedge clk); #0.2; g = g + 1; end
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 0; row_ready = 1;
        repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // ============================================================== W6
        for (h = 1; h <= 64; h = h + 1) begin
            run_block(h[6:0]);
            if (seen !== h) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: W1 h=%0d emitted %0d rows", h, seen);
            end
            if (n_done !== 1) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: W3 h=%0d done count %0d", h, n_done);
            end
            if (bad !== 0) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: W1/W2 h=%0d had %0d bad rows", h, bad);
            end
        end
        $display("TEST_INFO: W1/W2/W3 heights 1..64 emit 0..h-1 in order, row_last only on the last");

        // ============================================================== W4
        run_block(7'd0);
        if (seen !== 0 || n_done !== 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W4 height 0 must produce nothing (seen=%0d done=%0d)", seen, n_done);
        end
        else $display("TEST_INFO: W4 a block of height 0 produces nothing");

        // ============================================================== W5
        seen = 0; n_done = 0;
        bbox_h = 7'd8;
        @(posedge clk); #0.2; start <= 1'b1;
        @(posedge clk); #0.2; start <= 1'b0;
        for (k = 0; k < 3; k = k + 1) begin
            @(posedge clk); #0.2;
                    end
        @(posedge clk); #0.2; abort <= 1'b1;
        @(posedge clk); #0.2; abort <= 1'b0;
        repeat (6) @(posedge clk);
        if (seen >= 8 || n_done != 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W5 abort must stop the walk (seen=%0d done=%0d)", seen, n_done);
        end
        else $display("TEST_INFO: W5 abort stops the walk early");

        `DGC_FINISH
    end
endmodule
