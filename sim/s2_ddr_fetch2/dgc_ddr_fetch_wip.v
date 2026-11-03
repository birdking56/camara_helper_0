//-----------------------------------------------------------------------------
// dgc_ddr_fetch.v - native read request sequencer
// State machine fixed in docs section 12.
// `reserve` is driven combinationally by the state, NOT registered. When it was a
// registered pulse it became high during the AR cycle, the same cycle ar_fire
// fires, so the credit block added and subtracted in one cycle and the subtraction
// won: the counter wrapped and the sequencer halted (docs section 12.11).
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
    output reg [31:0] cnt_err, input wire job_restart
);
    localparam [2:0] IDLE=3'd0, RES=3'd1, AR=3'd2, WAIT=3'd3, HALT=3'd4;
    reg [2:0] st; reg second; reg [4:0] cur_beats; reg [31:0] cur_addr; reg [4:0] remaining;

    wire cross, is_single, split_ok; wire [4:0] fb, sb; wire [31:0] saddr;
    dgc_native_split u_split (.aligned_addr(aligned_addr), .beats(beats),
        .cross(cross), .first_beats(fb), .second_beats(sb), .second_addr(saddr),
        .is_single(is_single), .addr_ok(split_ok));

    reg [4:0] reserve_beats;
    wire reserve = (st == RES);          // combinational, sampled at the edge ending RES
    wire reserve_ok;
    wire [11:0] outstanding, reserved; wire overflow_seen;
    dgc_ddr_credit u_credit (.clk(clk), .rst_n(rst_n), .wr_level(wr_level),
        .reserve(reserve), .reserve_beats(reserve_beats), .reserve_ok(reserve_ok),
        .ar_fire(ar_valid && ar_ready), .ar_beats(cur_beats), .r_fire(r_valid),
        .outstanding(outstanding), .reserved(reserved), .headroom(), .overflow_seen(overflow_seen));

    wire e_any;
    dgc_rlast_check u_chk (.rvalid(r_valid), .rlast(r_last), .rid(r_id), .exp_id(4'd0),
        .remaining(remaining), .beat_taken(r_taken), .err_early(), .err_missing(),
        .err_extra(), .err_id(), .err_any(e_any));

    assign ar_valid  = (st == AR);
    assign ar_addr   = cur_addr[29:2];
    assign ar_len    = cur_beats - 5'd1;
    assign row_ready = (st == IDLE);
    assign busy      = (st != IDLE) && (st != HALT);
    assign halt      = (st == HALT);
    assign credit_bad = overflow_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=IDLE; second<=0; cur_beats<=0; cur_addr<=0; remaining<=0;
            cnt_err<=0; reserve_beats<=0;
        end
        else if (job_restart) begin st<=IDLE; second<=0; remaining<=0; end
        else begin
            if (r_valid && remaining != 5'd0) remaining <= remaining - 5'd1;
            if (r_valid && e_any) begin cnt_err <= cnt_err + 1; st <= HALT; end
            if (overflow_seen) st <= HALT;
            case (st)
            IDLE: if (row_valid) begin
                    if (!split_ok) begin st<=HALT; cnt_err<=cnt_err+1; end
                    else begin
                        second        <= cross;
                        cur_beats     <= is_single ? beats : fb;
                        cur_addr      <= aligned_addr;
                        reserve_beats <= is_single ? beats : fb;
                        st            <= RES;
                    end
                  end
            RES:  if (reserve_ok) begin remaining <= cur_beats; st <= AR; end
            AR:   if (ar_ready) st <= WAIT;
            WAIT: if (r_last) begin
                    if (second) begin
                        second        <= 0;
                        cur_beats     <= sb;
                        cur_addr      <= saddr;
                        reserve_beats <= sb;
                        st            <= RES;
                    end
                    else st <= IDLE;
                  end
            HALT: ;
            default: st <= IDLE;
            endcase
        end
    end
endmodule
