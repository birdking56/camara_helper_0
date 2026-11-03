//-----------------------------------------------------------------------------
// dgc_stripe_writer.v
//
// Writes interpolated pixels into one of the output stripe RAMs at their final
// position and publishes the stripe once every position has arrived.
//
// Frozen reference: 接口冻结规范_v1.md section 10 (updated 2026-11-01: four banks).
//
//   stripe_id 0..67, start y = stripe_id*16; stripes 0..66 are 16 lines high,
//   stripe 67 is 8 lines high.
//   Each stripe row keeps 2048 slots; the pixel address is
//       stripe_addr[14:0] = {dst_y[3:0], dst_x[10:0]}
//   so x = 1920..2047 is unused padding and must never be treated as image data.
//
// Bank count (2026-11-01)
//   With two banks the write side can only be one stripe ahead of the display,
//   and 68 stripe periods are exactly one output frame (68 x 245 us = 16.66 ms
//   at 1080p60). A job therefore cannot finish measurably before the frame
//   boundary; with ALIGN_TO_FRAME it misses the next boundary and the whole
//   system drops to 30 jobs/s. The 2026-11-01 board capture showed exactly that
//   (jobs +30/s, V0=V3=2040=68x30, half the offers discarded, 45 underflows/s),
//   so the writer now owns FOUR banks:
//
//       bank = stripe_id[1:0]
//
//   At most two banks may be READING at any time (the stripe being scanned and
//   the one prefetched for the next stripe); that keeps the reader's single
//   prefetch slot valid. The other two banks let the write side run two stripes
//   ahead of the display, which is what shortens the job by ~0.5 ms - enough to
//   fit inside 16.67 ms.
//
// Offer/release bank field
//   The 64-bit stripe_offer payload keeps its frozen field order but widens the
//   bank field from one bit to two:
//       [63] reserved 0, [62] bank[1], [61] error, [60:56] valid_lines,
//       [55] bank[0], [54:48] stripe_id, [47:32] config_epoch, [31:0] job_id
//   The stripe_release payload carries bank[1] in bit 42 and bank[0] in bit 39
//   (bit 42 was reserved). This is an explicit interface revision, recorded in
//   the frozen spec and in docs/DGC5串口协议_20261031.md.
//
// Completion
//   A stripe becomes READY only when every real output position has been
//   written: 30,720 pixels for a normal stripe, 15,360 for the last one.
//
// Ownership
//   FREE -> WRITING -> READY -> READING -> FREE, one state per bank.
//   A bank may not be reused until the read side releases it.
//
// Reader-ownership watchdog (DGC5, 2026-10-31)
//   The release contract is owned by the reader, but a reader that went black
//   while still holding a bank sends no release, and the writer then waits
//   forever: `px_ready` stays low and the core deadlocks.  `job_restart`
//   deliberately does NOT free a reader-owned bank, so the only safe bound is a
//   deadline: a bank that stays in READING for more than RD_TIMEOUT proc cycles
//   (24.56 ms at 171 MHz = 1.5 output frames) is declared abandoned and
//   reclaimed.  This trades a torn stripe in a pathological case for "the next
//   frame can be produced"; the sticky flag says it happened.
//
// The four RAM instances reuse the two generated wrappers; no new IP is needed.
//-----------------------------------------------------------------------------

