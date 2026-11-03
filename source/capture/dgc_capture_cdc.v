//-----------------------------------------------------------------------------
// dgc_capture_cdc.v
//
// Crosses the capture beat stream from the input pixel clock domain (vin_clk)
// to the DDR user clock domain (ddr_clk) through the generated 288-bit
// asynchronous pixel-beat FIFO.
//
// Frozen reference: 接口冻结规范_v1.md sections 2 and 4.
//
//   * The beat payload is 32 bytes of pixels plus the 32-bit byte address of the
//     beat, so the DDR side never has to reconstruct the address.
//   * capture_pack runs at one pixel per vin_clk; the DDR side consumes one beat
//     per ddr_clk, which is far more bandwidth than the 11.7 M beats/s the input
//     produces. The FIFO therefore only has to absorb DDR arbitration jitter.
//   * The read side is exposed as a plain valid/ready stream backed by the
//     already-verified dgc_fifo_rd_port (2-cycle pop latency, elastic output).
//   * Both FIFO resets must be asserted together for a session restart; this
//     wrapper takes one reset per side and leaves the coordination to the
//     caller, exactly like the other IP wrappers.
//-----------------------------------------------------------------------------

module dgc_capture_cdc (
    input  wire        wr_clk,          // vin_clk
    input  wire        wr_rst_n,
    input  wire        rd_clk,          // ddr_clk
    input  wire        rd_rst_n,

    // ---------------- capture side (vin_clk) ---------------------------------
    input  wire [287:0] wr_data,        // {byte_addr[31:0], beat_data[255:0]}
    input  wire         wr_en,
    output wire         wr_full,
    output wire [8:0]   wr_level,

    // ---------------- DDR side (ddr_clk) -------------------------------------
    output wire         rd_valid,
    input  wire         rd_ready,
    output wire [287:0] rd_data,

    // ---------------- diagnostics -------------------------------------------
    output wire [31:0]  cnt_push,
    output wire [31:0]  cnt_pop
);

    wire         ip_rd_empty;
    wire [287:0] ip_rd_data;
    wire         ip_rd_en;
    wire         ip_wr_full;
    wire [8:0]   ip_wr_level;
    wire         ip_almost_full, ip_almost_empty;
    wire [8:0]   ip_rd_level;

    pix_beat_fifo u_fifo (
        .wr_clk          (wr_clk),
        .wr_rst          (~wr_rst_n),
        .wr_en           (wr_en),
        .wr_data         (wr_data),
        .wr_full         (ip_wr_full),
        .wr_water_level  (ip_wr_level),
        .almost_full     (ip_almost_full),
        .rd_clk          (rd_clk),
        .rd_rst          (~rd_rst_n),
        .rd_en           (ip_rd_en),
        .rd_data         (ip_rd_data),
        .almost_empty    (ip_almost_empty),
        .rd_empty        (ip_rd_empty),
        .rd_water_level  (ip_rd_level)
    );

    assign wr_full  = ip_wr_full;
    assign wr_level = ip_wr_level;

    // Pop as soon as the elastic buffer has room; the consumer only ever sees
    // the aligned valid/ready stream.
    dgc_fifo_rd_port #(.DATA_W(288)) u_rd (
        .clk        (rd_clk),
        .rst_n      (rd_rst_n),
        .rd_fire    (1'b1),
        .rd_ready   (),
        .fifo_empty (ip_rd_empty),
        .fifo_pop   (ip_rd_en),
        .fifo_data  (ip_rd_data),
        .out_valid  (rd_valid),
        .out_ready  (rd_ready),
        .out_data   (rd_data)
    );

    // ------------------------------------------------------------- counters
    reg [31:0] push_c, pop_c;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) push_c <= 32'd0;
        else if (wr_en) push_c <= push_c + 32'd1;
    end
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) pop_c <= 32'd0;
        else if (ip_rd_en) pop_c <= pop_c + 32'd1;
    end
    assign cnt_push = push_c;
    assign cnt_pop  = pop_c;

endmodule
