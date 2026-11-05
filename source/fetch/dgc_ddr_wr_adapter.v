//-----------------------------------------------------------------------------
// dgc_ddr_wr_adapter.v
//
// Turns the capture beat stream into the DDR3 IP's simplified-AXI write
// channel: AW bursts of at most 16 beats, never crossing a 4 KiB Column
// boundary, with the 256-bit data and all-byte strobes on the W channel.
//
// Frozen reference: 接口冻结规范_v1.md sections 4 and 7.
//
//   * The native burst length limit is 16 beats (awlen is 4 bits).
//   * A request must not cross a 4 KiB Column boundary; the split is done here,
//     before the AW handshake, because awlen cannot be changed afterwards.
//   * The simplified AXI write data channel has no wvalid: the slave's wready is
//     the only valid indication, so the master must keep the current beat on
//     wdata and advance only when wready is high.
//   * Frames are written as one contiguous byte stream: a 1920-pixel row is
//     5760 = 180 x 32 bytes, so row N+1 starts exactly where row N ended. The
//     only address discontinuity is at a frame boundary, which is how the
//     adapter notices an aborted frame (its tail never reaches the frame's last
//     beat offset).
//
// Frame completion
//   The adapter, not the capture logic, is what can prove that the last beat of
//   a frame really reached the controller. For the frozen 1080p layout the last
//   beat of any frame starts at byte offset FRAME_BYTES-32 inside its 16 MiB
//   slot, and the slot base is 16 MiB aligned, so the low 24 address bits of
//   that beat are always the same. When that beat is accepted on the W channel
//   the adapter pulses `frame_end` with the slot number (address bits [25:24]).
//   If a new frame starts before the previous one reached that beat, the
//   previous frame is reported with `frame_abort` instead.
//
// Buffering
//   Beats are buffered so that a burst length can be decided before the AW
//   handshake. The buffer is small (BUF_DEPTH entries) because bursts are at
//   most 16 beats and the page split only shortens them.
//-----------------------------------------------------------------------------

