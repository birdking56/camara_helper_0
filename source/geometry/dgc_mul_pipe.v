//-----------------------------------------------------------------------------
// dgc_mul_pipe.v - two-stage signed multiplier for the 225 MHz map pipeline
//
// Why this exists
//   A 32x40 `*` in RTL is mapped by PDS to four cascaded APM slices. On
//   PG2L100H -6 that cascade is about 10.8 ns, so dgc_map_pipeline's stage 9
//   failed 225 MHz by -6.0 ns (see docs/s5/时序分析_20261022.md).
//
//   This module splits both operands at bit 16 and computes the four partial
//   products in parallel:
//
//       a = a_hi*2^16 + a_lo,  b = b_hi*2^16 + b_lo
//       p = a_hi*b_hi*2^32 + (a_hi*b_lo + a_lo*b_hi)*2^16 + a_lo*b_lo
//
//   Stage 1 registers the four products (one APM each, no cascade).
//   Stage 2 adds them with the required shifts and registers the result.
//   Result latency is 2 cycles; throughput is one multiply per cycle.
//
//   The arithmetic is exact for signed two's-complement inputs. a_lo/b_lo are
//   unsigned slices, a_hi/b_hi are signed slices; the identity holds because
//   the low slice has no sign.
//
// 2026-11-01 note (do NOT reintroduce the OUT_REG experiment)
//   An attempt to remove the stage-2 register at the thirteen instantiations
//   that leave `p` unconnected was reverted. Two reasons, both measured:
//   (1) Pango ADS already trims those registers itself (`dangling ... cleaned`),
//       so the change saved nothing; (2) with the register moved into a
//       generate block, ADS dropped the *fx/fy* stage-2 registers as dangling
//       too (`u_fx_mul/g_out_reg.p_r[...]`), which silently removed the k1/k2
//       distortion path while making the timing report look much better.
//   The stage-2 enable must also stay on `ce`: free-running p_r shifts the
//   p_r/rec9 alignment by one cycle at a stall boundary, and tying the whole
//   module's ce high additionally lets p0..p3 sample a changed config while the
//   pipeline is frozen. s1_map_pipeline catches both.
//-----------------------------------------------------------------------------

module dgc_mul_pipe #(
    parameter integer AW = 32,
    parameter integer BW = 40
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 ce,       // freeze both stages when low
    input  wire signed [AW-1:0] a,
    input  wire signed [BW-1:0] b,
    output wire signed [AW+BW-1:0] p,       // registered (2-cycle latency)
    output wire signed [AW+BW-1:0] p_comb   // sum of stage-1 products (1 cycle)
);

    // ---------------------------------------------------------- split at bit 16
    wire [15:0]            a_lo = a[15:0];
    wire signed [AW-17:0]  a_hi = a[AW-1:16];
    wire [15:0]            b_lo = b[15:0];
    wire signed [BW-17:0]  b_hi = b[BW-1:16];

    // ---------------------------------------------------------- stage 1 products
    // Widths are the exact worst cases: 16x16 unsigned = 32 bits,
    // 17x(BW-16) signed and (AW-16)x17 signed, (AW-16)x(BW-16) signed.
    reg  [32:0]             p0;   // a_lo * b_lo, unsigned
    reg  signed [BW:0]      p1;   // a_lo * b_hi, signed
    reg  signed [AW:0]      p2;   // a_hi * b_lo, signed
    reg  signed [AW+BW-33:0] p3;  // a_hi * b_hi, signed

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p0 <= 33'd0;
            p1 <= {(BW+1){1'b0}};
            p2 <= {(AW+1){1'b0}};
            p3 <= {(AW+BW-32){1'b0}};
        end
        else if (ce) begin
            p0 <= {1'b0, a_lo} * {1'b0, b_lo};
            p1 <= $signed({1'b0, a_lo}) * b_hi;
            p2 <= a_hi * $signed({1'b0, b_lo});
            p3 <= a_hi * b_hi;
        end
    end

    // ---------------------------------------------------------- stage 2 add tree
    wire signed [AW+BW-1:0] p0_ext = {{(AW+BW-33){1'b0}}, p0};
    wire signed [AW+BW-1:0] p1_ext = {{(AW-1){p1[BW]}}, p1};
    wire signed [AW+BW-1:0] p2_ext = {{(BW-1){p2[AW]}}, p2};
    wire signed [AW+BW-1:0] p3_ext = {{32{p3[AW+BW-33]}}, p3};

    wire signed [AW+BW-1:0] sum = p0_ext
                                + (p1_ext <<< 16)
                                + (p2_ext <<< 16)
                                + (p3_ext <<< 32);

    reg  signed [AW+BW-1:0] p_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) p_r <= {(AW+BW){1'b0}};
        else if (ce) p_r <= sum;
    end

    assign p      = p_r;
    assign p_comb = sum;

endmodule
