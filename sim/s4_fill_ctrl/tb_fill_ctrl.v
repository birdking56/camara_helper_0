//-----------------------------------------------------------------------------
// tb_fill_ctrl.v - ACCEPT block -> source cache fill
//
// Integrates the real fill controller with the real planner, the real unpack,
// the real cache owner and the real four-bank source cache. The only model is
// the DDR row source: it receives the fetch_row descriptors and returns the
// 32-byte beats that the DDR read FIFO would deliver, built from a synthetic
// image and the frozen BGR byte layout.
//
//   F1  a 16x4 block at the frame origin: 64 pixels, owner READY with the tag
//   F2  a 33x17 block at (64,32): 561 pixels, rows with 99 valid bytes
//   F3  two consecutive fills use the two cache sets (A/B ownership)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_fill_ctrl;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    `DGC_GRS_INST

    localparam integer STRIDE = 5760;

    // ------------------------------------------------------------- job / block
    reg         start = 0;
    reg  [31:0] frame_base = 32'h0000_0000;
    reg  [31:0] job_id = 32'h00B0_0001;
    reg  [15:0] tag = 0;
    reg  [10:0] bbox_x = 0, bbox_y = 0;
    reg  [6:0]  bbox_w = 0, bbox_h = 0;
    reg         abort = 0;

    // owner
    wire        fill_begin, fill_ok, fill_complete, fill_abort;
    wire [1:0]  fill_set;
    wire        set0_ready, set1_ready;
    wire [15:0] set0_tag, set1_tag;
    wire [1:0]  set0_state, set1_state;

    // row channel to the DDR side
    wire        row_valid, row_ready;
    wire [31:0] row_addr;
    wire [4:0]  row_beats, row_head_skip;
    wire [7:0]  row_valid_bytes;
    wire [5:0]  row_local_y;
    wire        row_row_last, row_set;
    wire [15:0] row_tag;
    wire [31:0] row_job_id;

    // beats back from the DDR side
    wire        beat_valid;
    wire        beat_ready;
    wire [255:0] beat_data;

    // cache write port (two channels: pixel x and x+1 of a two-pixel record)
    wire        fill_wr, fill_wr2;
    wire [5:0]  fill_x, fill_y;
    wire [23:0] fill_rgb, fill_rgb2;

    wire [1:0]  fill_set_w;
    wire busy, done;
    wire [31:0] cnt_px, cnt_blocks, cnt_abort;

    dgc_fill_ctrl u_dut (
        .clk (clk), .rst_n (rst_n),
        .start (start), .frame_base (frame_base), .job_id (job_id),
        .tag (tag), .bbox_x (bbox_x), .bbox_y (bbox_y),
        .bbox_w (bbox_w), .bbox_h (bbox_h), .abort (abort),
        .owner_fill_begin (fill_begin), .owner_fill_ok (fill_ok),
        .owner_fill_set (fill_set), .owner_fill_complete (fill_complete),
        .owner_fill_abort (fill_abort),
        .row_valid (row_valid), .row_ready (row_ready),
        .row_addr (row_addr), .row_beats (row_beats),
        .row_head_skip (row_head_skip), .row_valid_bytes (row_valid_bytes),
        .row_local_y (row_local_y), .row_row_last (row_row_last),
        .row_set (row_set), .row_tag (row_tag), .row_job_id (row_job_id),
        .beat_valid (beat_valid), .beat_ready (beat_ready), .beat_data (beat_data),
        .fill_wr (fill_wr), .fill_wr2 (fill_wr2), .fill_x (fill_x), .fill_y (fill_y),
        .fill_rgb (fill_rgb), .fill_rgb2 (fill_rgb2),
        .fill_set (fill_set_w),
        .busy (busy), .cnt_px (cnt_px), .cnt_blocks (cnt_blocks),
        .cnt_abort (cnt_abort), .done (done)
    );

    dgc_cache_owner u_owner (
        .clk (clk), .rst_n (rst_n),
        .fill_begin (fill_begin), .fill_tag (tag),
        .fill_complete (fill_complete), .fill_abort (fill_abort),
        .sample_begin (1'b0), .rel (1'b0),
        .fill_set (fill_set),
        .set0_ready (set0_ready), .set1_ready (set1_ready),
        .set0_tag (set0_tag), .set1_tag (set1_tag),
        .set0_state (set0_state), .set1_state (set1_state),
        .fill_ok (fill_ok),
        .cnt_fill (), .cnt_sample (), .cnt_release ()
    );

    // ------------------------------------------------------------- source cache
    wire        cache_wr_ready;
    wire        p0_valid, p1_valid, p2_valid, p3_valid;
    wire [23:0] p0_d, p1_d, p2_d, p3_d;

    dgc_source_cache4 u_cache (
        .clk (clk), .rst_n (rst_n),
        .wr_valid (fill_wr), .wr_ready (cache_wr_ready),
        .wr_set (fill_set_w),
        .wr_x (fill_x), .wr_y (fill_y), .wr_rgb (fill_rgb),
        .wr2_valid (fill_wr2), .wr2_rgb (fill_rgb2),
        .rd_set (1'b0),
        .p0_fire (1'b0), .p0_x (6'd0), .p0_y (6'd0),
        .p1_fire (1'b0), .p1_x (6'd0), .p1_y (6'd0),
        .p2_fire (1'b0), .p2_x (6'd0), .p2_y (6'd0),
        .p3_fire (1'b0), .p3_x (6'd0), .p3_y (6'd0),
        .p0_valid (p0_valid), .p0_d (p0_d),
        .p1_valid (p1_valid), .p1_d (p1_d),
        .p2_valid (p2_valid), .p2_d (p2_d),
        .p3_valid (p3_valid), .p3_d (p3_d)
    );

    // ------------------------------------------------------------- image model
    function [23:0] img(input [10:0] x, input [10:0] y);
        begin
            img = {x[7:0], y[7:0], x[7:0] ^ y[7:0]};
        end
    endfunction

    // byte c of the BGR memory layout for pixel p
    function [7:0] mem_byte(input [23:0] p, input [1:0] c);
        begin
            mem_byte = (c == 2'd0) ? p[7:0] :
                       (c == 2'd1) ? p[15:8] : p[23:16];
        end
    endfunction

    // ------------------------------------------------------------- row source
    // Queues the fetch_row descriptors and returns the beats for each row.
    reg [31:0] rq_addr [0:7];
    reg [4:0]  rq_beats [0:7];
    reg [4:0]  rq_skip [0:7];
    reg [7:0]  rq_vbytes [0:7];
    reg [5:0]  rq_ly [0:7];
    reg        rq_last [0:7], rq_tlast [0:7];
    reg [2:0]  rq_wp, rq_rp, rq_cnt;

    reg  [31:0] cur_addr;
    reg  [4:0]  cur_beats, cur_skip;
    reg  [7:0]  cur_vbytes;
    reg  [5:0]  cur_ly;
    reg  [5:0]  beat_idx;
    reg         cur_last, cur_tlast;
    reg         src_active;

    assign row_ready = (rq_cnt < 3'd7);

    wire [63:0] bb;   // beat byte index helper

    // build one 256-bit beat from the image
    function [255:0] make_beat(input [31:0] base_addr, input [4:0] k,
                               input [4:0] skip, input [7:0] vbytes,
                               input [5:0] ly, input [10:0] bx0, input [10:0] by0);
        integer j;
        reg [31:0] a, s;
        reg [31:0] d;
        reg [10:0] px, py;
        reg [23:0] pv;
        reg [1:0]  c;
        begin
            make_beat = 256'd0;
            s = base_addr + {27'd0, skip};
            for (j = 0; j < 32; j = j + 1) begin
                a = base_addr + k * 32 + j;
                if ((a >= s) && (a < (s + vbytes))) begin
                    d  = a - s;
                    px = bx0 + d / 3;
                    py = by0 + ly;
                    pv = img(px, py);
                    c  = d % 3;
                    make_beat[j*8 +: 8] = mem_byte(pv, c);
                end
                else make_beat[j*8 +: 8] = 8'hAA;
            end
        end
    endfunction

    // descriptor handshake
    wire ds_push = row_valid & row_ready;
    wire ds_pop  = !src_active && (rq_cnt != 0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq_wp <= 0; rq_rp <= 0; rq_cnt <= 0; src_active <= 0;
            cur_addr <= 0; cur_beats <= 0; cur_skip <= 0; cur_vbytes <= 0;
            cur_ly <= 0; beat_idx <= 0; cur_last <= 0; cur_tlast <= 0;
        end
        else begin
            if (ds_push) begin
                rq_addr[rq_wp]   <= row_addr;
                rq_beats[rq_wp]  <= row_beats;
                rq_skip[rq_wp]   <= row_head_skip;
                rq_vbytes[rq_wp] <= row_valid_bytes;
                rq_ly[rq_wp]     <= row_local_y;
                rq_last[rq_wp]   <= row_row_last;
                rq_tlast[rq_wp]  <= row_row_last;
                rq_wp <= rq_wp + 3'd1;
            end

            if (ds_pop) begin
                src_active <= 1'b1;
                cur_addr   <= rq_addr[rq_rp];
                cur_beats  <= rq_beats[rq_rp];
                cur_skip   <= rq_skip[rq_rp];
                cur_vbytes <= rq_vbytes[rq_rp];
                cur_ly     <= rq_ly[rq_rp];
                cur_last   <= rq_last[rq_rp];
                cur_tlast  <= rq_tlast[rq_rp];
                beat_idx   <= 6'd0;
                rq_rp      <= rq_rp + 3'd1;
            end
            else if (src_active && beat_valid && beat_ready) begin
                if (beat_idx + 6'd1 == {1'b0, cur_beats}) begin
                    src_active <= 1'b0;
                    beat_idx   <= 6'd0;
                end
                else beat_idx <= beat_idx + 6'd1;
            end

            // exactly one update, so a simultaneous push and pop keep the count
            rq_cnt <= rq_cnt + (ds_push ? 3'd1 : 3'd0) - (ds_pop ? 3'd1 : 3'd0);
        end
    end

    assign beat_valid = src_active;
    assign beat_data  = make_beat(cur_addr, beat_idx[4:0], cur_skip,
                                  cur_vbytes, cur_ly, bbox_x, bbox_y);

    // ------------------------------------------------------------- write checker
    // Two write channels: fill_wr is pixel x, fill_wr2 is pixel x+1 of the same
    // record, both written in the same cycle. Every written pixel is checked
    // against the image model at its own coordinate, and n_px counts pixels
    // (not cycles), so a dropped second pixel cannot hide.
    integer n_px = 0;
    always @(posedge clk) begin
        if (rst_n && fill_wr) begin
            n_px = n_px + 1 + (fill_wr2 ? 1 : 0);
            if (fill_x >= bbox_w || fill_y >= bbox_h) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: write outside the block (%0d,%0d) w=%0d h=%0d",
                         fill_x, fill_y, bbox_w, bbox_h);
            end
            else if (fill_rgb !== img(bbox_x + fill_x, bbox_y + fill_y)) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 12)
                    $display("TEST_FAIL: pixel (%0d,%0d) exp=%06h act=%06h",
                             fill_x, fill_y,
                             img(bbox_x + fill_x, bbox_y + fill_y), fill_rgb);
            end
            if (fill_wr2) begin
                if ((fill_x + 6'd1) >= bbox_w) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: second pixel outside the row (%0d,%0d) w=%0d",
                             fill_x, fill_y, bbox_w);
                end
                else if (fill_rgb2 !== img(bbox_x + fill_x + 6'd1, bbox_y + fill_y)) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 12)
                        $display("TEST_FAIL: pixel2 (%0d,%0d) exp=%06h act=%06h",
                                 fill_x + 6'd1, fill_y,
                                 img(bbox_x + fill_x + 6'd1, bbox_y + fill_y), fill_rgb2);
                end
            end
        end
    end

    // ------------------------------------------------------------- test flow
    integer n_done = 0;
    always @(posedge clk) if (rst_n && done) n_done = n_done + 1;

    task fill_block(input [10:0] bx, by, input [6:0] w, h, input [15:0] tg);
        integer guard;
        begin
            tag = tg; bbox_x = bx; bbox_y = by; bbox_w = w; bbox_h = h;
            start <= 1'b1;
            @(posedge clk); #0.2;
            start <= 1'b0;
            guard = 0;
            while (!done && guard < 20000) begin
                @(posedge clk); #0.2;
                guard = guard + 1;
            end
            if (!done) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: block (%0d,%0d) %0dx%0d never completed", bx, by, w, h); end
            repeat (4) @(posedge clk);
        end
    endtask

    integer i;

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // =============================================================== F1
        fill_block(11'd0, 11'd0, 7'd16, 7'd4, 16'h1001);
        if (n_px != 64) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F1 wrote %0d pixels, expected 64", n_px); end
        if (!set0_ready || set0_tag !== 16'h1001) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F1 owner state: set0_ready=%b set0_tag=%04h state=%0d",
                     set0_ready, set0_tag, set0_state);
        end
        else $display("TEST_INFO: F1 16x4 block: 64 pixels exact, set0 READY tag 1001");

        // =============================================================== F2
        fill_block(11'd64, 11'd32, 7'd33, 7'd17, 16'h1002);
        if (n_px != 64 + 561) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F2 wrote %0d pixels, expected 625", n_px); end
        if (!set1_ready || set1_tag !== 16'h1002) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F2 owner state: set1_ready=%b set1_tag=%04h state=%0d",
                     set1_ready, set1_tag, set1_state);
        end
        else $display("TEST_INFO: F2 33x17 block at (64,32): 561 pixels exact, set1 READY");

        // =============================================================== F3
        if (cnt_blocks != 2 || n_done != 2) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: F3 cnt_blocks=%0d done=%0d", cnt_blocks, n_done); end
        else $display("TEST_INFO: F3 two fills used both cache sets, counters consistent");
        if (cnt_px != 625) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: cnt_px=%0d expected 625", cnt_px); end

        $display("TEST_INFO: pixels=%0d blocks=%0d", cnt_px, cnt_blocks);
        `DGC_FINISH
    end
endmodule
