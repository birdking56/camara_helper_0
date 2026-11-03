//-----------------------------------------------------------------------------
// dgc_fill_ctrl.v
//
// Fills one source cache set for one ACCEPT block.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   ACCEPT descriptor
//     -> reserve a cache set (owner: FREE -> FILLING)
//     -> fetch_planner expands the bbox into one fetch_row per source row
//     -> each row goes to the DDR mailbox AND into a local descriptor queue that
//        tells unpack how to read the returned beats
//     -> unpack turns 256-bit beats into 1 or 2 pixels
//     -> both pixels of a record are written to the source cache in ONE cycle
//        (channel 0 = x, channel 1 = x+1, different parity banks)
//     -> the write of the tile_last record completes the fill (FILLING -> READY)
//
// 2026-10-30: this module used to split a two-pixel record into two one-pixel
// write cycles. The board P/Q counters then showed the cache write port as the
// dominant cost of a fill (556 of 707 cycles per block), which made the job
// 17.5 ms instead of the 15 ms the two-pixel path achieves. The cache now has
// the two write channels the frozen spec section 8 already asked for, so the
// split is gone and a record costs one cycle.
//
// The row descriptor is delivered to two places at once and the planner only
// advances when both accept it, so the DDR request and the unpack interpretation
// of its data can never get out of step.
//
// Abort
//   `abort` (DDR protocol error, job restart) stops the fill and returns the set
//   to FREE through the owner's fill_abort. The beats already in the read FIFO
//   are the session-reset logic's problem, not this module's.
//-----------------------------------------------------------------------------

