//-----------------------------------------------------------------------------
// dgc_ddr_rd_adapter.v
//
// Connects the native read channel of the DDR3 IP to the read FIFO and supplies
// ddr_fetch with a safe occupancy estimate.
//
// Frozen reference: 接口冻结规范_v1.md section 7.
//
//   * `dgc_ddr_fetch` owns the request sequence (MAX_OUTSTANDING = 1, 4 KiB
//     split, rlast/ID checks). This wrapper only adds the channel plumbing.
//   * The IP has no rready: every rvalid beat must be accepted. The credit
//     invariant U+O+P+B+16 <= 1024 is what makes that possible; it needs `U`,
//     the write-side FIFO occupancy.
//   * The generated FIFO's wr_water_level is not usable as a credit input in
//     simulation (it is Z before the first access in some IPs, and even when it
//     is driven it is only an estimate synchronized from the read pointer).
//     The adapter therefore counts the words it writes and subtracts a
//     gray-coded read counter synchronized from the consumer side. The
//     synchronized counter always lags the real read pointer, so `U` is an
//     upper bound - which is the safe direction for the credit check.
//
// Errors
//   rvalid while the FIFO reports full would mean the credit invariant failed
//   and the beat is lost (the IP cannot be back-pressured). That is counted as
//   a task fault and asserted in simulation; the frame must then be aborted.
//-----------------------------------------------------------------------------

module dgc_ddr_rd_adapter (
    input  wire        clk,             // ddr_clk
    input  wire        rst_n,

    // ---------------- row request (already crossed into the DDR domain) ------
    input  wire        row_valid,
    output wire        row_ready,
    input  wire [31:0] row_addr,        // 32-byte aligned byte address
    input  wire [4:0]  row_beats,

    // ---------------- read-side pop count (gray, from the processing domain) -
    input  wire [11:0] rd_beats_gray,

    // ---------------- native read address channel ----------------------------
    output wire [27:0] ar_addr,
    output wire [3:0]  ar_len,
    output wire        ar_valid,
    input  wire        ar_ready,

    // ---------------- native read data channel ------------------------------
    input  wire [255:0] r_data,
    input  wire         r_valid,
    input  wire         r_last,
    input  wire [3:0]   r_id,

    // ---------------- read FIFO write side ----------------------------------
    input  wire         fifo_full,
    output wire         fifo_wr,
    output wire [255:0] fifo_data,

    // ---------------- status -------------------------------------------------
    output wire        busy,
    output wire        halt,
    output wire        credit_bad,
    output wire [31:0] cnt_err,
    output reg  [31:0] cnt_beats,
    output reg  [31:0] cnt_rows,
    output wire [10:0] wr_level,        // U, for the credit check
    input  wire        job_restart,
    // ---------------- performance taps (DGC3 report, read-only) -------------
    output wire        dbg_ar_wait,
    output wire        dbg_ret_starve,
    output wire [3:0]  dbg_ret_cnt
);

    // ------------------------------------------------------------- ddr_fetch
    wire [10:0] used;
    wire        r_taken;
    wire [31:0] fetch_err;
    reg  [31:0] own_err;

    dgc_ddr_fetch u_fetch (
        .clk (clk), .rst_n (rst_n),
        .row_valid (row_valid), .row_ready (row_ready),
        .aligned_addr (row_addr), .beats (row_beats),
        .wr_level (used),
        .ar_valid (ar_valid), .ar_ready (ar_ready),
        .ar_addr (ar_addr), .ar_len (ar_len),
        .r_valid (r_valid), .r_last (r_last), .r_id (r_id),
        .r_taken (r_taken),
        .busy (busy), .halt (halt), .credit_bad (credit_bad),
        .cnt_err (fetch_err), .job_restart (job_restart),
        .dbg_ar_wait (dbg_ar_wait), .dbg_ret_starve (dbg_ret_starve),
        .dbg_ret_cnt (dbg_ret_cnt)
    );

    // ------------------------------------------------------------------ FIFO
    // The IP cannot be back-pressured, so a beat is written whenever rvalid is
    // high. `fifo_full` at that moment is a hard error, not a stall.
    assign fifo_wr   = r_valid;
    assign fifo_data = r_data;

    wire beat_lost = r_valid & fifo_full;

    // ------------------------------------------------------------ occupancy
    reg  [11:0] wr_count;
    reg  [11:0] g1, g2;                 // read counter synchronised into this domain

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_count <= 12'd0;
            g1 <= 12'd0; g2 <= 12'd0;
        end
        else begin
            g1 <= rd_beats_gray;
            g2 <= g1;
            if (fifo_wr) wr_count <= wr_count + 12'd1;
        end
    end

    function [11:0] gray2bin(input [11:0] g);
        integer k;
        begin
            gray2bin[11] = g[11];
            for (k = 10; k >= 0; k = k - 1)
                gray2bin[k] = gray2bin[k+1] ^ g[k];
        end
    endfunction

    wire [11:0] rd_count = gray2bin(g2);
    wire [11:0] used_w   = wr_count - rd_count;    // wraps correctly: mod 4096
    assign used      = used_w[10:0];
    assign wr_level  = used;

    // ------------------------------------------------------------- counters
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            own_err <= 32'd0;
            cnt_beats <= 32'd0;
            cnt_rows <= 32'd0;
        end
        else begin
            if (beat_lost) own_err <= own_err + 32'd1;
            if (fifo_wr) cnt_beats <= cnt_beats + 32'd1;
            if (row_valid && row_ready) cnt_rows <= cnt_rows + 32'd1;
        end
    end

    assign cnt_err = own_err + fetch_err;

`ifdef DGC_SIM
    // U is an upper bound on the real occupancy, so it must never be smaller
    // than what the FIFO actually holds. A popped-but-not-yet-synchronised word
    // only makes U larger, which is why the design is safe.
    always @(posedge clk) begin
        if (rst_n && beat_lost)
            $display("DGC_ERROR: ddr_rd_adapter beat lost, FIFO full while rvalid t=%0t", $time);
    end
`endif

endmodule
