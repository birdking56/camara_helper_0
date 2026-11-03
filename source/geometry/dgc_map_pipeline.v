//-----------------------------------------------------------------------------
// dgc_map_pipeline.v
//
// Output pixel coordinate -> source pixel coordinate with the inverse radial
// (k1/k2) distortion model, producing the frozen 96-bit coordinate record.
//
// Frozen reference: 接口冻结规范_v1.md sections 6 and 11.
//
// Modes (register 0x0010)
//   0  identity   : source coordinate equals the output coordinate (bit exact)
//   1  static     : default M derived from K, then radtan + K projection
//   2  affine     : submitted M, last row must be (0,0,1), no division
//   3  projective : NOT IMPLEMENTED at S1 (S5); config_manager must reject it
//
// Data path, justified by model/s1_pipeline_model.py and model/s1_envelope.py
//   a, b        F26, 48-bit intermediate from M * (u, v, 1)
//   x, y        F24 in 32 bits   (|x|,|y| <= norm_abs_max, capped at 4.0)
//   x^2, y^2    F24 in 40 bits
//   r2          F24 in 32 bits   (|r2| <= 32 inside the envelope)
//   r2^2        F24 in 40 bits   (|r2^2| <= 1024)
//   radial      F24 in 40 bits   (|radial| <= 1057)
//   xd, yd      F24 in 40 bits   (|xd| <= 4228)
//   sx, sy      F16 in 32 bits   (the frozen coordinate record value)
//
//   Measured with the real calibration: end-to-end error 0.011660 px against a
//   0.1 px budget, identity mode bit exact.
//
// Every narrowing is an arithmetic right shift (floor), matching both Python's
// >> and Verilog's >>>, so the final F16 value is already floor(coord*65536)
// and needs no additional rounding.
//
// sample_ok / math_error (frozen spec)
//   legal image coordinate           -> sample_ok = 1
//   mapped coordinate outside image  -> sample_ok = 0, math_error unchanged
//   |x| or |y| above norm_abs_max    -> math_error = 1, sample_ok = 0
//   arithmetic overflow              -> math_error = 1, sample_ok = 0
//   records with sample_ok = 0 still go out, but with sx0/sy0/wx/wy forced to
//   zero so the sampler can never read a garbage address.
//
// Backpressure: the whole pipeline freezes together when the output is valid but
// not accepted, so one beat per cycle in steady state.
//-----------------------------------------------------------------------------

