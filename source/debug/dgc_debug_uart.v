//-----------------------------------------------------------------------------
// dgc_debug_uart.v
//
// Board bring-up reporter: once per second it asks dgc_snapshot_hub for a
// coherent snapshot and prints eleven fixed-width lines at 115200 8N1 on C24.
//
//   DGC5 S=XXXX...   (25 characters per line: "DGC5 " + label + "=" + 16 hex + CRLF)
//
// The labels and word meanings are documented in dgc_snapshot_hub.v:
//
//   S  S status, T status, cap_frames, cap_aborted
//   I  cap_rows, pixel clock (0.1 MHz), line_px, frame_lines
//   W  wa_frames(good), wa_aborts, input RGB sum, output RGB sum
//   J  jobs, core blocks, job flags, slot states
//   G  recs_total, sample_left, underflows, reader flags
//   K  fill flags, job us, stripe ids + reader ownership, sticky flags
//   P  fill active, wait beats, wait row channel, wait planner
//   Q  fill writes, sample active, writer stall, sampler stall
//   R  AR handshakes, AR wait, return starve, max in flight
//   M  job frame id, capture alloc, releases, allocation drops
//   V  reader offers, discards, frames, releases (per second, DGC5)
//
// Version note: DGC2 (six lines) is documented in DGC2串口协议_20261028.md,
// DGC4 (ten lines) in DGC4串口协议_20261030.md, DGC5 (eleven lines) in
// DGC5串口协议_20261031.md. Words 0..39 keep their DGC4 positions; DGC5
// re-encodes K word 2 (full stripe ids) and appends the V line.
//
// The snapshot is latched before printing and the hub does not start another
// one until the next request, so a line can never mix two instants. This is
// the fix for the 10-27 "figures changed while being printed" problem.
//
// Everything runs in the 27 MHz sys_clk with a board-reset-only synchroniser,
// so the reporter works even while DDR/HDMI/video are still in reset.
//-----------------------------------------------------------------------------

