// Frame progress with real inter-event gaps (> the old 255-cycle age limit).
// Capture publishes, waits through blanking, and allocates the next frame before
// the processing job releases/acquires. Repeating a frame must not starve newer
// captures. Also exercise stopped/resumed input and frame-id rollover.
`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_frame_manager_liveness;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_DDR) clk = ~clk;
    reg rst_n = 0, alloc_req = 0, write_done = 0, acquire = 0, rel = 0;
    reg [1:0] done_slot = 0, release_slot = 0;
    wire alloc_grant, alloc_drop, acquire_valid;
    wire [127:0] frame_grant, frame_acquired;
    wire [7:0] slot_state;
    wire [31:0] cnt_drop;
    dgc_frame_manager u_dut (
        .clk(clk), .rst_n(rst_n), .alloc_req(alloc_req),
        .alloc_grant(alloc_grant), .frame_grant(frame_grant), .alloc_drop(alloc_drop),
        .write_done(write_done), .done_slot(done_slot), .done_good(1'b1),
        .acquire(acquire), .acquire_force(1'b0), .acquire_valid(acquire_valid),
        .frame_acquired(frame_acquired), .rel(rel), .release_slot(release_slot),
        .cfg_width(12'd1920), .cfg_height(12'd1080), .cfg_stride(16'd5760),
        .slot_state(slot_state), .cnt_drop(cnt_drop), .ready_fid(),
        .cnt_alloc(), .cnt_done(), .cnt_acquire(), .cnt_release());

    task reset; begin
        @(negedge clk); rst_n = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
    end endtask
    task alloc; begin
        @(negedge clk); alloc_req = 1;
        @(negedge clk); alloc_req = 0;
        `DGC_CHECK(alloc_grant && !alloc_drop, "capture must receive a slot")
    end endtask
    task finish(input [1:0] s); begin
        @(negedge clk); write_done = 1; done_slot = s;
        @(negedge clk); write_done = 0;
    end endtask
    task acq; begin
        @(negedge clk); acquire = 1;
        @(negedge clk); acquire = 0;
        `DGC_CHECK(acquire_valid, "a complete frame must always be available")
    end endtask
    task release_frame(input [1:0] s); begin
        @(negedge clk); rel = 1; release_slot = s;
        @(negedge clk); rel = 0;
    end endtask

    integer k, phase;
    integer seed = 32'h4d47524c;
    integer st_ref [0:3], seq_ref [0:3];
    integer nseq, best, oldest, chosen, ds, rs, j;
    integer allocations, drops, gets, finishes, releases;
    reg exp_grant, exp_drop, exp_acq;
    reg [31:0] exp_get_fid, exp_grant_fid;
    localparam [31:0] FUZZ_BASE = 32'hfffffff0;
    reg [1:0] job_slot, capture_slot;
    reg [31:0] published_fid, capture_fid, last_job_fid;
    initial begin
        reset;
        // Populate all four slots, with gaps long enough to saturate old ages.
        for (k = 0; k < 4; k = k + 1) begin
            alloc; capture_slot = frame_grant[105:104];
            finish(capture_slot);
            repeat (600) @(negedge clk);
        end
        acq; job_slot = frame_acquired[105:104];
        `DGC_CHECK_EQ(frame_acquired[31:0], 32'd4, "initial newest frame")
        alloc; capture_slot = frame_grant[105:104]; capture_fid = frame_grant[31:0];
        `DGC_CHECK_EQ(capture_slot, 2'd0, "after a long gap reclaim the oldest frame, not the highest slot")
        for (k = 0; k < 24; k = k + 1) begin
            repeat (1000) @(negedge clk);
            published_fid = capture_fid;
            finish(capture_slot);
            repeat (600) @(negedge clk);  // input blanking before next alloc
            alloc; capture_slot = frame_grant[105:104]; capture_fid = frame_grant[31:0];
            release_frame(job_slot);
            acq; job_slot = frame_acquired[105:104]; last_job_fid = frame_acquired[31:0];
            `DGC_CHECK_EQ(last_job_fid, published_fid, "newly completed frame must survive the next capture allocation")
        end
        $display("TEST_INFO: L1 24 capture/display periods, last source fid=%0d newest published=%0d",
                 last_job_fid, published_fid);

        // Repetition remains useful when capture really stops. Resume must update.
        for (k = 0; k < 12; k = k + 1) begin
            repeat (1000) @(negedge clk);
            release_frame(job_slot); acq; job_slot = frame_acquired[105:104];
            `DGC_CHECK_EQ(frame_acquired[31:0], published_fid, "stopped input repeats the latest complete frame")
        end
        finish(capture_slot);
        repeat (600) @(negedge clk);
        alloc;
        release_frame(job_slot); acq;
        `DGC_CHECK_EQ(frame_acquired[31:0], capture_fid, "resumed capture must replace the repeat frame")
        `DGC_CHECK_EQ(cnt_drop, 32'd0, "four slots must sustain capture without drops")
        $display("TEST_INFO: L2 stopped input repeats safely; resumed input updates immediately");

        // Frame ids wrap; sequence order must still choose frame 0 over FFFFFFFF.
        reset;
        u_dut.next_fid = 32'hfffffffd;
        for (k = 0; k < 4; k = k + 1) begin
            alloc; finish(frame_grant[105:104]);
            repeat (600) @(negedge clk);
        end
        acq;
        `DGC_CHECK_EQ(frame_acquired[31:0], 32'd0, "newest frame across 32-bit wrap")
        alloc;
        `DGC_CHECK_EQ(frame_grant[105:104], 2'd0, "oldest frame across 32-bit wrap")
        $display("TEST_INFO: L3 newest/oldest selection survives frame-id wrap");

        // L4: independent allocation-sequence scoreboard. Random simultaneous
        // requests/publications/releases exercise multi-held states, out-of-order
        // completion, full-slot drops and immediate repeat acquisitions.
        reset;
        u_dut.next_fid = FUZZ_BASE;
        for (j = 0; j < 4; j = j + 1) begin st_ref[j] = 0; seq_ref[j] = 0; end
        nseq = 0; allocations = 0; drops = 0; gets = 0; finishes = 0; releases = 0;
        for (k = 0; k < 6000; k = k + 1) begin
            @(negedge clk);
            alloc_req = ({$random(seed)} % 4) != 0;
            acquire = ({$random(seed)} % 3) != 0;
            ds = {$random(seed)} % 4;
            rs = {$random(seed)} % 4;
            write_done = (st_ref[ds] == 1);
            done_slot = ds;
            rel = (st_ref[rs] == 3);
            release_slot = rs;
            best = -1; oldest = -1; chosen = -1;
            for (j = 0; j < 4; j = j + 1)
                if (st_ref[j] == 2)
                    if (best < 0 || seq_ref[j] > seq_ref[best]) best = j;
            exp_acq = acquire && (best >= 0);
            exp_get_fid = (best >= 0) ? FUZZ_BASE + seq_ref[best] : 0;
            for (j = 0; j < 4; j = j + 1) begin
                if (st_ref[j] == 0 && chosen < 0) chosen = j;
                if (st_ref[j] == 2 && !(exp_acq && best == j))
                    if (oldest < 0 || seq_ref[j] < seq_ref[oldest]) oldest = j;
            end
            if (chosen < 0) chosen = oldest;
            exp_grant = alloc_req && chosen >= 0;
            exp_drop = alloc_req && chosen < 0;
            exp_grant_fid = FUZZ_BASE + nseq;
            @(posedge clk); #0.2;
            `DGC_CHECK_EQ(alloc_grant, exp_grant, "L4 allocation grant")
            `DGC_CHECK_EQ(alloc_drop, exp_drop, "L4 full-slot drop")
            `DGC_CHECK_EQ(acquire_valid, exp_acq, "L4 acquire response")
            if (exp_grant) begin
                `DGC_CHECK_EQ(frame_grant[105:104], chosen[1:0], "L4 reclaim oldest allocation sequence")
                `DGC_CHECK_EQ(frame_grant[31:0], exp_grant_fid, "L4 allocation fid including wrap")
                st_ref[chosen] = 1; seq_ref[chosen] = nseq;
                nseq = nseq + 1; allocations = allocations + 1;
            end
            if (exp_drop) drops = drops + 1;
            if (write_done) begin st_ref[ds] = 2; finishes = finishes + 1; end
            if (exp_acq) begin
                `DGC_CHECK_EQ(frame_acquired[105:104], best[1:0], "L4 acquire newest completed frame")
                `DGC_CHECK_EQ(frame_acquired[31:0], exp_get_fid, "L4 source fid including wrap")
                st_ref[best] = 3; gets = gets + 1;
            end
            if (rel) begin st_ref[rs] = 2; releases = releases + 1; end
            for (j = 0; j < 4; j = j + 1)
                `DGC_CHECK_EQ(slot_state[j*2 +: 2], st_ref[j][1:0], "L4 slot ownership matches scoreboard")
            if (dgc_errors > 20) begin `DGC_FINISH end
        end
        `DGC_CHECK_EQ(u_dut.cnt_alloc, allocations, "L4 allocation count")
        `DGC_CHECK_EQ(u_dut.cnt_drop, drops, "L4 drop count")
        `DGC_CHECK_EQ(u_dut.cnt_acquire, gets, "L4 acquire count")
        `DGC_CHECK_EQ(u_dut.cnt_done, finishes, "L4 publish count")
        `DGC_CHECK_EQ(u_dut.cnt_release, releases, "L4 release count")
        $display("TEST_INFO: L4 6000 random cycles: alloc=%0d drop=%0d acquire=%0d publish=%0d release=%0d",
                 allocations, drops, gets, finishes, releases);
        `DGC_FINISH
    end
endmodule
