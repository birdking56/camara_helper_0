//-----------------------------------------------------------------------------
// dgc_core.v
//
// The processing core: block scheduling, inverse mapping, source fetch/cache,
// four-neighbour sampling, gamma, bilinear and stripe writing, wired into one
// pipeline in the processing clock domain.
//
// Frozen reference: 接口冻结规范_v1.md sections 5, 6, 8, 9, 10 and 12.
//
// Block protocol (section 6)
//   dgc_coord_stage reserves FIFO space, maps a candidate, accumulates the exact
//   bbox and commits a descriptor. This module consumes descriptors in order:
//
//     ACCEPT : fill one cache set, then sample exactly record_count coordinates
//              through gamma and bilinear; release the set after the sampler and
//              the pixel pipeline have drained.
//     SPLIT  : discard record_count coordinates (the scheduler already re-issued
//              the halves); no output pixels.
//     BLACK  : feed the coordinates to bilinear as invalid samples, which the
//              frozen spec turns into exactly one black pixel each.
//
//   Blocks are processed one at a time (fill then sample). The fill of block N+1
//   runs underneath the sample of block N. Until 2026-11-02 a block boundary also
//   required a C_DRAIN state that waited for the pixel pipeline to empty; the core
//   now switches blocks inline on the last accepted record whenever the next
//   block's fill is already complete (the common case under display pacing) and
//   only falls back to C_DRAIN otherwise (frame tail, black blocks, late fill).
//   This changes no interface: the pixel stream stays in order and the cache owner
//   still sees one sample_begin/sample_rel pair per block.
//
// External DDR
//   Row descriptors leave through the frozen fetch_row channel; the caller puts
//   them through the proc->ddr mailbox. Returned beats arrive on beat_* from the
//   read FIFO's port wrapper. The native adapters are verified separately.
//-----------------------------------------------------------------------------

