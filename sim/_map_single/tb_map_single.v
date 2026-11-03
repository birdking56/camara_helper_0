`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_map_single;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg        in_valid = 0;
    wire       in_ready;
    reg [10:0] in_dst_x = 0, in_dst_y = 0;
    reg [15:0] in_tile_tag = 0;
    reg        in_tile_last = 0;
    wire       out_valid;
    reg        out_ready = 1;
    wire [95:0] out_coord;

    localparam signed [31:0] FX_Q = 32'sd137377855;
    localparam signed [31:0] FY_Q = 32'sd138692973;
    localparam signed [31:0] CX_Q = 32'sd64030536;
    localparam signed [31:0] CY_Q = 32'sd34085643;
    localparam signed [31:0] K1_Q = -32'sd129279204;
    localparam signed [31:0] K2_Q = 32'sd74679738;
    localparam signed [31:0] M00_Q = 32'sd32014;
    localparam signed [31:0] M01_Q = 32'sd0;
    localparam signed [31:0] M02_Q = -32'sd31278815;
    localparam signed [31:0] M10_Q = 32'sd0;
    localparam signed [31:0] M11_Q = 32'sd31711;
    localparam signed [31:0] M12_Q = -32'sd16492896;
    localparam [31:0] NORM_Q = 32'd134217728;

    dgc_map_pipeline u_dut (
        .clk (clk), .rst_n (rst_n),
        .cfg_mode (2'd1),
        .cfg_m00 (M00_Q), .cfg_m01 (M01_Q), .cfg_m02 (M02_Q),
        .cfg_m10 (M10_Q), .cfg_m11 (M11_Q), .cfg_m12 (M12_Q),
        .cfg_fx (FX_Q), .cfg_fy (FY_Q), .cfg_cx (CX_Q), .cfg_cy (CY_Q),
        .cfg_k1 (K1_Q), .cfg_k2 (K2_Q), .cfg_norm_abs_max (NORM_Q),
        .in_valid (in_valid), .in_ready (in_ready),
        .in_dst_x (in_dst_x), .in_dst_y (in_dst_y),
        .in_tile_tag (in_tile_tag), .in_tile_last (in_tile_last),
        .out_valid (out_valid), .out_ready (out_ready), .out_coord (out_coord)
    );

    integer i;
    task drive(input [10:0] x, input [10:0] y);
        begin
            @(negedge clk);
            in_valid = 1; in_dst_x = x; in_dst_y = y; in_tile_last = 0;
            @(posedge clk); #0.1;
            @(negedge clk); in_valid = 0;
        end
    endtask

    task expect(input [10:0] x, input [10:0] y, input [10:0] sx, input [10:0] sy,
                input [15:0] wx, input [15:0] wy);
        begin
            drive(x, y);
            // Backpressure the pipeline for several cycles after the input; the
            // result must be identical to the free-running case.
            out_ready = 0;
            repeat (10) @(posedge clk);
            out_ready = 1;
            i = 0;
            while (!out_valid && i < 50) begin @(posedge clk); #0.1; i = i + 1; end
            if (!out_valid) begin dgc_errors = dgc_errors + 1; $display("TEST_FAIL: no out"); end
            else begin
                if (out_coord[32:22] !== sx || out_coord[43:33] !== sy ||
                    out_coord[59:44] !== wx || out_coord[75:60] !== wy) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: (%0d,%0d) exp sx=%0d sy=%0d wx=%0d wy=%0d act sx=%0d sy=%0d wx=%0d wy=%0d",
                             x, y, sx, sy, wx, wy, out_coord[32:22], out_coord[43:33],
                             out_coord[59:44], out_coord[75:60]);
                end
                else $display("TEST_INFO: (%0d,%0d) exact", x, y);
            end
            @(posedge clk); #0.1;
        end
    endtask

    initial begin
        repeat (8) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        expect(0, 0, 109, 58, 16'hB02D, 16'h6404);   // 45101, 25604
        expect(1, 0, 110, 58, 16'h6F11, 16'h50A4);   // 28433, 20644
        expect(1000, 500, 0, 0, 0, 0);               // placeholder, prints actual
        `DGC_FINISH
    end
endmodule
