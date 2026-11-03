//-----------------------------------------------------------------------------
// dgc_counters.v
//
// The eight diagnostic counters.
//
// Frozen reference: 接口冻结规范_v1.md section 12.
//
//   0x0100 input_frames        0x0110 output_underflow
//   0x0104 input_dropped       0x0114 ddr_protocol_error
//   0x0108 jobs_completed      0x0118 math_error_pixels
//   0x010C output_frames_ok    0x011C tile_split_count
//
//   All eight are unsigned 32-bit SATURATING counters, cleared by reset.
//
// Saturating rather than wrapping matters: a wrapping "math_error_pixels" could
// read back as zero in a fault report, which is exactly when the number is needed.
//
// WIDTH and INC_W are parameters only so the testbench can drive a small counter to
// its ceiling in a few cycles and prove the saturation; real use keeps 32 bits.
//-----------------------------------------------------------------------------

module dgc_counters #(
    parameter integer WIDTH = 32,
    parameter integer INC_W = 8
) (
    input  wire                clk,
    input  wire                rst_n,

    input  wire [7:0]          inc_en,      // one bit per counter
    input  wire [8*INC_W-1:0]  inc_val,     // amount for each, 0 is harmless

    output wire [8*WIDTH-1:0]  cnt
);

    localparam [WIDTH-1:0] MAXV = {WIDTH{1'b1}};

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : gen_cnt
            reg [WIDTH-1:0] q;

            wire [INC_W-1:0]   add_v = inc_val[g*INC_W +: INC_W];
            wire [WIDTH:0]     sum   = {1'b0, q} + {{(WIDTH+1-INC_W){1'b0}}, add_v};

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    q <= {WIDTH{1'b0}};
                else if (inc_en[g])
                    // saturate: once the sum would exceed the ceiling, stop
                    q <= (sum > {1'b0, MAXV}) ? MAXV : sum[WIDTH-1:0];
            end

            assign cnt[g*WIDTH +: WIDTH] = q;
        end
    endgenerate

endmodule
