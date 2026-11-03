//-----------------------------------------------------------------------------
// dgc_core_sys.v
//
// System-level integration across the four data domains. This is what the board
// top instantiates between the DDR3 native port and the HDMI pins.
//
//   vin_clk  : capture_pack -> 288-bit beats -> pix_beat_fifo (async) -> ddr_clk
//   ddr_clk  : frame_manager, write adapter (AW/W), read adapter (AR/R + FIFO),
//              frame grant/release and fetch_row mailboxes
//   proc_clk : dgc_core (scheduler, coordinate stage, fill, cache, sampler,
//              gamma, bilinear, stripe writer) + job FSM
//   vout_clk : video reader -> RGB/DE/HS/VS (the top feeds the S0 TMDS chain)
//
// Control crossing: eight dgc_mailbox channels, all carrying single descriptors:
//   vin  -> ddr  frame allocation request        ddr  -> vin  frame grant (128)
//   proc -> ddr  fetch_row descriptor (128)      proc -> ddr  frame acquire
//   ddr  -> proc acquired frame descriptor (128) proc -> ddr  frame release (64)
//   proc -> vout stripe offer (64)               vout -> proc stripe release (64)
//
// Frame completion uses the write adapter's evidence: `frame_end` is asserted
// only when the last beat of the frame has really been accepted on the W channel,
// not when the capture logic merely handed it over.
//-----------------------------------------------------------------------------

