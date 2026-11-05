//-----------------------------------------------------------------------------
// dgc_unpack.v
//
// 256-bit DDR beats -> RGB888 pixels for the source cache fill port.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   memory byte order per pixel : B0 G0 R0 B1 G1 R1 ...
//   logical pixel               : rgb[23:0] = {R[7:0], G[7:0], B[7:0]}
//   per row                     : skip head_skip bytes, then consume valid_bytes
//                                 bytes, discard the tail alignment padding
//   output                      : 1 or 2 pixels per cycle, same row, x and x+1
//   carry                       : the RGB splice restarts at every row
//
// Fixed-distance shifts instead of a barrel shifter
//   The obvious implementation shifts a 272-bit window by an arbitrary byte
//   count, which costs a five-level 256-bit barrel shifter for the one thing
//   this module does most. Here every cycle consumes a *fixed* number of bytes -
//   HEAD_SKIP_BYTES (head skip group), 1 (remaining head bytes), 3 (one pixel)
//   or 6 (two pixels). The production four-byte group needs at most ten discard
//   cycles for head_skip=31. Skips are internal work and emit no cache record.
//
// Throughput
//   A beat is 32 bytes = 10 or 11 pixels. With the carry the sequence over three
//   beats is 11 + 11 + 10 = 32 pixels, emitted two per cycle, so the module
//   sustains about 1.78 pixels per cycle.
//
// Handshake
//   row_load pulses once per source row with its descriptor; the beats for that
//   row then arrive in order. The module keeps accepting beats until beats_total
//   has been consumed even after the last pixel was emitted, because the tail of
//   the alignment padding still occupies beats that must leave the FIFO.
//   Output is a valid/ready stream and the buffer only advances when the
//   consumer accepts, so a stalled source cache never loses a pixel.
//-----------------------------------------------------------------------------

