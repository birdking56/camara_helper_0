//-----------------------------------------------------------------------------
// dgc_cache_set.v - one source cache set: four 24x1024 DRM banks
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//   local bank = {local_y[0], local_x[0]},  address = (local_y>>1)*32 + (local_x>>1)
//   The address mapping is verified exhaustively in dgc_src_addr; this module is
//   the physical wiring around four differently named RAM wrappers, plus the
//   two-cycle read alignment proven in s0_ip_probe.
//
// One pixel per beat on both sides keeps this module to the wiring question only.
// The four-neighbour simultaneous read is a separate concern: it needs four ports
// and is being added after this single-point path is proven, because the earlier
// attempts failed at the eight-bank wiring rather than at the arithmetic.
//-----------------------------------------------------------------------------

module dgc_cache_set #(
    parameter integer PIPE = 2
) (
    input  wire        clk, rst_n,

    input  wire        wr_valid,
    output wire        wr_ready,
    input  wire [5:0]  wr_x, wr_y,
    input  wire [23:0] wr_rgb,

    input  wire        rd_fire,
    output wire        rd_ready,
    input  wire [5:0]  rd_x, rd_y,
    output wire        rd_valid,
    output wire [23:0] rd_rgb
);

    wire [1:0]  wb = {wr_y[0], wr_x[0]};
    wire [9:0]  wa = {wr_y[5:1], 5'd0} + {5'd0, wr_x[5:1]};
    wire [1:0]  rb = {rd_y[0], rd_x[0]};
    wire [9:0]  ra = {rd_y[5:1], 5'd0} + {5'd0, rd_x[5:1]};

    wire [23:0] q0, q1, q2, q3;

    // ---- the four banks, explicit because the wrappers have different names
    src_tile_bank_0 u_b0 (.wr_data(wr_rgb), .wr_addr(wa), .wr_en(wr_valid && wr_ready && wb == 2'd0),
        .wr_clk(clk), .wr_rst(~rst_n), .rd_data(q0), .rd_addr(ra), .rd_clk(clk), .rd_rst(~rst_n));
    src_tile_bank_1 u_b1 (.wr_data(wr_rgb), .wr_addr(wa), .wr_en(wr_valid && wr_ready && wb == 2'd1),
        .wr_clk(clk), .wr_rst(~rst_n), .rd_data(q1), .rd_addr(ra), .rd_clk(clk), .rd_rst(~rst_n));
    src_tile_bank_2 u_b2 (.wr_data(wr_rgb), .wr_addr(wa), .wr_en(wr_valid && wr_ready && wb == 2'd2),
        .wr_clk(clk), .wr_rst(~rst_n), .rd_data(q2), .rd_addr(ra), .rd_clk(clk), .rd_rst(~rst_n));
    src_tile_bank_3 u_b3 (.wr_data(wr_rgb), .wr_addr(wa), .wr_en(wr_valid && wr_ready && wb == 2'd3),
        .wr_clk(clk), .wr_rst(~rst_n), .rd_data(q3), .rd_addr(ra), .rd_clk(clk), .rd_rst(~rst_n));

    assign wr_ready = 1'b1;
    assign rd_ready = 1'b1;

    // ---- read alignment: the DRM output appears PIPE cycles after the fire, so
    //      carry the bank index alongside and capture one cycle later
    reg [1:0] bd1, bd2, bd3;
    reg       v1, v2, v3;
    reg [23:0] qcap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bd1 <= 2'd0; bd2 <= 2'd0; bd3 <= 2'd0;
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            qcap <= 24'd0;
        end
        else begin
            bd1 <= rb; v1 <= rd_fire;
            bd2 <= bd1; v2 <= v1;
            bd3 <= bd2; v3 <= v2;
            if (v2) begin
                case (bd2)
                    2'd0: qcap <= q0;
                    2'd1: qcap <= q1;
                    2'd2: qcap <= q2;
                    default: qcap <= q3;
                endcase
            end
        end
    end

    assign rd_valid = v3;
    assign rd_rgb   = qcap;

endmodule
