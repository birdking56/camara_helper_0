//-----------------------------------------------------------------------------
// dgc_ram_rd_port.v
//
// Aligned read port wrapper for a Pango DRM based simple dual port RAM
// (src_tile_bank_0..7, out_stripe_ram, out_stripe_ram_1).
//
// Why a wrapper is required
//   The generated DRM wrapper has NO read enable: rd_addr is sampled on every
//   rd_clk edge and the data appears a fixed number of cycles later. Therefore
//   (a) a read only exists when this wrapper decides to "fire", and
//   (b) the business side must be told exactly which firing produced the data
//       currently on out_data.
//
// Measured behaviour of the generated IP (see sim/s0_ip_probe, run against the
// real Pango behavioural models, not against the parameter names):
//   OUTPUT_REG = 1, FAB_REG = 0, RD_OCE_EN = 0  ->  PIPE = 2 cycles
//   fire at cycle P  =>  ram_rd_data valid during cycle P+2.
//
// Elasticity
//   The DRM output register is overwritten by the next sampled address, so the
//   returned data must be captured immediately. A small registered FIFO absorbs
//   consumer stalls. It is dimensioned OUT_DEPTH = PIPE + 2 which is the minimum
//   that sustains one beat per cycle without a fall-through bypass:
//       steady state: inflight = PIPE, occupancy = 1, fire when
//                     (occupancy + inflight) < OUT_DEPTH.
//
// Result latency (fire -> out_valid) is PIPE + 1 cycles. The consumer must use
// out_valid/out_ready; out_data is only meaningful while out_valid is asserted.
//-----------------------------------------------------------------------------

module dgc_ram_rd_port #(
    parameter integer DATA_W    = 24,
    parameter integer ADDR_W    = 10,
    parameter integer PIPE      = 2,      // measured DRM read latency
    parameter integer OUT_DEPTH = PIPE + 2
) (
    input  wire              clk,
    input  wire              rst_n,          // synchronous-release reset, active low

    // ---- request side (valid/ready handshake, one address per beat) ----------
    input  wire              rd_fire,
    output wire              rd_ready,
    input  wire [ADDR_W-1:0] rd_addr,

    // ---- physical DRM read port ---------------------------------------------
    output wire [ADDR_W-1:0] ram_rd_addr,
    input  wire [DATA_W-1:0] ram_rd_data,

    // ---- aligned result stream ----------------------------------------------
    output wire              out_valid,
    input  wire              out_ready,
    output wire [DATA_W-1:0] out_data
);

    localparam integer CNT_W = $clog2(OUT_DEPTH + PIPE + 2);
    localparam integer PTR_W = (OUT_DEPTH <= 2) ? 1 : $clog2(OUT_DEPTH);

    // ---------------------------------------------------------------- state
    reg  [PIPE-1:0]        ret_v;        // data-return valid pipeline
    reg  [CNT_W-1:0]       inflight;     // fired but not yet returned
    reg  [CNT_W-1:0]       occupancy;    // entries stored in mem[]

    reg  [DATA_W-1:0]      mem [0:OUT_DEPTH-1];
    reg  [PTR_W-1:0]       wr_ptr;
    reg  [PTR_W-1:0]       rd_ptr;

    wire [CNT_W-1:0]       slots_used = occupancy + inflight;
    wire                   can_accept = (slots_used < OUT_DEPTH);
    wire                   fire       = rd_fire & rd_ready;

    assign rd_ready = can_accept;

    // A firing freezes the address on the DRM port for the whole read; when
    // nothing fires the previous address is held, which merely refreshes the
    // same DRM output word and is harmless.
    reg  [ADDR_W-1:0]      addr_q;
    assign ram_rd_addr = rd_fire ? rd_addr : addr_q;

    // ---------------------------------------------------------------- returns
    // ret_v[0] is set on the cycle that fires; the data for that beat is valid
    // PIPE cycles later, i.e. when ret_v[PIPE-1] is high.
    wire ret_hit = ret_v[PIPE-1];
    wire push    = ret_hit;
    wire pop     = out_valid & out_ready;

    assign out_valid = (occupancy != {CNT_W{1'b0}});
    assign out_data  = mem[rd_ptr];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_q    <= {ADDR_W{1'b0}};
            ret_v     <= {PIPE{1'b0}};
            inflight  <= {CNT_W{1'b0}};
            occupancy <= {CNT_W{1'b0}};
            wr_ptr    <= {PTR_W{1'b0}};
            rd_ptr    <= {PTR_W{1'b0}};
        end
        else begin
            if (fire)
                addr_q <= rd_addr;

            // valid pipeline
            ret_v[0] <= fire;
            for (i = 1; i < PIPE; i = i + 1)
                ret_v[i] <= ret_v[i-1];

            // in-flight accounting: covers fire and return in the same cycle
            inflight <= inflight + (fire ? {{(CNT_W-1){1'b0}}, 1'b1} : {CNT_W{1'b0}})
                                 - (ret_hit ? {{(CNT_W-1){1'b0}}, 1'b1} : {CNT_W{1'b0}});

            // occupancy: push and pop may coincide
            if (push && !pop)      occupancy <= occupancy + {{(CNT_W-1){1'b0}}, 1'b1};
            else if (!push && pop) occupancy <= occupancy - {{(CNT_W-1){1'b0}}, 1'b1};

            if (push) begin
                mem[wr_ptr] <= ram_rd_data;
                wr_ptr      <= (wr_ptr == OUT_DEPTH-1) ? {PTR_W{1'b0}} : (wr_ptr + {{(PTR_W-1){1'b0}}, 1'b1});
            end
            if (pop)
                rd_ptr <= (rd_ptr == OUT_DEPTH-1) ? {PTR_W{1'b0}} : (rd_ptr + {{(PTR_W-1){1'b0}}, 1'b1});
        end
    end

`ifdef DGC_SIM
    // Simulation-only sanity checks: the credit rule must never be violated.
    always @(posedge clk) begin
        if (rst_n) begin
            if (slots_used > OUT_DEPTH)
                $display("DGC_ERROR: dgc_ram_rd_port overflow slots_used=%0d depth=%0d t=%0t",
                         slots_used, OUT_DEPTH, $time);
            if (push && (occupancy == OUT_DEPTH) && !pop)
                $display("DGC_ERROR: dgc_ram_rd_port push while full t=%0t", $time);
        end
    end
`endif

endmodule
