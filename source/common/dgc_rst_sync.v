//-----------------------------------------------------------------------------
// dgc_rst_sync.v
//
// Per-domain reset synchroniser: asynchronous assertion, three-stage
// synchronous release, active-low output.
//
// Frozen specification section 2:
//   "新增逻辑统一使用各域同步释放、低有效的 rst_n。异步置位复位、对应域至少
//    三级同步释放。"
//
// The asynchronous input may be a board-level reset, a PLL unlock, or the
// session reset produced by clock_reset. Because assertion is asynchronous the
// output falls in the same simulation delta as the input, so no logic in the
// domain can run a clock edge while the reset source is active.
//-----------------------------------------------------------------------------

module dgc_rst_sync #(
    parameter integer STAGES = 3
) (
    input  wire clk,
    input  wire rst_async_n,     // asynchronous source, active low
    output wire rst_n            // domain reset, active low, synchronous release
);

    reg [STAGES-1:0] sync_q;

    always @(posedge clk or negedge rst_async_n) begin
        if (!rst_async_n)
            sync_q <= {STAGES{1'b0}};
        else
            sync_q <= {sync_q[STAGES-2:0], 1'b1};
    end

    assign rst_n = sync_q[STAGES-1];

endmodule
