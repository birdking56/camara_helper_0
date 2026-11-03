////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
//////////////////////////////////////////////////////////////
//Decription:
//Author: wxxiao
//Hitory: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module  ips2l_ddrphy_control_path_adj_v1_0 #(
  parameter [1:0] DDR_TYPE      = 2'b00,
  parameter MEM_ADDR_WIDTH      = 16   ,
  parameter MEM_BANKADDR_WIDTH  = 3    ,
  parameter SLIP_BIT_NUM        = 2
)(
    input         ddrphy_sysclk  ,
    input         ddrphy_rst_n  ,

    input [3:0]   phy_cke       ,
    input [3:0]   phy_cs_n      ,
    input [3:0]   phy_ras_n     ,
    input [3:0]   phy_cas_n     ,
    input [3:0]   phy_we_n      ,
    input [4*MEM_ADDR_WIDTH-1:0]       phy_addr      ,
    input [4*MEM_BANKADDR_WIDTH-1:0]   phy_ba        ,
    input [3:0]   phy_odt       ,
    input [3:0]   phy_ck        ,

    output [7:0]  adj_cke       ,
    output [7:0]  adj_cs_n      ,
    output [7:0]  adj_ras_n     ,
    output [7:0]  adj_cas_n     ,
    output [7:0]  adj_we_n      ,
    output [8*MEM_ADDR_WIDTH-1:0]     adj_addr      ,
    output [8*MEM_BANKADDR_WIDTH-1:0] adj_ba        ,
    output [7:0]  adj_odt       ,
    output [7:0]  adj_ck        
  );
  reg [3:0]  phy_cke_r  ;
  reg [3:0]  phy_cs_n_r ;
  reg [3:0]  phy_ras_n_r;
  reg [3:0]  phy_cas_n_r;
  reg [3:0]  phy_we_n_r ;
  reg [4*MEM_ADDR_WIDTH-1:0]      phy_addr_r ;
  reg [4*MEM_BANKADDR_WIDTH-1:0]  phy_ba_r   ;
  reg [3:0]  phy_odt_r  ;

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) begin
        if(DDR_TYPE == 2'b10)
        phy_cke_r      <= 4'b1111  ;
        else
        phy_cke_r      <= 4'b0000  ;
        phy_cs_n_r     <= 4'b1111  ;
        phy_ras_n_r    <= 4'b1111  ;
        phy_cas_n_r    <= 4'b1111  ;
        phy_we_n_r     <= 4'b1111  ;
        phy_addr_r     <= {4*MEM_ADDR_WIDTH{1'b0}};
        phy_ba_r       <= {4*MEM_BANKADDR_WIDTH{1'b0}};
        phy_odt_r      <= 4'b0  ;
     end
     else begin
        phy_cke_r      <= phy_cke  ;
        phy_cs_n_r     <= phy_cs_n  ;
        phy_ras_n_r    <= phy_ras_n ;
        phy_cas_n_r    <= phy_cas_n ;
        phy_we_n_r     <= phy_we_n ;
        phy_addr_r     <= phy_addr ;
        phy_ba_r       <= phy_ba   ;
        phy_odt_r      <= phy_odt  ;
     end
  end

  assign adj_cke   = (SLIP_BIT_NUM == 2) ? slip_2bit(phy_cke  ,phy_cke_r  ):slip_1bit(phy_cke ,phy_cke_r );
  assign adj_cs_n  = (SLIP_BIT_NUM == 2) ? slip_2bit(phy_cs_n ,phy_cs_n_r ):slip_1bit(phy_cs_n,phy_cs_n_r );
  assign adj_ras_n = (SLIP_BIT_NUM == 2) ? slip_2bit(phy_ras_n,phy_ras_n_r):slip_1bit(phy_ras_n,phy_ras_n_r);
  assign adj_cas_n = (SLIP_BIT_NUM == 2) ? slip_2bit(phy_cas_n,phy_cas_n_r):slip_1bit(phy_cas_n,phy_cas_n_r);
  assign adj_we_n  = (SLIP_BIT_NUM == 2) ? slip_2bit(phy_we_n ,phy_we_n_r ):slip_1bit(phy_we_n, phy_we_n_r);
  assign adj_odt   = (SLIP_BIT_NUM == 2) ? slip_2bit(phy_odt  ,phy_odt_r  ):slip_1bit(phy_odt, phy_odt_r );
  assign adj_ck    = {phy_ck,phy_ck};

genvar gen_j;
generate
   for(gen_j=0; gen_j<MEM_BANKADDR_WIDTH; gen_j=gen_j+1) begin : mem_baddr
      assign adj_ba[gen_j*8+7:gen_j*8] = (SLIP_BIT_NUM == 2) ? slip_2bit(phy_ba[gen_j*4+3:gen_j*4], phy_ba_r[gen_j*4+3:gen_j*4]) : 
                                                                slip_1bit(phy_ba[gen_j*4+3:gen_j*4], phy_ba_r[gen_j*4+3:gen_j*4]); 
   end
endgenerate

genvar gen_k;
generate
   for(gen_k=0; gen_k<MEM_ADDR_WIDTH; gen_k=gen_k+1) begin : mem_addr
      assign adj_addr[gen_k*8+7:gen_k*8] = (SLIP_BIT_NUM == 2) ? slip_2bit(phy_addr[gen_k*4+3:gen_k*4], phy_addr_r[gen_k*4+3:gen_k*4]) : 
                                                               slip_1bit(phy_addr[gen_k*4+3:gen_k*4], phy_addr_r[gen_k*4+3:gen_k*4]); 
   end
endgenerate

//********************************************************************************************
    function [7:0] slip_1bit; //slip 0.5bit actually
        input [4-1:0]    data;
        input [4-1:0]    data_d;
        
        slip_1bit = {data[3], data[2], data[2], data[1], data[1], data[0], data[0], data_d[3]};
    endfunction
    
    function [7:0] slip_2bit; //slip 1.5bit actually
        input [4-1:0]    data;
        input [4-1:0]    data_d;
        
        slip_2bit = {data[2], data[1], data[1], data[0], data[0], data_d[3], data_d[3], data_d[2]};
    endfunction  


endmodule
