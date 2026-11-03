//-----------------------------------------------------------------------------
// tb_map_pipeline.v - S1 acceptance: map_pipeline against the golden model
//
// Two phases, both driven from files produced by model/gen_vectors.py:
//
//   P1  mode 0 identity sweep (42,625 records): every coordinate must be bit
//       exact, weight zero, sample_ok 1.
//   P2  mode 1 static k1/k2 over a whole 1920x1080 frame (2,073,600 records):
//       every sx0/sy0/wx/wy/sample_ok/math_error must match the golden model.
//
// The producer and the consumer are decoupled through a small scoreboard queue,
// and the consumer applies pseudo-random backpressure, so the pipeline stall path
// is exercised on real data instead of only in a directed test.
//
// Metadata pass-through is checked at the same time: tile_tag is driven as
// {5'b0, dst_y} and tile_last as (dst_x == 1919), so a metadata misalignment
// anywhere in the nine stages is caught.
//
// Plusargs
//   +LIMIT=<n>   stop after n records of phase 2 (default: whole frame)
//   +SEED=<n>    seed for the consumer backpressure (default 1)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_map_pipeline;

    integer dgc_errors = 0;

    reg clk = 0;
    always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    // ---------------------------------------------------------- configuration
    // Real calibration, quantised exactly as 接口常量_v1.json records it.
    localparam signed [31:0] FX_Q  = 32'sd137377855;
    localparam signed [31:0] FY_Q  = 32'sd138692973;
    localparam signed [31:0] CX_Q  = 32'sd64030536;
    localparam signed [31:0] CY_Q  = 32'sd34085643;
    localparam signed [31:0] K1_Q  = -32'sd129279204;
    localparam signed [31:0] K2_Q  = 32'sd74679738;

    // Default M from K, also exactly as 接口常量_v1.json records it.
    localparam signed [31:0] M00_Q = 32'sd32014;
    localparam signed [31:0] M01_Q = 32'sd0;
    localparam signed [31:0] M02_Q = -32'sd31278815;
    localparam signed [31:0] M10_Q = 32'sd0;
    localparam signed [31:0] M11_Q = 32'sd31711;
    localparam signed [31:0] M12_Q = -32'sd16492896;
    localparam        [31:0] NORM_Q = 32'd134217728;

    reg  [1:0]  cfg_mode;

    // ------------------------------------------------------------ DUT signals
    wire        in_ready;
    reg         in_valid = 0;
    reg  [10:0] in_dst_x = 0;
    reg  [10:0] in_dst_y = 0;
    reg  [15:0] in_tile_tag = 0;
    reg         in_tile_last = 0;

    wire        out_valid;
    reg         out_ready = 1;
    wire [95:0] out_coord;

    dgc_map_pipeline u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_mode         (cfg_mode),
        .cfg_m00          (M00_Q),
        .cfg_m01          (M01_Q),
        .cfg_m02          (M02_Q),
        .cfg_m10          (M10_Q),
        .cfg_m11          (M11_Q),
        .cfg_m12          (M12_Q),
        .cfg_fx           (FX_Q),
        .cfg_fy           (FY_Q),
        .cfg_cx           (CX_Q),
        .cfg_cy           (CY_Q),
        .cfg_k1           (K1_Q),
        .cfg_k2           (K2_Q),
        .cfg_norm_abs_max (NORM_Q),
        .in_valid         (in_valid),
        .in_ready         (in_ready),
        .in_dst_x         (in_dst_x),
        .in_dst_y         (in_dst_y),
        .in_tile_tag      (in_tile_tag),
        .in_tile_last     (in_tile_last),
        .out_valid        (out_valid),
        .out_ready        (out_ready),
        .out_coord        (out_coord)
    );

    // ------------------------------------------------------------- scoreboard
    localparam integer QN = 64;
    integer q_dx  [0:QN-1];
    integer q_dy  [0:QN-1];
    integer q_sx0 [0:QN-1];
    integer q_sy0 [0:QN-1];
    integer q_wx  [0:QN-1];
    integer q_wy  [0:QN-1];
    integer q_ok  [0:QN-1];
    integer q_me  [0:QN-1];
    integer q_wp = 0, q_rp = 0;

    integer seed = 1;
    integer rdy_r;

    always @(posedge clk) begin
        rdy_r = ({$random(seed)} % 100);
        if (rdy_r < 8 && !out_ready) out_ready <= 1'b1;
        else if (rdy_r < 8)          out_ready <= 1'b0;
    end

    integer n_checked = 0;

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            if (q_rp == q_wp) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: map_pipeline produced a record nobody asked for t=%0t", $time);
            end
            else begin
                if (out_coord[10:0] !== q_dx[q_rp][10:0]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: dst_x mismatch exp=%0d act=%0d t=%0t",
                             q_dx[q_rp], out_coord[10:0], $time);
                end
                if (out_coord[21:11] !== q_dy[q_rp][10:0]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: dst_y mismatch exp=%0d act=%0d t=%0t",
                             q_dy[q_rp], out_coord[21:11], $time);
                end
                if (out_coord[32:22] !== q_sx0[q_rp][10:0]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 30)
                    $display("TEST_FAIL: sx0 mismatch exp=%0d act=%0d at (%0d,%0d) t=%0t",
                             q_sx0[q_rp], out_coord[32:22], q_dx[q_rp], q_dy[q_rp], $time);
                end
                if (out_coord[43:33] !== q_sy0[q_rp][10:0]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 30)
                    $display("TEST_FAIL: sy0 mismatch exp=%0d act=%0d at (%0d,%0d) t=%0t",
                             q_sy0[q_rp], out_coord[43:33], q_dx[q_rp], q_dy[q_rp], $time);
                end
                if (out_coord[59:44] !== q_wx[q_rp][15:0]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 30)
                    $display("TEST_FAIL: wx mismatch exp=%0d act=%0d at (%0d,%0d) t=%0t",
                             q_wx[q_rp], out_coord[59:44], q_dx[q_rp], q_dy[q_rp], $time);
                end
                if (out_coord[75:60] !== q_wy[q_rp][15:0]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 30)
                    $display("TEST_FAIL: wy mismatch exp=%0d act=%0d at (%0d,%0d) t=%0t",
                             q_wy[q_rp], out_coord[75:60], q_dx[q_rp], q_dy[q_rp], $time);
                end
                if (out_coord[92] !== q_ok[q_rp][0]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: sample_ok mismatch exp=%0d act=%0d at (%0d,%0d) t=%0t",
                             q_ok[q_rp], out_coord[92], q_dx[q_rp], q_dy[q_rp], $time);
                end
                if (out_coord[93] !== q_me[q_rp][0]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: math_error mismatch exp=%0d act=%0d at (%0d,%0d) t=%0t",
                             q_me[q_rp], out_coord[93], q_dx[q_rp], q_dy[q_rp], $time);
                end
                if (out_coord[91:76] !== {5'b0, q_dy[q_rp][10:0]}) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: tile_tag mismatch exp=%0d act=%0d t=%0t",
                             q_dy[q_rp], out_coord[91:76], $time);
                end
                if (out_coord[94] !== (q_dx[q_rp] == 1919)) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: tile_last mismatch at (%0d,%0d) t=%0t",
                             q_dx[q_rp], q_dy[q_rp], $time);
                end
                if (out_coord[95] !== 1'b0) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: reserved bit [95] is not zero t=%0t", $time);
                end

                q_rp = (q_rp + 1) % QN;
                n_checked = n_checked + 1;
            end
        end
    end

    // ---------------------------------------------------------------- helpers
    reg [8*260-1:0] line_buf;
    integer fd, rc;
    integer v_dx, v_dy, v_sx0, v_sy0, v_wx, v_wy, v_ok, v_me;
    integer limit, sent_total;
    reg [8*260-1:0] vec0_path;
    reg [8*260-1:0] vec1_path;

    task push_q(input integer dx, input integer dy,
                input integer sx0, input integer sy0,
                input integer wx,  input integer wy,
                input integer ok,  input integer me);
        begin
            q_dx [q_wp] = dx;  q_dy [q_wp] = dy;
            q_sx0[q_wp] = sx0; q_sy0[q_wp] = sy0;
            q_wx [q_wp] = wx;  q_wy [q_wp] = wy;
            q_ok [q_wp] = ok;  q_me [q_wp] = me;
            q_wp = (q_wp + 1) % QN;
        end
    endtask

    // Drive one record and enqueue its expectation. in_ready is combinational
    // from the current pipeline state and is stable inside a cycle, so sampling
    // it here and firing in the same cycle is safe.
    task drive_one(input integer dx, input integer dy);
        begin
            while (!in_ready) begin @(posedge clk); #0.2; end
            in_valid     <= 1'b1;
            in_dst_x     <= dx[10:0];
            in_dst_y     <= dy[10:0];
            in_tile_tag  <= {5'b0, dy[10:0]};
            in_tile_last <= (dx == 1919);
            @(posedge clk); #0.2;
            in_valid     <= 1'b0;
        end
    endtask

    integer sent, idx;

    task run_phase(input [8*260-1:0] path, input integer mode, input integer max_rec);
        begin
            sent = 0;
            in_valid = 0;
            cfg_mode = mode[1:0];

            fd = $fopen(path, "r");
            if (fd == 0) begin
                `DGC_FAIL("could not open vector file")
            end
            else begin
                rc = $fgets(line_buf, fd);
                rc = $fgets(line_buf, fd);
                rc = $fgets(line_buf, fd);
                idx = 0;
                while (!$feof(fd)) begin
                    rc = $fscanf(fd, "%d %d %d %d %d %d %d %d\n",
                                 v_dx, v_dy, v_sx0, v_sy0, v_wx, v_wy, v_ok, v_me);
                    if (rc == 8) begin
                        push_q(v_dx, v_dy, v_sx0, v_sy0, v_wx, v_wy, v_ok, v_me);
                        drive_one(v_dx, v_dy);
                        sent = sent + 1;
                        idx  = idx  + 1;
                        if (max_rec > 0 && sent >= max_rec) begin
                            $fclose(fd);
                            sent = -sent;          // signals "truncated" to caller
                            disable run_phase;
                        end
                    end
                end
                $fclose(fd);
            end
        end
    endtask

    integer got0, got1;

    // -------------------------------------------------------------------- main
    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("LIMIT=%d", limit)) limit = 0;
        if (!$value$plusargs("VEC0=%s", vec0_path))
            vec0_path = "../../sim/s1_map_pipeline/vectors/coords_mode0_sweep.vec";
        if (!$value$plusargs("VEC1=%s", vec1_path))
            vec1_path = "../../sim/s1_map_pipeline/vectors/coords_mode1_full.vec";

        cfg_mode = 2'd0;
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (6) @(posedge clk);

        // ================================================================ P1
        $display("TEST_INFO: P1 starting identity sweep");
        run_phase(vec0_path, 0, 0);
        got0 = sent;
        repeat (60) @(posedge clk);
        if (n_checked == 0) `DGC_FAIL("P1: no record checked")
        $display("TEST_INFO: P1 identity sweep: %0d sent, %0d checked, %0d errors",
                 got0, n_checked, dgc_errors);

        // ================================================================ P2
        $display("TEST_INFO: P2 starting static k1/k2 full frame");
        run_phase(vec1_path, 1, limit);
        got1 = sent;
        repeat (200) @(posedge clk);
        if (n_checked == 0) `DGC_FAIL("P2: no record checked")
        $display("TEST_INFO: P2 static k1/k2: %0d sent, %0d checked total, %0d errors",
                 (got1 < 0 ? -got1 : got1), n_checked, dgc_errors);

        if ((got1 >= 0) && (n_checked != got0 + got1)) begin
            `DGC_FAIL("not every sent record was checked")
        end

        `DGC_FINISH
    end

endmodule
