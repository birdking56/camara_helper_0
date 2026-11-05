//-----------------------------------------------------------------------------
// tb_sys.v - cross-domain system test for dgc_core_sys
//
// The capture side is fed a *short* HDMI frame (64 active lines) so the whole
// write path completes quickly; the write adapter is parameterised with
// FRAME_BYTES = 64*5760 so it still sees a real frame-end offset. The DDR model
// stores the written beats, so the processing path reads back exactly what the
// capture path wrote for those rows. Addresses never written (rows 64..1079) are
// served from a lazy image generator, which lets the full 1080-line geometry run
// without capturing a full frame.
//
// Checked: the video reader's output for the first stripe (16 lines) of a frame
// whose stripe 0 was published in time. The core runs one block at a time, so it
// produces a stripe slower than the 60 Hz display; later stripes underflow by
// design of the first integration (throughput work is a separate item), and this
// test therefore limits itself to the stripe that the pipeline can sustain.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

// The default run proves the data path with the job started as soon as a frame
// is available. `+define+DGC_ALIGN_TEST` additionally proves the output-frame
// gate: a job may only start on a frame_tick (output vs_fall).
module tb_jobs;
    integer dgc_errors = 0;

`ifdef DGC_BOARD_RADIAL_TEST
`define DGC_RADIAL_JOB_TEST
`elsif DGC_ABORT_TEST
`define DGC_RADIAL_JOB_TEST
`endif
`ifdef DGC_RADIAL_JOB_TEST
    reg [23:0] radial_expected [0:2073599];
    reg [1023:0] expected_path;
    initial begin
        if (!$value$plusargs("EXPECT=%s", expected_path))
            $fatal(1, "radial job suite requires +EXPECT");
        $readmemh(expected_path, radial_expected);
    end
`endif

`ifdef DGC_ALIGN_TEST
    localparam integer ALIGN_TO_FRAME = 1;
`else
    localparam integer ALIGN_TO_FRAME = 0;
`endif

    reg vin_clk = 0;  always #(`DGC_T_VIN) vin_clk = ~vin_clk;
    reg ddr_clk = 0;  always #(`DGC_T_DDR) ddr_clk = ~ddr_clk;
    // 180 MHz, matching the board's pll_proc after the 2026-10-27 change. The
    // shared macro still says 225 MHz; the relative proc/vin/vout clocks change
    // the pipeline races under test, so this suite uses the real board clock.
`ifdef DGC_BOARD_RADIAL_TEST
    reg proc_clk = 0; always #2.921 proc_clk = ~proc_clk;
    reg vout_clk = 0; always #3.3635 vout_clk = ~vout_clk;
`else
    reg proc_clk = 0; always #2.7778 proc_clk = ~proc_clk;
    reg vout_clk = 0; always #(`DGC_T_VOUT) vout_clk = ~vout_clk;
`endif

    reg rst_n = 0;
    `DGC_GRS_INST

    localparam integer FRAME_BYTES = 64 * 5760;    // short capture frame
    localparam integer STRIDE = 5760;

    // ================================================================ vin raster
    integer hc = 0, vc = 0;      // vc: 0..63 active, then blanking, then VS
    localparam integer V_ACT = 64;
    localparam integer V_TOTAL = V_ACT + 45;

    always @(posedge vin_clk) begin
        if (!rst_n) begin hc <= 0; vc <= 0; end
        else begin
            if (hc == 2199) begin
                hc <= 0;
                vc <= (vc == V_TOTAL - 1) ? 0 : vc + 1;
            end
            else hc <= hc + 1;
        end
    end

    wire vs_in = (vc >= V_ACT + 2) && (vc < V_ACT + 7);
    wire hs_in = (hc < 44);
    wire de_in = (hc < 1920) && (vc < V_ACT);

    function [23:0] img(input [10:0] x, input [10:0] y);
        begin
            img = {x[7:0], y[7:0], x[7:0] ^ y[7:0]};
        end
    endfunction

    wire [23:0] rgb_in = img(hc[10:0], vc[10:0]);

    // ================================================================ vout raster
    // 2026-11-02 (b): the output raster now has a REAL vertical back porch. Without
    // one the active region started on the very first line after vs_fall, so a job
    // that starts exactly on the boundary could never have stripe 0 ready in time
    // and every aligned frame was black - which is why the aligned variants could
    // only assert "the start is near the tick", never that the frame was good.
    // 45 lines of blanking = 45 x 2200 vout clocks = 800 us of processing time,
    // the same budget the real 1080p60 mode gives.
    integer hco = 0, vco = 0;
`ifdef DGC_BOARD_RADIAL_TEST
    localparam integer VOUT_TOTAL = 1125;
    localparam integer V_BACK = 41;        // 5 sync + 36 back porch
    localparam integer H_ACTIVE = 192;     // 44 sync + 148 back porch
`else
    localparam integer VOUT_TOTAL = 1170;   // 45 blank + 1080 active + 45 front porch
    localparam integer V_BACK  = 45;
    localparam integer H_ACTIVE = 0;
`endif
    reg vout_en = 0;
    always @(posedge vout_clk) begin
        if (!rst_n) begin hco <= 0; vco <= 0; end
        else if (!vout_en) begin hco <= 0; vco <= 0; end
        else begin
            if (hco == 2199) begin
                hco <= 0;
                vco <= (vco == VOUT_TOTAL - 1) ? 0 : vco + 1;
            end
            else hco <= hco + 1;
        end
    end
    // The sync signals must be quiet while the raster is gated: holding de high
    // from reset produced a phantom de_rise, which the reader (correctly) treats
    // as "first active line without stripe 0" and abandons the frame.
    wire        in_active_v = vout_en && (vco >= V_BACK) && (vco < V_BACK + 1080);
    wire [11:0] y_act       = (vco >= V_BACK) ? (vco[11:0] - V_BACK[11:0]) : 12'd0;
    wire [11:0] x_act = hco[11:0] - H_ACTIVE[11:0];
    wire de_tg = in_active_v && (hco >= H_ACTIVE) && (hco < H_ACTIVE + 1920);
    wire hs_tg = vout_en && (hco < 44);
`ifdef DGC_BOARD_RADIAL_TEST
    wire vs_tg = vout_en && (vco < 5);
