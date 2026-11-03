//-----------------------------------------------------------------------------
// dgc_s0_pattern.v
//
// S0 bring-up test pattern for the HDMI output path.
//
// This module exists only to make the S0 top level a real, live design instead
// of an empty shell: it proves that the output pixel clock, the 1080p60 timing
// generator, the RGB pipeline and the TMDS serialisers all work together on the
// board. It is NOT part of the distortion-correction data path and will be
// replaced by video_reader at S4.
//
// Contents of the pattern:
//   * eight vertical colour bars across the active area,
//   * a horizontal grey ramp in the lower half so 8-bit truncation is visible,
//   * a moving white square that advances once per frame so a frozen picture is
//     immediately obvious during bring-up.
//-----------------------------------------------------------------------------

module dgc_s0_pattern (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        vs,
    output reg  [23:0] rgb
);

    // ------------------------------------------------------- frame counter
    reg [10:0] frame_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            frame_cnt <= 11'd0;
        else if (vs)
            frame_cnt <= frame_cnt + 11'd1;
    end

    // ------------------------------------------------------- bar selector
    // 1920 / 8 = 240 pixels per bar
    wire [2:0] bar = x[10:8];

    reg [23:0] bar_rgb;

    always @(*) begin
        case (bar)
            3'd0: bar_rgb = 24'hFF_FF_FF;   // white
            3'd1: bar_rgb = 24'hFF_FF_00;   // yellow
            3'd2: bar_rgb = 24'h00_FF_FF;   // cyan
            3'd3: bar_rgb = 24'h00_FF_00;   // green
            3'd4: bar_rgb = 24'hFF_00_FF;   // magenta
            3'd5: bar_rgb = 24'hFF_00_00;   // red
            3'd6: bar_rgb = 24'h00_00_FF;   // blue
            default: bar_rgb = 24'h00_00_00; // black
        endcase
    end

    // ------------------------------------------------------- moving square
    wire [11:0] box_x = {1'b0, frame_cnt} << 1;      // 0..2046, wraps
    wire        in_box = (x >= box_x) && (x < (box_x + 12'd64)) &&
                         (y >= 12'd64) && (y < (12'd128));

    // ------------------------------------------------------- grey ramp rows
    wire        in_ramp = (y >= 12'd540) && (y < 12'd660);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rgb <= 24'h00_00_00;
        else if (!de)
            rgb <= 24'h00_00_00;
        else if (in_box)
            rgb <= 24'hFF_FF_FF;
        else if (in_ramp)
            rgb <= {x[7:0], x[7:0], x[7:0]};         // 8-bit grey ramp
        else
            rgb <= bar_rgb;
    end

endmodule
