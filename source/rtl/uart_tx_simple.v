`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : uart_tx_simple
//
// Description :
//   Minimal 8N1 UART transmitter used to print FPGA-internal status to the PC.
//   The board's USB port is a CP2102 USB-UART bridge; FPGA-side TX = pin C24
//   (taken from the official 2_8_uart_test demo).
//
//   Frame: start(0) + 8 data bits (LSB first) + stop(1)
//
//   BAUD ACCURACY -- the one thing that matters here:
//   A UART receiver samples the centre of each bit, so both ends must agree to
//   within roughly +-4% over a 10-bit frame.  With CLK_FRE = 27 MHz and
//   BAUD = 115200 the exact bit period is CLK_FRE/BAUD = 234.375 clocks, so the
//   previous divider implementation effectively produced 240 clocks/bit
//   (112500 baud, 2.3% error).  The current integer floor gives 234 clocks/bit
//   (115384 baud, 0.16% error), comfortably inside tolerance.
//   Hence the divider truncates instead of rounding.
//
//   (A fractional divider would be even more accurate, but it needs a 64-bit
//    constant, and the Pango Verilog compiler rejects 'longint' as a localparam
//    type, so it cannot be built by PDS.  0.16% is an order of magnitude better
//    than what a UART actually requires, so truncation is the right trade.)
//////////////////////////////////////////////////////////////////////////////////

module uart_tx_simple #(
    parameter integer CLK_FRE = 27_000_000,
    parameter integer BAUD    = 115200
)(
    input             clk,
    input             rstn,        // active low
    input             tx_start,    // one-cycle pulse to start a transmission
    input      [7:0]  tx_data,
    output reg        txd,         // serial output, idle high
    output reg        tx_busy
);

    // clocks per bit, truncated towards zero (NOT rounded -- see header)
    //   (CLK_FRE*16)/BAUD = 3750, /16 -> 234
    localparam integer CPB_X16 = (CLK_FRE * 16) / BAUD;
    localparam integer BITS    = (CPB_X16 < 16) ? 16 : (CPB_X16 / 16);

    // frame[0] = start bit, frame[1..8] = data LSB..MSB, frame[9] = stop bit
    reg  [9:0]  frame;
    reg  [3:0]  bitidx;          // 0..9, then BIT_DONE
    reg  [15:0] cnt;             // counts 0..BITS-1 within one bit
    localparam [3:0] BIT_DONE = 4'd10;

    always @(posedge clk)
    begin
        if(!rstn)
        begin
            txd     <= 1'b1;
            tx_busy <= 1'b0;
            frame   <= 10'h3FF;
            bitidx  <= 4'd0;
            cnt     <= 16'd0;
        end
        else if(!tx_busy)
        begin
            txd <= 1'b1;                  // idle line stays high
            cnt <= 16'd0;
            if(tx_start)
            begin
                frame   <= {1'b1, tx_data, 1'b0};   // stop + data + start
                bitidx  <= 4'd0;
                cnt     <= 16'd0;
                tx_busy <= 1'b1;
                txd     <= 1'b0;          // drive the start bit immediately
            end
        end
        else if(bitidx == BIT_DONE)
        begin
            // every bit has been held for a full period; back to idle
            tx_busy <= 1'b0;
            txd     <= 1'b1;
            cnt     <= 16'd0;
        end
        else
        begin
            txd <= frame[bitidx];

            if(cnt == BITS-1)
            begin
                cnt    <= 16'd0;
                bitidx <= bitidx + 4'd1;
            end
            else
                cnt <= cnt + 16'd1;
        end
    end

endmodule
