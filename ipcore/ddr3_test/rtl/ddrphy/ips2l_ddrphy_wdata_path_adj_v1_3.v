////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_wdata_path_adj_v1_3 #(
    parameter DQ_WIDTH     = 8  //4 or 8
)(                                                
    input                     ddrphy_sysclk    ,
    input                     ddrphy_rst_n    , 
                                              
    input [3:0]               phy_wrdata_en   ,
    input [7:0]               phy_wrdata_mask ,
    input [DQ_WIDTH*8-1:0]    phy_wrdata      ,
    input                     wrlvl_dqs_en    ,
    input                     wrlvl_dqs       ,
                                    
    output [7:0]              adj_wrdq_en     ,
    output [DQ_WIDTH*8-1:0]   adj_wrdq        ,
    output [7:0]              adj_wrdqs_en    ,
    output [7:0]              adj_wrdqs       ,
    output [7:0]              adj_wrdata_mask 
   );

  reg [3:0]            phy_wrdata_en_r     ;
  reg [7:0]            phy_wrdata_mask_r   ;
  reg [DQ_WIDTH*8-1:0] phy_wrdata_r        ;
  wire [7:0]           phy_wrdata_en_slip1 ; 
  wire [7:0]           phy_wrdata_en_slip2 ;
  wire [7:0]           w_adj_wrdq_en       ; 
  wire [7:0]           w_adj_wrdqs_en      ;

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)    
      if(~ddrphy_rst_n) begin                                                
          phy_wrdata_en_r    <= 4'b0  ;
          phy_wrdata_mask_r  <= 8'h0  ;
          phy_wrdata_r       <= {DQ_WIDTH*8{1'b0}};
      end                                                   
      else begin      
          phy_wrdata_en_r      <= phy_wrdata_en   ;  
          phy_wrdata_mask_r    <= phy_wrdata_mask ;  
          phy_wrdata_r         <= phy_wrdata      ;                                                
      end                                                   

// oe 1 bit == dq 2 bits
  assign phy_wrdata_en_slip1 = {phy_wrdata_en[3],phy_wrdata_en[2],phy_wrdata_en[2],phy_wrdata_en[1],phy_wrdata_en[1],phy_wrdata_en[0],phy_wrdata_en[0],phy_wrdata_en_r[3]};
  assign phy_wrdata_en_slip2 = {phy_wrdata_en[2],phy_wrdata_en[2],phy_wrdata_en[1],phy_wrdata_en[1],phy_wrdata_en[0],phy_wrdata_en[0],phy_wrdata_en_r[3],phy_wrdata_en_r[3]};

//xuhao
  wire [7:0] w_phy_wrdata_en;
//  wire [7:0] w_adj_wrdq_en_270 ; 
  wire [7:0] w_adj_wrdq_en_90 ; 
//  wire [7:0] w_adj_wrdqs_en_270;
  wire [7:0] w_adj_wrdqs_en_90;
//  wire [7:0] adj_wrdq_en_270 ;
  wire [7:0] adj_wrdq_en_90 ;
// wire [7:0] adj_wrdqs_en_270;
  wire [7:0] adj_wrdqs_en_90;
//  wire [7:0] adj_wrdata_mask_270;
  wire [7:0] adj_wrdata_mask_90;
//  wire [DQ_WIDTH*8-1:0] adj_wrdq_270;
  wire [DQ_WIDTH*8-1:0] adj_wrdq_90;
//  wire [7:0]  adj_wrdqs_270;  
  wire [7:0]  adj_wrdqs_90;


  assign w_phy_wrdata_en = {phy_wrdata_en[3],phy_wrdata_en[3],phy_wrdata_en[2],phy_wrdata_en[2],phy_wrdata_en[1],phy_wrdata_en[1],phy_wrdata_en[0],phy_wrdata_en[0]};
//270wclk
//dq
//  //oe
//  assign w_adj_wrdq_en_270   = w_phy_wrdata_en;
//  assign adj_wrdq_en_270     = ~w_adj_wrdq_en_270;
//  //data
//  assign adj_wrdq_270        = phy_wrdata;                           
//  assign adj_wrdata_mask_270 = phy_wrdata_mask;
//
////dqs
//  //oe
//  assign w_adj_wrdqs_en_270 = wrlvl_dqs_en ? 8'b11111111 : (w_phy_wrdata_en | phy_wrdata_en_slip2);
//  assign adj_wrdqs_en_270 = ~w_adj_wrdqs_en_270;
//  //data
////  reg [3:0] wrdqs_tmp;    
//  assign adj_wrdqs_270 =  wrlvl_dqs_en ? {7'b0, wrlvl_dqs} : 8'b01010101;


//90wclk
//dq
  assign w_adj_wrdq_en_90   = phy_wrdata_en_slip1;
  assign adj_wrdq_en_90     = ~w_adj_wrdq_en_90;
  assign adj_wrdq_90        = dq_slip_1bit(phy_wrdata, phy_wrdata_r) ;                           
  assign adj_wrdata_mask_90 = dm_slip_1bit(phy_wrdata_mask, phy_wrdata_mask_r);
//dqs
  assign w_adj_wrdqs_en_90 = wrlvl_dqs_en ? 8'b11111111 : (w_phy_wrdata_en | phy_wrdata_en_slip2);
  assign adj_wrdqs_en_90 = ~w_adj_wrdqs_en_90;
 assign adj_wrdqs_90 =  wrlvl_dqs_en ? {7'b0, wrlvl_dqs} : 8'b01010101;  

// sel_wclk_del
//  assign adj_wrdq_en     =  WCLK_DEL_SEL ? adj_wrdq_en_90     : adj_wrdq_en_270    ;
//  assign adj_wrdq        =  WCLK_DEL_SEL ? adj_wrdq_90        : adj_wrdq_270       ;
//  assign adj_wrdata_mask =  WCLK_DEL_SEL ? adj_wrdata_mask_90 : adj_wrdata_mask_270;
//  assign adj_wrdqs_en    =  WCLK_DEL_SEL ? adj_wrdqs_en_90    : adj_wrdqs_en_270   ;
//  assign adj_wrdqs       =  WCLK_DEL_SEL ? adj_wrdqs_90       : adj_wrdqs_270      ;

  assign adj_wrdq_en     =  adj_wrdq_en_90     ;
  assign adj_wrdq        =  adj_wrdq_90        ;
  assign adj_wrdata_mask =  adj_wrdata_mask_90 ;
  assign adj_wrdqs_en    =  adj_wrdqs_en_90    ;
  assign adj_wrdqs       =  adj_wrdqs_90       ;

    function [DQ_WIDTH*8-1:0] dq_slip_1bit;
        input [DQ_WIDTH*8-1:0]    write_data;
        input [DQ_WIDTH*8-1:0]    write_data_d1;
        integer i,j;
        
        for(i=0; i<=DQ_WIDTH-1; i=i+1) begin
            dq_slip_1bit[i*8+0]=write_data_d1[i*8+7];    
            for(j=1;j<=7;j=j+1)
                dq_slip_1bit[i*8+j]=write_data[i*8+j-1];
        end
            
    endfunction
    
    //function [DQ_WIDTH*8-1:0] dq_slip_3bit;
    //    input [DQ_WIDTH*8-1:0]    write_data;
    //    input [DQ_WIDTH*8-1:0]    write_data_d1;
    //    integer i,j;
    //    
    //    for(i=0; i<=DQ_WIDTH-1; i=i+1) begin
    //        dq_slip_3bit[i*8+0]=write_data_d1[i*8+5];    
    //        dq_slip_3bit[i*8+1]=write_data_d1[i*8+6];    
    //        dq_slip_3bit[i*8+2]=write_data_d1[i*8+7];    
    //        for(j=3;j<=7;j=j+1)
    //            dq_slip_3bit[i*8+j]=write_data[i*8+j-3];
    //    end
    //        
    //endfunction

    function [7:0] dm_slip_1bit;
        input [7:0]    write_data_mask;
        input [7:0]    write_data_mask_d1;
        
        dm_slip_1bit = {write_data_mask[6:0], write_data_mask_d1[7]};
            
    endfunction
        
    //function [7:0] dm_slip_3bit;
    //    input [7:0]    write_data_mask;
    //    input [7:0]    write_data_mask_d1;
    //    
    //    dm_slip_3bit = {write_data_mask[4:0], write_data_mask_d1[7:5]};
    //        
    //endfunction
        

endmodule
