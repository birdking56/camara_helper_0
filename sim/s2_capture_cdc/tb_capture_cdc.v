//-----------------------------------------------------------------------------
// tb_capture_cdc.v - vin_clk -> ddr_clk capture beat crossing
//
// The real 288-bit asynchronous FIFO and the verified read-port wrapper are
// used. The producer runs on vin_clk, the consumer on ddr_clk.
//
//   C1  eight beats with a slow consumer: order and payload exact
//   C2  fill the FIFO with the consumer paused (wr_full must assert), then
//       drain: every accepted beat comes back exactly once, in order
//   C3  500 beats with random producer gaps and random consumer stalls
//   C4  a coordinated reset empties the path; after release it works again
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_capture_cdc;
    integer dgc_errors = 0;
    reg vin_clk = 0;  always #(`DGC_T_VIN) vin_clk = ~vin_clk;
    reg ddr_clk = 0;  always #(`DGC_T_DDR) ddr_clk = ~ddr_clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    reg  [287:0] wr_data = 0;
    reg          wr_en = 0;
    wire         wr_full;
    wire [8:0]   wr_level;

    wire         rd_valid;
    reg          rd_ready = 1;
    wire [287:0] rd_data;
    wire [31:0]  cnt_push, cnt_pop;

    dgc_capture_cdc u_dut (
        .wr_clk (vin_clk), .wr_rst_n (rst_n),
        .rd_clk (ddr_clk), .rd_rst_n (rst_n),
        .wr_data (wr_data), .wr_en (wr_en), .wr_full (wr_full), .wr_level (wr_level),
        .rd_valid (rd_valid), .rd_ready (rd_ready), .rd_data (rd_data),
        .cnt_push (cnt_push), .cnt_pop (cnt_pop)
    );

    // ------------------------------------------------------------- scoreboard
    localparam integer QN = 2048;
    reg [287:0] exp_q [0:QN-1];
    integer q_wp = 0, q_rp = 0;

    function [287:0] word(input integer n);
        begin
            word = {32'h1000_0000 + n[31:0], 224'h0, 32'h0000_0000 + n[31:0]};
        end
    endfunction

    integer n_checked = 0;
    always @(posedge ddr_clk) begin
        if (rst_n && rd_valid && rd_ready) begin
            if (q_rp >= q_wp) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: beat arrived with nothing expected");
            end
            else begin
                if (rd_data !== exp_q[q_rp]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 10)
                        $display("TEST_FAIL: beat %0d exp=%024h act=%024h", q_rp, exp_q[q_rp], rd_data);
                end
                q_rp = q_rp + 1;
                n_checked = n_checked + 1;
            end
        end
    end

    // ------------------------------------------------------------- producer
    task push(input integer n);
        begin
            @(negedge vin_clk);
            while (wr_full) @(negedge vin_clk);
            wr_data <= word(n);
            wr_en   <= 1'b1;
            exp_q[q_wp] = word(n);
            q_wp = q_wp + 1;
            @(posedge vin_clk); #0.2;
            wr_en <= 1'b0;
        end
    endtask

    integer seed = 32'hC0DE_1234;
    reg     prod_gap = 0;
    reg     cons_gap = 0;
    reg     cons_pause = 0;

    // consumer stalls
    always @(posedge ddr_clk) begin
        if (cons_pause)    rd_ready <= 1'b0;
        else if (cons_gap) rd_ready <= (({$random(seed)} % 100) >= 40);
        else               rd_ready <= 1'b1;
    end

    integer i;
    initial begin
        rst_n = 0;
        repeat (8) @(posedge vin_clk);
        repeat (8) @(posedge ddr_clk);
        rst_n = 1;
        repeat (5) @(posedge vin_clk);

        // =============================================================== C1
        for (i = 0; i < 8; i = i + 1) push(i);
        repeat (40) @(posedge ddr_clk);
        if (q_rp != 8) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: C1 %0d/8", q_rp); end
        else $display("TEST_INFO: C1 eight beats crossed vin->ddr in order");

        // =============================================================== C2
        // fill the FIFO: pause the consumer, push until wr_full
        repeat (10) @(posedge ddr_clk);
        cons_pause = 1'b1;
        begin : fill_loop
            integer k;
            for (k = 0; k < 400; k = k + 1) begin
                @(negedge vin_clk);
                if (!wr_full) begin
                    wr_data <= word(q_wp);
                    wr_en   <= 1'b1;
                    exp_q[q_wp] = word(q_wp);
                    q_wp = q_wp + 1;
                end
                else wr_en <= 1'b0;
                @(posedge vin_clk); #0.2;
                wr_en <= 1'b0;
            end
        end
        repeat (30) @(posedge vin_clk);
        $display("TEST_INFO: C2 accepted %0d beats, wr_full=%b, wr_level=%0d", q_wp, wr_full, wr_level);
        if (!wr_full) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C2 wr_full did not assert after filling the FIFO"); end
        else $display("TEST_INFO: C2 the FIFO filled and asserted wr_full");

        // resume the consumer and drain everything
        cons_pause = 1'b0;
        cons_gap = 1'b0;
        begin : drain
            integer guard;
            guard = 0;
            while ((q_rp != q_wp) && guard < 20000) begin
                @(posedge ddr_clk);
                guard = guard + 1;
            end
        end
        if (q_rp != q_wp) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C2 %0d of %0d beats arrived", q_rp, q_wp); end
        else $display("TEST_INFO: C2 all %0d beats arrived in order after the drain", q_wp);

        // =============================================================== C3
        cons_gap = 1'b1;
        prod_gap = 1'b1;
        for (i = 0; i < 500; i = i + 1) begin
            push(q_wp);
            if (({$random(seed)} % 3) == 0) repeat (2) @(posedge vin_clk);
        end
        repeat (20) @(posedge vin_clk);
        cons_gap = 1'b0;
        begin : drain2
            integer guard;
            guard = 0;
            while ((q_rp != q_wp) && guard < 20000) begin
                @(posedge ddr_clk);
                guard = guard + 1;
            end
        end
        if (q_rp != q_wp) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C3 %0d of %0d beats arrived", q_rp, q_wp); end
        else $display("TEST_INFO: C3 500 beats with random gaps and stalls, all exact");

        // =============================================================== C4
        // coordinated reset (both sides), then the path must work again
        rst_n = 0;
        repeat (5) @(posedge vin_clk);
        repeat (5) @(posedge ddr_clk);
        rst_n = 1;
        repeat (5) @(posedge vin_clk);
        q_wp = 0; q_rp = 0; n_checked = 0;
        for (i = 0; i < 4; i = i + 1) push(i);
        repeat (40) @(posedge ddr_clk);
        if (q_rp != 4) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C4 %0d/4 after reset", q_rp); end
        else $display("TEST_INFO: C4 coordinated reset cleared the path and it works again");

        $display("TEST_INFO: pushed=%0d popped=%0d checked=%0d", cnt_push, cnt_pop, n_checked);
        `DGC_FINISH
    end
endmodule
