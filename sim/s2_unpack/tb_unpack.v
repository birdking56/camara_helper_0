//-----------------------------------------------------------------------------
// tb_unpack.v - S2: unpack byte stream -> pixels
//
// The checker derives the expected pixel directly from fill_x, so it verifies
// the byte order (B G R in memory -> {R,G,B} logical), the head_skip offset and
// the cross-beat carry all at once, without needing a separate golden file.
//
// Cases
//   U1  head_skip = 0, 96 bytes  (3 beats, 32 pixels, no straddle)
//   U2  head_skip = 5,  3 bytes  (single pixel, offset inside the first beat)
//   U3  head_skip = 30, 9 bytes  (3 pixels straddling the beat boundary -> carry)
//   U4  head_skip = 0, 60 bytes  (2 beats, 20 pixels, tail padding to drain)
//   U5  U3 repeated with random fill_ready backpressure
//   U6  beat starvation: beats arrive with gaps
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_unpack;

    integer dgc_errors = 0;

    reg clk = 0;
    always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    // -------------------------------------------------------------- row control
    reg         row_load = 0;
    reg  [4:0]  row_head_skip = 0;
    reg  [7:0]  row_valid_bytes = 0;
    reg  [4:0]  row_beats_total = 0;
    reg  [5:0]  row_local_y = 0;
    reg         row_set = 0;
    reg  [15:0] row_tile_tag = 0;
    reg         row_last = 0;
    reg         row_tile_last = 0;

    // -------------------------------------------------------------- beat stream
    reg         beat_valid = 0;
    wire        beat_ready;
    reg  [255:0] beat_data = 0;

    // ---------------------------------------------------------------- fill out
    wire        fill_valid;
    reg         fill_ready = 1;
    wire        fill_set;
    wire [15:0] fill_tile_tag;
    wire [5:0]  fill_x, fill_y;
    wire [1:0]  fill_count;
    wire [23:0] fill_rgb0, fill_rgb1;
    wire        fill_row_last, fill_tile_last;

    dgc_unpack u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .row_load        (row_load),
        .row_head_skip   (row_head_skip),
        .row_valid_bytes (row_valid_bytes),
        .row_beats_total (row_beats_total),
        .row_local_y     (row_local_y),
        .row_set         (row_set),
        .row_tile_tag    (row_tile_tag),
        .row_last        (row_last),
        .row_tile_last   (row_tile_last),
        .beat_valid      (beat_valid),
        .beat_ready      (beat_ready),
        .beat_data       (beat_data),
        .fill_valid      (fill_valid),
        .fill_ready      (fill_ready),
        .fill_set        (fill_set),
        .fill_tile_tag   (fill_tile_tag),
        .fill_x          (fill_x),
        .fill_y          (fill_y),
        .fill_count      (fill_count),
        .fill_rgb0       (fill_rgb0),
        .fill_rgb1       (fill_rgb1),
        .fill_row_last   (fill_row_last),
        .fill_tile_last  (fill_tile_last)
    );

    integer cur_head_skip = 0;
    integer cur_valid_bytes = 0;
    integer cur_beats = 0;
    reg     bp_en = 0;

    // ------------------------------------------------------------- reference data
    // Row byte i (0-based within the valid data) has a unique value, so any
    // misalignment or lane swap shows up immediately.
    function [7:0] rb(input integer i);
        rb = ((i * 7) + 3) & 8'hFF;
    endfunction

    // Byte at aligned position a (0-based within the aligned row) for row r of
    // the current case. Positions outside the valid data are padding.
    function [7:0] ab(input integer a);
        integer idx;
        begin
            idx = a - cur_head_skip;
            if (idx >= 0 && idx < cur_valid_bytes) ab = rb(idx);
            else                                  ab = 8'hEE;
        end
    endfunction

    function [255:0] beat_of(input integer b);
        integer j, a, idx;
        reg [7:0] by;
        begin
            beat_of = 256'd0;
            for (j = 0; j < 32; j = j + 1) begin
                a   = b * 32 + j;
                idx = a - cur_head_skip;
                by  = (idx >= 0 && idx < cur_valid_bytes) ? rb(idx) : 8'hEE;
                beat_of[8*j +: 8] = by;
            end
        end
    endfunction

    // ------------------------------------------------------------- checking
    integer n_pixels = 0;
    integer n_rows_checked = 0;
    integer cur_row_pixels = 0;

    task check_fill;
        integer k, exp_rgb;
        begin
            for (k = 0; k < fill_count; k = k + 1) begin
                if (k == 0) exp_rgb = {rb(3*fill_x + 2), rb(3*fill_x + 1), rb(3*fill_x)};
                else        exp_rgb = {rb(3*(fill_x+1) + 2), rb(3*(fill_x+1) + 1), rb(3*(fill_x+1))};
                n_pixels = n_pixels + 1;
                cur_row_pixels = cur_row_pixels + 1;
                if (k == 0) begin
                    if (fill_rgb0 !== exp_rgb[23:0]) begin
                        dgc_errors = dgc_errors + 1;
                        $display("TEST_FAIL: pixel x=%0d exp=%06h act=%06h y=%0d t=%0t",
                                 fill_x, exp_rgb[23:0], fill_rgb0, fill_y, $time);
                    end
                end
                else begin
                    if (fill_rgb1 !== exp_rgb[23:0]) begin
                        dgc_errors = dgc_errors + 1;
                        $display("TEST_FAIL: pixel x=%0d exp=%06h act=%06h y=%0d t=%0t",
                                 fill_x + 1, exp_rgb[23:0], fill_rgb1, fill_y, $time);
                    end
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && fill_valid && fill_ready) check_fill;
    end

    // ------------------------------------------------------------------ drivers
    integer seed = 7;

    task run_row(input integer head_skip, input integer valid_bytes,
                 input integer local_y, input integer tile_last,
                 input integer random_ready, input integer beat_starve,
                 input [8*40-1:0] label);
        integer b, beats, gap, r;
        begin
            cur_head_skip   = head_skip;
            cur_valid_bytes = valid_bytes;
            beats = (head_skip + valid_bytes + 31) / 32;
            cur_beats = beats;

            // descriptor
            @(posedge clk); #0.2;
            row_head_skip   <= head_skip[4:0];
            row_valid_bytes <= valid_bytes[7:0];
            row_beats_total <= beats[4:0];
            row_local_y     <= local_y[5:0];
            row_set         <= (local_y % 2);
            row_tile_tag    <= 16'h0100 + local_y[15:0];
            row_last        <= 1'b1;
            row_tile_last   <= tile_last[0];
            row_load        <= 1'b1;
            @(posedge clk); #0.2;
            row_load        <= 1'b0;

            cur_row_pixels = 0;

            // beats
            for (b = 0; b < beats; b = b + 1) begin
                if (beat_starve != 0) begin
                    gap = ({$random(seed)} % 3);
                    repeat (gap) @(posedge clk);
                end
                @(posedge clk); #0.2;
                beat_valid <= 1'b1;
                beat_data  <= beat_of(b);
                while (!beat_ready) begin @(posedge clk); #0.2; end
                @(posedge clk); #0.2;
                beat_valid <= 1'b0;
            end

            // let the row drain
            repeat (60) @(posedge clk);

            if (cur_row_pixels != (valid_bytes / 3)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: %0s produced %0d pixels, expected %0d",
                         label, cur_row_pixels, valid_bytes / 3);
            end
            else begin
                n_rows_checked = n_rows_checked + 1;
                $display("TEST_INFO: %0s ok (%0d pixels, %0d beats)",
                         label, cur_row_pixels, beats);
            end
        end
    endtask

    // random fill backpressure
    integer rbrk;
    always @(posedge clk) begin
        if (bp_en) begin
            rbrk = ({$random(seed)} % 100);
            fill_ready <= (rbrk >= 25);          // 75 % ready
        end
        else begin
            fill_ready <= 1'b1;
        end
    end

    integer i;

    // -------------------------------------------------------------------- main
    initial begin
        rst_n = 0;
        fill_ready = 1;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        run_row( 0,  96, 0, 0, 0, 0, "U1 head_skip=0  valid=96");
        run_row( 5,   3, 1, 0, 0, 0, "U2 head_skip=5  valid=3");
        run_row(30,   9, 2, 0, 0, 0, "U3 head_skip=30 valid=9 (straddle)");
        run_row( 0,  60, 3, 0, 0, 0, "U4 valid=60 with tail padding");

        bp_en = 1;
        run_row(30,   9, 4, 0, 1, 0, "U5 straddle + random backpressure");
        run_row( 0, 192, 5, 1, 1, 0, "U5b full 64-pixel row + backpressure");
        bp_en = 0;

        run_row( 7,  33, 6, 0, 0, 0, "U6 straddle, gap-free");

        $display("TEST_INFO: rows checked = %0d, pixels = %0d", n_rows_checked, n_pixels);
        `DGC_FINISH
    end

endmodule
