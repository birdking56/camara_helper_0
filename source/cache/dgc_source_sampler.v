//-----------------------------------------------------------------------------
// dgc_source_sampler.v
//
// Turns the 96-bit coordinate stream into the frozen 192-bit four-neighbour
// sample record, using the four-port source cache.
//
// Frozen reference: 接口冻结规范_v1.md sections 8 and 9.
//
//   in : coord_valid/ready, coord_data[95:0]      (from the coordinate FIFO)
//   out: sample_valid/ready, sample_data[191:0]
//        [95:0] coord_record, [119:96] P00, [143:120] P10,
//        [167:144] P01, [191:168] P11
//
// Behaviour
//   * One output record per input record, in order. The coordinate record
//     travels through unchanged (sample_ok, math_error, tile_tag, weights),
//     so the pixel metadata that reaches bilinear is the mapper's, not a
//     re-derived copy.
//   * A record with sample_ok = 0 reads nothing and emits an all-zero
//     neighbour set. Bilinear then fills black; the cache is never addressed
//     for an invalid point, which is what keeps an unwritten hole from leaking
//     into the black fill.
//   * At the extreme right/bottom the neighbour is the same point. It is read
//     once (dgc_read_issue) and replicated (dgc_sample_dedup), so a single bank
//     never receives two different addresses in one cycle.
//   * Block-local coordinates are computed from the bbox origin that was captured
//     together with each record (`cdq_bx/cdq_by`), not from the current block's
//     bbox: the core may switch to the next block on the very cycle the last
//     record is taken (2026-11-02 inline switch), so the block context is no
//     longer guaranteed to be stable while a record is in flight.
//
// Timing
//   dgc_source_cache4 has no read-ready: fire in cycle N and the data plus its
//   valid flag appear `LAT` cycles later, together for all ports of one record.
//   The coordinate metadata therefore travels through a LAT-deep shift register
//   so that it meets its data. `LAT` is a parameter because it is a property of
//   the generated RAM wrapper (measured 3 by s0_rd_port) and the simulation
//   checks the alignment rather than trusting it.
//
// Backpressure
//   The cache cannot be stalled, so an issued record always completes. To keep
//   a stalled output from losing completed records, completed samples go into a
//   small output FIFO and new records are only issued while the FIFO plus the
//   in-flight records still fit. That bound is what makes the FIFO overflow
//   impossible rather than merely unlikely.
//
// Error accounting
//   `cnt_out_of_block` counts records whose sample_ok was set but whose local
//   coordinates fall outside the 64x64 container. That can only happen if the
//   bbox accumulated by the mapper is wrong; the sampler then emits zeros
//   instead of reading an address that belongs to another block.
//-----------------------------------------------------------------------------

