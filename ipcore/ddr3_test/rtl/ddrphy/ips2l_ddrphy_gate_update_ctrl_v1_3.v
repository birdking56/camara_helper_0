////////////////////////////////////////////////////////////////       
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                          
// ALL RIGHTS REVERVED.                                                
////////////////////////////////////////////////////////////////       
//Description:                                                         
//Author: wxxiao                                                      
//History: v1.0                                                        
//////////////////////////////////////////////////////////////// 
`timescale 1ns/10ps  
module ips2l_ddrphy_gate_update_ctrl_v1_3 #(
  parameter        UPDATE_EN           = 1,
  parameter        MEM_DQS_WIDTH       = 2
)(
  input                        ddrphy_sysclk          ,
  input                        ddrphy_rst_n           ,
  input                        calib_done             ,
  input [2*MEM_DQS_WIDTH-1:0]  dqs_drift              ,
  input                        ddrphy_update_done     ,
  output reg                   update_start           ,
  output [2*MEM_DQS_WIDTH-1:0] ddrphy_update_comp_val ,
  output [MEM_DQS_WIDTH-1:0]   ddrphy_update_comp_dir 
);


`ifdef IPS_DDR_SPEEDUP_SIM 
localparam TIME_1S = 32'd1000;
`else                      
localparam TIME_1S = 32'd100000000;
`endif

reg [31:0] gate_update_cnt;
reg ddrphy_update_req;
wire update_flag;

assign update_flag = |ddrphy_update_comp_val;

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if (!ddrphy_rst_n)
   gate_update_cnt <= 32'd0;
   else if(calib_done)
   begin
    if(gate_update_cnt == TIME_1S)
    begin
       if((update_flag == 0)||(ddrphy_update_done))
       gate_update_cnt <= 32'd0;
       else
       gate_update_cnt <= gate_update_cnt;
    end
    else
    gate_update_cnt <= gate_update_cnt + 32'd1;
   end
   else
   gate_update_cnt <= 32'd0;
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if (!ddrphy_rst_n)
   update_start <= 0;
   else if((calib_done)&(UPDATE_EN))
   begin
      if((gate_update_cnt == TIME_1S)&&(update_flag == 1))
      update_start <= 1;
      else
      update_start <= 0;
   end
   else
   update_start <= 0;
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if (!ddrphy_rst_n)
   ddrphy_update_req <= 0;
   else if((calib_done)&(UPDATE_EN))
   begin
      if(gate_update_cnt == TIME_1S - 32'd10)
      ddrphy_update_req <= 1;
      else
      ddrphy_update_req <= 0;
   end
   else
   ddrphy_update_req <= 0;
end


genvar gen_i;                                                             
generate                                                                  
   for(gen_i=0; gen_i<MEM_DQS_WIDTH; gen_i=gen_i+1) begin   : dqift_dqs_group 

   ips2l_ddrphy_drift_ctrl_v1_0 ddrphy_drift_ctrl
   (
     .ddrphy_sysclk           (ddrphy_sysclk           ),
     .ddrphy_rst_n            (ddrphy_rst_n            ),
     .calib_done              (calib_done              ),
     .dqs_drift               (dqs_drift[2*gen_i+1:2*gen_i]),
     .ddrphy_update_req       (ddrphy_update_req       ),
     .ddrphy_update_done      (ddrphy_update_done      ),
     .ddrphy_update_comp_val  (ddrphy_update_comp_val[2*gen_i+1:2*gen_i]),
     .ddrphy_update_comp_dir  (ddrphy_update_comp_dir[gen_i]  )
   );
  end     
endgenerate

endmodule
