//-----------------------------------------------------------------------------
// dgc_ddr_credit.v
//
// DDR read path credit accounting.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   U  write-domain FIFO occupancy estimate
//   O  beats already handshaked but not yet returned
//   P  beats reserved (arvalid raised, handshake not yet done)
//
//   Before issuing a new request for B beats:
//       U + O + P + B + 16 <= 1024
//
//   The 16-beat margin is a v1 control allowance and may not be used for anything
//   else. Reservation is completed BEFORE arvalid is raised; on the handshake the
//   reserved beats move from P to O; every rvalid decrements O and writes the FIFO.
//   The rule must also cover a request being issued in the same cycle a return
//   arrives, so the predicate is evaluated against the values that will hold after
//   this cycle's updates rather than the registered ones.
//
// This module only does the accounting. It does not drive arvalid, does not count
// rlast and does not split at 4 KiB; those belong to the adapter around it.
//-----------------------------------------------------------------------------

module dgc_ddr_credit (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [10:0] wr_level,      // U, FIFO write-side occupancy

    // reserve B beats: asserted for one cycle before arvalid can be raised
    input  wire        reserve,
    input  wire [4:0]  reserve_beats,
    output wire        reserve_ok,    // the reservation would fit

    // arvalid handshake: the reserved beats become outstanding
    input  wire        ar_fire,
    input  wire [4:0]  ar_beats,

    // one returned beat
    input  wire        r_fire,

    output wire [11:0] outstanding,   // O
    output wire [11:0] reserved,      // P
    output wire [12:0] headroom,      // 1024 - 16 - U - O - P
    output wire        overflow_seen  // sticky: the invariant was violated
);

    localparam integer FIFO_DEPTH = 1024;
    localparam integer MARGIN     = 16;

    reg [11:0] o_cnt;
    reg [11:0] p_cnt;
    reg        bad;

    wire [12:0] u_ext = {2'd0, wr_level};

    // Conservative reservation check on the registered counters:
    //     U + O + P + B + MARGIN <= FIFO_DEPTH
    // Do NOT borrow this cycle's rvalid by using o_next here. That borrow made
    // axi_rvalid -> credit subtract/compare -> reserve_ok a long combinational
    // path (the review measured -0.599 ns with 6.5 ns of route). Waiting one
    // cycle before reusing a returned slot is safe; the 16-beat margin and the
    // registered FIFO level already cover the bubble.
    wire [12:0] sum_try = u_ext + {1'b0, o_cnt} + {1'b0, p_cnt}
                        + {8'd0, reserve_beats} + MARGIN;

    // If an AR handshake is consuming the current P in this same cycle, keep the
    // guard that P is large enough; this uses only registered P and ar_beats.
    assign reserve_ok = (sum_try <= FIFO_DEPTH) &&
                        (p_cnt >= (ar_fire ? {7'd0, ar_beats} : 12'd0));

    assign outstanding = o_cnt;
    assign reserved    = p_cnt;
    assign headroom    = (FIFO_DEPTH - MARGIN) - u_ext - o_cnt - p_cnt;
    assign overflow_seen = bad;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_cnt <= 12'd0;
            p_cnt <= 12'd0;
            bad   <= 1'b0;
        end
        else begin
            // One update per register per cycle. Two separate non-blocking
            // assignments to the same counter silently drop whichever comes first
            // when both events happen in the same cycle; this module previously
            // wrote p_cnt under both `reserve` and `ar_fire` and wrote o_cnt under
            // both `ar_fire` and `r_fire`. Every same-cycle collision then lost the
            // increment, and o_cnt drifted negative (4095) which tripped the sticky
            // overflow check and halted the read engine for good. The combined
            // updates below are what the original comments already claimed.
            if (ar_fire && reserve && reserve_ok)
                p_cnt <= p_cnt - {7'd0, ar_beats} + {7'd0, reserve_beats};
            else if (ar_fire)
                p_cnt <= p_cnt - {7'd0, ar_beats};
            else if (reserve && reserve_ok)
                p_cnt <= p_cnt + {7'd0, reserve_beats};

            if (ar_fire && r_fire)
                o_cnt <= o_cnt + {7'd0, ar_beats} - 12'd1;
            else if (ar_fire)
                o_cnt <= o_cnt + {7'd0, ar_beats};
            else if (r_fire && (o_cnt != 12'd0))
                o_cnt <= o_cnt - 12'd1;

            // sticky violations. An ar handshake that draws more beats than were
            // reserved must be reported: the 12-bit counters would otherwise wrap and
            // turn a simple miscount into a permanent stall that looks like a
            // deadlock somewhere else.
            if ((u_ext + o_cnt + p_cnt) > (FIFO_DEPTH - MARGIN) + {0,1'b0})
                bad <= 1'b1;
            if (ar_fire && ({7'd0, ar_beats} > p_cnt))
                bad <= 1'b1;
        end
    end

endmodule
