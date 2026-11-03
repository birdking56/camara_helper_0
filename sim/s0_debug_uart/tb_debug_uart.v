//-----------------------------------------------------------------------------
// tb_debug_uart.v
//
// Directed test for the DGC3 reporter:
//   U1  the boot banner is exactly "DGC5 BOOT\\r\\n"
//   U2  eleven lines are printed with labels S I W J G K P Q R M V
//   U3  the 16 hexadecimal digits of each line equal the 44 snapshot words
//   U4  a snapshot is requested before each report (snap_start seen)
//   U5  a second report is produced on the next tick
//
// The testbench contains a real 8N1 receiver sampled at the transmitter's
// 234-clock bit period, so a byte-order, baud or framing mistake fails here.
// TICK_CYCLES is shortened to 400 so the test runs in microseconds.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_debug_uart;

    integer dgc_errors = 0;

    localparam integer BIT_CLKS = 234;   // 27e6 / 115200, truncated by the RTL

    reg clk = 0;
    always #18.5185 clk = ~clk;

    reg rst_n = 0;

    reg  [703:0] words;
    reg          snap_done;
    wire         snap_start;
    wire         uart_tx;

    integer i, k, l;
    integer snaps = 0;

    // -------------------------------------------------- fake snapshot provider
    reg [2:0] waitc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            waitc     <= 3'd0;
            snap_done <= 1'b0;
        end
        else begin
            snap_done <= 1'b0;
            if (snap_start) waitc <= 3'd1;
            else if (waitc != 3'd0) begin
                waitc <= waitc + 3'd1;
                if (waitc == 3'd3) begin
                    snap_done <= 1'b1;
                    waitc     <= 3'd0;
                end
            end
        end
    end

    always @(posedge clk) if (snap_start) snaps = snaps + 1;

    dgc_debug_uart #(.TICK_CYCLES(5000)) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .words      (words),
        .snap_done  (snap_done),
        .snap_start (snap_start),
        .uart_tx    (uart_tx)
    );

    // ------------------------------------------------------------- receiver
    reg [7:0] rb;
    reg [7:0] got [0:31];
    integer   nbytes;

    task recv_byte;
        output [7:0] b;
        integer j;
        begin
            @(negedge uart_tx);
            repeat (BIT_CLKS + BIT_CLKS/2) @(posedge clk);  // 1.5 bit -> bit0 centre
            for (j = 0; j < 8; j = j + 1) begin
                b[j] = uart_tx;
                repeat (BIT_CLKS) @(posedge clk);
            end
            // now at the stop-bit centre
            if (uart_tx !== 1'b1) `DGC_FAIL("U1 stop bit is not high")
        end
    endtask

    function [3:0] hexval(input [7:0] c);
        begin
            if (c >= 8'h30 && c <= 8'h39) hexval = c[3:0];
            else if (c >= 8'h41 && c <= 8'h46) hexval = c[3:0] + 4'd9;
            else hexval = 4'hF;
        end
    endfunction

    function [7:0] line_label(input integer ln);
        case (ln)
            0: line_label = "S";
            1: line_label = "I";
            2: line_label = "W";
            3: line_label = "J";
            4: line_label = "G";
            5: line_label = "K";
            6: line_label = "P";
            7: line_label = "Q";
            8: line_label = "R";
            9: line_label = "M";
            10: line_label = "V";
            default: line_label = "?";
        endcase
    endfunction

    task expect_char;
        input [7:0] exp;
        begin
            recv_byte(rb);
            if (rb !== exp) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: got 0x%02h '%c', expected 0x%02h '%c'",
                         rb, rb, exp, exp);
            end
        end
    endtask

    reg [15:0] w;
    reg [15:0] expw;

    task check_line;
        input integer ln;
        begin
            // "DGC5 "
            expect_char("D"); expect_char("G"); expect_char("C");
            expect_char("5"); expect_char(" ");
            expect_char(line_label(ln));
            expect_char("=");

            // four words, each printed MSB-first as four hex digits
            for (i = 0; i < 4; i = i + 1) begin
                w = 16'd0;
                for (k = 0; k < 4; k = k + 1) begin
                    recv_byte(rb);
                    w = {w[11:0], hexval(rb)};
                end
                expw = words[(ln*4 + i)*16 +: 16];
                if (w !== expw) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: line %0d word %0d = %04h, expected %04h",
                             ln, i, w, expw);
                end
            end
            expect_char(8'h0D);
            expect_char(8'h0A);
        end
    endtask

    // ------------------------------------------------------------------- main
    initial begin
        // 44 distinct, easy-to-recognise words (DGC5)
        for (i = 0; i < 44; i = i + 1)
            words[i*16 +: 16] = 16'h1000 + i;
        words[0*16 +: 16] = 16'h1FFD;
        words[1*16 +: 16] = 16'h02FF;

        snap_done = 0;
        rst_n     = 0;
        repeat (5) @(posedge clk);
        rst_n     = 1;

        // ---------------------------------------------------------------- U1
        expect_char("D"); expect_char("G"); expect_char("C");
        expect_char("5"); expect_char(" "); expect_char("B");
        expect_char("O"); expect_char("O"); expect_char("T");
        expect_char(8'h0D); expect_char(8'h0A);
        $display("TEST_INFO: U1 boot banner is DGC5 BOOT");

        // ---------------------------------------------------------------- U2/U3
        for (l = 0; l < 11; l = l + 1) check_line(l);
        $display("TEST_INFO: U2/U3 eleven lines and 44 words decoded exactly");

        // ---------------------------------------------------------------- U4
        if (snaps < 1) `DGC_FAIL("U4 no snapshot was requested")
        $display("TEST_INFO: U4 snapshots requested = %0d", snaps);

        // ---------------------------------------------------------------- U5
        // Change the words and read the next report: it must carry the new
        // values. Do NOT wait for a tick here - TICK_CYCLES is only 400, so the
        // next report may start while the receiver is still idle; the receiver
        // waits on uart_tx itself.
        for (i = 0; i < 44; i = i + 1)
            words[i*16 +: 16] = 16'h2000 + i;
        for (l = 0; l < 6; l = l + 1) check_line(l);
        $display("TEST_INFO: U5 second report carried the updated snapshot");

        if (dgc_errors == 0) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d", dgc_errors);
        $finish;
    end

endmodule