module dgc_debug_uart #(
    parameter integer TICK_CYCLES = 27_000_000
) (
    input  wire         clk,            // 27 MHz sys_clk
    input  wire         rst_n,          // board C22 rstn, active low

    input  wire [703:0] words,          // frozen snapshot, 44 x 16 bit
    input  wire         snap_done,      // one-cycle: words are valid
    output reg          snap_start,     // one-cycle: please take a snapshot

    output wire         uart_tx
);

    // ---------------------------------------------------------- boot message
    // "DGC5 BOOT\r\n" so a terminal shows life before the first 1 s report.
    localparam [1:0] ST_BOOT  = 2'd0;
    localparam [1:0] ST_IDLE  = 2'd1;
    localparam [1:0] ST_WAIT  = 2'd2;
    localparam [1:0] ST_PRINT = 2'd3;

    localparam [7:0] N_LINES  = 8'd11;
    localparam [7:0] LAST_CI  = 8'd24;   // 0..24 = 25 characters

    reg [1:0]  state;
    reg [7:0]  bi;          // boot character index
    reg [7:0]  ci;          // character index inside a line
    reg [3:0]  line;        // 0..8
    reg [17:0] wait_cnt;

    // ---------------------------------------------------------- 1 s tick
    reg [24:0] tick_cnt;
    reg        tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 25'd0;
            tick     <= 1'b0;
        end
        else if (tick_cnt == TICK_CYCLES - 1) begin
            tick_cnt <= 25'd0;
            tick     <= 1'b1;
        end
        else begin
            tick_cnt <= tick_cnt + 25'd1;
            tick     <= 1'b0;
        end
    end

    // ---------------------------------------------------------- character map
    function [7:0] hexc(input [3:0] v);
        hexc = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
    endfunction

    function [7:0] label(input [3:0] l);
        case (l)
            4'd0: label = 8'h53;   // S
            4'd1: label = 8'h49;   // I
            4'd2: label = 8'h57;   // W
            4'd3: label = 8'h4A;   // J
            4'd4: label = 8'h47;   // G
            4'd5: label = 8'h4B;   // K
            4'd6: label = 8'h50;   // P
            4'd7: label = 8'h51;   // Q
            4'd8: label = 8'h52;   // R
            4'd9: label = 8'h4D;   // M
            4'd10: label = 8'h56;  // V (DGC5 reader activity)
            default: label = 8'h3F;// '?'
        endcase
    endfunction

    // ci 7..22 selects 16 hexadecimal digits: word line*4 + p/4, nibble 3-p%4
    // widx is 6 bits because DGC5 has 44 words (line 10 -> words 40..43).
    wire [3:0]  p      = ci[3:0] - 4'd7;
    wire [5:0]  widx   = {line, 2'b00} + {4'd0, p[3:2]};
    wire [1:0]  nidx   = 2'd3 - p[1:0];
    wire [3:0]  nibble = words[{widx, 4'b0000} + {6'd0, nidx, 2'b00} +: 4];

    reg [7:0] ch;

    always @(*) begin
        if (state == ST_BOOT) begin
            case (bi)
                4'd0: ch = 8'h44;  // D
                4'd1: ch = 8'h47;  // G
                4'd2: ch = 8'h43;  // C
                4'd3: ch = 8'h35;  // 5
                4'd4: ch = 8'h20;  // space
                4'd5: ch = 8'h42;  // B
                4'd6: ch = 8'h4F;  // O
                4'd7: ch = 8'h4F;  // O
                4'd8: ch = 8'h54;  // T
                4'd9: ch = 8'h0D;  // CR
                default: ch = 8'h0A;// LF
            endcase
        end
        else if (ci == 8'd0) ch = 8'h44;   // D
        else if (ci == 8'd1) ch = 8'h47;   // G
        else if (ci == 8'd2) ch = 8'h43;   // C
        else if (ci == 8'd3) ch = 8'h35;   // 5
        else if (ci == 8'd4) ch = 8'h20;   // space
        else if (ci == 8'd5) ch = label(line);
        else if (ci == 8'd6) ch = 8'h3D;   // =
        else if (ci <  8'd23) ch = hexc(nibble);
        else if (ci == 8'd23) ch = 8'h0D;  // CR
        else ch = 8'h0A;                   // LF
    end

    // ------------------------------------------------------------- transmit
    wire tx_busy;
    wire send = ((state == ST_BOOT) || (state == ST_PRINT)) && ~tx_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_BOOT;
            bi        <= 8'd0;
            ci        <= 8'd0;
            line      <= 4'd0;
            wait_cnt  <= 18'd0;
            snap_start <= 1'b0;
        end
        else begin
            snap_start <= 1'b0;

            case (state)
                ST_BOOT: begin
                    if (send) begin
                        if (bi == 8'd10) begin
                            bi    <= 8'd0;
                            state <= ST_IDLE;
                        end
                        else bi <= bi + 8'd1;
                    end
                end

                ST_IDLE: begin
                    if (tick) begin
                        snap_start <= 1'b1;
                        wait_cnt   <= 18'd0;
                        state      <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    wait_cnt <= wait_cnt + 18'd1;
                    if (snap_done) begin
                        line  <= 4'd0;
                        ci    <= 8'd0;
                        state <= ST_PRINT;
                    end
                    else if (wait_cnt == 18'h3FFFF) begin
                        // The hub is guaranteed to answer within ~1024 sys
                        // clocks; this only protects the reporter itself.
                        state <= ST_IDLE;
                    end
                end

                ST_PRINT: begin
                    if (send) begin
                        if (ci == LAST_CI) begin
                            ci <= 8'd0;
                            if (line == N_LINES - 8'd1) state <= ST_IDLE;
                            else line <= line + 4'd1;
                        end
                        else ci <= ci + 8'd1;
                    end
                end
            endcase
        end
    end

    uart_tx_simple #(.CLK_FRE(27_000_000), .BAUD(115200)) u_tx (
        .clk      (clk),
        .rstn     (rst_n),
        .tx_start (send),
        .tx_data  (ch),
        .txd      (uart_tx),
        .tx_busy  (tx_busy)
    );

endmodule

//=============================================================================
// dgc_perf_ctr - DGC3 interval accumulator (co-located with the reporter)
//
// Placement note (2026-10-30): this module lives in the same compile unit as
// dgc_debug_uart because the PDS project could not be given a new source file
// while the GUI held camara_helper_0.pds open, and dgc_debug_uart.v is already
// registered from this canonical path. It is still a standalone module with its
// own directed test (sim/s0_perf_ctr). When the project is next closed, it can
// be moved back to source/debug/dgc_perf_ctr.v and registered normally; nothing
// outside the module would change.
//=============================================================================
//-----------------------------------------------------------------------------
// dgc_perf_ctr.v
//
// Bounded-interval performance accumulators for the DGC3 status report.
//
// Why it exists: the 2026-10-30 board run showed a job of 28.2 ms (4080 blocks,
// ~69 proc cycles per source row) against 3.8 ms-equivalent simulation
// (646 cycles/block, ~38 cycles/row). The next measurement must say *where*
// those extra ~31 cycles/row are spent, without another guess: fill waiting for
// beats, fill waiting for the row channel, or the sample side being held by the
// stripe writer. One 16-bit accumulated-cycles field per reason answers that.
//
// Operation
//   * `ev[i]` is a one-cycle condition in `clk`'s domain. Each high cycle adds
//     one to accumulator i.
//   * `latch` is the same pulse the domain's dgc_snapshot_src uses to freeze its
//     hold register (dgc_snapshot_src:latch_evt). On that cycle the published
//     value is (accumulated + this cycle) >> SHIFT and the accumulator restarts
//     from zero. The value is therefore "the interval since the previous
//     snapshot", not a free-running counter: no 16-bit wrap interpretation is
//     needed and the host can compare one report with the next directly.
//   * The published bus is combinational during the latch cycle so the snapshot
//     register captures the *current* interval rather than the previous one.
//     Without this the report would always lag one second behind, which looks
//     like a working counter and would silently invalidate the measurement.
//
// Scaling
//   At 171 MHz a one-second interval is 171e6 cycles, far more than 16 bits, so
//   SHIFT must be large enough that 171e6 >> SHIFT fits: SHIFT=12 gives 41,748.
//   One LSB is 4096 cycles (24 us). For event counts (e.g. native ARs per
//   second, ~2e6) a separate instance uses a smaller SHIFT chosen by the caller.
//
// Saturation
//   An accumulator saturates just below 2^32 and the published value saturates
//   at 0xFFFF, so a missing snapshot (ack timeout, reporter stall) produces a
//   pinned maximum instead of a wrapped, plausible-looking number.
//-----------------------------------------------------------------------------

module dgc_perf_ctr #(
    parameter integer N     = 4,      // number of independent counters
    parameter integer SHIFT = 12      // right shift applied when publishing
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             latch,    // one-cycle, same edge as the snapshot hold
    input  wire [N-1:0]     ev,       // counter i increments while ev[i] is high
    output wire [16*N-1:0]  value     // published intervals, counter 0 in the LSB word
);

    reg [31:0] acc [0:N-1];
    reg [15:0] val [0:N-1];

    // Saturation head-room: acc is never allowed to reach 2^32-1, so acc+ev can
    // be evaluated without carrying out of 32 bits.
    localparam [31:0] ACC_MAX = 32'hFFFF_FF00;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N; i = i + 1) begin
                acc[i] <= 32'd0;
                val[i] <= 16'd0;
            end
        end
        else begin
            for (i = 0; i < N; i = i + 1) begin
                if (latch) begin
                    // publish the interval that ends on this edge
                    if (((acc[i] + {31'd0, ev[i]}) >> SHIFT) > 32'h0000_FFFF)
                        val[i] <= 16'hFFFF;
                    else
                        val[i] <= (acc[i] + {31'd0, ev[i]}) >> SHIFT;
                    acc[i] <= 32'd0;
                end
                else if (ev[i] && (acc[i] < ACC_MAX)) begin
                    acc[i] <= acc[i] + 32'd1;
                end
            end
        end
    end

    // During the latch cycle the snapshot register must see the new interval;
    // at every other time it sees the last published value.
    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_publish
            wire [31:0] cur = acc[gi] + {31'd0, ev[gi]};
            wire [15:0] cur_sat = (cur >> SHIFT > 32'h0000_FFFF) ? 16'hFFFF
                                                               : (cur >> SHIFT);
            assign value[gi*16 +: 16] = latch ? cur_sat : val[gi];
        end
    endgenerate

endmodule
