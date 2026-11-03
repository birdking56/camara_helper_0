`timescale 1ns/1ps
`include "dgc_tb.vh"
module tb_capture_writer;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg         frame_begin = 0; reg [127:0] frame_desc = 0; reg frame_abort = 0;
    reg         px_valid = 0;    wire px_ready;
    reg  [23:0] px_data = 0;     reg px_eol = 0;
    wire        beat_valid;      reg beat_ready = 1;
    wire [31:0] beat_addr;       wire [255:0] beat_data;
    wire        frame_done;      wire [1:0] done_slot; wire [31:0] done_frame_id;
    wire [31:0] cnt_frames, cnt_aborted; wire [10:0] row_cnt;

    dgc_capture_writer #(.STRIDE_BYTES(96)) u_dut (
        .clk(clk), .rst_n(rst_n), .frame_begin(frame_begin), .frame_desc(frame_desc),
        .frame_abort(frame_abort), .px_valid(px_valid), .px_ready(px_ready),
        .px_data(px_data), .px_de(1'b1), .px_eol(px_eol),
        .beat_valid(beat_valid), .beat_ready(beat_ready), .beat_addr(beat_addr),
        .beat_data(beat_data), .frame_done(frame_done), .done_slot(done_slot),
        .done_frame_id(done_frame_id), .cnt_frames(cnt_frames),
        .cnt_aborted(cnt_aborted), .row_cnt(row_cnt));

    integer n_beats = 0, n_done = 0;
    reg [31:0] b12 = 0;          // address of the 12th beat == frame 1's last beat
    reg [1:0]  seen_slot = 0; reg [31:0] seen_fid = 0;

    always @(posedge clk) begin
        if (rst_n && beat_valid && beat_ready) begin
            n_beats = n_beats + 1;
            // record only once: n_beats is reset before frame 2, so without the
            // b12==0 guard the 12th beat of frame 2 would overwrite frame 1's
            if (n_beats == 12 && b12 == 32'd0) b12 = beat_addr;
        end
        if (rst_n && frame_done) begin
            n_done = n_done + 1; seen_slot = done_slot; seen_fid = done_frame_id;
        end
    end

    task start_frame(input [1:0] slot, input [31:0] fid);
        begin
            @(posedge clk); #0.2;
            frame_desc <= {20'd0, 2'd0, slot, 12'd4, 12'd32, 16'd96,
                           {6'd0, slot, 24'd0}, fid};   // slot base = slot * 0x01000000
            frame_begin <= 1'b1;
            @(posedge clk); #0.2;
            frame_begin <= 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    task push_row;
        integer x, k;
        begin
            for (x = 0; x < 32; x = x + 1) begin
                @(posedge clk); #0.2;
                k = 0;
                while (!px_ready && k < 64) begin @(posedge clk); #0.2; k = k + 1; end
                if (!px_ready) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: px_ready low (active=%b)", u_dut.active);
                end
                px_valid <= 1'b1;
                px_data  <= {8'h10 + x[7:0], 8'h20 + row_cnt[7:0], 8'h30 + x[7:0]};
                px_eol   <= (x == 31);
                @(posedge clk); #0.2;
                px_valid <= 1'b0; px_eol <= 1'b0;
            end
        end
    endtask

    integer r;
    initial begin
        rst_n = 0;
        repeat (6) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        start_frame(2'd1, 32'hDEAD_0001);
        for (r = 0; r < 4; r = r + 1) push_row;
        repeat (20) @(posedge clk);

        if (n_beats !== 12) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W1 beats exp=12 act=%0d", n_beats); end
        else $display("TEST_INFO: W1 a 32x4 frame produced 12 beats (3 per row)");

        if (n_done !== 1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W1 frame_done count exp=1 act=%0d", n_done); end
        else $display("TEST_INFO: W1 frame_done emitted once");

        if (seen_slot !== 2'd1 || seen_fid !== 32'hDEAD_0001) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W2 slot=%0d fid=%08h", seen_slot, seen_fid); end
        else $display("TEST_INFO: W2 frame_done carries slot 1 and frame_id DEAD0001");

        // last beat = row 3 (3*96 = 288) + beat 2 (2*32 = 64) = base + 352
        if (b12 !== (32'h0100_0000 + 32'd352)) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W3 12th beat exp=%08h act=%08h", 32'h0100_0000+352, b12); end
        else $display("TEST_INFO: W3 the 12th beat is at base+288+64 (row 3, beat 2), so the row base advanced");

        n_beats = 0; n_done = 0;
        start_frame(2'd2, 32'hDEAD_0002);
        push_row;
        @(posedge clk); #0.2; frame_abort <= 1'b1;
        @(posedge clk); #0.2; frame_abort <= 1'b0;
        repeat (4) @(posedge clk);
        for (r = 0; r < 96; r = r + 1) begin
            @(posedge clk); #0.2;
            px_valid <= 1'b1; px_data <= 24'h00_11_22; px_eol <= ((r % 32) == 31);
            @(posedge clk); #0.2;
            px_valid <= 1'b0; px_eol <= 1'b0;
        end
        repeat (10) @(posedge clk);
        if (n_done !== 0) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W4 an aborted frame must not be published"); end
        if (cnt_aborted !== 32'd1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: W4 abort not counted (%0d)", cnt_aborted); end
        else $display("TEST_INFO: W4 aborted frame dropped and counted");
        $display("TEST_INFO: W frames=%0d aborted=%0d", cnt_frames, cnt_aborted);
        `DGC_FINISH
    end
endmodule
