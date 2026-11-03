//-----------------------------------------------------------------------------
// dgc_bilinear.v
//
// Four-neighbour bilinear interpolation, exactly as the frozen spec defines it.
//
//   S = P00*(A-wx)*(A-wy) + P10*wx*(A-wy)
//     + P01*(A-wx)*wy     + P11*wx*wy
//   result = saturate_u8((S + 2^31) >> 32)
//
// The four-term sum is factored as:
//
//   top = P00*(A-wx) + P10*wx
//   bot = P01*(A-wx) + P11*wx
//   S   = top*(A-wy) + bot*wy
//
// One rounding only, at the output. Nothing is truncated between horizontal and
// vertical arithmetic.
//
// Pipeline (2026-10-23, after the static timing review):
//   B0 input record register
//   B1 (A-wx)/(A-wy) complement weights, pixels and metadata registered
//   B2 four horizontal products per colour registered
//   B3 top/bottom horizontal sums registered
//   B4 vertical multiplier partial products (dgc_mul_pipe stage 1)
//   B5 vertical product recomposed and registered
//   B6 top/bottom vertical products summed and registered
//   B7 single round/saturate/pack
//
// The whole arithmetic pipe uses one advance enable:
//   advance = ~out_valid | out_ready
// Every stage, including the dgc_mul_pipe instances, uses the same enable, so a
// downstream stall freezes the complete pipe and no data/valid/metadata can slip.
// Throughput is one pixel per cycle when out_ready is high.
//-----------------------------------------------------------------------------

