//-----------------------------------------------------------------------------
// dgc_video_reader.v
//
// Reads finished output stripes out of the two stripe RAM banks in raster order
// and hands RGB/DE/HS/VS to the TMDS encoder.
//
// Frozen reference: 接口冻结规范_v1.md section 10.
//
//   stripe_id 0..67, start y = stripe_id*16; 0..66 are 16 lines, 67 is 8.
//   stripe_addr[14:0] = {dst_y[3:0], dst_x[10:0]}
//   The output side locks a job before the frame starts and then only accepts
//   the increasing stripe_id of that job. If the first stripe is not ready the
//   whole frame is black; if a later stripe misses its deadline the rest of the
//   frame is black, underflow is counted and the processing side must abort.
//   Late descriptors are discarded and their ownership returned - they must
//   never be displayed as the next stripe.
//
// Ownership
//   The writer publishes a stripe with stripe_offer; this module returns the
//   bank with stripe_release after it has been scanned (status 0 normal,
//   2 underflow/discarded). Both cross clock domains through mailboxes created
//   by the top level; this module only speaks valid/ready.
//
// Two ownership fixes made for the 2026-10-31 black-screen deadlock
// (writer: bank0 reading=1 forever, reader: frame_black with cur_ok=0):
//
//   1. `frame_last` used to release stripe 67 and leave cur_ok set until vs_fall,
//      which pushed a *second* release for the same bank during the vertical
//      blanking. That duplicate could clear a reading flag the writer had just
//      set for the next frame's stripe in the same bank, and from then on the
//      two sides disagreed about ownership. cur_ok is now cleared on the same
//      edge that pushes the last-stripe release.
//   2. If stripe 0 of the new frame is accepted on the very same edge as vs_fall,
//      the old frame's cur_bank may be that same bank; the boundary release is
//      suppressed for it, because the offer handshake has already re-armed the
//      writer's `reading` bit for the new stripe. Releasing it again would free a
//      bank this reader now owns.
//
// Every path that drops ownership is counted: `cnt_rel_drop` (release queue
// overflow, must stay 0), and the sticky `vs_discard` flag (a frame boundary had
// to discard a bank it still owned - an anomaly worth seeing on the UART).
//-----------------------------------------------------------------------------
// Timing
//   The DRM read path has a two-cycle latency, so the reader issues the address
//   for the pixel RD_LAT cycles before it is needed and delays DE/HS/VS and the
//   bank select by the same amount. Delaying the bank select matters: the last
//   RD_LAT pixels of a stripe are still in flight when the next stripe's bank is
//   selected, and muxing them with the new bank would corrupt the stripe edge.
//   When a tree of these plays no audio, the DE/HS/VS and RGB must still stand
//   for the same scan position, which the shared delay guarantees.
//-----------------------------------------------------------------------------

