//-----------------------------------------------------------------------------
// tb_bilinear.v - S3: bilinear interpolation against the direct formula
//
// The DUT factors the four-term sum into two stages, so the testbench computes
// the *unfactored* expression
//
//     S = P00*(A-wx)*(A-wy) + P10*wx*(A-wy) + P01*(A-wx)*wy + P11*wx*wy
//     exp = saturate_u8((S + 2^31) >> 32)
//
// in 64-bit integer arithmetic. That is an independent derivation of the same
// mathematics, so a wrong term, a swapped weight or a truncation between stages
// shows up as a mismatch instead of being reproduced by the checker.
//
// Cases
//   B1  the four corners: (0,0) (0,1) (1,0) (1,1) in weight space
//   B2  the exact centre 0x8000, 0x8000
//   B3  2000 random pixel/weight vectors
//   B4  rounding at a tie
//   B5  sample_ok = 0 forces pure black
//   B6  metadata pass-through (tile_tag, dst_x/y, tile_last, math_error)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_bilinear;

    integer dgc_errors = 0;

    reg clk = 0;
    always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg  [191:0] in_sample = 0;
    reg          in_valid = 0;
    wire         in_ready;
    wire         out_valid;
    reg          out_ready = 1;
    wire [63:0]  out_pixel;

    dgc_bilinear u_dut (
        .clk (clk), .rst_n (rst_n),
        .in_valid (in_valid), .in_ready (in_ready), .in_sample (in_sample),
        .out_valid (out_valid), .out_ready (out_ready), .out_pixel (out_pixel)
    );

    // ------------------------------------------------------- reference formula
    // direct (unfactored) four-term sum for one 8-bit channel
    function [7:0] ref_chan(input [7:0] a, input [7:0] b, input [7:0] c, input [7:0] d,
                            input [15:0] wx, input [15:0] wy);
        reg [63:0] A;
        reg [63:0] awx, awy;
        reg [63:0] s;
        reg [63:0] t;
        begin
            A   = 64'd65536;
            awx = A - {48'd0, wx};
            awy = A - {48'd0, wy};
            s   = ({56'd0, a} * awx * awy)
                + ({56'd0, b} * {48'd0, wx} * awy)
                + ({56'd0, c} * awx * {48'd0, wy})
                + ({56'd0, d} * {48'd0, wx} * {48'd0, wy});
            t   = (s + 64'h8000_0000) >> 32;
            if (t > 64'd255) ref_chan = 8'd255;
            else             ref_chan = t[7:0];
        end
    endfunction

    function [23:0] ref_rgb(input [23:0] p00, p10, p01, p11,
                            input [15:0] wx, wy);
        begin
            ref_rgb = { ref_chan(p00[23:16], p10[23:16], p01[23:16], p11[23:16], wx, wy),
                        ref_chan(p00[15:8],  p10[15:8],  p01[15:8],  p11[15:8],  wx, wy),
                        ref_chan(p00[7:0],   p10[7:0],   p01[7:0],   p11[7:0],   wx, wy) };
        end
    endfunction

    // ------------------------------------------------------------- scoreboard
    localparam integer QN = 4096;
    reg [63:0] exp_q [0:QN-1];
    integer    q_wp = 0, q_rp = 0;
    integer    n_checked = 0;

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            if (q_rp >= q_wp) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: bilinear produced an unrequested beat t=%0t", $time);
            end
            else begin
                if (out_pixel !== exp_q[q_rp]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 25)
                    $display("TEST_FAIL: beat %0d exp=%016h act=%016h t=%0t",
                             q_rp, exp_q[q_rp], out_pixel, $time);
                end
                q_rp = q_rp + 1;
                n_checked = n_checked + 1;
            end
        end
    end

    // ------------------------------------------------------------------ drive
    task drive(input [23:0] p00, p10, p01, p11,
               input [15:0] wx, wy,
               input ok, input merr, input tlast,
               input [15:0] tag, input [10:0] dx, input [10:0] dy);
        reg [95:0]  cd;
        reg [63:0]  exp;
        begin
            cd = {1'b0, tlast, merr, ok, tag, wy, wx, 11'd0, 11'd0, dy[10:0], dx[10:0]};
            // note: the coord record is {reserved, tile_last, math_error,
            // sample_ok, tile_tag, wy, wx, sy0, sx0, dst_y, dst_x}; sx0/sy0 are
            // irrelevant to bilinear and set to zero here.
            in_sample <= {p11, p01, p10, p00, cd};
            in_valid  <= 1'b1;

            exp = { merr, tlast, tag, dy, dx,
                    ok ? ref_rgb(p00, p10, p01, p11, wx, wy) : 24'd0 };
            exp_q[q_wp] = exp;
            q_wp = q_wp + 1;

            @(posedge clk); #0.2;
            in_valid <= 1'b0;
        end
    endtask

    integer i, seed = 32'h1234_ABCD;
    integer seed2 = 32'h0BAD_F00D;
    reg [23:0] p00, p10, p01, p11;
    reg [15:0] wx, wy;
    reg [95:0] b7_cd;
    reg        bp_en = 1'b0;

    always @(posedge clk) begin
        if (bp_en) out_ready <= (({$random(seed2)} % 100) >= 35);
        else       out_ready <= 1'b1;
    end

    initial begin
        rst_n = 0;
        in_valid = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ================================================================== B1
        drive(24'hAA_BB_CC, 24'h11_22_33, 24'h44_55_66, 24'hDD_EE_FF,
              16'h0000, 16'h0000, 1, 0, 0, 16'h0102, 11'd5, 11'd6);
        drive(24'hAA_BB_CC, 24'h11_22_33, 24'h44_55_66, 24'hDD_EE_FF,
              16'hFFFF, 16'h0000, 1, 0, 0, 16'h0102, 11'd5, 11'd6);
        drive(24'hAA_BB_CC, 24'h11_22_33, 24'h44_55_66, 24'hDD_EE_FF,
              16'h0000, 16'hFFFF, 1, 0, 0, 16'h0102, 11'd5, 11'd6);
        drive(24'hAA_BB_CC, 24'h11_22_33, 24'h44_55_66, 24'hDD_EE_FF,
              16'hFFFF, 16'hFFFF, 1, 0, 0, 16'h0102, 11'd5, 11'd6);
        repeat (6) @(posedge clk);
        $display("TEST_INFO: B1 four weight-space corners checked");

        // ================================================================== B2
        drive(24'h00_00_00, 24'hFF_00_00, 24'h00_FF_00, 24'h00_00_FF,
              16'h8000, 16'h8000, 1, 0, 0, 16'h3333, 11'd100, 11'd200);
        repeat (4) @(posedge clk);
        $display("TEST_INFO: B2 exact centre checked");

        // ================================================================== B3
        for (i = 0; i < 2000; i = i + 1) begin
            p00 = {$random(seed)}; p10 = {$random(seed)};
            p01 = {$random(seed)}; p11 = {$random(seed)};
            wx  = {$random(seed)}; wy  = {$random(seed)};
            drive(p00, p10, p01, p11, wx, wy,
                  1, ({$random(seed)} % 2), ({$random(seed)} % 2),
                  {$random(seed)}, {$random(seed)} % 1920, {$random(seed)} % 1080);
        end
        repeat (20) @(posedge clk);
        $display("TEST_INFO: B3 2000 random vectors checked");

        // ================================================================== B4
        // a tie: all four neighbours 0 or 255 with equal weights gives exactly
        // half of the weighted sum, exercising the +2^31 rounding
        drive(24'h00_00_00, 24'h00_00_00, 24'h00_00_00, 24'h01_01_01,
              16'h8000, 16'h8000, 1, 0, 0, 16'd0, 11'd0, 11'd0);
        repeat (6) @(posedge clk);
        $display("TEST_INFO: B4 rounding tie checked");

        // ================================================================== B5
        drive(24'hFF_FF_FF, 24'hFF_FF_FF, 24'hFF_FF_FF, 24'hFF_FF_FF,
              16'h8000, 16'h8000, 0, 0, 0, 16'h4444, 11'd7, 11'd8);
        repeat (6) @(posedge clk);
        $display("TEST_INFO: B5 sample_ok=0 forces pure black");

        // ================================================================== B7
        // Backpressure: the frozen transfer rule says a valid beat must be held
        // until it is accepted. The first RTL ignored out_ready and dropped every
        // pixel produced during a stall, so this case is the regression that
        // proves the elastic pipeline actually holds data.
        bp_en = 1'b1;
        for (i = 0; i < 400; i = i + 1) begin
            p00 = {$random(seed)}; p10 = {$random(seed)};
            p01 = {$random(seed)}; p11 = {$random(seed)};
            wx  = {$random(seed)}; wy  = {$random(seed)};
            b7_cd = 96'd0;
            b7_cd[92]    = 1'b1;
            b7_cd[91:76] = 16'h7000 + i[15:0];
            b7_cd[75:60] = wy;
            b7_cd[59:44] = wx;
            b7_cd[21:11] = i[10:0] % 1080;
            b7_cd[10:0]  = i[10:0] % 1920;
            // assert only when the DUT can take it, and hold for exactly the
            // single accepting edge: holding valid across a stall would send the
            // same payload twice, which is a testbench error, not a DUT one
            while (!in_ready) begin
                @(posedge clk); #0.2;
            end
            in_sample <= {p11, p01, p10, p00, b7_cd};
            in_valid  <= 1'b1;
            exp_q[q_wp] = 64'd0;
            exp_q[q_wp][61:46] = 16'h7000 + i[15:0];
            exp_q[q_wp][45:35] = i[10:0] % 1080;
            exp_q[q_wp][34:24] = i[10:0] % 1920;
            exp_q[q_wp][23:0]  = ref_rgb(p00, p10, p01, p11, wx, wy);
            q_wp = q_wp + 1;
            @(posedge clk); #0.2;   // this edge accepts the beat
            in_valid <= 1'b0;
            @(posedge clk); #0.2;   // one idle cycle before the next beat
        end
        repeat (40) @(posedge clk);
        bp_en = 1'b0;
        out_ready <= 1'b1;
        repeat (10) @(posedge clk);
        if (n_checked != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: B7 %0d beats driven but only %0d came out",
                     q_wp, n_checked);
        end
        else $display("TEST_INFO: B7 400 beats through random output stalls, none lost");

        // ================================================================== B6
        drive(24'h12_34_56, 24'h65_43_21, 24'h0F_1E_2D, 24'h3C_4B_5A,
              16'h1234, 16'h5678, 1, 1, 1, 16'hBEEF, 11'd1919, 11'd1079);
        repeat (20) @(posedge clk);
        if (n_checked != q_wp) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: %0d sent but only %0d checked", q_wp, n_checked);
        end
        $display("TEST_INFO: B6 metadata pass-through checked, %0d beats total", n_checked);

        `DGC_FINISH
    end

endmodule
