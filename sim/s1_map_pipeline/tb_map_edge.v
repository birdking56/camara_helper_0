//-----------------------------------------------------------------------------
// tb_map_edge.v - S1 directed boundary and error cases for map_pipeline
//
// The full-frame test proves the arithmetic, but it only ever sees one benign
// parameter set where everything is legal. This test drives the parameter inputs
// directly to exercise the flag logic that the frozen spec defines:
//
//   E1  identity mode: coordinate exact, weight zero, math_error forced to 0
//       even when the submitted M would be nonsense
//   E2  norm_abs_max exceeded  -> math_error = 1, sample_ok = 0, fields zero
//   E3  mapped coordinate outside the source image -> sample_ok = 0 but
//       math_error = 0 (the spec is explicit that an out-of-range coordinate is
//       not an arithmetic error)
//   E4  negative mapped coordinate -> same as E3
//   E5  radial overflow (absurd k2) -> math_error = 1, sample_ok = 0
//   E6  corner pixels of the real configuration -> sample_ok = 1 and the exact
//       expected coordinate, including the last pixel of the frame
//
// Every expected value below is either structural (a flag policy) or taken from
// model/s1_pipeline_model.py, so this file does not duplicate the golden model.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_map_edge;

    integer dgc_errors = 0;

    reg clk = 0;
    always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;
    reg flush = 0;

    // ------------------------------------------------------- parameter regs
    reg  [1:0]  cfg_mode;
    reg signed [31:0] m00, m01, m02, m10, m11, m12;
    reg signed [31:0] fx, fy, cx, cy, k1, k2;
    reg  [31:0] norm_abs_max;

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
        .flush(flush),
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_mode         (cfg_mode),
        .cfg_m00          (m00), .cfg_m01 (m01), .cfg_m02 (m02),
        .cfg_m10          (m10), .cfg_m11 (m11), .cfg_m12 (m12),
        .cfg_fx           (fx),  .cfg_fy  (fy),  .cfg_cx  (cx), .cfg_cy (cy),
        .cfg_k1           (k1),  .cfg_k2  (k2),
        .cfg_norm_abs_max (norm_abs_max),
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

    // ------------------------------------------------------------- constants
    localparam signed [31:0] FX_R  = 32'sd137377855;
    localparam signed [31:0] FY_R  = 32'sd138692973;
    localparam signed [31:0] CX_R  = 32'sd64030536;
    localparam signed [31:0] CY_R  = 32'sd34085643;
    localparam signed [31:0] K1_R  = -32'sd129279204;
    localparam signed [31:0] K2_R  = 32'sd74679738;
    localparam signed [31:0] M00_R = 32'sd32014;
    localparam signed [31:0] M02_R = -32'sd31278815;
    localparam signed [31:0] M11_R = 32'sd31711;
    localparam signed [31:0] M12_R = -32'sd16492896;
    localparam        [31:0] NORM_R = 32'd134217728;    // 2.0

    // ------------------------------------------------------------------ helpers
    reg [95:0] cap;

    // Output monitor: every accepted record is pushed into a small queue, so a
    // test can grab exactly one record without having to guess the pipeline
    // latency or race the consumer handshake.
    localparam integer QN = 64;
    reg [95:0] rq [0:QN-1];
    integer    qwp = 0, qrp = 0;

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            rq[qwp] = out_coord;
            qwp = (qwp + 1) % QN;
        end
    end

    task flush_queue;
        begin
            repeat (25) @(posedge clk);
            qrp = qwp;
        end
    endtask

    task drive(input integer dx, input integer dy);
        begin
            while (!in_ready) begin @(posedge clk); #0.2; end
            in_valid     <= 1'b1;
            in_dst_x     <= dx[10:0];
            in_dst_y     <= dy[10:0];
            in_tile_tag  <= 16'h5A5A;
            in_tile_last <= (dx == 1919);
            @(posedge clk); #0.2;
            in_valid     <= 1'b0;
        end
    endtask

    // pop one captured record
    task grab(output integer dx, output integer dy, output integer sx0,
              output integer sy0, output integer wx, output integer wy,
              output integer ok,  output integer me);
        begin
            @(posedge clk); #0.2;
            while (qwp == qrp) begin
                @(posedge clk); #0.2;
            end
            cap = rq[qrp];
            qrp = (qrp + 1) % QN;
            dx  = cap[10:0];  dy = cap[21:11];
            sx0 = cap[32:22]; sy0 = cap[43:33];
            wx  = cap[59:44]; wy = cap[75:60];
            ok  = cap[92];    me  = cap[93];
        end
    endtask

    integer dx, dy, sx0, sy0, wx, wy, okv, mev;
    integer i;
    integer checked = 0;

    task one_case(input integer ix, input integer iy,
                  input integer exp_ok, input integer exp_me,
                  input integer exp_sx0, input integer exp_sy0,
                  input integer exp_wx,  input integer exp_wy,
                  input [8*40-1:0] label);
        begin
            drive(ix, iy);
            grab(dx, dy, sx0, sy0, wx, wy, okv, mev);
            checked = checked + 1;
            if (dx !== ix) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: %0s dst_x exp=%0d act=%0d", label, ix, dx); end
            if (dy !== iy) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: %0s dst_y exp=%0d act=%0d", label, iy, dy); end
            if (okv !== exp_ok) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: %0s sample_ok exp=%0d act=%0d", label, exp_ok, okv); end
            if (mev !== exp_me) begin dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: %0s math_error exp=%0d act=%0d", label, exp_me, mev); end
            if (exp_ok == 1) begin
                if (sx0 !== exp_sx0) begin dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: %0s sx0 exp=%0d act=%0d", label, exp_sx0, sx0); end
                if (sy0 !== exp_sy0) begin dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: %0s sy0 exp=%0d act=%0d", label, exp_sy0, sy0); end
                if (wx !== exp_wx) begin dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: %0s wx exp=%0d act=%0d", label, exp_wx, wx); end
                if (wy !== exp_wy) begin dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: %0s wy exp=%0d act=%0d", label, exp_wy, wy); end
            end
            else begin
                // with sample_ok = 0 all coordinate fields must be zero
                if (sx0 !== 0 || sy0 !== 0 || wx !== 0 || wy !== 0) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: %0s coordinate fields not zeroed on reject: %0d %0d %0d %0d",
                             label, sx0, sy0, wx, wy);
                end
            end
        end
    endtask

    task drain;
        begin
            repeat (30) @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------- main
    initial begin
        // start from the real calibration
        cfg_mode = 2'd1;
        m00 = M00_R; m01 = 0;      m02 = M02_R;
        m10 = 0;     m11 = M11_R;  m12 = M12_R;
        fx = FX_R;  fy = FY_R;  cx = CX_R;  cy = CY_R;
        k1 = K1_R;  k2 = K2_R;
        norm_abs_max = NORM_R;

        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // ================================================================ E6
        // real configuration, corner and centre pixels, values from
        // model/s1_pipeline_model.py
        one_case(   0,    0, 1, 0,  109,   58, 45101, 25604, "E6 corner 0,0");
        one_case( 960,  540, 1, 0,  959,  540, 65160,   273, "E6 centre 960,540");
        one_case(1919, 1079, 1, 0, 1815, 1017,  5462, 23669, "E6 corner 1919,1079");
        $display("TEST_INFO: E6 real configuration corners match the golden model");

        // ================================================================ E2
        // norm_abs_max = 0.1 makes every pixel exceed the declared range
        norm_abs_max = 32'd6710886;    // 0.1 in F26
        flush_queue;
        drive(0, 0);
        grab(dx, dy, sx0, sy0, wx, wy, okv, mev);
        checked = checked + 1;
        if (mev !== 1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E2 math_error not set when norm_abs_max is exceeded"); end
        if (okv !== 0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E2 sample_ok set despite range violation"); end
        if (sx0 !== 0 || sy0 !== 0 || wx !== 0 || wy !== 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E2 coordinate fields not zeroed"); end
        $display("TEST_INFO: E2 norm_abs_max violation sets math_error and zeroes the record");
        norm_abs_max = NORM_R;

        // ================================================================ E3 / E4
        // push the whole image to the left of the sensor: sx goes negative, which
        // is an out-of-image condition, NOT an arithmetic error
        cx = -32'sd64030536 * 4;    // about -3908 px
        flush_queue;
        drive(0, 0);
        grab(dx, dy, sx0, sy0, wx, wy, okv, mev);
        checked = checked + 1;
        if (okv !== 0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E3/E4 sample_ok set for a negative source coordinate"); end
        if (mev !== 0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E3/E4 out-of-image coordinate wrongly flagged as math_error"); end
        if (sx0 !== 0 || sy0 !== 0 || wx !== 0 || wy !== 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E3/E4 coordinate fields not zeroed on reject"); end
        $display("TEST_INFO: E3/E4 out-of-image coordinate gives sample_ok=0 with math_error=0");
        cx = CX_R;

        // ================================================================== E5
        // absurd k2 makes radial overflow the 40-bit bottleneck
        // m00 chosen so that x ~= 8.6 at u = 1919: r2 ~= 74 (inside the 32-bit
        // r2 range) but k2 * r2^2 with k2 = 7.45 reaches ~40000, which does not
        // fit the 40-bit F24 register and must be flagged, not wrapped.
        k2 = 32'sd2000000000;         // about 7.45 in F28, legal per the encoding
        m00 = 32'sd300000;
        norm_abs_max = 32'hFFFFFFFF;  // disable the range check so overflow is what fires
        flush_queue;
        drive(1919, 1079);
        grab(dx, dy, sx0, sy0, wx, wy, okv, mev);
        checked = checked + 1;
        if (mev !== 1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E5 overflow was not detected (math_error=%0d)", mev); end
        if (okv !== 0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E5 sample_ok set despite overflow"); end
        $display("TEST_INFO: E5 radial overflow is detected and rejected");
        k2 = K2_R;
        m00 = M00_R;
        norm_abs_max = NORM_R;

        // E8: overflow only in x*radial / y*radial. Tiny projection focal
        // factors keep the wrapped coordinates inside the image, so the later
        // projection/range checks cannot hide a missing product guard check.
        cfg_mode = 2'd1;
        fx = 32'sd1; fy = 32'sd1;
        k1 = 32'sd0; k2 = 32'sd536870912; // 2.0, directed out-of-envelope input
        norm_abs_max = 32'hFFFFFFFF;
        m00 = 32'sd300000;
        flush_queue;
        one_case(1919, 1079, 0, 1, 0, 0, 0, 0, "E8 x*radial guard overflow");
        m00 = M00_R; m11 = 32'sd600000;
        flush_queue;
        one_case(0, 1079, 0, 1, 0, 0, 0, 0, "E8 y*radial guard overflow");
        fx = FX_R; fy = FY_R; k1 = K1_R; k2 = K2_R;
        m11 = M11_R; norm_abs_max = NORM_R;
        $display("TEST_INFO: E8 radial product guard bits reject x/y overflow independently of projection");

        // ================================================================== E1
        // identity mode must ignore the (now nonsense) M entirely
        cfg_mode = 2'd0;
        m00 = 32'sd123456789; m02 = -32'sd999999999; m11 = 32'sd777;
        flush_queue;
        one_case(0, 0, 1, 0, 0, 0, 0, 0, "E1 identity 0,0");
        one_case(1919, 1079, 1, 0, 1919, 1079, 0, 0, "E1 identity last");
        one_case(1234, 567, 1, 0, 1234, 567, 0, 0, "E1 identity 1234,567");
        $display("TEST_INFO: E1 identity mode is exact and ignores the submitted matrix");

        // ================================================================== E7
        // mode 3 is an S5 feature. Until config_manager refuses it, the pipeline
        // must flag it instead of silently running the affine path.
        cfg_mode = 2'd3;
        m00 = M00_R; m01 = 0; m02 = M02_R;
        m10 = 0;     m11 = M11_R; m12 = M12_R;
        flush_queue;
        drive(100, 100);
        grab(dx, dy, sx0, sy0, wx, wy, okv, mev);
        checked = checked + 1;
        if (mev !== 1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E7 mode 3 not flagged as math_error (got %0d)", mev); end
        if (okv !== 0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E7 mode 3 produced sample_ok=1"); end
        if (sx0 !== 0 || sy0 !== 0 || wx !== 0 || wy !== 0) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: E7 mode 3 coordinate fields not zeroed"); end
        $display("TEST_INFO: E7 unsupported mode 3 is flagged, not silently mis-mapped");
        cfg_mode = 2'd1;

        // E9: cancel a full pipeline while its output is held by backpressure.
        // No old record may reappear, and the next input must retain alignment.
        cfg_mode = 2'd0;
        out_ready = 0;
        for (i = 0; i < 8; i = i + 1) drive(300+i, 200+i);
        wait (out_valid);
        repeat (4) @(posedge clk);
        @(negedge clk); flush = 1;
        repeat (2) @(posedge clk); #0.2;
        if (out_valid || !in_ready) `DGC_FAIL("E9 flush failed to cancel a stalled map pipeline")
        @(negedge clk); flush = 0; out_ready = 1;
        repeat (30) @(posedge clk);
        if (qwp != qrp) `DGC_FAIL("E9 stale map output returned after flush")
        one_case(123, 456, 1, 0, 123, 456, 0, 0, "E9 restart after held output");
        $display("TEST_INFO: E9 valid-only flush cancels a stalled pipeline; next record exact");

        $display("TEST_INFO: directed edge cases checked = %0d", checked);
        `DGC_FINISH
    end

endmodule
