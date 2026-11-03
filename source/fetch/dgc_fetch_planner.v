//-----------------------------------------------------------------------------
// dgc_fetch_planner.v
//
// Expands one block's source bbox into the frozen `fetch_row` channel: one
// descriptor per source row, in row order, with the 32-byte alignment, head
// skip, valid byte count and beat count of that row.
//
// Frozen reference: 接口冻结规范_v1.md sections 4 and 7.
//
//   start        = frame_base + sy*stride_bytes + 3*bbox_x
//   aligned_addr = floor(start/32)*32
//   head_skip    = start - aligned_addr            (0..31)
//   valid_bytes  = 3*bbox_width
//   beats_total  = ceil((head_skip + valid_bytes)/32), bounded 1..7 for a
//                  block at most 64 wide
//   local_y      = 0 .. bbox_h-1, row_last on the last row
//
// The descriptor is delivered on two ports that must both accept it:
//   * `row_*` goes to the DDR domain (through a mailbox) and drives the read;
//   * `urow_*` stays in the processing domain and tells `dgc_unpack` how to
//     interpret the beats when they come back.
// Keeping one payload and two ready inputs is what guarantees the unpack
// descriptor and the DDR request can never get out of step.
//
// `cache_set` and `tile_tag` are carried unchanged so the fill side knows where
// the pixels belong. `tile_last` marks the last row of the block, which is what
// completes a cache set.
//-----------------------------------------------------------------------------

module dgc_fetch_planner #(
    parameter integer STRIDE_BYTES = 5760
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,           // pulse: begin this block
    input  wire [31:0] frame_base,
    input  wire [31:0] job_id,
    input  wire [15:0] tile_tag,
    input  wire        cache_set,
    input  wire [10:0] bbox_x, bbox_y,
    input  wire [6:0]  bbox_w, bbox_h,

    // ---------------- DDR-domain row channel ---------------------------------
    output wire        row_valid,
    input  wire        row_ready,
    output wire [31:0] row_job_id,
    output wire [15:0] row_tag,
    output wire        row_set,
    output wire [31:0] row_addr,        // 32-byte aligned byte address
    output wire [4:0]  row_beats,
    output wire [4:0]  row_head_skip,
    output wire [7:0]  row_valid_bytes,
    output wire [5:0]  row_local_y,
    output wire        row_last,

    // ---------------- unpack descriptor (processing domain) -------------------
    output wire        urow_valid,
    input  wire        urow_ready,
    output wire [4:0]  urow_head_skip,
    output wire [7:0]  urow_valid_bytes,
    output wire [4:0]  urow_beats,
    output wire [5:0]  urow_local_y,
    output wire        urow_set,
    output wire [15:0] urow_tag,
    output wire        urow_row_last,
    output wire        urow_tile_last,

    // ---------------- status -------------------------------------------------
    output wire        busy,
    output wire        done,
    output wire        geom_bad      // sticky: a row exceeded the 1..7 beat bound
);

    // ------------------------------------------------------------- row walk
    wire        walk_valid, walk_ready;
    wire [5:0]  walk_local_y;
    wire        walk_row_last;
    wire        walk_done;
    wire [6:0]  walk_rows;

    wire [31:0] r_start_byte, r_aligned_addr;
    wire [4:0]  r_head_skip;
    wire [7:0]  r_valid_bytes;
    wire [4:0]  r_beats;
    wire        r_row_last;
    wire        r_geom_ok;

    wire both_ready = row_ready & urow_ready;

    dgc_fetch_walk u_walk (
        .clk(clk), .rst_n(rst_n),
        .start(start), .bbox_h(bbox_h),
        .row_valid(walk_valid), .row_ready(walk_ready),
        .local_y(walk_local_y), .row_last(walk_row_last),
        .done(walk_done), .rows_done(walk_rows),
        .abort(1'b0)
    );
    assign walk_ready = both_ready;

    dgc_fetch_row_plan #(.STRIDE_BYTES(STRIDE_BYTES)) u_plan (
        .frame_base(frame_base),
        .bbox_x(bbox_x), .bbox_y(bbox_y),
        .bbox_w(bbox_w), .bbox_h(bbox_h),
        .local_y(walk_local_y),
        .start_byte(r_start_byte),
        .aligned_addr(r_aligned_addr),
        .head_skip(r_head_skip),
        .valid_bytes(r_valid_bytes),
        .beats_total(r_beats),
        .row_last(r_row_last),
        .geom_ok(r_geom_ok)
    );

    // Both sinks must accept the same descriptor in the same cycle. Each valid is
    // qualified by the OTHER side's ready, so a sink whose own ready is high can
    // never consume a row that the other side has not taken - without this the
    // DDR request and the unpack descriptor could drift apart by one row (the
    // fill integration immediately showed the symptom: one row repeated forever).
    assign row_valid  = walk_valid & urow_ready;
    assign urow_valid = walk_valid & row_ready;

    assign row_job_id = job_id;
    assign row_tag = tile_tag;
    assign row_set = cache_set;
    assign row_addr = r_aligned_addr;
    assign row_beats = r_beats;
    assign row_head_skip = r_head_skip;
    assign row_valid_bytes = r_valid_bytes;
    assign row_local_y = walk_local_y;
    assign row_last = r_row_last;

    assign urow_head_skip = r_head_skip;
    assign urow_valid_bytes = r_valid_bytes;
    assign urow_beats = r_beats;
    assign urow_local_y = walk_local_y;
    assign urow_set = cache_set;
    assign urow_tag = tile_tag;
    assign urow_row_last = r_row_last;
    assign urow_tile_last = r_row_last;      // the last row closes the block

    reg busy_r;
    reg geom_bad_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_r <= 1'b0;
            geom_bad_r <= 1'b0;
        end
        else begin
            if (start) begin
                busy_r <= 1'b1;
                geom_bad_r <= 1'b0;
            end
            else if (walk_done) begin
                busy_r <= 1'b0;
            end
            if (walk_valid && walk_ready && !r_geom_ok) geom_bad_r <= 1'b1;
        end
    end

    assign busy = busy_r;
    assign done = walk_done;
    assign geom_bad = geom_bad_r;

endmodule
