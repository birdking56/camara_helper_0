//-----------------------------------------------------------------------------
// tb_dgc_core.v - end-to-end processing chain, identity mapping
//
// The whole processing path runs on the real geometry: the tile scheduler emits
// all 4080 blocks, dgc_coord_stage maps them, dgc_fill_ctrl fills the source
// cache from the DDR row model, the sampler reads four neighbours, gamma is
// bypassed, bilinear interpolates and the stripe writer fills the stripe RAM.
//
// Identity mapping (mode 0) is used so the expected image is exactly the source
// image: output(x,y) == img(x,y) with zero fractional weights. Every pixel of
// the first three stripes (3 x 30720 = 92160 pixels) is read back out of the
// stripe RAM and compared, and the stripe_offer payloads are checked.
//
// The DDR side is a behavioural row source: it accepts fetch_row descriptors and
// returns the 32-byte beats built from the synthetic image in the frozen BGR
// layout. The native read/write adapters and the mailboxes are verified in their
// own suites.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_dgc_core;
    integer dgc_errors = 0;
`ifdef DGC_BOARD_RATE_TEST
    reg clk = 0; always #2.921 clk = ~clk; // board: 171.174 MHz
`else
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
`endif
    reg rst_n = 0;
    `DGC_GRS_INST

    localparam integer STRIDE = 5760;
`ifdef DGC_RADIAL_TEST
`ifdef DGC_BOARD_RATE_TEST
    localparam integer NSTRIPE = 4;
`else
    localparam integer NSTRIPE = 68;
`endif
    reg [23:0] radial_expected [0:2073599];
    reg [2047:0] expected_path;
