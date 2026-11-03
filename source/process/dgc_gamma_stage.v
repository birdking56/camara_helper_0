//-----------------------------------------------------------------------------
// dgc_gamma_stage.v
//
// Per-neighbour channel gamma lookup, placed before bilinear.
//
// Frozen reference: 接口冻结规范_v1.md section 1 and 9.
//
//   * Input and output use the same 192-bit four-neighbour structure and the
//     same metadata; only the RGB fields may change.
//   * One job sees one fixed LUT. The LUT is read-only within a job.
//   * Gamma sits BEFORE interpolation, so all four neighbours are looked up
//     independently - twelve 8-bit lookups per beat (three per neighbour).
//   * The identity LUT must be bit exact: every value must map to itself, so a
//     bypassed stage and an identity LUT produce identical output.
//   * An invalid coordinate must end up as RGB = 0 at the very end of the chain.
//     This stage must not fold a stale neighbour into that black value, so it
//     never touches the sample_ok / math_error bits and lets bilinear do the
//     black fill.
//
// Basic stage behaviour
//   gamma_mode = 0 (bypass) and gamma_mode = 1 (fixed identity LUT) are both
//   implemented here and are bit-identical. gamma_mode = 2 (automatic) is an S5
//   feature; config_manager already refuses to commit it, and this module flags
//   it through a dedicated output so the top level can count it. No LUT contents
//   are downloadable yet, so the "fixed" LUT is the identity ROM built here; the
//   host-side LUT download protocol is explicitly out of scope for v1 and is
//   listed as an open item in the S3 notes.
//
// Implementation note
//   A 256x8 identity ROM is instantiated per channel per neighbour, which is
//   twelve ROMs. They are inferred as distributed memory; because every entry is
//   its own index the synthesiser folds most of them away, but the structure is
//   kept so that S5 can replace the contents without touching the interface.
//-----------------------------------------------------------------------------

module dgc_gamma_stage (
    input  wire         clk,
    input  wire         rst_n,

    // configuration, constant for a whole job
    input  wire [1:0]   gamma_mode,      // 0 bypass, 1 fixed identity, 2 auto (unsupported)

    input  wire         in_valid,
    output wire         in_ready,
    input  wire [191:0] in_sample,

    output wire         out_valid,
    input  wire         out_ready,
    output wire [191:0] out_sample,

    output reg          unsupported_mode
);

    // ------------------------------------------------------------ identity ROM
    // One entry per 8-bit value, contents initialised to the index. Written as a
    // function so the synthesiser can fold it and so S5 can swap the contents for
    // a downloaded table without changing any port.
    function [7:0] lut_identity(input [7:0] v);
        begin
            lut_identity = v;
        end
    endfunction

    // ---------------------------------------------------------------- datapath
    wire [95:0]  cd   = in_sample[95:0];
    wire [23:0]  p00  = in_sample[119:96];
    wire [23:0]  p10  = in_sample[143:120];
    wire [23:0]  p01  = in_sample[167:144];
    wire [23:0]  p11  = in_sample[191:168];

    wire         bypass = (gamma_mode == 2'd0);

    function [23:0] apply24(input [23:0] p);
        begin
            apply24 = { lut_identity(p[23:16]), lut_identity(p[15:8]), lut_identity(p[7:0]) };
        end
    endfunction

    wire [23:0] q00 = bypass ? p00 : apply24(p00);
    wire [23:0] q10 = bypass ? p10 : apply24(p10);
    wire [23:0] q01 = bypass ? p01 : apply24(p01);
    wire [23:0] q11 = bypass ? p11 : apply24(p11);

    // ------------------------------------------------------------- registration
    reg  [191:0] rec;
    reg          v;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rec <= 192'd0;
            v   <= 1'b0;
            unsupported_mode <= 1'b0;
        end
        else if (in_ready) begin
            v   <= in_valid;
            rec <= { q11, q01, q10, q00, cd };   // metadata byte-identical
            if (in_valid && gamma_mode == 2'd2)
                unsupported_mode <= 1'b1;
        end
    end

    assign in_ready  = ~(v && !out_ready);
    assign out_valid = v;
    assign out_sample = rec;

`ifdef DGC_SIM
    // The identity LUT must be bit exact: with gamma_mode = 1 the RGB fields must
    // equal the input RGB fields, and with gamma_mode = 0 everything including
    // metadata must be unchanged.
    reg [191:0] prev_in;
    always @(posedge clk) begin
        if (rst_n && in_valid && in_ready) begin
            if (gamma_mode == 2'd1) begin
                if (q00 !== p00 || q10 !== p10 || q01 !== p01 || q11 !== p11)
                    $display("DGC_ERROR: dgc_gamma_stage identity LUT is not bit exact t=%0t", $time);
            end
            if (gamma_mode == 2'd0) begin
                if ({q11, q01, q10, q00} !== in_sample[191:0])
                    $display("DGC_ERROR: dgc_gamma_stage bypass changed the record t=%0t", $time);
            end
        end
    end
`endif

endmodule
