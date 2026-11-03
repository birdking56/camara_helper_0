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
module prbs7_8bit
(     
input clk,
input rstn,
input prbs_gen ,
input init_en ,
input [7:0] prbs_din  ,
//input [7:0] din,
output [7:0] dout
);

wire [8:1] Y;
reg  [8:1] X;
wire [8:1] y_comb;
reg  [8:1] latch_y_all;
reg  [8:1] latch_y;
reg  [2:0] insert_er_d;

assign  Y[8] = X[7] ^ X[6] ^ 1 ;
assign  Y[7] = X[6] ^ X[5] ^ 1 ;
assign  Y[6] = X[5] ^ X[4] ^ 1 ;
assign  Y[5] = X[4] ^ X[3] ^ 1 ;
assign  Y[4] = X[3] ^ X[2] ^ 1 ;
assign  Y[3] = X[2] ^ X[1] ^ 1 ;
assign  Y[2] = X[7] ^ X[6] ^ X[1] ;
assign  Y[1] = X[7] ^ X[5]  ;

always @(posedge clk or negedge rstn)
   if (!rstn) begin
      X[8:1]         <= 8'b0;
   end
   else if(init_en )
      X[8:1] <= prbs_din ;
   else if (prbs_gen) begin
      X[8:1]         <= Y; 
   end

assign dout[7:0]  = init_en ? 8'd0 : prbs_gen ? Y :X[8:1];

endmodule
