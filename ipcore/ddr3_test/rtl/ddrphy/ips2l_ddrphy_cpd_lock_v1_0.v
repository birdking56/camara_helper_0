////////////////////////////////////////////////////////////////       
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                          
// ALL RIGHTS REVERVED.                                                
////////////////////////////////////////////////////////////////       
//Description:                                                         
//Author: wxxiao                                                      
//History: v1.0                                                        
//////////////////////////////////////////////////////////////// 
`timescale 1ns/10ps  
module   ips2l_ddrphy_cpd_lock_v1_0 
(
   input               ddrphy_sysclk  ,
   input               ddrphy_rst_n   ,
   input               ddrphy_cpd_up_dnb ,
   output reg          ddrphy_cpd_lock       
  );
 
reg  [3:0]  ddrphy_cpd_up_dnb_d;
wire        up_dn_pls;
reg  [2:0]  up_dn_cnt;
wire        up_dn_and;

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) 
 begin    
     if(!ddrphy_rst_n) 
         ddrphy_cpd_up_dnb_d <= 4'd0;
     else
         ddrphy_cpd_up_dnb_d <= {ddrphy_cpd_up_dnb_d[2:0],ddrphy_cpd_up_dnb};
 end

 assign up_dn_pls = ddrphy_cpd_up_dnb_d[2] ^ ddrphy_cpd_up_dnb_d[3];

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) 
 begin    
     if(!ddrphy_rst_n) 
         up_dn_cnt <= 3'd0;
     else if(up_dn_pls)
         up_dn_cnt <= up_dn_cnt + 3'd1;
     else;
 end

 assign up_dn_and = ddrphy_cpd_up_dnb_d[2] & ddrphy_cpd_up_dnb_d[3];

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) 
 begin    
     if(!ddrphy_rst_n) 
         ddrphy_cpd_lock <= 1'b0;
     else if(up_dn_cnt == 3'b100 && up_dn_and == 1'b0)
         ddrphy_cpd_lock <= 1'b1;
     else;
 end

endmodule   
