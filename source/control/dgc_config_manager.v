//-----------------------------------------------------------------------------
// dgc_config_manager.v
//
// Register file, shadow/active parameter model and error reporting.
//
// Frozen reference: 接口冻结规范_v1.md section 11.
//
// Bus
//   cfg_req_valid / ready, cfg_req_write, cfg_req_addr[15:0], cfg_req_wdata[31:0]
//   cfg_rsp_valid / ready, cfg_rsp_rdata[31:0], cfg_rsp_error[7:0]
//   Byte address, 4-byte aligned, whole 32-bit access, no partial byte writes.
//   One request produces exactly one response; at most one request is in flight.
//
// Register map (as frozen)
//   0x0000 RO version 0x00010000
//   0x0004 RO capability
//   0x0008 RO status
//   0x000C RW write 1 = commit, read = active config_epoch[15:0]
//   0x0010 shadow mode
//   0x0014 shadow gamma_mode
//   0x0018 shadow gamma_lut_id
//   0x001C RO last cfg error
//   0x0040..0x004C fx, fy, cx, cy           S32/F16
//   0x0050..0x0060 k1, k2, p1, p2, k3       S32/F28
//   0x0080..0x00A0 M 3x3, row major         S32/F26
//   0x00A4 epsilon                          U32/F26
//   0x00A8 norm_abs_max                     U32/F26
//   0x0100..0x011C eight RO counters
//
// Shadow / active model
//   A write only changes the shadow. A commit validates the shadow and, if it
//   passes, snapshots it into the pending set and sets pending. The pending set
//   is copied to active atomically at the next job_start, which also increments
//   config_epoch and clears pending. While pending is set, further parameter
//   writes or commits return BUSY. Parameter reads always return the shadow,
//   while 0x000C returns the *active* epoch.
//
// Capability for the basic stage
//   bit0 identity and bit1 k1/k2 are supported. Affine, projective, p1/p2/k3,
//   gamma and auto-gamma are NOT implemented yet, so a commit that asks for any
//   of them returns UNSUPPORTED rather than being silently ignored - the frozen
//   spec is explicit that ignoring an unsupported request is not allowed.
//
// Range checks (RANGE)
//   |k1|,|k2| <= 1.0            keeps the polynomial inside the proven envelope
//   norm_abs_max <= 4.0         bounds the normalised coordinate magnitude
//   fx, fy non-zero, |f| <= 2^15
//   M20 = M21 = 0 and M22 = 1.0 for every mode; mode 1 additionally requires the
//   whole M to be the default K-derived matrix, otherwise RANGE is returned so
//   that mode 1 and mode 2 cannot be confused.
//-----------------------------------------------------------------------------