module dgc_video_reader #(
    parameter integer RD_LAT = 2
) (
    input  wire        clk,             // vout_clk, 148.5 MHz
    input  wire        rst_n,

    // ---------------- output timing -----------------------------------------
    input  wire        de_in, hs_in, vs_in,
    input  wire [11:0] x_in, y_in,

    // ---------------- stripe_offer (from the processing side) ---------------
    input  wire        offer_valid,
    output wire        offer_ready,
    input  wire [63:0] offer_data,

    // ---------------- stripe_release (back to the processing side) ----------
    output wire        release_valid,
    input  wire        release_ready,
    output wire [63:0] release_data,

    // ---------------- stripe RAM read ports ---------------------------------
    output wire [14:0] ram0_rd_addr,
    input  wire [23:0] ram0_rd_data,
    output wire [14:0] ram1_rd_addr,
    input  wire [23:0] ram1_rd_data,
    output wire [14:0] ram2_rd_addr,
    input  wire [23:0] ram2_rd_data,
    output wire [14:0] ram3_rd_addr,
    input  wire [23:0] ram3_rd_data,

    // ---------------- video to the TMDS encoder -----------------------------
    output wire [23:0] rgb,
    output wire        de_out, hs_out, vs_out,

    // ---------------- status -------------------------------------------------
    output reg  [31:0] cnt_underflow,
    output reg  [31:0] cnt_frames,       // one per vs_fall
    output reg  [31:0] cnt_discard,      // offers consumed and thrown away
    output reg  [31:0] cnt_offers,       // every offer consumed (first+prefetch+discard)
    output reg  [31:0] cnt_releases,     // every stripe_release pushed (DGC5)
    output reg  [15:0] cnt_rel_drop,     // release-queue overflow events (must stay 0)
    output wire        frame_black,
    // Debug-only observation for the board UART. Pure taps, no behaviour change.
    output wire [6:0]  dbg_cur_stripe,
    output wire        dbg_frame_ok,
    output wire        dbg_cur_ok,
    output wire        dbg_waiting_first,
    output wire        dbg_have_next,
    output wire [1:0]  dbg_cur_bank,
    output wire [1:0]  dbg_next_bank,
    // {release pop, vs_fall, discard, offer} one-cycle events, for the DGC5
    // per-second interval counters. Pure taps.
    output wire [3:0]  dbg_events,
    // Sticky anomaly: a release was pushed at a frame boundary for a bank this
    // reader still owned (i.e. the frame ended mid-stripe or a prefetch leaked).
    output wire        dbg_vs_discard,
    output reg  [6:0]  dbg_uf_stripe,     // stripe index at which the frame starved
    output reg         dbg_uf_first       // 1: the starvation was stripe 0 missing the porch
);

    // ------------------------------------------------------------ offer decode
    wire [31:0] o_job    = offer_data[31:0];
    wire [6:0]  o_stripe = offer_data[54:48];
    // 2026-11-01: the bank field is two bits; bank[1] sits in the formerly
    // reserved bit 62.
    wire [1:0]  o_bank   = {offer_data[62], offer_data[55]};
    wire [4:0]  o_lines  = offer_data[60:56];

    localparam [6:0] LAST_STRIPE = 7'd67;
    localparam [5:0] LAST_LINES  = 6'd8;

    // ------------------------------------------------------------------ state
    reg [6:0]  cur_stripe;
    reg [1:0]  cur_bank;
    reg        cur_ok;
    reg        frame_ok;
    reg        waiting_first;   // frame started but stripe 0 not available yet
    reg [4:0]  line_cnt;        // completed active lines in the current stripe
    reg [31:0] job_l;

    reg        have_next;
    reg [1:0]  next_bank;

    // 2026-11-02 (four banks): stripe 0 of a LATER job may arrive while this frame
    // is still being scanned; parking it here lets the next frame start on its very
    // first line instead of being black. The parked bank is only taken in the frame
    // tail of a healthy frame - see the gating comment at take_pfirst below - because
    // the writer needs that same bank again four stripes later for the job it is
    // currently producing.
    reg        pf_valid;
    reg [1:0]  pf_bank;
    reg [31:0] pf_job;


    reg        de_d, vs_d;
    reg        vs_discard_sticky;

    wire de_rise = de_in & ~de_d;
    wire de_fall = ~de_in & de_d;
    wire vs_fall = vs_d & ~vs_in;

    // ------------------------------------------------------------ offer accept
    // Offers are never stalled: an unexpected one is consumed and released with
    // status "discarded", which returns its ownership instead of leaking a bank.
    assign offer_ready = 1'b1;

    wire take_offer   = offer_valid & offer_ready;
    wire take_first   = take_offer & waiting_first & (o_stripe == 7'd0);
    wire take_prefetch = take_offer & ~take_first & frame_ok &&
                         (o_job == job_l) && (o_stripe == (cur_stripe + 7'd1)) &&
                         !have_next;
    // 2026-11-02 (b): parking is only allowed in the frame tail of a HEALTHY frame.
    //
    // The first version parked any stripe 0 of "another job" as soon as the reader
    // was not waiting for one, and that starved the writer for a whole output frame
    // (s5_jobs with PF_EN=1: pixel count frozen at exactly 122880 = 4 x 30720, i.e.
    // stripes 0..3 written, then stripe 4 needed bank 0 - the parked one - and the
    // writer waited for vs_fall).
    //
    // Why: bank = stripe_id[1:0], so the job that produced the parked stripe 0 also
    // needs that same bank again four stripes later (stripe 4, 8, ...). Parking is
    // therefore only harmless once the writer can no longer touch that bank in this
    // job, which is exactly when the *previous* job has finished - and that has
    // already happened whenever a *new* job's stripe 0 exists at all. The reader can
    // check it without knowing the writer's internals:
    //   * frame_ok   : the frame on screen is healthy, so this reader has consumed
    //                  its own stripe 0 and the incoming stripe 0 must belong to a
    //                  job that started after this one completed. In a black frame
    //                  (frame_ok=0) the offer is the *current* job's late stripe 0 -
    //                  the case that used to hang the writer - and it is discarded.
    //   * cur_stripe : defensive bound; the writer is at most two stripes ahead, so
    //                  from stripe 64 on its remaining stripes (65..67) all live in
    //                  other banks. Even if the premise above is ever violated, the
    //                  worst stall is then vs_fall plus one stripe (~1 ms) instead of
    //                  a whole frame.
    localparam PF_EN   = 1'b1;
    localparam [6:0] PF_TAIL = 7'd64;
    wire take_pfirst  = PF_EN && take_offer & ~take_first & ~waiting_first & ~pf_valid &
                        frame_ok & (cur_stripe >= PF_TAIL) &
                        (o_stripe == 7'd0) & (o_job != job_l);
    wire take_discard = take_offer & ~take_first & ~take_pfirst & ~take_prefetch;

    // ------------------------------------------------------------ stripe ends
    wire stripe_end   = de_fall & (line_cnt == 5'd15);
    wire frame_last   = de_fall & (cur_stripe == LAST_STRIPE) &&
                        (line_cnt == (LAST_LINES[4:0] - 5'd1));
    // the first active pixel of a frame that never got stripe 0
    wire first_line_miss = de_rise & waiting_first;

    // --------------------------------------------------------- release queue
    // One stripe can end while a discarded descriptor is being returned, so two
    // pushes in one cycle are possible and both must be kept (depth 4).
    reg [31:0] q_job    [0:3];
    reg [6:0]  q_stripe [0:3];
    reg [1:0]  q_bank   [0:3];
    reg [1:0]  q_status [0:3];
    reg [1:0]  q_wp, q_rp;
    reg [2:0]  q_cnt;

    wire rel_pop = release_valid & release_ready;
    assign release_valid = (q_cnt != 0);
    // release payload: [63:43] 0, [42] bank[1], [41:40] status, [39] bank[0],
    //                  [38:32] stripe, [31:0] job   (bank[1] was reserved)
    wire [1:0] q_bank_head = q_bank[q_rp];
    assign release_data  = {21'd0, q_bank_head[1], q_status[q_rp],
                            q_bank_head[0], q_stripe[q_rp], q_job[q_rp]};

    // Normal stripe completion and the last stripe of the frame both release,
    // but only if this reader actually owned the stripe. During an underflow
    // (no offer, or the offer arrived too late) cur_ok is 0 and the writer may
    // still be filling that bank; releasing it then would clear the writer's
    // count and let the next stripe overwrite pixels that are still arriving.
    wire push_end = (stripe_end | frame_last) & cur_ok;

    // 2026-10-29 leak fix: a new frame clears cur_ok/have_next. If a bank was
    // still owned at that point (frame ended mid-stripe, or a prefetched stripe
    // was never promoted) the writer kept `reading[bank]` set forever, so its
    // px_ready stayed low, the bilinear stalled and the core deadlocked in
    // C_SAMPLE. Board signature: bank0_busy=1, px_ready=0, samp_busy=1,
    // sample_left frozen at 497. Both owned banks are now returned with
    // status=2 (discarded) at the frame boundary.
    //
    // 2026-10-31: if stripe 0 of the new frame is taken on this very edge, the
    // offer handshake has already set the writer's `reading` bit for `o_bank`.
    // Pushing the old frame's release for that same bank would clear it again and
    // desynchronise the two ownership views, so it is suppressed here.
    wire take_first_at_vs = vs_fall & take_first;
    wire rel_vs_cur  = vs_fall & cur_ok    & ~(take_first_at_vs & (cur_bank  == o_bank));
    wire rel_vs_next = vs_fall & have_next & ~(take_first_at_vs & (next_bank == o_bank));

    integer npush;
    always @(*) begin
        npush = (push_end ? 1 : 0) + (take_discard ? 1 : 0) +
                (rel_vs_cur ? 1 : 0) + (rel_vs_next ? 1 : 0);
    end

    // insertion offsets inside the 4-entry ring (2-bit arithmetic wraps)
    wire [1:0] off1 = push_end ? 2'd1 : 2'd0;
    wire [1:0] off2 = off1 + (take_discard ? 2'd1 : 2'd0);
    wire [1:0] off3 = off2 + (rel_vs_cur  ? 2'd1 : 2'd0);

    // The queue must never wrap: with four entries and at most two pushes per
    // cycle, requiring q_cnt + npush <= 4 keeps every entry intact. The producer
    // side drains at the stripe rate (one per 237 us), so this never limits it.
    wire push_ok = ((q_cnt + npush[2:0]) <= 3'd4);
    // If the queue were ever full this would silently drop ownership, which is
    // exactly the class of bug that deadlocked the board. Count it loudly instead
    // (the watchdog in dgc_stripe_writer is the last-resort recovery).
    wire rel_drop = (npush != 0) && !push_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wp <= 2'd0; q_rp <= 2'd0; q_cnt <= 3'd0;
            q_job[0] <= 32'd0; q_job[1] <= 32'd0; q_job[2] <= 32'd0; q_job[3] <= 32'd0;
            q_stripe[0] <= 7'd0; q_stripe[1] <= 7'd0; q_stripe[2] <= 7'd0; q_stripe[3] <= 7'd0;
            q_bank[0] <= 2'd0; q_bank[1] <= 2'd0; q_bank[2] <= 2'd0; q_bank[3] <= 2'd0;
            q_status[0] <= 2'd0; q_status[1] <= 2'd0; q_status[2] <= 2'd0; q_status[3] <= 2'd0;
            cnt_releases <= 32'd0;
            cnt_rel_drop <= 16'd0;
        end
        else begin
            if (push_ok && push_end) begin
                q_job[q_wp]    <= job_l;
                q_stripe[q_wp] <= cur_stripe;
                q_bank[q_wp]   <= cur_bank;
                q_status[q_wp] <= cur_ok ? 2'd0 : 2'd2;
            end
            if (push_ok && take_discard) begin
                q_job[q_wp + off1]    <= o_job;
                q_stripe[q_wp + off1] <= o_stripe;
                q_bank[q_wp + off1]   <= o_bank;
                q_status[q_wp + off1] <= 2'd2;
            end
            if (push_ok && rel_vs_cur) begin
                q_job[q_wp + off2]    <= job_l;
                q_stripe[q_wp + off2] <= cur_stripe;
                q_bank[q_wp + off2]   <= cur_bank;
                q_status[q_wp + off2] <= 2'd2;
            end
            if (push_ok && rel_vs_next) begin
                q_job[q_wp + off3]    <= job_l;
                q_stripe[q_wp + off3] <= cur_stripe + 7'd1;
                q_bank[q_wp + off3]   <= next_bank;
                q_status[q_wp + off3] <= 2'd2;
            end

            q_wp <= q_wp + (push_ok ? npush[1:0] : 2'd0);
            if (rel_pop) q_rp <= q_rp + 2'd1;
            q_cnt <= q_cnt + (push_ok ? npush[2:0] : 3'd0) - (rel_pop ? 3'd1 : 3'd0);
            if (rel_pop) cnt_releases <= cnt_releases + 32'd1;
            if (rel_drop && (cnt_rel_drop != 16'hFFFF))
                cnt_rel_drop <= cnt_rel_drop + 16'd1;
        end
    end

    // ------------------------------------------------------------ main FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_stripe <= 7'd0; cur_bank <= 1'b0; cur_ok <= 1'b0; frame_ok <= 1'b0;
            waiting_first <= 1'b1; line_cnt <= 5'd0;
            job_l <= 32'd0; have_next <= 1'b0; next_bank <= 1'b0;
            de_d <= 1'b0; vs_d <= 1'b0;
            cnt_underflow <= 32'd0; cnt_frames <= 32'd0; cnt_discard <= 32'd0;
            cnt_offers <= 32'd0;
            vs_discard_sticky <= 1'b0;
            pf_valid          <= 1'b0;
        end
        else begin
            de_d <= de_in; vs_d <= vs_in;
            if (take_offer) cnt_offers <= cnt_offers + 32'd1;
            if (rel_vs_cur || rel_vs_next) vs_discard_sticky <= 1'b1;

            // ------------------------------------------------- new frame
            if (vs_fall) begin
                cur_stripe    <= 7'd0;
                line_cnt      <= 5'd0;
                have_next     <= 1'b0;
                waiting_first <= 1'b1;
                frame_ok      <= 1'b0;
                cur_ok        <= 1'b0;
                cnt_frames    <= cnt_frames + 32'd1;
                if (pf_valid) begin
                    job_l         <= pf_job;
                    cur_bank      <= pf_bank;
                    cur_ok        <= 1'b1;
                    frame_ok      <= 1'b1;
                    waiting_first <= 1'b0;
                    pf_valid      <= 1'b0;
                end
            end

            // park the next job's stripe 0 for the coming frame
            if (take_pfirst) begin
                pf_valid <= 1'b1;
                pf_bank  <= o_bank;
                pf_job   <= o_job;
            end




            // ------------------------------------------------- stripe 0 lock
            if (take_first) begin
                job_l         <= o_job;
                cur_bank      <= o_bank;
                cur_ok        <= 1'b1;
                frame_ok      <= 1'b1;
                waiting_first <= 1'b0;
            end
            else if (take_prefetch) begin
                have_next <= 1'b1;
                next_bank <= o_bank;
            end
            else if (take_discard) begin
                cnt_discard <= cnt_discard + 32'd1;
            end

            // ------------------------------------------------- first line
            if (first_line_miss) begin
                // stripe 0 never arrived: this whole frame is black
                frame_ok      <= 1'b0;
                waiting_first <= 1'b0;
                cnt_underflow <= cnt_underflow + 32'd1;
                // 2026-11-01 flicker: record WHERE the frame starved. 0 means
                // stripe 0 missed the porch (job started too late / phase), any
                // other value means the writer fell behind mid-frame.
                dbg_uf_stripe <= 7'd0;
                dbg_uf_first  <= 1'b1;
            end
            // ------------------------------------------------- stripe switch
            if (stripe_end) begin
                line_cnt <= 5'd0;
                if (frame_ok) begin
                    cur_stripe <= cur_stripe + 7'd1;
                    cur_bank   <= next_bank;
                    cur_ok     <= have_next;
                    have_next  <= 1'b0;
                    if (!have_next) begin
                        frame_ok      <= 1'b0;
                        cnt_underflow <= cnt_underflow + 32'd1;
                        dbg_uf_stripe <= cur_stripe;   // starved while scanning this stripe
                        dbg_uf_first  <= 1'b0;
                    end
                end
            end
            else if (frame_last) begin
                // Stripe 67 was released above (push_end). Clear the ownership on
                // the same edge: leaving cur_ok set until vs_fall pushed a second
                // release for the same bank during vertical blanking, which could
                // clear the writer's `reading` bit for the next frame's stripe in
                // that bank (2026-10-31 ownership desync).
                frame_ok <= 1'b0;
                cur_ok   <= 1'b0;
            end
            else if (de_fall && frame_ok) begin
                line_cnt <= line_cnt + 5'd1;
            end
        end
    end

    // -------------------------------------------------------------- datapath
    // Addresses are issued from the live scan position; data comes back RD_LAT
    // cycles later, so DE/HS/VS, the bank select and the "this stripe is good"
    // flag are delayed to match.
    assign ram0_rd_addr = {y_in[3:0], x_in[10:0]};
    assign ram1_rd_addr = {y_in[3:0], x_in[10:0]};
    assign ram2_rd_addr = {y_in[3:0], x_in[10:0]};
    assign ram3_rd_addr = {y_in[3:0], x_in[10:0]};

    reg de_s   [0:RD_LAT-1];
    reg hs_s   [0:RD_LAT-1];
    reg vs_s   [0:RD_LAT-1];
    reg [1:0] bank_s [0:RD_LAT-1];
    reg ok_s   [0:RD_LAT-1];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < RD_LAT; i = i + 1) begin
                de_s[i] <= 1'b0; hs_s[i] <= 1'b0; vs_s[i] <= 1'b0;
                bank_s[i] <= 2'd0; ok_s[i] <= 1'b0;
            end
        end
        else begin
            de_s[0] <= de_in; hs_s[0] <= hs_in; vs_s[0] <= vs_in;
            bank_s[0] <= cur_bank; ok_s[0] <= cur_ok;
            for (i = 1; i < RD_LAT; i = i + 1) begin
                de_s[i] <= de_s[i-1]; hs_s[i] <= hs_s[i-1]; vs_s[i] <= vs_s[i-1];
                bank_s[i] <= bank_s[i-1]; ok_s[i] <= ok_s[i-1];
            end
        end
    end

    wire        de_dl   = de_s[RD_LAT-1];
    wire [1:0]  bank_dl = bank_s[RD_LAT-1];
    wire        ok_dl   = ok_s[RD_LAT-1];

    wire [23:0] ram_data = (bank_dl == 2'd0) ? ram0_rd_data :
                           (bank_dl == 2'd1) ? ram1_rd_data :
                           (bank_dl == 2'd2) ? ram2_rd_data : ram3_rd_data;

    assign rgb    = (de_dl && ok_dl) ? ram_data : 24'd0;
    assign de_out = de_dl;
    assign hs_out = hs_s[RD_LAT-1];
    assign vs_out = vs_s[RD_LAT-1];

    assign frame_black = ~frame_ok;

    assign dbg_cur_stripe    = cur_stripe;
    assign dbg_frame_ok      = frame_ok;
    assign dbg_cur_ok        = cur_ok;
    assign dbg_waiting_first = waiting_first;
    assign dbg_have_next     = have_next;
    assign dbg_cur_bank      = cur_bank;
    assign dbg_next_bank     = next_bank;
    assign dbg_events        = {rel_pop, vs_fall, take_discard, take_offer};
    assign dbg_vs_discard    = vs_discard_sticky;

endmodule























