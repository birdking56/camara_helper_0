//-----------------------------------------------------------------------------
// dgc_fifo_rd_port.v
//
// Aligned read (pop) port wrapper for a generated Pango FIFO
// (coord_fifo 96x2048 synchronous, ddr_read_fifo 256x1024 asynchronous).
//
// Why a wrapper is required
//   rd_en on the generated FIFO is a *pop command*, not a read address. It may
//   never be paired with the same-cycle rd_data, and it may never be asserted
//   while rd_empty is high.
//
// Measured behaviour of the generated IP (sim/s0_ip_probe/tb_fifo_timing.v,
// real Pango behavioural models, both FIFOs):
//   pop asserted during cycle P  =>  rd_data holds the popped word during P+2.
//   rd_empty rises on the cycle after the last pop, so at that point the last
//   word is still travelling through the two-stage output path.
//   Back-to-back pops sustain one word per cycle.
//   => PIPE = 2, exactly like the DRM read path.
//
// Because two pops can be outstanding, the FIFO output register alone is not
// enough: a consumer stall would let the second popped word overwrite the first
// before it was consumed. A registered elastic FIFO of OUT_DEPTH = PIPE + 2
// captures each returning word, which is the minimum depth that still sustains
// one word per cycle (steady state: occupancy 1 + inflight 2 < 4).
//
// Result latency (pop -> out_valid) is PIPE + 1 cycles.
//-----------------------------------------------------------------------------

module dgc_fifo_rd_port #(
    parameter integer DATA_W    = 96,
    parameter integer PIPE      = 2,      // measured FIFO pop latency
    parameter integer OUT_DEPTH = PIPE + 2
) (
    input  wire              clk,
    input  wire              rst_n,

    // ---- request side (one pop request per beat) ----------------------------
    input  wire              rd_fire,
    output wire              rd_ready,

    // ---- physical FIFO read port --------------------------------------------
    input  wire              fifo_empty,
    output wire              fifo_pop,
    input  wire [DATA_W-1:0] fifo_data,

    // ---- aligned result stream ----------------------------------------------
    output wire              out_valid,
    input  wire              out_ready,
    output wire [DATA_W-1:0] out_data
);

    localparam integer CNT_W = $clog2(OUT_DEPTH + PIPE + 2);
    localparam integer PTR_W = (OUT_DEPTH <= 2) ? 1 : $clog2(OUT_DEPTH);

    reg  [PIPE-1:0]        ret_v;
    reg  [CNT_W-1:0]       inflight;
    reg  [CNT_W-1:0]       occupancy;
    reg  [DATA_W-1:0]      mem [0:OUT_DEPTH-1];
    reg  [PTR_W-1:0]       wr_ptr;
    reg  [PTR_W-1:0]       rd_ptr;

    wire [CNT_W-1:0]       slots_used = occupancy + inflight;
    wire                   has_room   = (slots_used < OUT_DEPTH);

    // A pop may only be issued when there is data in the FIFO and room in the
    // elastic output buffer for the word it will produce.
    assign rd_ready = has_room & (~fifo_empty);

    wire fire = rd_fire & rd_ready;
    assign fifo_pop = fire;

    wire ret_hit = ret_v[PIPE-1];
    wire push    = ret_hit;
    wire pop     = out_valid & out_ready;

    assign out_valid = (occupancy != {CNT_W{1'b0}});
    assign out_data  = mem[rd_ptr];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ret_v     <= {PIPE{1'b0}};
            inflight  <= {CNT_W{1'b0}};
            occupancy <= {CNT_W{1'b0}};
            wr_ptr    <= {PTR_W{1'b0}};
            rd_ptr    <= {PTR_W{1'b0}};
        end
        else begin
            ret_v[0] <= fire;
            for (i = 1; i < PIPE; i = i + 1)
                ret_v[i] <= ret_v[i-1];

            inflight <= inflight + (fire    ? {{(CNT_W-1){1'b0}}, 1'b1} : {CNT_W{1'b0}})
                                 - (ret_hit ? {{(CNT_W-1){1'b0}}, 1'b1} : {CNT_W{1'b0}});

            if (push && !pop)      occupancy <= occupancy + {{(CNT_W-1){1'b0}}, 1'b1};
            else if (!push && pop) occupancy <= occupancy - {{(CNT_W-1){1'b0}}, 1'b1};

            if (push) begin
                mem[wr_ptr] <= fifo_data;
                wr_ptr      <= (wr_ptr == OUT_DEPTH-1) ? {PTR_W{1'b0}} : (wr_ptr + {{(PTR_W-1){1'b0}}, 1'b1});
            end
            if (pop)
                rd_ptr <= (rd_ptr == OUT_DEPTH-1) ? {PTR_W{1'b0}} : (rd_ptr + {{(PTR_W-1){1'b0}}, 1'b1});
        end
    end

`ifdef DGC_SIM
    always @(posedge clk) begin
        if (rst_n) begin
            if (fifo_pop && fifo_empty)
                $display("DGC_ERROR: dgc_fifo_rd_port pop while empty t=%0t", $time);
            if (slots_used > OUT_DEPTH)
                $display("DGC_ERROR: dgc_fifo_rd_port overflow t=%0t", $time);
        end
    end
`endif

endmodule