`else
    localparam integer NSTRIPE = 3;
`endif

    // ------------------------------------------------------------- job
    reg         job_start = 0;
    reg  [31:0] job_id = 32'h00C0_0001;
    reg  [31:0] frame_base = 32'h0000_0000;

    // ------------------------------------------------------------- config
    reg  [1:0]  cfg_mode = 2'd0;
    reg  signed [31:0] cfg_m00 = 32'sd67108864, cfg_m01 = 0, cfg_m02 = 0;
    reg  signed [31:0] cfg_m10 = 0, cfg_m11 = 32'sd67108864, cfg_m12 = 0;
    reg  signed [31:0] cfg_fx = 32'sd137377855, cfg_fy = 32'sd138692973;
    reg  signed [31:0] cfg_cx = 32'sd64030536,  cfg_cy = 32'sd34085643;
    reg  signed [31:0] cfg_k1 = -32'sd129279204, cfg_k2 = 32'sd74679738;
    reg  [31:0] cfg_norm = 32'h08000000;
    reg  [1:0]  gamma_mode = 2'd0;

    // ------------------------------------------------------------- row channel
    wire        row_valid, row_ready;
    wire [31:0] row_addr;
    wire [4:0]  row_beats, row_head_skip;
    wire [7:0]  row_valid_bytes;
    wire [5:0]  row_local_y;
    wire        row_row_last, row_set;
    wire [15:0] row_tag;
    wire [31:0] row_job_id;

    wire        src_fire;              // a source beat is accepted by the read FIFO
    wire        fifo_wr_en, fifo_wr_full, fifo_pop, fifo_empty;
    wire [255:0] fifo_rd_data;
    wire        beat_valid, beat_ready;
    wire [255:0] beat_data;
    wire [255:0] fifo_wr_data;

    // ------------------------------------------------------------- stripe side
    reg  [14:0] ram0_rd_addr = 0, ram1_rd_addr = 0, ram2_rd_addr = 0, ram3_rd_addr = 0;
    wire [23:0] ram0_rd_data, ram1_rd_data, ram2_rd_data, ram3_rd_data;
    wire        offer_valid;
    reg         offer_ack = 0;
    reg  [63:0] offer_cap;
    wire        offer_ready = offer_ack;
    wire [63:0] offer_data;
    reg         rel = 0;
    reg  [1:0]  release_bank = 2'd0;
    reg         release_status_bad = 0;

    wire        frame_done, busy;
    wire [15:0] cnt_accept, cnt_black, cnt_split;
    wire [31:0] cnt_pixels, cnt_blocks_done;

    dgc_core u_dut (
        .clk (clk), .rst_n (rst_n),
        .job_start (job_start), .job_abort (1'b0), .job_id (job_id), .frame_base (frame_base),
        .cfg_mode (cfg_mode),
        .cfg_m00 (cfg_m00), .cfg_m01 (cfg_m01), .cfg_m02 (cfg_m02),
        .cfg_m10 (cfg_m10), .cfg_m11 (cfg_m11), .cfg_m12 (cfg_m12),
        .cfg_fx (cfg_fx), .cfg_fy (cfg_fy), .cfg_cx (cfg_cx), .cfg_cy (cfg_cy),
        .cfg_k1 (cfg_k1), .cfg_k2 (cfg_k2),
        .cfg_norm_abs_max (cfg_norm),
        .gamma_mode (gamma_mode),
        .row_valid (row_valid), .row_ready (row_ready),
        .row_addr (row_addr), .row_beats (row_beats),
        .row_head_skip (row_head_skip), .row_valid_bytes (row_valid_bytes),
        .row_local_y (row_local_y), .row_row_last (row_row_last),
        .row_set (row_set), .row_tag (row_tag), .row_job_id (row_job_id),
        .beat_valid (beat_valid), .beat_ready (beat_ready), .beat_data (beat_data),
        .ram_rd_clk (clk), .ram_rd_rst_n (rst_n),
        .ram0_rd_addr (ram0_rd_addr), .ram0_rd_data (ram0_rd_data),
        .ram1_rd_addr (ram1_rd_addr), .ram1_rd_data (ram1_rd_data),
        .ram2_rd_addr (ram2_rd_addr), .ram2_rd_data (ram2_rd_data),
        .ram3_rd_addr (ram3_rd_addr), .ram3_rd_data (ram3_rd_data),
        .offer_valid (offer_valid), .offer_ready (offer_ready), .offer_data (offer_data),
        .rel (rel), .release_bank (release_bank),
        .release_status_bad (release_status_bad),
        .frame_done (frame_done), .busy (busy),
        .cnt_accept (cnt_accept), .cnt_black (cnt_black), .cnt_split (cnt_split),
        .cnt_pixels (cnt_pixels), .cnt_blocks_done (cnt_blocks_done)
    );

    // 2026-10-30 diagnostic (test only): board data showed ~6.9 us/block, which
    // is exactly fill(~3.9) + sample(~3.0), i.e. the prefetch looked serialized.
    // This probe measures, per block, how many cycles are spent with fill and
    // sample active and how many overlap.
    //
    // 2026-11-02 (b): a block still costs ~617 cycles for 512 pixels, i.e. ~90
    // cycles of bubble per block = 2.5 ms per 4080-block frame, which is what
    // pushes the job past one display frame on the board. These extra counters
    // split that bubble: cstate residency, writer backpressure (px_valid &
    // !px_ready), sampler starvation (in C_SAMPLE without samp_out_valid) and
    // coordinate pops. Whichever dominates is the thing to overlap next.
    integer blk_prev = 0, blk_cyc = 0, blk_fill = 0, blk_samp = 0, blk_both = 0;
    integer blk_drain = 0, blk_wrstall = 0, blk_smpstarve = 0, blk_pops = 0;
    integer b_drain = 0, b_wrstall = 0, b_smpstarve = 0, b_pops = 0, b_cyc = 0;
    integer b_fill = 0, b_samp = 0, b_both = 0;
    always @(posedge clk) if (rst_n) begin
        blk_cyc = blk_cyc + 1;
        if (u_dut.fill_busy) blk_fill = blk_fill + 1;
        if (u_dut.samp_busy) blk_samp = blk_samp + 1;
        if (u_dut.fill_busy && u_dut.samp_busy) blk_both = blk_both + 1;
        if (u_dut.cstate == 3'd3) blk_drain = blk_drain + 1;
        if (u_dut.px_valid && !u_dut.px_ready) blk_wrstall = blk_wrstall + 1;
        if (u_dut.cstate == 3'd2 && u_dut.cur_accept && !u_dut.samp_out_valid)
            blk_smpstarve = blk_smpstarve + 1;
        if (u_dut.cstate == 3'd2 && u_dut.fifo_rd_fire && u_dut.fifo_rd_accept)
            blk_pops = blk_pops + 1;
        if (cnt_blocks_done != blk_prev) begin
            if (blk_prev < 12 || blk_prev > 150) begin
                $display("BLK %0d cycles=%0d fill=%0d samp=%0d both=%0d drain=%0d wrstall=%0d smpstarve=%0d pops=%0d",
                         blk_prev, blk_cyc, blk_fill, blk_samp, blk_both,
                         blk_drain, blk_wrstall, blk_smpstarve, blk_pops);
                if (blk_prev > 150) begin
                    b_cyc = b_cyc + blk_cyc;   b_fill = b_fill + blk_fill;
                    b_samp = b_samp + blk_samp; b_both = b_both + blk_both;
                    b_drain = b_drain + blk_drain; b_wrstall = b_wrstall + blk_wrstall;
                    b_smpstarve = b_smpstarve + blk_smpstarve; b_pops = b_pops + blk_pops;
                    $display("BLKSUM n=%0d cyc=%0d fill=%0d samp=%0d both=%0d drain=%0d wrstall=%0d smpstarve=%0d pops=%0d",
                             1, b_cyc, b_fill, b_samp, b_both, b_drain, b_wrstall, b_smpstarve, b_pops);
                end
            end
            blk_prev = cnt_blocks_done; blk_cyc = 0; blk_fill = 0; blk_samp = 0; blk_both = 0;
            blk_drain = 0; blk_wrstall = 0; blk_smpstarve = 0; blk_pops = 0;
        end
    end

    // 2026-11-02 (f): C_DRAIN now exits on the pixel-in-flight counter instead of
    // the `pix_seen >= recs_total` level test. The two must agree exactly: the
    // moment the counter says the gamma/bilinear pipe is empty, every record of
    // the block must already have reached the stripe writer. A mismatch means the
    // counter is lying and the next block would be switched in with pixels of the
    // old one still inside - the failure mode that is invisible in the image until
    // a block boundary lands in the wrong place.
    always @(posedge clk) if (rst_n && u_dut.cstate == 3'd3) begin
        if ((u_dut.inflight_px == 10'd0) &&
            (u_dut.pix_seen < {22'd0, u_dut.recs_total})) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: DRAIN pixel pipe empty but pix_seen=%0d/%0d t=%0t",
                     u_dut.pix_seen, u_dut.recs_total, $time);
        end
    end

    // A set must have committed its last pipelined RAM write before sampling
    // begins. Check the ownership handoff, not just the eventual pixel values.
    always @(posedge clk) if (rst_n && u_dut.sample_begin) begin
        if (u_dut.samp_set[0] ? (|u_dut.u_cache.u_set1.we) : (|u_dut.u_cache.u_set0.we)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: sample_begin while the set still has a pending RAM write");
        end
    end

    // ------------------------------------------------------------- image model
    function [23:0] img(input [10:0] x, input [10:0] y);
        begin
            img = {x[7:0], y[7:0], x[7:0] ^ y[7:0]};
        end
    endfunction

    function [7:0] mem_byte(input [23:0] p, input [1:0] c);
        begin
            mem_byte = (c == 2'd0) ? p[7:0] :
                       (c == 2'd1) ? p[15:8] : p[23:16];
        end
    endfunction

    // ------------------------------------------------------------- row source
    reg [31:0] rq_addr  [0:15];
    reg [4:0]  rq_beats [0:15];
    reg [4:0]  rq_skip  [0:15];
    reg [7:0]  rq_vb    [0:15];
    reg [5:0]  rq_ly    [0:15];
    reg [2:0]  rq_wp = 0, rq_rp = 0, rq_cnt = 0;

    reg  [31:0] cur_addr;
    reg  [4:0]  cur_beats, cur_skip;
    reg  [7:0]  cur_vb;
    reg  [5:0]  cur_ly;
    reg  [5:0]  beat_idx;
    reg         src_active;
    reg         src_delay;
    integer     seed = 32'hC0DE_5678;

    wire ds_push = row_valid & row_ready;
    wire ds_pop  = !src_active && (rq_cnt != 0);
    assign row_ready = (rq_cnt < 3'd15);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq_wp <= 0; rq_rp <= 0; rq_cnt <= 0; src_active <= 0; src_delay <= 0;
            cur_addr <= 0; cur_beats <= 0; cur_skip <= 0; cur_vb <= 0; cur_ly <= 0;
            beat_idx <= 0;
        end
        else begin
            if (ds_push) begin
                rq_addr[rq_wp]  <= row_addr;
                rq_beats[rq_wp] <= row_beats;
                rq_skip[rq_wp]  <= row_head_skip;
                rq_vb[rq_wp]    <= row_valid_bytes;
                rq_ly[rq_wp]    <= row_local_y;
                rq_wp <= rq_wp + 3'd1;
            end
            if (ds_pop) begin
                cur_addr   <= rq_addr[rq_rp];
                cur_beats  <= rq_beats[rq_rp];
                cur_skip   <= rq_skip[rq_rp];
                cur_vb     <= rq_vb[rq_rp];
                cur_ly     <= rq_ly[rq_rp];
                beat_idx   <= 6'd0;
                src_active <= 1'b1;
                rq_rp      <= rq_rp + 3'd1;
            end
            else if (src_fire) begin
                if (beat_idx + 6'd1 == {1'b0, cur_beats}) begin
                    src_active <= 1'b0;
                    beat_idx   <= 6'd0;
                end
                else begin
                    beat_idx  <= beat_idx + 6'd1;
                end
            end
            rq_cnt <= rq_cnt + (ds_push ? 3'd1 : 3'd0) - (ds_pop ? 3'd1 : 3'd0);
        end
    end

    assign src_fire   = src_active & ~fifo_wr_full;
    assign fifo_wr_en = src_fire;
    assign fifo_wr_data = make_beat(cur_addr, beat_idx, cur_skip, cur_vb, cur_ly);

    function [255:0] make_beat(input [31:0] base_addr, input [5:0] k,
                               input [4:0] skip, input [7:0] vbytes,
                               input [5:0] ly);
        integer j;
        reg [31:0] a, rel, yy, off;
        reg [10:0] px, py;
        reg [23:0] pv;
        reg [1:0]  c;
        begin
            make_beat = 256'd0;
            for (j = 0; j < 32; j = j + 1) begin
                // the byte address inside the frame defines the pixel directly:
                //   byte = frame_base + y*stride + 3*x + c
                a   = base_addr + k * 32 + j;
                rel = a - 32'd0;          // frame_base is 0 in this test
                yy  = rel / 5760;
                off = rel % 5760;
                px  = off / 3;
                c   = off % 3;
                if ((yy < 1080) && (px < 1920)) begin
                    py = yy[10:0];
                    pv = img(px, py);
                    make_beat[j*8 +: 8] = mem_byte(pv, c);
                end
                else make_beat[j*8 +: 8] = 8'hAA;
            end
        end
    endfunction
    // ------------------------------------------- read FIFO + port (as in the top)
    // This is the exact two-stage hand-off the system uses between the DDR read
    // adapter and dgc_core: an async FIFO plus the elastic port wrapper.
    ddr_read_fifo u_rdf (
        .wr_clk (clk), .wr_rst (~rst_n),
        .wr_en (fifo_wr_en), .wr_data (fifo_wr_data),
        .wr_full (fifo_wr_full), .wr_water_level (),
        .rd_clk (clk), .rd_rst (~rst_n),
        .rd_en (fifo_pop), .rd_data (fifo_rd_data),
        .almost_full (), .rd_empty (fifo_empty),
        .rd_water_level (), .almost_empty ()
    );

    dgc_fifo_rd_port #(.DATA_W(256)) u_port (
        .clk (clk), .rst_n (rst_n),
        .rd_fire (1'b1), .rd_ready (),
        .fifo_empty (fifo_empty), .fifo_pop (fifo_pop), .fifo_data (fifo_rd_data),
        .out_valid (beat_valid), .out_ready (beat_ready), .out_data (beat_data)
    );
    // ------------------------------------------------------------- stripe check
    task read_pixel(input [1:0] bank, input [14:0] addr, output [23:0] rgb);
        begin
            case (bank)
                2'd0: begin ram0_rd_addr <= addr; @(posedge clk); #0.2;
                            @(posedge clk); #0.2; rgb = ram0_rd_data; end
                2'd1: begin ram1_rd_addr <= addr; @(posedge clk); #0.2;
                            @(posedge clk); #0.2; rgb = ram1_rd_data; end
                2'd2: begin ram2_rd_addr <= addr; @(posedge clk); #0.2;
                            @(posedge clk); #0.2; rgb = ram2_rd_data; end
                2'd3: begin ram3_rd_addr <= addr; @(posedge clk); #0.2;
                            @(posedge clk); #0.2; rgb = ram3_rd_data; end
                default: begin rgb = 24'd0; end
            endcase
        end
    endtask

    integer n_offer = 0;
    integer n_checked = 0;
    integer guard;
    integer n_ev = 0;
    always @(posedge clk) if (rst_n && (n_ev < 16) && u_dut.desc_valid && u_dut.desc_ready) begin
        n_ev = n_ev + 1;
        $display("DSC tag=%0d kind=%0d bx=%0d by=%0d bw=%0d bh=%0d recs=%0d",
                 u_dut.d_tag, u_dut.d_kind, u_dut.d_bbox_x, u_dut.d_bbox_y,
                 u_dut.d_bbox_w, u_dut.d_bbox_h, u_dut.d_rec_count);
    end
    always @(posedge clk) if (rst_n && (n_ev < 16) && u_dut.fill_start)
        $display("FILLSTART bx=%0d by=%0d bw=%0d bh=%0d", u_dut.fill_bx,
                 u_dut.fill_by, u_dut.fill_bw, u_dut.fill_bh);
    always @(posedge clk) if (rst_n && (n_ev < 16) && u_dut.u_fill.done)
        $display("FILLDONE set=%0d", u_dut.owner_fill_set);
    always @(posedge clk) if (rst_n && (n_ev < 16) && u_dut.sample_begin)
        $display("SAMPSTART bx=%0d by=%0d set=%0d", u_dut.samp_bx,
                 u_dut.samp_by, u_dut.samp_set);
    reg     tput_mode = 0;
    integer cyc = 0;
    integer cyc0 = 0;
    integer cyc_end = 0;
`ifdef DGC_BOARD_RATE_TEST
    real offer_us, deadline_us;
    integer late_stripes = 0;
`endif
    integer cyc_fill = 0, cyc_sample = 0, cyc_drain = 0, cyc_idle = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        case (u_dut.cstate)
            3'd0: cyc_idle = cyc_idle + 1;
            3'd1: cyc_fill = cyc_fill + 1;
            3'd2: cyc_sample = cyc_sample + 1;
            3'd3: cyc_drain = cyc_drain + 1;
        endcase
    end

    task check_stripe(input [6:0] sid, input [1:0] bank, input [31:0] job,
                      input [6:0] lines);
        integer lx, ly;
        reg [23:0] got;
        reg [23:0] exp;
        reg [14:0] addr;
        begin
            for (ly = 0; ly < lines; ly = ly + 1)
                for (lx = 0; lx < 1920; lx = lx + 1) begin
                    addr = {ly[3:0], lx[10:0]};
                    read_pixel(bank, addr, got);
`ifdef DGC_RADIAL_TEST
                    exp = radial_expected[(sid * 16 + ly) * 1920 + lx];
`else
                    exp = img(lx[10:0], (sid * 16 + ly));
`endif
                    if (got !== exp) begin
                        dgc_errors = dgc_errors + 1;
                        if (dgc_errors < 12)
                            $display("TEST_FAIL: stripe %0d (%0d,%0d) exp=%06h act=%06h",
                                     sid, lx, sid * 16 + ly, exp, got);
                    end
                    n_checked = n_checked + 1;
                end
        end
    endtask

    initial begin
`ifdef DGC_RADIAL_TEST
        cfg_mode = 2'd1;
        cfg_m00 = 32'sd32014; cfg_m02 = -32'sd31278815;
        cfg_m11 = 32'sd31711; cfg_m12 = -32'sd16492896;
        if (!$value$plusargs("EXPECT=%s", expected_path)) begin
            $display("TEST_FAIL: radial test requires +EXPECT=reference.hex");
            $finish;
        end
        $readmemh(expected_path, radial_expected);
        $display("TEST_INFO: MODE=1 full-frame radial correction, nonzero bilinear weights");
`endif
        tput_mode = $test$plusargs("TPUT");
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // start a job
        job_start <= 1'b1;
        @(posedge clk); #0.2;
        job_start <= 1'b0;
        cyc0 = cyc;

        // Offer capture is decoupled from the (slow) stripe readback: offers are
        // accepted into a small queue, otherwise a level-style offer would be
        // consumed by the writer while the testbench is busy reading pixels.
        guard = 0;
        while (n_offer < NSTRIPE && guard < 4000000) begin
            @(posedge clk); #0.2;
            guard = guard + 1;
            if (offer_valid) begin
                @(negedge clk);
                offer_cap = offer_data;
`ifdef DGC_BOARD_RATE_TEST
                // Earliest possible job start = display vs_fall; top has 36
                // back-porch lines, 2200 clocks/line, active starts at x=192.
                // Stripe n>0 must be prefetched before previous stripe DE falls.
                offer_us = (cyc - cyc0) * 5.842 / 1000.0;
                deadline_us = ((n_offer == 0) ? (36*2200+192) :
                               ((36+16*n_offer)*2200-88)) * 6.727 / 1000.0;
                $display("TEST_INFO: BOARD stripe=%0d ready_us=%0.3f deadline_us=%0.3f margin_us=%0.3f",
                         n_offer, offer_us, deadline_us, deadline_us-offer_us);
                if (offer_us > deadline_us) late_stripes = late_stripes + 1;
`endif
                offer_ack <= 1'b1;
                @(posedge clk); #0.2;
                offer_ack <= 1'b0;
                // offer payload: job32, epoch16, stripe7, bank1, lines5, err1, rsv2
                if (offer_cap[31:0] !== job_id) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: offer job %08h exp %08h", offer_cap[31:0], job_id);
                end
                if (offer_cap[54:48] !== n_offer[6:0]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: offer stripe %0d exp %0d", offer_cap[54:48], n_offer);
                end
                if (!tput_mode)
                    check_stripe(offer_cap[54:48], {offer_cap[62], offer_cap[55]},
                                 offer_cap[31:0], offer_cap[60:56]);
                // release the bank so the writer can reuse it
                release_bank = {offer_cap[62], offer_cap[55]};
                release_status_bad = 1'b0;
                rel <= 1'b1;
                @(posedge clk); #0.2;
                rel <= 1'b0;
                n_offer = n_offer + 1;
                if (tput_mode && (n_offer == NSTRIPE)) begin
                    cyc_end = cyc;
                    $display("TEST_INFO: TPUT cycles=%0d blocks=%0d cycles_per_block=%0d",
                             cyc_end - cyc0, cnt_blocks_done,
                             (cyc_end - cyc0) / ((cnt_blocks_done == 0) ? 1 : cnt_blocks_done));
                    $display("TEST_INFO: TPUT state cycles fill=%0d sample=%0d drain=%0d idle=%0d",
                             cyc_fill, cyc_sample, cyc_drain, cyc_idle);
                end
                else
                    $display("TEST_INFO: stripe %0d checked (%0d pixels)", n_offer - 1, n_checked);
            end
        end

        if (n_offer != NSTRIPE) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: only %0d stripe offers in %0d cycles", n_offer, guard);
        end
        $display("TEST_INFO: offers=%0d checked=%0d accept=%0d black=%0d split=%0d blocks=%0d",
                 n_offer, n_checked, cnt_accept, cnt_black, cnt_split, cnt_blocks_done);
`ifdef DGC_BOARD_RATE_TEST
        // This probe measures optimistic no-reader-backpressure arrival times;
        // a positive late count demonstrates a rate problem even in ideal RTL.
        $display("TEST_INFO: BOARD late_stripes=%0d of %0d (zero is required for on-time output)",
                 late_stripes, n_offer);
        `DGC_CHECK_EQ(late_stripes, 0, "board-rate probe stripe deadlines")
`endif
        `DGC_FINISH
    end
endmodule