module dgc_core (
    input  wire        clk,             // proc_clk
    input  wire        rst_n,

    // ---------------- job ----------------------------------------------------
    input  wire        job_start,
    // Cancel coordinate/pixel work and drop abandoned stripe ownership. A source
    // fill already in flight keeps draining; src_idle marks when its DDR source
    // slot may safely be returned. The next job_start resets cache ownership.
    input  wire        job_abort,
    input  wire [31:0] job_id,
    input  wire [31:0] frame_base,

    // ---------------- active configuration ----------------------------------
    input  wire [1:0]  cfg_mode,
    input  wire signed [31:0] cfg_m00, cfg_m01, cfg_m02,
    input  wire signed [31:0] cfg_m10, cfg_m11, cfg_m12,
    input  wire signed [31:0] cfg_fx, cfg_fy, cfg_cx, cfg_cy,
    input  wire signed [31:0] cfg_k1, cfg_k2,
    input  wire [31:0] cfg_norm_abs_max,
    input  wire [1:0]  gamma_mode,

    // ---------------- fetch_row channel to the DDR domain --------------------
    output wire        row_valid,
    input  wire        row_ready,
    output wire [31:0] row_addr,
    output wire [4:0]  row_beats,
    output wire [4:0]  row_head_skip,
    output wire [7:0]  row_valid_bytes,
    output wire [5:0]  row_local_y,
    output wire        row_row_last,
    output wire        row_set,
    output wire [15:0] row_tag,
    output wire [31:0] row_job_id,

    // ---------------- returned beats ----------------------------------------
    input  wire        beat_valid,
    output wire        beat_ready,
    input  wire [255:0] beat_data,

    // ---------------- stripe RAM read ports (reader side) -------------------
    input  wire        ram_rd_clk,     // vout clock for the stripe RAM read ports
    input  wire        ram_rd_rst_n,   // vout domain reset for those ports
    input  wire [14:0] ram0_rd_addr,
    output wire [23:0] ram0_rd_data,
    input  wire [14:0] ram1_rd_addr,
    output wire [23:0] ram1_rd_data,
    input  wire [14:0] ram2_rd_addr,
    output wire [23:0] ram2_rd_data,
    input  wire [14:0] ram3_rd_addr,
    output wire [23:0] ram3_rd_data,

    // ---------------- stripe offer / release --------------------------------
    output wire        offer_valid,
    input  wire        offer_ready,
    output wire [63:0] offer_data,
    input  wire        rel,
    input  wire [1:0]  release_bank,
    input  wire        release_status_bad,

    // ---------------- status -------------------------------------------------
    output wire        frame_done,
    // 2026-11-02: "this job will never read its source frame again". True while the
    // scheduler has dispatched every block, the current block has taken its last
    // coordinate record, the fill engine is idle, no next block is queued and no
    // row request is pending - i.e. no further DDR read of `frame_base` can be
    // issued. The remaining work is only pixel *emission*, which the stripe writer
    // paces against the display and which can therefore take milliseconds.
    // dgc_core_sys releases the DDR frame slot on this level instead of when the
    // last pixel has been accepted, so the capture side gets the slot back ~4 ms
    // earlier (see the job FSM in dgc_core_sys).
    output wire        src_idle,
    output wire        busy,
    output wire [15:0] cnt_accept,
    output wire [15:0] cnt_black,
    output wire [15:0] cnt_split,
    output wire [31:0] cnt_pixels,
    output wire [31:0] cnt_blocks_done,

    // Debug-only observation for the UART.
    output wire [2:0]  dbg_cstate,
    output wire        dbg_fill_busy,
    output wire        dbg_samp_busy,
    output wire        dbg_next_valid,
    output wire [9:0]  dbg_sample_left,
    // Full 10-bit record count: an 8-bit view turned the legitimate 512-record
    // block into 0x00 and produced a false "empty block" diagnosis on 10-27.
    output wire [9:0]  dbg_recs_total,
    // Pixels of the current block that actually reached the stripe writer. The
    // C_DRAIN exit waits for this to equal recs_total; without the tap a stall
    // there is indistinguishable from a stalled next-block prefetch.
    output wire [15:0] dbg_pix_seen,
    // {bank1_busy, bank0_busy, px_ready}: a bank stays busy while
    // WRITING/READY/READING, and px_ready is what actually back-pressures the
    // bilinear. If px_ready is 1 and the sampler still stalls, the stall is
    // inside the bilinear/gamma pipeline, not in stripe ownership.
    // 2026-11-01: banks 2/3 are summarised by dbg_aux_busy (J2 bit 3).
    output wire [2:0]  dbg_wr_busy,
    output wire        dbg_aux_busy,       // bank2_busy | bank3_busy
    // Individual stripe-writer bank ownership bits, because the OR shown by
    // dbg_wr_busy cannot tell "writing the stripe in progress" (normal) from
    // "still held by the reader" (deadlock). 2026-11-01: four banks, order:
    //   [11] writing3 [10] ready3 [9] reading3
    //   [8]  writing2 [7]  ready2 [6] reading2
    //   [5]  writing1 [4]  ready1 [3] reading1
    //   [2]  writing0 [1]  ready0 [0] reading0
    output wire [11:0] dbg_wr_state,
    // Current output pixel's stripe id and bank0's stripe id, so a stalled
    // px_ready can be attributed to a sid mismatch instead of guessed at.
    // DGC5: full 7 bits (the previous 5-bit slice truncated stripes >= 32).
    output wire [6:0]  dbg_pix_sid,
    output wire [6:0]  dbg_cur_sid0,
    // The reader-ownership bits, i.e. the deadlock-critical subset of
    // dbg_wr_state: {reading3, reading2, reading1, reading0}. DGC5's K word 2
    // carries the low two; J2 bit 3 carries "any of banks 2/3 busy".
    output wire [3:0]  dbg_reading,
    // Sticky: the stripe-writer watchdog had to reclaim a reader-owned bank
    // (see dgc_stripe_writer RD_TIMEOUT). Never 1 in a healthy stream.
    output wire        dbg_rd_timeout,
    // Live overshoot of the block pixel counter: pix_seen - recs_total when
    // pix_seen is larger. Board run 2026-10-29 13:26 showed pix_seen=524 for a
    // 512-record block; the old equality test then deadlocked C_DRAIN forever.
    // The exit now uses >= and this byte records how large the overshoot is.
    output wire [7:0]  dbg_pix_over,
    output wire [7:0]  dbg_fill_flags,
    // Performance taps for the DGC3 report (2026-10-30). Pure read-only
    // observations used to split the 28 ms job into fill waits / sample stalls:
    //   dbg_fill_wr        : the source cache write port is taking a record (1 or 2 px)
    //   dbg_fill_wait_beat : a row is loaded but its next DDR beat is late
    //   dbg_fill_wait_row  : the planner has a row but the DDR-side channel is
    //                        not accepting it (mailbox / request queue)
    //   dbg_fill_wait_plan : the unpack has no row descriptor to work on
    //   dbg_samp_stall_wr  : a pixel is ready but the stripe writer takes none
    //   dbg_samp_stall_smp : the sampler has no sample available (cache reads)
    output wire        dbg_fill_wr,
    output wire        dbg_fill_wait_beat,
    output wire        dbg_fill_wait_row,
    output wire        dbg_fill_wait_plan,
    output wire        dbg_samp_stall_wr,
    output wire        dbg_samp_stall_smp
);

    // =============================================================== scheduler
    wire        blk_valid, blk_ready;
    wire [15:0] blk_tag;
    wire [6:0]  blk_stripe;
    wire [10:0] blk_x0, blk_y0;
    wire [6:0]  blk_w, blk_h;
    wire        rpt_valid, split_valid;
    wire        sched_frame_done;
    wire [15:0] sched_cnt_blocks;
    wire [31:0] sched_cnt_split;

    // ---------------------------------------------------- shared declarations
    // Declared before every instantiation that references them; mixing an
    // implicit net with a later explicit declaration is a compile error.
    reg         fill_start;
    reg  [31:0] fill_base;
    reg  [15:0] fill_tag;
    reg  [10:0] fill_bx, fill_by;
    reg  [6:0]  fill_bw, fill_bh;

    wire        cache_wr;
    wire        cache_wr2;
    wire [5:0]  cache_x, cache_y;
    wire [23:0] cache_rgb, cache_rgb2;

    reg         black_mode;
    reg         cur_accept;
    reg         job_cancelled;

    // ------------------------------------------------------ job-boundary flush
    // A new job must not consume anything produced for the previous one. The
    // scheduler/fill/writer already restart on job_start, but the coordinate
    // FIFO and the sample pipelines did not: the first stale record (a stripe
    // 18 coordinate from the old frame) re-armed the just-cleared bank0 as
    // stripe 18 and blocked the new job's stripe-0 pixels forever
    // (board 2026-10-29: cur_sid0=18, pix_sid=0, px_ready stuck low).
    // Clear the complete coordinate stage, FIFO and sample pipelines on the
    // event edge and for two following cycles before new blocks may start.
    reg  [1:0] job_flush_sh;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) job_flush_sh <= 2'b00;
        else        job_flush_sh <= {job_flush_sh[0], job_start | job_abort};
    end
    wire job_flush = job_start | job_abort | (|job_flush_sh);

    dgc_tile_scheduler u_sched (
        .clk (clk), .rst_n (rst_n & ~job_abort),
        .frame_start (job_start),
        .blk_valid (blk_valid), .blk_ready (blk_ready),
        .blk_tag (blk_tag), .blk_stripe (blk_stripe),
        .blk_x0 (blk_x0), .blk_y0 (blk_y0), .blk_w (blk_w), .blk_h (blk_h),
        .rpt_valid (rpt_valid),
        .split_valid (split_valid), .split_tag (16'd0),
        .split_w (7'd0), .split_h (7'd0),
        .frame_done (sched_frame_done), .cnt_blocks (sched_cnt_blocks),
        .cnt_split (sched_cnt_split), .next_tag ()
    );

    // ============================================================= coordinate
    wire        cf_valid, cf_ready;
    wire [95:0] cf_data;
    wire        fifo_full, fifo_empty;
    wire [12:0] fifo_wl, fifo_rl;
    wire        fifo_rd_valid;
    wire [95:0] fifo_rd_data;
    wire        fifo_rd_ready_o;
    wire        fifo_rd_fire;
    wire        fifo_rd_accept;
    wire [12:0] fifo_free = 13'd2048 - fifo_wl;

    wire        desc_valid;
    wire        desc_ready;
    wire [31:0] d_job_id;
    wire [15:0] d_tag;
    wire [6:0]  d_stripe;
    wire [10:0] d_out_x, d_out_y;
    wire [5:0]  d_out_w;
    wire [4:0]  d_out_h;
    wire [9:0]  d_rec_count;
    wire [10:0] d_bbox_x, d_bbox_y;
    wire [6:0]  d_bbox_w, d_bbox_h;
    wire [1:0]  d_kind;
    wire        d_math_error;

    dgc_coord_stage u_coord (
        .clk (clk), .rst_n (rst_n), .flush (job_flush), .job_id (job_id),
        .cfg_mode (cfg_mode),
        .cfg_m00 (cfg_m00), .cfg_m01 (cfg_m01), .cfg_m02 (cfg_m02),
        .cfg_m10 (cfg_m10), .cfg_m11 (cfg_m11), .cfg_m12 (cfg_m12),
        .cfg_fx (cfg_fx), .cfg_fy (cfg_fy), .cfg_cx (cfg_cx), .cfg_cy (cfg_cy),
        .cfg_k1 (cfg_k1), .cfg_k2 (cfg_k2),
        .cfg_norm_abs_max (cfg_norm_abs_max),
        .blk_valid (blk_valid), .blk_ready (blk_ready),
        .blk_tag (blk_tag), .blk_stripe (blk_stripe),
        .blk_x0 (blk_x0), .blk_y0 (blk_y0), .blk_w (blk_w), .blk_h (blk_h),
        .rpt_valid (rpt_valid), .split_valid (split_valid),
        .cf_valid (cf_valid), .cf_ready (cf_ready), .cf_data (cf_data),
        .fifo_free (fifo_free),
        .desc_valid (desc_valid), .desc_ready (desc_ready),
        .d_job_id (d_job_id), .d_tag (d_tag), .d_stripe (d_stripe),
        .d_out_x (d_out_x), .d_out_y (d_out_y),
        .d_out_w (d_out_w), .d_out_h (d_out_h),
        .d_rec_count (d_rec_count),
        .d_bbox_x (d_bbox_x), .d_bbox_y (d_bbox_y),
        .d_bbox_w (d_bbox_w), .d_bbox_h (d_bbox_h),
        .d_kind (d_kind), .d_math_error (d_math_error),
        .cnt_accept (cnt_accept), .cnt_black (cnt_black),
        .cnt_split_done (cnt_split), .busy ()
    );

    // 2026-11-01 timing: the global proc reset net routed to the coord FIFO's
    // DRAM reset pins was a -0.565 ns path (rst_proc sync -> coord_fifo RSTB).
    // A local one-cycle replica breaks that long route: the path from the global
    // synchroniser now ends at this flop, and the DRAM pins are driven by a flop
    // placed next to them.  The reset is released one cycle later than before,
    // which is irrelevant because the FIFO is only written after the job FSM
    // leaves reset.
    reg cfifo_rst_n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cfifo_rst_n <= 1'b0;
        else        cfifo_rst_n <= 1'b1;
    end

    dgc_coord_fifo u_cfifo (
        .clk (clk), .rst_n (cfifo_rst_n), .flush (job_flush),
        .wr_valid (cf_valid), .wr_ready (cf_ready), .wr_data (cf_data),
        .rd_fire (fifo_rd_fire), .rd_ready (fifo_rd_accept),
        .rd_valid (fifo_rd_valid), .rd_ready_o (fifo_rd_ready_o),
        .rd_data (fifo_rd_data),
        .full (fifo_full), .empty (fifo_empty),
        .wr_level (fifo_wl), .rd_level (fifo_rl)
    );

    // ============================================================ source cache
    wire        owner_fill_begin, owner_fill_ok, owner_fill_complete, owner_fill_abort;
    wire [1:0]  owner_fill_set;
    wire        set0_ready, set1_ready;
    wire [15:0] set0_tag, set1_tag;
    wire [1:0]  set0_state, set1_state;
    reg         sample_begin, sample_rel;
    // 2026-11-02: release the cache set as soon as the block's pixels are out and the
    // sampler is idle, instead of waiting for the *next* block's fill.  Waiting for
    // that fill while holding both sets is a circular wait: the fill needs the set
    // this block still owns (the pending-first stripe parks the pipeline long enough
    // to hit it every frame).
    reg         rel_done;

    dgc_cache_owner u_owner (
        .clk (clk), .rst_n (rst_n & ~job_start),
        .fill_begin (owner_fill_begin), .fill_tag (fill_tag),
        .fill_complete (owner_fill_complete), .fill_abort (owner_fill_abort),
        .sample_begin (sample_begin), .rel (sample_rel),
        .fill_set (owner_fill_set),
        .set0_ready (set0_ready), .set1_ready (set1_ready),
        .set0_tag (set0_tag), .set1_tag (set1_tag),
        .set0_state (set0_state), .set1_state (set1_state),
        .fill_ok (owner_fill_ok),
        .cnt_fill (), .cnt_sample (), .cnt_release ()
    );

    // ================================================================ fill ctrl
    wire        fill_busy, fill_done;
    // A new job must not inherit a half-finished fill from the previous one.
    wire        fill_abort = job_start;
    wire [1:0]  fill_set;
    wire [31:0] fill_cnt_px, fill_cnt_blocks, fill_cnt_abort;

    dgc_fill_ctrl u_fill (
        .clk (clk), .rst_n (rst_n),
        .start (fill_start), .frame_base (fill_base), .job_id (job_id),
        .tag (fill_tag), .bbox_x (fill_bx), .bbox_y (fill_by),
        .bbox_w (fill_bw), .bbox_h (fill_bh),
        .abort (fill_abort),
        .owner_fill_begin (owner_fill_begin), .owner_fill_ok (owner_fill_ok),
        .owner_fill_set (owner_fill_set),
        .owner_fill_complete (owner_fill_complete),
        .owner_fill_abort (owner_fill_abort),
        .row_valid (row_valid), .row_ready (row_ready),
        .row_addr (row_addr), .row_beats (row_beats),
        .row_head_skip (row_head_skip), .row_valid_bytes (row_valid_bytes),
        .row_local_y (row_local_y), .row_row_last (row_row_last),
        .row_set (row_set), .row_tag (row_tag), .row_job_id (row_job_id),
        .beat_valid (beat_valid), .beat_ready (beat_ready), .beat_data (beat_data),
        .fill_wr (cache_wr), .fill_wr2 (cache_wr2),
        .fill_x (cache_x), .fill_y (cache_y),
        .fill_rgb (cache_rgb), .fill_rgb2 (cache_rgb2),
        .fill_set (fill_set),
        .busy (fill_busy), .cnt_px (fill_cnt_px), .cnt_blocks (fill_cnt_blocks),
        .cnt_abort (fill_cnt_abort), .done (fill_done),
        .dbg_wait_beat (dbg_fill_wait_beat),
        .dbg_wait_row (dbg_fill_wait_row),
        .dbg_wait_plan (dbg_fill_wait_plan)
    );

    // ------------------------------------------------------------ source cache
    reg  [1:0]  samp_set;
    wire        samp_rd_set;   // from the sampler: cache set of the record being fired
    wire        p0_fire, p1_fire, p2_fire, p3_fire;
    wire [5:0]  p0_x, p0_y, p1_x, p1_y, p2_x, p2_y, p3_x, p3_y;
    wire        p0_valid, p1_valid, p2_valid, p3_valid;
    wire [23:0] p0_d, p1_d, p2_d, p3_d;

    // 2026-11-02: the cache has exactly two sets, selected by one bit; the owner's
    // 2-bit index is only ever 0 or 1, so take bit 0 explicitly instead of letting
    // the tool truncate it (that mismatch was a simulation width warning).
    dgc_source_cache4 u_cache (
        .clk (clk), .rst_n (rst_n),
        .wr_valid (cache_wr), .wr_ready (), .wr_set (fill_set[0]),
        .wr_x (cache_x), .wr_y (cache_y), .wr_rgb (cache_rgb),
        .wr2_valid (cache_wr2), .wr2_rgb (cache_rgb2),
        // 2026-11-02 (e): the read set is the one captured with the record that is
        // being fired, not the block's current set. The fire is two cycles behind
        // the take, so a block switch on the last take would otherwise make the
        // last records read the next block's set (the 19:10 failure). Every
        // targeted/end-to-end test still checks the pixel data, which is what
        // proves this alignment: do not connect samp_set[0] here again.
        .rd_set (samp_rd_set),
        .p0_fire (p0_fire), .p0_x (p0_x), .p0_y (p0_y),
        .p1_fire (p1_fire), .p1_x (p1_x), .p1_y (p1_y),
        .p2_fire (p2_fire), .p2_x (p2_x), .p2_y (p2_y),
        .p3_fire (p3_fire), .p3_x (p3_x), .p3_y (p3_y),
        .p0_valid (p0_valid), .p0_d (p0_d),
        .p1_valid (p1_valid), .p1_d (p1_d),
        .p2_valid (p2_valid), .p2_d (p2_d),
        .p3_valid (p3_valid), .p3_d (p3_d)
    );

    // ================================================================= sampler
    reg  [10:0] samp_bx, samp_by;
    wire        samp_cd_valid, samp_cd_ready;
    wire        samp_out_valid, samp_out_ready;
    wire [191:0] samp_out_data;
    wire        samp_busy;
    wire        samp_push;       // one completed record enters the sampler output FIFO
    wire [7:0]  samp_inflight;   // records still inside the cache read pipeline
    wire [31:0] samp_cnt_samples, samp_cnt_oob;

    dgc_source_sampler u_sampler (
        .clk (clk), .rst_n (rst_n & ~job_flush),
        .blk_bbox_x (samp_bx), .blk_bbox_y (samp_by), .blk_set (samp_set[0]),
        .rd_set_o (samp_rd_set),
        .rd_push (samp_push), .rd_inflight (samp_inflight),
        .cd_valid (samp_cd_valid), .cd_ready (samp_cd_ready), .cd_data (fifo_rd_data),
        .p0_fire (p0_fire), .p0_x (p0_x), .p0_y (p0_y),
        .p1_fire (p1_fire), .p1_x (p1_x), .p1_y (p1_y),
        .p2_fire (p2_fire), .p2_x (p2_x), .p2_y (p2_y),
        .p3_fire (p3_fire), .p3_x (p3_x), .p3_y (p3_y),
        .p0_valid (p0_valid), .p0_d (p0_d),
        .p1_valid (p1_valid), .p1_d (p1_d),
        .p2_valid (p2_valid), .p2_d (p2_d),
        .p3_valid (p3_valid), .p3_d (p3_d),
        .sample_valid (samp_out_valid), .sample_ready (samp_out_ready),
        .sample_data (samp_out_data),
        .cnt_samples (samp_cnt_samples), .cnt_out_of_block (samp_cnt_oob),
        .busy (samp_busy)
    );

    // ================================================================== FSM state
    // Declared before the handshake assigns below that reference it.
    localparam [2:0] C_IDLE   = 3'd0;
    localparam [2:0] C_FILL   = 3'd1;
    localparam [2:0] C_SAMPLE = 3'd2;
    localparam [2:0] C_DRAIN  = 3'd3;

    reg [2:0] cstate;

    // ================================================== black path + gamma
    wire        bil_in_valid;
    wire        bil_in_ready;
    wire [191:0] bil_in_data;

    // ACCEPT: sampler output -> gamma. BLACK: the coordinate itself becomes an
    // invalid sample (P = 0, sample_ok = 0). SPLIT: nothing at all.
    // The coordinate FIFO port is a 4-deep elastic buffer and can sustain one
    // record per cycle; the core therefore streams records instead of holding a
    // single `pending` record and waiting for the sampler to hand it back.
    assign bil_in_valid = black_mode ? fifo_rd_valid : samp_out_valid;
    assign bil_in_data  = black_mode ? {96'd0, fifo_rd_data} : samp_out_data;
    assign samp_out_ready = black_mode ? 1'b0 : bil_in_ready;

    // who acknowledges the coordinate record held by the FIFO port
    assign samp_cd_valid = (!black_mode && cur_accept &&
                            (cstate == C_SAMPLE)) ? fifo_rd_valid : 1'b0;
    assign fifo_rd_ready_o = (cstate == C_SAMPLE) ?
                             (black_mode ? bil_in_ready :
                              cur_accept ? samp_cd_ready : 1'b1) : 1'b0;

    wire        gam_out_valid, gam_out_ready;
    wire [191:0] gam_out_data;

    dgc_gamma_stage u_gamma (
        .clk (clk), .rst_n (rst_n & ~job_flush), .gamma_mode (gamma_mode),
        .in_valid (bil_in_valid), .in_ready (bil_in_ready),
        .in_sample (bil_in_data),
        .out_valid (gam_out_valid), .out_ready (gam_out_ready),
        .out_sample (gam_out_data), .unsupported_mode ()
    );

    wire        px_valid, px_ready;
    wire [63:0] px_data;

    dgc_bilinear u_bilinear (
        .clk (clk), .rst_n (rst_n & ~job_flush),
        .in_valid (gam_out_valid), .in_ready (gam_out_ready),
        .in_sample (gam_out_data),
        .out_valid (px_valid), .out_ready (px_ready),
        .out_pixel (px_data)
    );

    // ============================================================ stripe writer
    wire [3:0]  wr_bank_busy;
    wire [11:0] wr_bank_state;
    wire [6:0] wr_cur_sid0;

    dgc_stripe_writer u_stripe (
        .clk (clk), .rst_n (rst_n),
        .job_id (job_id), .config_epoch (16'd0), .job_restart (job_start),
        .job_abort (job_abort),
        .px_valid (px_valid), .px_ready (px_ready), .px_data (px_data),
        .bank_busy (wr_bank_busy),
        .bank0_busy (), .bank1_busy (),
        .bank_state (wr_bank_state),
        .cur_sid0_out (wr_cur_sid0),
        .rel (rel), .release_bank (release_bank), .release_status_bad (release_status_bad),
        .offer_valid (offer_valid), .offer_ready (offer_ready), .offer_data (offer_data),
        .ram_rd_clk (ram_rd_clk), .ram_rd_rst_n (ram_rd_rst_n),
        .ram0_rd_addr (ram0_rd_addr), .ram0_rd_data (ram0_rd_data),
        .ram1_rd_addr (ram1_rd_addr), .ram1_rd_data (ram1_rd_data),
        .ram2_rd_addr (ram2_rd_addr), .ram2_rd_data (ram2_rd_data),
        .ram3_rd_addr (ram3_rd_addr), .ram3_rd_data (ram3_rd_data),
        .cnt_stripes_done (), .cnt_pixels_written (cnt_pixels),
        .dbg_rd_timeout (dbg_rd_timeout), .cnt_rd_timeout ()
    );

    // ================================================================== FSM
    reg [15:0] cur_tag;
    // `issue_left` counts records not yet popped from the coordinate FIFO;
    // `sample_left` counts records not yet consumed by the sampler (ACCEPT) or
    // dropped (SPLIT/BLACK). Keeping them separate lets the FIFO port run one
    // record per cycle ahead of the consumer instead of one-record-at-a-time.
    reg [9:0]  issue_left;
    reg [9:0]  sample_left;
    reg [9:0]  recs_total;
    reg [10:0] cur_bx, cur_by;
    reg [10:0] cur_cx, cur_cy;
    reg [6:0]  cur_cw, cur_ch;
    reg [1:0]  cur_kind;
    reg [31:0] pix_seen;
    // 2026-11-02 (f): pixels accepted into the sampler/gamma/bilinear path but not
    // yet accepted by the stripe writer. There is exactly one output pixel per
    // ACCEPT/BLACK record, and the pixel stream is in order, so this counter is
    // the exact "how many pixels are still in the pipe" figure. C_DRAIN waits for
    // it to reach zero instead of comparing `pix_seen` with `recs_total`: the old
    // test was a level comparison that cannot survive an early block switch, while
    // this counter can be handed over to the next block (step 2, see retire_left).
    reg [9:0]  inflight_px;
    // Pixels of a retired block that are still inside gamma/bilinear after an
    // inline block switch. The stream is in order, so they are emitted before any
    // pixel of the new block; the new block's counter only starts afterwards.
    reg [9:0]  retire_left;
    reg [31:0] blocks_done;
    // Cache-set handover after an inline block switch: how many records of the
    // retired block are still inside the cache read pipeline. The old set stays
    // READING (and a fill therefore cannot pick it) until this reaches zero.
    reg        hs_pending;
    reg  [3:0] hs_left;
    reg  [4:0] hs_age;            // backstop: a miscounted handover must not hold the set
    reg        job_started;

    // ---- next-block context: filled while the current block is sampled -------
    // The source cache has two sets and the owner already allows FILLING in one
    // set while READING the other. Keeping one descriptor here lets the fill of
    // block N+1 run underneath the sample of block N; the block becomes current
    // when the sampler has drained.
    reg        next_valid;
    reg        next_filling;
    reg        next_fill_done;
    reg [1:0]  next_set;
    reg [15:0] next_tag;
    reg [10:0] next_bx, next_by;
    reg [6:0]  next_bw, next_bh;
    reg [9:0]  next_recs;
    reg [1:0]  next_kind;

    // Stream records: the port's 4-deep elastic buffer and the sampler's
    // 8-deep output FIFO absorb short stalls, so in steady state this fires
    // every cycle and the sampler produces one pixel per cycle.
    assign fifo_rd_fire = (cstate == C_SAMPLE) && (issue_left != 10'd0);
    wire   issue_fire   = fifo_rd_fire & fifo_rd_accept;

    // The coordinate stage can run one block ahead: in C_FILL/C_SAMPLE it may
    // push the next descriptor into the context register while the current
    // block is still being filled or sampled. C_DRAIN does not accept, so the
    // descriptor being switched to can never be overwritten.
    assign desc_ready = !job_cancelled && !job_flush &&
                        ((cstate == C_IDLE) ||
                         ((cstate == C_FILL || cstate == C_SAMPLE) && !next_valid));

    // ACCEPT: the sampler takes the coordinate (its output FIFO absorbs any
    // bilinear stall). BLACK: bilinear takes it. SPLIT: it is only discarded.
    wire take_accept = samp_cd_valid && samp_cd_ready;
    wire take_split  = (!cur_accept && !black_mode) && fifo_rd_valid;
    wire take_black  = (!cur_accept &&  black_mode) && fifo_rd_valid && bil_in_ready;
    wire take_drop   = take_split | take_black;
    // One pixel is produced for every ACCEPT (sampler) and BLACK record; a SPLIT
    // record produces none. `px_out` is one pixel accepted by the stripe writer.
    wire take_pixel  = take_accept | take_black;
    wire px_out      = px_valid & px_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cstate <= C_IDLE;
            cur_tag <= 16'd0; issue_left <= 10'd0; sample_left <= 10'd0;
            recs_total <= 10'd0;
            cur_bx <= 11'd0; cur_by <= 11'd0;
            cur_cx <= 11'd0; cur_cy <= 11'd0; cur_cw <= 7'd0; cur_ch <= 7'd0;
            fill_start <= 1'b0;
            fill_base <= 32'd0; fill_tag <= 16'd0;
            fill_bx <= 11'd0; fill_by <= 11'd0; fill_bw <= 7'd0; fill_bh <= 7'd0;
            samp_bx <= 11'd0; samp_by <= 11'd0; samp_set <= 2'd0;
            sample_begin <= 1'b0; sample_rel <= 1'b0; rel_done <= 1'b0;
            black_mode <= 1'b0; cur_accept <= 1'b0; cur_kind <= 2'd0;
            pix_seen <= 32'd0; blocks_done <= 32'd0; job_started <= 1'b0;
            inflight_px <= 10'd0; retire_left <= 10'd0;
            hs_pending <= 1'b0; hs_left <= 4'd0; hs_age <= 5'd0;
            next_valid <= 1'b0; next_filling <= 1'b0; next_fill_done <= 1'b0;
            next_set <= 2'd0; next_tag <= 16'd0;
            next_bx <= 11'd0; next_by <= 11'd0; next_bw <= 7'd0; next_bh <= 7'd0;
            next_recs <= 10'd0; next_kind <= 2'd0;
            job_cancelled <= 1'b0;
        end
        else if (job_start || job_abort || job_cancelled) begin
            // This branch must be exclusive with descriptor/sample/FSM updates:
            // old C_SAMPLE/C_DRAIN activity used to overwrite the restart values.
            // Leave the fill engine running on abort so every outstanding DDR
            // row is consumed before src_idle permits releasing the source slot.
            job_started <= job_start;
            job_cancelled <= !job_start;
            cstate <= C_IDLE;
            fill_start <= 1'b0;
            sample_begin <= 1'b0;
            sample_rel <= 1'b0;
            cur_accept <= 1'b0;
            black_mode <= 1'b0;
            blocks_done <= 32'd0;
            pix_seen <= 32'd0;
            recs_total <= 10'd0;
            inflight_px <= 10'd0;
            retire_left <= 10'd0;
            hs_pending <= 1'b0;
            hs_left <= 4'd0;
            hs_age <= 5'd0;
            issue_left <= 10'd0;
            sample_left <= 10'd0;
            next_valid <= 1'b0;
            next_filling <= 1'b0;
            next_fill_done <= 1'b0;
            rel_done <= 1'b0;
        end
        else begin
            fill_start   <= 1'b0;
            sample_begin <= 1'b0;
            sample_rel   <= 1'b0;

            // Pixels in flight through gamma/bilinear: one enters per record that
            // produces a pixel, one leaves per writer accept. The guard on the
            // decrement keeps a stale pixel (which the job flush already removed in
            // every observed case) from wrapping the counter and deadlocking C_DRAIN.
            if (take_pixel && !px_out)
                inflight_px <= inflight_px + 10'd1;
            else if (!take_pixel && px_out && (inflight_px != 10'd0))
                inflight_px <= inflight_px - 10'd1;

            // Per-block accounting. `retire_left` holds the pixels of a block that
            // an inline switch retired; they are emitted before any pixel of the
            // new block (the stream is in order), so until they drain nothing is
            // attributed to the block that is now current.
            if (px_out) begin
                if (retire_left != 10'd0) retire_left <= retire_left - 10'd1;
                else                      pix_seen    <= pix_seen + 32'd1;
            end

            // 2026-11-02: free the set as soon as this block is fully emitted and the
            // sampler is idle; waiting for the next block's fill is a circular wait.
            if (!rel_done && cur_accept && !samp_busy && (retire_left == 10'd0) &&
                (pix_seen >= {22'd0, recs_total})) begin
                sample_rel <= 1'b1;
                rel_done   <= 1'b1;
            end

            // --------------------------------------- cache-set handover (inline switch)
            // After an inline switch the retired block's set is still READING in the
            // owner, because a fill must not overwrite it while its last reads are in
            // the cache pipeline. `hs_left` counts exactly those reads: it starts at
            // the in-flight count at the switch and decrements on every sampler push.
            // The final push means the last read of the old block has returned, so the
            // same edge may free the old set (rel) and claim the new one (sample_begin);
            // dgc_cache_owner resolves that pair with the pre-edge read_sel, which is
            // the old set, and picks the READY set as the new read target.
            if (hs_pending) begin
                hs_age <= hs_age + 5'd1;
                if (samp_push) begin
                    hs_left <= hs_left - 4'd1;
                    if (hs_left == 4'd1) begin
                        hs_pending   <= 1'b0;
                        sample_begin <= 1'b1;
                        sample_rel   <= 1'b1;
                    end
                end
                // Backstop: the count above is exact (a record is pushed five cycles
                // after its take, one per cycle), but a miscount must degrade to a
                // late release, never to a deadlocked cache set. By 31 cycles every
                // read of the retired block has certainly returned.
                if (hs_age >= 5'd31) begin
                    hs_pending   <= 1'b0;
                    sample_begin <= 1'b1;
                    sample_rel   <= 1'b1;
                end
            end

            // ------------------------------------------------------- descriptor
            // C_IDLE loads the block to run now; C_FILL/C_SAMPLE load the one to
            // run next, so its fill can proceed under the current sample.
            if (desc_valid && desc_ready) begin
                if (cstate == C_IDLE) begin
                    issue_left  <= d_rec_count;
                    sample_left <= d_rec_count;
                    recs_total  <= d_rec_count;
                    cur_tag    <= d_tag;
                    cur_bx     <= d_bbox_x; cur_by <= d_bbox_y;
                    cur_cx     <= d_out_x;  cur_cy <= d_out_y;
                    cur_cw     <= d_out_w;  cur_ch <= d_out_h;
                    cur_kind   <= d_kind;
                    pix_seen   <= 32'd0;   // pixels of this block
                    if (d_kind == 2'd0) begin
                        fill_base  <= frame_base;
                        fill_tag   <= d_tag;
                        fill_bx    <= d_bbox_x; fill_by <= d_bbox_y;
                        fill_bw    <= d_bbox_w; fill_bh <= d_bbox_h;
                        fill_start <= 1'b1;
                        cur_accept <= 1'b1;
                        black_mode <= 1'b0;
                        cstate <= C_FILL;
                    end
                    else if (d_kind == 2'd2) begin
                        black_mode <= 1'b1;      // emit black pixels
                        cur_accept <= 1'b0;
                        cstate <= C_SAMPLE;
                    end
                    else begin
                        black_mode <= 1'b0;      // SPLIT: discard
                        cur_accept <= 1'b0;
                        cstate <= C_SAMPLE;
                    end
                end
                else begin
                    next_valid     <= 1'b1;
                    next_tag       <= d_tag;
                    next_bx        <= d_bbox_x; next_by <= d_bbox_y;
                    next_bw        <= d_bbox_w; next_bh <= d_bbox_h;
                    next_recs      <= d_rec_count;
                    next_kind      <= d_kind;
                    next_filling   <= 1'b0;
                    next_fill_done <= (d_kind != 2'd0);
                end
            end

            case (cstate)
                C_IDLE: ;   // descriptor handling above starts the block
                C_FILL: begin
                    if (fill_done) begin
                        samp_set   <= owner_fill_set;
                        samp_bx    <= cur_bx;
                        samp_by    <= cur_by;
                        sample_begin <= 1'b1;
                        cstate     <= C_SAMPLE;
                    end
                end
                C_SAMPLE: begin
                    // A descriptor with record_count=0 has nothing to sample.
                    // The old FSM waited forever for a take_accept/take_drop
                    // that can never happen; finish that block instead.
                    if (sample_left == 10'd0)
                        cstate <= (cur_kind == 2'd2) ? C_DRAIN : C_IDLE;

                    if (issue_fire) issue_left <= issue_left - 10'd1;

                    // Start the next block's fill as soon as this block's sample
                    // begins. The owner guarantees FILLING and READING use
                    // different sets; if no set is free yet, wait a cycle.
                    if (next_valid && !next_filling && !next_fill_done &&
                        (next_kind == 2'd0) && owner_fill_ok) begin
                        fill_tag   <= next_tag;
                        fill_bx    <= next_bx;  fill_by <= next_by;
                        fill_bw    <= next_bw;  fill_bh <= next_bh;
                        fill_start <= 1'b1;
                        next_filling <= 1'b1;
                    end

                    if (next_filling && fill_done) begin
                        next_filling   <= 1'b0;
                        next_fill_done <= 1'b1;
                        next_set       <= owner_fill_set;
                    end

                    if (take_accept) begin
                        if (sample_left == 10'd1) begin
                            // ------------------------------------------ last record
                            // 2026-11-02 (g): inline switch. The next block's cache
                            // set is READY and its descriptor is already in the
                            // context registers, so the sampler can start the next
                            // block on the very next cycle. Nothing in this handover
                            // is speculative: the old block's pixels keep flowing
                            // through gamma/bilinear (the stream is in order) and are
                            // accounted to `retire_left`, its cache set is released by
                            // the handover pulse above once its reads have drained, and
                            // the new block's set/bbox take effect for the records
                            // taken from the next cycle on. This removes the C_DRAIN
                            // bubble (16 cycles per block, 0.38 ms per frame).
                            if (next_valid && next_fill_done && (next_kind == 2'd0)) begin
                                // pixels of the retired block still in the pixel pipe
                                retire_left <= inflight_px
                                             + (take_pixel ? 10'd1 : 10'd0)
                                             - (px_out     ? 10'd1 : 10'd0);
                                pix_seen    <= 32'd0;
                                blocks_done <= blocks_done + 32'd1;
                                // old cache set: wait for its reads, then hand over
                                hs_pending  <= 1'b1;
                                hs_left     <= samp_inflight[3:0] + 4'd1
                                             - (samp_push ? 4'd1 : 4'd0);
                                hs_age      <= 5'd0;
                                // next block becomes current; cstate stays C_SAMPLE
                                cur_tag     <= next_tag;
                                cur_bx      <= next_bx;   cur_by <= next_by;
                                cur_kind    <= next_kind;
                                issue_left  <= next_recs;
                                sample_left <= next_recs;
                                recs_total  <= next_recs;
                                black_mode  <= 1'b0;
                                cur_accept  <= 1'b1;
                                samp_set    <= next_set;
                                samp_bx     <= next_bx;
                                samp_by     <= next_by;
                                next_valid     <= 1'b0;
                                next_filling   <= 1'b0;
                                next_fill_done <= 1'b0;
                                rel_done       <= 1'b0;
                            end
                            else begin
                                sample_left <= 10'd0;
                                cstate <= C_DRAIN;
                            end
                        end
                        else sample_left <= sample_left - 10'd1;
                    end
                    else if (take_drop) begin
                        // SPLIT and BLACK both consume the record here; BLACK also
                        // hands it to bilinear as an invalid sample first
                        sample_left <= sample_left - 10'd1;
                        if (sample_left == 10'd1) begin
                            sample_left <= 10'd0;
                            cstate <= (cur_kind == 2'd2) ? C_DRAIN : C_IDLE;
                        end
                    end
                end
                C_DRAIN: begin
                    // A descriptor accepted in the same cycle as the last sample
                    // never saw the C_SAMPLE fill-start branch; start it here.
                    if (next_valid && !next_filling && !next_fill_done &&
                        (next_kind == 2'd0) && owner_fill_ok) begin
                        fill_tag   <= next_tag;
                        fill_bx    <= next_bx;  fill_by <= next_by;
                        fill_bw    <= next_bw;  fill_bh <= next_bh;
                        fill_start <= 1'b1;
                        next_filling <= 1'b1;
                    end
                    if (next_filling && fill_done) begin
                        next_filling   <= 1'b0;
                        next_fill_done <= 1'b1;
                        next_set       <= owner_fill_set;
                    end

                    // Every pixel of the block has reached the stripe writer, i.e.
                    // nothing is left in gamma/bilinear, and the sampler has no read
                    // in flight. The next block may only be switched in after its
                    // fill has completed.
                    // `inflight_px` replaces the old `pix_seen >= recs_total` level
                    // test: it is an up/down count of the pixels actually inside the
                    // pixel pipe, so it stays exact when a block is switched early
                    // (step 2 hands the remainder over as `retire_left`).
                    if ((inflight_px == 10'd0) && (retire_left == 10'd0) && !samp_busy &&
                        (!next_valid || (next_kind != 2'd0) || next_fill_done)) begin
                        rel_done    <= 1'b0;
                        blocks_done <= blocks_done + 32'd1;
                        if (next_valid) begin
                            cur_tag    <= next_tag;
                            cur_bx     <= next_bx; cur_by <= next_by;
                            cur_kind   <= next_kind;
                            issue_left <= next_recs;
                            sample_left <= next_recs;
                            recs_total  <= next_recs;
                            pix_seen   <= 32'd0;
                            black_mode <= (next_kind == 2'd2);
                            cur_accept <= (next_kind == 2'd0);
                            if (next_kind == 2'd0) begin
                                samp_set     <= next_set;
                                samp_bx      <= next_bx;
                                samp_by      <= next_by;
                                sample_begin <= 1'b1;
                            end
                            next_valid     <= 1'b0;
                            next_filling   <= 1'b0;
                            next_fill_done <= 1'b0;
                            cstate <= C_SAMPLE;
                        end
                        else cstate <= C_IDLE;
                    end
                end
                default: cstate <= C_IDLE;
            endcase
        end
    end

    assign busy = (cstate != C_IDLE);
    assign frame_done = sched_frame_done && (cstate == C_IDLE) && !desc_valid && job_started;

    // ------------------------------------------------- "source frame is done"
    // The last block's last record has been taken (`sample_left == 0` and the FSM
    // has left C_SAMPLE for C_DRAIN), every block was dispatched
    // (`sched_frame_done`), no descriptor is waiting (`!desc_valid`), nothing is
    // prefetched (`!next_valid`), the fill engine is idle and no row request is on
    // the channel (`!fill_busy && !row_valid`).
    //
    // Why each term is needed:
    //   * sched_frame_done / !desc_valid / !next_valid: no block can still start,
    //     and only a block can request a fill;
    //   * sample_left == 0: the sampler will not issue another cache read, so it
    //     cannot miss and trigger a fill either;
    //   * !fill_busy / !row_valid: no row request is in the fill engine or on its
    //     way to the DDR domain, so `frame_base` is not referenced any more. Writes
    //     into the source cache that are already in flight are harmless: nobody
    //     reads that data once the last record has been taken.
    // On cancellation the coordinate scheduler stops and no new fill may start;
    // the existing fill still consumes every requested beat. Its idle state then
    // makes src_idle true without requiring the cancelled scheduler to finish.
    // A job that never dispatches a block (black/split-only frame) leaves
    // sched_frame_done low, so nothing is released early by accident.
    assign src_idle = !fill_start && !fill_busy && !row_valid &&
                      (job_cancelled ||
                       (job_started && sched_frame_done && !desc_valid && !next_valid &&
                        (sample_left == 10'd0)));
    assign cnt_blocks_done = blocks_done;

    assign dbg_cstate    = cstate;
    assign dbg_fill_busy = fill_busy;
    assign dbg_samp_busy = samp_busy;
    assign dbg_next_valid = next_valid;
    assign dbg_sample_left = sample_left;
    assign dbg_recs_total = recs_total;
    assign dbg_pix_seen = pix_seen[15:0];
    assign dbg_wr_busy  = {wr_bank_busy[1], wr_bank_busy[0], px_ready};
    assign dbg_aux_busy = wr_bank_busy[3] | wr_bank_busy[2];
    assign dbg_wr_state = wr_bank_state;
    assign dbg_pix_sid  = px_data[45:39];   // dst_y[10:4]: current pixel's stripe id
    assign dbg_cur_sid0 = wr_cur_sid0;
    assign dbg_reading  = {wr_bank_state[9], wr_bank_state[6],
                           wr_bank_state[3], wr_bank_state[0]};
    assign dbg_pix_over = (pix_seen > {22'd0, recs_total}) ?
                          (pix_seen[7:0] - recs_total[7:0]) : 8'd0;
    // {next_valid, sample_begin, samp_busy, next_filling,
    //  next_fill_done, fill_done, fill_busy, owner_fill_ok}
    // owner_fill_ok is the gate on starting the prefetch of the next block; if
    // it stays 0 the DRAIN exit waits forever for next_fill_done.
    assign dbg_fill_flags = {next_valid, sample_begin, samp_busy, next_filling,
                             next_fill_done, fill_done, fill_busy, owner_fill_ok};

    // ------------------------------------------------------- performance taps
    // The sample stage holds one output pixel per cycle when healthy. Two things
    // can stop that: the stripe writer takes no pixel (owner/reader backpressure)
    // or the sampler has not produced one yet (source cache read latency).
    // `cur_accept` restricts the second tap to ACCEPT blocks, whose pixels come
    // through the sampler rather than the black path.
    assign dbg_fill_wr        = cache_wr;
    assign dbg_samp_stall_wr  = (cstate == C_SAMPLE) && px_valid && !px_ready;
    assign dbg_samp_stall_smp = (cstate == C_SAMPLE) && cur_accept &&
                                !samp_out_valid;

endmodule










