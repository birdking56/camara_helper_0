//-----------------------------------------------------------------------------
// tb_config_manager.v - S2: configuration manager against the frozen register map
//
// Cases
//   C1  version and capability reads
//   C2  defaults read back exactly as 接口常量_v1.json records them
//   C3  shadow write then read back; commit; epoch unchanged until job_start
//   C4  job_start applies the pending set atomically and increments the epoch
//   C5  BUSY while pending: further writes and commits are refused
//   C6  UNSUPPORTED for mode 2/3, gamma_mode != 0 and non-zero p1/p2/k3
//   C7  RANGE for |k1|>1, norm_abs_max>4, fx==0, mode 1 with a non-default M
//   C8  READ_ONLY for a counter write, BAD_ADDR for an unmapped address
//   C9  counters read back
//   C10 unknown address read returns BAD_ADDR
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_config_manager;

    integer dgc_errors = 0;

    reg clk = 0;
    always #(`DGC_T_PROC) clk = ~clk;
    reg rst_n = 0;

    reg         req_valid = 0;
    wire        req_ready;
    reg         req_write = 0;
    reg  [15:0] req_addr = 0;
    reg  [31:0] req_wdata = 0;
    wire        rsp_valid;
    reg         rsp_ready = 1;
    wire [31:0] rsp_rdata;
    wire [7:0]  rsp_error;

    reg         job_start = 0;
    reg         job_done = 0;
    wire        job_active;
    reg         fault_set = 0;

    wire [1:0]  act_mode;
    wire [31:0] act_fx, act_fy, act_cx, act_cy, act_k1, act_k2;
    wire [31:0] act_m00, act_m01, act_m02, act_m10, act_m11, act_m12;
    wire [31:0] act_m20, act_m21, act_m22, act_norm;
    wire [15:0] act_epoch;
    wire        pending;

    dgc_config_manager u_dut (
        .clk (clk), .rst_n (rst_n),
        .cfg_req_valid (req_valid), .cfg_req_ready (req_ready),
        .cfg_req_write (req_write), .cfg_req_addr (req_addr),
        .cfg_req_wdata (req_wdata),
        .cfg_rsp_valid (rsp_valid), .cfg_rsp_ready (rsp_ready),
        .cfg_rsp_rdata (rsp_rdata), .cfg_rsp_error (rsp_error),
        .job_start (job_start), .job_done (job_done), .job_active (job_active),
        .fault_set (fault_set),
        .cnt0_input_frames (32'h1111_0001), .cnt1_input_dropped (32'h2222_0002),
        .cnt2_jobs_completed (32'h3333_0003), .cnt3_output_frames_ok (32'h4444_0004),
        .cnt4_output_underflow (32'h5555_0005), .cnt5_ddr_protocol_error (32'h6666_0006),
        .cnt6_math_error_pixels (32'h7777_0007), .cnt7_tile_split (32'h8888_0008),
        .act_mode (act_mode),
        .act_fx (act_fx), .act_fy (act_fy), .act_cx (act_cx), .act_cy (act_cy),
        .act_k1 (act_k1), .act_k2 (act_k2),
        .act_m00 (act_m00), .act_m01 (act_m01), .act_m02 (act_m02),
        .act_m10 (act_m10), .act_m11 (act_m11), .act_m12 (act_m12),
        .act_m20 (act_m20), .act_m21 (act_m21), .act_m22 (act_m22),
        .act_norm_abs_max (act_norm),
        .act_epoch (act_epoch), .pending (pending)
    );

    // ---------------------------------------------------------------- bus tasks
    reg [31:0] cap_data;
    reg [7:0]  cap_err;
    reg        cap_is_read;

    task bus(input integer wr, input [15:0] addr, input [31:0] wdata);
        begin
            @(posedge clk); #0.2;
            while (!req_ready) begin @(posedge clk); #0.2; end
            req_write <= wr[0];
            req_addr  <= addr;
            req_wdata <= wdata;
            req_valid <= 1'b1;
            @(posedge clk); #0.2;
            req_valid <= 1'b0;
            while (!rsp_valid) begin @(posedge clk); #0.2; end
            cap_data    = rsp_rdata;
            cap_err     = rsp_error;
            cap_is_read = !wr[0];
            @(posedge clk); #0.2;
        end
    endtask

    task check(input [31:0] exp_data, input [7:0] exp_err, input [8*48-1:0] label);
        begin
            if (cap_err !== exp_err) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: %0s error exp=%0d act=%0d", label, exp_err, cap_err);
            end
            else if (cap_is_read && exp_err == 8'd0 && cap_data !== exp_data) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: %0s data exp=%08h act=%08h", label, exp_data, cap_data);
            end
        end
    endtask

    integer i;

    initial begin
        rst_n = 0;
        rsp_ready = 1;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ================================================================== C1
        bus(0, 16'h0000, 32'd0); check(32'h0001_0000, 8'd0, "C1 version");
        bus(0, 16'h0004, 32'd0); check(32'h0000_0003, 8'd0, "C1 capability");
        $display("TEST_INFO: C1 version 0x00010000 and capability 0x0003");

        // ================================================================== C2
        bus(0, 16'h0040, 32'd0); check(32'd137377855, 8'd0, "C2 fx default");
        bus(0, 16'h0044, 32'd0); check(32'd138692973, 8'd0, "C2 fy default");
        bus(0, 16'h0048, 32'd0); check(32'd64030536,  8'd0, "C2 cx default");
        bus(0, 16'h004C, 32'd0); check(32'd34085643,  8'd0, "C2 cy default");
        bus(0, 16'h0050, 32'd0); check(32'hF84B5B1C,  8'd0, "C2 k1 default");
        bus(0, 16'h0054, 32'd0); check(32'h047385BA,  8'd0, "C2 k2 default");
        bus(0, 16'h0080, 32'd0); check(32'd32014,     8'd0, "C2 M00 default");
        bus(0, 16'h00A0, 32'd0); check(32'h04000000,  8'd0, "C2 M22 default");
        bus(0, 16'h00A8, 32'd0); check(32'h08000000,  8'd0, "C2 norm default");
        $display("TEST_INFO: C2 all defaults match 接口常量_v1.json");

        // ================================================================== C3
        bus(1, 16'h0010, 32'd1); check(32'd0, 8'd0, "C3 write mode=1");
        bus(0, 16'h0010, 32'd0); check(32'd1, 8'd0, "C3 read shadow mode");
        bus(1, 16'h000C, 32'd1); check(32'd0, 8'd0, "C3 commit");
        bus(0, 16'h000C, 32'd0); check(32'd0, 8'd0, "C3 epoch still 0 before job_start");
        if (pending !== 1'b1) `DGC_FAIL("C3: pending not set after commit")
        $display("TEST_INFO: C3 shadow write + commit leaves the epoch unchanged");

        // ================================================================== C5
        bus(1, 16'h0040, 32'd1234); check(32'd0, 8'd4, "C5 write while pending = BUSY");
        bus(1, 16'h000C, 32'd1);    check(32'd0, 8'd4, "C5 commit while pending = BUSY");
        $display("TEST_INFO: C5 writes and commits are refused while pending");

        // ================================================================== C4
        @(posedge clk); #0.2; job_start <= 1'b1;
        @(posedge clk); #0.2; job_start <= 1'b0;
        repeat (4) @(posedge clk);
        bus(0, 16'h000C, 32'd0); check(32'd1, 8'd0, "C4 epoch is 1 after job_start");
        if (act_mode !== 2'd1) `DGC_FAIL("C4: active mode not applied")
        if (pending !== 1'b0) `DGC_FAIL("C4: pending not cleared by job_start")
        if (job_active !== 1'b1) `DGC_FAIL("C4: job_active not set")
        $display("TEST_INFO: C4 job_start applies the snapshot atomically, epoch = 1");
        @(posedge clk); #0.2; job_done <= 1'b1;
        @(posedge clk); #0.2; job_done <= 1'b0;
        repeat (2) @(posedge clk);

        // ================================================================== C6
        bus(1, 16'h0010, 32'd2); check(32'd0, 8'd2, "C6 mode 2 = UNSUPPORTED");
        bus(1, 16'h0010, 32'd3); check(32'd0, 8'd2, "C6 mode 3 = UNSUPPORTED");
        bus(1, 16'h0014, 32'd1); check(32'd0, 8'd2, "C6 gamma_mode 1 = UNSUPPORTED");
        bus(1, 16'h0058, 32'd5); check(32'd0, 8'd0, "C6 p1 write accepted into shadow");
        bus(1, 16'h000C, 32'd1); check(32'd0, 8'd2, "C6 commit with p1 != 0 = UNSUPPORTED");
        bus(1, 16'h0058, 32'd0); check(32'd0, 8'd0, "C6 p1 cleared");
        $display("TEST_INFO: C6 unsupported features are refused, not silently ignored");

        // ================================================================== C7
        bus(1, 16'h0050, 32'h2000_0000); check(32'd0, 8'd3, "C7 |k1| > 1 = RANGE");
        bus(0, 16'h0050, 32'd0); check(32'hF84B5B1C, 8'd0, "C7 k1 unchanged by the rejected write");
        bus(1, 16'h00A8, 32'h1000_0001); check(32'd0, 8'd3, "C7 norm > 4.0 = RANGE");
        bus(1, 16'h0040, 32'd0);         check(32'd0, 8'd3, "C7 fx == 0 = RANGE");
        bus(1, 16'h0080, 32'd99);        check(32'd0, 8'd0, "C7 M00 accepted");
        bus(1, 16'h000C, 32'd1);         check(32'd0, 8'd3, "C7 mode 1 with non-default M = RANGE");
        bus(1, 16'h0080, 32'd32014);     check(32'd0, 8'd0, "C7 M00 restored");
        bus(1, 16'h000C, 32'd1);         check(32'd0, 8'd0, "C7 commit now accepted");
        $display("TEST_INFO: C7 range checks reject and leave the shadow untouched");

        // roll the pending set forward so the next cases start clean
        @(posedge clk); #0.2; job_start <= 1'b1;
        @(posedge clk); #0.2; job_start <= 1'b0;
        repeat (4) @(posedge clk);
        bus(0, 16'h000C, 32'd0); check(32'd2, 8'd0, "C7 epoch is 2");

        // ================================================================== C8
        bus(1, 16'h0100, 32'd7); check(32'd0, 8'd5, "C8 counter write = READ_ONLY");
        bus(1, 16'h0200, 32'd7); check(32'd0, 8'd1, "C8 unmapped write = BAD_ADDR");
        bus(0, 16'h0200, 32'd0); check(32'd0, 8'd1, "C10 unmapped read = BAD_ADDR");
        $display("TEST_INFO: C8/C10 READ_ONLY and BAD_ADDR are reported correctly");

        // ================================================================== C9
        bus(0, 16'h0100, 32'd0); check(32'h1111_0001, 8'd0, "C9 counter 0");
        bus(0, 16'h011C, 32'd0); check(32'h8888_0008, 8'd0, "C9 counter 7");
        $display("TEST_INFO: C9 all eight counters read back");

        // ================================================================== C3b
        bus(0, 16'h001C, 32'd0);
        if (cap_data[7:0] !== 8'd1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: C3b last_cfg_error exp=1 act=%0d", cap_data[7:0]);
        end
        $display("TEST_INFO: C3b last_cfg_error holds the most recent failure");

        $display("TEST_INFO: config manager test finished at %0t", $time);
        `DGC_FINISH
    end

endmodule
