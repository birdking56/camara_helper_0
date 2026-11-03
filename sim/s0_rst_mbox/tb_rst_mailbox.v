//-----------------------------------------------------------------------------
// tb_rst_mailbox.v - S0 acceptance: reset synchroniser and cross-domain mailbox
//
//   Reset synchroniser
//     S1  asynchronous assertion: output falls with no clock edge
//     S2  release takes exactly STAGES clock edges
//     S3  an asynchronous pulse shorter than one clock period still resets
//
//   Mailbox  (DDR domain 125 MHz  <->  process domain 225 MHz)
//     M1  one descriptor: correct payload, latency measured
//     M2  eight descriptors back to back: order preserved, no loss, no duplicate
//     M3  destination stall: source must be held off (src_ready low) and the
//         payload must not move while the request is outstanding
//     M4  reverse direction (process -> DDR) to prove both directions work
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_rst_mailbox;

    integer dgc_errors = 0;

    reg proc_clk = 0;  always #(`DGC_T_PROC) proc_clk = ~proc_clk;
    reg ddr_clk  = 0;  always #(`DGC_T_DDR ) ddr_clk  = ~ddr_clk;
    reg cfg_clk  = 0;  always #(`DGC_T_CFG ) cfg_clk  = ~cfg_clk;

    integer pcyc = 0;
    always @(posedge proc_clk) pcyc <= pcyc + 1;

    // ======================================================= reset synchroniser
    reg  s_async_n;

    wire rst_proc_n, rst_ddr_n, rst_cfg_n;

    dgc_rst_sync #(.STAGES(3)) u_rst_proc (.clk (proc_clk), .rst_async_n (s_async_n), .rst_n (rst_proc_n));
    dgc_rst_sync #(.STAGES(3)) u_rst_ddr  (.clk (ddr_clk ), .rst_async_n (s_async_n), .rst_n (rst_ddr_n ));
    dgc_rst_sync #(.STAGES(3)) u_rst_cfg  (.clk (cfg_clk ), .rst_async_n (s_async_n), .rst_n (rst_cfg_n ));

    // =================================================================== mailbox
    reg  [63:0] m_src_data = 0;
    reg         m_src_valid = 0;
    wire        m_src_ready;
    wire        m_dst_valid;
    reg         m_dst_ready = 0;
    wire [63:0] m_dst_data;

    // DDR domain -> process domain
    dgc_mailbox #(.W(64)) u_mbox_fwd (
        .src_clk   (ddr_clk),
        .rst_src_n (rst_ddr_n),
        .src_valid (m_src_valid),
        .src_ready (m_src_ready),
        .src_data  (m_src_data),
        .dst_clk   (proc_clk),
        .rst_dst_n (rst_proc_n),
        .dst_valid (m_dst_valid),
        .dst_ready (m_dst_ready),
        .dst_data  (m_dst_data)
    );

    // process domain -> DDR domain
    reg  [63:0] r_src_data = 0;
    reg         r_src_valid = 0;
    wire        r_src_ready;
    wire        r_dst_valid;
    reg         r_dst_ready = 0;
    wire [63:0] r_dst_data;

    dgc_mailbox #(.W(64)) u_mbox_rev (
        .src_clk   (proc_clk),
        .rst_src_n (rst_proc_n),
        .src_valid (r_src_valid),
        .src_ready (r_src_ready),
        .src_data  (r_src_data),
        .dst_clk   (ddr_clk),
        .rst_dst_n (rst_ddr_n),
        .dst_valid (r_dst_valid),
        .dst_ready (r_dst_ready),
        .dst_data  (r_dst_data)
    );

    // -------------------------------------------------------------- scoreboards
    localparam integer QMAX = 32;
    reg [63:0] exp_q [0:QMAX-1];
    integer    exp_wr, exp_rd;
    reg [63:0] rexp_q [0:QMAX-1];
    integer    rexp_wr, rexp_rd;

    always @(posedge proc_clk) begin
        if (rst_proc_n && m_dst_valid && m_dst_ready) begin
            if (exp_rd >= exp_wr) `DGC_FAIL("mailbox FWD delivered an unexpected descriptor")
            else begin
                if (m_dst_data !== exp_q[exp_rd]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: mailbox FWD desc %0d exp=%0h act=%0h t=%0t",
                             exp_rd, exp_q[exp_rd], m_dst_data, $time);
                end
                exp_rd = exp_rd + 1;
            end
        end
    end

    always @(posedge ddr_clk) begin
        if (rst_ddr_n && r_dst_valid && r_dst_ready) begin
            if (rexp_rd >= rexp_wr) `DGC_FAIL("mailbox REV delivered an unexpected descriptor")
            else begin
                if (r_dst_data !== rexp_q[rexp_rd]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: mailbox REV desc %0d exp=%0h act=%0h t=%0t",
                             rexp_rd, rexp_q[rexp_rd], r_dst_data, $time);
                end
                rexp_rd = rexp_rd + 1;
            end
        end
    end

    integer i, k, c0;

    // -------------------------------------------------------------- send tasks
    task mbox_send(input [63:0] d);
        begin
            @(posedge ddr_clk); #0.2;
            while (!m_src_ready) begin @(posedge ddr_clk); #0.2; end
            m_src_valid <= 1'b1;
            m_src_data  <= d;
            exp_q[exp_wr] = d;
            exp_wr = exp_wr + 1;
            @(posedge ddr_clk); #0.2;
            m_src_valid <= 1'b0;
        end
    endtask

    task mbox_send_rev(input [63:0] d);
        begin
            @(posedge proc_clk); #0.2;
            while (!r_src_ready) begin @(posedge proc_clk); #0.2; end
            r_src_valid <= 1'b1;
            r_src_data  <= d;
            rexp_q[rexp_wr] = d;
            rexp_wr = rexp_wr + 1;
            @(posedge proc_clk); #0.2;
            r_src_valid <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------------- main
    initial begin
        exp_wr = 0; exp_rd = 0; rexp_wr = 0; rexp_rd = 0;
        s_async_n = 0;
        m_dst_ready = 0;
        r_dst_ready = 0;

        // ================================================================ S1
        // asynchronous assertion must not need a clock edge
        #1.0;
        s_async_n = 1'b0;                       // already low from time 0
        #0.5;
        if (rst_proc_n !== 1'b0) `DGC_FAIL("S1: proc reset not asserted asynchronously")
        s_async_n = 1;
        #0.1;
        if (rst_proc_n !== 1'b0) `DGC_FAIL("S1: reset released without a clock edge")

        // ================================================================ S2
        // release takes exactly STAGES proc clock edges
        c0 = pcyc;
        while (rst_proc_n !== 1'b1) @(posedge proc_clk);
        $display("TEST_INFO: S2 proc reset released after %0d clock edges (expected 3)", pcyc - c0);
        if ((pcyc - c0) != 3) `DGC_FAIL("S2: release depth mismatch")
        // the slow 10 MHz configuration domain needs its own three edges
        k = 0;
        while ((rst_cfg_n !== 1'b1 || rst_ddr_n !== 1'b1) && k < 200) begin
            @(posedge proc_clk); k = k + 1;
        end
        if (rst_cfg_n !== 1'b1 || rst_ddr_n !== 1'b1) `DGC_FAIL("S2: other domains not released")
        else $display("TEST_INFO: S2 all three domains released after %0d proc cycles", k);

        repeat (8) @(posedge proc_clk);

        // ================================================================ S3
        // asynchronous pulse shorter than one clock period must still reset
        s_async_n = 0;
        #0.4;
        s_async_n = 1;
        if (rst_proc_n !== 1'b0) `DGC_FAIL("S3: short asynchronous pulse not captured")
        while (rst_proc_n !== 1'b1) @(posedge proc_clk);
        repeat (6) @(posedge proc_clk);
        $display("TEST_INFO: S1..S3 reset synchroniser behaviour verified");

        // ================================================================ M1
        m_dst_ready = 1;
        @(posedge ddr_clk); #0.2;
        c0 = pcyc;
        mbox_send(64'h0000_0000_0000_00A5);
        while (exp_rd < 1) @(posedge proc_clk);
        $display("TEST_INFO: M1 mailbox forward latency = %0d proc cycles", pcyc - c0);
        repeat (4) @(posedge proc_clk);

        // ================================================================ M2
        for (i = 0; i < 8; i = i + 1)
            mbox_send(64'h1111_0000_0000_0000 | i[63:0]);
        repeat (20) @(posedge proc_clk);
        if (exp_rd != 9) `DGC_FAIL("M2: not all forward descriptors arrived")
        else $display("TEST_INFO: M2 mailbox forward 9 descriptors in order, none lost");

        // ================================================================ M3
        // destination stall: source must be held off and the payload must hold
        m_dst_ready = 0;
        @(posedge ddr_clk); #0.2;
        while (!m_src_ready) begin @(posedge ddr_clk); #0.2; end
        m_src_valid <= 1'b1;
        m_src_data  <= 64'hDEAD_BEEF_0000_0001;
        exp_q[exp_wr] = 64'hDEAD_BEEF_0000_0001;
        exp_wr = exp_wr + 1;
        @(posedge ddr_clk); #0.2;
        m_src_valid <= 1'b0;
        @(posedge ddr_clk); #0.2;
        @(posedge ddr_clk); #0.2;
        if (m_src_ready !== 1'b0) `DGC_FAIL("M3: source not held off while destination stalled")
        // hold the stall for a while; the payload must not move
        repeat (20) @(posedge proc_clk);
        if (m_dst_data !== 64'hDEAD_BEEF_0000_0001) `DGC_FAIL("M3: payload moved during stall")
        m_dst_ready = 1;
        repeat (8) @(posedge proc_clk);
        if (exp_rd != 10) `DGC_FAIL("M3: stalled descriptor lost")
        else $display("TEST_INFO: M3 mailbox backpressure and payload stability verified");

        // ================================================================ M4
        // reverse direction
        r_dst_ready = 1;
        for (i = 0; i < 6; i = i + 1)
            mbox_send_rev(64'h2222_0000_0000_0000 | i[63:0]);
        repeat (20) @(posedge ddr_clk);
        if (rexp_rd != 6) `DGC_FAIL("M4: reverse descriptors lost")
        else $display("TEST_INFO: M4 mailbox reverse direction 6 descriptors in order");

        // ================================================================ reset both ends
        s_async_n = 0;
        #0.5;
        if (m_src_ready !== 1'b1) `DGC_FAIL("reset did not return the mailbox to idle")
        s_async_n = 1;
        repeat (10) @(posedge proc_clk);

        `DGC_FINISH
    end

endmodule
