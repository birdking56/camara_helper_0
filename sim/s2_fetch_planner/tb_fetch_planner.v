//-----------------------------------------------------------------------------
// tb_fetch_planner.v - bbox -> one fetch_row descriptor per source row
//
// The expected values are computed here from the frozen byte-address formula in
// 64-bit integer arithmetic, independently of the RTL's shift/add form.
//
//   P1  a 33x17 bbox at (64,32): every row's address, head_skip, beats and bytes
//   P2  the last-stripe bbox at (1888,1072) 32x8
//   P3  pseudo-random blocks over 400 rows with random backpressure on BOTH
//       output ports, including one port stalling while the other accepts
//   P4  a block wider than 64 is flagged (geom_bad), never silently truncated
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_fetch_planner;
    integer dgc_errors = 0;
    reg clk = 0; always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg         start = 0;
    reg  [31:0] frame_base = 0;
    reg  [31:0] job_id = 32'hCAFE_0001;
    reg  [15:0] tile_tag = 0;
    reg         cache_set = 0;
    reg  [10:0] bbox_x = 0, bbox_y = 0;
    reg  [6:0]  bbox_w = 0, bbox_h = 0;

    wire        row_valid;
    reg         row_ready = 1;
    wire [31:0] row_job_id;
    wire [15:0] row_tag;
    wire        row_set;
    wire [31:0] row_addr;
    wire [4:0]  row_beats, row_head_skip;
    wire [7:0]  row_valid_bytes;
    wire [5:0]  row_local_y;
    wire        row_last;

    wire        urow_valid;
    reg         urow_ready = 1;
    wire [4:0]  urow_head_skip;
    wire [7:0]  urow_valid_bytes;
    wire [4:0]  urow_beats;
    wire [5:0]  urow_local_y;
    wire        urow_set;
    wire [15:0] urow_tag;
    wire        urow_row_last, urow_tile_last;

    wire        busy, done, geom_bad;

    dgc_fetch_planner u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .frame_base(frame_base), .job_id(job_id),
        .tile_tag(tile_tag), .cache_set(cache_set),
        .bbox_x(bbox_x), .bbox_y(bbox_y), .bbox_w(bbox_w), .bbox_h(bbox_h),
        .row_valid(row_valid), .row_ready(row_ready),
        .row_job_id(row_job_id), .row_tag(row_tag), .row_set(row_set),
        .row_addr(row_addr), .row_beats(row_beats),
        .row_head_skip(row_head_skip), .row_valid_bytes(row_valid_bytes),
        .row_local_y(row_local_y), .row_last(row_last),
        .urow_valid(urow_valid), .urow_ready(urow_ready),
        .urow_head_skip(urow_head_skip), .urow_valid_bytes(urow_valid_bytes),
        .urow_beats(urow_beats), .urow_local_y(urow_local_y),
        .urow_set(urow_set), .urow_tag(urow_tag),
        .urow_row_last(urow_row_last), .urow_tile_last(urow_tile_last),
        .busy(busy), .done(done), .geom_bad(geom_bad)
    );

    // ------------------------------------------------------------- backpressure
    integer seed = 32'h1F2E_3D4C;
    reg bp_en = 0;
    always @(posedge clk) begin
        if (bp_en) begin
            row_ready  <= (({$random(seed)} % 100) >= 30);
            urow_ready <= (({$random(seed)} % 100) >= 30);
        end
        else begin
            row_ready <= 1'b1; urow_ready <= 1'b1;
        end
    end

    // ------------------------------------------------------------- checker
    integer n_rows = 0;
    integer blk0 = 0;
    reg     check_en = 1'b1;
    integer n_done = 0;
    integer exp_rows = 0;
    reg [31:0] e_addr [0:127];
    reg [4:0]  e_beats[0:127], e_skip[0:127];
    reg [7:0]  e_bytes[0:127];
    integer    e_tag  [0:127];
    integer    e_base [0:127];

    always @(posedge clk) if (rst_n && done) n_done = n_done + 1;

    task build_expect(input [31:0] base, input [10:0] bx, by,
                      input [6:0] w, h);
        integer r;
        reg [63:0] sb;
        begin
            exp_rows = h;
            for (r = 0; r < h; r = r + 1) begin
                sb = base + ((by + r) * 5760) + (3 * bx);
                e_addr[r]  = (sb / 32) * 32;
                e_skip[r]  = sb % 32;
                e_bytes[r] = 3 * w;
                e_beats[r] = (e_skip[r] + e_bytes[r] + 31) / 32;
                e_tag[r]   = tile_tag;
                e_base[r]  = base;
            end
        end
    endtask

    // both ports must present the same row; compare on the joint handshake
    always @(posedge clk) begin
        if (rst_n && check_en && row_valid && urow_valid && row_ready && urow_ready) begin
            if (row_addr !== e_addr[n_rows - blk0]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d addr exp=%08h act=%08h", n_rows, e_addr[n_rows - blk0], row_addr);
            end
            if (row_head_skip !== e_skip[n_rows - blk0]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d skip exp=%0d act=%0d", n_rows, e_skip[n_rows - blk0], row_head_skip);
            end
            if (row_valid_bytes !== e_bytes[n_rows - blk0]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d bytes exp=%0d act=%0d", n_rows, e_bytes[n_rows - blk0], row_valid_bytes);
            end
            if (row_beats !== e_beats[n_rows - blk0]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d beats exp=%0d act=%0d", n_rows, e_beats[n_rows - blk0], row_beats);
            end
            if (row_local_y !== (n_rows - blk0)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d local_y act=%0d", n_rows, row_local_y);
            end
            if (row_last !== ((n_rows - blk0) == exp_rows - 1)) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d row_last=%b", n_rows, row_last);
            end
            if (urow_row_last !== row_last || urow_tile_last !== row_last) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d unpack last flags disagree", n_rows);
            end
            if (urow_head_skip !== row_head_skip || urow_beats !== row_beats ||
                urow_valid_bytes !== row_valid_bytes || urow_local_y !== row_local_y) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d the two descriptor copies disagree", n_rows);
            end
            if (row_tag !== e_tag[n_rows - blk0] || urow_tag !== e_tag[n_rows - blk0]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d tag mismatch", n_rows);
            end
            if (row_set !== 1'b0 || urow_set !== 1'b0) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d cache_set should be 0 here", n_rows);
            end
            if (row_job_id !== 32'hCAFE_0001) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: row %0d job_id not carried", n_rows);
            end
            n_rows = n_rows + 1;
        end
    end

    task run_block(input [31:0] base, input [10:0] bx, by, input [6:0] w, h,
                   input rr_stall);
        integer before, guard;
        begin
            tile_tag = tile_tag + 1;
            frame_base = base; bbox_x = bx; bbox_y = by; bbox_w = w; bbox_h = h;
            build_expect(base, bx, by, w, h);
            before = n_rows;
            blk0 = n_rows;
            bp_en = rr_stall;
            start <= 1'b1;
            @(posedge clk); #0.2;
            start <= 1'b0;
            guard = 0;
            while ((n_rows < before + exp_rows) && guard < 20000) begin
                @(posedge clk); #0.2;
                guard = guard + 1;
            end
            repeat (4) @(posedge clk);
            bp_en = 1'b0;
            if (n_rows != before + exp_rows) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: block %0dx%0d produced %0d rows, expected %0d",
                         w, h, n_rows - before, exp_rows);
            end
        end
    endtask

    integer i;

    initial begin
        rst_n = 0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        repeat (3) @(posedge clk);

        // =============================================================== P1
        run_block(32'h0000_0000, 11'd64, 11'd32, 7'd33, 7'd17, 1'b0);
        if (n_done != 1) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P1 done pulses=%0d", n_done); end
        else $display("TEST_INFO: P1 33x17 bbox at (64,32): 17 rows, fields exact");

        // =============================================================== P2
        run_block(32'h0200_0000, 11'd1888, 11'd1072, 7'd32, 7'd8, 1'b0);
        $display("TEST_INFO: P2 last-stripe block: 8 rows, addresses match the byte formula");

        // =============================================================== P3
        for (i = 0; i < 24; i = i + 1) begin
            run_block(32'h0100_0000 * (i % 3),
                      (i * 97) % 1920,
                      (i * 53) % 1080,
                      32 + (i % 32),
                      1 + (i % 16),
                      1'b1);
        end
        $display("TEST_INFO: P3 %0d rows through random backpressure, both copies identical", n_rows);

        // =============================================================== P4
        // 100 pixels wide cannot be one row window (beats would exceed 7)
        check_en = 1'b0;
        frame_base = 32'd0; bbox_x = 11'd0; bbox_y = 11'd0;
        bbox_w = 7'd100; bbox_h = 7'd2;
        start <= 1'b1;
        @(posedge clk); #0.2;
        start <= 1'b0;
        repeat (12) @(posedge clk);
        if (!geom_bad) begin dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: P4 an over-wide block must set geom_bad"); end
        else $display("TEST_INFO: P4 a block wider than 64 is flagged, not truncated");

        `DGC_FINISH
    end
endmodule