module dgc_core_sys #(
    parameter integer FRAME_BYTES = 6220800,
    // When 1, a new job may only start on `frame_tick` (the output frame's vs_fall
    // synchronised into proc_clk). This keeps the writer's job_restart at the
    // display frame boundary; without it a job that finishes early starts the
    // next frame mid-display and its stripe 0 is discarded by the reader.
    parameter integer ALIGN_TO_FRAME = 0,
    // Job watchdog deadline in proc cycles. The default is ~24.5 ms at 171 MHz
    // (1.5 output frames). It is a parameter so the end-to-end abort regression can
    // use a short deadline instead of simulating 4.2M cycles; the board keeps the
    // default and nothing else changes.
    parameter integer JOB_WD_LIMIT = 4200000
) (
    // ---------------- clocks and resets -------------------------------------
    input  wire        vin_clk,
    input  wire        vin_rst_n,
    input  wire        ddr_clk,
    input  wire        ddr_rst_n,
    input  wire        proc_clk,
    input  wire        proc_rst_n,
    input  wire        vout_clk,
    input  wire        vout_rst_n,

    // ---------------- HDMI input (vin_clk) ----------------------------------
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire        de_in,
    input  wire [23:0] rgb_in,

    // ---------------- DDR3 native write channel -----------------------------
    output wire [27:0] axi_awaddr,
    output wire [3:0]  axi_awlen,
    output wire        axi_awvalid,
    input  wire        axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0] axi_wstrb,
    input  wire        axi_wready,
    input  wire [3:0]  axi_wusero_id,
    input  wire        axi_wusero_last,

    // ---------------- DDR3 native read channel ------------------------------
    output wire [27:0] axi_araddr,
    output wire [3:0]  axi_arlen,
    output wire        axi_arvalid,
    input  wire        axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire        axi_rvalid,
    input  wire        axi_rlast,
    input  wire [3:0]  axi_rid,

    // ---------------- active configuration ----------------------------------
    input  wire [1:0]  cfg_mode,
    input  wire signed [31:0] cfg_m00, cfg_m01, cfg_m02,
    input  wire signed [31:0] cfg_m10, cfg_m11, cfg_m12,
    input  wire signed [31:0] cfg_fx, cfg_fy, cfg_cx, cfg_cy,
    input  wire signed [31:0] cfg_k1, cfg_k2,
    input  wire [31:0] cfg_norm_abs_max,
    input  wire [1:0]  gamma_mode,

    // ---------------- frame boundary (proc_clk, one-cycle pulse) ------------
    input  wire        frame_tick,

    // ---------------- output timing (vout_clk) ------------------------------
    input  wire        de_tg, hs_tg, vs_tg,
    input  wire [11:0] x_tg, y_tg,

    // ---------------- video out (vout_clk) ----------------------------------
    output wire [23:0] rgb_out,
    output wire        de_out, hs_out, vs_out,

    // ---------------- status -------------------------------------------------
    output wire [31:0] stat_frames_written,
    output wire [31:0] stat_frames_processed,
    output wire [31:0] stat_stripes_underflow,
    output wire [31:0] stat_frames_dropped,
    output wire [31:0] stat_ddr_errors,
    output wire        frame_black,

    // Debug-only observation for the board UART. Every port here is a pure tap:
    // it does not feed back into any control or data path.
    output wire        dbg_core_busy,
    output wire [1:0]  dbg_job_state,
    // Job elapsed time in microseconds: the board showed a ~33 ms job period
    // (one job every two frame ticks, hence the 30 Hz flicker). 171 cycles = 1 us.
    output wire [15:0] dbg_job_us,
    output wire [15:0] dbg_cap_frames,
    output wire [15:0] dbg_cap_aborted,
    output wire [10:0] dbg_cap_rows,
    output wire [15:0] dbg_write_done,
    output wire [15:0] dbg_wa_frames,     // write-adapter good frame_end pulses
    output wire [15:0] dbg_wa_aborts,
    output wire [15:0] dbg_drop,
    output wire [7:0]  dbg_slot_state,   // 4 slots x 2 bits (2026-11-03)
    output wire [15:0] dbg_fm_alloc,
    output wire [15:0] dbg_fm_drop,
    output wire [15:0] dbg_fm_acquire,
    output wire [15:0] dbg_fm_release,
    output wire [15:0] dbg_core_blocks,
    output wire [2:0]  dbg_cstate,
    output wire        dbg_fill_busy,
    output wire        dbg_samp_busy,
    output wire        dbg_next_valid,
    // 2026-11-03: two scheduling counters, published in the G line's first two words
    // (they replace the per-block recs_total/sample_left snapshot, which the block
    // counters and K1 already cover).
    //   dbg_no_pend_us : microseconds of this report interval spent IDLE (job_state=0)
    //                    with no descriptor in hand - "the FSM is waiting for a frame".
    //   dbg_tick_skip  : frame boundaries dropped because there was no descriptor AND
    //                    the repeat cap forbade forcing one. Should equal the black
    //                    frames per second (underflow increment) if the diagnosis is
    //                    right: every black frame is a boundary with nothing to start.
    output wire [15:0] dbg_no_pend_us,     // ms in the interval spent IDLE without a descriptor
    output wire [15:0] dbg_tick_skip,      // boundaries lost (no descriptor, no force allowed)
    output wire [7:0]  dbg_acq_req,        // acquire requests issued in the interval
    output wire [7:0]  dbg_acq_got,        // descriptors received back in the interval
    output wire [15:0] dbg_pix_seen,
    output wire [2:0]  dbg_wr_busy,
    output wire [11:0] dbg_wr_state,
    output wire [6:0]  dbg_pix_sid,        // DGC5: full 7-bit stripe id
    output wire [6:0]  dbg_cur_sid0,       // DGC5: full 7-bit bank0 stripe id
    output wire [3:0]  dbg_reading,        // DGC5: {reading3..reading0}
    output wire        dbg_aux_busy,       // bank2_busy | bank3_busy
    output wire        dbg_rd_timeout,     // DGC5: stripe-writer watchdog fired (sticky)
    output wire [7:0]  dbg_pix_over,
    output wire [7:0]  dbg_fill_flags,
    output wire [6:0]  dbg_gap_max,     // longest frame_done -> next job_start gap (0.25 ms units)
    output wire [6:0]  dbg_uf_stripe,   // vout domain: stripe index at which a frame starved
    output wire        dbg_uf_first,    // vout domain: that starvation was stripe 0 missing the porch
    output wire [15:0] dbg_reader_flags,
    output wire [15:0] dbg_offers,
    output wire        dbg_cur_bank,       // vout domain: bank being scanned
    output wire        dbg_next_bank,      // vout domain: prefetched bank
    output wire        dbg_rel_drop,       // vout domain: release-queue overflow (sticky)
    output wire        dbg_vs_discard,     // vout domain: frame boundary discarded a bank (sticky)
    // DGC4 frame-age diagnostic: frame_id of the source frame the current (or
    // last) job is processing. Compared with dbg_fm_alloc by the host this is
    // the frame age in frames: a live pipeline stays at 0..2, while hundreds
    // mean the job keeps reprocessing a stale DDR slot - the 2026-10-30 16:56
    // board symptom (full frame, correct geometry, but the picture is frozen).
    output wire [15:0] dbg_job_fid,

    // ---------------- DGC3 performance report (read-only) -------------------
    // Each field is the total of its condition during the interval since the
    // previous snapshot, already right-shifted (see dgc_perf_ctr). The latch
    // pulses come from the same dgc_snapshot_src edges that freeze the hold
    // registers, so a report is coherent with the rest of its words.
    //   proc_perf: [3:0] fill active / wait beats / wait row / wait planner
    //              [7:4] fill writes / sample active / writer stall / sampler stall
    //   ddr_perf : AR count (>>7), AR-wait cycles, return-starve cycles, max
    //              simultaneously outstanding requests
    input  wire        dbg_proc_latch,
    input  wire        dbg_ddr_latch,
    input  wire        dbg_vout_latch,     // freezes the vout interval counters
    output wire [127:0] dbg_perf_proc,
    output wire [63:0]  dbg_perf_ddr,
    // vout interval counters (DGC5): offers / discards / frames / releases since
    // the previous snapshot, exact counts (SHIFT=0), saturating at 0xFFFF.
    output wire [63:0]  dbg_perf_vout
);

    // ============================================================ declarations
    // vin domain
    reg          vs_d;
    wire         vs_rise;
    reg          alloc_src_valid;
    wire         alloc_src_ready;
    wire         mb_alloc_dst_valid;

    wire [127:0] grant_dst_data;
    wire         grant_dst_valid;
    reg  [127:0] vin_desc;
    reg          vin_frame_begin;
    reg  [10:0]  vin_x;

    wire         cap_beat_valid, cap_beat_ready;
    wire [31:0]  cap_beat_addr;
    wire [255:0] cap_beat_data;
    wire [31:0]  cap_frames, cap_aborted;
    wire [10:0]  cap_rows;

    wire         cdc_wr_full;
    wire [8:0]   cdc_wr_level;
    wire         cdc_rd_valid, cdc_rd_ready;
    wire [287:0] cdc_rd_data;
    wire [31:0]  cdc_push, cdc_pop;

    // ddr domain
    wire         alloc_grant, alloc_drop;
    wire [127:0] frame_grant;
    reg          grant_src_valid;
    reg  [127:0] grant_src_data;
    wire         grant_src_ready;

    wire         write_done_p;
    wire [1:0]   write_done_slot;
    wire         write_good;
    wire         acquire_p;
    wire         acquire_valid;
    wire [127:0] frame_acquired;
    wire         frame_rel_p;
    wire [1:0]   frame_rel_slot;

    // Debug-only taps from the frame manager (never used for control).
    wire [7:0]   fm_slot_state;
    wire [31:0]  fm_alloc, fm_get, fm_acquire_cnt, fm_release_cnt;

    wire [27:0]  wa_awaddr;
    wire [3:0]   wa_awlen;
    wire         wa_awvalid, wa_awready;
    wire [255:0] wa_wdata;
    wire [31:0]  wa_wstrb;
    wire         wa_wready;
    wire         wa_frame_end, wa_frame_abort;
    wire [1:0]   wa_end_slot, wa_abort_slot;
    wire [31:0]  wa_beats, wa_bursts, wa_frames, wa_aborts;
    wire         wa_idle;

    wire         mb_row_dst_valid, mb_row_dst_ready;
    wire [127:0] mb_row_dst_data;

    wire [27:0]  ra_araddr;
    wire [3:0]   ra_arlen;
    wire         ra_arvalid, ra_arready;
    wire         ra_fifo_wr;
    wire [255:0] ra_fifo_data;
    wire         ra_busy, ra_halt, ra_credit_bad;
    wire [31:0]  ra_err, ra_beats, ra_rows;
    wire         dbg_ar_wait, dbg_ret_starve;
    wire [3:0]   dbg_ret_cnt;
    wire [10:0]  ra_wr_level;
    reg  [11:0]  rd_gray_proc;
    wire [11:0]  rd_gray_sync;
    reg  [11:0]  rd_gray_s1, rd_gray_s2;
    wire         rd_fifo_full;

    // proc domain
    wire         rdf_rd_empty;
    wire [255:0] rdf_rd_data;
    wire         rdf_pop;
    wire         rdf_wr_full;
    wire         beat_valid_p, beat_ready_p;
    wire [255:0] beat_data_p;
    reg  [11:0]  pop_count;

    wire         row_valid, row_ready;
    wire [31:0]  row_addr;
    wire [4:0]   row_beats;
    wire [4:0]   row_head_skip;
    wire [7:0]   row_valid_bytes;
    wire [5:0]   row_local_y;
    wire         row_row_last, row_set;
    wire [15:0]  row_tag;
    wire [31:0]  row_job_id;
    wire [127:0] row_pack;

    // One-entry row mailbox source buffer. cur_by -> row_pack -> mailbox
    // payload_q was a -1.31 ns combinational path at 225 MHz; register the row
    // record before the CDC mailbox and keep the fill handshake elastic.
    reg          row_valid_q;
    reg  [127:0] row_pack_q;
    wire         mb_row_src_ready;
    wire         row_load = row_valid & (~row_valid_q | mb_row_src_ready);

    assign row_ready = ~row_valid_q | mb_row_src_ready;

    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) begin
            row_valid_q <= 1'b0;
            row_pack_q  <= 128'd0;
        end
        else if (row_load) begin
            row_valid_q <= 1'b1;
            row_pack_q  <= row_pack;
        end
        else if (row_valid_q && mb_row_src_ready) begin
            row_valid_q <= 1'b0;
        end
    end

    wire         offer_valid_c, offer_ready_c;
    wire [63:0]  offer_data_c;
    reg          rel_c, rel_bad_c;
    reg  [1:0]   rel_bank_c;

    wire [31:0]  core_pixels, core_blocks;
    wire         core_frame_done, core_busy;
    wire         core_src_idle;     // 2026-11-02: the core will not read frame_base again
    wire [15:0]  core_accept, core_black, core_split;

    reg  [31:0]  job_base, job_id_r;
    reg  [1:0]   job_slot;
    reg          job_start_p;
    // 2026-11-02: one release per job, issued as soon as the core can no longer read
    // the source frame (see the state-1 branch of the job FSM).
    reg          src_rel_sent;

    // Declared here (moved up 2026-11-03) because the job-duration timer below has
    // to know whether the job is running; it used to be declared with the rest of
    // the job FSM further down, which Questa rejects as "undefined variable".
    reg  [1:0]   job_state;

    reg [15:0] job_us; reg [7:0] us_div;
    reg [15:0] job_us_max;
    reg        fdone_d;
    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) begin
            job_us <= 16'd0; us_div <= 8'd0; job_us_max <= 16'd0; fdone_d <= 1'b0;
        end
        else begin
            fdone_d <= core_frame_done;
            if (job_start_p) begin job_us <= 16'd0; us_div <= 8'd0; end
            else if (job_state == 2'd1) begin
                // 2026-11-03: count ONLY while the job is running. `job_us` used to
                // free-run until the next job_start, and `frame_done` is a *level*
                // (sched_frame_done && C_IDLE && !desc_valid), so a descriptor that
                // arrives just after the last block makes it dip and rise again. That
                // spurious rising edge recorded the inter-job idle time as a "job
                // duration" - which is why K1 read a *constant* 56319 us on the board
                // while the job rate was 45/s (22222 us per job). 56319 was never a
                // job duration, it was ~2.5 idle frame periods.
                if (us_div == 8'd170) begin us_div <= 8'd0; job_us <= job_us + 16'd1; end
                else us_div <= us_div + 8'd1;
            end
            // 2026-11-01: K1 used to publish the free-running "microseconds since
            // the last job start".  At exactly 1 Hz with a 16.67/33.3 ms job that
            // value is phase-locked and therefore constant, which told us nothing
            // while the picture flickered.  K1 is now the LONGEST completed job in
            // the one-second window: if it is a little under 16667 us the job fits
            // one display frame, if it is around 33000 us the job is being stretched
            // by the bank handshake instead.  0 means no job finished in the window.
            if (core_frame_done && !fdone_d && (job_us > job_us_max))
                job_us_max <= job_us;
            if (dbg_proc_latch) job_us_max <= 16'd0;
        end
    end
    assign dbg_job_us = job_us_max;


    // 2026-11-01 (flicker diagnosis, part 2): job_us_max showed the job itself
    // fits one display frame (16055 us < 16667 us) while the job rate stayed at
    // 30/s, so the missing frame must be spent WAITING rather than working.  This
    // measures the idle gap from the end of one job (core_frame_done rising) to
    // the start of the next (job_start_p), in 0.25 ms units, and keeps the maximum
    // over the one-second window.  ~1 unit  = the job just waited for the next
    // display boundary (a 60 Hz cadence is possible); ~68 units = a whole frame
    // was lost (acquire refused / writer stalled by banks still displayed).
    reg [5:0]  gap_div;
    reg [6:0]  gap_cnt;
    reg [6:0]  gap_max;
    reg        fd_d3;
    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) begin
            gap_div <= 6'd0; gap_cnt <= 7'd0; gap_max <= 7'd0; fd_d3 <= 1'b0;
        end
        else begin
            fd_d3 <= core_frame_done;
            if (core_frame_done && !fd_d3) begin
                gap_div <= 6'd0;
                gap_cnt <= 7'd0;
            end
            else if (job_start_p) begin
                if (gap_cnt > gap_max) gap_max <= gap_cnt;
            end
            else if (gap_div == 6'd42) begin
                gap_div <= 6'd0;
                if (gap_cnt != 7'h7F) gap_cnt <= gap_cnt + 7'd1;
            end
            else gap_div <= gap_div + 6'd1;
            if (dbg_proc_latch) gap_max <= 7'd0;
        end
    end
    assign dbg_gap_max = gap_max;
    reg          acq_src_valid;
    // 2026-11-02 (b): the request is no longer aligned to the boundary (see the job
    // FSM below); this flag only records "a request went out in this frame" for the
    // failure dump. If the manager refuses it (the only READY frame is the one just
    // processed, see dgc_frame_manager stale-frame refusal), the FSM retries every
    // acq_wait window instead of waiting a whole frame.
    reg          acq_tried;
    wire         acq_src_ready;
    reg          rel_src_valid;
    wire         rel_src_ready;
    reg  [63:0]  rel_src_data;
    reg  [31:0]  stat_jobs;
    // One acquire per job. The FSM used to poll frame_acquire every cycle while
    // it waited for frame_tick; the manager handed out one READY slot per poll,
    // so several slots became HELD with only one job ever started (board run:
    // acquire=5, release=2, all three slots HELD, 8825 following frames
    // dropped). After a request the descriptor arrives within a few cycles; the
    // counter only re-arms if no frame was available at all.
    reg  [10:0]  acq_wait;

    wire         mb_acq_dst_valid;
    wire [1:0]   mb_acq_dst_data;      // {force, 1'b1}
    // Set by the job FSM for one request on a frame boundary when it holds no
    // descriptor: the frame manager then accepts a repeat of the last frame
    // instead of waiting for the next capture (see the FSM note below).
    reg          acq_force_req;
    wire         mb_job_dst_valid;
    wire         mb_job_dst_ready;
    wire [127:0] mb_job_dst_data;
    wire         job_src_ready;
    reg          job_hold_valid;
    reg  [127:0] job_hold_data;
    wire         frame_rel_dst_valid;
    wire [63:0]  frame_rel_dst_data;

    wire         mb_offer_dst_valid, mb_offer_dst_ready;
    wire [63:0]  mb_offer_dst_data;
    wire         mb_rel_dst_valid, mb_rel_dst_ready;
    wire [63:0]  mb_rel_dst_data;

    // vout domain
    wire         srel_valid, srel_ready;
    wire [63:0]  srel_data;
    wire [14:0]  ram0_rd_addr, ram1_rd_addr, ram2_rd_addr, ram3_rd_addr;
    wire [23:0]  ram0_rd_data, ram1_rd_data, ram2_rd_data, ram3_rd_data;
    wire [31:0]  reader_offers, reader_frames, reader_discards, reader_releases;
    wire [15:0]  reader_rel_drop;
    wire [6:0]   reader_cur_stripe;
    wire         reader_frame_ok, reader_cur_ok, reader_waiting_first, reader_have_next;
    wire [1:0]   reader_cur_bank, reader_next_bank;
    wire         reader_vs_discard;
    wire [6:0]   reader_uf_stripe;
    wire         reader_uf_first;
    // vout-domain starve index, forwarded to top_sys (V bundle w3) without a
    // CDC hop of its own: it rides the same vout snapshot as the other reader
    // counters.
    assign dbg_uf_stripe = reader_uf_stripe;
    assign dbg_uf_first  = reader_uf_first;
    wire [3:0]   reader_events;

    // ================================================== vin: frame allocation
    assign vs_rise = vs_in & ~vs_d;
    always @(posedge vin_clk or negedge vin_rst_n)
        if (!vin_rst_n) vs_d <= 1'b0;
        else            vs_d <= vs_in;

    always @(posedge vin_clk or negedge vin_rst_n) begin
        if (!vin_rst_n) alloc_src_valid <= 1'b0;
        else if (vs_rise) alloc_src_valid <= 1'b1;
        else if (alloc_src_valid && alloc_src_ready) alloc_src_valid <= 1'b0;
    end

    dgc_mailbox #(.W(1)) u_mb_alloc (
        .src_clk (vin_clk), .rst_src_n (vin_rst_n),
        .src_valid (alloc_src_valid), .src_ready (alloc_src_ready), .src_data (1'b1),
        .dst_clk (ddr_clk), .rst_dst_n (ddr_rst_n),
        .dst_valid (mb_alloc_dst_valid), .dst_ready (1'b1), .dst_data ()
    );

    // ================================================== vin: capture pipeline
    dgc_mailbox #(.W(128)) u_mb_grant (
        .src_clk (ddr_clk), .rst_src_n (ddr_rst_n),
        .src_valid (grant_src_valid), .src_ready (grant_src_ready),
        .src_data (grant_src_data),
        .dst_clk (vin_clk), .rst_dst_n (vin_rst_n),
        .dst_valid (grant_dst_valid), .dst_ready (1'b1), .dst_data (grant_dst_data)
    );

    always @(posedge vin_clk or negedge vin_rst_n) begin
        if (!vin_rst_n) begin
            vin_desc <= 128'd0;
            vin_frame_begin <= 1'b0;
            vin_x <= 11'd0;
        end
        else begin
            vin_frame_begin <= 1'b0;
            if (grant_dst_valid) begin
                vin_desc <= grant_dst_data;
                vin_frame_begin <= 1'b1;
            end
            // The pixel index must restart every active line, not once per frame.
            // Resetting it only on VS made every pixel after the first line carry
            // px_eol, which pushed row_base forward on every beat and silently
            // skipped rows (the write adapter then saw address jumps and aborted).
            if (!de_in) vin_x <= 11'd0;
            else if (vin_x != 11'd1919) vin_x <= vin_x + 11'd1;
        end
    end

    dgc_capture_writer u_capture (
        .clk (vin_clk), .rst_n (vin_rst_n),
        .frame_begin (vin_frame_begin), .frame_desc (vin_desc),
        .frame_abort (1'b0),
        .px_valid (de_in), .px_ready (), .px_data (rgb_in),
        .px_de (de_in), .px_eol (de_in & (vin_x == 11'd1919)),
        .beat_valid (cap_beat_valid), .beat_ready (cap_beat_ready),
        .beat_addr (cap_beat_addr), .beat_data (cap_beat_data),
        .frame_done (), .done_slot (), .done_frame_id (),
        .cnt_frames (cap_frames), .cnt_aborted (cap_aborted),
        .row_cnt (cap_rows)
    );

    assign cap_beat_ready = ~cdc_wr_full;

    dgc_capture_cdc u_cdc (
        .wr_clk (vin_clk), .wr_rst_n (vin_rst_n),
        .rd_clk (ddr_clk), .rd_rst_n (ddr_rst_n),
        .wr_data ({cap_beat_addr, cap_beat_data}),
        .wr_en (cap_beat_valid & cap_beat_ready),
        .wr_full (cdc_wr_full), .wr_level (cdc_wr_level),
        .rd_valid (cdc_rd_valid), .rd_ready (cdc_rd_ready), .rd_data (cdc_rd_data),
        .cnt_push (cdc_push), .cnt_pop (cdc_pop)
    );

    // ================================================== ddr: frame manager
    dgc_frame_manager u_fm (
        .clk (ddr_clk), .rst_n (ddr_rst_n),
        .alloc_req (mb_alloc_dst_valid), .alloc_grant (alloc_grant),
        .frame_grant (frame_grant), .alloc_drop (alloc_drop),
        .write_done (write_done_p), .done_slot (write_done_slot),
        .done_good (write_good),
        .acquire (acquire_p), .acquire_force (acquire_force_p),
        .acquire_valid (acquire_valid),
        .frame_acquired (frame_acquired),
        .rel (frame_rel_p), .release_slot (frame_rel_slot),
        .cfg_width (12'd1920), .cfg_height (12'd1080), .cfg_stride (16'd5760),
        .slot_state (fm_slot_state), .cnt_alloc (fm_alloc), .cnt_drop (stat_frames_dropped),
        .cnt_done (stat_frames_written), .cnt_acquire (fm_acquire_cnt),
        .ready_fid (),
        .cnt_release (fm_release_cnt)
    );

    always @(posedge ddr_clk or negedge ddr_rst_n) begin
        if (!ddr_rst_n) begin
            grant_src_valid <= 1'b0;
            grant_src_data <= 128'd0;
        end
        else begin
            if (alloc_grant) begin
                grant_src_data  <= frame_grant;
                grant_src_valid <= 1'b1;
            end
            else if (grant_src_valid && grant_src_ready) grant_src_valid <= 1'b0;
        end
    end

    // ================================================== ddr: write adapter
    dgc_ddr_wr_adapter #(.FRAME_BYTES(FRAME_BYTES)) u_wr (
        .clk (ddr_clk), .rst_n (ddr_rst_n),
        .beat_valid (cdc_rd_valid), .beat_ready (cdc_rd_ready), .beat_data (cdc_rd_data),
        .awaddr (wa_awaddr), .awlen (wa_awlen),
        .awuser_ap (), .awuser_id (),
        .awvalid (wa_awvalid), .awready (wa_awready),
        .wdata (wa_wdata), .wstrb (wa_wstrb), .wready (wa_wready),
        .wusero_id (axi_wusero_id), .wusero_last (axi_wusero_last),
        .frame_end (wa_frame_end), .frame_end_slot (wa_end_slot),
        .frame_abort (wa_frame_abort), .frame_abort_slot (wa_abort_slot),
        .cnt_beats (wa_beats), .cnt_bursts (wa_bursts),
        .cnt_frames (wa_frames), .cnt_aborts (wa_aborts), .idle (wa_idle)
    );

    assign axi_awaddr  = wa_awaddr;
    assign axi_awlen   = wa_awlen;
    assign axi_awvalid = wa_awvalid;
    assign wa_awready  = axi_awready;
    assign axi_wdata   = wa_wdata;
    assign axi_wstrb   = wa_wstrb;
    assign wa_wready   = axi_wready;

    assign write_done_p    = wa_frame_end | wa_frame_abort;
    assign write_done_slot = wa_frame_end ? wa_end_slot : wa_abort_slot;
    assign write_good      = wa_frame_end;

    // ================================================== ddr: row + read adapter
    dgc_mailbox #(.W(128)) u_mb_row (
        .src_clk (proc_clk), .rst_src_n (proc_rst_n),
        .src_valid (row_valid_q), .src_ready (mb_row_src_ready), .src_data (row_pack_q),
        .dst_clk (ddr_clk), .rst_dst_n (ddr_rst_n),
        .dst_valid (mb_row_dst_valid), .dst_ready (mb_row_dst_ready),
        .dst_data (mb_row_dst_data)
    );

    dgc_ddr_rd_adapter u_rd (
        .clk (ddr_clk), .rst_n (ddr_rst_n),
        .row_valid (mb_row_dst_valid), .row_ready (mb_row_dst_ready),
        // row_pack layout (LSB first): addr[31:0], row_last[32], beats[37:33],
        // head_skip[42:38], valid_bytes[50:43], local_y[56:51], set[57],
        // tag[73:58], job[105:74]. The beats field starts at bit 33, not 32:
        // slicing [36:32] picked up row_last and shifted the count, so every row
        // was fetched with twice the beats it needed (a 4-beat row produced an
        // 8-beat AR). The unpack consumed only the real beats, the surplus stayed
        // in the read FIFO, and after ~14 blocks the credit saturated and the
        // fill of the next block waited for a row that could never arrive.
        .row_addr (mb_row_dst_data[31:0]),
        .row_beats (mb_row_dst_data[37:33]),
        .rd_beats_gray (rd_gray_sync),
        .ar_addr (ra_araddr), .ar_len (ra_arlen),
        .ar_valid (ra_arvalid), .ar_ready (ra_arready),
        .r_data (axi_rdata), .r_valid (axi_rvalid), .r_last (axi_rlast), .r_id (axi_rid),
        .fifo_full (rd_fifo_full), .fifo_wr (ra_fifo_wr), .fifo_data (ra_fifo_data),
        .busy (ra_busy), .halt (ra_halt), .credit_bad (ra_credit_bad),
        .cnt_err (ra_err), .cnt_beats (ra_beats), .cnt_rows (ra_rows),
        .wr_level (ra_wr_level), .job_restart (1'b0),
        .dbg_ar_wait (dbg_ar_wait), .dbg_ret_starve (dbg_ret_starve),
        .dbg_ret_cnt (dbg_ret_cnt)
    );

    assign axi_araddr  = ra_araddr;
    assign axi_arlen   = ra_arlen;
    assign axi_arvalid = ra_arvalid;
    assign ra_arready  = axi_arready;
    assign stat_ddr_errors = ra_err + {31'd0, ra_halt};

    // ================================================== read FIFO (async)
    ddr_read_fifo u_rdf (
        .wr_clk (ddr_clk), .wr_rst (~ddr_rst_n),
        .wr_en (ra_fifo_wr), .wr_data (ra_fifo_data),
        .wr_full (rdf_wr_full), .wr_water_level (),
        .rd_clk (proc_clk), .rd_rst (~proc_rst_n),
        .rd_en (rdf_pop), .rd_data (rdf_rd_data),
        .almost_full (), .rd_empty (rdf_rd_empty),
        .rd_water_level (), .almost_empty ()
    );
    assign rd_fifo_full = rdf_wr_full;

    dgc_fifo_rd_port #(.DATA_W(256)) u_rdf_port (
        .clk (proc_clk), .rst_n (proc_rst_n),
        .rd_fire (1'b1), .rd_ready (),
        .fifo_empty (rdf_rd_empty), .fifo_pop (rdf_pop), .fifo_data (rdf_rd_data),
        .out_valid (beat_valid_p), .out_ready (beat_ready_p), .out_data (beat_data_p)
    );

    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) begin
            pop_count <= 12'd0;
            rd_gray_proc <= 12'd0;
        end
        else begin
            if (rdf_pop) pop_count <= pop_count + 12'd1;
            rd_gray_proc <= (pop_count >> 1) ^ pop_count;
        end
    end

    always @(posedge ddr_clk or negedge ddr_rst_n) begin
        if (!ddr_rst_n) begin
            rd_gray_s1 <= 12'd0; rd_gray_s2 <= 12'd0;
        end
        else begin
            rd_gray_s1 <= rd_gray_proc;
            rd_gray_s2 <= rd_gray_s1;
        end
    end
    assign rd_gray_sync = rd_gray_s2;

    // ================================================== job control
    dgc_mailbox #(.W(2)) u_mb_acq (
        .src_clk (proc_clk), .rst_src_n (proc_rst_n),
        .src_valid (acq_src_valid), .src_ready (acq_src_ready),
        .src_data ({acq_force_req, 1'b1}),
        .dst_clk (ddr_clk), .rst_dst_n (ddr_rst_n),
        .dst_valid (mb_acq_dst_valid), .dst_ready (1'b1), .dst_data (mb_acq_dst_data)
    );

    assign acquire_p = mb_acq_dst_valid & ~job_hold_valid;
    // force only travels with a request that is actually handed to the manager
    assign acquire_force_p = acquire_p & mb_acq_dst_data[1];

    always @(posedge ddr_clk or negedge ddr_rst_n) begin
        if (!ddr_rst_n) begin
            job_hold_valid <= 1'b0;
            job_hold_data <= 128'd0;
        end
        else begin
            if (acquire_valid) begin
                job_hold_data  <= frame_acquired;
                job_hold_valid <= 1'b1;
            end
            else if (job_hold_valid && job_src_ready) job_hold_valid <= 1'b0;
        end
    end

    dgc_mailbox #(.W(128)) u_mb_job (
        .src_clk (ddr_clk), .rst_src_n (ddr_rst_n),
        .src_valid (job_hold_valid), .src_ready (job_src_ready), .src_data (job_hold_data),
        .dst_clk (proc_clk), .rst_dst_n (proc_rst_n),
        .dst_valid (mb_job_dst_valid),
        .dst_ready (mb_job_dst_ready),
        .dst_data (mb_job_dst_data)
    );

    // ============================================ job start: acquire early, start on the boundary
    //
    // 2026-11-02 (b) board background: the capture frame and the output frame are
    // not phase locked. The camera delivers one frame every ~16.69 ms while the
    // display takes exactly 16.667 ms, so the moment the fresh frame becomes READY
    // slowly drifts through the whole output frame period. While the acquire was
    // issued *at* the boundary, every period in which the capture finished just
    // after the boundary started the job late, the first stripe missed the vertical
    // porch, and the whole frame went black (board: V2 = 0x0080, jobs 33/s, up to
    // 49 ms per job because a black frame also removes the display backpressure).
    //
    // New contract (this is what "ALIGN_TO_FRAME" now means):
    //   * the acquire request goes out as soon as the job FSM is idle again - no
    //     boundary gate, no mailbox latency on the critical path;
    //   * the returned descriptor is HELD (pend_*) until an output frame boundary
    //     arrives, and the job starts exactly on that tick with the source frame
    //     already in hand, so stripe 0 always lands in the porch;
    //   * ALIGN_TO_FRAME = 0 starts immediately, as before.
    //
    // A frame that arrives after the boundary is therefore held for the *next*
    // boundary: one frame of extra latency instead of one black frame. This is the
    // graceful degradation the frozen spec allows ("没有新帧可重复处理最近完整帧"),
    // and it is the only option with 4 stripe banks - a whole output frame cannot be
    // pre-buffered (68 stripes).
    //
    // Safety: the held source slot must not be pinned forever if the display stops
    // (no frame_tick). After ~1.5 frame periods the descriptor is released without
    // starting a job, and no new acquire is issued until a boundary is seen again.
    localparam [23:0] PEND_WD_LIMIT = 24'd4_300_000;   // ~25 ms at 171 MHz
    reg        pend_valid;
    reg [31:0] pend_base;
    reg [31:0] pend_id;
    reg [1:0]  pend_slot;
    reg [23:0] pend_wd;
    reg        wait_tick;          // after a hold timeout: no acquire until a tick shows up

    // 2026-11-02 20:45 (board, post-timing-fix): the capture frame completes every
    // ~16.69 ms while the display frame is 16.667 ms, so the fresh frame becomes
    // READY *after* the boundary most of the time (the phase sweeps one full frame
    // in ~10.6 s). The stale-frame refusal in the manager then blocks the early
    // acquire, and since a job may only start on a `frame_tick` pulse, the job waits
    // a whole frame: 30 jobs/s, every other display frame black. The serial capture
    // shows the smoking gun: steady 30/s with a ~1 s burst of 47/s every ~10.6 s,
    // V0=V3=68*jobs, V1=0.
    //
    // Fix: a start must never be lost to frame freshness. On a boundary with no
    // descriptor in hand, the FSM sends ONE forced acquire, which the manager
    // answers with the newest READY frame even if that repeats the previous job's
    // frame. The job then starts this frame (a repeated frame is a one-frame
    // judder, not a black frame). Non-forced (early) requests keep the refusal, so
    // a newly published capture is always preferred and the 2026-10-30 freeze
    // cannot return.
    //
    // The start window covers the descriptor round trip (mailbox + manager, tens of
    // cycles) and stays far below the 592 us vertical back porch, so stripe 0 still
    // lands in the porch.
    localparam [15:0] START_WINDOW   = 16'd20000;   // ~117 us at 171 MHz. 175 us was verified safe but useless while D > 16.667 ms: the job is still running at the boundary, so no late start is possible. Re-test it once D fits.
    localparam [15:0] TICK_AGE_MAX   = 16'h7FFF;
    reg  [15:0] tick_age;
    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) tick_age <= TICK_AGE_MAX;
        else if (frame_tick) tick_age <= 16'd0;
        else if (tick_age != TICK_AGE_MAX) tick_age <= tick_age + 16'd1;
    end
    wire start_window = ALIGN_TO_FRAME && (tick_age < START_WINDOW);
    wire start_now    = pend_valid && (!ALIGN_TO_FRAME || frame_tick || start_window);
    wire pend_expire  = pend_valid && !start_now && (pend_wd >= PEND_WD_LIMIT);

    // 2026-11-02 21:15 (board): the forced boundary acquire fixed the flicker
    // (60 jobs/s, V0=V3=4080, underflow ~0) but the source frame froze - the job kept
    // repeating the same frame for 9 s. Rule: a repeat is allowed ONCE. If the
    // current job processed a repeated frame, the next boundary must NOT force a
    // repeat; it waits for a genuinely newer capture frame (the early acquire hands
    // it out as soon as it is READY). If the capture has stopped, the wait times out
    // after ~24.5 ms and a repeat is allowed again (spec fallback: keep showing the
    // most recent complete frame instead of going black).
    // 2026-11-03 15:37 board: acq_req saturates (>=255/s) against acq_got=52/s with three
    // READY slots - so it is the stale-refusal wait (one descriptor per capture frame), not a
    // missing frame, that leaves 9 boundaries per second with nothing to start. A boundary
    // must therefore ALWAYS be able to force a repeat; the old 24.5 ms timeout (1.5 frames)
    // was the reason 9 boundaries/s were still skipped after the cap was raised. 2 ms is
    // long enough to reject a pending fresh frame only when the capture is really late.
    localparam [23:0] REPEAT_WD_LIMIT = 24'd342_000;     // ~2 ms at 171 MHz
    reg        job_seen;          // job_id_r is meaningful (at least one job started)
    reg [2:0]  job_repeat;        // consecutive repeats of the same source frame
    reg [23:0] repeat_wd;
    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) repeat_wd <= 24'd0;
        else if (job_start_p) repeat_wd <= 24'd0;
        else if ((job_state == 2'd0) && !pend_valid && job_repeat) begin
            if (repeat_wd < REPEAT_WD_LIMIT) repeat_wd <= repeat_wd + 24'd1;
        end
        else repeat_wd <= 24'd0;
    end
    // A repeat is allowed up to N times in a row: unlimited repeats freeze the picture
    // (board 21:11: same fid for 9 s); one is not enough (board 21:32: 40 jobs/s, a
    // black frame every third boundary). N bounds the judder while never losing a
    // boundary; a stalled capture still falls back after REPEAT_WD_LIMIT.
    localparam [2:0] REPEAT_MAX = 3'd7;   // 2026-11-03: 4 slots make a forced acquire take the NEWEST READY frame (M0 keeps advancing, no freeze), so cover every descriptor-less boundary with a repeat. Judder is bounded by 7; REPEAT_WD_LIMIT (2 ms) covers longer starvation runs.
    wire repeat_ok = (job_repeat < REPEAT_MAX) || (repeat_wd >= REPEAT_WD_LIMIT);

    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) pend_wd <= 24'd0;
        else if (pend_valid && !start_now) begin
            if (pend_wd < PEND_WD_LIMIT) pend_wd <= pend_wd + 24'd1;
        end
        else pend_wd <= 24'd0;
    end

    // A job may only be taken when the FSM is idle, nothing is pending, and (for
    // the descriptor mailbox) it is accepted here; the start is a separate event.
    assign mb_job_dst_ready = (job_state == 2'd0) && !pend_valid;

    dgc_mailbox #(.W(64)) u_mb_rel (
        .src_clk (proc_clk), .rst_src_n (proc_rst_n),
        .src_valid (rel_src_valid), .src_ready (rel_src_ready), .src_data (rel_src_data),
        .dst_clk (ddr_clk), .rst_dst_n (ddr_rst_n),
        .dst_valid (frame_rel_dst_valid), .dst_ready (1'b1),
        .dst_data (frame_rel_dst_data)
    );
    assign frame_rel_p    = frame_rel_dst_valid;
    assign frame_rel_slot = frame_rel_dst_data[33:32];

    // 2026-10-31 14:37 board deadlock: a job can stall forever in C_SAMPLE when
    // the stripe writer holds a bank that nobody releases any more (reader went
    // frame_black without ever owning that stripe). Measured signature: jobs
    // stuck at 3, blocks stuck at 180, Q1=Q2=100% of the second, reader flags
    // 0x0400, bank0_busy=1, output RGB sum 0.
    //
    // A job-level watchdog bounds the damage to one dropped frame: if no
    // core_frame_done arrives for ~1.5 frame periods, release the source frame
    // and let the next job start. The core and the stripe writer both reset on
    // job_start, so the wedged bank is cleared at the next job boundary. This is
    // a mitigation, not the ownership fix: the writer should also accept a
    // release for a bank it still considers WRITING.
    localparam [23:0] JOB_WD_TO = JOB_WD_LIMIT[23:0];   // default ~24.5 ms at 171 MHz
    reg [23:0] job_wd;
    wire       job_wd_expired = (job_state == 2'd1) && (job_wd >= JOB_WD_TO);
    // 2026-11-02: the watchdog is also the job-level abort event. The core passes
    // this one-cycle pulse to the stripe writer, which then returns every bank
    // (reader-owned ones included) to FREE. Without it the reader, which went black
    // and cleared its own ownership, never sends the release and the writer keeps
    // the bank READING forever - the next job then stalls on that bank and the
    // panel stays black until power cycle (observed on the board once).
    reg        job_abort_p;
    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) job_abort_p <= 1'b0;
        else             job_abort_p <= job_wd_expired && !job_abort_p;
    end

    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) job_wd <= 24'd0;
        else if (job_state != 2'd1) job_wd <= 24'd0;
        else if (job_wd < JOB_WD_TO) job_wd <= job_wd + 24'd1;
    end
    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) begin
            acq_src_valid <= 1'b0;
            acq_tried    <= 1'b0;
            rel_src_valid <= 1'b0;
            rel_src_data  <= 64'd0;
            job_start_p   <= 1'b0;
            job_base      <= 32'd0;
            job_id_r      <= 32'd0;
            job_slot      <= 2'd0;
            job_state     <= 2'd0;
            stat_jobs     <= 32'd0;
            acq_wait      <= 11'd0;
            pend_valid    <= 1'b0;
            pend_base     <= 32'd0;
            pend_id       <= 32'd0;
            pend_slot     <= 2'd0;
            wait_tick     <= 1'b0;
            acq_force_req <= 1'b0;
            job_seen      <= 1'b0;
            job_repeat    <= 3'd0;
            src_rel_sent  <= 1'b0;
        end
        else begin
            job_start_p <= 1'b0;
            if (frame_tick) begin
                acq_tried <= 1'b0;
                wait_tick <= 1'b0;
                // 2026-11-02 20:45: nothing in hand on a boundary -> force one
                // acquire so the job can still start this frame (repeat frame)
                // instead of waiting for the next capture and losing a frame.
                if (!pend_valid && !mb_job_dst_valid && !job_start_p && repeat_ok)
                    acq_force_req <= 1'b1;
            end
            else if (acq_src_valid && acq_src_ready) acq_tried <= 1'b1;
            case (job_state)
                2'd0: begin
                    // ---- start on the boundary with the descriptor already held
                    if (start_now) begin
                        job_base    <= pend_base;
                        job_id_r    <= pend_id;
                        job_slot    <= pend_slot;
                        job_start_p <= 1'b1;
                        job_repeat  <= (job_seen && (pend_id == job_id_r)) ? (job_repeat + 3'd1) : 3'd0;
                        job_seen    <= 1'b1;
                        stat_jobs   <= stat_jobs + 32'd1;
                        pend_valid  <= 1'b0;
                        job_state   <= 2'd1;
                        acq_wait    <= 11'd0;
                        src_rel_sent <= 1'b0;
                    end
                    // ---- the display stopped while we held a frame: give the slot
                    //      back instead of starting a job nobody will display
                    else if (pend_expire) begin
                        rel_src_data  <= {30'd0, pend_slot, pend_id};
                        rel_src_valid <= 1'b1;
                        pend_valid    <= 1'b0;
                        wait_tick     <= 1'b1;
                        job_state     <= 2'd2;
                    end
                    // ---- request at most one frame; re-arm after the wait window
                    //      expires without a descriptor (no READY frame yet)
                    //
                    // 2026-11-02 (b): the request is no longer gated by frame_tick.
                    // The 2026-10-30 23:32 bug (re-locking the frame the previous job
                    // had just released, picture frozen, frame age +60/s) was fixed in
                    // the frame manager itself: it refuses a frame whose id equals the
                    // last acquired one while a new capture is in flight, so an early
                    // request can only lock a genuinely new frame (or, if capture has
                    // stopped, repeat the last complete frame - the spec's fallback).
                    else begin
                        if (acq_wait != 11'd0) acq_wait <= acq_wait - 11'd1;
                        if (mb_job_dst_valid) acq_wait <= 11'd0;
                        if (!acq_src_valid && ((acq_wait == 11'd0) || acq_force_req) &&
                            !mb_job_dst_valid && !pend_valid &&
                            (!ALIGN_TO_FRAME || !wait_tick))
                            acq_src_valid <= 1'b1;
                        if (acq_src_valid && acq_src_ready) begin
                            acq_src_valid <= 1'b0;
                            acq_wait      <= 11'd1024;
                            acq_force_req <= 1'b0;   // the force bit has been sent
                        end
                        if (mb_job_dst_valid && mb_job_dst_ready) begin
                            pend_base  <= mb_job_dst_data[63:32];
                            pend_id    <= mb_job_dst_data[31:0];
                            pend_slot  <= mb_job_dst_data[105:104];
                            pend_valid <= 1'b1;
                            acq_wait   <= 11'd0;
                        end
                    end
                end
                2'd1: begin
                    acq_src_valid <= 1'b0;
                    acq_wait      <= 11'd0;
                    // Release handshake for the early release below: the mailbox may
                    // accept the release while the job is still running, and a held
                    // valid would hand the same release to the frame manager twice.
                    if (rel_src_valid && rel_src_ready) rel_src_valid <= 1'b0;
                    // -------------------------------------------------- source release
                    // 2026-11-02 22:45: the source slot is no longer held until the
                    // last pixel reaches the stripe writer. `core_src_idle` says the
                    // core cannot issue another DDR read of frame_base, so the slot may
                    // go back to the manager immediately - about 4 ms before the job
                    // ends when the display paces the tail. That gives the capture side
                    // the slot (and its 16 MiB) back earlier and keeps a frame slot
                    // READY for the next acquire instead of HELD for the whole frame.
                    //
                    // The release is issued once per job (`src_rel_sent`) and still
                    // carries the same payload as before, so the frame manager sees
                    // exactly one release per started job - the acquire/release
                    // accounting (M1/M2, s2_frame_mgr R1-R5b) is unchanged.
                    //
                    // The completion flags below keep their old meaning: the job is
                    // only finished in state 1 when the core reports frame_done (or the
                    // watchdog fires), which is what allows the next job to start.
                    if (!src_rel_sent &&
                        (core_src_idle || core_frame_done || job_wd_expired)) begin
                        rel_src_data  <= {30'd0, job_slot, job_id_r};
                        rel_src_valid <= 1'b1;
                        src_rel_sent  <= 1'b1;
                    end
                    // job_start_p is consumed by the core on this edge.
                    // Until that edge its level-style frame_done still belongs
                    // to the previous job. Never release the new source slot
                    // using that stale completion.
                    if ((core_frame_done && !job_start_p) || job_wd_expired) begin
                        job_state <= 2'd2;
                    end
                end
                default: begin
                    acq_src_valid <= 1'b0;
                    acq_wait      <= 11'd0;
                    if (rel_src_valid && rel_src_ready) rel_src_valid <= 1'b0;
                    if (!rel_src_valid) job_state <= 2'd0;
                end
            endcase
        end
    end
    // ---------------------------------------------- scheduling counters (G0/G1)
    // 2026-11-03 board reading: D = 15.8 ms (fits one frame with 0.87 ms to spare)
    // yet only 45 job/s, so 15 boundaries per second start nothing. The model says a
    // job that fits should be started at every boundary, so the FSM must be sitting
    // idle without a descriptor when the boundary arrives. These counters measure
    // exactly that, instead of another estimate:
    //   no_pend_ms : ms in this interval spent (job_state==0 && !pend_valid)
    //   tick_skip  : boundaries where nothing started and the repeat cap also forbade
    //                forcing (i.e. the black frames; compare with the G underflow
    //                increment - they should match if the diagnosis is right)
    // 2026-11-03 (after 4 slots did NOT change the rate): the next question is *where*
    // the descriptor is lost, so K0 now carries
    //   acq_req : acquire requests handed to the mailbox
    //   acq_got : descriptors actually received back
    // While the FSM waits, acq_req keeps climbing every 6 us; if acq_got stays 0 the
    // frame manager refuses (or has no READY frame), if acq_got tracks acq_req the
    // loss is downstream of the acquire (start/pend handling).
    reg [15:0] no_pend_us;
    reg [7:0]  np_div;
    reg [15:0] tick_skip;
    reg [7:0]  acq_req, acq_got;
    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) begin
            no_pend_us <= 16'd0; np_div <= 8'd0; tick_skip <= 16'd0;
            acq_req <= 8'd0; acq_got <= 8'd0;
        end
        else begin
            if ((job_state == 2'd0) && !pend_valid) begin
                if (np_div == 8'd170) begin
                    np_div <= 8'd0;
                    if (no_pend_us != 16'hFFFF) no_pend_us <= no_pend_us + 16'd1;
                end
                else np_div <= np_div + 8'd1;
            end
            else np_div <= 8'd0;
            // a boundary with nothing to start and no forced acquire = a lost frame
            if (frame_tick && !pend_valid && !mb_job_dst_valid && !job_start_p) begin
                if (!((job_repeat < REPEAT_MAX) || (repeat_wd >= REPEAT_WD_LIMIT)))
                    if (tick_skip != 16'hFFFF) tick_skip <= tick_skip + 16'd1;
            end
            if (acq_src_valid && acq_src_ready)
                if (acq_req != 8'hFF) acq_req <= acq_req + 8'd1;
            if (mb_job_dst_valid && mb_job_dst_ready)
                if (acq_got != 8'hFF) acq_got <= acq_got + 8'd1;
            if (dbg_proc_latch) begin
                no_pend_us <= 16'd0;
                tick_skip  <= 16'd0;
                acq_req    <= 8'd0;
                acq_got    <= 8'd0;
            end
        end
    end
    // published in units of 1024 us (= 1.024 ms) so it cannot saturate: 16 bits = 67 s.
    // A shift instead of a divider keeps this out of the timing budget.
    assign dbg_no_pend_us = {6'd0, no_pend_us[15:10]};
    assign dbg_tick_skip  = tick_skip;
    assign dbg_acq_req    = acq_req;
    assign dbg_acq_got    = acq_got;


    // ================================================== stripe mailboxes
    dgc_mailbox #(.W(64)) u_mb_offer (
        .src_clk (proc_clk), .rst_src_n (proc_rst_n),
        .src_valid (offer_valid_c), .src_ready (offer_ready_c), .src_data (offer_data_c),
        .dst_clk (vout_clk), .rst_dst_n (vout_rst_n),
        .dst_valid (mb_offer_dst_valid), .dst_ready (mb_offer_dst_ready),
        .dst_data (mb_offer_dst_data)
    );

    dgc_mailbox #(.W(64)) u_mb_srel (
        .src_clk (vout_clk), .rst_src_n (vout_rst_n),
        .src_valid (srel_valid), .src_ready (srel_ready), .src_data (srel_data),
        .dst_clk (proc_clk), .rst_dst_n (proc_rst_n),
        .dst_valid (mb_rel_dst_valid), .dst_ready (mb_rel_dst_ready),
        .dst_data (mb_rel_dst_data)
    );

    // stripe release payload: {22'd0, status2, bank1, stripe7, job32}
    always @(posedge proc_clk or negedge proc_rst_n) begin
        if (!proc_rst_n) begin
            rel_c <= 1'b0; rel_bank_c <= 2'd0; rel_bad_c <= 1'b0;
        end
        else begin
            rel_c <= 1'b0;
            if (mb_rel_dst_valid) begin
                rel_c      <= 1'b1;
                rel_bank_c <= {mb_rel_dst_data[42], mb_rel_dst_data[39]};
                rel_bad_c  <= (mb_rel_dst_data[41:40] != 2'd0);
            end
        end
    end
    assign mb_rel_dst_ready = 1'b1;

    // ================================================== dgc_core
    wire        dbg_fill_wr, dbg_fill_wait_beat, dbg_fill_wait_row;
    wire        dbg_fill_wait_plan, dbg_samp_stall_wr, dbg_samp_stall_smp;

    dgc_core u_core (
        .clk (proc_clk), .rst_n (proc_rst_n),
        .job_start (job_start_p), .job_abort (job_abort_p), .job_id (job_id_r), .frame_base (job_base),
        .cfg_mode (cfg_mode),
        .cfg_m00 (cfg_m00), .cfg_m01 (cfg_m01), .cfg_m02 (cfg_m02),
        .cfg_m10 (cfg_m10), .cfg_m11 (cfg_m11), .cfg_m12 (cfg_m12),
        .cfg_fx (cfg_fx), .cfg_fy (cfg_fy), .cfg_cx (cfg_cx), .cfg_cy (cfg_cy),
        .cfg_k1 (cfg_k1), .cfg_k2 (cfg_k2),
        .cfg_norm_abs_max (cfg_norm_abs_max),
        .gamma_mode (gamma_mode),
        .row_valid (row_valid), .row_ready (row_ready),
        .row_addr (row_addr), .row_beats (row_beats),
        .row_head_skip (row_head_skip), .row_valid_bytes (row_valid_bytes),
        .row_local_y (row_local_y), .row_row_last (row_row_last),
        .row_set (row_set), .row_tag (row_tag), .row_job_id (row_job_id),
        .beat_valid (beat_valid_p), .beat_ready (beat_ready_p), .beat_data (beat_data_p),
        .ram_rd_clk (vout_clk), .ram_rd_rst_n (vout_rst_n),
        .ram0_rd_addr (ram0_rd_addr), .ram0_rd_data (ram0_rd_data),
        .ram1_rd_addr (ram1_rd_addr), .ram1_rd_data (ram1_rd_data),
        .ram2_rd_addr (ram2_rd_addr), .ram2_rd_data (ram2_rd_data),
        .ram3_rd_addr (ram3_rd_addr), .ram3_rd_data (ram3_rd_data),
        .offer_valid (offer_valid_c), .offer_ready (offer_ready_c),
        .offer_data (offer_data_c),
        .rel (rel_c), .release_bank (rel_bank_c), .release_status_bad (rel_bad_c),
        .frame_done (core_frame_done), .src_idle (core_src_idle), .busy (core_busy),
        .cnt_accept (core_accept), .cnt_black (core_black), .cnt_split (core_split),
        .cnt_pixels (core_pixels), .cnt_blocks_done (core_blocks),
        .dbg_cstate (dbg_cstate), .dbg_fill_busy (dbg_fill_busy),
        .dbg_samp_busy (dbg_samp_busy), .dbg_next_valid (dbg_next_valid),
        .dbg_pix_seen (dbg_pix_seen), .dbg_fill_flags (dbg_fill_flags),
        .dbg_wr_busy (dbg_wr_busy), .dbg_aux_busy (dbg_aux_busy), .dbg_wr_state (dbg_wr_state),
        // 2026-11-02: these two were declared as outputs of this module but never
        // connected to the core, so K2's reading0/1 (from dbg_reading) and
        // K3[10]/J2[12] (the writer watchdog sticky, dbg_rd_timeout) were floating
        // on the board - exactly the two fields the DGC5 black-screen decision table
        // relies on. Both are simple taps of the stripe writer.
        .dbg_reading (dbg_reading), .dbg_rd_timeout (dbg_rd_timeout),
        .dbg_pix_sid (dbg_pix_sid), .dbg_cur_sid0 (dbg_cur_sid0),
        .dbg_pix_over (dbg_pix_over),
        .dbg_fill_wr (dbg_fill_wr),
        .dbg_fill_wait_beat (dbg_fill_wait_beat),
        .dbg_fill_wait_row (dbg_fill_wait_row),
        .dbg_fill_wait_plan (dbg_fill_wait_plan),
        .dbg_samp_stall_wr (dbg_samp_stall_wr),
        .dbg_samp_stall_smp (dbg_samp_stall_smp)
    );

    assign row_pack = {22'd0, row_job_id, row_tag, row_set, row_local_y,
                       row_valid_bytes, row_head_skip, row_beats, row_row_last,
                       row_addr};

    // ================================================ DGC3 performance counters
    // Read-only. Two domains, each publishing "cycles since the previous
    // snapshot" on the same edge that freezes that domain's status hold.
    //
    // proc: the 28 ms job has to be attributed either to the source-cache fill
    // (waiting for DDR beats / for the row channel) or to the sample side being
    // held by the stripe writer. These eight fields are that split; fill_active
    // plus sample_active against the job time says which engine owns the block.
    wire [127:0] perf_proc;
    dgc_perf_ctr #(.N(8), .SHIFT(12)) u_perf_proc (
        .clk (proc_clk), .rst_n (proc_rst_n), .latch (dbg_proc_latch),
        .ev ({dbg_samp_stall_smp, dbg_samp_stall_wr,
              (dbg_cstate == 3'd2), dbg_fill_wr,
              dbg_fill_wait_plan, dbg_fill_wait_row, dbg_fill_wait_beat,
              dbg_fill_busy}),
        .value (perf_proc)
    );

    // ddr: is the native read channel refusing the next AR, holding requests
    // without returning beats, and does more than one request ever overlap?
    wire [31:0] perf_ddr_cyc;
    wire [15:0] perf_ddr_ar;
    wire        ar_fire = ra_arvalid & axi_arready;

    dgc_perf_ctr #(.N(2), .SHIFT(12)) u_perf_ddr_cyc (
        .clk (ddr_clk), .rst_n (ddr_rst_n), .latch (dbg_ddr_latch),
        .ev ({dbg_ret_starve, dbg_ar_wait}), .value (perf_ddr_cyc)
    );
    // Native AR handshakes: ~2e6 per second on the board, so SHIFT=7 (one LSB
    // is 128 ARs, 16k..32k counts per report).
    dgc_perf_ctr #(.N(1), .SHIFT(7)) u_perf_ddr_ar (
        .clk (ddr_clk), .rst_n (ddr_rst_n), .latch (dbg_ddr_latch),
        .ev (ar_fire), .value (perf_ddr_ar)
    );

    // How deep the request pipeline really got. If the board never shows more
    // than one outstanding AR, the IP (not our queue depth) serialises reads.
    reg [3:0] ddr_ret_max, ddr_ret_max_pub;
    always @(posedge ddr_clk or negedge ddr_rst_n) begin
        if (!ddr_rst_n) begin
            ddr_ret_max <= 4'd0;
            ddr_ret_max_pub <= 4'd0;
        end
        else if (dbg_ddr_latch) begin
            ddr_ret_max_pub <= (dbg_ret_cnt > ddr_ret_max) ? dbg_ret_cnt
                                                            : ddr_ret_max;
            ddr_ret_max <= 4'd0;
        end
        else if (dbg_ret_cnt > ddr_ret_max) begin
            ddr_ret_max <= dbg_ret_cnt;
        end
    end

    // R line word order (LSB first): ARs, AR-wait, return-starve, max in flight.
    assign dbg_perf_proc = perf_proc;
    assign dbg_perf_ddr  = {{12'd0, ddr_ret_max_pub}, perf_ddr_cyc[31:16],
                            perf_ddr_cyc[15:0], perf_ddr_ar};

    // ================================================== vout: video reader
    dgc_video_reader u_reader (
        .clk (vout_clk), .rst_n (vout_rst_n),
        .de_in (de_tg), .hs_in (hs_tg), .vs_in (vs_tg),
        .x_in (x_tg), .y_in (y_tg),
        .offer_valid (mb_offer_dst_valid), .offer_ready (mb_offer_dst_ready),
        .offer_data (mb_offer_dst_data),
        .release_valid (srel_valid), .release_ready (srel_ready),
        .release_data (srel_data),
        .ram0_rd_addr (ram0_rd_addr), .ram0_rd_data (ram0_rd_data),
        .ram1_rd_addr (ram1_rd_addr), .ram1_rd_data (ram1_rd_data),
        .ram2_rd_addr (ram2_rd_addr), .ram2_rd_data (ram2_rd_data),
        .ram3_rd_addr (ram3_rd_addr), .ram3_rd_data (ram3_rd_data),
        .rgb (rgb_out), .de_out (de_out), .hs_out (hs_out), .vs_out (vs_out),
        .cnt_underflow (stat_stripes_underflow),
        .cnt_frames (reader_frames), .cnt_discard (reader_discards),
        .cnt_offers (reader_offers), .cnt_releases (reader_releases),
        .cnt_rel_drop (reader_rel_drop),
        .frame_black (frame_black),
        .dbg_cur_stripe (reader_cur_stripe),
        .dbg_frame_ok (reader_frame_ok),
        .dbg_cur_ok (reader_cur_ok),
        .dbg_waiting_first (reader_waiting_first),
        .dbg_have_next (reader_have_next),
        .dbg_cur_bank (reader_cur_bank),
        .dbg_next_bank (reader_next_bank),
        .dbg_events (reader_events),
        .dbg_vs_discard (reader_vs_discard),
        .dbg_uf_stripe (reader_uf_stripe),
        .dbg_uf_first  (reader_uf_first)
    );

    // DGC5: per-second reader activity, computed in the vout domain on the same
    // edge that freezes u_snap_vout, so the four words describe exactly the
    // interval of the rest of the report. SHIFT=0: these are small counts
    // (offers ~60/s, releases ~4080/s), not cycle counts.
    dgc_perf_ctr #(.N(4), .SHIFT(0)) u_perf_vout (
        .clk (vout_clk), .rst_n (vout_rst_n), .latch (dbg_vout_latch),
        .ev (reader_events),
        .value (dbg_perf_vout)
    );

    reg [15:0] dbg_write_done_r;
    always @(posedge ddr_clk or negedge ddr_rst_n) begin
        if (!ddr_rst_n) dbg_write_done_r <= 16'd0;
        else if (write_done_p) dbg_write_done_r <= dbg_write_done_r + 16'd1;
    end

    assign stat_frames_processed = stat_jobs;
    assign dbg_core_busy = core_busy;
    assign dbg_job_state = job_state;
    assign dbg_cap_frames  = cap_frames[15:0];
    assign dbg_cap_aborted = cap_aborted[15:0];
    assign dbg_cap_rows    = cap_rows;
    assign dbg_write_done  = dbg_write_done_r;
    assign dbg_wa_frames   = wa_frames[15:0];
    assign dbg_wa_aborts   = wa_aborts[15:0];
    assign dbg_drop        = stat_frames_dropped[15:0];
    assign dbg_slot_state  = fm_slot_state;
    assign dbg_fm_alloc    = fm_alloc[15:0];
    assign dbg_fm_drop     = stat_frames_dropped[15:0];
    assign dbg_fm_acquire  = fm_acquire_cnt[15:0];
    assign dbg_fm_release  = fm_release_cnt[15:0];
    assign dbg_core_blocks = core_blocks[15:0];
    // DGC5 reader flags (G3). 2026-11-01: four banks, so the two bank fields are
    // two bits each and occupy the four formerly reserved MSBs:
    //   [15:14] next_bank[1:0], [13:12] cur_bank[1:0],
    //   [11] have_next, [10] frame_black, [9] waiting_first,
    //   [8] cur_ok, [7] frame_ok, [6:0] cur_stripe.
    assign dbg_reader_flags = {reader_next_bank, reader_cur_bank,
                               reader_have_next, frame_black,
                               reader_waiting_first, reader_cur_ok,
                               reader_frame_ok, reader_cur_stripe};
    assign dbg_cur_bank   = reader_cur_bank;
    assign dbg_next_bank  = reader_next_bank;
    assign dbg_rel_drop   = (reader_rel_drop != 16'd0);
    assign dbg_vs_discard = reader_vs_discard;
    assign dbg_offers = reader_offers[15:0];
    assign dbg_job_fid = job_id_r[15:0];

endmodule












