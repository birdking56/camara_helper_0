//-----------------------------------------------------------------------------
// dgc_cache_set4.v - one cache set with four simultaneous read ports
//
// Frozen reference: 接口冻结规范_v1.md section 8. The four bilinear neighbours of
// one output pixel land in four different banks when they are distinct, so all four
// can be read in one cycle. Where an edge makes two neighbours the same point, the
// sampler must read once and replicate (dgc_sample_dedup), so two ports never
// target the same bank in one cycle.
//
// Each bank therefore receives exactly one address per cycle, built from whichever
// port targets it. Each port then muxes the four captured bank outputs by its own
// delayed bank index, so no per-beat tags are needed.
//
// Timing contract, found the hard way during integration
//   The fire inputs are sampled every cycle; there is no back-pressure. If a caller
//   holds fire high and changes the coordinates, the outputs keep updating and each
//   result appears PIPE+1 = 3 cycles after the coordinates it belongs to. A caller
//   that samples immediately after changing the coordinates reads a stale point.
//   Two valid styles:
//     * pulse fire for one cycle per request and wait for the valid flag, or
//     * hold fire high and accept that the output always lags by 3 cycles.
//   Mixing the two silently returns the wrong pixel, which is exactly what the first
//   edge-integration testbench did.
//
// Kept separate from dgc_cache_set (verified single port) so that module stays
// untouched; the two-port-per-neighbour case is added only after this is proven.
//
// 2026-10-30: two write channels. The frozen spec section 8 already requires
// "2 像素/拍是解包与源缓存写端的目标能力"; the earlier integration wrote one
// pixel per cycle because it was the easy starting point, and the board then
// measured the cache write port as the dominant cost of a fill (556 of 707
// cycles per block). A two-pixel unpack record writes pixel x to channel 0 and
// x+1 to channel 1 in the same cycle: the two pixels have opposite x parity, so
// they always land in different banks and never fight for a write port.
// Accepted writes commit to RAM on the following edge through per-bank
// address/data/enable registers. The owner must wait for this write to commit
// before sampling; dgc_fill_ctrl's existing S_LAST completion stage covers it.
// Read latency remains three cycles and write acceptance stays one record/clock.
//-----------------------------------------------------------------------------