module dgc_fill_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- job / block context ------------------------------------
    input  wire        start,            // pulse: fill the descriptor below
    input  wire [31:0] frame_base,
    input  wire [31:0] job_id,
    input  wire [15:0] tag,
    input  wire [10:0] bbox_x, bbox_y,
    input  wire [6:0]  bbox_w, bbox_h,
    input  wire        abort,

    // ---------------- cache ownership ---------------------------------------
    output reg         owner_fill_begin,
    input  wire        owner_fill_ok,
    input  wire [1:0]  owner_fill_set,
    output reg         owner_fill_complete,
    output reg         owner_fill_abort,

    // ---------------- row descriptor to the DDR mailbox ----------------------
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

    // ---------------- reader beat stream (from ddr_read_fifo) ---------------
    input  wire        beat_valid,
    output wire        beat_ready,
    input  wire [255:0] beat_data,

    // ---------------- source cache write port -------------------------------
    // A two-pixel unpack record is written in ONE cycle over the two write
    // channels of the cache (x and x+1 land in different parity banks). The
    // earlier version split every record into two one-pixel cycles, which the
    // board then measured as the dominant fill cost (556 of 707 cycles/block).
    output reg         fill_wr,
    output reg         fill_wr2,       // second pixel of the same record
    output reg  [5:0]  fill_x,
    output reg  [5:0]  fill_y,
    output reg  [23:0] fill_rgb,
    output reg  [23:0] fill_rgb2,
    output wire [1:0]  fill_set,

    // ---------------- status -------------------------------------------------
    output wire        busy,
    output reg  [31:0] cnt_px,
    output reg  [31:0] cnt_blocks,
    output reg  [31:0] cnt_abort,
    output reg         done,

    // ---------------- performance taps (board diagnosis, read-only) ----------
    // One cycle each; they never influence the fill. The 2026-10-30 board run
    // needs the fill time split into its three possible waits:
    //   wait_beat : this row's beats are late (DDR return / read FIFO path)
    //   wait_row  : the planner has the next row but the row channel (mailbox /
    //               DDR request queue) will not take it
    //   wait_plan : the unpack has no row descriptor at all (planner has not
    //               produced one yet, typically because the row channel is busy)
    // The sum of these plus `fill_wr` (pixel actually written) accounts for the
    // S_FILL time; whatever remains is record/row handshake overhead.
    output wire        dbg_wait_beat,
    output wire        dbg_wait_row,
    output wire        dbg_wait_plan
);

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_BEGIN = 3'd1;     // owner fill_begin
    localparam [2:0] S_SET   = 3'd2;     // capture the chosen set, start planner
    localparam [2:0] S_FILL  = 3'd3;
    localparam [2:0] S_LAST  = 3'd4;     // last pixel written, complete the owner
    localparam [2:0] S_ABORT = 3'd5;

    reg [2:0]  state;
    reg [31:0] cur_base;
    reg [15:0] cur_tag;
    reg [10:0] cur_bx, cur_by;
    reg [6:0]  cur_bw, cur_bh;
    reg [1:0]  cur_set;
    reg        pl_start;

    assign busy = (state != S_IDLE);

    // ------------------------------------------------------------- planner
    wire        urow_valid, urow_ready;
    wire [4:0]  urow_head_skip;
    wire [7:0]  urow_valid_bytes;
    wire [4:0]  urow_beats;
    wire [5:0]  urow_local_y;
    wire        urow_set, urow_row_last, urow_tile_last;
    wire [15:0] urow_tag;
    wire        pl_busy, pl_done, pl_geom_bad;

    dgc_fetch_planner u_planner (
        .clk (clk), .rst_n (rst_n),
        .start (pl_start),
        .frame_base (cur_base), .job_id (job_id),
        .tile_tag (cur_tag), .cache_set (cur_set[0]),
        .bbox_x (cur_bx), .bbox_y (cur_by),
        .bbox_w (cur_bw), .bbox_h (cur_bh),
        .row_valid (row_valid), .row_ready (row_ready),
        .row_job_id (row_job_id), .row_tag (row_tag), .row_set (row_set),
        .row_addr (row_addr), .row_beats (row_beats),
        .row_head_skip (row_head_skip), .row_valid_bytes (row_valid_bytes),
        .row_local_y (row_local_y), .row_last (row_row_last),
        .urow_valid (urow_valid), .urow_ready (urow_ready),
        .urow_head_skip (urow_head_skip), .urow_valid_bytes (urow_valid_bytes),
        .urow_beats (urow_beats), .urow_local_y (urow_local_y),
        .urow_set (urow_set), .urow_tag (urow_tag),
        .urow_row_last (urow_row_last), .urow_tile_last (urow_tile_last),
        .busy (pl_busy), .done (pl_done), .geom_bad (pl_geom_bad)
    );

    // ------------------------------------------------- row descriptor queue
    // Small register queue: the planner may run ahead of unpack by a few rows.
    localparam integer QD = 4;
    reg [4:0]  q_hs [0:QD-1];
    reg [7:0]  q_vb [0:QD-1];
    reg [4:0]  q_beats [0:QD-1];
    reg [5:0]  q_ly [0:QD-1];
    reg        q_set [0:QD-1];
    reg [15:0] q_tag [0:QD-1];
    reg        q_rlast [0:QD-1];
    reg        q_tlast [0:QD-1];
    reg [1:0]  q_wp, q_rp;
    reg [2:0]  q_cnt;

    reg unpack_row_load;      // declared before the wire that reads it
    reg  row_pending;

    wire push_row = urow_valid & urow_ready;
    wire pop_row  = (q_cnt != 0) && unpack_row_load;
    assign urow_ready = (q_cnt < QD);

    wire [4:0]  r_hs = q_hs[q_rp];
    wire [7:0]  r_vb = q_vb[q_rp];
    wire [4:0]  r_beats = q_beats[q_rp];
    wire [5:0]  r_ly = q_ly[q_rp];
    wire        r_set = q_set[q_rp];
    wire [15:0] r_tag = q_tag[q_rp];
    wire        r_rlast = q_rlast[q_rp];
    wire        r_tlast = q_tlast[q_rp];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wp <= 2'd0; q_rp <= 2'd0; q_cnt <= 3'd0;
        end
        else begin
            if (push_row) begin
                q_hs[q_wp]    <= urow_head_skip;
                q_vb[q_wp]    <= urow_valid_bytes;
                q_beats[q_wp] <= urow_beats;
                q_ly[q_wp]    <= urow_local_y;
                q_set[q_wp]   <= urow_set;
                q_tag[q_wp]   <= urow_tag;
                q_rlast[q_wp] <= urow_row_last;
                q_tlast[q_wp] <= urow_tile_last;
                q_wp <= q_wp + 2'd1;
            end
            if (pop_row) q_rp <= q_rp + 2'd1;
            q_cnt <= q_cnt + (push_row ? 3'd1 : 3'd0) - (pop_row ? 3'd1 : 3'd0);
        end
    end

    // -------------------------------------------------------------- unpack
    wire        up_fill_valid, up_fill_ready;
    wire [1:0]  up_fill_count;
    wire [5:0]  up_fill_x, up_fill_y;
    wire [23:0] up_fill_rgb0, up_fill_rgb1;
    wire        up_fill_row_last, up_fill_tile_last;
    wire        up_row_done;

    dgc_unpack u_unpack (
        .clk (clk), .rst_n (rst_n),
        .row_load (unpack_row_load),
        .row_head_skip (r_hs), .row_valid_bytes (r_vb), .row_beats_total (r_beats),
        .row_local_y (r_ly), .row_set (r_set), .row_tile_tag (r_tag),
        .row_last (r_rlast), .row_tile_last (r_tlast),
        .beat_valid (beat_valid), .beat_ready (beat_ready), .beat_data (beat_data),
        .fill_valid (up_fill_valid), .fill_ready (up_fill_ready),
        .fill_set (), .fill_tile_tag (),
        .fill_x (up_fill_x), .fill_y (up_fill_y),
        .fill_count (up_fill_count),
        .fill_rgb0 (up_fill_rgb0), .fill_rgb1 (up_fill_rgb1),
        .fill_row_last (), .fill_tile_last (up_fill_tile_last),
        .row_done (up_row_done)
    );

    // A row is loaded from the queue when the previous row's beats have all been
    // consumed. Loading the next descriptor earlier would overwrite the unpack's
    // row context while its beats were still arriving.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unpack_row_load <= 1'b0;
            row_pending <= 1'b0;
        end
        else begin
            unpack_row_load <= 1'b0;
            if (state != S_FILL) begin
                row_pending <= 1'b0;
            end
            else if (!row_pending && (q_cnt != 0)) begin
                unpack_row_load <= 1'b1;
                row_pending <= 1'b1;
            end
            else if (row_pending && up_row_done) begin
                row_pending <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------- cache write port
    // One unpack record carries one or two adjacent pixels of the same source
    // row. The cache now has two write channels (even/odd x bank), so a
    // two-pixel record is written in a single cycle: channel 0 gets pixel x,
    // channel 1 gets x+1. The old version split it into two one-pixel cycles;
    // the 2026-10-30 board reading showed that split as the dominant fill cost.
    //
    // The write is registered: a record accepted in cycle T is written in T+1,
    // which is why the completion FSM waits one extra state (S_LAST) before it
    // reports the set READY.
    assign up_fill_ready = 1'b1;

    wire take_record = up_fill_valid & up_fill_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_wr  <= 1'b0;
            fill_wr2 <= 1'b0;
            fill_x   <= 6'd0; fill_y <= 6'd0;
            fill_rgb <= 24'd0; fill_rgb2 <= 24'd0;
            cnt_px   <= 32'd0;
        end
        else begin
            fill_wr  <= take_record;
            fill_wr2 <= take_record && (up_fill_count == 2'd2);
            if (take_record) begin
                fill_x    <= up_fill_x;
                fill_y    <= up_fill_y;
                fill_rgb  <= up_fill_rgb0;
                fill_rgb2 <= up_fill_rgb1;
                cnt_px    <= cnt_px + {30'd0, up_fill_count};
            end
        end
    end

    // ------------------------------------------------------------- main FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            owner_fill_begin <= 1'b0;
            owner_fill_complete <= 1'b0;
            owner_fill_abort <= 1'b0;
            pl_start <= 1'b0;
            cur_base <= 32'd0; cur_tag <= 16'd0;
            cur_bx <= 11'd0; cur_by <= 11'd0; cur_bw <= 7'd0; cur_bh <= 7'd0;
            cur_set <= 2'd0;
            cnt_blocks <= 32'd0; cnt_abort <= 32'd0;
            done <= 1'b0;
        end
        else begin
            owner_fill_begin   <= 1'b0;
            owner_fill_complete<= 1'b0;
            owner_fill_abort   <= 1'b0;
            pl_start <= 1'b0;
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start && owner_fill_ok) begin
                        cur_base <= frame_base;
                        cur_tag  <= tag;
                        cur_bx   <= bbox_x; cur_by <= bbox_y;
                        cur_bw   <= bbox_w; cur_bh <= bbox_h;
                        owner_fill_begin <= 1'b1;
                        state <= S_BEGIN;
                    end
                end
                S_BEGIN: begin
                    // `owner_fill_begin` was asserted at the previous edge; the
                    // owner registers fill_sel at *this* edge, so owner_fill_set
                    // is still the old value here. Capture it one cycle later in
                    // S_SET, otherwise the second and later fills write into the
                    // other set (the first one accidentally matched the reset
                    // value 0).
                    state <= S_SET;
                end
                S_SET: begin
                    cur_set  <= owner_fill_set;
                    pl_start <= 1'b1;
                    state    <= S_FILL;
                end
                S_FILL: begin
                    if (abort) begin
                        owner_fill_abort <= 1'b1;
                        cnt_abort <= cnt_abort + 32'd1;
                        state <= S_ABORT;
                    end
                    // The last record may carry one or two pixels, and either way
                    // both (or the single one) are written in the cycle after it is
                    // accepted, so there is only one completion case now.
                    else if (take_record && up_fill_tile_last) begin
                        state <= S_LAST;
                    end
                end
                S_LAST: begin
                    owner_fill_complete <= 1'b1;
                    cnt_blocks <= cnt_blocks + 32'd1;
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                S_ABORT: begin
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    assign fill_set = cur_set;

    // ------------------------------------------------------- performance taps
    // All three are observed in S_FILL only; S_BEGIN/S_SET/S_LAST are fixed
    // few-cycle setup costs and would only blur the attribution.
    //   wait_beat: a row is loaded in the unpack, the unpack can take a beat,
    //              and none is available.
    //   wait_row : the planner has a row ready but the DDR-side channel is not
    //              accepting it (mailbox round trip or ddr_fetch request queue).
    //   wait_plan: the unpack is idle with an empty descriptor queue, i.e. the
    //              planner has not yet produced the next row.
    assign dbg_wait_beat = (state == S_FILL) && row_pending &&
                           beat_ready && !beat_valid;
    assign dbg_wait_row  = (state == S_FILL) && row_valid && !row_ready;
    assign dbg_wait_plan = (state == S_FILL) && !row_pending && (q_cnt == 3'd0);

endmodule
