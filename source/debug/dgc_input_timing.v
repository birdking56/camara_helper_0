//-----------------------------------------------------------------------------
// dgc_input_timing.v
//
// Measures the HDMI input raster in the pixel-clock domain so the board UART
// can answer the first bring-up question: is the camera really sending the
// 1920x1080 the capture path assumes?
//
// Everything is counted with the pixel clock itself. A slow system-clock gate
// only marks the measurement window; each result is latched and stays stable
// until the next window, so the 1 Hz report never sees a torn value.
//
//   fclk_cnt     pixclk edges between two `gate_tgl` edges (24 bit)
//   line_px      DE pixels in the most recent complete line (12 bit)
//   frame_lines  complete DE lines in the most recent frame (12 bit)
//
// The gate is a toggle in the sys_clk domain (the top generates one every
// 2^21 = 2,097,152 sys clocks = 77.67 ms at 27 MHz). The reporter converts
// fclk_cnt to 0.1 MHz units with  fclk_100k = (fclk_cnt * 135) >> 20:
//
//   fclk = fclk_cnt / (2^21 / 27e6) = fclk_cnt * 12.874 Hz
//   0.1 MHz units = fclk_cnt * 12.874 / 1e5 = fclk_cnt * 135 / 2^20
//
// A 1080p60 source therefore reports 1485 +- 1, a 720p60 source 742 +- 1.
//
// The module is observation-only: it never drives DE/VS or any capture signal.
//-----------------------------------------------------------------------------

module dgc_input_timing (
    input  wire        pixclk,
    input  wire        rst_n,           // pixclk domain reset

    input  wire        de,
    input  wire        vs,
    input  wire        gate_tgl,        // sys-clk-domain toggle, window marker

    output reg  [23:0] fclk_cnt,
    output reg  [11:0] line_px,
    output reg  [11:0] frame_lines,
    output reg         de_seen,
    output reg         vs_seen
);

    reg  [1:0]  g_sync;
    reg  [23:0] pix_cnt;

    reg  [11:0] lpx, flines;
    reg         de_d, vs_d;

    wire gate_edge = g_sync[0] ^ g_sync[1];
    wire de_fall   = de_d & ~de;
    wire vs_fall   = vs_d & ~vs;

    always @(posedge pixclk or negedge rst_n) begin
        if (!rst_n) begin
            g_sync      <= 2'd0;
            pix_cnt     <= 24'd0;
            fclk_cnt    <= 24'd0;
            lpx         <= 12'd0;
            flines      <= 12'd0;
            line_px     <= 12'd0;
            frame_lines <= 12'd0;
            de_d        <= 1'b0;
            vs_d        <= 1'b0;
            de_seen     <= 1'b0;
            vs_seen     <= 1'b0;
        end
        else begin
            g_sync <= {g_sync[0], gate_tgl};
            de_d   <= de;
            vs_d   <= vs;

            // ------------------------------------------------ frequency window
            if (gate_edge) begin
                fclk_cnt <= pix_cnt;
                pix_cnt  <= 24'd1;
            end
            else begin
                pix_cnt <= pix_cnt + 24'd1;
            end

            // ------------------------------------------------------- line width
            if (de) begin
                de_seen <= 1'b1;
                lpx     <= lpx + 12'd1;
            end
            if (de_fall) begin
                line_px <= lpx;          // lpx was fully counted on the last DE pixel
                lpx     <= 12'd0;
                flines  <= flines + 12'd1;
            end

            // ------------------------------------------------------ frame height
            if (vs_fall) begin
                vs_seen     <= 1'b1;
                frame_lines <= flines;
                flines      <= 12'd0;
            end
        end
    end

endmodule
