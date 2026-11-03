//-----------------------------------------------------------------------------
// tb_rdport_stress.v - S0: randomised stress of the read-port wrappers
//
// The functional suite (sim/s0_rd_port) uses deterministic patterns so a failure
// points at one specific case. This test does the opposite: it drives fire and
// ready with pseudo-random sequences over a long run and checks every single
// beat against a scoreboard. It is the check that would catch an accounting bug
// that only appears after the elastic output buffer wraps.
//
// Covered
//   * DRM read port  (dgc_ram_rd_port + src_tile_bank_0), 600 beats
//   * FIFO read port (dgc_fifo_rd_port + coord_fifo),     600 beats
//
// Randomisation: fire probability ~55 %, ready probability ~88 %, plus stall
// bursts of 1..24 cycles so both the empty and the full edge of the elastic
// buffer are exercised. Order and data must be exact for every beat.
//
// The wrappers carry DGC_SIM assertions for credit overflow and empty pops; any
// violation prints DGC_ERROR and the runner fails the run.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`include "dgc_tb.vh"

module tb_rdport_stress;

    integer dgc_errors = 0;

    reg proc_clk = 0;  always #(`DGC_T_PROC) proc_clk = ~proc_clk;
    reg rst_n = 0;
    wire rst = ~rst_n;

    `DGC_GRS_INST

    localparam integer NBEAT = 600;
    localparam integer PIPE  = 2;

    integer seed_a = 32'h1234_5678;
    integer seed_b = 32'h8765_4321;

    // ============================================================ DRM read port
    reg  [23:0] ram_wr_data = 0;
    reg  [9:0]  ram_wr_addr = 0;
    reg         ram_wr_en   = 0;
    wire [23:0] ram_q;
    wire [9:0]  ram_rd_addr;

    reg         rp_fire = 0;
    wire        rp_ready;
    reg  [9:0]  rp_addr = 0;
    wire        rp_out_valid;
    reg         rp_out_ready = 0;
    wire [23:0] rp_out_data;

    src_tile_bank_0 u_bank (
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

    // ========================================================== FIFO read port
    reg  [95:0] cf_wr_data = 0;
    reg         cf_wr_en = 0;
    wire [95:0] cf_rd_data;
    wire        cf_rd_empty, cf_rd_en;
    wire        cf_wr_full, cf_almost_full, cf_almost_empty;
    wire [12:0] cf_wr_wl, cf_rd_wl;

    reg         fp_fire = 0;
    wire        fp_ready;
    wire        fp_out_valid;
    reg         fp_out_ready = 0;
    wire [95:0] fp_out_data;

    coord_fifo u_coord_fifo (
        .clk (proc_clk), .rst (rst),
        .wr_en (cf_wr_en), .wr_data (cf_wr_data), .wr_full (cf_wr_full),
        .wr_water_level (cf_wr_wl), .rd_en (cf_rd_en), .rd_data (cf_rd_data),
        .almost_full (cf_almost_full), .rd_empty (cf_rd_empty),
        .rd_water_level (cf_rd_wl), .almost_empty (cf_almost_empty)
    );

    dgc_fifo_rd_port #(.DATA_W(96), .PIPE(PIPE), .OUT_DEPTH(PIPE + 2)) u_fifo_port (
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

    // =============================================================== helpers
    function [23:0] pat(input [9:0] a);
        pat = {4'h7, a[9:0], 4'h3, a[3:0]};
    endfunction

    // ---------------------------------------------------------- scoreboards
    localparam integer QN = 1024;
    reg [23:0] rq [0:QN-1];
    integer    rq_wr = 0, rq_rd = 0;
    reg [95:0] fq [0:QN-1];
    integer    fq_wr = 0, fq_rd = 0;

    always @(posedge proc_clk) begin
        if (rst_n && rp_out_valid && rp_out_ready) begin
            if (rq_rd >= rq_wr) `DGC_FAIL("RAM port delivered a beat nobody asked for")
            else begin
                if (rp_out_data !== rq[rq_rd]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: RAM beat %0d exp=%06h act=%06h t=%0t",
                             rq_rd, rq[rq_rd], rp_out_data, $time);
                end
                rq_rd = rq_rd + 1;
            end
        end
    end

    always @(posedge proc_clk) begin
        if (rst_n && fp_out_valid && fp_out_ready) begin
            if (fq_rd >= fq_wr) `DGC_FAIL("FIFO port delivered a beat nobody asked for")
            else begin
                if (fp_out_data !== fq[fq_rd]) begin
                    dgc_errors = dgc_errors + 1;
                    $display("TEST_FAIL: FIFO beat %0d exp=%0h act=%0h t=%0t",
                             fq_rd, fq[fq_rd], fp_out_data, $time);
                end
                fq_rd = fq_rd + 1;
            end
        end
    end

    // ------------------------------------------------------------- drivers
    integer i, r, stall_cnt;
    integer addr_seq = 0;
    integer fifo_seq = 0;

    initial begin
        rst_n = 0;
        repeat (8) @(posedge proc_clk);
        rst_n = 1;
        repeat (4) @(posedge proc_clk);

        // preload the whole DRM address space so any address is legal
        for (i = 0; i < 1024; i = i + 1) begin
            @(posedge proc_clk);
            ram_wr_en   <= 1'b1;
            ram_wr_addr <= i[9:0];
            ram_wr_data <= pat(i[9:0]);
        end
        @(posedge proc_clk);
        ram_wr_en <= 1'b0;
        repeat (4) @(posedge proc_clk);

        // push enough FIFO records for the whole run
        for (i = 0; i < NBEAT; i = i + 1) begin
            @(posedge proc_clk);
            cf_wr_en   <= 1'b1;
            cf_wr_data <= {72'h0, i[11:0], 12'h5A5};
        end
        @(posedge proc_clk);
        cf_wr_en <= 1'b0;
        repeat (4) @(posedge proc_clk);

        rp_out_ready = 1;
        fp_out_ready = 1;

        // ------------------------------------------------------------ stress
        fork
            // RAM: random fire
            begin : drm_fire
                while (rq_wr < NBEAT) begin
                    @(posedge proc_clk); #0.2;
                    r = ({$random(seed_a)} % 100);
                    if (r < 55 && rp_ready) begin
                        rp_fire <= 1'b1;
                        rp_addr <= addr_seq[9:0];
                        rq[rq_wr] = pat(addr_seq[9:0]);
                        rq_wr = rq_wr + 1;
                        addr_seq = addr_seq + 1;
                        @(posedge proc_clk); #0.2;
                        rp_fire <= 1'b0;
                    end
                end
            end

            // RAM: random ready with occasional long stall
            begin : drm_ready
                while (rq_rd < NBEAT) begin
                    @(posedge proc_clk); #0.2;
                    r = ({$random(seed_b)} % 100);
                    if (r < 12) begin
                        rp_out_ready = 0;
                        stall_cnt = 1 + ({$random(seed_b)} % 24);
                        repeat (stall_cnt) @(posedge proc_clk);
                        rp_out_ready = 1;
                    end
                end
            end

            // FIFO: random fire, gated by the port's own ready
            begin : fifo_fire
                while (fq_wr < NBEAT) begin
                    @(posedge proc_clk); #0.2;
                    r = ({$random(seed_b)} % 100);
                    if (r < 55 && fp_ready) begin
                        fp_fire <= 1'b1;
                        fq[fq_wr] = {72'h0, fifo_seq[11:0], 12'h5A5};
                        fq_wr = fq_wr + 1;
                        fifo_seq = fifo_seq + 1;
                        @(posedge proc_clk); #0.2;
                        fp_fire <= 1'b0;
                    end
                end
            end

            // FIFO: random ready
            begin : fifo_ready
                while (fq_rd < NBEAT) begin
                    @(posedge proc_clk); #0.2;
                    r = ({$random(seed_a)} % 100);
                    if (r < 12) begin
                        fp_out_ready = 0;
                        stall_cnt = 1 + ({$random(seed_a)} % 24);
                        repeat (stall_cnt) @(posedge proc_clk);
                        fp_out_ready = 1;
                    end
                end
            end
        join

        repeat (60) @(posedge proc_clk);
        rp_fire      = 0;
        fp_fire      = 0;
        rp_out_ready = 1;
        fp_out_ready = 1;
        repeat (60) @(posedge proc_clk);

        if (rq_rd != NBEAT) `DGC_FAIL("RAM stress lost beats")
        if (fq_rd != NBEAT) `DGC_FAIL("FIFO stress lost beats")
        $display("TEST_INFO: RAM  port stress: %0d beats, order and data exact", rq_rd);
        $display("TEST_INFO: FIFO port stress: %0d beats, order and data exact", fq_rd);

        `DGC_FINISH
    end

endmodule
