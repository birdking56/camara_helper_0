//-----------------------------------------------------------------------------
// dgc_rlast_check.v
//
// Return-side protocol check for the DDR read path, isolated as a combinational
// predicate so it can be verified exhaustively.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   The native read port has no rready, so a returned beat can never be refused.
//   That makes a protocol violation uncorrectable after the fact, which is why it
//   must be *detected* immediately and counted rather than silently absorbed:
//
//     * rlast must arrive on exactly the last expected beat of a request;
//       arriving earlier, or not at all, is an error;
//     * more beats than requested is an error;
//     * the return ID must match the request ID.
//
// `remaining` is the number of beats still expected for the request in flight,
// including this one, so `remaining == 1` is the beat that must carry rlast.
// The module is purely combinational; the caller owns the counter.
//-----------------------------------------------------------------------------

module dgc_rlast_check (
    input  wire       rvalid,
    input  wire       rlast,
    input  wire [3:0] rid,
    input  wire [3:0] exp_id,
    input  wire [4:0] remaining,     // beats still expected, this one included; 0 = nothing in flight

    output wire       beat_taken,    // a beat is being consumed
    output wire       err_early,     // rlast before the last expected beat
    output wire       err_missing,   // last expected beat without rlast
    output wire       err_extra,     // a beat with nothing in flight
    output wire       err_id,        // wrong return ID
    output wire       err_any
);

    assign beat_taken  = rvalid;

    assign err_early   = rvalid && rlast && (remaining > 5'd1);
    assign err_missing = rvalid && !rlast && (remaining == 5'd1);
    assign err_extra   = rvalid && (remaining == 5'd0);
    assign err_id      = rvalid && (rid != exp_id);

    assign err_any = err_early | err_missing | err_extra | err_id;

endmodule
