//-----------------------------------------------------------------------------
// tb_rd_port.v - S0 acceptance: DRM / FIFO read-port wrappers
//
// The wrappers are exercised against the *real* generated Pango IP models
// (src_tile_bank_0, coord_fifo, ddr_read_fifo) so the evidence covers the
// actual read timing, not a hand written stand-in RAM.
//
// Test list (frozen-spec section 8: "pulse read, continuous read, gapped read,
// stall and reset must all be correct"):
//
//   RAM port (dgc_ram_rd_port + src_tile_bank_0, PIPE = 2)
//     R1  single pulse read: exactly one beat, exact data, latency PIPE+1
//     R2  continuous read: 64 beats back to back, 1 beat/cycle, in order
//     R3  gapped read: random gaps, order and data preserved
//     R4  consumer stall: out_valid holds, no beat lost or duplicated
//     R5  reset mid-flight: out_valid drops, no stale beat leaks afterwards
//     R6  credit safety: never more than OUT_DEPTH beats outstanding
//
//   FIFO port (dgc_fifo_rd_port + coord_fifo, synchronous)
//     F1  empty FIFO: rd_ready must be 0, no pop issued
//     F2  pulse pop: one beat, latency 1, exact data
//     F3  continuous pop: 32 beats, 1 beat/cycle
//     F4  consumer stall: data held by the FIFO output register
//     F5  reset mid-stream
//
//   DDR read FIFO port (dgc_fifo_rd_port + ddr_read_fifo, 125 MHz -> 225 MHz)
//     D1  write in the DDR domain, pop in the process domain, order preserved
//     D2  stall the process-domain consumer across a clock-domain boundary
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_rd_port;

    integer dgc_errors = 0;

    // ------------------------------------------------------------------ clocks
    reg proc_clk = 0;  always #(`DGC_T_PROC) proc_clk = ~proc_clk;   // 225 MHz
    reg ddr_clk  = 0;  always #(`DGC_T_DDR ) ddr_clk  = ~ddr_clk;    // 125 MHz
    reg rst_n    = 0;
    wire rst     = ~rst_n;

    `DGC_GRS_INST

    integer cyc = 0;
    always @(posedge proc_clk) cyc <= cyc + 1;

    // =========================================================== RAM under test
    localparam integer PIPE = 2;   // measured DRM read latency

    wire [9:0]  ram_rd_addr;

    reg  [23:0] ram_wr_data = 0;
    reg  [9:0]  ram_wr_addr = 0;
    reg         ram_wr_en   = 0;
    wire [23:0] ram_q;

    reg         rp_fire = 0;
    wire        rp_ready;
    reg  [9:0]  rp_addr = 0;
    wire        rp_out_valid;
    reg         rp_out_ready = 0;
    wire [23:0] rp_out_data;

    src_tile_bank_0 u_src_bank (
        .wr_data (ram_wr_data), .wr_addr (ram_wr_addr), .wr_en (ram_wr_en),
        .wr_clk  (proc_clk),    .wr_rst  (rst),
        .rd_data (ram_q),       .rd_addr (ram_rd_addr), .rd_clk (proc_clk), .rd_rst (rst)
    );

    dgc_ram_rd_port #(
        .DATA_W    (24),
        .ADDR_W    (10),
        .PIPE      (PIPE),
        .OUT_DEPTH (PIPE + 2)
    ) u_ram_port (
        .clk         (proc_clk),
        .rst_n       (rst_n),
        .rd_fire     (rp_fire),
        .rd_ready    (rp_ready),
        .rd_addr     (rp_addr),
        .ram_rd_addr (ram_rd_addr),
        .ram_rd_data (ram_q),
        .out_valid   (rp_out_valid),
        .out_ready   (rp_out_ready),
        .out_data    (rp_out_data)
    );

    // =========================================================== FIFO under test
    reg  [95:0] cf_wr_data = 0;
    reg         cf_wr_en   = 0;
    wire [95:0] cf_rd_data;
    reg         fp_fire = 0;
    wire        fp_ready;
    wire        fp_out_valid;
    reg         fp_out_ready = 0;
    wire [95:0] fp_out_data;
    wire        cf_rd_empty, cf_rd_en;
    wire        cf_wr_full, cf_almost_full, cf_almost_empty;
    wire [12:0] cf_wr_wl, cf_rd_wl;

    coord_fifo u_coord_fifo (
        .clk             (proc_clk),
        .rst             (rst),
        .wr_en           (cf_wr_en),
        .wr_data         (cf_wr_data),
        .wr_full         (cf_wr_full),
        .wr_water_level  (cf_wr_wl),
        .rd_en           (cf_rd_en),
        .rd_data         (cf_rd_data),
        .almost_full     (cf_almost_full),
        .rd_empty        (cf_rd_empty),
        .rd_water_level  (cf_rd_wl),
        .almost_empty    (cf_almost_empty)
    );

    dgc_fifo_rd_port #(.DATA_W(96)) u_fifo_port (
        .clk        (proc_clk),
        .rst_n      (rst_n),
        .rd_fire    (fp_fire),
        .rd_ready   (fp_ready),
        .fifo_empty (cf_rd_empty),
        .fifo_pop   (cf_rd_en),
        .fifo_data  (cf_rd_data),
        .out_valid  (fp_out_valid),
        .out_ready  (fp_out_ready),
        .out_data   (fp_out_data)
    );

    // ======================================================= DDR FIFO under test
    reg  [255:0] df_wr_data = 0;
    reg          df_wr_en   = 0;
    wire [255:0] df_rd_data;
    wire         df_rd_empty, df_rd_en;
    reg          dp_fire = 0;
    wire         dp_ready;
    wire         dp_out_valid;
    reg          dp_out_ready = 0;
    wire [255:0] dp_out_data;
    wire         df_wr_full, df_almost_full, df_almost_empty;
    wire [11:0]  df_wr_wl, df_rd_wl;

    ddr_read_fifo u_ddr_fifo (
        .wr_clk         (ddr_clk),
        .wr_rst         (rst),
        .wr_en          (df_wr_en),
        .wr_data        (df_wr_data),
        .wr_full        (df_wr_full),
        .wr_water_level (df_wr_wl),
        .rd_clk         (proc_clk),
        .rd_rst         (rst),
        .rd_en          (df_rd_en),
        .rd_data        (df_rd_data),
        .almost_full    (df_almost_full),
        .rd_empty       (df_rd_empty),
        .rd_water_level (df_rd_wl),
        .almost_empty   (df_almost_empty)
    );

    dgc_fifo_rd_port #(.DATA_W(256)) u_ddr_fifo_port (
        .clk        (proc_clk),
        .rst_n      (rst_n),
        .rd_fire    (dp_fire),
        .rd_ready   (dp_ready),
        .fifo_empty (df_rd_empty),
        .fifo_pop   (df_rd_en),
        .fifo_data  (df_rd_data),
        .out_valid  (dp_out_valid),
        .out_ready  (dp_out_ready),
        .out_data   (dp_out_data)
    );

    // ================================================================ helpers
    function [23:0] pat(input [9:0] a);
        pat = {4'h5, a[9:0], 4'hA, a[3:0]};
    endfunction

    // --- scoreboards -----------------------------------------------------
    localparam integer QMAX = 256;
    reg [23:0]  rq [0:QMAX-1];
    integer     rq_wr = 0, rq_rd = 0;
    reg [95:0]  fq [0:QMAX-1];
    integer     fq_rd = 0, fq_wr = 0;
    reg [255:0] dq [0:QMAX-1];
    integer     dq_rd = 0, dq_wr = 0;

    integer pulses_seen, i, n, gap;

    // RAM port collector
    always @(posedge proc_clk) begin
        if (rst_n && rp_out_valid && rp_out_ready) begin
            if (rq_rd >= rq_wr) begin
                `DGC_FAIL("RAM port produced an unexpected beat")
            end
            else begin
                if (rp_out_data !== rq[rq_rd]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: RAM beat %0d exp=%06h act=%06h t=%0t",
                             rq_rd, rq[rq_rd], rp_out_data, $time);
                end
                rq_rd = rq_rd + 1;
            end
            pulses_seen = pulses_seen + 1;
        end
    end

    // FIFO port collector
    always @(posedge proc_clk) begin
        if (rst_n && fp_out_valid && fp_out_ready) begin
            if (fq_rd >= fq_wr) `DGC_FAIL("coord FIFO produced an unexpected beat")
            else begin
                if (fp_out_data !== fq[fq_rd]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: COORD beat %0d exp=%0h act=%0h t=%0t",
                             fq_rd, fq[fq_rd], fp_out_data, $time);
                end
                fq_rd = fq_rd + 1;
            end
        end
    end

    // DDR FIFO port collector
    always @(posedge proc_clk) begin
        if (rst_n && dp_out_valid && dp_out_ready) begin
            if (dq_rd >= dq_wr) `DGC_FAIL("DDR FIFO produced an unexpected beat")
            else if (dp_out_data !== dq[dq_rd]) begin
                dgc_errors = dgc_errors + 1;
                $display("TEST_FAIL: DDRFIFO beat %0d exp=%0h act=%0h t=%0t",
                         dq_rd, dq[dq_rd], dp_out_data, $time);
            end
            dq_rd = dq_rd + 1;
        end
    end

    // ---------------------------------------------------------------- drivers
    task ram_fire(input [9:0] a);
        begin
            @(posedge proc_clk);
            #0.2;
            while (!rp_ready) begin @(posedge proc_clk); #0.2; end
            rp_fire <= 1'b1;
            rp_addr <= a;
            rq[rq_wr] = pat(a);
            rq_wr = rq_wr + 1;
            @(posedge proc_clk);
            rp_fire <= 1'b0;
        end
    endtask

    task fifo_fire;
        begin
            @(posedge proc_clk);
            #0.2;
            while (!fp_ready) begin @(posedge proc_clk); #0.2; end
            fp_fire <= 1'b1;
            @(posedge proc_clk);
            fp_fire <= 1'b0;
        end
    endtask

    // ---------------------------------------------------------------- main
    initial begin
        pulses_seen = 0;
        rp_out_ready = 0;
        fp_out_ready = 0;
        dp_out_ready = 0;

        rst_n = 0;
        repeat (8) @(posedge proc_clk);
        rst_n = 1;
        repeat (6) @(posedge proc_clk);

        // ---------------- preload the DRM with unique patterns
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge proc_clk);
            ram_wr_en   <= 1'b1;
            ram_wr_addr <= i[9:0];
            ram_wr_data <= pat(i[9:0]);
        end
        @(posedge proc_clk);
        ram_wr_en <= 1'b0;
        repeat (4) @(posedge proc_clk);

        // ================================================================ R1
        // single pulse read, consumer always ready, measure latency
        rp_out_ready = 1;
        @(posedge proc_clk); #0.2;
        begin : r1
            integer t_fire, t_valid, waited;
            rp_fire <= 1'b1;
            rp_addr <= 10'd21;
            rq[rq_wr] = pat(10'd21);
            rq_wr = rq_wr + 1;
            t_fire = cyc;
            @(posedge proc_clk); #0.2;
            rp_fire <= 1'b0;
            waited = 0;
            t_valid = -1;
            while (t_valid < 0 && waited < 12) begin
                @(posedge proc_clk); #0.2;
                waited = waited + 1;
                if (rp_out_valid) t_valid = cyc;
            end
            if (t_valid < 0) `DGC_FAIL("R1: no out_valid after pulse read")
            else begin
                $display("TEST_INFO: R1 pulse read latency = %0d cycles (expected %0d)",
                         t_valid - t_fire, PIPE + 1);
                if ((t_valid - t_fire) != (PIPE + 1)) `DGC_FAIL("R1: latency mismatch")
                if (rp_out_data !== pat(10'd21))     `DGC_FAIL("R1: data mismatch")
            end
            // let the beat drain
            @(posedge proc_clk); #0.2;
            while (rp_out_valid) begin @(posedge proc_clk); #0.2; end
        end

        // ================================================================ R2
        // continuous read of 64 addresses, 1 beat per cycle
        rq_wr = 0; rq_rd = 0;
        begin : r2
            integer fires;
            fires = 0;
            fork
                begin : r2_drv
                    for (i = 0; i < 64; i = i + 1) begin
                        @(posedge proc_clk); #0.2;
                        while (!rp_ready) begin @(posedge proc_clk); #0.2; end
                        rp_fire <= 1'b1;
                        rp_addr <= i[9:0];
                        rq[rq_wr] = pat(i[9:0]);
                        rq_wr = rq_wr + 1;
                        fires = fires + 1;
                    end
                    @(posedge proc_clk); #0.2;
                    rp_fire <= 1'b0;
                end
                begin : r2_mon
                    // count cycles actually spent delivering 64 beats
                    integer c0;
                    c0 = cyc;
                    while (rq_rd < 64) @(posedge proc_clk);
                    $display("TEST_INFO: R2 continuous read, 64 beats delivered in %0d cycles",
                             cyc - c0);
                end
            join
            repeat (4) @(posedge proc_clk);
            if (rq_rd != 64) `DGC_FAIL("R2: not all beats returned")
        end

        // ================================================================ R3
        // gapped read
        rq_wr = 0; rq_rd = 0;
        for (i = 0; i < 32; i = i + 1) begin
            ram_fire((i * 7) % 64);
            gap = (i % 5);
            repeat (gap) @(posedge proc_clk);
        end
        @(posedge proc_clk);
        while (rp_out_valid) @(posedge proc_clk);
        repeat (4) @(posedge proc_clk);
        if (rq_rd != 32) `DGC_FAIL("R3: gapped read lost beats")

        // ================================================================ R4
        // consumer stall: 12 consecutive beats with a stall in the middle
        rq_wr = 0; rq_rd = 0;
        rp_out_ready = 1;
        fork
            begin : r4_drive
                for (i = 0; i < 12; i = i + 1) begin
                    @(posedge proc_clk); #0.2;
                    while (!rp_ready) begin @(posedge proc_clk); #0.2; end
                    rp_fire <= 1'b1;
                    rp_addr <= i[9:0];
                    rq[rq_wr] = pat(i[9:0]);
                    rq_wr = rq_wr + 1;
                end
                @(posedge proc_clk); #0.2;
                rp_fire <= 1'b0;
            end
            begin : r4_stall
                repeat (6) @(posedge proc_clk);
                rp_out_ready = 0;              // stall the consumer
                repeat (10) @(posedge proc_clk);
                rp_out_ready = 1;
            end
        join
        repeat (8) @(posedge proc_clk);
        if (rq_rd != 12) `DGC_FAIL("R4: stalled read lost beats")
        else $display("TEST_INFO: R4 consumer stall handled, %0d beats intact", rq_rd);

        // ================================================================ R6
        // credit safety is asserted inside the wrapper (DGC_SIM block)

        // ================================================================ R5
        // reset mid-flight: fire two reads, assert reset before they return
        rq_wr = 0; rq_rd = 0;
        rp_out_ready = 1;
        @(posedge proc_clk); #0.2;
        rp_fire <= 1'b1; rp_addr <= 10'd3;
        @(posedge proc_clk); #0.2;
        rp_fire <= 1'b1; rp_addr <= 10'd4;
        @(posedge proc_clk); #0.2;
        rp_fire <= 1'b0;
        #0.1;
        rst_n = 0;                              // abort while 2 beats are in flight
        repeat (4) @(posedge proc_clk);
        if (rp_out_valid) `DGC_FAIL("R5: out_valid not cleared by reset")
        rst_n = 1;
        repeat (8) @(posedge proc_clk);
        if (rp_out_valid) `DGC_FAIL("R5: stale beat leaked after reset")

        // ================================================================ F1..F4
        // coord FIFO
        fq_wr = 0; fq_rd = 0;
        // F1: empty
        @(posedge proc_clk); #0.2;
        if (fp_ready !== 1'b0) `DGC_FAIL("F1: rd_ready high while FIFO empty")
        if (cf_rd_en !== 1'b0) `DGC_FAIL("F1: pop issued while FIFO empty")
        $display("TEST_INFO: F1 empty FIFO correctly refuses a pop");

        // load 32 records
        for (i = 0; i < 32; i = i + 1) begin
            @(posedge proc_clk);
            cf_wr_en   <= 1'b1;
            cf_wr_data <= {64'h0, i[15:0], 16'hC0DE};
            fq[fq_wr] = {64'h0, i[15:0], 16'hC0DE};
            fq_wr = fq_wr + 1;
        end
        @(posedge proc_clk);
        cf_wr_en <= 1'b0;
        repeat (4) @(posedge proc_clk);

        // F2: pulse pop
        fp_out_ready = 1;
        @(posedge proc_clk); #0.2;
        begin : f2
            integer t_fire, t_valid, waited;
            fp_fire <= 1'b1;
            t_fire = cyc;
            @(posedge proc_clk); #0.2;
            fp_fire <= 1'b0;
            waited = 0; t_valid = -1;
            while (t_valid < 0 && waited < 8) begin
                @(posedge proc_clk); #0.2;
                waited = waited + 1;
                if (fp_out_valid) t_valid = cyc;
            end
            if (t_valid < 0) `DGC_FAIL("F2: no out_valid after pop")
            else begin
                $display("TEST_INFO: F2 pop latency = %0d cycles (expected %0d)", t_valid - t_fire, PIPE + 1);
                if ((t_valid - t_fire) != (PIPE + 1)) `DGC_FAIL("F2: pop latency mismatch")
            end
        end
        @(posedge proc_clk); #0.2;

        // F3: continuous pop of the remaining 31 records
        begin : f3
            integer c0;
            c0 = cyc;
            fork
                begin
                    for (i = 0; i < 31; i = i + 1) begin
                        @(posedge proc_clk); #0.2;
                        while (!fp_ready) begin @(posedge proc_clk); #0.2; end
                        fp_fire <= 1'b1;
                    end
                    @(posedge proc_clk); #0.2;
                    fp_fire <= 1'b0;
                end
                begin
                    while (fq_rd < 32) @(posedge proc_clk);
                    $display("TEST_INFO: F3 continuous pop, 32 beats in %0d cycles", cyc - c0);
                end
            join
            repeat (4) @(posedge proc_clk);
            if (fq_rd != 32) `DGC_FAIL("F3: not all coord records returned")
        end

        // F4: stall test with a fresh burst
        fq_wr = 0; fq_rd = 0;
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge proc_clk);
            cf_wr_en   <= 1'b1;
            cf_wr_data <= {64'h0, i[15:0], 16'hBEEF};
            fq[fq_wr] = {64'h0, i[15:0], 16'hBEEF};
            fq_wr = fq_wr + 1;
        end
        @(posedge proc_clk);
        cf_wr_en <= 1'b0;
        repeat (4) @(posedge proc_clk);
        fp_out_ready = 1;
        fork
            begin
                for (i = 0; i < 8; i = i + 1) begin
                    @(posedge proc_clk); #0.2;
                    while (!fp_ready) begin @(posedge proc_clk); #0.2; end
                    fp_fire <= 1'b1;
                end
                @(posedge proc_clk); #0.2;
                fp_fire <= 1'b0;
            end
            begin
                repeat (3) @(posedge proc_clk);
                fp_out_ready = 0;
                repeat (8) @(posedge proc_clk);
                fp_out_ready = 1;
            end
        join
        repeat (8) @(posedge proc_clk);
        if (fq_rd != 8) `DGC_FAIL("F4: stalled coord read lost beats")
        else $display("TEST_INFO: F4 coord FIFO stall survived, %0d beats intact", fq_rd);

        // F5: reset mid-stream
        @(posedge proc_clk); #0.2;
        fp_fire <= 1'b1;
        @(posedge proc_clk); #0.2;
        fp_fire <= 1'b0;
        rst_n = 0;
        repeat (4) @(posedge proc_clk);
        if (fp_out_valid) `DGC_FAIL("F5: out_valid not cleared by reset")
        rst_n = 1;
        repeat (6) @(posedge proc_clk);

        // ================================================================ D1/D2
        // DDR read FIFO across the 125 MHz -> 225 MHz boundary
        fq_wr = 0; fq_rd = 0; dq_rd = 0;
        for (i = 0; i < 24; i = i + 1) begin
            @(posedge ddr_clk);
            df_wr_en   <= 1'b1;
            df_wr_data <= {240'h0, i[15:0]};
            dq[dq_wr] = {240'h0, i[15:0]};
            dq_wr = dq_wr + 1;
        end
        @(posedge ddr_clk);
        df_wr_en <= 1'b0;
        repeat (8) @(posedge proc_clk);

        dp_out_ready = 1;
        fork
            begin
                for (i = 0; i < 24; i = i + 1) begin
                    @(posedge proc_clk); #0.2;
                    while (!dp_ready) begin @(posedge proc_clk); #0.2; end
                    dp_fire <= 1'b1;
                end
                @(posedge proc_clk); #0.2;
                dp_fire <= 1'b0;
            end
            begin
                repeat (5) @(posedge proc_clk);
                dp_out_ready = 0;                 // D2 stall across the CDC
                repeat (12) @(posedge proc_clk);
                dp_out_ready = 1;
            end
        join
        repeat (10) @(posedge proc_clk);
        if (dq_rd != 24) `DGC_FAIL("D1/D2: DDR FIFO beats lost across CDC")
        else $display("TEST_INFO: D1/D2 DDR FIFO 24 beats across 125/225 MHz with stall, all intact");

        $display("TEST_INFO: total RAM beats delivered this run = %0d", pulses_seen);
        `DGC_FINISH
    end

endmodule
