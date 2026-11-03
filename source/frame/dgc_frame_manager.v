//-----------------------------------------------------------------------------
// dgc_frame_manager.v
//
// Allocation, publication, locking and release of the four DDR source frame
// slots. Lives in the DDR clock domain.
//
// Frozen reference: 接口冻结规范_v1.md sections 4 and 5.
//
//   slot byte base : slot0..3 = 0x00000000..0x03000000, spaced 16 MiB
//   slot states    : FREE, WRITING, READY, HELD
//   allocation     : prefer FREE; otherwise reclaim an old READY that is not
//                    locked; never reclaim WRITING or HELD. If nothing can be
//                    granted the whole input frame is dropped and counted, the
//                    input must not wait.
//   only a finished frame may start processing.
//
// frame_desc, LSB first (128 bit):
//   frame_id32, base_bytes32, stride_bytes16, width12, height12,
//   slot2, format2, reserved20            and reserved MUST be zero.
//   format 0 is the BGR byte stream / RGB logical pixel layout of this spec.
//
// Selection rules (corrected 2026-10-21; the first version selected the OLDEST
// READY slot and its test asserted that, which contradicts the frozen text):
//
//   * acquire takes the NEWEST complete READY frame, compared by frame_id.
//     "处理启动时锁定最新完整 READY 帧". Release does not change capture order.
//   * release returns the frame to READY, not FREE. "释放后的最新帧可以回到
//     READY，直到被更新的完成帧替代或槽回收" - that is what lets the newest
//     frame be processed again when no newer one exists. A later capture
//     allocation may still reclaim it, because a READY slot is not locked.
//   * capture reclaim takes the OLDEST READY frame by frame_id, and never the
//     slot that the processing side acquires in the same cycle.
//   * `frame_written.good` gates publication: a frame whose last write beat was
//     not accepted, or whose size was wrong, must never become READY.
//
// Six pairwise order bits track capture allocation order. Release never changes
// that order; frame-id rollover does not affect it.
//-----------------------------------------------------------------------------

