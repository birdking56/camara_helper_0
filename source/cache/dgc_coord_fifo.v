//-----------------------------------------------------------------------------
// dgc_coord_fifo.v
//
// Wrapper around the generated 96 x 2048 synchronous coordinate FIFO.
//
// Frozen reference: 接口冻结规范_v1.md section 6.
//   The coordinate FIFO carries the 96-bit coordinate record. Its read side is a
//   pop command, so the alignment and the "never pop while empty" rule are
//   handled by dgc_fifo_rd_port rather than by the callers.
//
// Interface
//   write side : wr_valid / wr_ready / wr_data[95:0]
//                wr_ready is simply not-full; the scheduler is responsible for
//                reserving width*height slots plus one descriptor before it
//                starts mapping a candidate block, as the frozen spec requires.
//   read side  : rd_fire / rd_ready, then rd_valid / rd_ready_o / rd_data
//                with the two-cycle pop latency absorbed by the port wrapper.
//   status     : full, empty and both water levels are exposed for diagnostics
//                and for the reservation logic.
//
// Reset
//   The IP uses an active-high reset; the wrapper takes the project-wide
//   active-low rst_n and inverts it, as the spec requires of every IP wrapper.
//-----------------------------------------------------------------------------

module dgc_coord_fifo (
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- write side --------------------------------------------
    input  wire        wr_valid,
    output wire        wr_ready,
    input  wire [95:0] wr_data,

    // ---------------- read side ---------------------------------------------
    input  wire        rd_fire,
    output wire        rd_ready,       // request accepted; can be used as a credit
    output wire        rd_valid,
    input  wire        rd_ready_o,
    output wire [95:0] rd_data,

    // Job-boundary flush: the coordinate stage, the elastic read port and the
    // IP FIFO are all cleared so no record from the previous job can be
    // consumed by the new one. Without it the writer's job_restart cleared
    // bank0 and then the first stale record (a stripe-18 coordinate from the
    // old frame) immediately re-armed it as stripe 18, which deadlocked
    // px_ready against the new job's stripe-0 pixels (board 2026-10-29).
    input  wire        flush,

    // ---------------- status ------------------------------------------------
    output wire        full,
    output wire        empty,
    output wire [12:0] wr_level,
    output wire [12:0] rd_level
);

    wire        ip_wr_full;
    wire        ip_rd_empty;
    wire        ip_almost_full;
    wire        ip_almost_empty;
    wire [12:0] ip_wr_level;
    wire [12:0] ip_rd_level;
    wire [95:0] ip_rd_data;
    wire        ip_rd_en;

    // The generated IP's water-level outputs are `Z` in behavioural simulation
    // until the first write/read (the real hardware computes them from the
    // pointers). The reservation logic must not depend on that, and for a
    // synchronous FIFO the occupancy is exact anyway, so the wrapper keeps its
    // own write/read event counter and reports that instead.
    reg [12:0] level;

    wire wr_fire = wr_valid & wr_ready;
    wire pop_fire = ip_rd_en;

    coord_fifo u_ip (
        .clk             (clk),
        .rst             (~rst_n | flush),
        .wr_en           (wr_valid & wr_ready),
        .wr_data         (wr_data),
        .wr_full         (ip_wr_full),
        .wr_water_level  (ip_wr_level),
        .rd_en           (ip_rd_en),
        .rd_data         (ip_rd_data),
        .almost_full     (ip_almost_full),
        .rd_empty        (ip_rd_empty),
        .rd_water_level  (ip_rd_level),
        .almost_empty    (ip_almost_empty)
    );

    assign wr_ready = ~ip_wr_full;
    assign full     = ip_wr_full;
    assign empty    = ip_rd_empty;
    assign wr_level = level;
    assign rd_level = level;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) level <= 13'd0;
        else if (flush) level <= 13'd0;
        else begin
            case ({wr_fire, pop_fire})
                2'b10:   level <= level + 13'd1;
                2'b01:   level <= level - 13'd1;
                default: level <= level;
            endcase
        end
    end

    dgc_fifo_rd_port #(.DATA_W(96)) u_rd (
        .clk        (clk),
        .rst_n      (rst_n & ~flush),
        .rd_fire    (rd_fire),
        .rd_ready   (rd_ready),
        .fifo_empty (ip_rd_empty),
        .fifo_pop   (ip_rd_en),
        .fifo_data  (ip_rd_data),
        .out_valid  (rd_valid),
        .out_ready  (rd_ready_o),
        .out_data   (rd_data)
    );

endmodule

