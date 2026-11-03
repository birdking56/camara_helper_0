//-----------------------------------------------------------------------------
// tb_ddr_wr_adapter.v - native write channel: bursts, pages, frame boundaries
//
// A scaled frame is used: FRAME_BYTES = 5760 (one 1080p row, 180 beats), so the
// last-beat offset, the 4 KiB page crossing and the frame boundary logic are all
// exercised with a few hundred beats instead of 194,400.
//
//   W1  one frame in slot 0 (180 beats): every burst is <= 16 beats, never
//       crosses a 4 KiB boundary, every beat lands in order, frame_end slot 0
//   W2  a frame in slot 1: slot decoding and a different page offset
//   W3  a frame cut short (100 of 180 beats) followed by a new frame: the tail is
//       flushed, frame_abort is reported for slot 2, no frame_end for it
//   W4  same traffic with random awready/wready stalls: all data and all burst
//       rules still hold
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_ddr_wr_adapter;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_DDR) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST
    localparam integer FRAME_BYTES = 5760;
    localparam integer FRAME_BEATS = FRAME_BYTES / 32;
    // ------------------------------------------------------------- beat stream
    reg  [287:0] beat_data = 0;
    reg          beat_valid = 0;
    wire         beat_ready;
    // ------------------------------------------------------------- native AW/W
    wire [27:0] awaddr;
    wire [3:0]  awlen;
    wire        awuser_ap;
    wire [3:0]  awuser_id;
    wire        awvalid;
    reg         awready = 1;
    wire [255:0] wdata;
    wire [31:0]  wstrb;
    reg          wready = 1;
    wire [3:0]   wusero_id = 4'd0;
    wire         wusero_last = 1'b0;
    wire frame_end, frame_abort;
    wire [1:0] frame_end_slot, frame_abort_slot;
    wire [31:0] cnt_beats, cnt_bursts, cnt_frames, cnt_aborts;
    wire idle;
    dgc_ddr_wr_adapter #(
        .FRAME_BYTES (FRAME_BYTES),
        .BUF_DEPTH   (32)
    ) u_dut (
        .clk (clk), .rst_n (rst_n),
        .beat_valid (beat_valid), .beat_ready (beat_ready), .beat_data (beat_data),
        .awaddr (awaddr), .awlen (awlen),
        .awuser_ap (awuser_ap), .awuser_id (awuser_id),
        .awvalid (awvalid), .awready (awready),
        .wdata (wdata), .wstrb (wstrb), .wready (wready),
        .wusero_id (wusero_id), .wusero_last (wusero_last),
        .frame_end (frame_end), .frame_end_slot (frame_end_slot),
        .frame_abort (frame_abort), .frame_abort_slot (frame_abort_slot),
        .cnt_beats (cnt_beats), .cnt_bursts (cnt_bursts),
        .cnt_frames (cnt_frames), .cnt_aborts (cnt_aborts),
        .idle (idle)
    );
    // ------------------------------------------------------------- expected queue
    localparam integer QN = 2048;
    reg [287:0] exp_q [0:QN-1];
    integer q_wp = 0, q_rp = 0, n_written = 0;
    // ------------------------------------------------------------- slave model
    reg [27:0]  sl_addr;
    reg [3:0]   sl_len;
    integer     sl_left = 0;  // beats still expected in the current burst
    integer     n_bursts = 0;
    integer     n_beats  = 0;
    reg [31:0]  sl_burst_addr;
    integer     sl_idx;
    always @(posedge clk) begin
        if (rst_n) begin
            // ---------------- write address channel
            if (awvalid && awready) begin
                sl_addr = awaddr;
                sl_len  = awlen;
                sl_left = awlen + 1;
                sl_burst_addr = awaddr << 2;
                sl_idx = 0;
                n_bursts = n_bursts + 1;
                // rule 1: length 1..16
                if (awlen > 4'd15) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: burst length %0d exceeds 16", awlen + 1);
                end
                // rule 2: the whole burst stays inside one 4 KiB page
                if (((awaddr << 2) & 32'hFFF) + ((awlen + 1) * 32) > 4096) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: burst at %08h len %0d crosses a 4 KiB boundary",
                             awaddr << 2, awlen + 1);
                end
            end
            // ---------------- write data beats (no wvalid: wready is the strobe)
            // a W beat must never be taken in the same edge as the AW handshake
            // (the DUT only starts its W phase on the following cycle)
            else if (wready && (sl_left > 0)) begin
                if (q_rp >= q_wp) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: a W beat arrived with nothing expected");
                end
                else begin
                    if (wdata !== exp_q[q_rp][255:0]) begin
                        dgc_errors = dgc_errors + 1;
                        if (dgc_errors < 15)
                            $display("TEST_FAIL: beat %0d data exp=%064h act=%064h",
                                     q_rp, exp_q[q_rp][255:0], wdata);
                    end
                    if (wstrb !== 32'hFFFF_FFFF) begin
                        dgc_errors = dgc_errors + 1;
                        $display("TEST_FAIL: wstrb must be all ones");
                    end
                    if ((sl_burst_addr + sl_idx * 32) !== exp_q[q_rp][287:256]) begin
                        dgc_errors = dgc_errors + 1;
                        $display("TEST_FAIL: burst address mismatch at beat %0d: burst base %08h idx %0d vs queued %08h",
                                 q_rp, sl_burst_addr, sl_idx, exp_q[q_rp][287:256]);
                    end
                    q_rp = q_rp + 1;
                    n_beats = n_beats + 1;
                    sl_idx = sl_idx + 1;
                    sl_left = sl_left - 1;
                end
            end
        end
    end
    // ------------------------------------------------------------- frame events
    integer n_end = 0, n_abort = 0;
    integer end_slot [0:15];
    integer abort_slot [0:15];
    always @(posedge clk) begin
        if (rst_n && frame_end) begin
            if (n_end < 16) end_slot[n_end] = frame_end_slot;
            n_end = n_end + 1;
        end
        if (rst_n && frame_abort) begin
            if (n_abort < 16) abort_slot[n_abort] = frame_abort_slot;
            n_abort = n_abort + 1;
        end
    end
    // ------------------------------------------------------------- backpressure
    integer seed = 32'h0DDB_A11;
    reg bp_en = 0;
    always @(posedge clk) begin
        if (bp_en) begin
            awready <= (({$random(seed)} % 100) >= 25);
            wready  <= (({$random(seed)} % 100) >= 20);
        end
        else begin
            awready <= 1'b1; wready <= 1'b1;
        end
    end
    // ------------------------------------------------------------- driver
    integer g_beat = 0;
    task send_beat(input [31:0] addr, input [31:0] tag);
        begin
            // Drive the beat and hold it until the DUT really accepts it. A
            // "drive one cycle and hope" pattern loses the beat when beat_ready
            // falls after the driver checked it (that happened when a
            // discontinuity turned on the flush in the middle of the cycle).
            beat_data  <= {addr, tag, 224'd0};
            beat_valid <= 1'b1;
            @(negedge clk);
            while (!beat_ready) @(negedge clk);
            @(posedge clk); #0.2;
            beat_valid <= 1'b0;
            exp_q[q_wp] = {addr, tag, 224'd0};
            q_wp = q_wp + 1;
        end
    endtask
    task send_frame(input [31:0] base, input integer nbeats);
        integer k;
        begin
            for (k = 0; k < nbeats; k = k + 1) begin
                send_beat(base + k * 32, 32'hB000_0000 + g_beat);
                g_beat = g_beat + 1;
            end
        end
    endtask
    task wait_idle;
        integer guard;
        begin
            guard = 0;
            while ((!idle || (q_rp != q_wp)) && guard < 20000) begin
                @(posedge clk); #0.2;
                guard = guard + 1;
            end
            repeat (4) @(posedge clk);
        end
    endtask
    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);
        // =============================================================== W1
        send_frame(32'h0000_0000, FRAME_BEATS);
        wait_idle;
        if (n_end != 1 || end_slot[0] !== 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W1 frame_end count=%0d slot=%0d", n_end, end_slot[0]);
        end
        else $display("TEST_INFO: W1 slot0 frame: %0d beats, %0d bursts, frame_end slot 0",
                      n_beats, n_bursts);
        if (n_bursts < 11) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W1 expected at least 11 bursts for 180 beats, got %0d", n_bursts);
        end
        // =============================================================== W2
        n_bursts = 0;
        send_frame(32'h0100_0000, FRAME_BEATS);
        wait_idle;
        if (n_end != 2 || end_slot[1] !== 1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W2 frame_end count=%0d slot=%0d", n_end, end_slot[1]);
        end
        else $display("TEST_INFO: W2 slot1 frame: frame_end slot 1, %0d bursts", n_bursts);
        // =============================================================== W3
        // a frame cut short at 100 beats, then a new frame in another slot
        n_bursts = 0;
        send_frame(32'h0200_0000, 100);
        send_frame(32'h0000_0000, FRAME_BEATS);
        wait_idle;
        if (n_abort != 1 || abort_slot[0] !== 2) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W3 frame_abort count=%0d slot=%0d", n_abort, abort_slot[0]);
        end
        else $display("TEST_INFO: W3 an aborted slot2 frame was reported and its tail flushed");
        if (n_end != 3 || end_slot[2] !== 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W3 the following slot0 frame did not complete");
        end
        else $display("TEST_INFO: W3 the following slot0 frame completed normally");
        // =============================================================== W4
        bp_en = 1'b1;
        n_bursts = 0;
        send_frame(32'h0100_0000, FRAME_BEATS);
        send_frame(32'h0000_0000, FRAME_BEATS);
        bp_en = 1'b0;
        wait_idle;
        if (n_end != 5) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W4 frame_end count exp=5 act=%0d", n_end);
        end
        else $display("TEST_INFO: W4 random awready/wready stalls: %0d bursts, all beats exact", n_bursts);
        if (q_rp != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: %0d beats queued but %0d written", q_wp, q_rp);
        end
        else $display("TEST_INFO: total %0d beats written exactly once, %0d frames, %0d aborts",
                      n_beats, cnt_frames, cnt_aborts);
        `DGC_FINISH
    end
endmodule
