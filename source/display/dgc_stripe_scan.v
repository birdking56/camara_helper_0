//-----------------------------------------------------------------------------
// dgc_stripe_scan.v
//
// Raster address generator for reading one output stripe back out.
//
// Frozen reference: 接口冻结规范_v1.md section 10.
//
//   * A stripe row occupies 2048 slots, and the pixel slot is
//       slot_addr[14:0] = {dst_y[3:0], dst_x[10:0]}
//     so x = 1920..2047 is padding and is never scanned.
//   * A normal stripe is 1920x16 = 30,720 pixels; the last stripe (id 67) is
//     1920x8 = 15,360.
//   * Scanning is one pixel per cycle in raster order, y outer and x inner, with
//     no gaps, because the read side is the fixed 148.5 MHz display path.
//
// This module is the address side only. It does not read the RAM, does not cross
// clock domains and does not implement start-of-stripe handover; those are the
// integration step, which will drive `start` from the vout domain and take the
// RAM data through the same two-cycle read alignment proven in s0_ip_probe.
// Keeping the scan arithmetic separate makes it verifiable on its own: the
// expected sequence is fully determined by the stripe id.
//-----------------------------------------------------------------------------

module dgc_stripe_scan (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,          // pulse to begin a stripe
    input  wire [6:0]  stripe_id,
    input  wire [4:0]  valid_lines,    // 16 normally, 8 for stripe 67

    output reg  [14:0] slot_addr,
    output reg  [10:0] dst_x,
    output reg  [10:0] dst_y,
    output reg         de,             // one pixel per cycle while scanning
    output reg         active,
    output reg         done            // pulses for one cycle after the last pixel
);

    localparam [10:0] LINE_PIXELS = 11'd1920;

    reg [10:0] x;
    reg [4:0]  ly;

    wire [10:0] base_y  = {4'd0, stripe_id} << 4;   // stripe_id * 16
    wire [10:0] cur_y   = base_y + {6'd0, ly};
    wire [14:0] cur_adr = {ly[3:0], x};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x         <= 11'd0;
            ly        <= 5'd0;
            slot_addr <= 15'd0;
            dst_x     <= 11'd0;
            dst_y     <= 11'd0;
            de        <= 1'b0;
            active    <= 1'b0;
            done      <= 1'b0;
        end
        else if (start) begin
            // Only arm the counters. The addresses are driven by the active
            // branch below, so the first pixel presented is x=0 and not a
            // duplicate of it.
            x      <= 11'd0;
            ly     <= 5'd0;
            active <= 1'b1;
            done   <= 1'b0;
            de     <= 1'b0;
        end
        else if (active) begin
            // present the current pixel, then advance
            slot_addr <= cur_adr;
            dst_x     <= x;
            dst_y     <= cur_y;
            de        <= 1'b1;

            if (x == LINE_PIXELS - 11'd1) begin
                x <= 11'd0;
                if (ly == valid_lines - 5'd1) begin
                    // The last pixel still needs de = 1 for its own cycle; the
                    // inactive branch clears de on the following cycle.
                    active <= 1'b0;
                    done   <= 1'b1;
                end
                else begin
                    ly <= ly + 5'd1;
                end
            end
            else begin
                x <= x + 11'd1;
            end
        end
        else begin
            de   <= 1'b0;
            done <= 1'b0;
        end
    end

endmodule
