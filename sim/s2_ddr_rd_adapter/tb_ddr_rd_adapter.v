//-----------------------------------------------------------------------------
// tb_ddr_rd_adapter.v - native read channel + read FIFO + occupancy credit
//
// The real 256x1024 asynchronous read FIFO and the real read-port wrapper are
// used, with a native simplified-AXI slave model on the other side, so the whole
// path is exercised: request -> AR -> returned beats -> FIFO -> processing side.
//
//   R1  ten short rows: AR fields checked, all beats arrive in order
//   R2  a row that crosses a 4 KiB Column boundary: ddr_fetch splits it, the
//       slave sees two requests, the beat stream is unchanged
//   R3  the processing side stops popping: the credit must stop accepting rows
//       before the FIFO overflows; after the consumer resumes everything still
//       arrives exactly once and in order
//   R4  random arready / r gaps throughout: same checks
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_ddr_rd_adapter;
    integer dgc_errors = 0;
    reg ddr_clk = 0;  always #(`DGC_T_DDR) ddr_clk = ~ddr_clk;
    reg proc_clk = 0; always #(`DGC_T_PROC) proc_clk = ~proc_clk;
    reg rst_n = 0;
    wire rst = ~rst_n;
    `DGC_GRS_INST

    // ------------------------------------------------------------- DUT nets
    reg         row_valid = 0;
    wire        row_ready;
    reg  [31:0] row_addr = 0;
    reg  [4:0]  row_beats = 0;

    wire [27:0] ar_addr;
    wire [3:0]  ar_len;
    wire        ar_valid;
    reg         ar_ready = 1;

    reg  [255:0] r_data = 0;
    reg          r_valid = 0;
    reg          r_last = 0;
    wire [3:0]   r_id = 4'd0;
    wire         fifo_full;
    wire         fifo_wr;
    wire [255:0] fifo_data;

    wire busy, halt, credit_bad;
    wire [31:0] cnt_err, cnt_beats, cnt_rows;
    wire [10:0] wr_level;

    reg  [11:0] rd_beats_gray = 0;

    // ------------------------------------------------------------- read FIFO
    wire         fifo_rd_empty;
    wire [255:0] fifo_rd_data;
    wire         fifo_pop;
    wire         fifo_almost_full, fifo_almost_empty;
    wire [10:0]  fifo_wl, fifo_rl;

    ddr_read_fifo u_fifo (
        .wr_clk (ddr_clk), .wr_rst (rst),
        .wr_en (fifo_wr), .wr_data (fifo_data),
        .wr_full (fifo_full), .wr_water_level (fifo_wl),
        .rd_clk (proc_clk), .rd_rst (rst),
        .rd_en (fifo_pop), .rd_data (fifo_rd_data),
        .almost_full (fifo_almost_full), .rd_empty (fifo_rd_empty),
        .rd_water_level (fifo_rl), .almost_empty (fifo_almost_empty)
    );

    reg         pause_pop = 0;
    wire        port_rd_ready;
    wire        port_out_valid;
    wire [255:0] port_out_data;
    wire        pop_req = port_rd_ready & ~pause_pop;

    dgc_fifo_rd_port #(.DATA_W(256)) u_port (
        .clk (proc_clk), .rst_n (rst_n),
        .rd_fire (pop_req), .rd_ready (port_rd_ready),
        .fifo_empty (fifo_rd_empty), .fifo_pop (fifo_pop), .fifo_data (fifo_rd_data),
        .out_valid (port_out_valid), .out_ready (1'b1), .out_data (port_out_data)
    );

    dgc_ddr_rd_adapter u_dut (
        .clk (ddr_clk), .rst_n (rst_n),
        .row_valid (row_valid), .row_ready (row_ready),
        .row_addr (row_addr), .row_beats (row_beats),
        .rd_beats_gray (rd_beats_gray),
        .ar_addr (ar_addr), .ar_len (ar_len),
        .ar_valid (ar_valid), .ar_ready (ar_ready),
        .r_data (r_data), .r_valid (r_valid), .r_last (r_last), .r_id (r_id),
        .fifo_full (fifo_full), .fifo_wr (fifo_wr), .fifo_data (fifo_data),
        .busy (busy), .halt (halt), .credit_bad (credit_bad),
        .cnt_err (cnt_err), .cnt_beats (cnt_beats), .cnt_rows (cnt_rows),
        .wr_level (wr_level), .job_restart (1'b0)
    );

    // ------------------------------------------------------------- expected queue
    localparam integer QN = 4096;
    reg [31:0] exp_addr [0:QN-1];
    integer q_wp = 0, q_rp = 0;

    function [255:0] pattern(input [31:0] byte_addr);
        begin
            pattern = {224'd0, 32'hA000_0000 + (byte_addr >> 5)};
        end
    endfunction

    // ------------------------------------------------------------- row feeder
    // A free-running feeder, so that the stimulus never blocks the initial block
    // (that would deadlock when the credit correctly stops accepting rows).
    reg [31:0] f_addr  [0:511];
    reg [4:0]  f_beats [0:511];
    integer    f_n = 0, f_wp = 0;

    task add_row(input [31:0] a, input [4:0] b);
        begin
            f_addr[f_n] = a;
            f_beats[f_n] = b;
            f_n = f_n + 1;
        end
    endtask

    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n) begin
            row_valid <= 0;
        end
        else begin
            if (row_valid && row_ready) begin
                // accepted: queue the expected beats and present the next row
                begin : exp_push
                    integer k;
                    for (k = 0; k < row_beats; k = k + 1) begin
                        exp_addr[q_wp] = row_addr + k * 32;
                        q_wp = q_wp + 1;
                    end
                end
                if (f_wp < f_n) begin
                    row_addr  <= f_addr[f_wp];
                    row_beats <= f_beats[f_wp];
                    f_wp <= f_wp + 1;
                    row_valid <= 1'b1;
                end
                else begin
                    row_valid <= 1'b0;
                end
            end
            else if (!row_valid && (f_wp < f_n)) begin
                row_addr  <= f_addr[f_wp];
                row_beats <= f_beats[f_wp];
                f_wp <= f_wp + 1;
                row_valid <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------- native slave
    localparam [1:0] SL_IDLE = 2'd0, SL_WAIT = 2'd1, SL_SEND = 2'd2;
    reg [1:0]  sl_state;
    reg [27:0] sl_addr;
    reg [4:0]  sl_len;
    reg [5:0]  sl_idx;
    integer    sl_delay;
    integer    seed = 32'h51A7_E123;
    reg        bp_en = 1'b1;
    integer    n_ar = 0;
    // 2026-10-30 route A: the slave must model a real AXI slave, which accepts
    // ARs while it is still returning another request's data. Requests go into
    // an 8-deep queue and are served in order.
    reg [27:0] sa_addr [0:15];
    reg [4:0]  sa_len  [0:15];
    reg [3:0]  sa_wp = 0, sa_rp = 0, sa_cnt = 0;
    wire ar_take = ar_valid && ar_ready;

    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n) begin
            sl_state <= SL_IDLE;
            r_valid <= 0; r_last <= 0; r_data <= 0;
            sl_addr <= 0; sl_len <= 0; sl_idx <= 0; sl_delay <= 0;
        end
        else begin
            if (ar_take) begin
                sa_addr[sa_wp] <= ar_addr;
                sa_len[sa_wp]  <= ar_len;
                sa_wp <= (sa_wp == 4'd15) ? 4'd0 : sa_wp + 4'd1;
                n_ar = n_ar + 1;
                if (((ar_addr << 2) & 32'hFFF) + ((ar_len + 1) * 32) > 4096) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: AR at %08h len %0d crosses a 4 KiB boundary",
                             ar_addr << 2, ar_len + 1);
                end
            end
            case (sl_state)
                SL_IDLE: begin
                    r_valid <= 0; r_last <= 0;
                    if (sa_cnt != 0) begin
                        sl_addr  <= sa_addr[sa_rp];
                        sl_len   <= sa_len[sa_rp];
                        sa_rp <= (sa_rp == 4'd15) ? 4'd0 : sa_rp + 4'd1;
                        sl_idx   <= 0;
                        sl_delay <= 4 + (($random(seed) % 6) + 6) % 6;
                        sl_state <= SL_WAIT;
                    end
                end
                SL_WAIT: begin
                    if (sl_delay > 0) sl_delay <= sl_delay - 1;
                    else begin
                        r_valid <= 1'b1;
                        r_last  <= (sl_len == 5'd0);
                        r_data  <= pattern({sl_addr, 2'b00});
                        sl_idx  <= 0;
                        sl_state <= (sl_len == 5'd0) ? SL_IDLE : SL_SEND;
                    end
                end
                SL_SEND: begin
                    if (r_valid) begin
                        // The beat presented during this cycle is accepted (the IP
                        // never back-pressures). Advance, and decide whether the
                        // next beat appears immediately or after a bubble. A beat
                        // must never be presented for two acceptance cycles: the
                        // first version dropped r_valid in the same edge it had
                        // already been accepted, so the beat was sent twice.
                        r_valid <= 1'b0;
                        if (sl_idx == sl_len) begin
                            r_last   <= 1'b0;
                            sl_state <= SL_IDLE;
                        end
                        else begin
                            sl_idx <= sl_idx + 1;
                            if (bp_en && (({$random(seed)} % 100) < 12)) begin
                                // bubble: next cycle no beat
                            end
                            else begin
                                r_data  <= pattern({sl_addr, 2'b00} + (sl_idx + 1) * 32);
                                r_last  <= ((sl_idx + 1) == sl_len);
                                r_valid <= 1'b1;
                            end
                        end
                    end
                    else begin
                        // resume after a bubble: prepare and present beat sl_idx
                        r_data  <= pattern({sl_addr, 2'b00} + sl_idx * 32);
                        r_last  <= (sl_idx == sl_len);
                        r_valid <= 1'b1;
                    end
                end
            endcase

            // one combined update: push and pop can happen in the same cycle
            sa_cnt <= sa_cnt + (ar_take ? 4'd1 : 4'd0)
                             - (((sl_state == SL_IDLE) && (sa_cnt != 0)) ? 4'd1 : 4'd0);
            // a real AXI slave back-pressures AR when its request queue is full
            if (sa_cnt >= 4'd13) ar_ready <= 1'b0;
            else if (bp_en) ar_ready <= (({$random(seed)} % 100) >= 20);
            else       ar_ready <= 1'b1;
        end
    end

    // ------------------------------------------------------------- proc consumer
    reg [11:0] pop_count = 0;
    always @(posedge proc_clk or negedge rst_n) begin
        if (!rst_n) begin
            pop_count <= 12'd0;
            rd_beats_gray <= 12'd0;
        end
        else begin
            if (fifo_pop) pop_count <= pop_count + 12'd1;
            rd_beats_gray <= (pop_count >> 1) ^ pop_count;
        end
    end

    integer n_checked = 0;
    reg [255:0] exp_word;
    always @(posedge proc_clk) begin
        if (rst_n && port_out_valid) begin
            n_checked = n_checked + 1;
            if (q_rp >= q_wp) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: read beat arrived with nothing expected");
            end
            else begin
                exp_word = pattern(exp_addr[q_rp]);
                if (port_out_data !== exp_word) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 15)
                        $display("TEST_FAIL: beat %0d exp=%08h act=%08h (addr %08h)",
                                 q_rp, exp_word[31:0],
                                 port_out_data[31:0], exp_addr[q_rp]);
                end
                q_rp = q_rp + 1;
            end
        end
    end

    // ------------------------------------------------------------- helpers
    task wait_all(input integer max_cycles);
        integer guard;
        begin
            guard = 0;
            while (((q_rp != q_wp) || (f_wp != f_n) || row_valid || (u_dut.u_fetch.u_credit.o_cnt != 0)) && guard < max_cycles) begin
                @(posedge proc_clk);
                guard = guard + 1;
            end
        end
    endtask

    integer i;

    initial begin
        rst_n = 0;
        repeat (10) @(posedge ddr_clk);
        repeat (10) @(posedge proc_clk);
        rst_n = 1;
        repeat (5) @(posedge ddr_clk);

        // =============================================================== R1
        for (i = 0; i < 10; i = i + 1) add_row(32'h0000_0000 + i * 32'd256, 5'd3);
        wait_all(20000);
        if (q_rp != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R1 %0d of %0d beats arrived", q_rp, q_wp);
        end
        else $display("TEST_INFO: R1 ten 3-beat rows: AR fields and beat order exact");

        // =============================================================== R2
        add_row(32'h0000_0FC0, 5'd7);   // crosses 0x1000
        add_row(32'h0000_2000, 5'd4);
        wait_all(20000);
        if (q_rp != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R2 %0d of %0d beats arrived", q_rp, q_wp);
        end
        else $display("TEST_INFO: R2 page-crossing row was split and reassembled exactly");

        // =============================================================== R3
        // Stop the consumer and offer far more beats than the FIFO holds; the
        // credit must stop the feeder. Then resume and check every beat.
        pause_pop = 1'b1;
        for (i = 0; i < 200; i = i + 1) add_row(32'h0001_0000 + i * 32'd256, 5'd7);
        repeat (4000) @(posedge ddr_clk);
        $display("TEST_INFO: R3 while paused: rows accepted=%0d of 200, wr_level=%0d, full=%b",
                 cnt_rows, wr_level, fifo_full);
        if (cnt_rows >= 200) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R3 the credit did not stop the feeder");
        end
        if (fifo_full) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R3 the read FIFO reached full");
        end
        pause_pop = 1'b0;
        wait_all(400000);
        if (q_rp != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R3 %0d of %0d beats arrived", q_rp, q_wp); $display("R3DUMP req=%0d ret=%0d halt=%b o=%0d p=%0d rows=%0d ar=%0d", u_dut.u_fetch.req_cnt, u_dut.u_fetch.ret_cnt, u_dut.u_fetch.halted, u_dut.u_fetch.u_credit.o_cnt, u_dut.u_fetch.u_credit.p_cnt, u_dut.cnt_rows, n_ar);
        end
        else $display("TEST_INFO: R3 credit stopped the feeder, then all %0d beats arrived", q_rp);

        // =============================================================== R4
        for (i = 0; i < 20; i = i + 1) add_row(32'h0002_0000 + i * 32'd128, 5'd2 + (i[4:0] % 6));
        wait_all(100000);
        if (q_rp != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R4 %0d of %0d beats arrived", q_rp, q_wp);
        end
        else $display("TEST_INFO: R4 random arready/r gaps: all beats exact");

        if (halt) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: ddr_fetch halted"); end
        if (cnt_err != 0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: error count = %0d", cnt_err); end
        $display("TEST_INFO: rows added=%0d accepted=%0d ARs=%0d beats=%0d checked=%0d",
                 f_n, cnt_rows, n_ar, cnt_beats, n_checked);
        `DGC_FINISH
    end
endmodule






