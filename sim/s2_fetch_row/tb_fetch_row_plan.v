//-----------------------------------------------------------------------------
// tb_fetch_row_plan.v - per-row fetch arithmetic
//   R1  alignment: aligned_addr is 32-byte aligned and inside [start-31, start]
//   R2  head_skip = start - aligned_addr, always 0..31
//   R3  beats_total = ceil((head_skip+valid_bytes)/32) and stays within 1..7
//   R4  the covered window includes the whole row's valid bytes
//   R5  exhaustive over every head_skip and block width
//   R6  row_last only on the final row
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_fetch_row_plan;
    integer dgc_errors = 0;

    reg  [31:0] frame_base = 32'h0100_0000;
    reg  [10:0] bbox_x = 0, bbox_y = 0;
    reg  [6:0]  bbox_w = 1, bbox_h = 1;
    reg  [5:0]  local_y = 0;
    wire [31:0] start_byte, aligned_addr;
    wire [4:0]  head_skip;
    wire [7:0]  valid_bytes;
    wire [4:0]  beats_total;
    wire        row_last, geom_ok;

    dgc_fetch_row_plan #(.STRIDE_BYTES(5760)) u_dut (
        .frame_base(frame_base), .bbox_x(bbox_x), .bbox_y(bbox_y),
        .bbox_w(bbox_w), .bbox_h(bbox_h), .local_y(local_y),
        .start_byte(start_byte), .aligned_addr(aligned_addr),
        .head_skip(head_skip), .valid_bytes(valid_bytes),
        .beats_total(beats_total), .row_last(row_last), .geom_ok(geom_ok));

    integer x, w, y, ly;
    integer exp_beats, total;

    initial begin
        // ============================================================== R5
        for (x = 0; x < 32; x = x + 1)
        for (w = 1; w <= 64; w = w + 1) begin
            bbox_x = x[10:0]; bbox_y = 11'd7; bbox_w = w[6:0]; bbox_h = 7'd2;
            local_y = 6'd0;
            #0;
            // R1 alignment
            if (aligned_addr[4:0] !== 5'd0) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: R1 not aligned x=%0d w=%0d", x, w);
            end
            if (aligned_addr > start_byte || (start_byte - aligned_addr) > 32'd31) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: R1 aligned_addr out of range x=%0d w=%0d", x, w);
            end
            // R2
            if (head_skip !== start_byte[4:0]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: R2 head_skip x=%0d w=%0d", x, w);
            end
            if (head_skip > 5'd31) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: R2 head_skip > 31");
            end
            // R3
            total = head_skip + valid_bytes;
            exp_beats = (total + 31) / 32;
            if (beats_total !== exp_beats[4:0]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: R3 beats exp=%0d act=%0d (x=%0d w=%0d)", exp_beats, beats_total, x, w);
            end
            if (beats_total < 1 || beats_total > 7) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: R3 beats out of 1..7");
            end
            if (!geom_ok) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: R3 geom_ok low for a legal block");
            end
            // R4 the beat window must cover head_skip+valid_bytes
            if (beats_total * 32 < total) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: R4 window too small x=%0d w=%0d", x, w);
            end
            // and must not waste a whole extra beat
            if ((beats_total - 1) * 32 >= total) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: R4 window too large x=%0d w=%0d", x, w);
            end
        end
        $display("TEST_INFO: R1/R2 aligned to 32 bytes, head_skip matches start[4:0]");
        $display("TEST_INFO: R3/R4 beats = ceil(total/32) within 1..7, minimal window");
        $display("TEST_INFO: R5 exhaustive over 32 head offsets x 64 block widths = %0d cases", 32*64);

        // ============================================================== R6
        bbox_x = 11'd0; bbox_y = 11'd0; bbox_w = 7'd64; bbox_h = 7'd4;
        for (ly = 0; ly < 4; ly = ly + 1) begin
            local_y = ly[5:0]; #0;
            if (row_last !== ((ly == 3) ? 1'b1 : 1'b0)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: R6 row_last wrong at ly=%0d", ly);
            end
        end
        // the spec's worst case: 64 wide, head skip 31
        bbox_x = 11'd11; bbox_w = 7'd64; local_y = 6'd0; #0;
        $display("TEST_INFO: R6 worst case start=%08h aligned=%08h skip=%0d valid=%0d beats=%0d",
                 start_byte, aligned_addr, head_skip, valid_bytes, beats_total);
        if (beats_total !== 5'd7) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: R6 worst case must need 7 beats, got %0d", beats_total);
        end
        else $display("TEST_INFO: R6 the 64-wide, 31-byte-skip worst case needs exactly 7 beats");
        `DGC_FINISH
    end
endmodule