module dgc_unpack #(
    parameter integer HEAD_SKIP_BYTES = 4   // supported fixed steps: 1, 4, 8
) (
    input  wire         clk,
    input  wire         rst_n,

    // ---------------- row descriptor -----------------------------------------
    input  wire         row_load,
    input  wire [4:0]   row_head_skip,
    input  wire [7:0]   row_valid_bytes,
    input  wire [4:0]   row_beats_total,   // 1..7, beats announced for this row
    input  wire [5:0]   row_local_y,
    input  wire         row_set,
    input  wire [15:0]  row_tile_tag,
    input  wire         row_last,
    input  wire         row_tile_last,

    // ---------------- beat stream from the DDR read FIFO port ----------------
    input  wire         beat_valid,
    output wire         beat_ready,
    input  wire [255:0] beat_data,

    // ---------------- fill stream to the source cache -----------------------
    output wire         fill_valid,
    input  wire         fill_ready,
    output wire         fill_set,
    output wire [15:0]  fill_tile_tag,
    output wire [5:0]   fill_x,
    output wire [5:0]   fill_y,
    output wire [1:0]   fill_count,
    output wire [23:0]  fill_rgb0,
    output wire [23:0]  fill_rgb1,
    output wire         fill_row_last,
    output wire         fill_tile_last,

    // ---------------- row retirement ---------------------------------------
    output wire         row_done      // one cycle: the announced beats of this row are consumed
);

    // ------------------------------------------------------------------ state
    reg  [271:0] bybuf;          // {beat[255:0], carry[15:0]}, low byte = oldest
    reg  [5:0]   bcnt;         // valid bytes in bybuf (0..34)
    reg  [4:0]   disc_left;    // head_skip bytes still to throw away
    reg  [7:0]   bytes_left;   // pixel bytes still to consume
    reg  [4:0]   beats_left;   // beats still expected for this row
    reg  [5:0]   local_x;
    reg  [5:0]   local_y;
    reg          cur_set;
    reg  [15:0]  cur_tag;
    reg          cur_row_last;
    reg          cur_tile_last;
    reg          row_active;

    // ------------------------------------------------------------------ decode
    // The head-skip may only consume a byte that is actually present. Without
    // the bcnt >= 1 guard the very first discard of a row happens with an empty
    // buffer, bcnt underflows to 63 and the "room for the next beat" test never
    // becomes true again - the row then emits a full set of zero pixels from an
    // all-zero buffer.
    //
    // 2026-11-02 timing (worst proc path of the 20:06 build: -0.681 ns,
    // disc_left[4] -> ... -> 272-bit buf_after mux -> bybuf[*]):
    // `take_bytes` selects a 272-bit data mux, so every input of the phase decode
    // is on the most expensive net in the module. The four thresholds that decide
    // `taking` are therefore carried as registers, updated in the same edge as the
    // counter they describe (exactly like ge3/ge6 below): the mux select is then at
    // most two LUT levels from a flop and the path no longer starts at a 5-bit
    // compare of disc_left. The rules are mutually exclusive on purpose:
    //   disc_done  = (disc_left  == 0)
    //   bc_nz      = (bcnt       != 0)
    //   bl_nz/ge3/ge6 = (bytes_left != 0 / >= 3 / >= 6)
    reg  disc_done;         // disc_left == 0
    reg  disc_bulk;         // disc_left >= HEAD_SKIP_BYTES
    reg  bc_bulk;           // bcnt >= HEAD_SKIP_BYTES
    reg  bc_bulk_room;      // bcnt <= HEAD_SKIP_BYTES + 2
    reg  bc_nz;             // bcnt != 0
    reg  bl_nz;             // bytes_left != 0
    reg  bl_ge3, bl_ge6;    // bytes_left >= 3 / >= 6
    reg  bl_eq3, bl_eq6;    // last one/two-pixel emission
    reg  bc_le3, bc_le8;    // refill room after discarding 1 / emitting 6 bytes
    wire disc_phase = row_active && !disc_done && bc_nz;
    wire disc_take_bulk = disc_phase && disc_bulk && bc_bulk;
    wire px_phase   = row_active && disc_done && bl_nz;

    // can_one must NOT require bytes_left < 6: when bcnt sits between 3 and 5
    // while more than 6 bytes remain, refusing the single-pixel case would leave
    // the module with nothing to do (bcnt too small for two pixels, too large to
    // load the next beat) and deadlock.
    // 2026-11-01 timing (-0.041 ns on two endpoints): the bcnt compare sat on the
    // 272-bit bybuf enable.  bcnt only changes when a beat is consumed or loaded,
    // so its two thresholds are carried as registers updated together with bcnt;
    // the enable path then starts at a flop instead of a 6-bit compare.
    reg  ge3, ge6;
    wire can_two = px_phase && ge6 && bl_ge6;
    wire can_one = px_phase && ge3 && bl_ge3;
    wire taking  = disc_phase | can_two | can_one;

    localparam [5:0] HEAD_STEP = HEAD_SKIP_BYTES;
    wire [5:0] take_bytes  = disc_phase ? (disc_take_bulk ? HEAD_STEP : 6'd1) :
                                       (can_two ? 6'd6 : (can_one ? 6'd3 : 6'd0));
    wire [1:0] take_pixels = can_two ? 2'd2 : (can_one ? 2'd1 : 2'd0);

    // Every shift is a fixed-distance slice (pure wiring). The extra bulk
    // choice is a single constant-distance mux, not a variable byte shifter.
    wire [271:0] by_8  = {8'd0,  bybuf[271:8]};
    wire [271:0] by_24 = {24'd0, bybuf[271:24]};
    wire [271:0] by_48 = {48'd0, bybuf[271:48]};
    wire [271:0] by_bulk = {{(8*HEAD_SKIP_BYTES){1'b0}}, bybuf[271:(8*HEAD_SKIP_BYTES)]};
    wire [271:0] buf_after = disc_phase ? (disc_take_bulk ? by_bulk : by_8) :
                             can_two ? by_48 : can_one ? by_24 : bybuf;

    wire [5:0] bcnt_after  = bcnt - take_bytes;
    wire [7:0] bytes_after = (taking && !disc_phase) ? (bytes_left - {2'b0, take_bytes})
                                                     : bytes_left;

    // The buffer advances only when the consumer accepts the beat, otherwise a
    // stalled cache would lose the pixels already extracted.
    // Discarding padding is independent of cache readiness. Only real pixels
    // use the fill valid/ready handshake and must stay stable under a stall.
    wire accepted = disc_phase || (!taking) || fill_ready;

    // -------------------------------------------------------------- beat input
    // A new beat may only be loaded once at most two bytes are left over, because
    // those two bytes are the carry that must precede the new beat.
    // Refill decisions use thresholds carried with the counters, not the
    // decode -> subtract -> zero/room compare chain on the 272-bit buffer CE.
    wire more_after = disc_phase ? bl_nz : can_two ? !bl_eq6 :
                                      can_one ? !bl_eq3 : bl_nz;
    wire room_after = disc_phase ? (disc_take_bulk ? bc_bulk_room : bc_le3) : can_two ? bc_le8 :
                                      can_one ? !ge6 : !ge3;
    wire need_more = row_active && more_after && room_after;

    // One-entry input register. The previous version fed the CDC FIFO read data
    // straight into the 272-bit bybuf mux; at 225 MHz that path (and the CE
    // fanout behind it) was -1.99 ns. Registering the beat first turns it into a
    // register-to-register path and still sustains one beat per cycle.
    reg  [255:0] in_data;
    reg          in_valid;

    wire load_beat  = in_valid && need_more && accepted;
    wire drain_beat = row_active && (bytes_left == 8'd0) && (beats_left != 5'd0) &&
                      in_valid && accepted;
    wire in_consume = load_beat || drain_beat;

    assign beat_ready = (~in_valid | in_consume) && row_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_data  <= 256'd0;
            in_valid <= 1'b0;
        end
        else if (beat_valid && beat_ready) begin
            in_data  <= beat_data;
            in_valid <= 1'b1;
        end
        else if (in_consume) begin
            in_valid <= 1'b0;
        end
    end

    // The leftover bytes (0, 1 or 2) are the carry and must sit directly *below*
    // the new beat, otherwise the first pixel of the new beat is read two bytes
    // too high. Placing the beat at a fixed offset was the bug that made every
    // pixel after the first emission come out shifted.
    wire [271:0] load_bybuf =
        (bcnt_after == 6'd0) ? {16'd0, in_data}                      :
        (bcnt_after == 6'd1) ? {8'd0,  in_data, buf_after[7:0]}      :
                                {in_data, buf_after[15:0]};

    // Keep the hold function on the explicit write enable. Counter thresholds
    // are carried as flags so the wide buffer does not wait for fresh compares.
    wire [271:0] by_mux   = load_beat ? load_bybuf : buf_after;
    wire [5:0]   bcnt_next = load_beat ? ({2'b0, bcnt_after} + 6'd32) :
                                         (taking ? bcnt_after : bcnt);
    wire         bybuf_wr = accepted & (load_beat | taking);

    // ------------------------------------------------------------------ output
    assign fill_valid     = can_two | can_one;
    assign fill_set       = cur_set;
    assign fill_tile_tag  = cur_tag;
    assign fill_x         = local_x;
    assign fill_y         = local_y;
    assign fill_count     = take_pixels;
    assign fill_rgb0      = bybuf[23:0];
    assign fill_rgb1      = bybuf[47:24];
    // the last emission of a row is the one that consumes the remaining bytes
    wire last_emit = taking && (!disc_phase) && (bytes_left == {2'b0, take_bytes});
    assign fill_row_last  = cur_row_last  && last_emit;
    assign fill_tile_last = cur_tile_last && cur_row_last && last_emit;

    // row_done pulses when the last announced beat of the row has been consumed
    assign row_done = row_active && (beats_left == 5'd0) && !load_beat && !drain_beat &&
                      (bytes_left == 8'd0) && !taking;

    // ------------------------------------------------------------------ update
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bybuf           <= 272'd0;
            bcnt          <= 6'd0;
            ge3           <= 1'b0;
            ge6           <= 1'b0;
            disc_done     <= 1'b1;      // disc_left == 0
            disc_bulk     <= 1'b0;
            bc_bulk       <= 1'b0;
            bc_bulk_room  <= 1'b1;
            bc_nz         <= 1'b0;      // bcnt == 0
            bl_nz         <= 1'b0;      // bytes_left == 0
            bl_ge3        <= 1'b0;
            bl_ge6        <= 1'b0;
            bl_eq3        <= 1'b0; bl_eq6 <= 1'b0;
            bc_le3        <= 1'b1; bc_le8 <= 1'b1;
            disc_left     <= 5'd0;
            bytes_left    <= 8'd0;
            beats_left    <= 5'd0;
            local_x       <= 6'd0;
            local_y       <= 6'd0;
            cur_set       <= 1'b0;
            cur_tag       <= 16'd0;
            cur_row_last  <= 1'b0;
            cur_tile_last <= 1'b0;
            row_active    <= 1'b0;
        end
        else if (row_load) begin
            // the RGB splice restarts here, so no carry survives from the last row
            bybuf           <= 272'd0;
            bcnt          <= 6'd0;
            ge3           <= 1'b0;
            ge6           <= 1'b0;
            disc_done     <= (row_head_skip == 5'd0);
            disc_bulk     <= (row_head_skip >= HEAD_SKIP_BYTES);
            bc_bulk       <= 1'b0;
            bc_bulk_room  <= 1'b1;
            bc_nz         <= 1'b0;
            bl_nz         <= (row_valid_bytes != 8'd0);
            bl_ge3        <= (row_valid_bytes >= 8'd3);
            bl_ge6        <= (row_valid_bytes >= 8'd6);
            bl_eq3        <= (row_valid_bytes == 8'd3);
            bl_eq6        <= (row_valid_bytes == 8'd6);
            bc_le3        <= 1'b1; bc_le8 <= 1'b1;
            disc_left     <= row_head_skip;
            bytes_left    <= row_valid_bytes;
            beats_left    <= row_beats_total;
            local_x       <= 6'd0;
            local_y       <= row_local_y;
            cur_set       <= row_set;
            cur_tag       <= row_tile_tag;
            cur_row_last  <= row_last;
            cur_tile_last <= row_tile_last;
            row_active    <= 1'b1;
        end
        else begin
            // bybuf is written only when a beat loads or a pixel is emitted; the
            // data mux no longer carries the hold path (see the timing note above).
            if (bybuf_wr) bybuf <= by_mux;

            // bcnt is updated from one place so its threshold flags can never
            // disagree with it (a beat load and a pixel emission can coincide).
            if (accepted && (taking || load_beat)) begin
                bcnt <= bcnt_next;
                ge3  <= (bcnt_next >= 6'd3);
                ge6  <= (bcnt_next >= 6'd6);
                bc_nz <= (bcnt_next != 6'd0);
                bc_le3 <= (bcnt_next <= 6'd3);
                bc_le8 <= (bcnt_next <= 6'd8);
                bc_bulk <= (bcnt_next >= HEAD_SKIP_BYTES);
                bc_bulk_room <= (bcnt_next <= HEAD_SKIP_BYTES + 2);
            end

            // one cycle can accept a beat and emit pixels at the same time, so
            // the two updates are written to be mutually consistent
            if (accepted) begin
                if (taking) begin
                    if (disc_phase) begin
                        disc_left <= disc_left - take_bytes[4:0];
                        disc_done <= disc_take_bulk ? (disc_left == HEAD_SKIP_BYTES) :
                                                     (disc_left == 5'd1);
                        disc_bulk <= disc_take_bulk ? (disc_left >= 2*HEAD_SKIP_BYTES) :
                                                     (disc_left >= HEAD_SKIP_BYTES + 1);
                    end
                    else begin
                        bytes_left <= bytes_after;
                        local_x    <= local_x + {4'd0, take_pixels};
                        bl_nz      <= (bytes_after != 8'd0);
                        bl_ge3     <= (bytes_after >= 8'd3);
                        bl_ge6     <= (bytes_after >= 8'd6);
                        bl_eq3     <= (bytes_after == 8'd3);
                        bl_eq6     <= (bytes_after == 8'd6);
                    end
                end

                if (load_beat) begin
                    beats_left <= beats_left - 5'd1;
                end
                else if (drain_beat) begin
                    beats_left <= beats_left - 5'd1;
                end


            end

            // row retires when every announced beat has been consumed
            if (row_active && (beats_left == 5'd0) && !load_beat && !drain_beat &&
                (bytes_left == 8'd0) && !taking)
                row_active <= 1'b0;
        end
    end

`ifdef DGC_SIM
    initial begin
        if (HEAD_SKIP_BYTES != 1 && HEAD_SKIP_BYTES != 4 && HEAD_SKIP_BYTES != 8)
            $fatal(1, "unsupported fixed head skip step");
    end
`endif

endmodule







