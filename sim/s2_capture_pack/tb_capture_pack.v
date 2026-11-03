//-----------------------------------------------------------------------------
// tb_capture_pack.v - RGB888 into 32-byte beats
//   P1  one row of 1920 pixels produces exactly 180 beats
//   P2  the bytes replayed from the beats equal the pixel stream exactly
//   P3  beat addresses are row_base + k*32 and advance by 5760 per row
//   P4  two rows: the second row starts beat-aligned with no carry
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_capture_pack;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg  [31:0] frame_base = 32'h0100_0000;
    reg         frame_start = 0;
    reg         px_valid = 0;
    wire        px_ready;
    reg  [23:0] px_data = 0;
    reg         px_eol = 0;
    wire        beat_valid;
    reg         beat_ready = 1;
    wire [31:0] beat_addr;
    wire [255:0] beat_data;
    wire        beat_sof;
    wire [31:0] cnt_px, cnt_beats;

    dgc_capture_pack u_dut (
        .clk(clk), .rst_n(rst_n),
        .frame_base(frame_base), .frame_start(frame_start),
        .px_valid(px_valid), .px_ready(px_ready), .px_data(px_data),
        .px_de(1'b1), .px_eol(px_eol),
        .beat_valid(beat_valid), .beat_ready(beat_ready), .beat_addr(beat_addr),
        .beat_data(beat_data), .beat_sof(beat_sof),
        .cnt_px(cnt_px), .cnt_beats(cnt_beats));

    // replay buffer: 180 beats x 32 bytes for two rows
    reg [7:0] replay [0:12000];
    integer   rp = 0;
    integer   n_beats = 0;
    reg [31:0] first_addr = 0, second_addr = 0;
    integer    n_sof = 0;

    always @(posedge clk) begin
        if (rst_n && beat_valid && beat_ready) begin
            n_beats = n_beats + 1;
            if (beat_sof) n_sof = n_sof + 1;
            if (n_beats == 1) first_addr = beat_addr;
            if (n_beats == 181) second_addr = beat_addr;
            replay[rp + 0] = beat_data[7:0];    replay[rp + 1] = beat_data[15:8];
            replay[rp + 2] = beat_data[23:16];  replay[rp + 3] = beat_data[31:24];
            replay[rp + 4] = beat_data[39:32];  replay[rp + 5] = beat_data[47:40];
            replay[rp + 6] = beat_data[55:48];  replay[rp + 7] = beat_data[63:56];
            replay[rp + 8] = beat_data[71:64];  replay[rp + 9] = beat_data[79:72];
            replay[rp + 10] = beat_data[87:80]; replay[rp + 11] = beat_data[95:88];
            replay[rp + 12] = beat_data[103:96]; replay[rp + 13] = beat_data[111:104];
            replay[rp + 14] = beat_data[119:112]; replay[rp + 15] = beat_data[127:120];
            replay[rp + 16] = beat_data[135:128]; replay[rp + 17] = beat_data[143:136];
            replay[rp + 18] = beat_data[151:144]; replay[rp + 19] = beat_data[159:152];
            replay[rp + 20] = beat_data[167:160]; replay[rp + 21] = beat_data[175:168];
            replay[rp + 22] = beat_data[183:176]; replay[rp + 23] = beat_data[191:184];
            replay[rp + 24] = beat_data[199:192]; replay[rp + 25] = beat_data[207:200];
            replay[rp + 26] = beat_data[215:208]; replay[rp + 27] = beat_data[223:216];
            replay[rp + 28] = beat_data[231:224]; replay[rp + 29] = beat_data[239:232];
            replay[rp + 30] = beat_data[247:240]; replay[rp + 31] = beat_data[255:248];
            rp = rp + 32;
        end
    end

    task push(input integer x, input integer y);
        reg [23:0] p;
        begin
            p = {y[7:0], x[11:4], x[3:0]};    // a value that depends on x and y
            @(posedge clk); #0.2;
            while (!px_ready) begin @(posedge clk); #0.2; end
            px_valid <= 1'b1;
            px_data  <= p;
            px_eol   <= (x == 1919);
            @(posedge clk); #0.2;
            px_valid <= 1'b0;
            px_eol   <= 1'b0;
        end
    endtask

    integer x, y, i, byte_i, exp_b, act_b;

    initial begin
        rst_n = 0;
        repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);
        @(posedge clk); #0.2; frame_start <= 1'b1;
        @(posedge clk); #0.2; frame_start <= 1'b0;

        // ---- two complete rows
        for (y = 0; y < 2; y = y + 1)
            for (x = 0; x < 1920; x = x + 1)
                push(x, y);

        wait (n_beats >= 360);
        repeat (20) @(posedge clk);

        // ============================================================== P1
        if (n_beats != 360) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P1 expected 360 beats for two rows, got %0d", n_beats);
        end
        else $display("TEST_INFO: P1 two rows produced exactly 360 beats (180 per row)");

        // ============================================================== P2
        // replay the byte stream and compare with the pixel order
        for (y = 0; y < 2; y = y + 1)
            for (x = 0; x < 1920; x = x + 1) begin
                exp_b = {y[7:0], x[11:4], x[3:0]};
                byte_i = (y * 1920 + x) * 3;
                if (replay[byte_i] !== exp_b[7:0] ||
                    replay[byte_i + 1] !== exp_b[15:8] ||
                    replay[byte_i + 2] !== exp_b[23:16]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8)
                    $display("TEST_FAIL: P2 byte mismatch at pixel (%0d,%0d) exp=%06h got=%02h%02h%02h",
                             x, y, exp_b, replay[byte_i+2], replay[byte_i+1], replay[byte_i]);
                end
            end
        $display("TEST_INFO: P2 the replayed byte stream equals the pixel stream exactly");

        // ============================================================== P3
        if (first_addr !== frame_base) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P3 first beat addr exp=%08h act=%08h", frame_base, first_addr);
        end
        if (second_addr !== (frame_base + 32'd5760)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P3 first beat of row 1 exp=%08h act=%08h",
                     frame_base + 32'd5760, second_addr);
        end
        $display("TEST_INFO: P3 row bases are frame_base and frame_base+5760");

        // ============================================================== P4
        if (n_sof != 2) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P4 expected 2 row-start beats, got %0d", n_sof);
        end
        else $display("TEST_INFO: P4 each row starts beat-aligned, no carry across the row boundary");

        `DGC_FINISH
    end
endmodule
