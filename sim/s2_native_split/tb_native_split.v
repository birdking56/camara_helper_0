//-----------------------------------------------------------------------------
// tb_native_split.v - 4 KiB boundary handling
//   K1  a request that does not reach the boundary stays a single request
//   K2  a request that reaches it is split, and the two parts sum to the total
//   K3  the first part ends exactly on the boundary and the second starts there
//   K4  neither part crosses a page
//   K5  exhaustive over a whole page's worth of aligned addresses x beats 1..7
//   K6  addr_ok reflects the 28-bit word address limit
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_native_split;
    integer dgc_errors = 0;

    reg  [31:0] aligned_addr = 32'h0100_0000;
    reg  [4:0]  beats = 1;
    wire        cross, is_single, addr_ok;
    wire [4:0]  first_beats, second_beats;
    wire [31:0] second_addr;

    dgc_native_split u_dut (
        .aligned_addr(aligned_addr), .beats(beats),
        .cross(cross), .first_beats(first_beats), .second_beats(second_beats),
        .second_addr(second_addr), .is_single(is_single), .addr_ok(addr_ok));

    integer off, b, n_cross, n_single;
    reg [31:0] a, end1, end2;

    initial begin
        n_cross = 0; n_single = 0;

        // ============================================================== K5
        // sweep one page worth of 32-byte-aligned offsets, all legal beat counts
        for (off = 0; off < 4096; off = off + 32)
        for (b = 1; b <= 7; b = b + 1) begin
            aligned_addr = 32'h0100_0000 + off[31:0];
            beats = b[4:0];
            #0;

            if (cross) begin
                n_cross = n_cross + 1;
                // K2: the two parts are the whole request
                if (first_beats + second_beats !== beats) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8)
                    $display("TEST_FAIL: K2 parts do not sum off=%0d beats=%0d", off, b);
                end
                // K3: the split lands on the boundary
                end1 = aligned_addr + ({27'd0, first_beats} << 5) - 1;
                if (end1[11:0] !== 12'hFFF) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8)
                    $display("TEST_FAIL: K3 first part does not end on the boundary off=%0d", off);
                end
                if (second_addr !== (aligned_addr + (32'h1000 - aligned_addr[11:0]))) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8)
                    $display("TEST_FAIL: K3 second start wrong off=%0d", off);
                end
                end2 = second_addr + ({27'd0, second_beats} << 5) - 1;
                // K4: neither part crosses
                if (aligned_addr[31:12] !== end1[31:12]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: K4 first part still crosses");
                end
                if (second_addr[31:12] !== end2[31:12]) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: K4 second part crosses");
                end
                if (first_beats < 1 || first_beats > 7) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: K2 first_beats out of 1..7");
                end
                if (second_beats < 1 || second_beats > 7) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: K2 second_beats out of 1..7");
                end
                if (is_single) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: K1 is_single set on a crossing request");
                end
            end
            else begin
                n_single = n_single + 1;
                if (first_beats !== beats || second_beats !== 0) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8)
                    $display("TEST_FAIL: K1 a single request must pass the beat count through");
                end
                if (!is_single) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: K1 is_single missing");
                end
            end
        end
        $display("TEST_INFO: K5 swept 128 page offsets x 7 beat counts: %0d split, %0d single",
                 n_cross, n_single);
        $display("TEST_INFO: K2/K3 parts sum to the request and the split lands exactly on 4 KiB");
        $display("TEST_INFO: K4 neither part crosses a page");

        // ============================================================== K6
        aligned_addr = 32'h3FFF_FFE0; beats = 5'd1; #0;
        if (!addr_ok) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: K6 just below 1 GiB must be addressable");
        end
        aligned_addr = 32'h3FFF_FFE0; beats = 5'd2; #0;
        if (addr_ok) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: K6 crossing 1 GiB must be refused");
        end
        else $display("TEST_INFO: K6 the 28-bit word address limit is reported, not truncated");

        // a concrete split example
        aligned_addr = 32'h0100_0FE0; beats = 5'd7; #0;
        $display("TEST_INFO: K example addr=%08h beats=%0d -> cross=%0d first=%0d second=%0d at %08h",
                 aligned_addr, beats, cross, first_beats, second_beats, second_addr);
        `DGC_FINISH
    end
endmodule
