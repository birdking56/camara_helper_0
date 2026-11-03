//-----------------------------------------------------------------------------
// dgc_snapshot_hub.v
//
// File location note (cleaned up 2026-11-03 07:30): until this date the PDS
// project compiled a stale mirror of this file under source/source/debug/. The
// project now registers source/debug/dgc_snapshot_hub.v (same for
// dgc_snapshot_src.v and dgc_input_timing.v) and the mirror tree is deleted, so
// this is the only copy again. That mirror was why the 2026-11-03 06:37 board
// build printed W2/W3 = 0x0000: the old hub still took those words from the proc
// snapshot registers that had been removed, and the two new RGB accumulators had
// no remaining observer, so ADS reported them as "dangling" and trimmed them.
// If a build ever prints two words that look frozen at 0 again, grep
// synthesize/run.log for "dangling" first.
//
// System-clock side of the board status snapshot. It asks every processing
// domain to latch its own status bundle, waits for the four acknowledgements,
// then freezes 44 x 16-bit words for the UART reporter.
//
// Why a snapshot at all: the 10-27 board readings were assembled from live
// asynchronous buses and from truncated fields, which produced several wrong
// conclusions (a 512-record block looked like "0 records"). The reporter must
// print one coherent observation set, not a mixture of times.
//
// Protocol (44 words, printed as eleven lines of four words, MSB first)
//
//   S: [0] S status        [1] T status       [2] cap_frames   [3] cap_aborted
//   I: [4] cap_rows        [5] fclk/0.1 MHz   [6] line_px      [7] frame_lines
//   W: [8] wa_frames       [9] wa_aborts      [10] input RGB sum, upper half
//                                              [11] output RGB sum, upper half
//   J: [12] jobs           [13] core blocks   [14] job flags    [15] slot states
//   G: [16] recs_total     [17] sample_left   [18] underflows   [19] reader flags
//   K: [20] fill/flags     [21] block pix_seen [22] stripe offers [23] sticky
//
// DGC3 appended the performance report (2026-10-30): the board job is 28.2 ms
// against 3.8 us/block in simulation, and these twelve words say where the
// missing time goes. All are "total since the previous snapshot, already
// right-shifted by the domain's dgc_perf_ctr" - see that module for the scale.
//
//   P: [24] fill active cycles  [25] fill waiting for beats
//      [26] fill waiting for the row channel  [27] fill waiting for the planner
//   Q: [28] fill pixel writes   [29] sample active cycles
//      [30] sample stalled by the stripe writer [31] sample stalled by the sampler
//   R: [32] native AR handshakes [33] AR channel wait cycles
//      [34] beat-return starve cycles [35] max requests in flight
//
// Wording fix in DGC3: the W words are wa_frames/wa_aborts and the two RGB
// rolling sums, exactly as the 2026-10-28 protocol document says. The old
// comment in this file called them fm_alloc/fm_drop, which never matched the
// word map and is removed.
//
// 2026-11-02: the two probe words (core-FSM snapshot, fill starts per interval)
// are gone again. They were added on 10-31 to tell "the core never starts a
// block" from "blocks run but never finish", but J2 reports the same core state
// (cstate, fill_busy, samp_busy, next_valid, px_ready, bank busy, core_busy,
// job_state), while the current board symptom - black screen with a healthy
// stripe pipeline - needs the pixel *content* question answered. So W2/W3 are
// the input/output RGB rolling sums, taken from the vin/vout bundles in their
// own clock domain (no CDC: each is a 32-bit accumulator registered in the
// domain that owns the pixels, and only its upper 16 bits are printed - see
// dgc_top_sys.v for why the upper half cannot alias on a flat source).
//
// `sticky` is OR-accumulated across reports so a single event is never lost to
// a wrapping 16-bit counter:
//   [0] ever wa_frames   [1] ever wa_aborts   [2] ever fm_alloc
//   [3] ever fm_acquire  [4] ever job         [5] ever stripe offer
//   [6] ever underflow   [7] ever cap frame   [8] ever cap abort
//   [9] ever non-FREE slot                    [15] ack timeout occurred
//   [10] stripe-writer reader-ownership watchdog fired (DGC5)
//   [11] video-reader release queue overflow (DGC5, must stay 0)
//   [12] video reader had to discard a bank at a frame boundary (DGC5)
//
// DGC5 (2026-10-31): 44 words / 11 lines. The first 40 words keep their DGC4
// positions exactly; the new line is appended at words 40..43:
//
//   V: [40] reader offers consumed   [41] offers discarded
//      [42] display frames (vs_fall) [43] stripe releases pushed
//
// All four are exact counts during the interval since the previous snapshot
// (dgc_perf_ctr #(.SHIFT(0))) in the vout domain, published on the same edge
// that freezes vout_hold. One stripe release per stripe means ~4080/s when the
// display is being fed; offers ~60/s means one stripe offered per frame, and
// discard ~= offers with release == 0 is the "reader black, banks stranded"
// signature.
//-----------------------------------------------------------------------------

