//-----------------------------------------------------------------------------
// tb_rlast_check.v - return protocol predicate
//   L1  rlast on the last expected beat is clean
//   L2  rlast early is an error
//   L3  last beat without rlast is an error
//   L4  a beat with nothing in flight is an error
//   L5  a wrong ID is an error even when rlast is correct
//   L6  exhaustive over remaining 0..31 x all rlast/rid combinations
//   L7  exactly one beat is consumed per rvalid, regardless of the checks
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_rlast_check;
    integer dgc_errors = 0;

    reg        rvalid = 0, rlast = 0;
    reg  [3:0] rid = 0, exp_id = 0;
    reg  [4:0] remaining = 0;
    wire       beat_taken, err_early, err_missing, err_extra, err_id, err_any;

    dgc_rlast_check u_dut (
        .rvalid(rvalid), .rlast(rlast), .rid(rid), .exp_id(exp_id),
        .remaining(remaining), .beat_taken(beat_taken),
        .err_early(err_early), .err_missing(err_missing), .err_extra(err_extra),
        .err_id(err_id), .err_any(err_any));

    integer rem, l, i, idok;
    reg e_early, e_missing, e_extra, e_id;

    initial begin
        // ============================================================== L6
        for (rem = 0; rem <= 31; rem = rem + 1)
        for (l = 0; l <= 1; l = l + 1)
        for (i = 0; i <= 1; i = i + 1) begin
            remaining = rem[4:0];
            rvalid = 1'b1; rlast = l[0];
            exp_id = 4'd5;
            rid    = i ? 4'd5 : 4'd9;      // i=1 -> matching id
            idok   = i;
            #0;

            e_early   = (l == 1) && (rem > 1);
            e_missing = (l == 0) && (rem == 1);
            e_extra   = (rem == 0);
            e_id      = !idok;

            if (err_early !== e_early) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: L2 err_early rem=%0d last=%0d", rem, l);
            end
            if (err_missing !== e_missing) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: L3 err_missing rem=%0d last=%0d", rem, l);
            end
            if (err_extra !== e_extra) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: L4 err_extra rem=%0d", rem);
            end
            if (err_id !== e_id) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: L5 err_id rem=%0d idok=%0d", rem, idok);
            end
            if (err_any !== (e_early | e_missing | e_extra | e_id)) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: L6 err_any wrong at rem=%0d", rem);
            end
            if (beat_taken !== 1'b1) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: L7 a beat must be consumed whenever rvalid");
            end
        end
        $display("TEST_INFO: L6 exhaustive over remaining 0..31 with both rlast and both id cases");
        $display("TEST_INFO: L2/L3/L4 early, missing and extra rlast are each detected");
        $display("TEST_INFO: L5 an ID mismatch is an error independent of rlast");
        $display("TEST_INFO: L7 exactly one beat is consumed per rvalid");

        // ============================================================== L1
        remaining = 5'd1; rvalid = 1'b1; rlast = 1'b1; rid = 4'd5; exp_id = 4'd5; #0;
        if (err_any) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: L1 a clean last beat was flagged");
        end
        else $display("TEST_INFO: L1 rlast on the last expected beat is clean");

        // no beat at all must never raise anything
        rvalid = 1'b0; rlast = 1'b1; remaining = 5'd0; #0;
        if (err_any || beat_taken) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: L1 an idle cycle raised an error");
        end
        else $display("TEST_INFO: L1 an idle cycle is silent");

        `DGC_FINISH
    end
endmodule
