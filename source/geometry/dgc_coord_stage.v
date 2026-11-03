//-----------------------------------------------------------------------------
// dgc_coord_stage.v
//
// The coordinate half of the processing pipeline: it turns candidate output
// blocks into the frozen 96-bit coordinate stream plus a block descriptor.
//
// Frozen reference: 接口冻结规范_v1.md section 6.
//
// For one candidate block this module
//   1. reserves width*height coordinate-FIFO entries and one descriptor slot
//      BEFORE mapping starts (reservation is a condition to start, not a reaction
//      to almost_full);
//   2. walks the block in raster order, y outer / x inner, one coordinate per
//      cycle, with tile_last on the final coordinate;
//   3. maps every point through dgc_map_pipeline;
//   4. accumulates the exact source bbox of the block from every active record
//      (dgc_bbox_acc);
//   5. writes the records to the coordinate FIFO and, when the last one has been
//      accepted, commits a descriptor and reports back to the tile scheduler.
//
// Descriptor kind
//   0 ACCEPT : bbox fits 64x64, the fetch/sampler path must load and sample it
//   1 SPLIT  : bbox wider or taller than 64; the scheduler re-issues the halves.
//              The parent's records stay in the FIFO and the consumer drops
//              exactly record_count of them - the frozen protocol forbids
//              removing FIFO tail entries, so they are consumed and discarded.
//   2 BLACK  : no active point at all; no DDR request may be issued.
//
// The descriptor is packed as separate ports whose widths are the frozen ones in
// 接口常量_v1.json (`unpacked_channels_payload_widths.tile_descriptor`).
//-----------------------------------------------------------------------------

