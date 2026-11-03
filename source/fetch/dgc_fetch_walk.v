//-----------------------------------------------------------------------------
// dgc_fetch_walk.v
//
// Walks the rows of one source block and hands each local row index to
// dgc_fetch_row_plan, which has already been verified exhaustively.
//
// Frozen reference: 接口冻结规范_v1.md section 8. A block is fetched row by row,
// top to bottom, and each row's descriptor is consumed before the next is issued.
//
// Interface note: the descriptor itself is produced by dgc_fetch_row_plan from
// this module's `local_y`. Keeping the walk here and the arithmetic there means
// the counter and the geometry can each be verified on their own.
//
// A block with bbox_h rows produces exactly bbox_h descriptors, the last of which
// carries row_last. A bbox_h of 0 produces nothing.
//-----------------------------------------------------------------------------

module dgc_fetch_walk (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,          // pulse to begin a block
    input  wire [6:0]  bbox_h,

    output reg         row_valid,      // a local row index is available
    input  wire        row_ready,      // the consumer took it
    output reg  [5:0]  local_y,
    output reg         row_last,

    output reg         done,           // pulses when the block has been walked
    output reg  [6:0]  rows_done,
    input  wire        abort           // drop the rest of the block
);

    reg busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_valid <= 1'b0;
            local_y   <= 6'd0;
            row_last  <= 1'b0;
            done      <= 1'b0;
            rows_done <= 7'd0;
            busy      <= 1'b0;
        end
        else begin
            done <= 1'b0;

            if (start) begin
                rows_done <= 7'd0;
                row_valid <= 1'b0;
                busy      <= (bbox_h != 7'd0);
            end
            else if (abort) begin
                busy      <= 1'b0;
                row_valid <= 1'b0;
            end
            else if (busy && !row_valid) begin
                // present the next row
                local_y   <= rows_done[5:0];
                row_last  <= (rows_done == bbox_h - 7'd1);
                row_valid <= 1'b1;
            end
            else if (row_valid && row_ready) begin
                row_valid <= 1'b0;
                rows_done <= rows_done + 7'd1;
                if (rows_done == bbox_h - 7'd1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

endmodule