module dgc_config_manager (
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- configuration bus -------------------------------------
    input  wire        cfg_req_valid,
    output wire        cfg_req_ready,
    input  wire        cfg_req_write,
    input  wire [15:0] cfg_req_addr,
    input  wire [31:0] cfg_req_wdata,
    output wire        cfg_rsp_valid,
    input  wire        cfg_rsp_ready,
    output wire [31:0] cfg_rsp_rdata,
    output wire [7:0]  cfg_rsp_error,

    // ---------------- job control -------------------------------------------
    input  wire        job_start,
    input  wire        job_done,
    output wire        job_active,
    input  wire        fault_set,

    // ---------------- counters (read-only, saturating upstream) -------------
    input  wire [31:0] cnt0_input_frames,
    input  wire [31:0] cnt1_input_dropped,
    input  wire [31:0] cnt2_jobs_completed,
    input  wire [31:0] cnt3_output_frames_ok,
    input  wire [31:0] cnt4_output_underflow,
    input  wire [31:0] cnt5_ddr_protocol_error,
    input  wire [31:0] cnt6_math_error_pixels,
    input  wire [31:0] cnt7_tile_split,

    // ---------------- active configuration to map_pipeline ------------------
    output wire [1:0]  act_mode,
    output wire [31:0] act_fx,
    output wire [31:0] act_fy,
    output wire [31:0] act_cx,
    output wire [31:0] act_cy,
    output wire [31:0] act_k1,
    output wire [31:0] act_k2,
    output wire [31:0] act_m00,
    output wire [31:0] act_m01,
    output wire [31:0] act_m02,
    output wire [31:0] act_m10,
    output wire [31:0] act_m11,
    output wire [31:0] act_m12,
    output wire [31:0] act_m20,
    output wire [31:0] act_m21,
    output wire [31:0] act_m22,
    output wire [31:0] act_norm_abs_max,
    output wire [15:0] act_epoch,
    output wire        pending
);

    // ------------------------------------------------------------- constants
    localparam [31:0] VERSION      = 32'h0001_0000;
    localparam [31:0] CAPABILITY   = 32'h0000_0003;   // bit0 identity, bit1 k1/k2

    localparam [7:0]  E_OK          = 8'd0;
    localparam [7:0]  E_BAD_ADDR    = 8'd1;
    localparam [7:0]  E_UNSUPPORTED = 8'd2;
    localparam [7:0]  E_RANGE       = 8'd3;
    localparam [7:0]  E_BUSY        = 8'd4;
    localparam [7:0]  E_READ_ONLY   = 8'd5;

    // frozen defaults, exactly as 接口常量_v1.json records them
    localparam signed [31:0] D_FX  = 32'sd137377855;
    localparam signed [31:0] D_FY  = 32'sd138692973;
    localparam signed [31:0] D_CX  = 32'sd64030536;
    localparam signed [31:0] D_CY  = 32'sd34085643;
    localparam signed [31:0] D_K1  = -32'sd129279204;
    localparam signed [31:0] D_K2  = 32'sd74679738;
    localparam signed [31:0] D_M00 = 32'sd32014;
    localparam signed [31:0] D_M02 = -32'sd31278815;
    localparam signed [31:0] D_M11 = 32'sd31711;
    localparam signed [31:0] D_M12 = -32'sd16492896;
    localparam        [31:0] D_M22 = 32'sd67108864;   // 1.0 in F26
    localparam        [31:0] D_EPS = 32'd262144;      // 1/256
    localparam        [31:0] D_NRM = 32'd134217728;   // 2.0

    // limit of |k| is 1.0 in F28
    localparam signed [31:0] K_LIMIT = 32'sd268435456;

    // ------------------------------------------------------------- shadow
    reg  [1:0]  sh_mode;
    reg  [1:0]  sh_gamma_mode;
    reg  [1:0]  sh_gamma_lut;
    reg  signed [31:0] sh_fx, sh_fy, sh_cx, sh_cy;
    reg  signed [31:0] sh_k1, sh_k2, sh_p1, sh_p2, sh_k3;
    reg  signed [31:0] sh_m00, sh_m01, sh_m02, sh_m10, sh_m11, sh_m12,
                       sh_m20, sh_m21, sh_m22;
    reg         [31:0] sh_eps, sh_nrm;

    // ------------------------------------------------------- pending / active
    reg  [1:0]  pd_mode;
    reg  signed [31:0] pd_fx, pd_fy, pd_cx, pd_cy, pd_k1, pd_k2;
    reg  signed [31:0] pd_m00, pd_m01, pd_m02, pd_m10, pd_m11, pd_m12,
                       pd_m20, pd_m21, pd_m22;
    reg         [31:0] pd_nrm;

    reg  [1:0]  ac_mode;
    reg  signed [31:0] ac_fx, ac_fy, ac_cx, ac_cy, ac_k1, ac_k2;
    reg  signed [31:0] ac_m00, ac_m01, ac_m02, ac_m10, ac_m11, ac_m12,
                       ac_m20, ac_m21, ac_m22;
    reg         [31:0] ac_nrm;

    reg         pd_valid;
    reg  [15:0] epoch;
    reg         busy_flag;
    reg  [7:0]  last_err;

    assign pending    = pd_valid;
    assign job_active = busy_flag;
    assign act_epoch  = epoch;

    assign act_mode = ac_mode;
    assign act_fx = ac_fx;   assign act_fy = ac_fy;
    assign act_cx = ac_cx;   assign act_cy = ac_cy;
    assign act_k1 = ac_k1;   assign act_k2 = ac_k2;
    assign act_m00 = ac_m00; assign act_m01 = ac_m01; assign act_m02 = ac_m02;
    assign act_m10 = ac_m10; assign act_m11 = ac_m11; assign act_m12 = ac_m12;
    assign act_m20 = ac_m20; assign act_m21 = ac_m21; assign act_m22 = ac_m22;
    assign act_norm_abs_max = ac_nrm;

    // ------------------------------------------------------------- response
    reg         rsp_valid;
    reg  [31:0] rsp_data;
    reg  [7:0]  rsp_err;

    assign cfg_req_ready = ~rsp_valid;
    assign cfg_rsp_valid = rsp_valid;
    assign cfg_rsp_rdata = rsp_data;
    assign cfg_rsp_error = rsp_err;

    // ------------------------------------------------------------ validation
    wire [1:0]  wr_mode = (cfg_req_addr == 16'h0010) ? cfg_req_wdata[1:0] : sh_mode;

    // feature support: basic stage implements identity and k1/k2 only
    wire mode_bad       = (cfg_req_addr == 16'h0010) && (cfg_req_wdata[1:0] > 2'd1);
    wire gamma_mode_bad = (cfg_req_addr == 16'h0014) && (cfg_req_wdata[1:0] != 2'd0);
    wire gamma_lut_bad  = (cfg_req_addr == 16'h0018) && (cfg_req_wdata[31:2] != 30'd0);

    // range checks, evaluated on the value that a write would leave in the shadow
    wire signed [31:0] chk_fx = (cfg_req_addr == 16'h0040) ? cfg_req_wdata : sh_fx;
    wire signed [31:0] chk_fy = (cfg_req_addr == 16'h0044) ? cfg_req_wdata : sh_fy;
    wire signed [31:0] chk_k1 = (cfg_req_addr == 16'h0050) ? cfg_req_wdata : sh_k1;
    wire signed [31:0] chk_k2 = (cfg_req_addr == 16'h0054) ? cfg_req_wdata : sh_k2;
    wire        [31:0] chk_nrm= (cfg_req_addr == 16'h00A8) ? cfg_req_wdata : sh_nrm;

    wire fx_bad  = (chk_fx <= 32'sd0);
    wire fy_bad  = (chk_fy <= 32'sd0);
    wire k1_bad  = (chk_k1 > K_LIMIT) || (chk_k1 < -K_LIMIT);
    wire k2_bad  = (chk_k2 > K_LIMIT) || (chk_k2 < -K_LIMIT);
    wire nrm_bad = (chk_nrm > 32'd268435456);          // 4.0 in F26

    // ------------------------------------------------------------------ write
    wire addr_is_writable =
        (cfg_req_addr == 16'h0010) || (cfg_req_addr == 16'h0014) ||
        (cfg_req_addr == 16'h0018) ||
        (cfg_req_addr >= 16'h0040 && cfg_req_addr <= 16'h004C) ||
        (cfg_req_addr >= 16'h0050 && cfg_req_addr <= 16'h0060) ||
        (cfg_req_addr >= 16'h0080 && cfg_req_addr <= 16'h00A0) ||
        (cfg_req_addr == 16'h00A4) || (cfg_req_addr == 16'h00A8);

    wire addr_is_counter = (cfg_req_addr >= 16'h0100) && (cfg_req_addr <= 16'h011C);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh_mode <= 2'd0; sh_gamma_mode <= 2'd0; sh_gamma_lut <= 2'd0;
            sh_fx <= D_FX; sh_fy <= D_FY; sh_cx <= D_CX; sh_cy <= D_CY;
            sh_k1 <= D_K1; sh_k2 <= D_K2;
            sh_p1 <= 32'sd0; sh_p2 <= 32'sd0; sh_k3 <= 32'sd0;
            sh_m00 <= D_M00; sh_m01 <= 32'sd0; sh_m02 <= D_M02;
            sh_m10 <= 32'sd0; sh_m11 <= D_M11; sh_m12 <= D_M12;
            sh_m20 <= 32'sd0; sh_m21 <= 32'sd0; sh_m22 <= D_M22;
            sh_eps <= D_EPS; sh_nrm <= D_NRM;
        end
        else if (cfg_req_valid && cfg_req_ready && cfg_req_write && addr_is_writable &&
                 !pd_valid && !mode_bad && !gamma_mode_bad && !gamma_lut_bad &&
                 !fx_bad && !fy_bad && !k1_bad && !k2_bad && !nrm_bad) begin
            case (cfg_req_addr)
                16'h0010: sh_mode       <= cfg_req_wdata[1:0];
                16'h0014: sh_gamma_mode <= cfg_req_wdata[1:0];
                16'h0018: sh_gamma_lut  <= cfg_req_wdata[1:0];
                16'h0040: sh_fx <= cfg_req_wdata;
                16'h0044: sh_fy <= cfg_req_wdata;
                16'h0048: sh_cx <= cfg_req_wdata;
                16'h004C: sh_cy <= cfg_req_wdata;
                16'h0050: sh_k1 <= cfg_req_wdata;
                16'h0054: sh_k2 <= cfg_req_wdata;
                16'h0058: sh_p1 <= cfg_req_wdata;
                16'h005C: sh_p2 <= cfg_req_wdata;
                16'h0060: sh_k3 <= cfg_req_wdata;
                16'h0080: sh_m00 <= cfg_req_wdata;
                16'h0084: sh_m01 <= cfg_req_wdata;
                16'h0088: sh_m02 <= cfg_req_wdata;
                16'h008C: sh_m10 <= cfg_req_wdata;
                16'h0090: sh_m11 <= cfg_req_wdata;
                16'h0094: sh_m12 <= cfg_req_wdata;
                16'h0098: sh_m20 <= cfg_req_wdata;
                16'h009C: sh_m21 <= cfg_req_wdata;
                16'h00A0: sh_m22 <= cfg_req_wdata;
                16'h00A4: sh_eps <= cfg_req_wdata;
                16'h00A8: sh_nrm <= cfg_req_wdata;
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------- request decode
    reg  [7:0] req_err_now;

    always @(*) begin
        req_err_now = E_OK;
        if (cfg_req_valid) begin
            if (cfg_req_write) begin
                if (pd_valid)                        req_err_now = E_BUSY;
                else if (!addr_is_writable) begin
                    if (addr_is_counter || cfg_req_addr == 16'h0000 ||
                        cfg_req_addr == 16'h0004 || cfg_req_addr == 16'h0008 ||
                        cfg_req_addr == 16'h000C || cfg_req_addr == 16'h001C)
                        req_err_now = E_READ_ONLY;
                    else
                        req_err_now = E_BAD_ADDR;
                end
                else if (mode_bad || gamma_mode_bad || gamma_lut_bad)
                    req_err_now = E_UNSUPPORTED;
                else if (fx_bad || fy_bad || k1_bad || k2_bad || nrm_bad)
                    req_err_now = E_RANGE;
            end
            else begin
                // reads: unknown address is an error, nothing is BUSY
                if (!(addr_is_writable || addr_is_counter ||
                      cfg_req_addr == 16'h0000 || cfg_req_addr == 16'h0004 ||
                      cfg_req_addr == 16'h0008 || cfg_req_addr == 16'h000C ||
                      cfg_req_addr == 16'h001C))
                    req_err_now = E_BAD_ADDR;
            end
        end
    end

    // ------------------------------------------------------- commit validation
    // The pending snapshot is taken from the shadow, so validate the shadow.
    wire commit_p1 = (sh_p1 != 32'sd0) || (sh_p2 != 32'sd0) || (sh_k3 != 32'sd0);
    wire commit_gamma_bad = (sh_gamma_mode != 2'd0);
    wire m_tail_bad = (sh_m20 != 32'sd0) || (sh_m21 != 32'sd0) || (sh_m22 != D_M22);

    // mode 1 must use the default K-derived matrix; mode 2 uses the submitted one
    wire m_is_default = (sh_m00 == D_M00) && (sh_m01 == 32'sd0) && (sh_m02 == D_M02) &&
                        (sh_m10 == 32'sd0) && (sh_m11 == D_M11) && (sh_m12 == D_M12);

    wire fx_bad_commit = (sh_fx <= 32'sd0);
    wire fy_bad_commit = (sh_fy <= 32'sd0);
    wire k1_bad_commit = (sh_k1 > K_LIMIT) || (sh_k1 < -K_LIMIT);
    wire k2_bad_commit = (sh_k2 > K_LIMIT) || (sh_k2 < -K_LIMIT);
    wire nrm_bad_commit = (sh_nrm > 32'd268435456);

    wire commit_range_bad = fx_bad_commit || fy_bad_commit || k1_bad_commit ||
                            k2_bad_commit || nrm_bad_commit;

    reg  [7:0] commit_err;

    always @(*) begin
        commit_err = E_OK;
        if (sh_mode > 2'd1)                       commit_err = E_UNSUPPORTED;
        else if (commit_gamma_bad || commit_p1)   commit_err = E_UNSUPPORTED;
        else if (commit_range_bad)                commit_err = E_RANGE;
        else if (m_tail_bad)                      commit_err = E_RANGE;
        else if ((sh_mode == 2'd1) && !m_is_default) commit_err = E_RANGE;
    end

    // ----------------------------------------------------------- rsp / snapshot
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_valid   <= 1'b0;
            rsp_data    <= 32'd0;
            rsp_err     <= 8'd0;
            last_err    <= 8'd0;
            pd_valid    <= 1'b0;
            epoch       <= 16'd0;
            busy_flag   <= 1'b0;
            pd_mode     <= 2'd0;
            pd_fx <= D_FX; pd_fy <= D_FY; pd_cx <= D_CX; pd_cy <= D_CY;
            pd_k1 <= D_K1; pd_k2 <= D_K2;
            pd_m00 <= D_M00; pd_m01 <= 32'sd0; pd_m02 <= D_M02;
            pd_m10 <= 32'sd0; pd_m11 <= D_M11; pd_m12 <= D_M12;
            pd_m20 <= 32'sd0; pd_m21 <= 32'sd0; pd_m22 <= D_M22;
            pd_nrm <= D_NRM;
            ac_mode <= 2'd0;
            ac_fx <= D_FX; ac_fy <= D_FY; ac_cx <= D_CX; ac_cy <= D_CY;
            ac_k1 <= D_K1; ac_k2 <= D_K2;
            ac_m00 <= D_M00; ac_m01 <= 32'sd0; ac_m02 <= D_M02;
            ac_m10 <= 32'sd0; ac_m11 <= D_M11; ac_m12 <= D_M12;
            ac_m20 <= 32'sd0; ac_m21 <= 32'sd0; ac_m22 <= D_M22;
            ac_nrm <= D_NRM;
        end
        else begin
            // response channel
            if (rsp_valid && cfg_rsp_ready)
                rsp_valid <= 1'b0;

            if (cfg_req_valid && cfg_req_ready && !rsp_valid) begin
                rsp_valid <= 1'b1;
                rsp_err   <= req_err_now;
                last_err  <= (req_err_now == E_OK) ? last_err : req_err_now;

                // read data
                if (!cfg_req_write) begin
                    case (cfg_req_addr)
                        16'h0000: rsp_data <= VERSION;
                        16'h0004: rsp_data <= CAPABILITY;
                        16'h0008: rsp_data <= {29'd0, fault_set, busy_flag, pd_valid};
                        16'h000C: rsp_data <= {16'd0, epoch};
                        16'h0010: rsp_data <= {30'd0, sh_mode};
                        16'h0014: rsp_data <= {30'd0, sh_gamma_mode};
                        16'h0018: rsp_data <= {30'd0, sh_gamma_lut};
                        16'h001C: rsp_data <= {24'd0, last_err};
                        16'h0040: rsp_data <= sh_fx;
                        16'h0044: rsp_data <= sh_fy;
                        16'h0048: rsp_data <= sh_cx;
                        16'h004C: rsp_data <= sh_cy;
                        16'h0050: rsp_data <= sh_k1;
                        16'h0054: rsp_data <= sh_k2;
                        16'h0058: rsp_data <= sh_p1;
                        16'h005C: rsp_data <= sh_p2;
                        16'h0060: rsp_data <= sh_k3;
                        16'h0080: rsp_data <= sh_m00;
                        16'h0084: rsp_data <= sh_m01;
                        16'h0088: rsp_data <= sh_m02;
                        16'h008C: rsp_data <= sh_m10;
                        16'h0090: rsp_data <= sh_m11;
                        16'h0094: rsp_data <= sh_m12;
                        16'h0098: rsp_data <= sh_m20;
                        16'h009C: rsp_data <= sh_m21;
                        16'h00A0: rsp_data <= sh_m22;
                        16'h00A4: rsp_data <= sh_eps;
                        16'h00A8: rsp_data <= sh_nrm;
                        16'h0100: rsp_data <= cnt0_input_frames;
                        16'h0104: rsp_data <= cnt1_input_dropped;
                        16'h0108: rsp_data <= cnt2_jobs_completed;
                        16'h010C: rsp_data <= cnt3_output_frames_ok;
                        16'h0110: rsp_data <= cnt4_output_underflow;
                        16'h0114: rsp_data <= cnt5_ddr_protocol_error;
                        16'h0118: rsp_data <= cnt6_math_error_pixels;
                        16'h011C: rsp_data <= cnt7_tile_split;
                        default:  rsp_data <= 32'd0;
                    endcase
                end
                else begin
                    // commit is a write of 1 to 0x000C
                    if (cfg_req_addr == 16'h000C) begin
                        if (pd_valid || commit_err != E_OK) begin
                            rsp_err  <= (pd_valid ? E_BUSY : commit_err);
                            last_err <= (pd_valid ? E_BUSY : commit_err);
                        end
                        else begin
                            rsp_err  <= E_OK;      // commit accepted
                            pd_valid <= 1'b1;
                            pd_mode  <= sh_mode;
                            pd_fx <= sh_fx; pd_fy <= sh_fy; pd_cx <= sh_cx; pd_cy <= sh_cy;
                            pd_k1 <= sh_k1; pd_k2 <= sh_k2;
                            pd_m00 <= sh_m00; pd_m01 <= sh_m01; pd_m02 <= sh_m02;
                            pd_m10 <= sh_m10; pd_m11 <= sh_m11; pd_m12 <= sh_m12;
                            pd_m20 <= sh_m20; pd_m21 <= sh_m21; pd_m22 <= sh_m22;
                            pd_nrm <= sh_nrm;
                        end
                    end
                end
            end

            // job lifecycle
            if (job_start) begin
                busy_flag <= 1'b1;
                if (pd_valid) begin
                    ac_mode <= pd_mode;
                    ac_fx <= pd_fx; ac_fy <= pd_fy; ac_cx <= pd_cx; ac_cy <= pd_cy;
                    ac_k1 <= pd_k1; ac_k2 <= pd_k2;
                    ac_m00 <= pd_m00; ac_m01 <= pd_m01; ac_m02 <= pd_m02;
                    ac_m10 <= pd_m10; ac_m11 <= pd_m11; ac_m12 <= pd_m12;
                    ac_m20 <= pd_m20; ac_m21 <= pd_m21; ac_m22 <= pd_m22;
                    ac_nrm <= pd_nrm;
                    pd_valid <= 1'b0;
                    epoch    <= epoch + 16'd1;
                end
            end

            if (job_done || fault_set) busy_flag <= 1'b0;
        end
    end

endmodule