module dgc_source_sampler #(
    parameter integer LAT      = 3,      // cache fire -> valid, in cycles
    parameter integer FIFO_DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- block context (stable for the whole block) -------------
    input  wire [10:0] blk_bbox_x,
    input  wire [10:0] blk_bbox_y,
    input  wire        blk_set,          // which cache set the block lives in
    // Set of the record currently being *fired* at the cache read ports (two cycles
    // behind the take, see below). dgc_core connects this to the cache's rd_set so
    // that the set may change on the very cycle a block's last record is taken.
    output wire        rd_set_o,

    // ---------------- coordinate stream --------------------------------------
    input  wire        cd_valid,
    output wire        cd_ready,
    input  wire [95:0] cd_data,

    // ---------------- four cache read ports ---------------------------------
    output wire        p0_fire, output wire [5:0] p0_x, p0_y,
    output wire        p1_fire, output wire [5:0] p1_x, p1_y,
    output wire        p2_fire, output wire [5:0] p2_x, p2_y,
    output wire        p3_fire, output wire [5:0] p3_x, p3_y,
    input  wire        p0_valid, input wire [23:0] p0_d,
    input  wire        p1_valid, input wire [23:0] p1_d,
    input  wire        p2_valid, input wire [23:0] p2_d,
    input  wire        p3_valid, input wire [23:0] p3_d,

    // ---------------- functional observation for the cache handover ----------
    // `rd_push` is the pulse of a completed record being written into the output
    // FIFO; `rd_inflight` is the number of records that are still inside the
    // cache read pipeline. dgc_core uses both to decide when the *previous*
    // block's cache set may return to FREE after an inline block switch: the set
    // may be released as soon as its last read has returned, long before the last
    // pixel has reached the stripe writer.
    output wire        rd_push,
    output wire [7:0]  rd_inflight,

    // ---------------- sample stream to gamma ---------------------------------
    output wire        sample_valid,
    input  wire        sample_ready,
    output wire [191:0] sample_data,

    // ---------------- diagnostics -------------------------------------------
    output reg  [31:0] cnt_samples,
    output reg  [31:0] cnt_out_of_block,
    output wire        busy               // records still in flight or queued
);

    // -------------------------------------------------------------- decode
    // Second alignment stage (2026-10-29, second timing pass). With one register
    // between the neighbour arithmetic and the cache, the worst path became
    //   rd_ptr -> FIFO LUTRAM -> min/sub -> pre_act   -0.281 ns (4 endpoints)
    // so that half alone still exceeded the 5.55 ns period. Registering the FIFO
    // word first splits the LUTRAM read from the min/sub chain; the latency
    // pipeline below starts at `pre`, which is one stage later than before, and
    // the data still meets it LAT cycles after the fire.
    wire        take = cd_valid & cd_ready;

    reg         cdq_v;
    reg  [95:0] cdq;
    // 2026-11-02 (c): the block bbox is captured together with the record instead of
    // being sampled combinationally one cycle later. The core can then switch to the
    // next block's bbox on the very cycle the last record is accepted (the cache's
    // delayed set select takes care of the read data), which removes the C_DRAIN
    // wait for the read pipeline. Behaviour is identical while the bbox is held for
    // a whole block, as it is today.
    reg  [10:0] cdq_bx, cdq_by;
    // 2026-11-02 (d): the cache read is *fired* two cycles after the take
    // (take -> cdq -> pre/fire), so the set must travel with the record through
    // exactly two stages and be presented on the fire cycle.
    //
    // 2026-11-02 (e): the second experiment drove the cache from a THREE-stage
    // replica (`set_s2`) and broke every block boundary: at the fire cycle that
    // replica still carried the *previous* record's set, so each block's first
    // record read the set the previous block lived in (s4_core reported 32-pixel
    // source misalignment at (32,0), (64,0), ...).  One stage less (driving the
    // cache from `blk_set`) breaks the last two records of a block the other way.
    // `fire_set` is the single correct alignment; do not add or remove a stage.
    reg         cdq_set, fire_set;
    assign rd_set_o = fire_set;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cdq_v <= 1'b0; cdq <= 96'd0; cdq_bx <= 11'd0; cdq_by <= 11'd0;
                       cdq_set <= 1'b0; fire_set <= 1'b0; end
        else begin
            if (take) begin
                cdq_v  <= 1'b1;
                cdq    <= cd_data;
                cdq_bx <= blk_bbox_x;
                cdq_by <= blk_bbox_y;
                cdq_set <= blk_set;
            end
            else cdq_v <= 1'b0;
            fire_set <= cdq_set;
        end
    end

    wire [10:0] sx0 = cdq[32:22];
    wire [10:0] sy0 = cdq[43:33];
    wire        ok  = cdq[92];

    wire [10:0] sx1, sy1;
    wire [5:0]  lx0, ly0, lx1, ly1;
    wire        edge_x, edge_y, active, in_block;

    dgc_neighbour_calc u_nb (
        .sx0(sx0), .sy0(sy0),
        .bbox_x(cdq_bx), .bbox_y(cdq_by),
        .sample_ok(ok),
        .sx1(sx1), .sy1(sy1),
        .lx0(lx0), .ly0(ly0), .lx1(lx1), .ly1(ly1),
        .edge_x(edge_x), .edge_y(edge_y),
        .active(active), .in_block(in_block)
    );

    // a record is only allowed to touch the cache when it really belongs to
    // this block; otherwise it is treated exactly like an invalid coordinate
    wire        real_read = active & in_block;

    wire        p0_f, p1_f, p2_f, p3_f;
    wire [2:0]  reads;
    dgc_read_issue u_ri (
        .edge_x(edge_x), .edge_y(edge_y),
        .p0_fire(p0_f), .p1_fire(p1_f), .p2_fire(p2_f), .p3_fire(p3_f),
        .reads(reads)
    );

    // Reads must be issued exactly once per record. While the output side is
    // stalled, cd_valid stays high with the same payload, so an ungated fire
    // would re-read the same coordinates every cycle and leave stray returns
    // arriving at the wrong time - which showed up as zero P10/P11 in the
    // random-stall case. `take` is the accepted-record pulse.
    // ------------------------------------------------------- read-issue pre-stage
    // 2026-10-29 timing: the placed design reported
    //   u_cfifo/u_rd/rd_ptr[1] -> u_cache/u_set0/vf2[1]  -0.466 ns @180 MHz
    // (11 endpoints, TNS -2.037). That is one combinational chain: the coord
    // FIFO's LUTRAM read, then neighbour_calc's min/subtract arithmetic, then
    // the cache read-address registers. Register the arithmetic result here and
    // issue the cache read on the following cycle; the latency pipeline below
    // also starts from this register, so the recorded sample still meets its
    // data LAT cycles after the fire.
    reg         pre_v;
    reg  [95:0] pre_cd;
    reg         pre_act, pre_ex, pre_ey;
    reg  [5:0]  pre_x0, pre_y0, pre_x1, pre_y1;
    reg         pre_f0, pre_f1, pre_f2, pre_f3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_v <= 1'b0; pre_cd <= 96'd0;
            pre_act <= 1'b0; pre_ex <= 1'b0; pre_ey <= 1'b0;
            pre_x0 <= 6'd0; pre_y0 <= 6'd0; pre_x1 <= 6'd0; pre_y1 <= 6'd0;
            pre_f0 <= 1'b0; pre_f1 <= 1'b0; pre_f2 <= 1'b0; pre_f3 <= 1'b0;
        end
        else begin
            pre_v   <= cdq_v;
            pre_cd  <= cdq;
            pre_act <= cdq_v & real_read;
            pre_ex  <= edge_x;
            pre_ey  <= edge_y;
            pre_x0  <= lx0; pre_y0 <= ly0;
            pre_x1  <= lx1; pre_y1 <= ly1;
            pre_f0  <= p0_f; pre_f1 <= p1_f;
            pre_f2  <= p2_f; pre_f3 <= p3_f;
        end
    end

    assign p0_fire = pre_v & pre_act & pre_f0;
    assign p1_fire = pre_v & pre_act & pre_f1;
    assign p2_fire = pre_v & pre_act & pre_f2;
    assign p3_fire = pre_v & pre_act & pre_f3;

    assign p0_x = pre_x0; assign p0_y = pre_y0;
    assign p1_x = pre_x1; assign p1_y = pre_y0;
    assign p2_x = pre_x0; assign p2_y = pre_y1;
    assign p3_x = pre_x1; assign p3_y = pre_y1;

    // ------------------------------------------------------- in-flight budget
    // `inflight` counts issued records that have not reached the output FIFO.
    // Issuing is allowed while the FIFO plus the in-flight records still leave
    // room for the *next* record, so no completed sample can ever be dropped.
    //
    // 2026-11-02 (b): the reservation was two slots, i.e. issue was blocked at
    // inflight+level >= 6 with an 8-deep FIFO. In steady state the level settles
    // at ~3 (three pushes happen before the first pop) and inflight is LAT=3, so
    // budget_used sits exactly on 6 and the sampler stalls itself every few
    // cycles: the s4_core probe measured **93 of 602 sample cycles** spent with
    // no sample available (smpstarve) while the stripe writer never pushed back
    // (wrstall=0). That self-inflicted bubble is 4080 x 93 = 380k cycles = 2.2 ms
    // per frame - the reason the job does not fit into one display frame.
    //
    // One reserved slot is enough: the invariant (level + inflight <= DEPTH-1) is
    // preserved by every push (it moves one record from inflight to level), so the
    // level can never exceed DEPTH-1 and a completed record can never be dropped.
    // This costs no registers at all.
    localparam integer CTR_W  = 8;
    localparam integer FIFO_AW = (FIFO_DEPTH == 8) ? 3 :
                                 (FIFO_DEPTH == 16) ? 4 : 4;
    reg  [CTR_W-1:0] inflight;
    reg  [CTR_W-1:0] fifo_level;

    // one record leaves the latency pipeline every cycle it was issued
    wire inline_done;

    wire [CTR_W-1:0] budget_used = inflight + fifo_level;
    wire issue_ok = (budget_used < (FIFO_DEPTH - 1));

    assign cd_ready = issue_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) inflight <= {CTR_W{1'b0}};
        else begin
            // a record leaves the latency pipe when it is written to the FIFO
            case ({take, inline_done})
                2'b10: inflight <= inflight + 1'b1;
                2'b01: inflight <= inflight - 1'b1;
                default: ;
            endcase
        end
    end

    // --------------------------------------------------- latency alignment
    // One entry per cycle: the record itself plus the flags needed to rebuild
    // the four neighbours from the distinct reads.
    reg [95:0]  lat_cd  [0:LAT-1];
    reg         lat_act [0:LAT-1];
    reg         lat_ex  [0:LAT-1];
    reg         lat_ey  [0:LAT-1];
    reg         lat_v   [0:LAT-1];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < LAT; k = k + 1) begin
                lat_cd[k] <= 96'd0; lat_act[k] <= 1'b0;
                lat_ex[k] <= 1'b0; lat_ey[k] <= 1'b0; lat_v[k] <= 1'b0;
            end
        end
        else begin
            // the record now leaves the pre-stage, so the alignment pipeline
            // starts there too (fire and lat capture happen on the same edge)
            lat_cd[0]  <= pre_cd;
            lat_act[0] <= pre_v & pre_act;
            lat_ex[0]  <= pre_ex;
            lat_ey[0]  <= pre_ey;
            lat_v[0]   <= pre_v;
            for (k = 1; k < LAT; k = k + 1) begin
                lat_cd[k]  <= lat_cd[k-1];
                lat_act[k] <= lat_act[k-1];
                lat_ex[k]  <= lat_ex[k-1];
                lat_ey[k]  <= lat_ey[k-1];
                lat_v[k]   <= lat_v[k-1];
            end
        end
    end

    // the record that completed LAT cycles after it was issued
    wire [95:0] done_cd  = lat_cd[LAT-1];
    wire        done_act = lat_act[LAT-1];
    wire        done_ex  = lat_ex[LAT-1];
    wire        done_ey  = lat_ey[LAT-1];
    assign      inline_done = lat_v[LAT-1];

    // Only the ports that were actually issued carry valid data. The dedup stage
    // ignores the lanes that an edge collapsed, so their value is irrelevant.
    wire [23:0] r00 = done_act ? p0_d : 24'd0;
    wire [23:0] r10 = (done_act & ~done_ex) ? p1_d : 24'd0;
    wire [23:0] r01 = (done_act & ~done_ey) ? p2_d : 24'd0;
    wire [23:0] r11 = (done_act & ~done_ex & ~done_ey) ? p3_d : 24'd0;

    wire [23:0] q00, q10, q01, q11;
    wire [2:0]  need, dup;
    dgc_sample_dedup u_dd (
        .edge_x(done_ex), .edge_y(done_ey),
        .r00(r00), .r10(r10), .r01(r01), .r11(r11),
        .p00(q00), .p10(q10), .p01(q01), .p11(q11),
        .need(need), .dup(dup)
    );

    wire [191:0] done_sample = {q11, q01, q10, q00, done_cd};

    // ------------------------------------------------------------ output FIFO
    reg [191:0] fifo [0:FIFO_DEPTH-1];
    reg [CTR_W-1:0] fifo_wp, fifo_rp;

    wire fifo_empty = (fifo_level == 0);
    wire fifo_push  = inline_done;
    wire fifo_pop   = (~fifo_empty) & sample_ready;

    always @(posedge clk) begin
        if (fifo_push) fifo[fifo_wp[FIFO_AW-1:0]] <= done_sample;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wp <= {CTR_W{1'b0}};
            fifo_rp <= {CTR_W{1'b0}};
            fifo_level <= {CTR_W{1'b0}};
        end
        else begin
            if (fifo_push) begin
                fifo_wp <= fifo_wp + 1'b1;
                if (!fifo_pop) fifo_level <= fifo_level + 1'b1;
            end
            else if (fifo_pop) begin
                fifo_level <= fifo_level - 1'b1;
            end
            if (fifo_pop) fifo_rp <= fifo_rp + 1'b1;
        end
    end

    assign sample_valid = ~fifo_empty;
    assign sample_data  = fifo[fifo_rp[FIFO_AW-1:0]];
    assign busy         = (fifo_level != 0) | (inflight != 0) | inline_done;
    assign rd_push      = inline_done;
    assign rd_inflight  = inflight;

    // ---------------------------------------------------------- diagnostics
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_samples <= 32'd0;
            cnt_out_of_block <= 32'd0;
        end
        else begin
            if (fifo_pop) cnt_samples <= cnt_samples + 32'd1;
            // active/in_block are computed from cdq (one stage after take), so
            // the counter must be qualified by cdq_v, not by take.
            if (cdq_v && active && !in_block) cnt_out_of_block <= cnt_out_of_block + 32'd1;
        end
    end

`ifdef DGC_SIM
    // The cache guarantees a valid three cycles after a fire. If the parameter
    // ever drifts from the generated RAM latency, this fires immediately instead
    // of silently pairing a record with the previous one's pixels.
    wire exp_p0 = done_act;
    wire exp_p1 = done_act & ~done_ex;
    wire exp_p2 = done_act & ~done_ey;
    wire exp_p3 = done_act & ~done_ex & ~done_ey;

    always @(posedge clk) begin
        if (rst_n && inline_done) begin
            if ((p0_valid !== exp_p0) || (p1_valid !== exp_p1) ||
                (p2_valid !== exp_p2) || (p3_valid !== exp_p3))
                $display("DGC_ERROR: dgc_source_sampler port valid mismatch with LAT=%0d t=%0t",
                         LAT, $time);
        end
        else if (rst_n) begin
            if (p0_valid | p1_valid | p2_valid | p3_valid)
                $display("DGC_ERROR: dgc_source_sampler stray cache valid with LAT=%0d t=%0t",
                         LAT, $time);
        end
    end
`endif

endmodule
