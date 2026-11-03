//-----------------------------------------------------------------------------
// dgc_ddr_fetch.v - native read request sequencer (multi-outstanding)
//
// 2026-10-30 route A. The frozen interface spec allows more than one outstanding
// native request provided the return order/ID are verified and the credit proof
// still holds; MAX_NATIVE_OUTSTANDING=1 was only the correctness starting point.
// A stripe needs 17 rows x 60 blocks = 1020 rows inside a 237 us scan window
// (232 ns/row); the single-row turnaround was already ~226 ns with an ideal DDR
// model, so any real latency made the stripe miss its deadline and the reader
// went black (underflow +1/frame, flags 0x0402).
//
// Structure: request side and return side are independent.
//   * request queue (4 entries): a row is accepted while two slots are free; a
//     page-crossing row is split into its two native parts at acceptance, so the
//     issuer never waits for data to issue the second half.
//   * issuer: pops one entry, reserves credit, pulses AR, pushes the expected
//     beat count onto the return queue. It starts only when the return queue has
//     room, so an expectation can never be overwritten.
//   * return side: AXI returns beats in AR order. Every beat is checked against
//     the head count (r_last exactly on the last beat, r_id must be 0); the count
//     is decremented and the entry popped on its last beat.
//
// All queue pointers wrap modulo QD (a non-wrapping write pointer indexed past
// the array and silently corrupted the order in the first version).
//-----------------------------------------------------------------------------
module dgc_ddr_fetch (
    input  wire clk, rst_n,
    input  wire row_valid, output wire row_ready,
    input  wire [31:0] aligned_addr, input wire [4:0] beats,
    input  wire [10:0] wr_level,
    output wire ar_valid, input wire ar_ready,
    output wire [27:0] ar_addr, output wire [3:0] ar_len,
    input  wire r_valid, input wire r_last, input wire [3:0] r_id,
    output wire r_taken,
    output wire busy, output wire halt, output wire credit_bad,
    output reg [31:0] cnt_err, input wire job_restart,
    // ---------------- performance taps (DGC3 report, read-only) -------------
    // The board job is ~1.8x the simulated cycle count per row. These four say
    // whether the DDR side is (a) refusing the next AR, (b) holding requests
    // without returning data, (c) actually running several requests at once,
    // and (d) how many native ARs were issued (4 KiB splits included).
    output wire        dbg_ar_wait,     // issuer has an AR pending, IP not ready
    output wire        dbg_ret_starve,  // requests outstanding, no beat returning
    output wire [3:0]  dbg_ret_cnt      // requests issued but not completed (saturates at 15)
);
    // 2026-11-01 (reverted experiment): QD was briefly raised 8 -> 16 to widen the
    // read window.  It cost 0.42 ns on the proc domain (-0.041 -> -0.461) and
    // 0.61 ns on ddrphy_sysclk (+0.13 -> -0.48): the sixteen-entry request/return
    // queues are ~600 extra flops plus a deeper head mux, and the congestion
    // pushed the DDRC logic too.  Back to 8; the read side is credit-limited, not
    // queue-limited, so the extra entries bought nothing.
    localparam integer QD = 8;

    reg  [36:0] req_q [0:QD-1];         // {addr[31:0], beats[4:0]}
    reg  [3:0]  req_wp, req_rp, req_cnt;

    reg  [4:0]  ret_q [0:QD-1];         // beats still expected, in AR order
    reg  [3:0]  ret_wp, ret_rp, ret_cnt;

    // A crossing row pushes two entries, so keep two slots free.
    assign row_ready = (req_cnt <= (QD-2));

    // ---------------------------------------------------------------- splitter
    wire cross, is_single, split_ok;
    wire [4:0] fb, sb;
    wire [31:0] saddr;
    dgc_native_split u_split (.aligned_addr(aligned_addr), .beats(beats),
        .cross(cross), .first_beats(fb), .second_beats(sb), .second_addr(saddr),
        .is_single(is_single), .addr_ok(split_ok));

    // ------------------------------------------------------------- issue engine
    localparam [1:0] I_IDLE = 2'd0, I_RES = 2'd1, I_AR = 2'd2;
    reg  [1:0]  ist;
    reg  [31:0] cur_addr;
    reg  [4:0]  cur_beats;

    wire reserve = (ist == I_RES);
    wire reserve_ok;
    wire [11:0] outstanding, reserved;
    wire overflow_seen;
    dgc_ddr_credit u_credit (.clk(clk), .rst_n(rst_n), .wr_level(wr_level),
        .reserve(reserve), .reserve_beats(cur_beats), .reserve_ok(reserve_ok),
        .ar_fire(ar_valid && ar_ready), .ar_beats(cur_beats), .r_fire(r_valid),
        .outstanding(outstanding), .reserved(reserved), .headroom(), .overflow_seen(overflow_seen));

    assign ar_valid = (ist == I_AR);
    assign ar_addr  = cur_addr[29:2];
    assign ar_len   = cur_beats - 5'd1;

    // ------------------------------------------------------------ return engine
    wire [4:0] head_left = ret_q[ret_rp];
    wire       head_last = (head_left == 5'd1);

    wire err_early   = r_valid && (ret_cnt == 0);
    wire err_missing = r_valid && (ret_cnt != 0) && head_last && !r_last;
    wire err_extra   = r_valid && (ret_cnt != 0) && !head_last && r_last;
    wire err_id      = r_valid && (r_id != 4'd0);
    wire err_any     = err_early | err_missing | err_extra | err_id;

    assign r_taken = r_valid;

    reg    halted;
    assign halt    = halted;
    assign busy    = (req_cnt != 0) || (ist != I_IDLE) || (ret_cnt != 0);
    assign credit_bad = overflow_seen;

    // ------------------------------------------------------- performance taps
    // ar_wait: the address channel is presenting an AR while ar_ready is low.
    //   A large value means the IP, not our queue, limits the request rate.
    // ret_starve: at least one AR has been handshaked and its beats have not all
    //   returned, yet no beat is arriving this cycle. This is the read latency /
    //   return-bandwidth exposure of the fetch engine.
    assign dbg_ar_wait    = (ist == I_AR) && !ar_ready;
    assign dbg_ret_starve = (ret_cnt != 0) && !r_valid;
    assign dbg_ret_cnt    = ret_cnt;

    // ------------------------------------------------------------- sequential
    wire acc_row = row_valid && row_ready && split_ok;
    wire acc_two = acc_row && !is_single;
    wire iss_ar  = (ist == I_AR) && ar_ready;
    wire ret_pop = r_valid && (ret_cnt != 0) && head_last;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ist <= I_IDLE; cur_addr <= 0; cur_beats <= 0;
            req_wp <= 0; req_rp <= 0; req_cnt <= 0;
            ret_wp <= 0; ret_rp <= 0; ret_cnt <= 0;
            halted <= 1'b0; cnt_err <= 0;
            for (i = 0; i < QD; i = i + 1) begin req_q[i] <= 0; ret_q[i] <= 0; end
        end
        else if (job_restart) begin
            ist <= I_IDLE; req_wp <= 0; req_rp <= 0; req_cnt <= 0;
            ret_wp <= 0; ret_rp <= 0; ret_cnt <= 0; halted <= 1'b0;
        end
        else if (!halted) begin
            // ---- accept a row (one or two native requests)
            if (acc_row) begin
                if (is_single) begin
                    req_q[req_wp] <= {aligned_addr, beats};
                end
                else begin
                    req_q[req_wp] <= {aligned_addr, fb};
                    req_q[(req_wp + 3'd1) & (QD-1)] <= {saddr, sb};
                end
            end
            if (row_valid && row_ready && !split_ok) begin
                halted  <= 1'b1;
                cnt_err <= cnt_err + 1;
            end

            // ---- issue engine (independent of data return)
            case (ist)
            I_IDLE: if (req_cnt != 0 && ret_cnt != QD) begin
                        cur_addr  <= req_q[req_rp][36:5];
                        cur_beats <= req_q[req_rp][4:0];
                        ist       <= I_RES;
                    end
            I_RES:  if (reserve_ok) ist <= I_AR;
            I_AR:   if (ar_ready) begin
                        ret_q[ret_wp] <= cur_beats;
                        ist           <= I_IDLE;
                    end
            endcase

            // ---- pointers and counts (one assignment each, wrapping mod QD)
            if (acc_row) req_wp <= (req_wp + (is_single ? 3'd1 : 3'd2)) & (QD-1);
            if (iss_ar)  req_rp <= (req_rp + 3'd1) & (QD-1);
            if (iss_ar)  ret_wp <= (ret_wp + 3'd1) & (QD-1);
            if (ret_pop) ret_rp <= (ret_rp + 3'd1) & (QD-1);

            req_cnt <= req_cnt + (acc_row ? (is_single ? 3'd1 : 3'd2) : 3'd0)
                               - (iss_ar ? 3'd1 : 3'd0);
            ret_cnt <= ret_cnt + (iss_ar ? 3'd1 : 3'd0)
                               - (ret_pop ? 3'd1 : 3'd0);

            // ---- return side: decrement the head unless it is the last beat
            if (r_valid) begin
                if (ret_cnt != 0 && !head_last) ret_q[ret_rp] <= head_left - 5'd1;
                if (err_any) begin
                    halted  <= 1'b1;
                    cnt_err <= cnt_err + 1;
                end
            end
            if (overflow_seen) begin
                halted  <= 1'b1;
                cnt_err <= cnt_err + 1;
            end
        end
    end

    // ------------------------------------------------------- observation view
    // Compatibility view for the directed tests: WAIT is reported while beats
    // are outstanding, HALT wins over everything.
    wire [2:0] st = halted        ? 3'd4 :
                    (ist == I_AR) ? 3'd2 :
                    (ist == I_RES)? 3'd1 :
                    (ret_cnt != 0)? 3'd3 : 3'd0;
    wire [4:0] remaining = (ret_cnt != 0) ? ret_q[ret_rp] : 5'd0;
    wire       e_any     = err_any;   // s5_sys diagnostic reference
endmodule