module dgc_cache_set4 (
    input  wire        clk, rst_n,

    // Write channel 0: one pixel. When wr2_valid is high this is the first of
    // two adjacent pixels of the same source row and wr2 is the second one.
    input  wire        wr_valid,
    output wire        wr_ready,
    input  wire [5:0]  wr_x, wr_y,
    input  wire [23:0] wr_rgb,

    // Write channel 1: pixel (x+1) of a two-pixel unpack record.
    // Contract: wr2 is only valid together with wr_valid, and x+1 must stay in
    // the same source row (the unpack guarantees both). The two pixels always
    // land in different x-parity banks, so they never contend for a bank.
    input  wire        wr2_valid,
    input  wire [23:0] wr2_rgb,

    input  wire        p0_fire, input wire [5:0] p0_x, p0_y,
    input  wire        p1_fire, input wire [5:0] p1_x, p1_y,
    input  wire        p2_fire, input wire [5:0] p2_x, p2_y,
    input  wire        p3_fire, input wire [5:0] p3_x, p3_y,

    output wire        p0_valid, output wire [23:0] p0_d,
    output wire        p1_valid, output wire [23:0] p1_d,
    output wire        p2_valid, output wire [23:0] p2_d,
    output wire        p3_valid, output wire [23:0] p3_d
);

    // ------------------------------------------------------- write addressing
    // bank = {y[0], x[0]}, address = (y>>1)*32 + (x>>1). The two pixels of a
    // pair have opposite x parity, hence different banks, but do NOT always
    // share an address: for an odd x, (x)>>1 and (x+1)>>1 differ. Both cases are
    // handled by giving every bank its own data/enable/address mux.
    wire [9:0] wa0  = {wr_y[5:1], 5'd0} + {5'd0, wr_x[5:1]};
    wire [5:0] x1   = wr_x + 6'd1;
    wire [9:0] wa1  = {wr_y[5:1], 5'd0} + {5'd0, x1[5:1]};

    wire [1:0] wb0 = {wr_y[0], wr_x[0]};        // first pixel
    wire [1:0] wb1 = {wr_y[0], ~wr_x[0]};       // second pixel is x+1

    wire wacc0 = wr_valid  && wr_ready;
    wire wacc1 = wr2_valid && wr_ready;

    // one write per bank: the two channels always select different banks
    reg [3:0]  we;
    reg [23:0] wd [0:3];
    reg [9:0]  waddr [0:3];

    genvar gw;
    generate
        for (gw = 0; gw < 4; gw = gw + 1) begin : gen_wr
            wire sel0 = (wb0 == gw[1:0]);
            wire sel1 = (wb1 == gw[1:0]);
            wire accept_bank = (wacc0 && sel0) || (wacc1 && sel1);
            // Local RAM write pipeline: decode set/parity before a register,
            // then drive each physical bank's WE/address/data from local flops.
            // The fill controller's S_LAST retirement already keeps the owner
            // FILLING until the final pipelined write commits. Read LAT unchanged.
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) we[gw] <= 1'b0;
                else we[gw] <= accept_bank;
            end
            always @(posedge clk) begin
                if (accept_bank) begin
                    wd[gw]    <= sel0 ? wr_rgb : wr2_rgb;
                    waddr[gw] <= sel0 ? wa0 : wa1;
                end
            end
        end
    endgenerate

    wire [1:0] b0 = {p0_y[0], p0_x[0]};
    wire [1:0] b1 = {p1_y[0], p1_x[0]};
    wire [1:0] b2 = {p2_y[0], p2_x[0]};
    wire [1:0] b3 = {p3_y[0], p3_x[0]};

    wire [9:0] a0 = {p0_y[5:1], 5'd0} + {5'd0, p0_x[5:1]};
    wire [9:0] a1 = {p1_y[5:1], 5'd0} + {5'd0, p1_x[5:1]};
    wire [9:0] a2 = {p2_y[5:1], 5'd0} + {5'd0, p2_x[5:1]};
    wire [9:0] a3 = {p3_y[5:1], 5'd0} + {5'd0, p3_x[5:1]};

    // one address per bank: whichever port selects it
    wire [39:0] raddr;      // 4 x 10
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_sel
            assign raddr[g*10 +: 10] = (b0 == g[1:0]) ? a0 :
                                       (b1 == g[1:0]) ? a1 :
                                       (b2 == g[1:0]) ? a2 : a3;
        end
    endgenerate

    wire [95:0] q;          // 4 x 24

    src_tile_bank_0 u_b0 (.wr_data(wd[0]), .wr_addr(waddr[0]), .wr_en(we[0]),
        .wr_clk(clk), .wr_rst(~rst_n), .rd_data(q[0*24 +: 24]),
        .rd_addr(raddr[0*10 +: 10]), .rd_clk(clk), .rd_rst(~rst_n));
    src_tile_bank_1 u_b1 (.wr_data(wd[1]), .wr_addr(waddr[1]), .wr_en(we[1]),
        .wr_clk(clk), .wr_rst(~rst_n), .rd_data(q[1*24 +: 24]),
        .rd_addr(raddr[1*10 +: 10]), .rd_clk(clk), .rd_rst(~rst_n));
    src_tile_bank_2 u_b2 (.wr_data(wd[2]), .wr_addr(waddr[2]), .wr_en(we[2]),
        .wr_clk(clk), .wr_rst(~rst_n), .rd_data(q[2*24 +: 24]),
        .rd_addr(raddr[2*10 +: 10]), .rd_clk(clk), .rd_rst(~rst_n));
    src_tile_bank_3 u_b3 (.wr_data(wd[3]), .wr_addr(waddr[3]), .wr_en(we[3]),
        .wr_clk(clk), .wr_rst(~rst_n), .rd_data(q[3*24 +: 24]),
        .rd_addr(raddr[3*10 +: 10]), .rd_clk(clk), .rd_rst(~rst_n));

    assign wr_ready = 1'b1;

    // ---- alignment: two DRM stages plus one capture register
    reg [3:0]  vf1, vf2, vf3;
    reg [1:0]  d0a, d0b, d0c;
    reg [1:0]  d1a, d1b, d1c;
    reg [1:0]  d2a, d2b, d2c;
    reg [1:0]  d3a, d3b, d3c;
    reg [95:0] cap;

    function [23:0] pick(input [1:0] sel, input [95:0] v);
        begin
            case (sel)
                2'd0: pick = v[0*24 +: 24];
                2'd1: pick = v[1*24 +: 24];
                2'd2: pick = v[2*24 +: 24];
                default: pick = v[3*24 +: 24];
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vf1 <= 4'd0; vf2 <= 4'd0; vf3 <= 4'd0;
            d0a <= 2'd0; d0b <= 2'd0; d0c <= 2'd0;
            d1a <= 2'd0; d1b <= 2'd0; d1c <= 2'd0;
            d2a <= 2'd0; d2b <= 2'd0; d2c <= 2'd0;
            d3a <= 2'd0; d3b <= 2'd0; d3c <= 2'd0;
            cap <= 96'd0;
        end
        else begin
            vf1 <= {p3_fire, p2_fire, p1_fire, p0_fire};
            vf2 <= vf1;
            vf3 <= vf2;

            d0a <= b0; d0b <= d0a; d0c <= d0b;
            d1a <= b1; d1b <= d1a; d1c <= d1b;
            d2a <= b2; d2b <= d2a; d2c <= d2b;
            d3a <= b3; d3b <= d3a; d3c <= d3b;

            // q is indexed by BANK; each port must take the bank it selected, so the
            // capture muxes by that port's delayed bank index. The cap lanes are then
            // indexed by PORT, which is what the outputs want.
            if (vf2[0]) cap[0*24 +: 24] <= pick(d0b, q);
            if (vf2[1]) cap[1*24 +: 24] <= pick(d1b, q);
            if (vf2[2]) cap[2*24 +: 24] <= pick(d2b, q);
            if (vf2[3]) cap[3*24 +: 24] <= pick(d3b, q);
        end
    end

    // cap is already per port, so the outputs are a plain read
    assign p0_valid = vf3[0]; assign p0_d = cap[0*24 +: 24];
    assign p1_valid = vf3[1]; assign p1_d = cap[1*24 +: 24];
    assign p2_valid = vf3[2]; assign p2_d = cap[2*24 +: 24];
    assign p3_valid = vf3[3]; assign p3_d = cap[3*24 +: 24];

endmodule
