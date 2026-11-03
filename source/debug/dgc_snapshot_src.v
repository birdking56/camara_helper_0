//-----------------------------------------------------------------------------
// dgc_snapshot_src.v
//
// Per-clock-domain half of the board status snapshot.
//
// The system-clock side toggles `req_tgl`; this module synchronises it with two
// flops, latches the whole status bundle on the detected edge and returns the
// observed toggle as `ack_tgl`. `hold` is then stable until the next request,
// so the system side may read it asynchronously without tearing.
//
// This is the bundled-data pattern required by the frozen interface spec:
// only the toggle crosses through synchronisers, the payload is captured while
// it is guaranteed stable, and the destination acknowledges before the source
// is allowed to start the next transfer.
//
// The latch is clocked by the domain that owns the data, so all fields of the
// bundle are coherent to the same edge (no per-bit synchronisation).
//-----------------------------------------------------------------------------

module dgc_snapshot_src #(
    parameter integer W = 128
) (
    input  wire         clk,        // this domain's clock
    input  wire         rst_n,      // this domain's reset

    input  wire         req_tgl,    // from sys_clk, asynchronous
    input  wire [W-1:0] data,       // live status bundle, same domain as clk

    output reg  [W-1:0] hold,       // stable copy, same domain as clk
    output wire         latch_evt,  // one cycle: `hold` is being updated (see below)
    output reg          ack_tgl     // to sys_clk, asynchronous
);

    reg [2:0] rq;

    // Performance accumulators in this domain need to publish and restart on
    // exactly the edge that freezes `hold`, otherwise the report lags one
    // snapshot period behind. This is that edge, exported for them.
    assign latch_evt = rq[1] ^ rq[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq      <= 3'd0;
            hold    <= {W{1'b0}};
            ack_tgl <= 1'b0;
        end
        else begin
            rq <= {rq[1:0], req_tgl};
            // Latch once, on the edge of the synchronised request. The ack is a
            // delayed copy of the synchronised *level*, not a sample of rq[1] on
            // the edge cycle: the latter copied the pre-edge bit, so the first
            // request produced ack=0 and the system side timed out (found by
            // tb_snapshot P1).
            if (rq[1] ^ rq[0]) hold <= data;
            ack_tgl <= rq[1];
        end
    end

endmodule
