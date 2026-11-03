//-----------------------------------------------------------------------------
// tb_coord_fifo.v - S2: coord FIFO wrapper on the real generated IP
//
// Cases
//   W1  empty FIFO: rd_ready low, no pop issued
//   W2  write 200 records, read back in order
//   W3  random consumer backpressure on the read side
//   W4  full flag: fill the FIFO to its 2048-entry limit and check wr_ready
//   W5  reset clears the FIFO and the wrapper returns to empty
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_coord_fifo;

    integer dgc_errors = 0;

    reg clk = 0;
    always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg         wr_valid = 0;
    wire        wr_ready;
    reg  [95:0] wr_data = 0;

    reg         rd_fire = 0;
    wire        rd_ready;
    wire        rd_valid;
    reg         rd_ready_o = 1;
    wire [95:0] rd_data;

    wire        full, empty;
    wire [12:0] wr_level, rd_level;

    `DGC_GRS_INST

    dgc_coord_fifo u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_valid   (wr_valid),
        .wr_ready   (wr_ready),
        .wr_data    (wr_data),
        .rd_fire    (rd_fire),
        .rd_ready   (rd_ready),
        .rd_valid   (rd_valid),
        .rd_ready_o (rd_ready_o),
        .flush      (1'b0),
        .rd_data    (rd_data),
        .full       (full),
        .empty      (empty),
        .wr_level   (wr_level),
        .rd_level   (rd_level)
    );

    // ------------------------------------------------------------- scoreboard
    localparam integer QN = 4096;
    reg [95:0] exp_q [0:QN-1];
    integer    q_wp = 0, q_rp = 0;
    integer    n_checked = 0;

    always @(posedge clk) begin
        if (rst_n && rd_valid && rd_ready_o) begin
            if (q_rp >= q_wp) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: coord fifo returned a record nobody wrote t=%0t", $time);
            end
            else begin
                if (rd_data !== exp_q[q_rp]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: coord record %0d exp=%0h act=%0h t=%0t",
                             q_rp, exp_q[q_rp], rd_data, $time);
                end
                q_rp = q_rp + 1;
                n_checked = n_checked + 1;
            end
        end
    end

    integer i, seed = 11, r;
    integer popped = 0;

    task push(input integer v);
        begin
            @(posedge clk); #0.2;
            while (!wr_ready) begin @(posedge clk); #0.2; end
            wr_valid <= 1'b1;
            wr_data  <= {64'h0, v[31:0]};
            exp_q[q_wp] = {64'h0, v[31:0]};
            q_wp = q_wp + 1;
            @(posedge clk); #0.2;
            wr_valid <= 1'b0;
        end
    endtask

    // pop one record, waiting for readiness
    task pop_once;
        begin
            @(posedge clk); #0.2;
            while (!rd_ready) begin @(posedge clk); #0.2; end
            rd_fire <= 1'b1;
            @(posedge clk); #0.2;
            rd_fire <= 1'b0;
            popped = popped + 1;
        end
    endtask

    reg bp_en = 0;

    // random consumer backpressure
    always @(posedge clk) begin
        if (bp_en) begin
            r = ({$random(seed)} % 100);
            rd_ready_o <= (r >= 30);
        end
        else rd_ready_o <= 1'b1;
    end

    // -------------------------------------------------------------------- main
    initial begin
        rst_n = 0;
        rd_ready_o = 1;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (6) @(posedge clk);

        // ================================================================== W1
        @(posedge clk); #0.2;
        if (empty !== 1'b1)   `DGC_FAIL("W1: FIFO not reported empty after reset")
        if (rd_ready !== 1'b0) `DGC_FAIL("W1: rd_ready high on an empty FIFO")
        if (full !== 1'b0)    `DGC_FAIL("W1: full set on an empty FIFO")
        $display("TEST_INFO: W1 empty FIFO refuses a pop and reports empty");

        // ================================================================== W2
        for (i = 0; i < 200; i = i + 1) push(32'h1000 + i);
        repeat (10) @(posedge clk);
        for (i = 0; i < 200; i = i + 1) pop_once;
        repeat (40) @(posedge clk);
        if (n_checked != 200) `DGC_FAIL("W2: not all records came back")
        $display("TEST_INFO: W2 200 records written and read back in order");

        // ================================================================== W3
        bp_en = 1;
        for (i = 0; i < 100; i = i + 1) push(32'h2000 + i);
        repeat (10) @(posedge clk);
        for (i = 0; i < 100; i = i + 1) pop_once;
        repeat (200) @(posedge clk);
        bp_en = 0;
        if (n_checked != 300) `DGC_FAIL("W3: backpressure lost records")
        $display("TEST_INFO: W3 100 records through random backpressure, %0d checked total", n_checked);

        // ================================================================== W4
        // drain what is left, then fill the FIFO until it reports full
        i = 0;
        while (!empty && i < 4000) begin pop_once; i = i + 1; end
        repeat (40) @(posedge clk);
        i = 0;
        @(posedge clk); #0.2;
        wr_valid <= 1'b1;
        wr_data  <= 96'hA5A5_0000_0000_0000_0001;
        while (!full && i < 4000) begin @(posedge clk); #0.2; i = i + 1; end
        if (!full) begin
            `DGC_FAIL("W4: FIFO never reported full")
        end
        else begin
            @(posedge clk); #0.2;
            if (wr_ready !== 1'b0) begin
                `DGC_FAIL("W4: wr_ready still high when full")
            end
            $display("TEST_INFO: W4 FIFO full after %0d writes, wr_ready correctly low", i);
        end
        wr_valid <= 1'b0;
        // the FIFO now holds unrecorded records; clear it with a reset
        // (W5) rather than draining, so the scoreboard stays consistent
        q_wp = 0; q_rp = 0;

        // ================================================================== W5
        rst_n = 0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        repeat (20) @(posedge clk);
        @(posedge clk); #0.2;
        if (empty !== 1'b1) `DGC_FAIL("W5: FIFO not empty after reset")
        if (full !== 1'b0)  `DGC_FAIL("W5: full still set after reset")
        $display("TEST_INFO: W5 reset clears the FIFO");

        // and it still works afterwards
        push(32'hDEAD_BEEF);
        pop_once;
        repeat (30) @(posedge clk);
        if (n_checked != 301) `DGC_FAIL("W5: wrapper unusable after reset")
        $display("TEST_INFO: W5 wrapper usable after reset");

        $display("TEST_INFO: coord fifo test finished at %0t", $time);
        `DGC_FINISH
    end

endmodule



