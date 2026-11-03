//-----------------------------------------------------------------------------
// tb_coord_stage.v - scheduler-driven block -> coordinate records + descriptor
//
// The coordinate stage is the first real integration of four pieces: the tile
// scheduler handshake, the coordinate generator, dgc_map_pipeline and the bbox
// accumulator, with the real 96x2048 coordinate FIFO attached.
//
//   C1  identity block 32x16: 512 records in raster order, ACCEPT, exact bbox
//   C2  last-stripe block 32x8 at (1888,1072): 256 records, ACCEPT
//   C3  a scaled mapping makes the bbox wider than 64: kind SPLIT, records still
//       written (the consumer drops them) and the scheduler receives the split
//   C4  a mapping that leaves the image: kind BLACK, sample_ok = 0 on every
//       record, coordinate fields forced to zero
//   C5  reservation: the stage refuses a block while the FIFO cannot hold it
//   C6  descriptor queue backpressure: four un-consumed descriptors block a start
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_coord_stage;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    // ------------------------------------------------------------- config
    reg  [1:0]  cfg_mode = 0;
    reg  signed [31:0] cfg_m00 = 32'sd67108864, cfg_m01 = 0, cfg_m02 = 0;
    reg  signed [31:0] cfg_m10 = 0, cfg_m11 = 32'sd67108864, cfg_m12 = 0;
    reg  signed [31:0] cfg_fx = 32'sd137377855, cfg_fy = 32'sd138692973;
    reg  signed [31:0] cfg_cx = 32'sd64030536,  cfg_cy = 32'sd34085643;
    reg  signed [31:0] cfg_k1 = -32'sd129279204, cfg_k2 = 32'sd74679738;
    reg  [31:0] cfg_norm = 32'h08000000;

    // ------------------------------------------------------------- block in
    reg         blk_valid = 0;
    wire        blk_ready;
    reg  [15:0] blk_tag = 0;
    reg  [6:0]  blk_stripe = 0;
    reg  [10:0] blk_x0 = 0, blk_y0 = 0;
    reg  [6:0]  blk_w = 32, blk_h = 16;

    wire        rpt_valid, split_valid;

    // ------------------------------------------------------------- FIFO
    wire        cf_valid;
    wire        cf_ready = 1'b1;      // the consumer drains at full rate here
    wire [95:0] cf_data;

    wire        fifo_full, fifo_empty;
    wire [12:0] fifo_wl, fifo_rl;
    wire        fifo_rd_valid;
    wire [95:0] fifo_rd_data;
    wire        fifo_rd_ready = 1'b1;
    wire        fifo_rd_fire;

    wire [12:0] fifo_free = 13'd2048 - fifo_wl;

    dgc_coord_fifo u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(cf_valid), .wr_ready(cf_ready), .wr_data(cf_data),
        .rd_fire(fifo_rd_fire), .rd_ready(fifo_rd_ready),
        .rd_valid(fifo_rd_valid), .rd_ready_o(1'b1), .rd_data(fifo_rd_data), .flush(1'b0),
        .full(fifo_full), .empty(fifo_empty),
        .wr_level(fifo_wl), .rd_level(fifo_rl)
    );
    assign fifo_rd_fire = ~fifo_empty & fifo_rd_ready;

    reg rpt_split = 1'b0;
    always @(posedge clk) if (rst_n && rpt_valid) rpt_split <= split_valid;

    integer wr_cnt = 0;
    always @(posedge clk) if (rst_n && cf_valid && cf_ready) wr_cnt = wr_cnt + 1;

    // ------------------------------------------------------------- descriptors
    wire        desc_valid;
    reg         desc_ready = 1;
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
    wire [15:0] cnt_accept, cnt_black, cnt_split_done;
    wire        busy;

    dgc_coord_stage u_dut (
        .clk(clk), .rst_n(rst_n), .flush(1'b0), .job_id(32'h1234_5678),
        .cfg_mode(cfg_mode),
        .cfg_m00(cfg_m00), .cfg_m01(cfg_m01), .cfg_m02(cfg_m02),
        .cfg_m10(cfg_m10), .cfg_m11(cfg_m11), .cfg_m12(cfg_m12),
        .cfg_fx(cfg_fx), .cfg_fy(cfg_fy), .cfg_cx(cfg_cx), .cfg_cy(cfg_cy),
        .cfg_k1(cfg_k1), .cfg_k2(cfg_k2), .cfg_norm_abs_max(cfg_norm),
        .blk_valid(blk_valid), .blk_ready(blk_ready),
        .blk_tag(blk_tag), .blk_stripe(blk_stripe),
        .blk_x0(blk_x0), .blk_y0(blk_y0), .blk_w(blk_w), .blk_h(blk_h),
        .rpt_valid(rpt_valid), .split_valid(split_valid),
        .cf_valid(cf_valid), .cf_ready(cf_ready), .cf_data(cf_data),
        .fifo_free(fifo_free),
        .desc_valid(desc_valid), .desc_ready(desc_ready),
        .d_job_id(d_job_id), .d_tag(d_tag), .d_stripe(d_stripe),
        .d_out_x(d_out_x), .d_out_y(d_out_y), .d_out_w(d_out_w), .d_out_h(d_out_h),
        .d_rec_count(d_rec_count),
        .d_bbox_x(d_bbox_x), .d_bbox_y(d_bbox_y),
        .d_bbox_w(d_bbox_w), .d_bbox_h(d_bbox_h),
        .d_kind(d_kind), .d_math_error(d_math_error),
        .cnt_accept(cnt_accept), .cnt_black(cnt_black),
        .cnt_split_done(cnt_split_done), .busy(busy)
    );

    // ------------------------------------------------------------- scoreboard
    localparam integer QN = 4096;
    reg [95:0] exp_q [0:QN-1];
    reg        chk_q [0:QN-1];
    integer q_wp = 0, q_rp = 0;

    always @(posedge clk) begin
        if (rst_n && fifo_rd_valid) begin   // out_ready is tied high
            if (q_rp >= q_wp) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 10)
                    $display("TEST_FAIL: unrequested coordinate record t=%0t", $time);
            end
            else begin
                if (chk_q[q_rp] && (fifo_rd_data !== exp_q[q_rp])) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 10)
                        $display("TEST_FAIL: coord %0d exp=%024h act=%024h t=%0t",
                                 q_rp, exp_q[q_rp], fifo_rd_data, $time);
                end
                q_rp = q_rp + 1;
            end
        end
    end

    // build the expected records for an identity block
    task expect_identity(input [10:0] x0, y0, input [6:0] w, h,
                         input [15:0] tag, input black);
        integer i, xx, yy;
        reg [95:0] r;
        begin
            for (i = 0; i < w * h; i = i + 1) begin
                xx = x0 + (i % w);
                yy = y0 + (i / w);
                r = 96'd0;
                r[10:0]  = xx[10:0];
                r[21:11] = yy[10:0];
                if (!black) begin
                    r[32:22] = xx[10:0];
                    r[43:33] = yy[10:0];
                end
                r[91:76] = tag;
                r[92]    = !black;
                r[94]    = (i == w * h - 1);
                exp_q[q_wp] = r;
                chk_q[q_wp] = 1'b1;
                q_wp = q_wp + 1;
            end
        end
    endtask

    // occupy the scoreboard for a block whose mapped values are not checked here
    // (the distortion arithmetic itself is checked bit-exactly by s1_map_pipeline)
    task skip_expect(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                exp_q[q_wp] = 96'd0;
                chk_q[q_wp] = 1'b0;
                q_wp = q_wp + 1;
            end
        end
    endtask

    task start_block(input [10:0] x0, y0, input [6:0] w, h,
                     input [6:0] stripe, input [15:0] tag);
        begin
            blk_x0 = x0; blk_y0 = y0; blk_w = w; blk_h = h;
            blk_stripe = stripe; blk_tag = tag;
            blk_valid <= 1'b1;
            // blk_ready is combinational from the current cycle's state, so it is
            // sampled mid-cycle: waiting on it right after a posedge would sample
            // the state the accept has already moved away from, and the driver
            // would hold valid for an extra block.
            @(negedge clk);
            while (!blk_ready) @(negedge clk);
            @(posedge clk); #0.2;
            blk_valid <= 1'b0;
        end
    endtask

    task wait_rpt;
        integer guard;
        begin
            guard = 0;
            while (!rpt_valid && guard < 5000) begin
                @(posedge clk); #0.2;
                guard = guard + 1;
            end
            if (!rpt_valid) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: no scheduler report");
            end
            @(posedge clk); #0.2;
        end
    endtask

    task check_desc(input [1:0] kind, input [10:0] ex, ey, ebx, eby,
                    input [6:0] ebw, ebh, input [9:0] erc);
        begin
            if (!desc_valid) begin
                dgc_errors = dgc_errors + 1; $display("TEST_FAIL: no descriptor"); end
            else begin
                if (d_kind !== kind) begin dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: kind exp=%0d act=%0d", kind, d_kind); end
                if (d_out_x !== ex || d_out_y !== ey) begin dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: out origin exp=(%0d,%0d) act=(%0d,%0d)",
                             ex, ey, d_out_x, d_out_y); end
                if (d_bbox_x !== ebx || d_bbox_y !== eby ||
                    d_bbox_w !== ebw || d_bbox_h !== ebh) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: bbox exp=(%0d,%0d,%0d,%0d) act=(%0d,%0d,%0d,%0d)",
                             ebx, eby, ebw, ebh, d_bbox_x, d_bbox_y, d_bbox_w, d_bbox_h);
                end
                if (d_rec_count !== erc) begin dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: rec_count exp=%0d act=%0d", erc, d_rec_count); end
                @(posedge clk); #0.2;
            end
        end
    endtask

    integer i;

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);
        $display("DBG after reset: free=%0d wl=%0d ready=%b state=%0d desc_count=%0d",
                 fifo_free, fifo_wl, blk_ready, u_dut.state, u_dut.desc_count);

        // =============================================================== C1
        cfg_mode = 0;
        expect_identity(11'd0, 11'd0, 7'd32, 7'd16, 16'h0001, 1'b0);
        start_block(11'd0, 11'd0, 7'd32, 7'd16, 7'd0, 16'h0001);
        wait_rpt;
        if (rpt_split) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C1 identity block must not request a split"); end
        check_desc(2'd0, 11'd0, 11'd0, 11'd0, 11'd0, 7'd33, 7'd17, 10'd512);
        repeat (20) @(posedge clk);
        if (q_rp != 512) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C1 %0d of 512 records arrived (writes=%0d fifo_level=%0d)", q_rp, wr_cnt, u_fifo.level); end
        else $display("TEST_INFO: C1 32x16 identity block: 512 records, ACCEPT, bbox 33x17 (includes the neighbour)");

        // =============================================================== C2
        expect_identity(11'd1888, 11'd1072, 7'd32, 7'd8, 16'h0002, 1'b0);
        start_block(11'd1888, 11'd1072, 7'd32, 7'd8, 7'd67, 16'h0002);
        wait_rpt;
        check_desc(2'd0, 11'd1888, 11'd1072, 11'd1888, 11'd1072, 7'd32, 7'd8, 10'd256);
        repeat (20) @(posedge clk);
        if (q_rp != 768) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C2 %0d of 768 records arrived", q_rp); end
        else $display("TEST_INFO: C2 last-stripe block 32x8: 256 records, ACCEPT");

        // =============================================================== C3
        // Zoom the inverse mapping out by 3x around the optical centre, in the
        // normalised coordinate space the matrix actually lives in:
        //   M00 = 3/fx, M02 = -3*cx/fx  (and the same in y)
        // A 32x16 output block at the centre then covers ~96x48 source pixels,
        // so the bbox is wider than 64 and the candidate must be split.
        cfg_mode = 2;
        cfg_m00 = 32'sd96042; cfg_m11 = 32'sd95133;
        cfg_m02 = -32'sd93836445; cfg_m12 = -32'sd49478688;
        skip_expect(32*16);   // mapped values are checked by s1_map_pipeline
        start_block(11'd928, 11'd520, 7'd32, 7'd16, 7'd32, 16'h0003);
        wait_rpt;
        if (!rpt_split) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C3 a >64 bbox must request a split (bbox %0dx%0d)",
                     d_bbox_w, d_bbox_h); end
        else $display("TEST_INFO: C3 zoomed-out 32x16 block requested SPLIT, bbox %0dx%0d",
                      d_bbox_w, d_bbox_h);
        if (desc_valid && d_kind !== 2'd1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C3 descriptor kind exp=1 act=%0d", d_kind); end
        if (desc_valid && (d_bbox_w <= 7'd64) && (d_bbox_h <= 7'd64)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C3 split requested without a >64 bbox"); end
        if (desc_valid) @(posedge clk); #0.2;
        repeat (40) @(posedge clk);
        if (q_rp != 768 + 512) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C3 %0d of 1280 records arrived", q_rp); end

        // =============================================================== C4
        // translate the normalised mapping by +1.0 so every source coordinate
        // lands to the right of the image: sx ~ 2650 > 1919 for every point
        cfg_mode = 2;
        cfg_m00 = 32'sd32014; cfg_m11 = 32'sd31711;
        cfg_m02 = 32'sd67108864;   // +1.0
        cfg_m12 = 32'sd67108864;
        skip_expect(32*16);   // every point is invalid here; contents are all zero
        start_block(11'd0, 11'd0, 7'd32, 7'd16, 7'd0, 16'h0004);
        wait_rpt;
        check_desc(2'd2, 11'd0, 11'd0, 11'd0, 11'd0, 7'd0, 7'd0, 10'd512);
        repeat (40) @(posedge clk);
        if (q_rp != 1280 + 512) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C4 %0d of 1792 records arrived", q_rp); end
        else $display("TEST_INFO: C4 fully out-of-image block: BLACK, sample_ok=0, fields zero");

        // =============================================================== C5/C6
        // Restore identity. With the descriptor consumer frozen, four blocks fill
        // the descriptor queue; the fifth start must then be refused (C6). Once
        // the queue is drained it must accept again (C5).
        cfg_mode = 0;
        cfg_m02 = 0; cfg_m12 = 0;
        desc_ready = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            expect_identity(11'd0, 11'd0, 7'd32, 7'd16, 16'h0100 + i[15:0], 1'b0);
            start_block(11'd0, 11'd0, 7'd32, 7'd16, 7'd0, 16'h0100 + i[15:0]);
            wait_rpt;
        end
        repeat (8) @(posedge clk);
        blk_x0 = 11'd0; blk_y0 = 11'd0; blk_w = 7'd32; blk_h = 7'd16;
        blk_stripe = 7'd0; blk_tag = 16'h0104;
        blk_valid <= 1'b1;
        @(negedge clk);
        if (blk_ready) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C6 start accepted with a full descriptor queue");
        end
        else $display("TEST_INFO: C6 a full descriptor queue blocks a new block");
        blk_valid <= 1'b0;

        // drain the four queued descriptors, then the same start must succeed
        desc_ready = 1'b1;
        repeat (8) @(posedge clk);
        expect_identity(11'd0, 11'd0, 7'd32, 7'd16, 16'h0104, 1'b0);
        start_block(11'd0, 11'd0, 7'd32, 7'd16, 7'd0, 16'h0104);
        wait_rpt;
        desc_ready = 1'b1;
        repeat (60) @(posedge clk);
        if (q_rp != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: %0d records expected, %0d arrived", q_wp, q_rp);
        end
        else $display("TEST_INFO: C5 the stage accepted the start again after the queue drained");

        $display("TEST_INFO: descriptors accept=%0d black=%0d split=%0d",
                 cnt_accept, cnt_black, cnt_split_done);
        `DGC_FINISH
    end
endmodule



