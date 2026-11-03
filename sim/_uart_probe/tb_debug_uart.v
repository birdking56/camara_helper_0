`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_debug_uart;
    integer dgc_errors = 0;
    reg clk = 0;
    always #18.5185 clk = ~clk;   // 27 MHz

    reg rst_n = 0;
    reg [3:0] pll_locks = 4'b1111;
    reg [4:0] rst_state = 5'b11111;
    reg ddr_init_done = 1;
    reg hdmi_rx_done = 1;
    reg hdmi_tx_done = 0;
    reg pix_tgl = 0;
    reg [5:0] tx_state = 6'h0A;
    wire uart_tx;

    dgc_debug_uart #(.TICK_CYCLES(2000)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .pll_locks(pll_locks), .rst_state(rst_state),
        .ddr_init_done(ddr_init_done),
        .hdmi_rx_done(hdmi_rx_done), .hdmi_tx_done(hdmi_tx_done),
        .pix_tgl(pix_tgl), .tx_state(tx_state),
        .tx_data_out(8'h5A),
        .frames_written(8'h11), .jobs_started(8'h22),
        .underflows(8'h33), .status_byte(8'hA5),
        .uart_tx(uart_tx)

    );

    localparam real BIT_NS = 1.0e9 / 115200.0;

    task uart_recv(output [7:0] d);
        integer i;
        begin
            while (uart_tx !== 1'b1) @(posedge clk);
            @(negedge uart_tx);
            #(BIT_NS * 1.5);
            for (i = 0; i < 8; i = i + 1) begin
                d[i] = uart_tx;
                #(BIT_NS);
            end
            if (uart_tx !== 1'b1) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: UART stop bit not high d=%02x t=%0t", d, $time);
            end
        end
    endtask

    reg [7:0] b;
    integer n;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        // Let the pix activity detector see a transition.
        #1000 pix_tgl = 1;

        n = 0;
        while (n < 35) begin
            uart_recv(b);
            $display("TEST_INFO: UART[%0d]=%02x %c", n, b, (b >= 8'h20 && b < 8'h7f) ? b : 8'h2e);
            n = n + 1;
        end

        if (dgc_errors == 0) $display("TEST_PASS");
        else                 $display("TEST_FAIL_COUNT %0d", dgc_errors);
        `DGC_FINISH
    end
endmodule
