//-----------------------------------------------------------------------------
// dgc_mailbox.v
//
// Single-outstanding cross-domain descriptor mailbox using two toggle bits and
// bundled-data payload transfer, as required by the frozen specification
// section 3:
//
//   1. the source latches the whole payload while idle, then flips `req`;
//   2. the destination synchronises `req` through at least two stages and only
//      then captures the payload in its own domain;
//   3. the destination flips `ack` once it accepts the transfer;
//   4. the source holds the payload unchanged until it observes `ack`;
//   5. only the toggle bits are synchronised - the payload bits are NEVER
//      individually double-registered.
//
// Consequently the physical constraint set must place a bundled-data /
// max-delay style constraint on src_data relative to req across the two clock
// domains; `set_false_path` on the payload is wrong and is not used.
//
// Reset rule (frozen specification section 2): both domains must be released by
// the same session reset. If only one side is reset the two toggles disagree and
// the pair would transfer stale data, so the ports are named rst_src_n and
// rst_dst_n to make the coordination explicit at the instantiation site.
//
// Throughput: one descriptor per round trip (request -> ack -> request). That is
// intentional; each mailbox carries a low-rate control channel (DDR row request,
// frame grant/release, stripe publish/release), never pixel data.
//-----------------------------------------------------------------------------

module dgc_mailbox #(
    parameter integer W = 64
) (
    // ---------------- source clock domain -----------------------------------
    input  wire          src_clk,
    input  wire          rst_src_n,
    input  wire          src_valid,
    output wire          src_ready,
    input  wire [W-1:0]  src_data,

    // ---------------- destination clock domain -------------------------------
    input  wire          dst_clk,
    input  wire          rst_dst_n,
    output wire          dst_valid,
    input  wire          dst_ready,
    output wire [W-1:0]  dst_data
);

    // ---------------- source-domain state ------------------------------------
    reg  [W-1:0] payload_q;      // bundled data, stable until acknowledged
    reg          req_tgl_q;      // request toggle
    reg  [1:0]   ack_sync_q;     // acknowledge toggle synchronised into source

    // ---------------- destination-domain state -------------------------------
    reg  [2:0]   req_sync_q;     // 2 synchroniser stages + 1 stable cycle
    reg  [W-1:0] dst_payload_q;
    reg          dst_valid_q;
    reg          ack_tgl_q;      // acknowledge toggle

    // ================================================== source side
    assign src_ready = (req_tgl_q == ack_sync_q[1]);

    always @(posedge src_clk or negedge rst_src_n) begin
        if (!rst_src_n) begin
            payload_q  <= {W{1'b0}};
            req_tgl_q  <= 1'b0;
            ack_sync_q <= 2'b00;
        end
        else begin
            ack_sync_q <= {ack_sync_q[0], ack_tgl_q};

            if (src_valid && src_ready) begin
                payload_q <= src_data;        // latched before req_tgl_q flips
                req_tgl_q <= ~req_tgl_q;
            end
        end
    end

    // ================================================== destination side
    // req_sync_q[0..1] are the two synchroniser stages; req_sync_q[2] provides
    // one further destination cycle of stability before the payload is captured.
    wire req_event = req_sync_q[2] ^ req_sync_q[1];

    assign dst_valid = dst_valid_q;
    assign dst_data  = dst_payload_q;

    always @(posedge dst_clk or negedge rst_dst_n) begin
        if (!rst_dst_n) begin
            req_sync_q    <= 3'b000;
            dst_payload_q <= {W{1'b0}};
            dst_valid_q   <= 1'b0;
            ack_tgl_q     <= 1'b0;
        end
        else begin
            req_sync_q <= {req_sync_q[1:0], req_tgl_q};

            if (req_event) begin
                // bundled-data capture: payload has been stable for at least two
                // destination cycles when the toggle edge is observed
                dst_payload_q <= payload_q;
                dst_valid_q   <= 1'b1;
            end
            else if (dst_valid_q && dst_ready) begin
                dst_valid_q <= 1'b0;
            end

            if (dst_valid_q && dst_ready)
                ack_tgl_q <= req_sync_q[2];
        end
    end

`ifdef DGC_SIM
    // The bundled-data contract forbids the payload moving while a request is
    // still outstanding. Assert that it only ever changes on an accepted request.
    // payload_q is updated by a non-blocking assignment in the source block, so
    // at a given edge the value read here is still the pre-edge one. A fire at
    // edge N therefore becomes visible here at edge N+1, which is why the fire
    // condition is registered one cycle before it is used.
    reg [W-1:0] payload_prev;
    reg         fire_d;
    initial begin
        payload_prev = {W{1'b0}};
        fire_d       = 1'b0;
    end
    always @(posedge src_clk) begin
        if (!rst_src_n) begin
            payload_prev <= {W{1'b0}};
            fire_d       <= 1'b0;
        end
        else begin
            if ((payload_q !== payload_prev) && !fire_d)
                $display("DGC_ERROR: dgc_mailbox payload moved outside an accepted request t=%0t", $time);
            payload_prev <= payload_q;
            fire_d       <= (src_valid && src_ready);
        end
    end
`endif

endmodule
