`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : input_timing_report
//
// Description :
//   Measures the real timing of the HDMI input (the parallel video from the
//   MS7200) and prints it over the serial port.
//
//   Pure "measure and report": reads pixclk / vs / de, drives only uart_tx.
//   It is not part of the video datapath.
//
//   WHY THE MEASUREMENT RUNS IN THE pixclk DOMAIN:
//   sys_clk is 27 MHz and pixclk is 148.5 MHz, so sampling pixclk with sys_clk
//   would be undersampling (ratio 5.5:1) and the edge count would be garbage.
//   Therefore everything is counted with pixclk, and only the finished results
//   are brought back into the sys_clk domain for transmission.  The counters
//   change at most once per frame, so two-stage sampling is adequate for this
//   diagnostic readout (it is intentionally not a fully atomic CDC channel).
//
//   Measured values:
//     FCLK  : pixel clock in MHz with one decimal
//             = CLK_FRE_MHZ * 10 * PIX_CNT / 2^GATE_SHIFT
//             where 2^GATE_SHIFT is a fixed number of sys_clk cycles during which
//             PIX_CNT pixclk edges are counted.
//     LINE  : longest line in pixels   (pixclk edges while de is high)
//     FRAM  : longest frame in pixels  (pixclk edges between two vs rises)
//
//   Expected for 1080p60: FCLK=148.5  LINE=1920  FRAM=2475000
//
//   Message (one line per report, CR LF): 148.5 1920 2475000
//////////////////////////////////////////////////////////////////////////////////

module input_timing_report #(
    parameter integer CLK_FRE_MHZ = 27,           // sys_clk frequency in MHz
    parameter integer GATE_SHIFT  = 21,           // frequency window = 2^GATE_SHIFT sys_clk cycles
    parameter integer REPORT_DIV  = 27000000      // report interval in sys_clk cycles (~1 s)
)(
    input        clk,          // sys_clk
    input        rstn,         // active low
    input        pixclk,       // input pixel clock
    input        vs,           // input vertical sync
    input        de,           // input data enable
    output       txd
);

    //==========================================================================
    // 1) sys_clk domain: measurement gate + report pacing
    //
    // The frequency window is a POWER OF TWO on purpose.  Dividing by 2^N is a
    // shift, so the frequency calculation needs no divider at all.
    //
    // A previous version used GATE_CLKS = 2,700,000 and computed
    //     freq = gate_pix * 27 * 10 / 2700000
    // with a 64-bit combinational divider.  That path needed 48.1 ns against a
    // 37.0 ns clock, so post-route timing reported -7.619 ns on sys_clk: the
    // quotient never settled and every reported number was meaningless.
    //==========================================================================
    // GATE_SHIFT is the module parameter declared above; only the derived
    // constants are declared here.
    localparam [31:0]   GATE = 32'd1 << GATE_SHIFT;      // 2,097,152 cycles (~77 ms)
    localparam [31:0]   RPT  = REPORT_DIV[31:0];

    reg [31:0] gate_cnt;
    reg [31:0] rpt_cnt;
    reg        gate;

    always @(posedge clk)
    begin
        if(!rstn)
        begin
            gate_cnt <= 32'd0;
            rpt_cnt  <= 32'd0;
            gate     <= 1'b0;
        end
        else
        begin
            if(gate_cnt >= GATE)
                gate_cnt <= 32'd0;
            else
                gate_cnt <= gate_cnt + 32'd1;

            // gate is high while the counter runs, and drops for exactly one
            // clk cycle when the window closes -- that single-cycle pulse is
            // what the pixel-clock domain uses to latch its result.
            gate <= (gate_cnt < GATE);

            if(rpt_cnt >= RPT)
                rpt_cnt <= 32'd0;
            else
                rpt_cnt <= rpt_cnt + 32'd1;
        end
    end

    wire rpt_tick = (rpt_cnt == RPT);

    // Synchronise the gate into the pixel clock domain with three stages, and
    // derive a one-cycle "window closed" pulse from the falling edge.
    reg gate_p0, gate_p1, gate_p2;
    always @(posedge pixclk)
    begin
        gate_p0 <= gate;
        gate_p1 <= gate_p0;
        gate_p2 <= gate_p1;
    end

    wire win_done = (gate_p1 === 1'b0) && (gate_p2 === 1'b1);   // 1 -> 0

    //==========================================================================
    // 2) pixclk domain: all measurements
    //==========================================================================
    reg [31:0] pix_cnt;        // pixclk edges while the gate is open
    reg [31:0] gate_pix;       // result of the last completed gate

    reg        vs_q, de_q;
    reg [31:0] line_cnt, line_max;
    reg [31:0] frame_cnt, frame_max;

    // The pixel-clock domain has no reset of its own, so initialise the
    // counters at configuration time.  On hardware the FPGA's global set/reset
    // provides this; without it the counters would stay undefined in simulation.
    initial
    begin
        pix_cnt   = 32'd0;
        gate_pix  = 32'd0;
        vs_q      = 1'b0;
        de_q      = 1'b0;
        line_cnt  = 32'd0;
        line_max  = 32'd0;
        frame_cnt = 32'd0;
        frame_max = 32'd0;
        gate_p0   = 1'b0;
        gate_p1   = 1'b0;
        gate_p2   = 1'b0;
    end

    always @(posedge pixclk)
    begin
        vs_q <= vs;
        de_q <= de;

        //--- frequency: count pixclk edges while the gate is open ---
        if(gate_p1)
            pix_cnt <= pix_cnt + 32'd1;

        if(win_done)
        begin
            gate_pix  <= pix_cnt;      // latch the completed window
            pix_cnt   <= 32'd0;
            // Clear the maxima with every window so the report shows the
            // CURRENT input timing instead of the all-time maximum.  Without
            // this, any startup transient (VS not stable yet, DE stretched on
            // the first line) is latched forever and the numbers never recover.
            line_max  <= 32'd0;
            frame_max <= 32'd0;
        end

        //--- line length ---
        if(de)
            line_cnt <= line_cnt + 32'd1;
        else
        begin
            if(de_q)                       // de falling edge = end of a line
            begin
                if(line_cnt > line_max)
                    line_max <= line_cnt;
            end
            line_cnt <= 32'd0;
        end

        //--- frame length ---
        frame_cnt <= frame_cnt + 32'd1;
        if(vs & ~vs_q)                     // vs rising edge = frame boundary
        begin
            // Include the current pixel-clock edge.  Storing frame_cnt alone
            // reports one less than the number of clocks between VS rises.
            if((frame_cnt + 32'd1) > frame_max)
                frame_max <= frame_cnt + 32'd1;
            frame_cnt <= 32'd0;
        end
    end

    //==========================================================================
    // 3) bring the results back into the sys_clk domain
    //    The values only change once per frame, so two samples a few clk cycles
    //    apart are enough for a diagnostic readout.
    //==========================================================================
    reg [31:0] s_gate_pix_1, s_gate_pix_2;
    reg [31:0] s_line_1,     s_line_2;
    reg [31:0] s_frame_1,    s_frame_2;

    always @(posedge clk)
    begin
        if(!rstn)
        begin
            s_gate_pix_1 <= 32'd0;
            s_gate_pix_2 <= 32'd0;
            s_line_1     <= 32'd0;
            s_line_2     <= 32'd0;
            s_frame_1    <= 32'd0;
            s_frame_2    <= 32'd0;
        end
        else
        begin
            s_gate_pix_1 <= gate_pix;
            s_gate_pix_2 <= s_gate_pix_1;
            s_line_1     <= line_max;
            s_line_2     <= s_line_1;
            s_frame_1    <= frame_max;
            s_frame_2    <= s_frame_1;
        end
    end

    // frequency x10 = pixel_clk_edges * CLK_FRE_MHZ * 10 / 2^GATE_SHIFT
    //
    // GATE is a power of two, so the division is a shift: there is no divider on
    // this path.  The product is registered as well, which keeps the multiplier
    // out of the same clock cycle as the decimal conversion below.
    wire [39:0] gp40        = {8'd0, s_gate_pix_2};                 // explicit widening
    wire [39:0] freq_prod_c = gp40 * (CLK_FRE_MHZ * 10);            // 32 x 9 bit, 40 bit result
    reg  [39:0] freq_prod;

    always @(posedge clk)
    begin
        if(!rstn) freq_prod <= 40'd0;
        else      freq_prod <= freq_prod_c;
    end

    wire [39:0] freq_raw    = freq_prod >> GATE_SHIFT;
    wire [31:0] freq_mhz10  = (freq_raw > 40'd9999) ? 32'd9999 : freq_raw[31:0];

    //==========================================================================
    // 4) message buffer: computed once per report so it is a consistent snapshot
    //==========================================================================
    // Fixed-width message:
    //     148.5 1920 2475000<CR><LF>
    //     ----- ---- -------  --
    //       5    4      7      2  = 20 transmitted bytes
    // One extra zero byte terminates the buffer for the sender below.
    localparam MSG_LEN = 21;

    reg [7:0]  msg [0:MSG_LEN-1];

    function [7:0] dec_digit;
        input [31:0] v;
        begin
            dec_digit = 8'h30 + (v % 10);
        end
    endfunction

    integer    i;
    reg [31:0] f_line, f_frame;

    task automatic build_msg;
        begin
            for(i = 0; i < MSG_LEN; i = i + 1)
                msg[i] = 8'h00;

            f_line  = s_line_2;
            f_frame = s_frame_2;

            // Compact, fixed-width message:
            //     148.5 1920 2475000<CR><LF>
            // Pixel clock is xxx.x MHz, line length is four digits and frame
            // length is seven digits.  The previous version allocated only
            // 3/6 digits and split binary bit-fields as though they were
            // decimal groups, so 1920 and 2475000 could not print correctly.
            msg[0] = dec_digit(freq_mhz10 / 1000);
            msg[1] = dec_digit(freq_mhz10 / 100);
            msg[2] = dec_digit(freq_mhz10 / 10);
            msg[3] = ".";
            msg[4] = dec_digit(freq_mhz10);

            msg[5] = " ";

            msg[6] = dec_digit(f_line / 1000);
            msg[7] = dec_digit(f_line / 100);
            msg[8] = dec_digit(f_line / 10);
            msg[9] = dec_digit(f_line);

            msg[10] = " ";

            msg[11] = dec_digit(f_frame / 1000000);
            msg[12] = dec_digit(f_frame / 100000);
            msg[13] = dec_digit(f_frame / 10000);
            msg[14] = dec_digit(f_frame / 1000);
            msg[15] = dec_digit(f_frame / 100);
            msg[16] = dec_digit(f_frame / 10);
            msg[17] = dec_digit(f_frame);

            msg[18] = 8'h0D;
            msg[19] = 8'h0A;
            msg[20] = 8'h00;
        end
    endtask

    //==========================================================================
    // 5) transmit the message
    //==========================================================================
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;

    uart_tx_simple #(
        .CLK_FRE (CLK_FRE_MHZ * 1000000),
        .BAUD    (115200)
    ) u_uart (
        .clk      (clk),
        .rstn     (rstn),
        .tx_start (tx_start),
        .tx_data  (tx_data),
        .txd      (txd),
        .tx_busy  (tx_busy)
    );

    reg [6:0] mptr;
    reg       sending;

    always @(posedge clk)
    begin
        if(!rstn)
        begin
            mptr     <= 7'd0;
            sending  <= 1'b0;
            tx_start <= 1'b0;
            tx_data  <= 8'd0;
        end
        else
        begin
            tx_start <= 1'b0;

            if(!sending)
            begin
                if(rpt_tick)
                begin
                    build_msg();
                    sending <= 1'b1;
                    mptr    <= 7'd0;
                end
            end
            // tx_start and tx_busy are registered in two different always
            // blocks.  The UART sees tx_start one clock after this producer
            // raises it, and tx_busy becomes visible to this producer one
            // further clock later.  Do not issue another character during
            // that acknowledgement cycle; doing so advances mptr twice and
            // makes the UART drop every second byte.
            else if(!tx_busy && !tx_start)
            begin
                if(msg[mptr] == 8'h00)
                    sending <= 1'b0;
                else
                begin
                    tx_data  <= msg[mptr];
                    tx_start <= 1'b1;
                    mptr     <= mptr + 7'd1;
                end
            end
        end
    end

endmodule