module dgc_map_pipeline #(
    parameter integer META_W = 41
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- active configuration (constant for a whole job) --------
    input  wire [1:0]  cfg_mode,
    input  wire signed [31:0] cfg_m00,
    input  wire signed [31:0] cfg_m01,
    input  wire signed [31:0] cfg_m02,
    input  wire signed [31:0] cfg_m10,
    input  wire signed [31:0] cfg_m11,
    input  wire signed [31:0] cfg_m12,
    input  wire signed [31:0] cfg_fx,
    input  wire signed [31:0] cfg_fy,
    input  wire signed [31:0] cfg_cx,
    input  wire signed [31:0] cfg_cy,
    input  wire signed [31:0] cfg_k1,
    input  wire signed [31:0] cfg_k2,
    input  wire [31:0] cfg_norm_abs_max,   // U32/F26

    // ---------------- output coordinate stream ------------------------------
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [10:0] in_dst_x,
    input  wire [10:0] in_dst_y,
    input  wire [15:0] in_tile_tag,
    input  wire        in_tile_last,

    // ---------------- coordinate record -------------------------------------
    output wire        out_valid,
    input  wire        out_ready,
    output wire [95:0] out_coord
);

    localparam integer F24 = 24;
    localparam integer F16 = 16;

    // metadata layout: {dst_x[10:0], dst_y[10:0], tile_tag[15:0], tile_last, merr, mode0}
    localparam integer M_LAST = 2;
    localparam integer M_MERR = 1;
    localparam integer M_MODE0 = 0;

    localparam signed [31:0] SX_MAX_F16 = 32'sd125829120;   // (1920-1)<<16
    localparam signed [31:0] SY_MAX_F16 = 32'sd70713344;    // (1080-1)<<16
    localparam signed [39:0] ONE_F24     = 40'sd16777216;   // 1.0 in F24

    // ================================================================= metadata
    wire [META_W-1:0] meta_in = {
        in_dst_x, in_dst_y, in_tile_tag, in_tile_last, 1'b0, (cfg_mode == 2'd0)
    };

    wire stall = out_valid & (~out_ready);

    // ================================================================= stage 1
    reg  signed [47:0] a1, b1;
    reg  [META_W-1:0]  meta1;
    reg                v1;

    wire signed [43:0] p00 = cfg_m00 * $signed({21'b0, in_dst_x});
    wire signed [43:0] p01 = cfg_m01 * $signed({21'b0, in_dst_y});
    wire signed [43:0] p10 = cfg_m10 * $signed({21'b0, in_dst_x});
    wire signed [43:0] p11 = cfg_m11 * $signed({21'b0, in_dst_y});

    wire signed [47:0] a_next = $signed({{4{p00[43]}}, p00})
                              + $signed({{4{p01[43]}}, p01})
                              + $signed({{16{cfg_m02[31]}}, cfg_m02});
    wire signed [47:0] b_next = $signed({{4{p10[43]}}, p10})
                              + $signed({{4{p11[43]}}, p11})
                              + $signed({{16{cfg_m12[31]}}, cfg_m12});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a1 <= 48'sd0; b1 <= 48'sd0; meta1 <= {META_W{1'b0}}; v1 <= 1'b0;
        end
        else if (!stall) begin
            v1    <= in_valid;
            meta1 <= meta_in;
            a1    <= (cfg_mode == 2'd0) ? 48'sd0 : a_next;
            b1    <= (cfg_mode == 2'd0) ? 48'sd0 : b_next;
        end
    end

    // ================================================================= stage 2
    // Drop the two extra fractional bits of the F26 matrix result.
    reg  signed [31:0] x2, y2;
    reg  [META_W-1:0]  meta2;
    reg                v2;

    // x fits 32 bits signed iff a1 fits 34 bits signed
    wire x_ovf = (a1[47:34] != {14{a1[33]}});
    wire y_ovf = (b1[47:34] != {14{b1[33]}});

    wire signed [33:0] x_wide = a1 >>> 2;
    wire signed [33:0] y_wide = b1 >>> 2;

    // |x| in F26 for the norm_abs_max comparison.
    // x_wide is signed, so it must be sign extended before the absolute value;
    // zero extension here would turn any negative coordinate into a huge
    // positive value and trip the range check on every pixel.
    wire [39:0] x_ext = {{6{x_wide[33]}}, x_wide};
    wire [39:0] y_ext = {{6{y_wide[33]}}, y_wide};
    wire [39:0] abs_x_f26 = (x_wide[33] ? (~x_ext + 40'd1) : x_ext) << 2;
    wire [39:0] abs_y_f26 = (y_wide[33] ? (~y_ext + 40'd1) : y_ext) << 2;
    wire norm_ovf = ~(x_ovf | y_ovf) &
                    ((abs_x_f26 > {8'b0, cfg_norm_abs_max}) |
                     (abs_y_f26 > {8'b0, cfg_norm_abs_max}));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x2 <= 32'sd0; y2 <= 32'sd0;
            meta2 <= {META_W{1'b0}}; v2 <= 1'b0;
        end
        else if (!stall) begin
            v2 <= v1;
            if (v1) begin
                x2     <= x_ovf ? 32'sd0 : x_wide[31:0];
                y2     <= y_ovf ? 32'sd0 : y_wide[31:0];
                meta2  <= {meta1[META_W-1:2],
                           (meta1[M_MERR] | x_ovf | y_ovf | norm_ovf),
                           meta1[M_MODE0]};
            end
            else begin
                meta2 <= {META_W{1'b0}};
            end
        end
    end

    // ================================================================= stage 3
    // Squares. x and y are carried forward from here to stage 8; every value
    // that a later stage consumes must travel with the same pixel.
    reg  signed [31:0] x3, y3;
    reg  signed [39:0] xsq3, ysq3;
    reg  [META_W-1:0]  meta3;
    reg                v3;

    // 32x32 squares through the two-stage partial-product multiplier. The
    // stage-3 register samples the combinational sum one cycle after the pipe
    // has captured its partial products, so the record latency grows by 2.
    wire signed [63:0] xx_p, yy_p;
    dgc_mul_pipe #(.AW(32), .BW(32)) u_xx_mul (
        .clk (clk), .rst_n (rst_n), .ce (~stall),
        .a (x2), .b (x2), .p (), .p_comb (xx_p)
    );
    dgc_mul_pipe #(.AW(32), .BW(32)) u_yy_mul (
        .clk (clk), .rst_n (rst_n), .ce (~stall),
        .a (y2), .b (y2), .p (), .p_comb (yy_p)
    );

    reg signed [31:0] x2_d1, y2_d1;
    reg [META_W-1:0]  meta3d;
    reg               v3d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x3 <= 32'sd0; y3 <= 32'sd0;
            xsq3 <= 40'sd0; ysq3 <= 40'sd0;
            meta3 <= {META_W{1'b0}}; meta3d <= {META_W{1'b0}};
            v3 <= 1'b0; v3d <= 1'b0;
            x2_d1 <= 32'sd0; y2_d1 <= 32'sd0;
        end
        else if (!stall) begin
            x2_d1 <= x2; y2_d1 <= y2;
            v3d    <= v2; meta3d <= meta2;
            v3     <= v3d;
            meta3  <= meta3d;
            // The pipe's stage-1 register and this delay are the only two
            // registers between x2 and the stage-3 output; one metadata delay
            // (not two) keeps data and metadata aligned through a stall.
            x3    <= x2_d1;
            y3    <= y2_d1;
            xsq3  <= xx_p >>> F24;
            ysq3  <= yy_p >>> F24;
        end
    end

    // ================================================================= stage 4
    reg  signed [31:0] x4, y4, r2_4;
    reg  [META_W-1:0]  meta4;
    reg                v4;

    wire signed [39:0] r2_sum = xsq3 + ysq3;
    wire               r2_ovf = (r2_sum[39:32] != {8{r2_sum[31]}});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x4 <= 32'sd0; y4 <= 32'sd0; r2_4 <= 32'sd0;
            meta4 <= {META_W{1'b0}}; v4 <= 1'b0;
        end
        else if (!stall) begin
            v4    <= v3;
            x4    <= x3;
            y4    <= y3;
            r2_4  <= r2_ovf ? 32'sd0 : r2_sum[31:0];
            meta4 <= {meta3[META_W-1:2],
                      (meta3[M_MERR] | r2_ovf),
                      meta3[M_MODE0]};
        end
    end

    // ================================================================= stage 5
    // r2^2, and carry r2 forward so stage 6 sees r2 and r2^2 of the same pixel.
    reg  signed [31:0] x5, y5, r2_5;
    reg  signed [39:0] r2sq5;
    reg  [META_W-1:0]  meta5;
    reg                v5;

    wire signed [63:0] r4_p;
    dgc_mul_pipe #(.AW(32), .BW(32)) u_r4_mul (
        .clk (clk), .rst_n (rst_n), .ce (~stall),
        .a (r2_4), .b (r2_4), .p (), .p_comb (r4_p)
    );

    reg signed [31:0] x4_d1, y4_d1, r2_4_d1;
    reg [META_W-1:0]  meta5d;
    reg               v5d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x5 <= 32'sd0; y5 <= 32'sd0; r2_5 <= 32'sd0; r2sq5 <= 40'sd0;
            meta5 <= {META_W{1'b0}}; meta5d <= {META_W{1'b0}};
            v5 <= 1'b0; v5d <= 1'b0;
            x4_d1 <= 32'sd0; y4_d1 <= 32'sd0; r2_4_d1 <= 32'sd0;
        end
        else if (!stall) begin
            x4_d1 <= x4; y4_d1 <= y4; r2_4_d1 <= r2_4;
            v5d   <= v4; meta5d <= meta4;
            v5    <= v5d;
            meta5 <= meta5d;
            x5    <= x4_d1;
            y5    <= y4_d1;
            r2_5  <= r2_4_d1;
            r2sq5 <= r4_p >>> F24;
        end
    end

    // ================================================================= stage 6
    reg  signed [31:0] x6, y6;
    reg  signed [39:0] k1r2_6, k2r2s_6;
    reg  [META_W-1:0]  meta6;
    reg                v6;

    // t1 = F28*F24 -> 64-bit partial-product sum; t2 = F28*F24 -> 72-bit.
    // (32x40 is exactly 72 bits; the old 80-bit wire was a sign-extension
    // convenience, but reading above bit 71 from a 72-bit port leaves X.)
    wire signed [63:0] t1_p;
    wire signed [71:0] t2_p;
    dgc_mul_pipe #(.AW(32), .BW(32)) u_t1_mul (
        .clk (clk), .rst_n (rst_n), .ce (~stall),
        .a (cfg_k1), .b (r2_5), .p (), .p_comb (t1_p)
    );
    dgc_mul_pipe #(.AW(32), .BW(40)) u_t2_mul (
        .clk (clk), .rst_n (rst_n), .ce (~stall),
        .a (cfg_k2), .b (r2sq5), .p (), .p_comb (t2_p)
    );

    // t1 is a 32x32 product, so (t1 >> 28) always fits 40 bits. t2 is 32x40,
    // so (t2 >> 28) can really overflow and must be detected.
    wire t2_ovf = (t2_p[71:68] != {4{t2_p[67]}});

    reg signed [31:0] x5_d1, y5_d1;
    reg [META_W-1:0]  meta6d;
    reg               v6d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x6 <= 32'sd0; y6 <= 32'sd0;
            k1r2_6 <= 40'sd0; k2r2s_6 <= 40'sd0;
            meta6 <= {META_W{1'b0}}; meta6d <= {META_W{1'b0}};
            v6 <= 1'b0; v6d <= 1'b0;
            x5_d1 <= 32'sd0; y5_d1 <= 32'sd0;
        end
        else if (!stall) begin
            x5_d1 <= x5; y5_d1 <= y5;
            v6d   <= v5; meta6d <= meta5;
            v6    <= v6d;
            meta6 <= {meta6d[META_W-1:2],
                      (meta6d[M_MERR] | t2_ovf),
                      meta6d[M_MODE0]};
            x6      <= x5_d1;
            y6      <= y5_d1;
            k1r2_6  <= t1_p >>> 28;
            k2r2s_6 <= t2_p >>> 28;
        end
    end

    // ================================================================= stage 7
    reg  signed [31:0] x7, y7;
    reg  signed [39:0] radial7;
    reg  [META_W-1:0]  meta7;
    reg                v7;

    // widen by one bit so a true overflow is visible instead of wrapping
    wire signed [40:0] radial_wide = $signed({k1r2_6[39], k1r2_6})
                                   + $signed({k2r2s_6[39], k2r2s_6})
                                   + $signed({1'b0, ONE_F24});
    wire radial_ovf = (radial_wide[40] != radial_wide[39]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x7 <= 32'sd0; y7 <= 32'sd0; radial7 <= 40'sd0;
            meta7 <= {META_W{1'b0}}; v7 <= 1'b0;
        end
        else if (!stall) begin
            v7      <= v6;
            meta7   <= {meta6[META_W-1:2],
                        (meta6[M_MERR] | radial_ovf),
                        meta6[M_MODE0]};
            x7      <= x6;
            y7      <= y6;
            radial7 <= radial_wide[39:0];
        end
    end

    // ================================================================= stage 8
    reg  signed [39:0] xd8, yd8;
    reg  [META_W-1:0]  meta8;
    reg                v8;

    wire signed [71:0] ux_p, uy_p;
    dgc_mul_pipe #(.AW(32), .BW(40)) u_ux_mul (
        .clk (clk), .rst_n (rst_n), .ce (~stall),
        .a (x7), .b (radial7), .p (), .p_comb (ux_p)
    );
    dgc_mul_pipe #(.AW(32), .BW(40)) u_uy_mul (
        .clk (clk), .rst_n (rst_n), .ce (~stall),
        .a (y7), .b (radial7), .p (), .p_comb (uy_p)
    );
    // Capture product guard/sign bits with xd8/yd8. Compare them in the next
    // stage: the wide multiplier add tree no longer also drives the overflow
    // reduction and metadata OR before reaching a register (MODE=1 critical path).
    reg [8:0] ux_guard8, uy_guard8;
    wire ux_ovf = (ux_guard8[8:1] != {8{ux_guard8[0]}});
    wire uy_ovf = (uy_guard8[8:1] != {8{uy_guard8[0]}});

    reg [META_W-1:0]  meta8d;
    reg               v8d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xd8 <= 40'sd0; yd8 <= 40'sd0;
            ux_guard8 <= 9'd0; uy_guard8 <= 9'd0;
            meta8 <= {META_W{1'b0}}; meta8d <= {META_W{1'b0}};
            v8 <= 1'b0; v8d <= 1'b0;
        end
        else if (!stall) begin
            v8d   <= v7; meta8d <= meta7;
            v8    <= v8d;
            meta8 <= meta8d;
            xd8   <= ux_p >>> F24;
            yd8   <= uy_p >>> F24;
            ux_guard8 <= ux_p[71:63];
            uy_guard8 <= uy_p[71:63];
        end
    end
    // ================================================================= stage 9
    // The two 32x40 projection multiplies are the critical path at 225 MHz.
    // dgc_mul_pipe splits them into four parallel 16x16/16x24 partial products
    // (stage 1) and a shifted add tree.
    //
    // 2026-11-01 timing: the multiplier's own stage-2 register (72 bits, enabled
    // by ~stall) was the worst path of the 4-bank P&R: coord FIFO full ->
    // map_in_ready -> a 33-stage enable chain, -1.538 ns.  The register is now
    // instantiated HERE, in the stage-9 block next to rec9/meta9, which is where
    // its consumers live; the multiplier's internal copy becomes unobservable
    // and ADS trims it (same as the other thirteen instances).  The function is
    // unchanged: the same sum is captured on the same edge with the same enable,
    // so rec9 sees exactly the same value as before.  (Do NOT instead free-run
    // the enable: s1_map_pipeline shows the p_r/rec9 alignment slips by a cycle
    // at a stall boundary.)
    wire signed [71:0] fx_sum, fy_sum;
    reg  signed [71:0] fx_r,   fy_r;

    dgc_mul_pipe #(.AW(32), .BW(40)) u_fx_mul (
        .clk (clk), .rst_n (rst_n), .ce (~stall),
        .a (cfg_fx), .b (xd8), .p (), .p_comb (fx_sum)
    );
    dgc_mul_pipe #(.AW(32), .BW(40)) u_fy_mul (
        .clk (clk), .rst_n (rst_n), .ce (~stall),
        .a (cfg_fy), .b (yd8), .p (), .p_comb (fy_sum)
    );

    reg  [META_W-1:0] meta9a, meta9b;
    reg               v9a, v9b, v9c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta9a <= {META_W{1'b0}}; meta9b <= {META_W{1'b0}};
            v9a <= 1'b0; v9b <= 1'b0; v9c <= 1'b0;
            fx_r <= 72'sd0; fy_r <= 72'sd0;
        end
        else if (!stall) begin
            v9a <= v8;
            meta9a <= {meta8[META_W-1:2],
                       (meta8[M_MERR] | ux_ovf | uy_ovf), meta8[M_MODE0]};
            v9b <= v9a;     meta9b <= meta9a;
            // rec9 samples fx_r/meta9b on the next edge, so its valid is
            // one cycle after v9b; exporting v9b would present the previous
            // rec9 with the new record's timing.
            v9c <= v9b;
            // Stage-2 of the projection multiply, moved here from inside
            // dgc_mul_pipe so it is placed with its consumer (see stage 9 note).
            fx_r <= fx_sum;
            fy_r <= fy_sum;
        end
    end

    wire signed [71:0] sx72 = (fx_r >>> F24) + $signed({{40{cfg_cx[31]}}, cfg_cx});
    wire signed [71:0] sy72 = (fy_r >>> F24) + $signed({{40{cfg_cy[31]}}, cfg_cy});

    wire sx_ovf = (sx72[71:32] != {40{sx72[31]}});
    wire sy_ovf = (sy72[71:32] != {40{sy72[31]}});

    wire signed [31:0] sx_f16 = sx72[31:0];
    wire signed [31:0] sy_f16 = sy72[31:0];

    wire in_image = (sx_f16 >= 32'sd0) && (sx_f16 <= SX_MAX_F16) &&
                    (sy_f16 >= 32'sd0) && (sy_f16 <= SY_MAX_F16);

    wire        mode0_9 = meta9b[M_MODE0];
    wire        last_9  = meta9b[M_LAST];
    wire [15:0] tag_9   = meta9b[18:3];
    wire [10:0] dy_9    = meta9b[29:19];
    wire [10:0] dx_9    = meta9b[40:30];

    // identity mode is bit exact and cannot fail
    // Mode 3 (projective) needs the homogeneous division and is an S5 feature.
    // Until config_manager refuses it, map_pipeline must not silently run the
    // affine path and hand back coordinates that look legal but are wrong: the
    // frozen spec explicitly forbids ignoring an unsupported request. Flagging
    // math_error forces the pixel black, which is a visible, safe failure.
    wire        mode_unsupported = (cfg_mode == 2'd3);

    wire        merr_9  = mode0_9 ? 1'b0
                                 : (meta9b[M_MERR] | sx_ovf | sy_ovf | mode_unsupported);
    wire signed [31:0] sx_sel = mode0_9 ? $signed({1'b0, dx_9, 16'h0000}) : sx_f16;
    wire signed [31:0] sy_sel = mode0_9 ? $signed({1'b0, dy_9, 16'h0000}) : sy_f16;

    wire        ok_9  = mode0_9 ? 1'b1 : (in_image & (~merr_9));

    // ================================================================= stage 10
    // 2026-11-03 timing (single seed, report_timing 06:52): the only failing family
    // of the whole design was this block - 18 endpoints, WNS -0.132 ns:
    //
    //   u_map/fy_r[26] -> sy72 adder (9 carry stages) -> sy_ovf (8-stage sign
    //   extension compare) -> merr_9 (fanout 54) -> ok_9 -> wx/wy/sx0/sy0 mux
    //   -> rec9[*]          13 logic levels, 3.50 of 5.49 ns routing,
    //                       capture-clock skew -0.197 ns
    //
    // So the "add + range compare + force-zero select" chain was reaching the
    // record register in one cycle. Stage 10 registers the arithmetic result and
    // the decision, leaving only the force-zero select in front of rec9. The
    // pipeline is still one pixel per cycle; the record leaves one cycle later and
    // out_valid moves with it (v9d), exactly like every other stage boundary here.
    reg                merr10, ok10, last10;
    reg [15:0]         tag10;
    reg [10:0]         dy10, dx10;
    reg signed [31:0]  sx10, sy10;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            merr10 <= 1'b0; ok10 <= 1'b0; last10 <= 1'b0;
            tag10 <= 16'd0; dy10 <= 11'd0; dx10 <= 11'd0;
            sx10 <= 32'sd0; sy10 <= 32'sd0;
        end
        else if (!stall) begin
            // the stage-10 payload is valid in the same cycle as v9c (both are
            // loaded from what stage 9 presented from meta9b)
            merr10 <= merr_9;
            ok10   <= ok_9;
            last10 <= last_9;
            tag10  <= tag_9;
            dy10   <= dy_9;
            dx10   <= dx_9;
            sx10   <= sx_sel;
            sy10   <= sy_sel;
        end
    end

    wire [10:0] sx0_10 = ok10 ? sx10[26:16] : 11'd0;
    wire [10:0] sy0_10 = ok10 ? sy10[26:16] : 11'd0;
    wire [15:0] wx_10  = ok10 ? sx10[15:0]  : 16'd0;
    wire [15:0] wy_10  = ok10 ? sy10[15:0]  : 16'd0;

    reg  [95:0] rec9;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rec9 <= 96'd0;
        end
        else if (!stall) begin
            rec9 <= {
                1'b0,        // [95]    reserved, must be 0
                last10,      // [94]    tile_last
                merr10,      // [93]    math_error
                ok10,        // [92]    sample_ok
                tag10,       // [91:76] tile_tag
                wy_10,       // [75:60] wy
                wx_10,       // [59:44] wx
                sy0_10,      // [43:33] sy0
                sx0_10,      // [32:22] sx0
                dy10,        // [21:11] dst_y
                dx10         // [10:0]  dst_x
            };
        end
    end

    // rec9 is one cycle behind the stage-10 registers, so out_valid is v9c delayed
    // by one cycle (previously rec9 was fed straight from stage 9, where v9c was
    // already the matching valid).
    reg v9d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) v9d <= 1'b0;
        else if (!stall) v9d <= v9c;
    end

    assign out_coord = rec9;
    assign out_valid = v9d;
    assign in_ready  = ~stall;

endmodule