module dgc_stripe_writer #(
    parameter integer STRIPE_LINES = 16,
    // 4,200,000 proc cycles = 24.56 ms at 171 MHz (1.5 x 16.67 ms).  Parameterised
    // so the directed test can shrink it instead of simulating 4.2M cycles.
    parameter integer RD_TIMEOUT   = 4200000
) (
    input  wire        clk,          // proc domain, 171 MHz
    input  wire        rst_n,

    // ---------------- configuration for the running job ----------------------
    input  wire [31:0] job_id,
    input  wire [15:0] config_epoch,
    input  wire        job_restart,   // start a new frame: reset stripe bookkeeping
    // 2026-11-02: job-level abort (the job watchdog fired because a bank was never
    // released). Unlike job_restart this must ALSO return reader-owned banks to
    // FREE: the reader gave up its ownership when it went black and will never send
    // the release, so keeping `reading` set guarantees that the next job stalls on
    // the same bank and the panel stays black until power cycle (observed on the
    // board). The trade-off is a possibly torn stripe that is no longer on screen.
    input  wire        job_abort,

    // ---------------- pixel stream from bilinear -----------------------------
    input  wire        px_valid,
    output wire        px_ready,
    input  wire [63:0] px_data,

    // ---------------- ownership ---------------------------------------------
    output wire [3:0]  bank_busy,     // one bit per bank: WRITING|READY|READING
    output wire        bank0_busy,    // aliases kept for the ownership testbenches
    output wire        bank1_busy,
    output wire [11:0] bank_state,    // {w3,r3,rd3, w2,r2,rd2, w1,r1,rd1, w0,r0,rd0}
    output wire [6:0]  cur_sid0_out,  // stripe id currently in bank0 (diagnostic)
    input  wire        rel,
    input  wire [1:0]  release_bank,
    input  wire        release_status_bad,   // underflow / discard

    // ---------------- stripe_offer ------------------------------------------
    output wire        offer_valid,
    input  wire        offer_ready,
    output wire [63:0] offer_data,

    // ---------------- read ports for the output reader ----------------------
    // The banks are owned by the write side; the reader addresses them through
    // these ports so the memories are shared rather than duplicated.
    input  wire        ram_rd_clk,     // output-reader clock (vout domain)
    input  wire        ram_rd_rst_n,   // output-reader reset (vout domain)
    input  wire [14:0] ram0_rd_addr,
    output wire [23:0] ram0_rd_data,
    input  wire [14:0] ram1_rd_addr,
    output wire [23:0] ram1_rd_data,
    input  wire [14:0] ram2_rd_addr,
    output wire [23:0] ram2_rd_data,
    input  wire [14:0] ram3_rd_addr,
    output wire [23:0] ram3_rd_data,

    // ---------------- diagnostics -------------------------------------------
    output wire [31:0] cnt_stripes_done,
    output wire [31:0] cnt_pixels_written,
    output wire        dbg_rd_timeout,     // sticky: a bank was reclaimed by the watchdog
    output wire [15:0] cnt_rd_timeout      // number of watchdog reclamations
);

    localparam integer NBANK = 4;
    localparam [31:0] PIX_PER_STRIPE  = 32'd30720;   // 1920 x 16
    localparam [31:0] PIX_LAST_STRIPE = 32'd15360;   // 1920 x 8
    localparam [23:0] RD_TO           = RD_TIMEOUT;  // watchdog deadline, proc cycles

    // ------------------------------------------------------------- pixel decode
    wire [10:0] dx     = px_data[34:24];
    wire [10:0] dy     = px_data[45:35];
    wire        merr   = px_data[63];

    wire [6:0]  sid    = dy[10:4];                 // dst_y / 16, 0..67
    wire [3:0]  ly     = dy[3:0];
    wire [14:0] waddr  = {ly, dx};                 // {dst_y[3:0], dst_x[10:0]}
    wire [23:0] wdata  = px_data[23:0];

    // A pixel outside the active area must never be written: the padding columns
    // 1920..2047 exist only because the row is 2048 slots wide.
    wire in_active = (dx < 11'd1920) && (dy < 11'd1080);

    wire wr_fire = px_valid & px_ready & in_active;

    // ------------------------------------------------------------ bank choice
    // 2026-11-01 (second revision): THREE banks instead of four.  The device was
    // at 123/155 DRM (80 %) and the four 32Kx24 stripe RAMs dominated placement;
    // the remaining timing failures were pure routing (one logic level + 5.9 ns
    // of wire).  Three banks free ~23 DRM blocks.  Throughput is unchanged: the
    // in-flight cap below is 2, so the write side is always exactly two stripes
    // ahead of the display whether it has three banks or four.
    //
    // bank = stripe_id % 3.  4 == 1 (mod 3), so the 7-bit id reduces to a short
    // sum of 2-bit groups and a three-way compare - a few LUT levels.
    // 2026-11-02: back to FOUR banks.  Three banks cannot hold the pending first
    // stripe of the next frame (cur + next + pf) and still leave one bank for the
    // writer, which is what the display needs to stay fed across a late job start.
    // stripe_id[1:0] picks the bank, so no divider in the pixel path.
    wire [1:0] wr_bank = sid[1:0];

    reg  [6:0]  cur_sid [0:3];
    reg  [31:0] cnt     [0:3];
    reg         writing [0:3];
    reg         ready   [0:3];
    // `reading` is set when the output side accepts the offer and is cleared
    // only by stripe_release (or by the watchdog).
    reg         reading [0:3];
    // How long each bank has been in READING. Cleared to zero on every non-
    // READING cycle, so it always measures the current ownership interval.
    reg  [23:0] rd_age [0:3];
    reg         rd_timeout_sticky;
    reg  [15:0] rd_timeout_cnt;
    reg  [31:0] stripe_cnt;
    reg  [31:0] pixel_cnt;
    // RAM write stage (see the timing note in the sequential block)
    reg         wr_pending;
    reg  [14:0] waddr_r;
    reg  [23:0] wdata_r;
    reg  [1:0]  wbank_r;

    assign dbg_rd_timeout = rd_timeout_sticky;
    assign cnt_rd_timeout = rd_timeout_cnt;

    assign bank_busy = {writing[3] | ready[3] | reading[3],
                        writing[2] | ready[2] | reading[2],
                        writing[1] | ready[1] | reading[1],
                        writing[0] | ready[0] | reading[0]};
    assign bank0_busy = bank_busy[0];
    assign bank1_busy = bank_busy[1];

    assign bank_state = {writing[3], ready[3], reading[3],
                         writing[2], ready[2], reading[2],
                         writing[1], ready[1], reading[1],
                         writing[0], ready[0], reading[0]};
    assign cur_sid0_out = cur_sid[0];

    // expected count for a stripe
    function [31:0] expected_pixels(input [6:0] s);
        begin
            expected_pixels = (s == 7'd67) ? PIX_LAST_STRIPE : PIX_PER_STRIPE;
        end
    endfunction

    // ---------------------------------------------------------- write / count
    wire [31:0] wr_cnt_sel = cnt[wr_bank];
    // A bank may accept the next stripe only after the output side has released
    // the previous one; `writing` covers the stripe in progress, `ready` the
    // completed (or already offered) stripe and `reading` the stripe the video
    // reader currently owns. Pixels belonging to the stripe already in progress
    // are of course still accepted - only a *different* stripe is held back.
    wire        wr_same_stripe = writing[wr_bank] && (cur_sid[wr_bank] == sid);
    wire        wr_bank_busy   = ready[wr_bank] | reading[wr_bank] |
                                 (writing[wr_bank] & ~wr_same_stripe);
    wire        wr_ok          = ~wr_bank_busy;

    // Pixels outside the active area are consumed and dropped instead of
    // stalling the pipeline forever; bilinear should never emit one, but a
    // math-error or a boundary record must not deadlock the whole core.
    // Pixels outside the active area are consumed and dropped instead of
    // stalling the pipeline forever; bilinear should never emit one, but a
    // math-error or a boundary record must not deadlock the whole core.
    assign px_ready = ~in_active | wr_ok;

    // ------------------------------------------------------------ offer select
    // Offers must describe the OLDEST completed stripe: the reader only accepts
    // stripe cur+1, so publishing a newer ready stripe first would make it
    // discard that stripe and throw the completed pixels away.  A 3-way/4-way
    // minimum over cur_sid is cheap enough at 171 MHz (7-bit compare each).
    reg  [1:0] off_bank;
    reg  [6:0] off_sid;
    always @(*) begin
        off_bank = 2'd0;
        off_sid  = 7'd0;
        if (ready[0]) begin
            off_bank = 2'd0;
            off_sid  = cur_sid[0];
        end
        if (ready[1] && ((cur_sid[1] < off_sid) || !ready[0])) begin
            off_bank = 2'd1;
            off_sid  = cur_sid[1];
        end
        if (ready[2] && ((cur_sid[2] < off_sid) || (!ready[0] && !ready[1]))) begin
            off_bank = 2'd2;
            off_sid  = cur_sid[2];
        end
        if (ready[3] && ((cur_sid[3] < off_sid) || (!ready[0] && !ready[1] && !ready[2]))) begin
            off_bank = 2'd3;
            off_sid  = cur_sid[3];
        end
    end

    // At most two banks may be READING (the scanned stripe plus its prefetch).
    // A third offer would be discarded by the reader and its pixels lost, so the
    // writer holds completed stripes in READY until a bank comes back.  The
    // count is derived from the ownership bits, not from a separate counter, so
    // a watchdog reclamation or a discard automatically restores capacity.
    wire [2:0] n_reading = {2'd0, reading[0]} + {2'd0, reading[1]} +
                           {2'd0, reading[2]} + {2'd0, reading[3]};
    wire any_ready = ready[0] | ready[1] | ready[2] | ready[3];

    // 2026-11-02: the three-in-flight allowance for a stripe 0 must be enabled only
    // together with the reader's pending-first path (PF_EN in dgc_video_reader).
    // With PF_EN = 0 the reader would DISCARD that third stripe, so every frame
    // lost its stripe 0 and the panel stayed black (board 15:30).  Keep this at
    // two in flight until PF_EN is turned on.
    assign offer_valid = any_ready && (n_reading < 3'd2);
    // stripe_offer payload, frozen field order (LSB first) with the 2026-11-01
    // two-bit bank extension:
    //   [63] reserved0, [62] bank[1], [61] error, [60:56] valid_lines5,
    //   [55] bank[0], [54:48] stripe_id7, [47:32] epoch16, [31:0] job_id32
    wire [4:0]  off_lines = (off_sid == 7'd67) ? 5'd8 : 5'd16;

    assign offer_data = {
        1'b0,           // [63]    reserved, must be zero
        off_bank[1],    // [62]    bank[1]  (reserved before 2026-11-01)
        1'b0,           // [61]    error
        off_lines,      // [60:56] valid_lines
        off_bank[0],    // [55]    bank[0]
        off_sid,        // [54:48] stripe_id
        config_epoch,   // [47:32] config_epoch
        job_id          // [31:0]  job_id
    };

    assign cnt_stripes_done   = stripe_cnt;
    assign cnt_pixels_written = pixel_cnt;

    // Every per-bank signal is driven from this single sequential block.
    integer b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (b = 0; b < NBANK; b = b + 1) begin
                cur_sid[b] <= 7'd0;
                cnt[b]     <= 32'd0;
                writing[b] <= 1'b0;
                ready[b]   <= 1'b0;
                reading[b] <= 1'b0;
                rd_age[b]  <= 24'd0;
            end
            rd_timeout_sticky <= 1'b0;
            rd_timeout_cnt <= 16'd0;
            stripe_cnt <= 32'd0;
            pixel_cnt  <= 32'd0;
            wr_pending <= 1'b0;
            waddr_r    <= 15'd0;
            wdata_r    <= 24'd0;
            wbank_r    <= 2'd0;
        end
        else begin
            // job_restart abandons the *pending* stripes of the old job, but it
            // must not free a bank the reader still owns: the new job's stripe 0
            // would otherwise overwrite the previous frame while it is on screen.
            if (job_restart) begin
                for (b = 0; b < NBANK; b = b + 1) begin
                    cur_sid[b] <= 7'd0;
                    cnt[b]     <= 32'd0;
                    writing[b] <= 1'b0;
                    ready[b]   <= 1'b0;
                end
                stripe_cnt <= 32'd0;
                pixel_cnt  <= 32'd0;
            end

            // job_abort: the job watchdog gave up on this job. Nothing the reader
            // owns can ever come back, so every bank (including `reading`) and its
            // deadline counter return to FREE. This is what keeps a single wedged
            // bank from killing every following job.
            if (job_abort) begin
                for (b = 0; b < NBANK; b = b + 1) begin
                    cur_sid[b] <= 7'd0;
                    cnt[b]     <= 32'd0;
                    writing[b] <= 1'b0;
                    ready[b]   <= 1'b0;
                    reading[b] <= 1'b0;
                    rd_age[b]  <= 24'd0;
                end
                stripe_cnt <= 32'd0;
                pixel_cnt  <= 32'd0;
            end

            // ------------------------------------------------ read side releases
            // Process the release first so a same-cycle new offer (which can
            // only happen after the bank was free in an earlier cycle) wins.
            if (rel && !job_abort) begin
                ready[release_bank]   <= 1'b0;
                writing[release_bank] <= 1'b0;
                reading[release_bank] <= 1'b0;
                cnt[release_bank]     <= 32'd0;
            end

            // ------------------------------------------------ reader watchdog
            // A bank that the reader accepted but never returned (reader went
            // black and cleared its own ownership) is reclaimed after RD_TIMEOUT
            // cycles. This never fires in a healthy stream: the release arrives
            // one stripe period (~245 us) after the offer.
            for (b = 0; b < NBANK; b = b + 1) begin
                if (reading[b] && !job_abort && !(rel && (release_bank == b))) begin
                    if (rd_age[b] >= RD_TO - 24'd1) begin
                        reading[b] <= 1'b0;
                        cnt[b]     <= 32'd0;
                        rd_age[b]  <= 24'd0;
                        rd_timeout_sticky <= 1'b1;
                        if (rd_timeout_cnt != 16'hFFFF)
                            rd_timeout_cnt <= rd_timeout_cnt + 16'd1;
                    end
                    else rd_age[b] <= rd_age[b] + 24'd1;
                end
                else rd_age[b] <= 24'd0;
            end

            // ------------------------------------------------ accept a pixel
            if (wr_fire && !job_restart && !job_abort) begin
                pixel_cnt <= pixel_cnt + 32'd1;

                if (!writing[wr_bank] && !ready[wr_bank] && !reading[wr_bank]) begin
                    writing[wr_bank] <= 1'b1;
                    cur_sid[wr_bank] <= sid;
                    cnt[wr_bank]     <= 32'd1;
                end
                else begin
                    cnt[wr_bank] <= wr_cnt_sel + 32'd1;
                    if (wr_cnt_sel + 32'd1 == expected_pixels(cur_sid[wr_bank])) begin
                        ready[wr_bank]   <= 1'b1;
                        writing[wr_bank] <= 1'b0;
                    end
                end
            end

            // ------------------------------------------------ stripe published
            // The handshake hands ownership to the reader: the bank stays busy
            // until stripe_release, so it can no longer be overwritten while the
            // display scans it.
            if (offer_valid && offer_ready && !job_abort) begin
                ready[off_bank]   <= 1'b0;
                reading[off_bank] <= 1'b1;
                stripe_cnt <= stripe_cnt + 32'd1;
            end

            // ------------------------------------------------ RAM write stage
            // 2026-11-01 timing: the RAM write enable used to be combinationally
            // `wr_fire & (wr_bank == n)`, i.e. it came out of the whole accept
            // chain (sid -> bank -> per-bank state -> px_ready).  In the 12:29
            // P&R that was the -0.372 ns path (cur_sid -> u_ram2/WEA).  Registering
            // the write port data/address/enable one cycle after the accept splits
            // it: the RAM pins are now driven by flops placed next to them.
            // Functionally transparent: the count/ownership logic still advances
            // on the accept edge, and the reader only reads a stripe long after
            // its last pixel (offer -> mailbox -> scan).  A pixel left in this
            // stage by a job_restart belongs to the abandoned stripe and lands in
            // a bank that the new job overwrites before it is offered.
            wr_pending <= wr_fire;
            if (wr_fire) begin
                waddr_r <= waddr;
                wdata_r <= wdata;
                wbank_r <= wr_bank;
            end
        end
    end

    // --------------------------------------------------------------- the RAMs
    // Four instances of the two generated wrappers. The read port is reset by
    // the *output* domain reset, never by the processing reset (an asynchronous
    // reset from proc_clk into a register clocked by ram_rd_clk is a CDC
    // violation and also held the read port in reset in simulation).
    out_stripe_ram u_ram0 (
        .wr_data (wdata_r), .wr_addr (waddr_r), .wr_en (wr_pending & (wbank_r == 2'd0)),
        .wr_clk  (clk),   .wr_rst  (~rst_n),
        .rd_data (ram0_rd_data), .rd_addr (ram0_rd_addr),
        .rd_clk  (ram_rd_clk),   .rd_rst  (~ram_rd_rst_n)
    );

    out_stripe_ram_1 u_ram1 (
        .wr_data (wdata_r), .wr_addr (waddr_r), .wr_en (wr_pending & (wbank_r == 2'd1)),
        .wr_clk  (clk),   .wr_rst  (~rst_n),
        .rd_data (ram1_rd_data), .rd_addr (ram1_rd_addr),
        .rd_clk  (ram_rd_clk),   .rd_rst  (~ram_rd_rst_n)
    );

    // Banks 2 and 3 reuse the same two wrappers; the tool infers four RAMs.
    out_stripe_ram u_ram2 (
        .wr_data (wdata_r), .wr_addr (waddr_r), .wr_en (wr_pending & (wbank_r == 2'd2)),
        .wr_clk  (clk),   .wr_rst  (~rst_n),
        .rd_data (ram2_rd_data), .rd_addr (ram2_rd_addr),
        .rd_clk  (ram_rd_clk),   .rd_rst  (~ram_rd_rst_n)
    );
    out_stripe_ram_1 u_ram3 (
        .wr_data (wdata_r), .wr_addr (waddr_r), .wr_en (wr_pending & (wbank_r == 2'd3)),
        .wr_clk  (clk),   .wr_rst  (~rst_n),
        .rd_data (ram3_rd_data), .rd_addr (ram3_rd_addr),
        .rd_clk  (ram_rd_clk),   .rd_rst  (~ram_rd_rst_n)
    );

endmodule




















