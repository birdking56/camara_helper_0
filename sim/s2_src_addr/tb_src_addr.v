//-----------------------------------------------------------------------------
// tb_src_addr.v - the frozen source cache mapping
//   M1  (bank, addr) is bijective over a 64x64 block: 4096 distinct pairs
//   M2  each local bank holds exactly 1024 pixels and uses addresses 0..1023
//   M3  the four bilinear neighbours land in four different banks
//   M4  the fill partner at local_x+1 flips x parity, address +0 when x even else +1
//   M5  the set bit only selects banks 0-3 or 4-7
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dgc_tb.vh"

module tb_src_addr;
    integer dgc_errors = 0;

    reg         cache_set = 0;
    reg  [5:0]  lx = 0, ly = 0;
    wire [2:0]  bank;
    wire [9:0]  addr;
    wire [1:0]  local_bank;

    dgc_src_addr u_dut (.cache_set(cache_set), .lx(lx), .ly(ly),
                        .bank(bank), .addr(addr), .local_bank(local_bank));

    reg seen [0:2047];
    reg [1:0] b00, b10, b01, b11;
    reg [5:0] lx1, ly1;
    integer x, y, i, b, cnt, a_hold;
    reg [1:0] lb_hold;

    initial begin
        // ============================================================== M1
        for (i = 0; i < 2048; i = i + 1) seen[i] = 0;
        for (y = 0; y < 64; y = y + 1)
        for (x = 0; x < 64; x = x + 1) begin
            lx = x[5:0]; ly = y[5:0]; cache_set = 1'b0; #0;
            i = {local_bank, addr[9:0]};
            if (seen[i]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8)
                $display("TEST_FAIL: M1 collision at (%0d,%0d)", x, y);
            end
            seen[i] = 1;
        end
        $display("TEST_INFO: M1 4096 pixels map to 4096 distinct (bank,addr) pairs");

        // ============================================================== M2
        for (b = 0; b < 4; b = b + 1) begin
            cnt = 0;
            for (y = 0; y < 64; y = y + 1)
            for (x = 0; x < 64; x = x + 1) begin
                lx = x[5:0]; ly = y[5:0]; #0;
                if (local_bank == b[1:0]) begin
                    cnt = cnt + 1;
                    if (a_hold < 0) a_hold = 0;
                    if (addr > 10'd1023) begin
                        dgc_errors = dgc_errors + 1;
                        if (dgc_errors < 8) $display("TEST_FAIL: M2 address beyond the bank");
                    end
                end
            end
            if (cnt != 1024) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: M2 bank %0d holds %0d pixels not 1024", b, cnt);
            end
        end
        $display("TEST_INFO: M2 each local bank holds exactly 1024 pixels; a 64x64 block fills the DRM");

        // ============================================================== M3
        for (y = 0; y < 63; y = y + 1)
        for (x = 0; x < 63; x = x + 1) begin
            lx = x[5:0];     ly = y[5:0];     #0; b00 = local_bank;
            lx = x[5:0] + 6'd1; ly = y[5:0];  #0; b10 = local_bank;
            lx = x[5:0] + 6'd1; ly = y[5:0] + 6'd1; #0; b11 = local_bank;
            lx = x[5:0];     ly = y[5:0] + 6'd1; #0; b01 = local_bank;
            if (b00 == b10 || b00 == b01 || b00 == b11 ||
                b10 == b01 || b10 == b11 || b01 == b11) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8)
                $display("TEST_FAIL: M3 neighbours share a bank at (%0d,%0d)", x, y);
            end
        end
        $display("TEST_INFO: M3 the four neighbours always land in four different banks");

        // ============================================================== M4
        for (x = 0; x < 63; x = x + 1) begin
            lx = x[5:0]; ly = 6'd10; #0;
            a_hold = addr; lb_hold = local_bank;
            lx = x[5:0] + 6'd1; #0;
            if (local_bank[0] !== ~lb_hold[0]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: M4 x parity did not flip at x=%0d", x);
            end
            if (local_bank[1] !== lb_hold[1]) begin
                dgc_errors = dgc_errors + 1;
                if (dgc_errors < 8) $display("TEST_FAIL: M4 y parity changed at x=%0d", x);
            end
            if ((x % 2) == 0) begin
                if (addr !== a_hold) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: M4 even x must keep the address");
                end
            end
            else begin
                if (addr !== (a_hold + 10'd1)) begin
                    dgc_errors = dgc_errors + 1;
                    if (dgc_errors < 8) $display("TEST_FAIL: M4 odd x must advance the address");
                end
            end
        end
        $display("TEST_INFO: M4 the fill partner flips x parity and uses address +0 or +1");

        // ============================================================== M5
        lx = 6'd7; ly = 6'd9; cache_set = 1'b0; #0;
        a_hold = addr; lb_hold = local_bank;
        cache_set = 1'b1; #0;
        if (addr !== a_hold || local_bank !== lb_hold) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: M5 the set bit changed the local bank or address");
        end
        if (bank[2] !== 1'b1) begin
            dgc_errors = dgc_errors + 1;
            $display("TEST_FAIL: M5 set 1 must select banks 4-7");
        end
        else $display("TEST_INFO: M5 the set bit only selects banks 0-3 or 4-7");

        `DGC_FINISH
    end
endmodule