module dgc_snapshot_hub (
    input  wire         clk,            // sys_clk, 27 MHz
    input  wire         rst_n,          // board reset only

    input  wire         start,          // one-cycle request from the reporter

    input  wire [15:0]  s_status,
    input  wire [15:0]  t_status,
    input  wire [127:0] vin_hold,
    input  wire [239:0] ddr_hold,
    input  wire [271:0] proc_hold,
    input  wire [143:0] vout_hold,

    input  wire         vin_ack,
    input  wire         ddr_ack,
    input  wire         proc_ack,
    input  wire         vout_ack,

    output reg          req_tgl,
    output reg  [703:0] words,
    output reg          done
);

    // ------------------------------------------------------- ack synchronisers
    reg [1:0] va, da, pa, oa;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            va <= 2'd0; da <= 2'd0; pa <= 2'd0; oa <= 2'd0;
        end
        else begin
            va <= {va[0], vin_ack};
            da <= {da[0], ddr_ack};
            pa <= {pa[0], proc_ack};
            oa <= {oa[0], vout_ack};
        end
    end

    wire all_ack = (va[1] == req_tgl) && (da[1] == req_tgl) &&
                   (pa[1] == req_tgl) && (oa[1] == req_tgl);

    // ------------------------------------------------------------------- FSM
    localparam [0:0] ST_IDLE = 1'b0;
    localparam [0:0] ST_WAIT = 1'b1;

    reg        state;
    reg [10:0] wait_cnt;
    reg [15:0] sticky;

    wire timeout_now = (state == ST_WAIT) && (wait_cnt == 11'h7FF);

    // --------------------------------------------------- pixel clock estimate
    // vin_hold word3 = fclk_cnt[15:0], word4 = fclk_cnt[23:16]
    wire [23:0] fclk_raw  = {vin_hold[79:64], vin_hold[63:48]};
    wire [31:0] fclk_mul  = fclk_raw * 32'd135;   // 24x8 fits in 32 bits unsigned
    wire [15:0] fclk_100k = fclk_mul[31:20];      // / 2^20

    // ------------------------------------------------------------- sticky bits
    wire [15:0] sticky_now;

    assign sticky_now[0]  = sticky[0]  | (|ddr_hold[15:0]);     // good write frames
    assign sticky_now[1]  = sticky[1]  | (|ddr_hold[31:16]);    // write aborts
    assign sticky_now[2]  = sticky[2]  | (|ddr_hold[47:32]);    // frame allocations
    assign sticky_now[3]  = sticky[3]  | (|ddr_hold[79:64]);    // acquires
    assign sticky_now[4]  = sticky[4]  | (|proc_hold[15:0]);    // jobs started
    assign sticky_now[5]  = sticky[5]  | (|vout_hold[47:32]);   // stripe offers
    assign sticky_now[6]  = sticky[6]  | (|vout_hold[15:0]);    // underflows
    assign sticky_now[7]  = sticky[7]  | (|vin_hold[15:0]);     // captured frames
    assign sticky_now[8]  = sticky[8]  | (|vin_hold[31:16]);    // capture aborts
    assign sticky_now[9]  = sticky[9]  | (|ddr_hold[127:112]);  // a slot not FREE
    // DGC5 anomaly stickies. They come from the domain that owns the signal:
    //   [10] proc J2 bit 12: stripe-writer watchdog            (proc_hold[44])
    //   [11] vout w3 bit 0 : reader release-queue overflow     (vout_hold[48])
    //   [12] vout w3 bit 1 : reader discarded a bank at vs_fall (vout_hold[49])
    assign sticky_now[10] = sticky[10] | proc_hold[44];
    assign sticky_now[11] = sticky[11] | vout_hold[48];
    assign sticky_now[12] = sticky[12] | vout_hold[49];
    assign sticky_now[14:13] = sticky[14:13];
    assign sticky_now[15] = sticky[15] | timeout_now;

    // --------------------------------------------------------- frozen word map
    wire [703:0] next_words = {
        // ---- DGC5 V line: video-reader activity per second -------------------
        vout_hold[127:112],    // p43 stripe releases pushed
        vout_hold[111:96],     // p42 display frames (vs_fall)
        vout_hold[95:80],      // p41 offers discarded
        vout_hold[79:64],      // p40 offers consumed
        // ---- DGC4 M line: frame age / slot recycling -------------------------
        ddr_hold[239:224],     // p39 M3 allocation drops (fm_drop)
        ddr_hold[223:208],     // p38 M2 releases
        ddr_hold[207:192],     // p37 M1 capture frame counter (fm_alloc)
        proc_hold[271:256],    // p36 M0 frame_id the job is processing
        // ---- DGC3 R line: DDR read-engine performance -------------------------
        ddr_hold[191:176],     // p35 max requests in flight
        ddr_hold[175:160],     // p34 beat-return starve cycles
        ddr_hold[159:144],     // p33 AR channel wait cycles
        ddr_hold[143:128],     // p32 native AR handshakes
        // ---- DGC3 Q line: sample / stripe-writer performance -----------------
        proc_hold[255:240],    // p31 sample stalled by the sampler
        proc_hold[239:224],    // p30 sample stalled by the stripe writer
        proc_hold[223:208],    // p29 sample active cycles
        proc_hold[207:192],    // p28 fill pixel writes
        // ---- DGC3 P line: fill performance -----------------------------------
        proc_hold[191:176],    // p27 fill waiting for the planner
        proc_hold[175:160],    // p26 fill waiting for the row channel
        proc_hold[159:144],    // p25 fill waiting for beats
        proc_hold[143:128],    // p24 fill active cycles
        // ---- DGC2 words, positions unchanged --------------------------------
        sticky_now,            // p23
        proc_hold[127:112],    // p22 stripe writer bank states {wr1,rdy1,rdg1,wr0,rdy0,rdg0}
        proc_hold[111:96],     // p21 pixels of this block that reached the writer
        proc_hold[95:80],      // p20 core fill/next-fill flags
        vout_hold[31:16],      // p19 reader flags
        vout_hold[15:0],       // p18 stripe underflows
        proc_hold[79:64],      // p17 sample_left
        proc_hold[63:48],      // p16 recs_total
        ddr_hold[127:112],     // p15 slot states
        proc_hold[47:32],      // p14 job flags
        proc_hold[31:16],      // p13 core blocks done
        proc_hold[15:0],       // p12 jobs started
        vout_hold[143:128],    // p11 W3 output RGB rolling sum, upper half (vout domain)
        vin_hold[127:112],     // p10 W2 input RGB rolling sum, upper half (vin domain)
        ddr_hold[31:16],       // p9  wa_aborts
        ddr_hold[15:0],        // p8  wa_frames (good)
        vin_hold[111:96],      // p7  frame_lines
        vin_hold[95:80],       // p6  line_px
        fclk_100k,             // p5  pixel clock / 0.1 MHz
        vin_hold[47:32],       // p4  capture rows of the current frame
        vin_hold[31:16],       // p3  capture aborted
        vin_hold[15:0],        // p2  capture frames
        t_status,              // p1
        s_status               // p0
    };

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            req_tgl  <= 1'b0;
            wait_cnt <= 11'd0;
            words    <= 704'd0;
            sticky   <= 16'd0;
            done     <= 1'b0;
        end
        else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        req_tgl  <= ~req_tgl;
                        wait_cnt <= 11'd0;
                        state    <= ST_WAIT;
                    end
                end
                ST_WAIT: begin
                    wait_cnt <= wait_cnt + 11'd1;
                    if (all_ack || timeout_now) begin
                        words    <= next_words;
                        sticky   <= sticky_now;
                        done     <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end
            endcase
        end
    end

endmodule


