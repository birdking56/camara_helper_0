////////////////////////////////////////////////////////////////       
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                          
// ALL RIGHTS REVERVED.                                                
////////////////////////////////////////////////////////////////       
//Description:                                                         
//Author: wxxiao                                                      
//History: v1.0                                                        
//////////////////////////////////////////////////////////////// 
`timescale 1ns/10ps  
module   ips2l_ddrphy_gpll_phase_v1_0 
(
   input               gpll_dps_clk  ,
   input               ddr_rst_n     ,
   input               gpll_dps_done ,
   input               gpll_dps_dir  ,
   output reg [8:0]    gpll_dps_phase       
  );
 
reg  [2:0]  gpll_dps_done_d;
reg         gpll_dps_done_pos;

 always @(posedge gpll_dps_clk or negedge ddr_rst_n) 
 begin    
     if(!ddr_rst_n) 
     begin
         gpll_dps_done_d   <= 3'b0;
         gpll_dps_done_pos <= 1'b0;
     end
     else
     begin
         gpll_dps_done_d   <= {gpll_dps_done_d[1:0],gpll_dps_done};
         gpll_dps_done_pos <= ~gpll_dps_done_d[2] & gpll_dps_done_d[1];
     end
 end
 
 always @(posedge gpll_dps_clk or negedge ddr_rst_n) 
 begin    
     if(!ddr_rst_n) 
         gpll_dps_phase <= 9'd0;
     else if(gpll_dps_done_pos) 
         if(gpll_dps_dir)
             gpll_dps_phase <= gpll_dps_phase - 9'd1;
         else
             gpll_dps_phase <= gpll_dps_phase + 9'd1;
     else;
 end

endmodule   