module dgc_coord_stage #(
    parameter integer DESC_DEPTH = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    // Job-boundary flush: clears only the map pipeline (in-flight coordinates
    // from the previous job). The configuration snapshot and the block FSM are
    // deliberately NOT reset: resetting the whole stage lost the config and
    // froze it (s4_core blocks=0), so only the map's valid pipeline is cleared.
    input  wire        flush,

    input  wire [31:0] job_id,

    // ---------------- active configuration ----------------------------------
    input  wire [1:0]  cfg_mode,
    input  wire signed [31:0] cfg_m00, cfg_m01, cfg_m02,
    input  wire signed [31:0] cfg_m10, cfg_m11, cfg_m12,
    input  wire signed [31:0] cfg_fx, cfg_fy, cfg_cx, cfg_cy,
    input  wire signed [31:0] cfg_k1, cfg_k2,
    input  wire [31:0] cfg_norm_abs_max,

    // ---------------- candidate block from the tile scheduler ---------------
    input  wire        blk_valid,
    output wire        blk_ready,
    input  wire [15:0] blk_tag,
    input  wire [6:0]  blk_stripe,
    input  wire [10:0] blk_x0, blk_y0,
    input  wire [6:0]  blk_w, blk_h,

    output reg         rpt_valid,        // one report per accepted candidate
    output reg         split_valid,

    // ---------------- coordinate FIFO ---------------------------------------
    output wire        cf_valid,
    input  wire        cf_ready,
    output wire [95:0] cf_data,
    input  wire [12:0] fifo_free,        // entries available in the FIFO

    // ---------------- block descriptor queue --------------------------------
    output wire        desc_valid,
    input  wire        desc_ready,
    output wire [31:0] d_job_id,
    output wire [15:0] d_tag,
    output wire [6:0]  d_stripe,
    output wire [10:0] d_out_x, d_out_y,
    output wire [5:0]  d_out_w,
    output wire [4:0]  d_out_h,
    output wire [9:0]  d_rec_count,
    output wire [10:0] d_bbox_x, d_bbox_y,
    output wire [6:0]  d_bbox_w, d_bbox_h,
    output wire [1:0]  d_kind,
    output wire        d_math_error,

    // ---------------- status -------------------------------------------------
    output reg  [15:0] cnt_accept,
    output reg  [15:0] cnt_black,
    output reg  [15:0] cnt_split_done,
    output wire        busy
);

    localparam [1:0] K_ACCEPT = 2'd0;
    localparam [1:0] K_SPLIT  = 2'd1;
    localparam [1:0] K_BLACK  = 2'd2;

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_GEN  = 2'd1;
    localparam [1:0] S_WAIT = 2'd2;

    localparam integer AW = 2;

    // ------------------------------------------------------------- state
    reg  [1:0]  state;
    reg  [10:0] gen_x, gen_y;
    reg  [6:0]  gen_col;
    reg  [9:0]  gen_idx;
    reg  [9:0]  gen_total;
    reg  [10:0] cur_x0, cur_y0;
    reg  [6:0]  cur_w, cur_h, cur_stripe;
    reg  [15:0] cur_tag;
    reg         bbox_rst;

    wire [11:0] blk_pixels = {5'd0, blk_w} * {5'd0, blk_h};   // <= 512
    wire        gen_last = (gen_idx == gen_total - 10'd1);

    // ------------------------------------------------------------- mapper nets
    wire        map_in_ready;
    wire        map_out_valid, map_out_ready;
    wire [95:0] map_out_coord;

    // ------------------------------------------------------------- bbox nets
    wire [10:0] bbox_x, bbox_y;
    wire [6:0]  bbox_w, bbox_h;
    wire [9:0]  rec_count;
    wire        any_ok, block_merr, acc_done;

    // --------------------------------------------------------- descriptor queue
    reg [31:0] q_job  [0:DESC_DEPTH-1];
    reg [15:0] q_tag  [0:DESC_DEPTH-1];
    reg [6:0]  q_strp [0:DESC_DEPTH-1];
    reg [10:0] q_ox   [0:DESC_DEPTH-1];
    reg [10:0] q_oy   [0:DESC_DEPTH-1];
    reg [5:0]  q_ow   [0:DESC_DEPTH-1];
    reg [4:0]  q_oh   [0:DESC_DEPTH-1];
    reg [9:0]  q_rc   [0:DESC_DEPTH-1];
    reg [10:0] q_bx   [0:DESC_DEPTH-1];
    reg [10:0] q_by   [0:DESC_DEPTH-1];
    reg [6:0]  q_bw   [0:DESC_DEPTH-1];
    reg [6:0]  q_bh   [0:DESC_DEPTH-1];
    reg [1:0]  q_kind [0:DESC_DEPTH-1];
    reg        q_merr [0:DESC_DEPTH-1];

    reg [AW-1:0] q_wp, q_rp;
    reg [3:0]    desc_count;

    wire pop        = desc_ready & (desc_count != 0);
    wire desc_space = (desc_count != DESC_DEPTH);
    wire start_ok   = desc_space & (fifo_free >= {1'b0, blk_pixels});

    assign blk_ready = (state == S_IDLE) & start_ok;

    // ------------------------------------------------------------- mapper
    dgc_map_pipeline u_map (
        .clk(clk), .rst_n(rst_n),
        .cfg_mode(cfg_mode),
        .cfg_m00(cfg_m00), .cfg_m01(cfg_m01), .cfg_m02(cfg_m02),
        .cfg_m10(cfg_m10), .cfg_m11(cfg_m11), .cfg_m12(cfg_m12),
        .cfg_fx(cfg_fx), .cfg_fy(cfg_fy), .cfg_cx(cfg_cx), .cfg_cy(cfg_cy),
        .cfg_k1(cfg_k1), .cfg_k2(cfg_k2),
        .cfg_norm_abs_max(cfg_norm_abs_max),
        .in_valid(state == S_GEN), .in_ready(map_in_ready),
        .in_dst_x(gen_x), .in_dst_y(gen_y),
        .in_tile_tag(cur_tag), .in_tile_last(gen_last),
        .out_valid(map_out_valid), .out_ready(map_out_ready),
        .out_coord(map_out_coord)
    );

    // ------------------------------------------------------------- bbox
    dgc_bbox_acc u_bbox (
        .clk(clk), .rst_n(rst_n),
        .blk_start(bbox_rst),
        .in_valid(map_out_valid), .in_ready(map_out_ready),
        .in_coord(map_out_coord),
        .out_valid(cf_valid), .out_ready(cf_ready),
        .out_coord(cf_data),
        .done(acc_done),
        .bbox_x(bbox_x), .bbox_y(bbox_y), .bbox_w(bbox_w), .bbox_h(bbox_h),
        .rec_count(rec_count), .any_ok(any_ok), .block_math_error(block_merr)
    );

    // ------------------------------------------------- descriptor payload regs
    reg         push_req;
    reg [31:0]  p_job;
    reg [15:0]  p_tag;
    reg [6:0]   p_stripe;
    reg [10:0]  p_ox, p_oy;
    reg [5:0]   p_ow;
    reg [4:0]   p_oh;
    reg [9:0]   p_rc;
    reg [10:0]  p_bx, p_by;
    reg [6:0]   p_bw, p_bh;
    reg [1:0]   p_kind;
    reg         p_merr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            gen_x <= 11'd0; gen_y <= 11'd0; gen_col <= 7'd0; gen_idx <= 10'd0;
            gen_total <= 10'd0;
            cur_x0 <= 11'd0; cur_y0 <= 11'd0;
            cur_w <= 7'd0; cur_h <= 7'd0; cur_stripe <= 7'd0; cur_tag <= 16'd0;
            bbox_rst <= 1'b0;
            rpt_valid <= 1'b0; split_valid <= 1'b0;
            cnt_accept <= 16'd0; cnt_black <= 16'd0; cnt_split_done <= 16'd0;
            push_req <= 1'b0;
            p_job <= 32'd0; p_tag <= 16'd0; p_stripe <= 7'd0;
            p_ox <= 11'd0; p_oy <= 11'd0; p_ow <= 6'd0; p_oh <= 5'd0;
            p_rc <= 10'd0; p_bx <= 11'd0; p_by <= 11'd0; p_bw <= 7'd0; p_bh <= 7'd0;
            p_kind <= 2'd0; p_merr <= 1'b0;
        end
        else begin
            rpt_valid <= 1'b0;
            split_valid <= 1'b0;
            bbox_rst <= 1'b0;
            push_req <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (blk_valid && blk_ready) begin
                        cur_x0 <= blk_x0; cur_y0 <= blk_y0;
                        cur_w  <= blk_w;  cur_h  <= blk_h;
                        cur_stripe <= blk_stripe; cur_tag <= blk_tag;
                        gen_x <= blk_x0; gen_y <= blk_y0;
                        gen_col <= 7'd0; gen_idx <= 10'd0;
                        gen_total <= blk_pixels[9:0];
                        bbox_rst <= 1'b1;
                        state <= S_GEN;
                    end
                end
                S_GEN: begin
                    if (map_in_ready) begin
                        if (gen_last) state <= S_WAIT;
                        if (gen_col == cur_w - 7'd1) begin
                            gen_col <= 7'd0;
                            gen_x   <= cur_x0;
                            gen_y   <= gen_y + 11'd1;
                        end
                        else begin
                            gen_col <= gen_col + 7'd1;
                            gen_x   <= gen_x + 11'd1;
                        end
                        gen_idx <= gen_idx + 10'd1;
                    end
                end
                S_WAIT: begin
                    if (acc_done) begin
                        // payload is latched here and written to the queue on the
                        // next cycle, so the queue block only ever sees stable data
                        p_job <= job_id; p_tag <= cur_tag; p_stripe <= cur_stripe;
                        p_ox <= cur_x0; p_oy <= cur_y0;
                        p_ow <= cur_w[5:0]; p_oh <= cur_h[4:0];
                        p_rc <= rec_count;
                        p_bx <= bbox_x; p_by <= bbox_y; p_bw <= bbox_w; p_bh <= bbox_h;
                        p_merr <= block_merr;
                        push_req <= 1'b1;
                        rpt_valid <= 1'b1;
                        if (!any_ok) begin
                            p_kind <= K_BLACK;
                            cnt_black <= cnt_black + 16'd1;
                        end
                        else if ((bbox_w > 7'd64) || (bbox_h > 7'd64)) begin
                            p_kind <= K_SPLIT;
                            cnt_split_done <= cnt_split_done + 16'd1;
                            split_valid <= 1'b1;
                        end
                        else begin
                            p_kind <= K_ACCEPT;
                            cnt_accept <= cnt_accept + 16'd1;
                        end
                        state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------- queue bookkeeping
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wp <= {AW{1'b0}}; q_rp <= {AW{1'b0}}; desc_count <= 4'd0;
        end
        else begin
            if (push_req) begin
                q_job [q_wp] <= p_job;
                q_tag [q_wp] <= p_tag;
                q_strp[q_wp] <= p_stripe;
                q_ox  [q_wp] <= p_ox;
                q_oy  [q_wp] <= p_oy;
                q_ow  [q_wp] <= p_ow;
                q_oh  [q_wp] <= p_oh;
                q_rc  [q_wp] <= p_rc;
                q_bx  [q_wp] <= p_bx;
                q_by  [q_wp] <= p_by;
                q_bw  [q_wp] <= p_bw;
                q_bh  [q_wp] <= p_bh;
                q_kind[q_wp] <= p_kind;
                q_merr[q_wp] <= p_merr;
                q_wp <= q_wp + 1'b1;
            end
            if (pop) q_rp <= q_rp + 1'b1;

            case ({push_req, pop})
                2'b10:   desc_count <= desc_count + 4'd1;
                2'b01:   desc_count <= desc_count - 4'd1;
                default: ;
            endcase
        end
    end

    assign desc_valid  = (desc_count != 0);
    assign d_job_id    = q_job [q_rp];
    assign d_tag       = q_tag [q_rp];
    assign d_stripe    = q_strp[q_rp];
    assign d_out_x     = q_ox  [q_rp];
    assign d_out_y     = q_oy  [q_rp];
    assign d_out_w     = q_ow  [q_rp];
    assign d_out_h     = q_oh  [q_rp];
    assign d_rec_count = q_rc  [q_rp];
    assign d_bbox_x    = q_bx  [q_rp];
    assign d_bbox_y    = q_by  [q_rp];
    assign d_bbox_w    = q_bw  [q_rp];
    assign d_bbox_h    = q_bh  [q_rp];
    assign d_kind      = q_kind[q_rp];
    assign d_math_error= q_merr[q_rp];

    assign busy = (state != S_IDLE);

endmodule