module dgc_ddr_wr_adapter #(
    parameter integer FRAME_BYTES = 6220800,     // 1920 x 1080 x 3
    parameter integer BUF_DEPTH   = 32
) (
    input  wire        clk,           // ddr_clk
    input  wire        rst_n,

    // ---------------- beat stream from the CDC FIFO read port ---------------
    input  wire        beat_valid,
    output wire        beat_ready,
    input  wire [287:0] beat_data,    // [255:0] data, [287:256] byte address

    // ---------------- native write address channel ---------------------------
    output reg  [27:0] awaddr,
    output reg  [3:0]  awlen,
    output wire        awuser_ap,
    output wire [3:0]  awuser_id,
    output reg         awvalid,
    input  wire        awready,

    // ---------------- native write data channel -----------------------------
    output wire [255:0] wdata,
    output wire [31:0]  wstrb,
    input  wire         wready,
    input  wire [3:0]   wusero_id,     // driven by the IP
    input  wire         wusero_last,

    // ---------------- frame completion (DDR domain) -------------------------
    output reg         frame_end,      // one cycle: the frame's last beat landed
    output reg  [1:0]  frame_end_slot,
    output reg         frame_abort,    // one cycle: a new frame cut this one off
    output reg  [1:0]  frame_abort_slot,

    // ---------------- diagnostics -------------------------------------------
    output reg  [31:0] cnt_beats,
    output reg  [31:0] cnt_bursts,
    output reg  [31:0] cnt_frames,
    output reg  [31:0] cnt_aborts,
    output wire        idle
);

    localparam [31:0] LAST_OFF = FRAME_BYTES - 32;

    assign awuser_ap = 1'b0;
    assign awuser_id = 4'd0;

    // ---------------------------------------------------------------- buffer
    reg  [255:0] buf_data [0:BUF_DEPTH-1];
    reg  [31:0]  buf_addr [0:BUF_DEPTH-1];
    reg          buf_last [0:BUF_DEPTH-1];

    reg  [4:0]   wp, rp;
    reg  [5:0]   count;
    reg  [3:0]   last_in_buf;      // entries whose address is the frame's last beat
    reg          any_last;         // (last_in_buf != 0)

    // previous pushed beat, for discontinuity detection
    reg  [31:0]  prev_addr;
    reg          prev_valid;
    reg          prev_was_last;

    // One-entry input register. The CDC FIFO read data used to feed the 32x256
    // buffer CE combinationally; at 125 MHz that path was -0.97 ns. Registering
    // the beat first keeps one beat per cycle and moves the FIFO read out of the
    // buffer-write cone.
    reg  [287:0] in_data;
    reg          in_valid;
    reg          in_disc;
    reg          input_seen;
    reg  [31:0]  input_next_addr;

    // ------------------------------------------------------------ burst state
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_AW   = 2'd1;
    localparam [1:0] S_W    = 2'd2;

    reg  [1:0]  state;
    reg  [4:0]  burst_len;
    reg  [4:0]  beat_idx;

    // -------------------------------------------------- input side decisions
    wire [31:0] in_addr = in_data[287:256];

    // Compare at the input-register boundary, where each accepted beat is
    // sequenced, rather than in the CE cone of the 32x256-bit write buffer.
    wire disc_now = in_valid & prev_valid & in_disc;
    wire flush    = (count > 0) & disc_now;

    // stop accepting beats while the previous frame's tail is being flushed, so
    // a burst can never span the discontinuity
    wire buf_ok = ~flush & (count < BUF_DEPTH - 1);
    wire push   = in_valid & buf_ok;

    assign beat_ready = ~in_valid | push;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_data  <= 288'd0;
            in_valid <= 1'b0;
            in_disc <= 1'b0;
            input_seen <= 1'b0;
            input_next_addr <= 32'd0;
        end
        else if (beat_valid && beat_ready) begin
            in_data  <= beat_data;
            in_valid <= 1'b1;
            in_disc <= input_seen && (beat_data[287:256] != input_next_addr);
            input_seen <= 1'b1;
            input_next_addr <= beat_data[287:256] + 32'd32;
        end
        else if (push) begin
            in_valid <= 1'b0;
        end
    end

    // -------------------------------------------------------- burst length
    // All input addresses are 32-byte aligned and native bursts have at most
    // 16 beats. Only the final 512 bytes of a 4 KiB page can shorten a burst.
    // Work directly in AXI's beats-minus-one encoding: in that region the page
    // limit is 15 - addr[8:5], which is just a four-bit complement. This removes
    // the pointer mux -> 12-bit subtract -> compare -> subtract path to AWLEN.
    wire [31:0] head_addr = buf_addr[rp];
    wire [3:0] want_last = (count >= 16) ? 4'hf : (count[3:0] - 4'd1);
    wire [3:0] page_last = (&head_addr[11:9]) ? ~head_addr[8:5] : 4'hf;
    wire [3:0] issue_last = (want_last < page_last) ? want_last : page_last;
    wire        can_issue  = (state == S_IDLE) && (count > 0) &&
                             (flush || (count >= 16) || any_last);
    wire [4:0]  issue_len  = {1'b0, issue_last} + 5'd1;

    assign wdata = buf_data[rp];
    assign wstrb = 32'hFFFF_FFFF;

    wire pop_w = (state == S_W) && wready;
    wire [31:0] pop_addr = buf_addr[rp];
    wire        pop_last = buf_last[rp];

    assign idle = (state == S_IDLE) && (count == 0);

    // ---------------------------------------------------------------- FSM
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            awaddr <= 28'd0; awlen <= 4'd0; awvalid <= 1'b0;
            burst_len <= 5'd0; beat_idx <= 5'd0;
            wp <= 5'd0; rp <= 5'd0; count <= 6'd0;
            last_in_buf <= 4'd0; any_last <= 1'b0;
            prev_addr <= 32'd0; prev_valid <= 1'b0; prev_was_last <= 1'b0;
            frame_end <= 1'b0; frame_end_slot <= 2'd0;
            frame_abort <= 1'b0; frame_abort_slot <= 2'd0;
            cnt_beats <= 32'd0; cnt_bursts <= 32'd0;
            cnt_frames <= 32'd0; cnt_aborts <= 32'd0;
            for (i = 0; i < BUF_DEPTH; i = i + 1) begin
                buf_data[i] <= 256'd0; buf_addr[i] <= 32'd0; buf_last[i] <= 1'b0;
            end
        end
        else begin
            frame_end   <= 1'b0;
            frame_abort <= 1'b0;

            // -------------------------------------------------- push a beat
            // count and last_in_buf are updated once, at the end of the block:
            // a push and a pop happen in the same cycle almost all the time, and
            // two separate non-blocking updates would silently keep only one of
            // them (that made the buffer overrun and read stale entries).
            if (push) begin
                buf_data[wp] <= in_data[255:0];
                buf_addr[wp] <= in_addr;
                buf_last[wp] <= (in_addr[23:0] == LAST_OFF[23:0]);
                wp <= wp + 5'd1;
                cnt_beats <= cnt_beats + 32'd1;
                prev_addr <= in_addr;
                prev_valid <= 1'b1;
                prev_was_last <= (in_addr[23:0] == LAST_OFF[23:0]);
            end

            // a new frame while the previous one had not reached its last beat
            if (disc_now && !prev_was_last && (state == S_IDLE) && (count == 0)) begin
                frame_abort <= 1'b1;
                frame_abort_slot <= prev_addr[25:24];
                cnt_aborts <= cnt_aborts + 32'd1;
                prev_valid <= 1'b0;
            end

            // -------------------------------------------------- burst issue
            if (can_issue) begin
                // native address unit is one 32-bit storage word: byte address >> 2
                awaddr  <= buf_addr[rp][29:2];
                awlen   <= issue_last;
                burst_len <= issue_len;
                beat_idx  <= 5'd0;
                awvalid   <= 1'b1;
                state     <= S_AW;
            end

            // -------------------------------------------------- address handshake
            if ((state == S_AW) && awready) begin
                awvalid <= 1'b0;
                state   <= S_W;
            end

            // -------------------------------------------------- data beats
            if (pop_w) begin
                rp <= rp + 5'd1;
                if (pop_last) begin
                    frame_end <= 1'b1;
                    frame_end_slot <= pop_addr[25:24];
                    cnt_frames <= cnt_frames + 32'd1;
                    prev_was_last <= 1'b1;
                end
                if (beat_idx + 5'd1 == burst_len) begin
                    beat_idx <= 5'd0;
                    state <= S_IDLE;
                    cnt_bursts <= cnt_bursts + 32'd1;
                end
                else begin
                    beat_idx <= beat_idx + 5'd1;
                end
            end

            // ------------------------------------------------ one update each
            count <= count + (push ? 6'd1 : 6'd0) - (pop_w ? 6'd1 : 6'd0);
            last_in_buf <= last_in_buf + (push && (in_addr[23:0] == LAST_OFF[23:0]) ? 4'd1 : 4'd0)
                                      - (pop_w && pop_last ? 4'd1 : 4'd0);
            any_last <= ((last_in_buf + (push && (in_addr[23:0] == LAST_OFF[23:0]) ? 4'd1 : 4'd0)
                                     - (pop_w && pop_last ? 4'd1 : 4'd0)) != 4'd0);
        end
    end

`ifdef DGC_SIM
    // A burst must never carry two non-contiguous addresses.
    reg [31:0] dbg_first_addr;
    reg        dbg_have_first;
    always @(posedge clk) begin
        if (rst_n && can_issue) begin
            dbg_first_addr <= buf_addr[rp];
            dbg_have_first <= 1'b1;
        end
        if (rst_n && (state == S_W) && wready) begin
            if (dbg_have_first && (buf_addr[rp] != dbg_first_addr + {beat_idx[4:0], 5'd0}))
                $display("DGC_ERROR: wr_adapter burst not contiguous at beat %0d t=%0t", beat_idx, $time);
        end
    end
`endif

endmodule
