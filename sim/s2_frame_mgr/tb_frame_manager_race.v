//-----------------------------------------------------------------------------
// tb_frame_manager_race.v - directed cases for the two frame-manager defects
//
// The first frame_manager implementation selected the OLDEST READY slot for
// `acquire`, and its original test asserted that behaviour. The frozen spec
// (section 5) says:
//
//   "处理启动时锁定最新完整 READY 帧；没有新帧可重复处理最近完整帧。
//    释放后的最新帧可以回到 READY，直到被更新的完成帧替代或槽回收。"
//
// so acquisition must take the NEWEST complete READY frame, and a release must
// put the frame back into READY (not FREE) so that the most recent frame can be
// processed again when no newer one exists.
//
// R1  newest-by-frame-id wins even when an older frame was released later
// R2  release returns the slot to READY, and the same frame can be re-acquired
// R3  `write_done` with good = 0 never publishes a frame
// R4  a capture reclaim and a processing acquire in the same cycle never take
//     the same slot (that would overwrite a frame being read)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_frame_manager_race;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_DDR) clk = ~clk;
    reg rst_n = 0;

    reg          alloc_req = 0;
    wire         alloc_grant, alloc_drop;
    wire [127:0] frame_grant;
    reg          write_done = 0;
    reg  [1:0]   done_slot = 0;
    reg          done_good = 1;
    reg          acquire = 0;
    reg          acquire_force = 0;  // 2026-11-02: forced (repeat) acquire
    wire         acquire_valid;
    wire [127:0] frame_acquired;
    reg          rel = 0;
    reg  [1:0]   release_slot = 0;
    wire [7:0]   slot_state;
    wire [31:0]  cnt_alloc, cnt_drop, cnt_done, cnt_acquire, cnt_release;

    dgc_frame_manager u_dut (
        .clk(clk), .rst_n(rst_n),
        .alloc_req(alloc_req), .alloc_grant(alloc_grant), .frame_grant(frame_grant),
        .alloc_drop(alloc_drop),
        .write_done(write_done), .done_slot(done_slot), .done_good(done_good),
        .acquire(acquire), .acquire_force(acquire_force), .acquire_valid(acquire_valid), .frame_acquired(frame_acquired),
        .rel(rel), .release_slot(release_slot),
        .cfg_width(12'd1920), .cfg_height(12'd1080), .cfg_stride(16'd5760),
        .slot_state(slot_state),
        .cnt_alloc(cnt_alloc), .cnt_drop(cnt_drop), .cnt_done(cnt_done),
        .cnt_acquire(cnt_acquire), .cnt_release(cnt_release));

    integer n_grant = 0, n_acq = 0;
    reg [127:0] last_grant, last_acq;

    always @(posedge clk) begin
        if (rst_n && alloc_grant) begin last_grant = frame_grant; n_grant = n_grant + 1; end
        if (rst_n && acquire_valid) begin last_acq = frame_acquired; n_acq = n_acq + 1; end
    end

    task alloc; begin
        @(posedge clk); #0.2; alloc_req <= 1'b1;
        @(posedge clk); #0.2; alloc_req <= 1'b0;
        repeat (1) @(posedge clk);
    end endtask

    task finish(input [1:0] s, input good); begin
        @(posedge clk); #0.2; write_done <= 1'b1; done_slot <= s; done_good <= good;
        @(posedge clk); #0.2; write_done <= 1'b0; done_good <= 1'b1;
        repeat (1) @(posedge clk);
    end endtask

    task acq; begin
        @(posedge clk); #0.2; acquire <= 1'b1;
        @(posedge clk); #0.2; acquire <= 1'b0;
        repeat (1) @(posedge clk);
    end endtask

    // 2026-11-02: forced acquire (job boundary with no descriptor in hand).
    task acq_force; begin
        @(posedge clk); #0.2; acquire <= 1'b1; acquire_force <= 1'b1;
        @(posedge clk); #0.2; acquire <= 1'b0; acquire_force <= 1'b0;
        repeat (1) @(posedge clk);
    end endtask

    task do_rel(input [1:0] s); begin
        @(posedge clk); #0.2; rel <= 1'b1; release_slot <= s;
        @(posedge clk); #0.2; rel <= 1'b0;
        repeat (1) @(posedge clk);
    end endtask

    integer i;
    reg [31:0] r5_ref;
    reg [31:0] r5b_ref;

    initial begin
        rst_n = 0;
        repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        // ---------------------------------------------------------------- R1
        // slot0 gets frame 1 and is finished first; slot1 gets frame 2 later.
        alloc;                 // slot0 = frame 1
        finish(2'd0, 1'b1);    // slot0 READY (frame 1)
        alloc;                 // slot1 = frame 2
        finish(2'd1, 1'b1);    // slot1 READY (frame 2)
        acq;
        if (n_acq != 1) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: R1 no acquire"); end
        else if (last_acq[105:104] !== 2'd1 || last_acq[31:0] !== 32'd2) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R1 acquire must take the newest frame (slot1/frame2), got slot%0d frame%0d",
                     last_acq[105:104], last_acq[31:0]);
        end
        else $display("TEST_INFO: R1 acquire takes the newest complete READY frame");

        // an older frame released later must not look newer: slot2 = frame 3
        alloc;                 // slot2 = frame 3
        finish(2'd2, 1'b1);
        do_rel(2'd1);          // frame 2 back to READY, frame 3 is newer
        acq;
        if (n_acq != 2) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: R1b no acquire"); end
        else if (last_acq[31:0] !== 32'd3) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R1b expected newest frame 3, got frame%0d", last_acq[31:0]);
        end
        else $display("TEST_INFO: R1b newest is chosen by frame id, not by release order");

        // ---------------------------------------------------------------- R2
        do_rel(2'd2);
        // frame 3 is READY again; with no newer frame it can be re-acquired
        acq;
        if (n_acq != 3) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: R2 no re-acquire after release"); end
        else if (last_acq[31:0] !== 32'd3 || last_acq[105:104] !== 2'd2) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R2 release must return the frame to READY, got slot%0d frame%0d",
                     last_acq[105:104], last_acq[31:0]);
        end
        else $display("TEST_INFO: R2 a released frame returns to READY and can be re-acquired");
        do_rel(2'd2);

        // ---------------------------------------------------------------- R3
        // a bad frame must never become READY
        alloc;                 // slot0 = frame 4
        finish(2'd0, 1'b0);
        if (slot_state[1:0] !== 2'd0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R3 a frame with good=0 became state %0d, expected FREE", slot_state[1:0]);
        end
        else $display("TEST_INFO: R3 write_done with good=0 frees the slot instead of publishing it");

        // ---------------------------------------------------------------- R4
        // Reclaim + acquire in the same cycle. Make all three slots READY:
        // slot0 gets frame 5, slot1 still holds frame 2, slot2 holds frame 3.
        alloc; finish(2'd0, 1'b1);      // slot0 = frame 5
        @(posedge clk); #0.2;
        alloc_req <= 1'b1;
        acquire   <= 1'b1;
        @(posedge clk); #0.2;
        alloc_req <= 1'b0;
        acquire   <= 1'b0;
        repeat (2) @(posedge clk);
        if (n_acq != 4) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: R4 acquire lost"); end
        else if (last_acq[105:104] !== 2'd0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R4 expected newest frame 5 in slot0, got slot%0d", last_acq[105:104]);
        end
        if (n_grant != 6) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: R4 alloc lost"); end
        else if (last_grant[105:104] !== 2'd1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R4 reclaim took slot%0d, expected the oldest remaining READY slot 1",
                     last_grant[105:104]);
        end
        else if (last_grant[105:104] == last_acq[105:104]) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R4 reclaim and acquire took the same slot%0d", last_acq[105:104]);
        end
        else $display("TEST_INFO: R4 simultaneous reclaim and acquire never take the same slot");

        // ---------------------------------------------------------------- R5
        // 2026-11-03 policy change: the stale-frame refusal is GONE (board: it admitted
        // only one descriptor per capture period, so every boundary that landed before
        // the publish had to repeat or drop). The manager now always hands out the
        // newest READY frame; when nothing newer exists the same frame comes back, which
        // is the frozen-spec fallback, and the job FSM bounds the repeats.
        // State here: slot0 READY(f5), slot1 READY(f2), slot2 READY(f3), no HELD.
        acq;                            // take the newest frame
        r5_ref = last_acq[31:0];
        $display("TEST_INFO: R5 setup took frame %0d", r5_ref);
        do_rel(last_acq[105:104]);       // release it -> READY again
        alloc;                           // a newer frame (f6) starts being captured
        acq;                             // newest READY is still the last one -> repeat
        if (n_acq != 5) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R5 the just-processed frame was not handed out again");
        end
        else if (last_acq[31:0] != r5_ref) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R5 expected the repeat frame %0d, got %0d",
                     r5_ref, last_acq[31:0]);
        end
        else $display("TEST_INFO: R5 with nothing newer READY the same frame is handed out (repeat)");
        do_rel(last_acq[105:104]);       // release it again
        finish(last_grant[105:104], 1'b1);   // finish the capture of f6
        acq;
        if (n_acq != 6) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R5b the newer frame was not handed out after it completed");
        end
        else if (last_acq[31:0] == r5_ref) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R5b still the same frame %0d", last_acq[31:0]);
        end
        else $display("TEST_INFO: R5b the newer frame is handed out as soon as it is READY");

        $display("TEST_INFO: race suite alloc=%0d drop=%0d done=%0d acquire=%0d rel=%0d",
                 cnt_alloc, cnt_drop, cnt_done, cnt_acquire, cnt_release);
        `DGC_FINISH
    end
endmodule