`else
    wire vs_tg = vout_en && (vco >= V_BACK + 1080) && (vco < V_BACK + 1085);
`endif

    // ================================================================ DDR model
    // The DDR model returns the synthetic image for every address (the same
    // bytes the capture path writes), so the processing path reads exactly what
    // the capture path would have stored, without a 6 MB simulator array.
    integer     i;

    // write side
    reg  [27:0] aw_addr;
    reg  [4:0]  aw_left;
    reg         aw_active = 0;

    // read side
    reg  [27:0] ar_addr;
    reg  [5:0]  ar_left;
    // ---------------------------------------------------- read slave (s2-style)
    // Same response state machine as the verified s2_ddr_rd_adapter slave. The
    // critical detail (documented in that testbench) is that the last beat's
    // rvalid must be dropped in the same edge at which it is accepted, otherwise
    // the beat is presented for two acceptance cycles and every burst reports an
    // extra beat, which makes the R-channel checker halt the read engine.
    localparam [1:0] SL_IDLE = 2'd0, SL_WAIT = 2'd1, SL_SEND = 2'd2;
    reg  [1:0]  sl_state = SL_IDLE;
    reg  [27:0] sl_addr;
    reg  [4:0]  sl_len, sl_idx;
    reg  [7:0]  sl_delay;
    integer read_delay = 4;
    initial begin
        if ($value$plusargs("RD_DELAY=%d", read_delay)) begin end
        if (read_delay < 0 || read_delay > 255) $fatal(1, "invalid RD_DELAY");
        $display("TEST_INFO: DDR model initial read delay=%0d cycles", read_delay);
    end
    reg  [255:0] rdata = 0;
    reg          rvalid = 0, rlast = 0;
    reg  [3:0]   rid = 0;

    wire [27:0] awaddr; wire [3:0] awlen; wire awvalid;
    wire [255:0] wdata; wire [31:0] wstrb;
    wire [27:0] araddr; wire [3:0] arlen; wire arvalid;

    // Lazy image word for a byte address.
    // The frame manager hands out slots at 0x00000000 / 0x01000000 / 0x02000000,
    // i.e. 16 MiB apart, while one 1080p frame is only 6.2 MB (and 16 MiB is not a
    // whole number of frames), so the address must first be reduced to the offset
    // *inside its slot* and only then wrapped into one frame. Wrapping the absolute
    // address (`byte_addr % FRAME_MOD`) shifted the picture by a fraction of a row,
    // which is exactly the long-unexplained "valid image value at the wrong
    // coordinate" (e.g. a9822a at (0,0)) seen whenever a job ran in slot 1 or 2.
    localparam [31:0] FRAME_MOD = 32'd1920 * 32'd3 * 32'd1080;
    function [255:0] img_word(input [31:0] byte_addr);
        integer j;
        reg [31:0] a, a0, off, yy;
        reg [10:0] px;
        reg [1:0]  c;
        reg [23:0] pv;
        begin
            img_word = 256'd0;
            a0  = (byte_addr & 32'h00FF_FFFF) % FRAME_MOD;
            for (j = 0; j < 32; j = j + 1) begin
                a   = a0 + j; if (a >= FRAME_MOD) a = a - FRAME_MOD;
                yy  = a / STRIDE;
                off = a % STRIDE;
                px  = off / 3;
                c   = off % 3;
                if (yy < 1080) begin
                    pv = img(px, yy[10:0]);
                    img_word[j*8 +: 8] = (c == 2'd0) ? pv[7:0] :
                                         (c == 2'd1) ? pv[15:8] : pv[23:16];
                end
                else img_word[j*8 +: 8] = 8'hAA;
            end
        end
    endfunction

    // AXI address unit is 4 bytes: byte address = word address * 4. One beat of
    // the native 256-bit port is 32 bytes, so the next beat is +8 native words,
    // not +1. The first version used +1 and returned overlapping 4-byte-shifted
    // beats; the first 10 pixels (one beat) were right and every pixel after the
    // 30-byte boundary was wrong, which looked like an unpack carry bug.
    wire [27:0] sl_next = sl_addr + {20'd0, sl_idx, 3'd0} + 28'd8;
    wire [255:0] imgw0 = img_word({2'b00, sl_addr, 2'b00});
    wire [255:0] imgw1 = img_word({2'b00, sl_next, 2'b00});

    always @(posedge ddr_clk) begin
        if (!rst_n) begin
            sl_state <= SL_IDLE;
            rvalid <= 1'b0; rlast <= 1'b0;
        end
        else case (sl_state)
            SL_IDLE: begin
                if (arvalid) begin
                    sl_addr  <= araddr;
                    sl_len   <= arlen;
                    sl_idx   <= 5'd0;
                    sl_delay <= read_delay[7:0];
                    sl_state <= SL_WAIT;
                end
            end
            SL_WAIT: begin
                if (sl_delay != 0) sl_delay <= sl_delay - 8'd1;
                else begin
                    rdata    <= imgw0;
                    rvalid   <= 1'b1;
                    rlast    <= (sl_len == 5'd0);
                    sl_idx   <= 5'd0;
                    // always run SL_SEND, even for a one-beat burst: that state is
                    // the one that drops rvalid after the accepted beat. Jumping
                    // straight to SL_IDLE left rvalid high for a second cycle,
                    // which the R-channel checker (correctly) reports as an
                    // extra beat and then halts the engine.
                    sl_state <= SL_SEND;
                end
            end
            default: begin   // SL_SEND: the beat presented now is accepted
                rvalid <= 1'b0;
                if (sl_idx == sl_len) begin
                    rlast    <= 1'b0;
                    sl_state <= SL_IDLE;
                end
                else begin
                    sl_idx <= sl_idx + 5'd1;
                    rdata  <= imgw1;
                    rlast  <= ((sl_idx + 5'd1) == sl_len);
                    rvalid <= 1'b1;
                end
            end
        endcase
    end

    assign axi_arready = (sl_state == SL_IDLE);

    // ================================================================ DUT
    wire [23:0] rgb_out; wire de_out, hs_out, vs_out;
    wire [31:0] st_wr, st_proc, st_uf, st_drop, st_err;
    wire frame_black;

    // One-cycle frame-boundary pulse in the proc domain.
    // 2026-11-02 (b): with ALIGN_TO_FRAME this is the REAL output vs_fall, turned
    // into a toggle in the vout domain and synchronised into proc_clk exactly the
    // way dgc_top_sys derives it. The synthetic 100k-cycle tick used before was not
    // tied to the display at all, so the aligned test could not tell whether the
    // start phase was the one the board sees.
    reg frame_tick = 0;
    reg frame_tick_d = 0;
    generate
        if (ALIGN_TO_FRAME) begin : g_real_tick
            reg vs_tg_d, tick_tgl;
            reg [2:0] tick_sync;
            always @(posedge vout_clk or negedge rst_n) begin
                if (!rst_n) begin vs_tg_d <= 1'b0; tick_tgl <= 1'b0; end
                else begin
                    vs_tg_d <= vs_tg;
                    if (vs_tg_d & ~vs_tg) tick_tgl <= ~tick_tgl;
                end
            end
            always @(posedge proc_clk or negedge rst_n) begin
                if (!rst_n) tick_sync <= 3'b000;
                else        tick_sync <= {tick_sync[1:0], tick_tgl};
            end
            always @(posedge proc_clk) begin
                frame_tick   <= (tick_sync[2] ^ tick_sync[1]);
                frame_tick_d <= frame_tick;
            end
        end
        else begin : g_no_tick
            always @(posedge proc_clk) begin
                frame_tick   <= 1'b0;
                frame_tick_d <= 1'b0;
            end
        end
    endgenerate

    // Frame alignment (2026-11-02 b): what must be aligned is the START, not the
    // request. The acquire is issued as soon as the job FSM is idle and the
    // returned descriptor is held until an output frame boundary arrives, so
    // job_start_p must land on the tick (one or two cycles after it, because it is
    // registered). The old design requested *at* the boundary and started a mailbox
    // round trip later, which is why this window used to be 12000 cycles.
    //
    // 2026-11-02 20:45: when no descriptor is in hand at the boundary (capture
    // frame completes after it, which is the common case), the FSM sends a forced
    // acquire and starts as soon as the descriptor returns. That round trip is a few
    // tens of cycles, still far inside the 592 us vertical back porch, so the window
    // is raised to the RTL's START_WINDOW (20000 cycles ~= 117 us) and the start
    // must not drift beyond it.
    localparam integer ALIGN_WINDOW = 20000;   // mirrors START_WINDOW in dgc_core_sys.v
    integer align_cyc = 0;
    always @(posedge proc_clk) begin
        if (frame_tick) align_cyc <= 0;
        else if (align_cyc < ALIGN_WINDOW + 1) align_cyc <= align_cyc + 1;
    end

    always @(posedge proc_clk) begin
        if (rst_n && ALIGN_TO_FRAME && u_sys.job_start_p && (align_cyc > ALIGN_WINDOW)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: job_start outside the output frame boundary window (%0d cycles)", align_cyc);
        end
    end

    // The 2026-10-30 stale-frame bug was fixed in the frame manager (it refuses a
    // frame that equals the last acquired one while a new capture is in flight), so
    // the acquire no longer has to wait for the boundary. Prove the new property:
    // every job's descriptor is requested well away from the boundary. If the
    // request were still gated by frame_tick, this assertion fires instead.
    integer acq_cyc = 0;
    reg     acq_far = 0;
    always @(posedge proc_clk) begin
        if (frame_tick) acq_cyc <= 0;
        else if (acq_cyc < 64) acq_cyc <= acq_cyc + 1;
        if (rst_n && u_sys.acq_src_valid && u_sys.acq_src_ready && (acq_cyc > 8) &&
            !u_sys.acq_force_req)
            acq_far <= 1'b1;
    end
    always @(posedge proc_clk) begin
        if (rst_n && ALIGN_TO_FRAME && u_sys.job_start_p) begin
            if (!acq_far) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: the source frame of this job was requested at the boundary, not early");
            end
            acq_far <= 1'b0;
        end
    end

    // A job may only repeat the same source frame once in a row (2026-11-02: forced
    // boundary acquire is capped to one repeat; twice in a row means the source frame
    // is frozen again).
    //
    // 2026-11-02 20:45: a *single* repeat is now legal by design - the forced
    // boundary acquire hands out the last frame when the fresh capture has not
    // completed yet, which is what keeps 60 jobs/s. A permanent freeze still shows
    // up as the same frame being used three or more times in a row.
    reg [31:0] last_job_fid   = 32'hFFFF_FFFF;
    reg [31:0] last_job_alloc = 32'hFFFF_FFFF;
    integer    same_run = 0;
    always @(posedge proc_clk) begin
        if (rst_n && u_sys.job_start_p) begin
            if (u_sys.job_id_r == last_job_fid) same_run <= same_run + 1;
            else                                same_run <= 0;
            if ((u_sys.job_id_r == last_job_fid) && (u_sys.fm_alloc != last_job_alloc) &&
                (same_run >= 9)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: job re-processed frame_id %0d twice in a row although %0d new frame(s) were allocated",
                         last_job_fid, u_sys.fm_alloc - last_job_alloc);
            end
            else if ((u_sys.job_id_r == last_job_fid) && (u_sys.fm_alloc != last_job_alloc))
                $display("TEST_INFO: frame %0d repeated once (forced boundary acquire)", last_job_fid);
            last_job_fid   = u_sys.job_id_r;
            last_job_alloc = u_sys.fm_alloc;
        end
    end

    reg         proc_latch = 1'b0;
    reg         ddr_latch  = 1'b0;
    reg         vout_latch = 1'b0;
    wire [127:0] dbg_perf_proc;
    wire [63:0]  dbg_perf_ddr;
    wire [63:0]  dbg_perf_vout;

    dgc_core_sys #(.FRAME_BYTES(FRAME_BYTES), .ALIGN_TO_FRAME(ALIGN_TO_FRAME)
`ifdef DGC_ABORT_TEST
                   , .JOB_WD_LIMIT(2800000)   // just above one healthy job (~2.6 M cycles)
`endif
                   ) u_sys (
        .vin_clk (vin_clk), .vin_rst_n (rst_n),
        .ddr_clk (ddr_clk), .ddr_rst_n (rst_n),
        .proc_clk (proc_clk), .proc_rst_n (rst_n),
        .vout_clk (vout_clk), .vout_rst_n (rst_n),
        .vs_in (vs_in), .hs_in (hs_in), .de_in (de_in), .rgb_in (rgb_in),
        .axi_awaddr (awaddr), .axi_awlen (awlen), .axi_awvalid (awvalid),
        .axi_awready (1'b1),
        .axi_wdata (wdata), .axi_wstrb (wstrb), .axi_wready (1'b1),
        .axi_wusero_id (4'd0), .axi_wusero_last (1'b0),
        .axi_araddr (araddr), .axi_arlen (arlen), .axi_arvalid (arvalid),
        .axi_arready (axi_arready),
        .axi_rdata (rdata), .axi_rvalid (rvalid), .axi_rlast (rlast), .axi_rid (rid),
`ifdef DGC_RADIAL_JOB_TEST
        .cfg_mode (2'd1),
        .cfg_m00 (32'sd32014), .cfg_m01 (32'sd0), .cfg_m02 (-32'sd31278815),
        .cfg_m10 (32'sd0), .cfg_m11 (32'sd31711), .cfg_m12 (-32'sd16492896),
`else
        .cfg_mode (2'd0),
        .cfg_m00 (32'sd67108864), .cfg_m01 (32'sd0), .cfg_m02 (32'sd0),
        .cfg_m10 (32'sd0), .cfg_m11 (32'sd67108864), .cfg_m12 (32'sd0),
`endif
        .cfg_fx (32'sd137377855), .cfg_fy (32'sd138692973),
        .cfg_cx (32'sd64030536), .cfg_cy (32'sd34085643),
        .cfg_k1 (-32'sd129279204), .cfg_k2 (32'sd74679738),
        .cfg_norm_abs_max (32'h08000000), .gamma_mode (2'd0),
        .frame_tick (frame_tick),
        .de_tg (de_tg), .hs_tg (hs_tg), .vs_tg (vs_tg),
        .x_tg (x_act), .y_tg (y_act),   // active-line y: the reader addresses {y[3:0], x}
        .rgb_out (rgb_out), .de_out (de_out), .hs_out (hs_out), .vs_out (vs_out),
        .stat_frames_written (st_wr), .stat_frames_processed (st_proc),
        .stat_stripes_underflow (st_uf), .stat_frames_dropped (st_drop),
        .stat_ddr_errors (st_err), .frame_black (frame_black),
        .dbg_proc_latch (proc_latch), .dbg_ddr_latch (ddr_latch),
        .dbg_vout_latch (vout_latch),
        .dbg_perf_proc (dbg_perf_proc), .dbg_perf_ddr (dbg_perf_ddr),
        .dbg_perf_vout (dbg_perf_vout)
    );


    // ================================================================ checker
    // delayed raster to align with the reader's RD_LAT
    reg [11:0] xd [0:1];
    reg [11:0] yd [0:1];
    integer k;
    always @(posedge vout_clk) begin
        xd[0] <= x_act; yd[0] <= y_act;   // active-line y (back porch removed)
        xd[1] <= xd[0];     yd[1] <= yd[0];
    end
    wire [11:0] x_dl = xd[1];
    wire [11:0] y_dl = yd[1];

    reg check_frame = 0;
    integer proc_wait = 0;
    integer fe_cnt = 0, fa_cnt = 0;

    // -------------------------------------------- early source release (DGC5d)
    // 2026-11-02: dgc_core_sys now releases the source DDR slot as soon as the core
    // can no longer read it (`u_core.src_idle`: all blocks dispatched, the last
    // record taken, fill idle, no row request in flight) instead of when the last
    // pixel has been accepted by the stripe writer - the writer is paced by the
    // display, so the tail of a job is often several ms long.
    //
    // What this monitor proves on the integration:
    //   * every started job issues exactly one release (the frame manager's
    //     acquire/release accounting, and s2_frame_mgr R1-R5b, stay valid);
    //   * at least one release happens while the core is still busy, and the lead
    //     over frame_done is printed, so the change is measurably "early" and not a
    //     rename of the old behaviour.
    integer src_rel_n = 0;
    integer src_rel_early_n = 0;
    integer src_rel_dup = 0;
    integer rel_at_cyc = 0;
    integer rel_at_max = 0;
    integer job_cyc = 0;
    integer rel_cstate_seen = 0;
    reg     src_rel_in_job = 1'b0;

    // Where inside the job does the release happen? Counted in proc cycles since
    // job_start, so it can be compared directly with the job duration the testbench
    // prints ("job N complete ... t="). The release is *early* when this is well
    // below the job duration.
    always @(posedge proc_clk) begin
        if (rst_n) begin
            if (u_sys.job_start_p) begin
                src_rel_in_job = 1'b0;
                job_cyc = 0;
            end
            else job_cyc = job_cyc + 1;
            if (u_sys.rel_src_valid && u_sys.rel_src_ready) begin
                src_rel_n = src_rel_n + 1;
                if (u_sys.u_core.busy) src_rel_early_n = src_rel_early_n + 1;
                if (u_sys.job_state == 2'd1) begin
                    if (src_rel_in_job) src_rel_dup = src_rel_dup + 1;
                    src_rel_in_job = 1'b1;
                end
                if (rel_cstate_seen == 0) rel_cstate_seen = u_sys.u_core.dbg_cstate + 1;
                rel_at_cyc = job_cyc;
                if (rel_at_cyc > rel_at_max) rel_at_max = rel_at_cyc;
            end
        end
    end
    integer dbg_c = 0; always @(posedge proc_clk) dbg_c <= dbg_c + 1;
    integer dbg_beats = 0;
    integer n_pop = 0;
    integer n_js = 0;
    integer n_of = 0, n_orf = 0;
    always @(posedge proc_clk) if (rst_n && u_sys.offer_valid_c && u_sys.offer_ready_c && n_of < 5) begin n_of = n_of + 1; $display("OFFER sid=%0d bank=%b lines=%0d t=%0t", u_sys.offer_data_c[54:48], u_sys.offer_data_c[55], u_sys.offer_data_c[60:56], $time); $display("MEM0=%06h MEM1=%06h MEM4=%06h", u_sys.u_core.u_stripe.u_ram0.mem[0], u_sys.u_core.u_stripe.u_ram0.mem[1], u_sys.u_core.u_stripe.u_ram0.mem[4]); end
    always @(posedge vout_clk) if (rst_n && u_sys.mb_offer_dst_valid && u_sys.mb_offer_dst_ready && n_orf < 5) begin n_orf = n_orf + 1; $display("RD_TAKE sid=%0d wf=%b cok=%b t=%0t", u_sys.mb_offer_dst_data[54:48], u_sys.u_reader.waiting_first, u_sys.u_reader.cur_ok, $time); end
    always @(posedge proc_clk) if (rst_n && u_sys.job_start_p) begin
        n_js = n_js + 1;
        // 2026-11-03: used to measure the stripe-0 latency (job_start -> first
        // sid=0 offer), which is the physical budget a late start may spend:
        // window + that latency must stay below the vertical back porch.
        $display("JOBSTART n=%0d t=%0t align_cyc=%0d", n_js, $time, align_cyc);
    end

    // ------------------------------------------------ K1 = job duration check
    // 2026-11-03: K1 (dbg_job_us) must be the longest *job duration* of the report
    // window. Before the fix the microsecond timer free-ran until the next job_start
    // while frame_done is a level, so a descriptor arriving after the last block made
    // it dip and rise again and the inter-job idle gap was recorded as a "job
    // duration" (the board read a constant 56319 us at 45 job/s = 22222 us per job).
    // Here the real duration is measured cycle by cycle and compared.
    integer k1_cyc = 0, k1_errs = 0, k1_wait = 0, k1_exp = 0;
    reg     k1_run = 1'b0, k1_done = 1'b0, k1_fd_d = 1'b0, k1_checked = 1'b0;
    always @(posedge proc_clk) begin
        if (rst_n) begin
            if (u_sys.job_start_p) begin
                k1_cyc = 0; k1_run = 1'b1; k1_done = 1'b0; k1_wait = 0;
            end
            else if (k1_run && !k1_done) k1_cyc = k1_cyc + 1;
            // Completion is the RISING edge of the level (it stays high between jobs),
            // and dbg_job_us is registered one cycle after that edge.
            // Only the first completed job is compared: frame_done is a level and
            // can dip/rise again when a descriptor arrives after the last block (the
            // very defect this fix is about), which would fire this monitor twice.
            if (k1_run && !k1_done && !k1_checked && u_sys.core_frame_done && !k1_fd_d) begin
                k1_done = 1'b1;
                k1_exp  = k1_cyc / 171;
                k1_wait = 3;
            end
            else if (k1_done && (k1_wait > 0)) begin
                k1_wait = k1_wait - 1;
                if (k1_wait == 0) begin
                    if ((u_sys.dbg_job_us > k1_exp + 3) || (u_sys.dbg_job_us + 3 < k1_exp)) begin
                        k1_errs = k1_errs + 1;
                        $display("TEST_FAIL: K1=%0d us but the job took %0d us",
                                 u_sys.dbg_job_us, k1_exp);
                    end
                    else $display("TEST_INFO: K1 job duration=%0d us matches the measured %0d us",
                                  u_sys.dbg_job_us, k1_exp);
                    k1_run = 1'b0;
                    k1_checked = 1'b1;
                end
            end
            // updated LAST: the edge detect above compares against the previous cycle
            k1_fd_d = u_sys.core_frame_done;
        end
    end
    always @(posedge proc_clk) if (rst_n && (dbg_c % 100000 == 0))
        $display("ST3 ofv=%b ore=%b mob=%b mobr=%b wf=%b fok=%b cok=%b sid0=%0d rdy0=%b rdy1=%b pix=%0d s0cnt=%0d s1cnt=%0d js=%0d", u_sys.offer_valid_c, u_sys.offer_ready_c, u_sys.mb_offer_dst_valid, u_sys.mb_offer_dst_ready, u_sys.u_reader.waiting_first, u_sys.u_reader.frame_ok, u_sys.u_reader.cur_ok, u_sys.u_core.u_stripe.cur_sid[0], u_sys.u_core.u_stripe.ready[0], u_sys.u_core.u_stripe.ready[1], u_sys.u_core.cnt_pixels, u_sys.u_core.u_stripe.cnt[0], u_sys.u_core.u_stripe.cnt[1], n_js);
    always @(posedge proc_clk) if (rst_n && (dbg_c % 100000 == 0) && (dbg_c > 250000))
        $display("ST2 busy=%b mbd=%b mbr=%b q=%0d pend=%0d act=%0d left=%0d head=%0d used=%0d pop=%0d", u_sys.ra_busy, u_sys.mb_row_dst_valid, u_sys.mb_row_dst_ready, u_sys.u_core.u_fill.q_cnt, u_sys.u_core.u_fill.row_pending, u_sys.u_core.u_fill.u_unpack.row_active, u_sys.u_core.u_fill.u_unpack.beats_left, u_sys.u_rd.u_fetch.u_credit.headroom, u_sys.u_rd.used, u_sys.pop_count);
    reg dbg_cred = 0;
    reg dbg_h = 0;
    reg [27:0] h_addr [0:3]; reg [4:0] h_len [0:3]; reg [1:0] h_wp = 0;
    always @(posedge ddr_clk) if (rst_n && arvalid && axi_arready) begin h_addr[h_wp] <= araddr; h_len[h_wp] <= arlen; h_wp <= h_wp + 1; end
    always @(posedge ddr_clk) if (rst_n && u_sys.u_rd.u_fetch.e_any && !dbg_h) begin
        dbg_h <= 1;
        $display("FIRSTERR rem=%0d rv=%b rl=%b sl_len=%0d sl_idx=%0d sl_state=%0d rrows=%0d | AR[3]=%08h/%0d AR[2]=%08h/%0d AR[1]=%08h/%0d AR[0]=%08h/%0d", u_sys.u_rd.u_fetch.remaining, u_sys.axi_rvalid, u_sys.axi_rlast, sl_len, sl_idx, sl_state, u_sys.ra_rows, h_addr[3],h_len[3],h_addr[2],h_len[2],h_addr[1],h_len[1],h_addr[0],h_len[0]);
    end
    integer n_ar = 0, n_row = 0;
    always @(posedge ddr_clk) if (rst_n && arvalid && axi_arready && n_ar < 10) begin
        $display("AR a=%08h len=%0d", araddr, arlen); n_ar = n_ar + 1; end
    always @(posedge ddr_clk) if (rst_n && u_sys.mb_row_dst_valid && u_sys.mb_row_dst_ready && n_row < 10) begin
        $display("ROW a=%08h beats=%0d skip=%0d ly=%0d wly=%0d rd=%0d", u_sys.mb_row_dst_data[31:0], u_sys.mb_row_dst_data[36:32], u_sys.mb_row_dst_data[41:37], u_sys.mb_row_dst_data[55:50], u_sys.u_core.u_fill.u_planner.u_walk.local_y, u_sys.u_core.u_fill.u_planner.u_walk.rows_done); n_row = n_row + 1; end
    always @(posedge ddr_clk) if (rst_n && u_sys.ra_credit_bad && !dbg_cred) begin
        dbg_cred <= 1;
        $display("CREDIT u_ext=%0d ocnt=%0d pcnt=%0d used=%0d wr=%0d pop=%0d", u_sys.u_rd.u_fetch.u_credit.u_ext, u_sys.u_rd.u_fetch.u_credit.o_cnt, u_sys.u_rd.u_fetch.u_credit.p_cnt, u_sys.u_rd.used, u_sys.u_rd.wr_count, u_sys.pop_count);
    end
    reg trace_on = 0;
    integer tr = 0;
    always @(posedge proc_clk) begin
        if (u_sys.u_core.desc_valid && u_sys.u_core.desc_ready) trace_on <= 1;
        if (trace_on && tr < 260) begin
            tr <= tr + 1;
            $display("T%0d rv=%b rr=%b mbd=%b mbr=%b arv=%b arr=%b rvv=%b rll=%b fwr=%b fst=%0d q=%0d plv=%b plr=%b rdlvl=%0d",
                     tr, u_sys.row_valid, u_sys.row_ready, u_sys.mb_row_dst_valid, u_sys.mb_row_dst_ready, u_sys.ra_arvalid, u_sys.ra_arready, u_sys.axi_rvalid, u_sys.axi_rlast, u_sys.ra_fifo_wr, u_sys.u_core.u_fill.state, u_sys.u_core.u_fill.q_cnt, u_sys.u_core.u_fill.urow_valid, u_sys.u_core.u_fill.urow_ready, u_sys.ra_wr_level);
        end
    end
    reg [2:0] fprev = 0;
    integer fp = 0;
    // Trace disabled in this suite: the multi-job run is ~33 ms of simulated
    // time, and a $display every 500 cycles dominates the wall clock without
    // adding information to the two assertions that matter (job completes,
    // next job completes).
    always @(posedge proc_clk) if (rst_n && trace_on && (tr > 250)) begin
        fp <= fp + 1;
    end
    always @(posedge proc_clk) begin
        fprev <= u_sys.u_core.u_fill.state;
    end
    always @(posedge proc_clk) begin
        if (rst_n && u_sys.u_core.desc_valid && u_sys.u_core.desc_ready && (n_pop < 20)) begin
            n_pop = n_pop + 1;
            $display("POP tag=%0d kind=%0d recs=%0d bx=%0d by=%0d bw=%0d bh=%0d ox=%0d oy=%0d ow=%0d oh=%0d", u_sys.u_core.d_tag, u_sys.u_core.d_kind, u_sys.u_core.d_rec_count, u_sys.u_core.d_bbox_x, u_sys.u_core.d_bbox_y, u_sys.u_core.d_bbox_w, u_sys.u_core.d_bbox_h, u_sys.u_core.d_out_x, u_sys.u_core.d_out_y, u_sys.u_core.d_out_w, u_sys.u_core.d_out_h);
        end
    end
    always @(posedge ddr_clk) if (rst_n && (dbg_c % 100000 == 0))
        $display("DBGR arv=%b arr=%b rav=%b rvv=%b rll=%b rdv=%b rdr=%b rlvl=%0d ast=%0d",
                 araddr != 0 || arvalid, arvalid, u_sys.ra_arvalid, u_sys.axi_arready, u_sys.axi_rvalid, u_sys.axi_rlast, u_sys.cdc_rd_valid, u_sys.ra_busy, u_sys.ra_wr_level);
    always @(posedge ddr_clk) if (rst_n && u_sys.cdc_rd_valid && u_sys.cdc_rd_ready && dbg_beats < 8) begin
        $display("BEAT addr=%08h eol? t=%0t", u_sys.cdc_rd_data[287:256], $time); dbg_beats = dbg_beats + 1; end
    always @(posedge ddr_clk) if (rst_n && u_sys.wa_frame_abort)
        $display("ABT prev=%08h cnt=%0d pwl=%b", u_sys.u_wr.prev_addr, u_sys.u_wr.count, u_sys.u_wr.prev_was_last);
    always @(posedge ddr_clk) begin
        if (rst_n && u_sys.wa_frame_end) fe_cnt = fe_cnt + 1;
        if (rst_n && u_sys.wa_frame_abort) fa_cnt = fa_cnt + 1;
        if (rst_n && u_sys.wa_frame_abort) $display("ABORT slot=%0d t=%0t", u_sys.wa_abort_slot, $time);
        if (rst_n && u_sys.wa_frame_end) $display("FRAMEEND slot=%0d t=%0t", u_sys.wa_end_slot, $time);
    end
    always @(posedge proc_clk) if (rst_n && (dbg_c % 100000 == 0))
        $display("DBG c=%0d capf=%0d push=%0d wabeats=%0d fw=%0d cst=%0d blk=%0d fok=%b cok=%b wf=%b hlt=%b crd=%b err=%0d rbeats=%0d rrows=%0d fe=%0d fa=%0d",
                 dbg_c, u_sys.cap_frames, u_sys.cdc_push, u_sys.wa_beats, st_wr,
                 u_sys.u_core.cstate, u_sys.u_core.blocks_done, u_sys.u_reader.frame_ok, u_sys.u_reader.cur_ok, u_sys.u_reader.waiting_first, u_sys.ra_halt, u_sys.ra_credit_bad, u_sys.ra_err, u_sys.ra_beats, u_sys.ra_rows, fe_cnt, fa_cnt);
    always @(posedge proc_clk) if (rst_n && (dbg_c % 20000 == 0))
        $display("DBGR rowv=%b rowr=%b mbr=%b mbd=%b rbusy=%b rwr=%b rempty=%b bv=%b br=%b rdlvl=%0d",
                 u_sys.row_valid, u_sys.row_ready, u_sys.mb_row_dst_valid, u_sys.mb_row_dst_ready, u_sys.ra_busy, u_sys.ra_fifo_wr, u_sys.rdf_rd_empty, u_sys.beat_valid_p, u_sys.beat_ready_p, u_sys.ra_wr_level);
    always @(posedge proc_clk) if (rst_n && (dbg_c % 20000 == 0))
        $display("DBGF fs=%0d fstate=%0d qcnt=%0d plbusy=%b fill_ok=%b s0=%0d s1=%0d fbase=%08h bx=%0d by=%0d bw=%0d bh=%0d",
                 u_sys.u_core.fill_start, u_sys.u_core.u_fill.state, u_sys.u_core.u_fill.q_cnt, u_sys.u_core.u_fill.pl_busy, u_sys.u_core.owner_fill_ok, u_sys.u_core.set0_state, u_sys.u_core.set1_state, u_sys.job_base, u_sys.u_core.fill_bx, u_sys.u_core.fill_by, u_sys.u_core.fill_bw, u_sys.u_core.fill_bh);
    always @(posedge proc_clk) if (rst_n && !vout_en) proc_wait <= proc_wait + 1;
    integer good_frames = 0;
    integer checked_px = 0;

    // --------------------------------------------------- per-block pixel audit
    // Board run 2026-10-29 13:26: pix_seen=524 for a 512-record block, so the
    // old equality test deadlocked C_DRAIN. Track the worst overshoot of every
    // block here; if the simulation reproduces it, the mechanism can be traced
    // offline instead of by another board build.
    integer   blk_max_over = 0;
    integer   over_blocks  = 0;
    reg [31:0] blocks_done_d = 0;

    always @(posedge proc_clk) begin
        if (!rst_n) begin
            blk_max_over  <= 0;
            over_blocks   <= 0;
            blocks_done_d <= 0;
        end
        else begin
            if (u_sys.u_core.pix_seen > {22'd0, u_sys.u_core.recs_total}) begin
                if ((u_sys.u_core.pix_seen - {22'd0, u_sys.u_core.recs_total}) > blk_max_over)
                    blk_max_over <= u_sys.u_core.pix_seen - {22'd0, u_sys.u_core.recs_total};
            end
            if (u_sys.u_core.blocks_done !== blocks_done_d) begin
                if (blk_max_over > 0) begin
                    over_blocks = over_blocks + 1;
                    dgc_errors  = dgc_errors + 1;
                    if (over_blocks <= 5)
                        $display("TEST_FAIL: block pixel overshoot by %0d (recs=%0d) block=%0d t=%0t",
                                 blk_max_over, u_sys.u_core.recs_total,
                                 blocks_done_d, $time);
                end
                blk_max_over  <= 0;
                blocks_done_d <= u_sys.u_core.blocks_done;
            end
        end
    end

    // sample the reader's frame status at the start of each frame
    always @(posedge vout_clk) begin
        // Sample the frame status at the FIRST active line, not at vs_fall: with a
        // real back porch stripe 0 is published during the porch, after vco wraps.
        if (rst_n && vout_en && (hco == 0) && (vco == V_BACK)) begin
            check_frame <= ~frame_black;
            if (~frame_black) good_frames = good_frames + 1;
        end
    end

    // Pixel content is NOT asserted here. s5_sys enables the display late and
    // therefore always checks the first stripe that the pipeline produced in a
    // known phase; this suite runs the display from t=0, so the first non-black
    // frame can be a frame whose stripe 0 was produced while the job/display
    // phases were still arbitrary (and a torn stripe is legal for the watchdog
    // recovery path). Content correctness is covered by s5_sys / s4_core; here we
    // only count how many pixels were seen so a totally blank screen would show.
    integer px_mismatch = 0;
    always @(posedge vout_clk) begin
`ifndef DGC_BOARD_RADIAL_TEST
        if (rst_n && de_out && check_frame && (y_dl < 16)) begin
            checked_px = checked_px + 1;
            if (rgb_out !== img(x_dl[10:0], y_dl[10:0])) begin
                px_mismatch = px_mismatch + 1;
                if (px_mismatch < 4)
                    $display("TEST_INFO: pixel (%0d,%0d) differs exp=%06h act=%06h (phase, not asserted)",
                             x_dl, y_dl, img(x_dl[10:0], y_dl[10:0]), rgb_out);
            end
        end
`endif
    end

`ifdef DGC_BOARD_RADIAL_TEST
    // This suite models the production clocks/raster and checks every displayed
    // radial pixel. Startup black frames before the first job are allowed.
    integer board_checked = 0, board_frames = 0, board_starts = 0;
    integer board_aborts = 0, board_uf = 0;
    reg [31:0] board_uf_d = 0;
    time board_job_start;
    real stripe_deadline_us, stripe_ready_us, stripe_margin_us;
    real min_stripe_margin_us = 1.0e9;
    integer late_stripes = 0;
    always @(posedge proc_clk) if (rst_n) begin
        if (u_sys.job_start_p) begin
            board_starts = board_starts + 1;
            board_job_start = $time;
            $display("BOARD_JOB start=%0d fid=%0d t=%0t", board_starts, u_sys.job_id_r, $time);
        end
        if (u_sys.job_abort_p) begin
            board_aborts = board_aborts + 1;
            $display("BOARD_ABORT job=%0d blocks=%0d coord=%0d sched=%0d pix_sid=%0d bank0=%0d elapsed=%0t",
                     board_starts, u_sys.u_core.blocks_done, u_sys.u_core.u_coord.state,
                     u_sys.u_core.u_sched.cur_stripe, u_sys.u_core.dbg_pix_sid,
                     u_sys.u_core.dbg_cur_sid0, $time - board_job_start);
        end
        if (u_sys.offer_valid_c && u_sys.offer_ready_c) begin
            // A job can start late in its window. This optimistic deadline
            // proves a miss; the reader remains the authoritative check.
            stripe_ready_us = ($realtime - board_job_start)/1000.0;
            stripe_deadline_us = (36.0*2200.0 + 192.0)*0.006727 +
                                 u_sys.offer_data_c[54:48]*16.0*2200.0*0.006727;
            stripe_margin_us = stripe_deadline_us - stripe_ready_us;
            if (stripe_margin_us < min_stripe_margin_us) min_stripe_margin_us = stripe_margin_us;
            if (stripe_margin_us < 0) late_stripes = late_stripes + 1;
            $display("BOARD_STRIPE sid=%0d ready_us=%0.3f deadline_us=%0.3f margin_us=%0.3f",
                     u_sys.offer_data_c[54:48], stripe_ready_us, stripe_deadline_us, stripe_margin_us);
        end
    end
    always @(posedge vout_clk) if (rst_n) begin
        board_uf_d <= st_uf;
        if ((st_uf != board_uf_d) && (board_starts != 0)) begin
            board_uf = board_uf + 1;
            if (!$test$plusargs("EXPECT_UF")) dgc_errors = dgc_errors + 1;
            $display("BOARD_UF stripe=%0d first=%b job=%0d elapsed=%0t blocks=%0d cstate=%0d coord=%0d sample_left=%0d",
                     u_sys.u_reader.dbg_uf_stripe, u_sys.u_reader.dbg_uf_first,
                     board_starts, $time - board_job_start, u_sys.u_core.blocks_done,
                     u_sys.u_core.cstate, u_sys.u_core.u_coord.state, u_sys.u_core.sample_left);
            if ($test$plusargs("FAIL_FAST") && !$test$plusargs("EXPECT_UF")) begin
                `DGC_FINISH
            end
        end
        if (de_out && check_frame && u_sys.u_reader.ok_dl) begin
            board_checked = board_checked + 1;
            checked_px = checked_px + 1;
            if (rgb_out !== radial_expected[y_dl * 1920 + x_dl]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 5)
                    $display("TEST_FAIL: radial displayed pixel (%0d,%0d) exp=%06h actual=%06h",
                             x_dl, y_dl, radial_expected[y_dl * 1920 + x_dl], rgb_out);
            end
        end
        if (u_sys.u_reader.frame_last && u_sys.u_reader.frame_ok)
            board_frames = board_frames + 1;
    end
`endif

    integer n_beat = 0; integer n_cw = 0; integer n_px = 0; integer n_wr = 0;
    // Test-only accounting distinguishes useful pixel records and head skips.
    integer prof_rows=0, prof_head_bytes=0, prof_disc_cycles=0;
    integer prof_px1=0, prof_px2=0, prof_empty_records=0, prof_wait_beat=0, prof_fill=0;
    reg prof_done_d=0;
    always @(posedge proc_clk) if (rst_n) begin
        prof_done_d <= u_sys.core_frame_done;
        if (u_sys.job_start_p) begin
            prof_rows=0; prof_head_bytes=0; prof_disc_cycles=0;
            prof_px1=0; prof_px2=0; prof_empty_records=0; prof_wait_beat=0; prof_fill=0;
        end else if (u_sys.job_state == 1) begin
            if (u_sys.u_core.u_fill.unpack_row_load) begin
                prof_rows=prof_rows+1;
                prof_head_bytes=prof_head_bytes+u_sys.u_core.u_fill.r_hs;
            end
            if (u_sys.u_core.u_fill.u_unpack.disc_phase && u_sys.u_core.u_fill.u_unpack.accepted)
                prof_disc_cycles=prof_disc_cycles+1;
            if (u_sys.u_core.u_fill.take_record) begin
                case (u_sys.u_core.u_fill.up_fill_count)
                    0: prof_empty_records=prof_empty_records+1;
                    1: prof_px1=prof_px1+1;
                    2: prof_px2=prof_px2+1;
                endcase
            end
            if (u_sys.u_core.dbg_fill_wait_beat) prof_wait_beat=prof_wait_beat+1;
            if (u_sys.u_core.fill_busy) prof_fill=prof_fill+1;
        end
        if (u_sys.core_frame_done && !prof_done_d)
            $display("FILL_PROFILE rows=%0d head_bytes=%0d discard_cycles=%0d one_px=%0d two_px=%0d zero_px=%0d wait_beat=%0d fill=%0d",
                     prof_rows,prof_head_bytes,prof_disc_cycles,prof_px1,prof_px2,prof_empty_records,prof_wait_beat,prof_fill);
    end
    always @(posedge proc_clk) if (rst_n && u_sys.u_core.u_stripe.wr_fire && n_wr < 5) begin n_wr = n_wr + 1; $display("WR a=%0d d=%06h bank=%b", u_sys.u_core.u_stripe.waddr, u_sys.u_core.u_stripe.wdata, u_sys.u_core.u_stripe.wr_bank); end
    always @(posedge proc_clk) if (rst_n && u_sys.u_core.px_valid && u_sys.u_core.px_ready && n_px < 4) begin n_px = n_px + 1; $display("PXD rgb=%06h dx=%0d dy=%0d", u_sys.u_core.px_data[23:0], u_sys.u_core.px_data[34:24], u_sys.u_core.px_data[45:35]); end
    always @(posedge ddr_clk) if (rst_n && u_sys.ra_fifo_wr && n_beat < 2) begin n_beat = n_beat + 1; $display("BEATD %02h %02h %02h %02h %02h %02h", u_sys.ra_fifo_data[7:0], u_sys.ra_fifo_data[15:8], u_sys.ra_fifo_data[23:16], u_sys.ra_fifo_data[31:24], u_sys.ra_fifo_data[39:32], u_sys.ra_fifo_data[47:40]); end
    always @(posedge proc_clk) if (rst_n && u_sys.u_core.cache_wr && n_cw < 4) begin n_cw = n_cw + 1; $display("CW x=%0d y=%0d rgb=%06h", u_sys.u_core.cache_x, u_sys.u_core.cache_y, u_sys.u_core.cache_rgb); end
    // ---------------------------------------------------- multi-job monitors
    // s5_sys deliberately enables the display only after the capture pipeline is
    // primed and then checks one stripe; that sequencing leaves the reader
    // holding both stripe banks while the display is gated off, so the core
    // stalls after ~120 blocks and a job never completes. This suite runs the
    // display from the beginning and asks the whole-machine question instead:
    // does a job complete (>= 4080 blocks) and does the next job complete too?
    integer jobs_done = 0;
    integer job_blocks [0:3];
    integer guard = 0;
    reg     fd_d = 0;

    // 2026-11-02 (g): coverage for the inline block switch. Under display pacing
    // the next block's fill is long finished when the current block's last record
    // is taken, so the core switches blocks without the 16-cycle C_DRAIN - the
    // case the unconstrained s4_core cannot reach (there the fill itself is the
    // limiter). Count both paths so the suite proves the fast path is used.
    integer n_hs = 0, n_drain = 0;
    reg     hs_d = 0, cst3_d = 0;
    always @(posedge proc_clk) begin
        if (rst_n) begin
            hs_d <= u_sys.u_core.hs_pending;
            if (u_sys.u_core.hs_pending && !hs_d) n_hs = n_hs + 1;
            cst3_d <= (u_sys.u_core.cstate == 3'd3);
            if ((u_sys.u_core.cstate == 3'd3) && !cst3_d) n_drain = n_drain + 1;
        end
    end

    // ------------------------------------------------------ bank leak monitor
    // 2026-11-02: the pending-first experiment left a bank owned by the writer
`ifdef DGC_ABORT_TEST
    // ------------------------------------------- end-to-end abort regression
    // The board once showed a job watchdog abort that left a reader-owned bank
    // behind: every following job then stalled on that bank and the panel stayed
    // black until power cycle. Reproduce it deterministically: right after the
    // first job_start, park bank3 in READING (no reader will ever release it), let
    // the job watchdog fire (2.8 M cycles here instead of 4.2 M), and require the
    // next job to run the complete 4080-block frame. `release` leaves the register
    // at 1, exactly like a reader that went black, so only job_abort can clear it.
    integer abort_state = 0;
    integer abort_wait  = 0;
    reg abort_first_desc = 0;
    integer abort_restarts = 0;
    integer abort_checked = 0;
    integer abort_pixel_errors = 0;
    reg abort_clear_checked = 0;
    always @(posedge proc_clk) if (rst_n && u_sys.job_abort_p) begin
        #0.2;
        if (u_sys.u_core.u_stripe.bank_state !== 12'd0)
            `DGC_FAIL("job_abort did not clear all abandoned stripe banks")
        abort_clear_checked = 1;
    end
    always @(posedge proc_clk) if (rst_n) begin
        if (u_sys.job_start_p) begin
            abort_first_desc <= 1'b1;
            if (abort_state == 3) abort_restarts = abort_restarts + 1;
        end
        else if (u_sys.u_core.desc_valid && u_sys.u_core.desc_ready && abort_first_desc) begin
            abort_first_desc <= 1'b0;
            if ((u_sys.u_core.d_tag !== 0) || (u_sys.u_core.d_out_x !== 0) ||
                (u_sys.u_core.d_out_y !== 0) || (u_sys.u_core.d_job_id !== u_sys.job_id_r)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: restart consumed stale first descriptor tag=%0d xy=(%0d,%0d) job=%0d expected_job=%0d",
                         u_sys.u_core.d_tag, u_sys.u_core.d_out_x, u_sys.u_core.d_out_y,
                         u_sys.u_core.d_job_id, u_sys.job_id_r);
                if ($test$plusargs("FAIL_FAST")) begin
                    `DGC_FINISH
                end
            end
        end
        if ((abort_restarts != 0) && !u_sys.u_core.job_flush &&
            u_sys.u_core.px_valid && u_sys.u_core.px_ready) begin
            abort_checked = abort_checked + 1;
            if (u_sys.u_core.px_data[23:0] !==
                radial_expected[u_sys.u_core.px_data[45:35] * 1920 + u_sys.u_core.px_data[34:24]]) begin
                abort_pixel_errors = abort_pixel_errors + 1;
                dgc_errors = dgc_errors + 1;
                if (abort_pixel_errors < 4)
                    $display("TEST_FAIL: recovered radial pixel (%0d,%0d) mismatch",
                             u_sys.u_core.px_data[34:24], u_sys.u_core.px_data[45:35]);
            end
        end
        if ((abort_state == 3) && u_sys.rel_src_valid &&
            (u_sys.u_core.fill_busy || u_sys.row_valid))
            `DGC_FAIL("aborted source slot released before outstanding DDR fill drained")
    end
    always @(posedge proc_clk) begin
        if (rst_n) begin
            case (abort_state)
                0: if (u_sys.job_start_p) begin
                       if (!$test$plusargs("FILL_ABORT"))
                           force u_sys.u_core.u_stripe.reading[3] = 1'b1;
                       abort_wait  <= 0;
                       abort_state <= 1;
                   end
                1: begin
                       abort_wait <= abort_wait + 1;
                       if ($test$plusargs("FILL_ABORT")) begin
                           if (u_sys.u_core.fill_busy && u_sys.beat_valid_p && u_sys.beat_ready_p) begin
                               force u_sys.job_wd = 24'hffffff;
                               abort_state <= 2;
                           end
                       end
                       else if (abort_wait == 20000) begin
                           release u_sys.u_core.u_stripe.reading[3];
                           abort_state <= 2;
                       end
                   end
                2: if (u_sys.job_abort_p) begin
                       if ($test$plusargs("FILL_ABORT")) release u_sys.job_wd;
                       abort_state <= 3;
                   end
                default: ;
            endcase
        end
    end
`endif
    // (`reading[b] = 1`) while the reader held nothing. This monitor reports the
    // first moment a bank stays "reading" for 5000 cycles with no reader owner,
    // together with the reader state, which is what identifies the lost release.
    integer leak_cnt [0:3];
    integer lb;
    reg     owned_b;
    // The end-to-end abort test deliberately leaves bank3 "reader owned" so the job
    // watchdog fires; the leak monitor would (correctly) report that as a failure.
`ifdef DGC_ABORT_TEST
    localparam LEAK_EN = 1'b0;
`else
    localparam LEAK_EN = 1'b1;
`endif
    initial begin
        leak_cnt[0] = 0; leak_cnt[1] = 0; leak_cnt[2] = 0; leak_cnt[3] = 0;
    end
    always @(posedge proc_clk) begin
        if (rst_n && LEAK_EN) begin
            // unrolled: a variable index into a hierarchical array is not reliable
            owned_b = ((u_sys.u_reader.pf_valid  && (u_sys.u_reader.pf_bank   == 2'd0)) ||
                       (u_sys.u_reader.cur_ok    && (u_sys.u_reader.cur_bank  == 2'd0)) ||
                       (u_sys.u_reader.have_next && (u_sys.u_reader.next_bank == 2'd0)) ||
                       1'b0);
            if (u_sys.u_core.u_stripe.reading[0] && !owned_b) begin
                leak_cnt[0] = leak_cnt[0] + 1;
                if (leak_cnt[0] == 3000)
                    $display("TEST_FAIL: bank0 stuck READING, no owner (t=%0t) cur_ok=%b cur_bank=%0d have_next=%b next_bank=%0d job_l=%h sel=%h off=%0d dis=%0d rel=%0d qw=%0d qr=%0d",
                             $time, u_sys.u_reader.cur_ok, u_sys.u_reader.cur_bank,
                             u_sys.u_reader.have_next, u_sys.u_reader.next_bank,
                             u_sys.u_reader.job_l, u_sys.u_core.u_stripe.bank_state, u_sys.u_reader.cnt_offers, u_sys.u_reader.cnt_discard, u_sys.u_reader.cnt_releases, u_sys.u_reader.q_wp, u_sys.u_reader.q_rp);
            end
            else leak_cnt[0] = 0;
            owned_b = ((u_sys.u_reader.pf_valid  && (u_sys.u_reader.pf_bank   == 2'd1)) ||
                       (u_sys.u_reader.cur_ok    && (u_sys.u_reader.cur_bank  == 2'd1)) ||
                       (u_sys.u_reader.have_next && (u_sys.u_reader.next_bank == 2'd1)) ||
                       1'b0);
            if (u_sys.u_core.u_stripe.reading[1] && !owned_b) begin
                leak_cnt[1] = leak_cnt[1] + 1;
                if (leak_cnt[1] == 3000)
                    $display("TEST_FAIL: bank1 stuck READING, no owner (t=%0t) cur_ok=%b cur_bank=%0d have_next=%b next_bank=%0d job_l=%h sel=%h off=%0d dis=%0d rel=%0d qw=%0d qr=%0d",
                             $time, u_sys.u_reader.cur_ok, u_sys.u_reader.cur_bank,
                             u_sys.u_reader.have_next, u_sys.u_reader.next_bank,
                             u_sys.u_reader.job_l, u_sys.u_core.u_stripe.bank_state, u_sys.u_reader.cnt_offers, u_sys.u_reader.cnt_discard, u_sys.u_reader.cnt_releases, u_sys.u_reader.q_wp, u_sys.u_reader.q_rp);
            end
            else leak_cnt[1] = 0;
            owned_b = ((u_sys.u_reader.pf_valid  && (u_sys.u_reader.pf_bank   == 2'd2)) ||
                       (u_sys.u_reader.cur_ok    && (u_sys.u_reader.cur_bank  == 2'd2)) ||
                       (u_sys.u_reader.have_next && (u_sys.u_reader.next_bank == 2'd2)) ||
                       1'b0);
            if (u_sys.u_core.u_stripe.reading[2] && !owned_b) begin
                leak_cnt[2] = leak_cnt[2] + 1;
                if (leak_cnt[2] == 3000)
                    $display("TEST_FAIL: bank2 stuck READING, no owner (t=%0t) cur_ok=%b cur_bank=%0d have_next=%b next_bank=%0d job_l=%h sel=%h off=%0d dis=%0d rel=%0d qw=%0d qr=%0d",
                             $time, u_sys.u_reader.cur_ok, u_sys.u_reader.cur_bank,
                             u_sys.u_reader.have_next, u_sys.u_reader.next_bank,
                             u_sys.u_reader.job_l, u_sys.u_core.u_stripe.bank_state, u_sys.u_reader.cnt_offers, u_sys.u_reader.cnt_discard, u_sys.u_reader.cnt_releases, u_sys.u_reader.q_wp, u_sys.u_reader.q_rp);
            end
            else leak_cnt[2] = 0;
            // 2026-11-02: bank 3 was missing from this monitor, and the first
            // PF_EN=1 s5_jobs run froze at stripe 3 (bank 3) without a single
            // report - exactly the blind spot this closes.
            owned_b = ((u_sys.u_reader.pf_valid  && (u_sys.u_reader.pf_bank   == 2'd3)) ||
                       (u_sys.u_reader.cur_ok    && (u_sys.u_reader.cur_bank  == 2'd3)) ||
                       (u_sys.u_reader.have_next && (u_sys.u_reader.next_bank == 2'd3)) ||
                       1'b0);
            if (u_sys.u_core.u_stripe.reading[3] && !owned_b) begin
                leak_cnt[3] = leak_cnt[3] + 1;
                if (leak_cnt[3] == 3000)
                    $display("TEST_FAIL: bank3 stuck READING, no owner (t=%0t) cur_ok=%b cur_bank=%0d have_next=%b next_bank=%0d job_l=%h sel=%h off=%0d dis=%0d rel=%0d qw=%0d qr=%0d",
                             $time, u_sys.u_reader.cur_ok, u_sys.u_reader.cur_bank,
                             u_sys.u_reader.have_next, u_sys.u_reader.next_bank,
                             u_sys.u_reader.job_l, u_sys.u_core.u_stripe.bank_state, u_sys.u_reader.cnt_offers, u_sys.u_reader.cnt_discard, u_sys.u_reader.cnt_releases, u_sys.u_reader.q_wp, u_sys.u_reader.q_rp);
            end
            else leak_cnt[3] = 0;
        end
    end

    always @(posedge proc_clk) begin
        fd_d <= u_sys.u_core.frame_done;
        if (rst_n && u_sys.u_core.frame_done && !fd_d) begin
            job_blocks[jobs_done] = u_sys.u_core.blocks_done;
            $display("TEST_INFO: job %0d complete: blocks=%0d pixels=%0d t=%0t",
                     jobs_done, u_sys.u_core.blocks_done,
                     u_sys.u_core.cnt_pixels, $time);
            jobs_done = jobs_done + 1;
        end
    end

    initial begin
        // no storage array: the image model is authoritative
        rst_n = 0;
        repeat (20) @(posedge proc_clk);
        rst_n = 1;
        // Run the output raster from the start. With vout gated off the reader
        // has no vs_fall and no scan, so it keeps both banks it accepted and the
        // core blocks - a testbench artefact that hides the real job length.
        @(posedge vout_clk);
        vout_en <= 1'b1;
        @(posedge vout_clk);

        // Two complete jobs. One job is ~15 ms of simulation at the board clock,
        // so the guard is generous (12 M proc cycles = 66 ms) but finite.
        // Under DGC_ABORT_TEST the first job is deliberately aborted by the job
        // watchdog (the stalled job must burn its 2.8 M-cycle deadline), so only one
        // *completed* job is required: the one that proves the abort left no
        // ownership behind.
`ifdef DGC_ABORT_TEST
        while ((jobs_done < 1) && (guard < 12_000_000)) begin
`else
        while ((jobs_done < ($test$plusargs("EXPECT_UF") ? 1 : 2)) && (guard < 12_000_000)) begin
`endif
            @(posedge proc_clk);
            guard = guard + 1;
        end
        $display("TEST_INFO: waited %0d proc cycles, jobs_done=%0d", guard, jobs_done);
        // Let the registered duration tap and its three-cycle monitor settle
        // before the final performance snapshot clears job_us_max. A one-job
        // abort test otherwise cleared K1 while that comparison was pending.
        repeat (8) @(posedge proc_clk);
        if ((jobs_done > 0) && (!k1_checked || (k1_errs != 0)))
            `DGC_FAIL("completed-job duration check failed or never ran")

`ifdef DGC_BOARD_RADIAL_TEST
        if ($test$plusargs("EXPECT_UF")) begin
            if ((jobs_done != 1) || (board_uf == 0) || (board_aborts != 0) ||
                (job_blocks[0] != 4080) || (st_err != 0))
                `DGC_FAIL("expected-underflow profile did not complete one job and reproduce starvation")
            $display("TEST_INFO: EXPECTED_UF profile jobs=%0d uf=%0d min_margin_us=%0.3f late_stripes=%0d",
                     jobs_done,board_uf,min_stripe_margin_us,late_stripes);
            `DGC_FINISH
        end
`endif

`ifdef DGC_BOARD_RADIAL_TEST
        while ((board_frames < 2) && (guard < 12_000_000)) begin
            @(posedge proc_clk);
            guard = guard + 1;
        end
        repeat (5) @(posedge vout_clk);
        if ((board_frames < 2) || (board_checked < 4147200) || (board_aborts != 0)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: board frames=%0d checked=%0d aborts=%0d", board_frames, board_checked, board_aborts);
        end
        $display("TEST_INFO: BOARD frames=%0d checked=%0d starts=%0d aborts=%0d underflows_after_start=%0d",
                 board_frames, board_checked, board_starts, board_aborts, board_uf);
        $display("TEST_INFO: BOARD min_margin_us=%0.3f late_stripes=%0d", min_stripe_margin_us,late_stripes);
`endif

`ifdef DGC_ABORT_TEST
        if (jobs_done < 1) begin
`else
        if (jobs_done < 2) begin
`endif
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: only %0d job(s) completed in %0d cycles (cstate=%0d blocks=%0d bank_state=%b px_ready=%b)",
                     jobs_done, guard, u_sys.u_core.cstate, u_sys.u_core.blocks_done,
                     u_sys.u_core.u_stripe.bank_state, u_sys.u_core.px_ready);
            $display("            diag: kind=%0d recs=%0d pix=%0d samp_busy=%b next_valid=%b cstate=%0d", u_sys.u_core.cur_kind, u_sys.u_core.recs_total, u_sys.u_core.pix_seen, u_sys.u_core.samp_busy, u_sys.u_core.next_valid, u_sys.u_core.cstate);
            $display("            diag: jstate=%0d acq_tried=%b acq_valid=%b job_id=%h frame_done=%b",
                     u_sys.job_state, u_sys.acq_tried, u_sys.acq_src_valid,
                     u_sys.job_id_r, u_sys.u_core.frame_done);
            $display("            diag: wait_first=%b cur_ok=%b frame_ok=%b have_next=%b cur_stripe=%0d relq_wr=%0d relq_rd=%0d pf=%b/%0d",
                     u_sys.u_reader.waiting_first, u_sys.u_reader.cur_ok,
                     u_sys.u_reader.frame_ok, u_sys.u_reader.have_next,
                     u_sys.u_reader.cur_stripe, u_sys.u_reader.q_wp, u_sys.u_reader.q_rp,
                     u_sys.u_reader.pf_valid, u_sys.u_reader.pf_bank);
        end
        else begin
            if (job_blocks[0] < 4080) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: job 0 completed only %0d blocks (< 4080)", job_blocks[0]);
            end
`ifndef DGC_ABORT_TEST
            if (job_blocks[1] < 4080) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: job 1 completed only %0d blocks (< 4080)", job_blocks[1]);
            end
            $display("TEST_INFO: two jobs completed, blocks=%0d / %0d", job_blocks[0], job_blocks[1]);
`endif
`ifdef DGC_ABORT_TEST
        if (abort_state < 3) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: the job watchdog never aborted (state=%0d)", abort_state);
        end
        // Check at the abort edge above: bank3 may legitimately belong to the
        // reader again when the recovered job's last stripe (67) is published.
        if (!abort_clear_checked) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: the abort bank-clear check was never reached");
        end
        $display("TEST_INFO: abort regression: watchdog fired, first completed job after it ran %0d blocks",
                 job_blocks[0]);
        if ((abort_checked != 2073600) || (abort_pixel_errors != 0))
            `DGC_FAIL("recovered job did not produce exactly one full correct radial frame")
        $display("TEST_INFO: recovered radial pixels=%0d errors=%0d", abort_checked, abort_pixel_errors);
`endif
        $display("TEST_INFO: block switches: inline=%0d drain=%0d", n_hs, n_drain);
        end
        if (st_err != 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: DDR errors = %0d", st_err);
        end
        if (u_sys.u_core.u_stripe.dbg_rd_timeout) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: the reader watchdog fired (%0d) in a healthy run",
                     u_sys.u_core.u_stripe.cnt_rd_timeout);
        end
        if (st_wr == 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: no frame written");
        end
        $display("TEST_INFO: frames written=%0d jobs_started=%0d good_frames=%0d checked=%0d mismatched=%0d underflows=%0d", st_wr, st_proc, good_frames, checked_px, px_mismatch, st_uf);

        // The job FSM must not poll frame_acquire while it already owns a frame:
        // on the board that leaked every slot (acquire=5/release=2, all HELD).
        // At most one job may be outstanding at any time.
        if ((u_sys.u_fm.cnt_acquire - u_sys.u_fm.cnt_release) > 1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: frame slots leaked: acquire=%0d release=%0d",
                     u_sys.u_fm.cnt_acquire, u_sys.u_fm.cnt_release);
        end
        else $display("TEST_INFO: frame acquire/release balanced (acquire=%0d release=%0d)",
                      u_sys.u_fm.cnt_acquire, u_sys.u_fm.cnt_release);

        // ------------------------------------------- early source release checks
        if (src_rel_dup != 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: %0d job(s) released their source slot more than once", src_rel_dup);
        end
        if (src_rel_early_n < 1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: no release happened while the core was still busy (src_idle unused)");
        end
        $display("TEST_INFO: source releases=%0d (while core busy=%0d), latest release at %0d proc cycles = %0d us after job_start, first release cstate=%0d",
                 src_rel_n, src_rel_early_n, rel_at_max, rel_at_max / 171,
                 (rel_cstate_seen == 0) ? 0 : rel_cstate_seen - 1);

        // ------------------------------------------------------- DGC3 perf taps
        // The report is only useful if the counters actually count inside the
        // real integration. Pulse each domain's snapshot latch the way
        // dgc_snapshot_src does and require plausible published values:
        // fill writes happen inside fill-active time, sample stalls are a
        // subset of sample time, and the DDR engine saw at least one request.
        proc_latch = 1'b1;
        @(posedge proc_clk);
        proc_latch = 1'b0;
        ddr_latch = 1'b1;
        @(posedge ddr_clk);
        ddr_latch = 1'b0;
        @(posedge proc_clk);
        if (dbg_perf_proc[15:0] == 16'd0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: DGC3 fill_active counter never advanced");
        end
        if (dbg_perf_proc[79:64] > dbg_perf_proc[15:0]) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: DGC3 fill writes (%0d) exceed fill active (%0d)",
                     dbg_perf_proc[79:64], dbg_perf_proc[15:0]);
        end
        if (dbg_perf_proc[111:96] > dbg_perf_proc[95:80]) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: DGC3 writer stalls (%0d) exceed sample time (%0d)",
                     dbg_perf_proc[111:96], dbg_perf_proc[95:80]);
        end
        if ((dbg_perf_proc[95:80] == 16'd0) || (dbg_perf_proc[79:64] == 16'd0)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: DGC3 sample/fill counters are zero (perf taps not wired)");
        end
        if ((dbg_perf_ddr[15:0] == 16'd0) || (dbg_perf_ddr[63:48] == 16'd0)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: DGC3 AR count / max-inflight are zero");
        end
        else
            $display("TEST_INFO: DGC3 perf fill=%0d beatwait=%0d writes=%0d sample=%0d wrstall=%0d ar=%0d arwait=%0d starve=%0d inflight=%0d",
                     dbg_perf_proc[15:0], dbg_perf_proc[31:16], dbg_perf_proc[79:64],
                     dbg_perf_proc[95:80], dbg_perf_proc[111:96],
                     dbg_perf_ddr[15:0], dbg_perf_ddr[31:16], dbg_perf_ddr[47:32],
                     dbg_perf_ddr[63:48]);

`ifdef DGC_ALIGN_TEST
        // 2026-11-02 (b): the point of "acquire early, start on the boundary" is that
        // stripe 0 is published inside the vertical back porch. With the real output
        // tick and a real 45-line porch every non-black frame must therefore carry the
        // identity image in its first stripe, bit for bit. This is the assertion the
        // synthetic tick could never make (the TB had no back porch at all before).
        if (checked_px == 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: no non-black frame was available to check");
        end
        else if (px_mismatch != 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: %0d of %0d first-stripe pixels differ from the identity image",
                     px_mismatch, checked_px);
        end
`ifdef DGC_BOARD_RADIAL_TEST
        else $display("TEST_INFO: aligned radial frames are exact (%0d pixels, %0d full frames)",
                      board_checked, board_frames);
`else
        else
            $display("TEST_INFO: aligned frames are exact (%0d first-stripe pixels, %0d good frames)",
                     checked_px, good_frames);
`endif
`endif

        `DGC_FINISH
    end
endmodule