module dgc_bilinear (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [191:0] in_sample,

    output reg         out_valid,
    input  wire        out_ready,
    output reg  [63:0] out_pixel
);

    localparam [17:0] A = 18'd65536;

    wire advance = ~out_valid | out_ready;
    assign in_ready = advance;

    // ------------------------------------------------------------- B0: input
    reg [191:0] s0_sample;
    reg         s0_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_sample <= 192'd0;
            s0_valid  <= 1'b0;
        end
        else if (advance) begin
            s0_sample <= in_sample;
            s0_valid  <= in_valid;
        end
    end

    // ------------------------------------------- B1: complement weights/pixels
    reg [191:0] s1_sample;
    reg [17:0]  s1_awx, s1_awy;
    reg [15:0]  s1_wy;
    reg         s1_valid;

    wire [15:0] s0_wx = s0_sample[59:44];
    wire [15:0] s0_wy = s0_sample[75:60];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_sample <= 192'd0;
            s1_awx <= 18'd0; s1_awy <= 18'd0; s1_wy <= 16'd0;
            s1_valid <= 1'b0;
        end
        else if (advance) begin
            s1_sample <= s0_sample;
            s1_awx    <= A - {2'b00, s0_wx};
            s1_awy    <= A - {2'b00, s0_wy};
            s1_wy     <= s0_wy;
            s1_valid  <= s0_valid;
        end
    end

    // ------------------------------------------------- B2: horizontal products
    wire [7:0] p00_r = s1_sample[119:112];
    wire [7:0] p10_r = s1_sample[143:136];
    wire [7:0] p01_r = s1_sample[167:160];
    wire [7:0] p11_r = s1_sample[191:184];
    wire [7:0] p00_g = s1_sample[111:104];
    wire [7:0] p10_g = s1_sample[135:128];
    wire [7:0] p01_g = s1_sample[159:152];
    wire [7:0] p11_g = s1_sample[183:176];
    wire [7:0] p00_b = s1_sample[103:96];
    wire [7:0] p10_b = s1_sample[127:120];
    wire [7:0] p01_b = s1_sample[151:144];
    wire [7:0] p11_b = s1_sample[175:168];
    wire [15:0] s1_wx = s1_sample[59:44];

    reg [25:0] h00_r, h10_r, h01_r, h11_r;
    reg [25:0] h00_g, h10_g, h01_g, h11_g;
    reg [25:0] h00_b, h10_b, h01_b, h11_b;
    reg [95:0] s2_cd;
    reg [17:0] s2_awy;
    reg [15:0] s2_wy;
    reg        s2_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h00_r <= 26'd0; h10_r <= 26'd0; h01_r <= 26'd0; h11_r <= 26'd0;
            h00_g <= 26'd0; h10_g <= 26'd0; h01_g <= 26'd0; h11_g <= 26'd0;
            h00_b <= 26'd0; h10_b <= 26'd0; h01_b <= 26'd0; h11_b <= 26'd0;
            s2_cd <= 96'd0; s2_awy <= 18'd0; s2_wy <= 16'd0; s2_valid <= 1'b0;
        end
        else if (advance) begin
            h00_r <= p00_r * s1_awx;
            h10_r <= p10_r * s1_wx;
            h01_r <= p01_r * s1_awx;
            h11_r <= p11_r * s1_wx;
            h00_g <= p00_g * s1_awx;
            h10_g <= p10_g * s1_wx;
            h01_g <= p01_g * s1_awx;
            h11_g <= p11_g * s1_wx;
            h00_b <= p00_b * s1_awx;
            h10_b <= p10_b * s1_wx;
            h01_b <= p01_b * s1_awx;
            h11_b <= p11_b * s1_wx;
            s2_cd  <= s1_sample[95:0];
            s2_awy <= s1_awy;
            s2_wy  <= s1_wy;
            s2_valid <= s1_valid;
        end
    end

    // --------------------------------------------- B3: top/bottom sums
    reg [26:0] top_r, bot_r, top_g, bot_g, top_b, bot_b;
    reg [95:0] s3_cd;
    reg [17:0] s3_awy;
    reg [15:0] s3_wy;
    reg        s3_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            top_r <= 27'd0; bot_r <= 27'd0;
            top_g <= 27'd0; bot_g <= 27'd0;
            top_b <= 27'd0; bot_b <= 27'd0;
            s3_cd <= 96'd0; s3_awy <= 18'd0; s3_wy <= 16'd0; s3_valid <= 1'b0;
        end
        else if (advance) begin
            top_r <= h00_r + h10_r;
            bot_r <= h01_r + h11_r;
            top_g <= h00_g + h10_g;
            bot_g <= h01_g + h11_g;
            top_b <= h00_b + h10_b;
            bot_b <= h01_b + h11_b;
            s3_cd <= s2_cd;
            s3_awy <= s2_awy;
            s3_wy  <= s2_wy;
            s3_valid <= s2_valid;
        end
    end

    // ------------------------------- B4/B5: vertical products (2-cycle pipe)
    wire [63:0] vp_tr, vp_br, vp_tg, vp_bg, vp_tb, vp_bb;

    dgc_mul_pipe #(.AW(32), .BW(32)) u_vtr (
        .clk(clk), .rst_n(rst_n), .ce(advance),
        .a({5'd0, top_r}), .b({14'd0, s3_awy}), .p(), .p_comb(vp_tr));
    dgc_mul_pipe #(.AW(32), .BW(32)) u_vbr (
        .clk(clk), .rst_n(rst_n), .ce(advance),
        .a({5'd0, bot_r}), .b({16'd0, s3_wy}), .p(), .p_comb(vp_br));
    dgc_mul_pipe #(.AW(32), .BW(32)) u_vtg (
        .clk(clk), .rst_n(rst_n), .ce(advance),
        .a({5'd0, top_g}), .b({14'd0, s3_awy}), .p(), .p_comb(vp_tg));
    dgc_mul_pipe #(.AW(32), .BW(32)) u_vbg (
        .clk(clk), .rst_n(rst_n), .ce(advance),
        .a({5'd0, bot_g}), .b({16'd0, s3_wy}), .p(), .p_comb(vp_bg));
    dgc_mul_pipe #(.AW(32), .BW(32)) u_vtb (
        .clk(clk), .rst_n(rst_n), .ce(advance),
        .a({5'd0, top_b}), .b({14'd0, s3_awy}), .p(), .p_comb(vp_tb));
    dgc_mul_pipe #(.AW(32), .BW(32)) u_vbb (
        .clk(clk), .rst_n(rst_n), .ce(advance),
        .a({5'd0, bot_b}), .b({16'd0, s3_wy}), .p(), .p_comb(vp_bb));

    // B4: the pipe's stage-1 registers capture the B3 operands on this edge.
    // Only metadata advances here; the product is not visible until the next edge.
    reg [95:0] s4_cd;
    reg        s4_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_cd <= 96'd0; s4_valid <= 1'b0;
        end
        else if (advance) begin
            s4_cd <= s3_cd;
            s4_valid <= s3_valid;
        end
    end

    // B5: p_comb (partial products summed) and its metadata are captured one
    // cycle after B4. This is the stage that was missing in the first rewrite and
    // made rgb lag one pixel behind the metadata.
    reg [44:0] v_r, v_br, v_g, v_bg, v_b, v_bb;
    reg [95:0] s5_cd;
    reg        s5_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_r <= 45'd0; v_br <= 45'd0;
            v_g <= 45'd0; v_bg <= 45'd0;
            v_b <= 45'd0; v_bb <= 45'd0;
            s5_cd <= 96'd0; s5_valid <= 1'b0;
        end
        else if (advance) begin
            v_r  <= vp_tr[44:0];
            v_br <= vp_br[44:0];
            v_g  <= vp_tg[44:0];
            v_bg <= vp_bg[44:0];
            v_b  <= vp_tb[44:0];
            v_bb <= vp_bb[44:0];
            s5_cd <= s4_cd;
            s5_valid <= s4_valid;
        end
    end

    // --------------------------------------------- B6: final vertical sum
    reg [47:0] sum_r, sum_g, sum_b;
    reg [95:0] s6_cd;
    reg        s6_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_r <= 48'd0; sum_g <= 48'd0; sum_b <= 48'd0;
            s6_cd <= 96'd0; s6_valid <= 1'b0;
        end
        else if (advance) begin
            sum_r <= v_r + v_br;
            sum_g <= v_g + v_bg;
            sum_b <= v_b + v_bb;
            s6_cd <= s5_cd;
            s6_valid <= s5_valid;
        end
    end

    // --------------------------------------------- B7: one round/saturate/pack
    function [7:0] round_sat(input [47:0] s);
        reg [47:0] t;
        begin
            t = s + 48'h8000_0000;
            t = t >> 32;
            if (t > 48'd255) round_sat = 8'd255;
            else             round_sat = t[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_pixel <= 64'd0;
        end
        else if (advance) begin
            out_valid <= s6_valid;
            out_pixel <= {
                s6_cd[93],           // math_error
                s6_cd[94],           // tile_last
                s6_cd[91:76],        // tile_tag
                s6_cd[21:11],        // dst_y
                s6_cd[10:0],         // dst_x
                s6_cd[92] ? {round_sat(sum_r), round_sat(sum_g), round_sat(sum_b)}
                          : 24'd0
            };
        end
    end

endmodule


