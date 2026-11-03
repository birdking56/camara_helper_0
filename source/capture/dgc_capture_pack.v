//-----------------------------------------------------------------------------
// dgc_capture_pack.v
//
// Packs RGB888 pixels into 32-byte DDR write beats and gives each beat its byte
// address.
//
// Frozen reference: 接口冻结规范_v1.md section 4.
//   byte_addr = frame_base + y*5760 + 3*x ; beat = 32 bytes ; native unit = 4 bytes
//
// One row is 1920*3 = 5760 bytes and 5760 / 32 = 180 exactly, so a row is always
// a whole number of beats and nothing carries across a row boundary. Each row
// starts beat-aligned, which makes the address row_base + k*32.
//
// A beat holds ten whole pixels plus two bytes of the eleventh, so a pixel can
// straddle a beat boundary and the packer needs a byte accumulator.
//
// Implementation note
//   The pixel is written at byte offset `nbytes`, and when that reaches 32 the low
//   beat is emitted and the accumulator shifts down. Those two operations touch
//   the same register, so they are done on a blocking temporary (`work_acc`) and
//   the register is updated once at the end. Writing the slice and the whole
//   register from two different non-blocking assignments in one block is a
//   conflict - that was the first attempt and it was discarded.
//-----------------------------------------------------------------------------

module dgc_capture_pack #(
    parameter integer STRIDE_BYTES = 5760
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [31:0]  frame_base,
    input  wire         frame_start,     // pulse before the first pixel of a frame

    input  wire         px_valid,
    output wire         px_ready,
    input  wire [23:0]  px_data,
    input  wire         px_de,
    input  wire         px_eol,          // this pixel is the last of its row

    output reg          beat_valid,
    input  wire         beat_ready,
    output reg  [31:0]  beat_addr,
    output reg  [255:0] beat_data,
    output reg          beat_sof,        // first beat of a row

    output reg  [31:0]  cnt_px,
    output reg  [31:0]  cnt_beats
);

    reg [511:0] acc;
    reg [6:0]   nbytes;
    reg [31:0]  row_base;
    reg [8:0]   beat_idx;
    reg         row_start;

    wire [31:0] cur_addr = row_base + {21'd0, beat_idx, 5'd0};

    // accept while a beat is not blocking and the accumulator has room for 3 bytes
    assign px_ready = (!beat_valid || beat_ready) && (nbytes <= 7'd32);

    reg [511:0] work_acc;
    reg [6:0]   work_nb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc        <= 512'd0;
            nbytes     <= 7'd0;
            row_base   <= 32'd0;
            beat_idx   <= 9'd0;
            row_start  <= 1'b1;
            beat_valid <= 1'b0;
            beat_addr  <= 32'd0;
            beat_data  <= 256'd0;
            beat_sof   <= 1'b0;
            cnt_px     <= 32'd0;
            cnt_beats  <= 32'd0;
        end
        else begin
            if (frame_start) begin
                acc       <= 512'd0;
                nbytes    <= 7'd0;
                row_base  <= frame_base;
                beat_idx  <= 9'd0;
                row_start <= 1'b1;
            end
            else begin
                if (beat_valid && beat_ready)
                    beat_valid <= 1'b0;

                if ((!beat_valid || beat_ready) && px_valid && px_de) begin
                    // ---- stage the write and the possible pop on a temporary
                    work_acc = acc;
                    work_nb  = nbytes;
                    work_acc[work_nb*8 +: 24] = px_data;
                    work_nb  = work_nb + 7'd3;
                    cnt_px   <= cnt_px + 32'd1;

                    if (work_nb >= 7'd32) begin
                        beat_valid <= 1'b1;
                        beat_addr  <= cur_addr;
                        beat_data  <= work_acc[255:0];
                        beat_sof   <= row_start;
                        cnt_beats  <= cnt_beats + 32'd1;
                        row_start  <= 1'b0;

                        work_acc = work_acc >> 256;
                        work_nb  = work_nb - 7'd32;
                        beat_idx <= beat_idx + 9'd1;

                        if (px_eol) begin
                            // the last pixel closes beat 180 exactly
                            row_base  <= row_base + STRIDE_BYTES[31:0];
                            beat_idx  <= 9'd0;
                            row_start <= 1'b1;
                        end
                    end

                    acc    <= work_acc;
                    nbytes <= work_nb;
                end
            end
        end
    end

endmodule
