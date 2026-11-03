//-----------------------------------------------------------------------------
// tb_frame_manager.v - FOUR slot allocation, publication, locking, rel
//   F1  a fresh manager grants slot 0 and packs frame_desc correctly
//   F2  three allocations use slots 0, 1, 2 in turn
//   F3  the fourth allocation uses slot 3; a fifth one drops (all four WRITING)
//   F3b with all four WRITING nothing can be granted: the frame is dropped
//   F4  finished frames become READY and can be acquired (HELD)
//   F5  a HELD slot is never reclaimed; a READY one is
//   F6  rel returns a slot to FREE and it is preferred again
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_frame_manager;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_DDR) clk = ~clk;
    reg rst_n = 0;

    reg         alloc_req = 0;
    wire        alloc_grant, alloc_drop;
    wire [127:0] frame_grant;
    reg         write_done = 0;
    reg  [1:0]  done_slot = 0;
    reg         acquire = 0;
    reg         acquire_force = 0;   // 2026-11-02: forced (repeat) acquire
    wire        acquire_valid;
    wire [127:0] frame_acquired;
    reg         rel = 0;
    reg  [1:0]  release_slot = 0;
    wire [7:0]  slot_state;
    wire [31:0] cnt_alloc, cnt_drop, cnt_done, cnt_acquire, cnt_release;

    dgc_frame_manager u_dut (
        .clk(clk), .rst_n(rst_n),
        .alloc_req(alloc_req), .alloc_grant(alloc_grant), .frame_grant(frame_grant),
        .alloc_drop(alloc_drop),
        .write_done(write_done), .done_slot(done_slot), .done_good(1'b1),
        .acquire(acquire), .acquire_force(acquire_force), .acquire_valid(acquire_valid), .frame_acquired(frame_acquired),
        .rel(rel), .release_slot(release_slot),
        .cfg_width(12'd1920), .cfg_height(12'd1080), .cfg_stride(16'd5760),
        .slot_state(slot_state),
        .cnt_alloc(cnt_alloc), .cnt_drop(cnt_drop), .cnt_done(cnt_done),
        .cnt_acquire(cnt_acquire), .cnt_release(cnt_release));

    reg [127:0] got_grant [0:7];
    reg [127:0] got_acq [0:7];
    integer n_grant = 0, n_acq = 0;
    integer got_acq_base = 0;

    always @(posedge clk) begin
        if (rst_n && alloc_grant) begin got_grant[n_grant] = frame_grant; n_grant = n_grant + 1; end
        if (rst_n && acquire_valid) begin got_acq[n_acq] = frame_acquired; n_acq = n_acq + 1; end
    end

    task alloc; begin
        @(posedge clk); #0.2; alloc_req <= 1'b1;
        @(posedge clk); #0.2; alloc_req <= 1'b0;
        repeat (2) @(posedge clk);
    end endtask

    task finish(input [1:0] s); begin
        @(posedge clk); #0.2; write_done <= 1'b1; done_slot <= s;
        @(posedge clk); #0.2; write_done <= 1'b0;
        repeat (2) @(posedge clk);
    end endtask

    task acq; begin
        @(posedge clk); #0.2; acquire <= 1'b1;
        @(posedge clk); #0.2; acquire <= 1'b0;
        repeat (2) @(posedge clk);
    end endtask

    task do_rel(input [1:0] s); begin
        @(posedge clk); #0.2; rel <= 1'b1; release_slot <= s;
        @(posedge clk); #0.2; rel <= 1'b0;
        repeat (2) @(posedge clk);
    end endtask

    // 2026-11-02: forced acquire (job boundary with no descriptor in hand).
    task acq_force; begin
        @(posedge clk); #0.2; acquire <= 1'b1; acquire_force <= 1'b1;
        @(posedge clk); #0.2; acquire <= 1'b0; acquire_force <= 1'b0;
        repeat (2) @(posedge clk);
    end endtask

    initial begin
        rst_n = 0;
        repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        // ============================================================== F1
        alloc;
        if (n_grant != 1) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: F1 no grant"); end
        else begin
            if (got_grant[0][105:104] !== 2'd0) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: F1 slot exp=0 act=%0d", got_grant[0][105:104]); end
            if (got_grant[0][63:32] !== 32'h0000_0000) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: F1 slot0 base exp=0 act=%08h", got_grant[0][63:32]); end
            if (got_grant[0][79:64] !== 16'd5760) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: F1 stride act=%0d", got_grant[0][79:64]); end
            if (got_grant[0][91:80] !== 12'd1920) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: F1 width act=%0d", got_grant[0][91:80]); end
            if (got_grant[0][103:92] !== 12'd1080) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: F1 height act=%0d", got_grant[0][103:92]); end
            if (got_grant[0][107:106] !== 2'd0) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: F1 format exp=0"); end
            if (got_grant[0][127:108] !== 20'd0) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: F1 reserved not zero"); end
            if (got_grant[0][31:0] !== 32'd1) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: F1 frame_id exp=1 act=%0d", got_grant[0][31:0]); end
            $display("TEST_INFO: F1 slot 0 granted with a correct 128-bit descriptor");
        end

        // ============================================================== F2
        alloc; alloc;
        if (n_grant != 3) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: F2 expected 3 grants"); end
        else if (got_grant[1][105:104] !== 2'd1 || got_grant[2][105:104] !== 2'd2) begin
            dgc_errors = dgc_errors + 1; $display("TEST_FAIL: F2 slots exp=1,2"); end
        else if (got_grant[1][63:32] !== 32'h0100_0000 || got_grant[2][63:32] !== 32'h0200_0000) begin
            dgc_errors = dgc_errors + 1; $display("TEST_FAIL: F2 slot bases wrong"); end
        else $display("TEST_INFO: F2 three allocations used slots 0,1,2 with bases 0x00000000/0x01000000/0x02000000");

        // ============================================================== F3 (4 slots)
        alloc;
        if (n_grant != 4) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F3 the fourth slot was not granted"); end
        else if (got_grant[3][105:104] !== 2'd3 || got_grant[3][63:32] !== 32'h0300_0000) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F3 expected slot 3 base 0x03000000, got slot %0d base %08h",
                     got_grant[3][105:104], got_grant[3][63:32]); end
        else $display("TEST_INFO: F3 the fourth slot is granted (slot 3, base 0x03000000)");
        alloc;
        if (n_grant != 4 || cnt_drop !== 32'd1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F3b all four slots WRITING must drop (grants=%0d drop=%0d)", n_grant, cnt_drop); end
        else $display("TEST_INFO: F3b with all four slots WRITING the frame is dropped and counted");

        // ============================================================== F4
        // Spec section 5: "处理启动时锁定最新完整 READY 帧", so slots 0,1,2 all
        // finishing in order must give slot 2 (frame 3), the newest.
        finish(2'd0); finish(2'd1); finish(2'd2); finish(2'd3);
        acq;
        if (n_acq != 1) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: F4 no acquire"); end
        else begin
            if (got_acq[0][105:104] !== 2'd3) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: F4 expected the newest frame in slot 3, got slot %0d",
                         got_acq[0][105:104]); end
            else $display("TEST_INFO: F4 newest finished frame acquired and locked (HELD)");
        end

        // ============================================================== F5
        alloc;   // no FREE slot; the HELD one must not be taken
        if (n_grant != 5) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: F5 expected a reclaim of a READY slot (grants=%0d)", n_grant); end
        else if (got_grant[4][105:104] !== 2'd0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F5 reclaim must skip the HELD slot 3 and take the oldest READY slot 0, got slot %0d", got_grant[4][105:104]); end
        else $display("TEST_INFO: F5 HELD slot 3 was skipped, oldest READY slot 0 reclaimed");

        // ============================================================== F6
        // release returns the frame to READY (spec 5), it does not free the slot;
        // the allocation therefore still has to reclaim a READY slot, and slot 1
        // is now the oldest one (slot 0 was reclaimed in F5).
        do_rel(2'd3);
        alloc;
        if (n_grant != 6) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: F6 no grant after rel"); end
        else if (got_grant[5][105:104] !== 2'd1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F6 expected the oldest READY slot 1, got slot %0d", got_grant[5][105:104]); end
        else $display("TEST_INFO: F6 release kept the frame READY and the oldest READY slot 1 was reclaimed");

        // ============================================================== F7
        got_acq_base = got_acq[0][31:0];
        // 2026-11-03 policy change: the stale-frame refusal is gone (board: it admitted
        // only one descriptor per 16.69 ms capture period, so every boundary that landed
        // before the publish had to repeat or drop). A normal acquire now also hands out
        // the newest READY frame, i.e. the repeat frame when nothing newer exists - the
        // frozen-spec fallback - and the job FSM bounds the repeats (REPEAT_MAX).
        repeat (4) @(posedge clk);
        if (!u_dut.newest_is_last) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F7 precondition: the newest READY is not the just-processed frame");
        end
        acq;                             // normal: repeat frame is accepted now
        if (n_acq != 2) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F7 the normal acquire returned no frame (acq=%0d)", n_acq);
        end
        else if (got_acq[1][31:0] != got_acq_base) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F7 normal acquire took frame %0d, expected the repeat %0d",
                     got_acq[1][31:0], got_acq_base);
        end
        else $display("TEST_INFO: F7 normal acquire hands out the repeat frame (refusal removed)");
        acq_force;                       // forced at a boundary: same result
        if (n_acq != 3) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F7 the forced acquire returned no frame");
        end
        else $display("TEST_INFO: F7 forced acquire behaves identically (acquire_force is now redundant)");

        $display("TEST_INFO: F alloc=%0d drop=%0d done=%0d acquire=%0d rel=%0d",
                 cnt_alloc, cnt_drop, cnt_done, cnt_acquire, cnt_release);
        `DGC_FINISH
    end
endmodule
