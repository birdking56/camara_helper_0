//////////////////////////////////////////////////////////////////////////////
//
// Copyright [c] 2016 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROPRIETARY TO PANGO MICROSYSTEMS, INC.
// IT SHALL NOT BE REPRODUCED OR DISCLOSED IN WHOLE OR IN PART OR USED BY
// PARTIES WITHOUT WRITTEN AUTHORIZATION FROM THE OWNER.
//
//////////////////////////////////////////////////////////////////////////////
module prbs7_28bit #(
    parameter PRBS_INIT = 21'b0,
    parameter PRBS_GEN_EN = 1'b0
)(
input clk,
input rstn,
input clk_en,

input cnt_mode,
input [20:0] din,
output [20:0] dout,
input insert_er,
output reg error
);

wire [21:1] Y;
wire [21:1] X;
wire [21:1] y_comb;
reg  [21:1] latch_y_all;
reg  [21:1] latch_y;
reg  [2:0] insert_er_d;


assign Y[21] = X[7] ^ X[6] ^ 1 ;
assign Y[20] = X[6] ^ X[5] ^ 1 ;
assign Y[19] = X[5] ^ X[4] ^ 1 ;
assign Y[18] = X[4] ^ X[3] ^ 1 ;
assign Y[17] = X[3] ^ X[2] ^ 1 ;
assign Y[16] = X[2] ^ X[1] ^ 1 ;
assign Y[15] = X[7] ^ X[6] ^ X[1] ^ 0 ;
assign Y[14] = X[7] ^ X[5] ^ 1 ;
assign Y[13] = X[6] ^ X[4] ^ 1 ;
assign Y[12] = X[5] ^ X[3] ^ 1 ;
assign Y[11] = X[4] ^ X[2] ^ 1 ;
assign Y[10] = X[3] ^ X[1] ^ 1 ;
assign Y[9] = X[7] ^ X[6] ^ X[2] ^ 0 ;
assign Y[8] = X[6] ^ X[5] ^ X[1] ^ 0 ;
assign Y[7] = X[7] ^ X[6] ^ X[5] ^ X[4] ^ 1 ;
assign Y[6] = X[6] ^ X[5] ^ X[4] ^ X[3] ^ 1 ;
assign Y[5] = X[5] ^ X[4] ^ X[3] ^ X[2] ^ 1 ;
assign Y[4] = X[4] ^ X[3] ^ X[2] ^ X[1] ^ 1 ;
assign Y[3] = X[7] ^ X[6] ^ X[3] ^ X[2] ^ X[1] ^ 0 ;
assign Y[2] = X[7] ^ X[5] ^ X[2] ^ X[1] ^ 1 ;
assign Y[1] = X[7] ^ X[4] ^ X[1] ^ 0 ;
//assign Y[7] = X[7] ^ X[3] ^ 1 ;
//assign Y[6] = X[6] ^ X[2] ^ 1 ;
//assign Y[5] = X[5] ^ X[1] ^ 1 ;
//assign Y[4] = X[7] ^ X[6] ^ X[4] ^ 0 ;
//assign Y[3] = X[6] ^ X[5] ^ X[3] ^ 0 ;
//assign Y[2] = X[5] ^ X[4] ^ X[2] ^ 0 ;
//assign Y[1] = X[4] ^ X[3] ^ X[1] ^ 0 ;


assign y_comb[21:1] = cnt_mode ? (latch_y + 21'b1) : (PRBS_GEN_EN ? Y[21:1] : din[20:0]);

always @(posedge clk or negedge rstn)
   if (!rstn) begin
      latch_y         <= PRBS_INIT;
      latch_y_all     <= PRBS_INIT;
   end
   else if (clk_en) begin
      latch_y         <= y_comb; 
      latch_y_all     <= Y;
   end
   
always @(posedge clk or negedge rstn)
   if (!rstn) begin
      insert_er_d       <= 3'b0;
      error            <= 1'b0;
   end
   else if (clk_en) begin
      insert_er_d       <= {insert_er_d[1:0], insert_er};
      error            <= latch_y_all != latch_y; //for cfg_prbs_mode 1~6
   end

assign X = latch_y;

assign dout[20:1]  = X[21:2];

assign dout[0] = (insert_er_d[2] ^ insert_er_d[1]) ? (~X[1]) : X[1];

endmodule
