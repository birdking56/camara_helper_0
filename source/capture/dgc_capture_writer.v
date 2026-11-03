//-----------------------------------------------------------------------------
// dgc_capture_writer.v - frame lifecycle around dgc_capture_pack
// Timing (docs section 10), frame_begin at N: N captures the descriptor,
// N+1 sets begin_d, N+2 pulses pack_start so the pack latches the NEW base,
// N+3 releases px_ready. Pulsing pack_start at N latched the previous base.
//-----------------------------------------------------------------------------
module dgc_capture_writer #(
    parameter integer STRIDE_BYTES = 5760
) (
    input  wire         clk, input wire rst_n,
    input  wire         frame_begin,
    input  wire [127:0] frame_desc,
    input  wire         frame_abort,
    input  wire         px_valid,
    output wire         px_ready,
    input  wire [23:0]  px_data,
    input  wire         px_de,
    input  wire         px_eol,
    output wire         beat_valid,
    input  wire         beat_ready,
    output wire [31:0]  beat_addr,
    output wire [255:0] beat_data,
    output reg          frame_done,
    output wire [1:0]   done_slot,
    output wire [31:0]  done_frame_id,
    output reg  [31:0]  cnt_frames,
    output reg  [31:0]  cnt_aborted,
    output wire [10:0]  row_cnt
);
    wire [31:0] d_frame_id = frame_desc[31:0];
    wire [31:0] d_base     = frame_desc[63:32];
    wire [15:0] d_stride   = frame_desc[79:64];
    wire [11:0] d_height   = frame_desc[103:92];
    wire [1:0]  d_slot     = frame_desc[105:104];

    reg [31:0] d_base_r, d_frame_id_r;
    reg [15:0] d_stride_r;
    reg [11:0] d_height_r;
    reg [1:0]  d_slot_r;
    reg        active, last_row_pending, begin_d, pack_start;
    reg [10:0] rows;

    assign done_slot = d_slot_r;
    assign done_frame_id = d_frame_id_r;
    assign row_cnt = rows;

    wire pack_px_ready;
    // HDMI cannot obey ready: discard input unless this writer owns a frame.
    // Close admission while a new descriptor/base is being installed, too.
    // Already accepted output beats still drain through beat_valid/beat_ready.
    wire capture_enable = active && !frame_begin && !begin_d &&
                          !pack_start && !frame_abort;

    dgc_capture_pack #(.STRIDE_BYTES(STRIDE_BYTES)) u_pack (
        .clk(clk), .rst_n(rst_n),
        .frame_base(d_base_r), .frame_start(pack_start),
        .px_valid(px_valid && capture_enable), .px_ready(pack_px_ready), .px_data(px_data),
        .px_de(px_de), .px_eol(px_eol),
        .beat_valid(beat_valid), .beat_ready(beat_ready), .beat_addr(beat_addr),
        .beat_data(beat_data), .beat_sof(), .cnt_px(), .cnt_beats());

    assign px_ready = pack_px_ready && capture_enable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_base_r <= 0; d_stride_r <= 0; d_height_r <= 0; d_slot_r <= 0;
            d_frame_id_r <= 0; active <= 0; last_row_pending <= 0;
            begin_d <= 0; pack_start <= 0; frame_done <= 0;
            cnt_frames <= 0; cnt_aborted <= 0; rows <= 0;
        end
        else begin
            frame_done <= 1'b0;
            pack_start <= 1'b0;
            begin_d    <= frame_begin;

            if (frame_begin) begin
                active <= 1'b0;
                d_base_r <= d_base; d_stride_r <= d_stride; d_height_r <= d_height;
                d_slot_r <= d_slot; d_frame_id_r <= d_frame_id;
                rows <= 0; last_row_pending <= 0;
            end
            if (begin_d)    pack_start <= 1'b1;
            if (pack_start) active <= 1'b1;

            if (frame_abort && active) begin
                active <= 1'b0; cnt_aborted <= cnt_aborted + 1;
            end

            if (capture_enable && px_valid && px_de && pack_px_ready && px_eol) begin
                rows <= rows + 1;
                if (rows == d_height_r - 1) last_row_pending <= 1'b1;
            end

            if (last_row_pending && beat_valid && beat_ready) begin
                last_row_pending <= 1'b0; active <= 1'b0;
                frame_done <= 1'b1; cnt_frames <= cnt_frames + 1;
            end
        end
    end
endmodule
