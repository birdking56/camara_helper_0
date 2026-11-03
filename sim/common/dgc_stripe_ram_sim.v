//-----------------------------------------------------------------------------
// dgc_stripe_ram_sim.v
//
// Behavioural stand-in for the two generated stripe RAMs, used ONLY by the
// full-system simulation (sim/s5_sys). The generated Pango DRM models are exact
// in isolation (see s4_stripe_ram) but in the full system, which elaborates more
// than twenty DRM instances, they stop updating on the read port: a third,
// independent instance written 0..3 and streamed back returns the word at
// address 0 (see docs 0.3n). Synthesis keeps using the real IP; this model only
// lets the system-level functional test observe the writer's data.
//
// Semantics matched to the IP: 24-bit x 32768, independent clocks, one output
// register, so the data for the address presented in cycle t is available in
// cycle t+2 (the reader's RD_LAT is 2).
//-----------------------------------------------------------------------------

module out_stripe_ram (
    input  wire [23:0] wr_data,
    input  wire [14:0] wr_addr,
    input  wire        wr_en,
    input  wire        wr_clk,
    input  wire        wr_rst,
    output reg  [23:0] rd_data,
    input  wire [14:0] rd_addr,
    input  wire        rd_clk,
    input  wire        rd_rst
);
    reg [23:0] mem [0:32767];
    reg [14:0] a1;

    always @(posedge wr_clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            a1 <= 15'd0;
            rd_data <= 24'd0;
        end
        else begin
            a1 <= rd_addr;
            rd_data <= mem[a1];
        end
    end
endmodule

module out_stripe_ram_1 (
    input  wire [23:0] wr_data,
    input  wire [14:0] wr_addr,
    input  wire        wr_en,
    input  wire        wr_clk,
    input  wire        wr_rst,
    output reg  [23:0] rd_data,
    input  wire [14:0] rd_addr,
    input  wire        rd_clk,
    input  wire        rd_rst
);
    reg [23:0] mem [0:32767];
    reg [14:0] a1;

    always @(posedge wr_clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            a1 <= 15'd0;
            rd_data <= 24'd0;
        end
        else begin
            a1 <= rd_addr;
            rd_data <= mem[a1];
        end
    end
endmodule