module dgc_frame_manager (
    input  wire         clk,
    input  wire         rst_n,

    // ---------------- capture side ------------------------------------------
    input  wire         alloc_req,      // a new input frame wants a slot
    output reg          alloc_grant,    // one-cycle pulse when granted
    output wire [127:0] frame_grant,
    output reg          alloc_drop,     // one-cycle pulse when nothing is free
    input  wire         write_done,     // capture_writer finished a whole frame
    input  wire [1:0]   done_slot,
    input  wire         done_good,      // frame_written.good: only 1 may publish

    // ---------------- processing side ---------------------------------------
    input  wire         acquire,        // processing wants a finished frame
    // Compatibility port: ordinary and forced requests now both accept repeats.
    input  wire         acquire_force,
    output reg          acquire_valid,
    output wire [127:0] frame_acquired,
    input  wire         rel,
    input  wire [1:0]   release_slot,

    // ---------------- geometry for the descriptor ---------------------------
    input  wire [11:0]  cfg_width,
    input  wire [11:0]  cfg_height,
    input  wire [15:0]  cfg_stride,

    // ---------------- status -------------------------------------------------
    output wire [7:0]   slot_state,     // {st3, st2, st1, st0}, 2 bits each (4 slots)
    output reg  [31:0]  cnt_alloc,
    output reg  [31:0]  cnt_drop,
    output reg  [31:0]  cnt_done,
    // Newest READY frame id (combinational status).
    output wire [31:0]  ready_fid,

    output reg  [31:0]  cnt_acquire,
    output reg  [31:0]  cnt_release
);

    localparam [1:0] ST_FREE    = 2'd0;
    localparam [1:0] ST_WRITING = 2'd1;
    localparam [1:0] ST_READY   = 2'd2;
    localparam [1:0] ST_HELD    = 2'd3;

    localparam [1:0] FORMAT_BGR = 2'd0;

    // Four frame slots, 64 MiB total; descriptor layout unchanged (spec section 10.7).
    localparam integer NSLOT = 4;

    reg [1:0]  st  [0:NSLOT-1];
    reg [31:0] fid [0:NSLOT-1];        // frame_id held by each slot

    reg [31:0] next_fid;
    reg [31:0] g_fid;
    reg [1:0]  g_slot;
    reg [1:0]  grant_slot;
    reg [1:0]  acq_slot;
    reg [31:0] acq_fid;

    integer i, newest_i, reclaim_i, free_i;

    // A newly allocated frame is newer than every existing slot. Cache those
    // six pairwise relations at allocation instead of cascading 32-bit subtract,
    // compare and selected-fid muxes through acquire and reclaim on every cycle.
    // No extra handshake cycle: order and fid change on the same allocation edge.
    wire [NSLOT-1:0] newer_than [0:NSLOT-1];
    wire [NSLOT-1:0] ready_mask, newest_mask, reclaim_mask, oldest_mask;
    wire can_grant;
    genvar oi, oj;
    generate
        for (oi = 0; oi < NSLOT; oi = oi + 1) begin : gen_order
            assign newer_than[oi][oi] = 1'b0;
            assign ready_mask[oi] = (st[oi] == ST_READY);
            assign newest_mask[oi] = ready_mask[oi] &&
                (&(newer_than[oi] | ~ready_mask | (4'b0001 << oi)));
            assign oldest_mask[oi] = reclaim_mask[oi] &&
                !(|(newer_than[oi] & reclaim_mask));
            for (oj = oi + 1; oj < NSLOT; oj = oj + 1) begin : gen_pair
                reg newer;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) newer <= 1'b0;
                    else if (alloc_req && can_grant) begin
                        if (grant_slot == oi) newer <= 1'b1;
                        else if (grant_slot == oj) newer <= 1'b0;
                    end
                end
                assign newer_than[oi][oj] = newer;
                assign newer_than[oj][oi] = ~newer;
            end
        end
    endgenerate

    assign slot_state = {st[3], st[2], st[1], st[0]};

    // ------------------------------------------------------------------ status
    wire any_free = (st[0] == ST_FREE) | (st[1] == ST_FREE) |
                    (st[2] == ST_FREE) | (st[3] == ST_FREE);
    wire any_rdy  = (st[0] == ST_READY) | (st[1] == ST_READY) |
                    (st[2] == ST_READY) | (st[3] == ST_READY);

    // ------------------------------------------------- newest READY by frame id
    // A released frame keeps its capture id; publication/release time is irrelevant.
    reg        best_v;
    reg [1:0]  best_slot;
    always @(*) begin
        best_v    = 1'b0;
        best_slot = 2'd0;
        for (newest_i = 0; newest_i < NSLOT; newest_i = newest_i + 1) begin
            if (newest_mask[newest_i]) begin
                best_v    = 1'b1;
                best_slot = newest_i[1:0];
            end
        end
    end
    wire [1:0]  newest_slot = best_slot;
    wire [31:0] newest_fid  = best_v ? fid[best_slot] : 32'd0;
    assign ready_fid = newest_fid;

    // Repeat the newest complete frame when no newer capture is available.
    // Capture reclamation must preserve newer frames; refusing repeat requests
    // instead caused missing output jobs. These last-acquire taps are debug only.
    reg [31:0] last_acq_fid;
    reg        last_acq_valid;
    wire newest_is_last = last_acq_valid && any_rdy && (newest_fid == last_acq_fid);

    // The slot the processing side locks in this cycle must not be handed to the
    // capture side as well: that would start overwriting a frame that is already
    // being read, and the two owners would disagree about it for a whole frame.
    // 2026-11-03: the stale refusal no longer blocks. acquire_force is kept in the
    // port list (the FSM still sets it at frame boundaries) but is now redundant.
    wire        acq_now = acquire && any_rdy;
    assign reclaim_mask = ready_mask & ~(newest_mask & {NSLOT{acq_now}});

    // ------------------------------------------------- oldest READY by frame id
    // Only READY slots are reclaimable, and never the one being acquired in this
    // cycle. An 8-bit cycle age saturated in 2.04 us at 125 MHz, so all slots
    // tied and capture repeatedly reclaimed a new frame before it was acquired.
    reg        rec_v;
    reg [1:0]  rec_slot;
    always @(*) begin
        rec_v    = 1'b0;
        rec_slot = 2'd0;
        for (reclaim_i = 0; reclaim_i < NSLOT; reclaim_i = reclaim_i + 1) begin
            if (oldest_mask[reclaim_i]) begin
                rec_v    = 1'b1;
                rec_slot = reclaim_i[1:0];
            end
        end
    end
    wire       any_reclaim = rec_v;
    wire [1:0] reclaim_slot = rec_slot;

    // Prefer a FREE slot (lowest index), then the oldest READY one.
    reg [1:0] free_sel;
    reg       free_v;
    always @(*) begin
        free_v   = 1'b0;
        free_sel = 2'd0;
        for (free_i = NSLOT - 1; free_i >= 0; free_i = free_i - 1) begin
            if (st[free_i] == ST_FREE) begin
                free_v   = 1'b1;
                free_sel = free_i[1:0];
            end
        end
    end

    always @(*) begin
        if (free_v)            grant_slot = free_sel;
        else if (any_reclaim)  grant_slot = reclaim_slot;
        else                   grant_slot = 2'd0;
    end

    assign can_grant = free_v | any_reclaim;

    // ------------------------------------------------------------- descriptors
    function [31:0] slot_base(input [1:0] s);
        begin
            slot_base = {6'd0, s, 24'd0};      // s * 0x01000000
        end
    endfunction

    function [127:0] make_desc(input [31:0] fid, input [1:0] s,
                               input [15:0] stride, input [11:0] w, input [11:0] h);
        begin
            make_desc = { 20'd0,            // [127:108] reserved, must be zero
                          FORMAT_BGR,       // [107:106] format
                          s,                // [105:104] slot
                          h,                // [103:92]  height
                          w,                // [91:80]   width
                          stride,           // [79:64]   stride_bytes
                          slot_base(s),     // [63:32]   base_bytes
                          fid };            // [31:0]    frame_id
        end
    endfunction

    assign frame_grant    = make_desc(g_fid, g_slot, cfg_stride, cfg_width, cfg_height);
    assign frame_acquired = make_desc(acq_fid, acq_slot, cfg_stride, cfg_width, cfg_height);

    // ------------------------------------------------------------------- state
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NSLOT; i = i + 1) begin
                st[i]  <= ST_FREE;
                fid[i] <= 32'd0;
            end
            next_fid   <= 32'd1;
            g_fid      <= 32'd0;
            g_slot     <= 2'd0;
            alloc_grant <= 1'b0;
            alloc_drop  <= 1'b0;
            acquire_valid <= 1'b0;
            acq_slot <= 2'd0;
            acq_fid  <= 32'd0;
            cnt_alloc <= 32'd0; cnt_drop <= 32'd0; cnt_done <= 32'd0;
            cnt_acquire <= 32'd0; cnt_release <= 32'd0;
            last_acq_fid <= 32'd0; last_acq_valid <= 1'b0;
        end
        else begin
            alloc_grant   <= 1'b0;
            alloc_drop    <= 1'b0;
            acquire_valid <= 1'b0;

            // ------------------------------------------------- allocation
            if (alloc_req) begin
                if (can_grant) begin
                    alloc_grant <= 1'b1;
                    cnt_alloc   <= cnt_alloc + 32'd1;
                    g_fid       <= next_fid;
                    g_slot      <= grant_slot;
                    next_fid    <= next_fid + 32'd1;
                    case (grant_slot)
                        2'd0: begin st[0] <= ST_WRITING; fid[0] <= next_fid; end
                        2'd1: begin st[1] <= ST_WRITING; fid[1] <= next_fid; end
                        2'd2: begin st[2] <= ST_WRITING; fid[2] <= next_fid; end
                        default: begin st[3] <= ST_WRITING; fid[3] <= next_fid; end
                    endcase
                end
                else begin
                    // the input must not wait: the whole frame is dropped
                    alloc_drop <= 1'b1;
                    cnt_drop   <= cnt_drop + 32'd1;
                end
            end

            // ------------------------------------------------- write finished
            // good = 0 is never published; the slot is simply free again.
            if (write_done) begin
                cnt_done <= cnt_done + 32'd1;
                if (done_good) begin
                    case (done_slot)
                        2'd0: st[0] <= ST_READY;
                        2'd1: st[1] <= ST_READY;
                        2'd2: st[2] <= ST_READY;
                        default: st[3] <= ST_READY;
                    endcase
                end
                else begin
                    case (done_slot)
                        2'd0: st[0] <= ST_FREE;
                        2'd1: st[1] <= ST_FREE;
                        2'd2: st[2] <= ST_FREE;
                        default: st[3] <= ST_FREE;
                    endcase
                end
            end

            // ------------------------------------------------- processing takes one
            if (acq_now) begin
                acquire_valid <= 1'b1;
                acq_slot <= newest_slot;
                cnt_acquire <= cnt_acquire + 32'd1;
                last_acq_fid <= newest_fid;
                last_acq_valid <= 1'b1;
                case (newest_slot)
                    2'd0: begin st[0] <= ST_HELD; acq_fid <= fid[0]; end
                    2'd1: begin st[1] <= ST_HELD; acq_fid <= fid[1]; end
                    2'd2: begin st[2] <= ST_HELD; acq_fid <= fid[2]; end
                    default: begin st[3] <= ST_HELD; acq_fid <= fid[3]; end
                endcase
            end

            // ------------------------------------------------- release
            // Back to READY so the newest frame can be processed again (spec: a
            // released newest frame stays available; the acquire side ranks by
            // frame_id, so this does not make it look newer).
            //
            // Release does not refresh or artificially age a captured frame.
            if (rel) begin
                cnt_release <= cnt_release + 32'd1;
                case (release_slot)
                    2'd0: if (st[0] == ST_HELD) st[0] <= ST_READY;
                    2'd1: if (st[1] == ST_HELD) st[1] <= ST_READY;
                    2'd2: if (st[2] == ST_HELD) st[2] <= ST_READY;
                    default: if (st[3] == ST_HELD) st[3] <= ST_READY;
                endcase
            end
        end
    end

endmodule
