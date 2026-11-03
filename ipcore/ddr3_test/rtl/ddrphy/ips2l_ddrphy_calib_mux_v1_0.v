////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_calib_mux_v1_0 #(
  parameter [1:0] DDR_TYPE      = 2'b00,  //2'b00:DDR3  2'b01:DDR2  2'b10:LPDDR
  parameter MEM_ADDR_WIDTH      = 16,
  parameter MEM_BANKADDR_WIDTH  = 3    
)(
  input        ddrphy_sysclk   ,
  input        ddrphy_rst_n   ,

  input        init_start     ,
  input        wrlvl_start    ,
  input        rdcal_start    ,
  input        wrcal_start    ,
  input        eyecal_start   ,
  input        update_start   , 
     
  input [MEM_BANKADDR_WIDTH-1:0]   init_ba        ,
  input [MEM_ADDR_WIDTH-1:0]       init_address   ,
  input                            init_cs_n      ,
  input                            init_ras_n     ,
  input                            init_cas_n     ,
  input                            init_we_n      ,
  input                            init_cke       ,
  input                            init_odt       ,

  input [MEM_BANKADDR_WIDTH-1:0]   wrlvl_ba       ,
  input [MEM_ADDR_WIDTH-1:0]       wrlvl_address  ,
  input                            wrlvl_cs_n     ,
  input                            wrlvl_ras_n    ,
  input                            wrlvl_cas_n    ,
  input                            wrlvl_we_n     ,
  input                            wrlvl_cke      ,
  input                            wrlvl_odt      ,

  input [MEM_BANKADDR_WIDTH-1:0]   rdcal_ba       ,
  input [MEM_ADDR_WIDTH-1:0]       rdcal_address  ,
  input                            rdcal_cs_n     ,
  input                            rdcal_ras_n    ,
  input                            rdcal_cas_n    ,
  input                            rdcal_we_n     ,
  input                            rdcal_cke      ,
  input                            rdcal_odt      ,

   input [MEM_BANKADDR_WIDTH-1:0]  wrcal_ba       ,
   input [MEM_ADDR_WIDTH-1:0]      wrcal_address  ,
   input                           wrcal_cs_n     ,
   input                           wrcal_ras_n    ,
   input                           wrcal_cas_n    ,
   input                           wrcal_we_n     ,
   input                           wrcal_cke      ,
   input                           wrcal_odt      ,
   
   input [MEM_BANKADDR_WIDTH-1:0]  eyecal_ba      ,
   input [MEM_ADDR_WIDTH-1:0]      eyecal_address ,
   input                           eyecal_cs_n    ,
   input                           eyecal_ras_n   ,
   input                           eyecal_cas_n   ,
   input                           eyecal_we_n    ,
   input                           eyecal_cke     ,
   input                           eyecal_odt     , 
//  input [MEM_BANKADDR_WIDTH-1:0]   upcal_ba       ,
//  input [MEM_ADDR_WIDTH-1:0]       upcal_address  ,
//  input                            upcal_cs_n     ,
//  input                            upcal_ras_n    ,
//  input                            upcal_cas_n    ,
//  input                            upcal_we_n     ,
//  input                            upcal_cke      ,
//  input                            upcal_odt      ,

  output reg [MEM_BANKADDR_WIDTH-1:0] calib_ba        ,
  output reg [MEM_ADDR_WIDTH-1:0]     calib_address   ,
  output reg                       calib_cs_n      ,
  output reg                       calib_ras_n     ,
  output reg                       calib_cas_n     ,
  output reg                       calib_we_n      ,
  output reg                       calib_cke       ,
  output reg                       calib_odt
 );

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
     if(!ddrphy_rst_n)  begin
        calib_ba        <= {MEM_BANKADDR_WIDTH{1'b0}};
        calib_address   <= {MEM_ADDR_WIDTH{1'b0}};
        calib_cs_n      <= 1'b1;
        calib_ras_n     <= 1'b0;
        calib_cas_n     <= 1'b0;
        calib_we_n      <= 1'b0;
        calib_odt       <= 1'b0;
        if(DDR_TYPE == 2'b10)
        calib_cke       <= 1'b1;
        else
        calib_cke       <= 1'b0;
     end
     else begin
         case({init_start,wrlvl_start,rdcal_start,update_start,wrcal_start,eyecal_start})
                  6'b100000: begin                             //init
                             calib_ba       <= init_ba       ;
                             calib_address  <= init_address  ;
                             calib_cs_n     <= init_cs_n     ;
                             calib_ras_n    <= init_ras_n    ;
                             calib_cas_n    <= init_cas_n    ;
                             calib_we_n     <= init_we_n     ;
                             calib_cke      <= init_cke      ;
                             calib_odt      <= init_odt      ;
                           end

                  6'b010000: begin                             //wrlvl
                             calib_ba       <= wrlvl_ba         ;
                             calib_address  <= wrlvl_address    ;
                             calib_cs_n     <= wrlvl_cs_n       ;
                             calib_ras_n    <= wrlvl_ras_n      ;
                             calib_cas_n    <= wrlvl_cas_n      ;
                             calib_we_n     <= wrlvl_we_n       ;
                             calib_cke      <= wrlvl_cke        ;
                             calib_odt      <= wrlvl_odt        ;
                           end

                  6'b001000: begin                            //rdcal
                              calib_ba       <= rdcal_ba        ;
                              calib_address  <= rdcal_address   ;
                              calib_cs_n     <= rdcal_cs_n      ;
                              calib_ras_n    <= rdcal_ras_n     ;
                              calib_cas_n    <= rdcal_cas_n     ;
                              calib_we_n     <= rdcal_we_n      ;
                              calib_cke      <= rdcal_cke       ;
                              calib_odt      <= rdcal_odt       ;
                           end

                   6'b000100:begin                            //update
                               calib_ba        <= {MEM_BANKADDR_WIDTH{1'b0}};
                               calib_address   <= {MEM_ADDR_WIDTH{1'b0}};    
                               calib_cs_n      <= 1'b1; 
                               calib_ras_n     <= 1'b1; 
                               calib_cas_n     <= 1'b1; 
                               calib_we_n      <= 1'b1; 
                               calib_cke       <= 1'b1;     
                               calib_odt       <= 1'b0;
                           end
                           
                   6'b000010: begin                            //wrcal
                              calib_ba       <= wrcal_ba        ;
                              calib_address  <= wrcal_address   ;
                              calib_cs_n     <= wrcal_cs_n      ;
                              calib_ras_n    <= wrcal_ras_n     ;
                              calib_cas_n    <= wrcal_cas_n     ;
                              calib_we_n     <= wrcal_we_n      ;
                              calib_cke      <= wrcal_cke       ;
                              calib_odt      <= wrcal_odt       ;
                           end

                   6'b000001: begin                            //eyecal
                              calib_ba       <= eyecal_ba        ;
                              calib_address  <= eyecal_address   ;
                              calib_cs_n     <= eyecal_cs_n      ;
                              calib_ras_n    <= eyecal_ras_n     ;
                              calib_cas_n    <= eyecal_cas_n     ;
                              calib_we_n     <= eyecal_we_n      ;
                              calib_cke      <= eyecal_cke       ;
                              calib_odt      <= eyecal_odt       ;
                           end

                   default: begin
                               calib_ba        <= {MEM_BANKADDR_WIDTH{1'b0}};
                               calib_address   <= {MEM_ADDR_WIDTH{1'b0}};    
                               calib_cs_n      <= 1'b1; 
                               calib_ras_n     <= 1'b1; 
                               calib_cas_n     <= 1'b1; 
                               calib_we_n      <= 1'b1; 
                               if(DDR_TYPE == 2'b10)
                               calib_cke       <= 1'b1;
                               else
                               calib_cke       <= 1'b0;     
                               calib_odt       <= 1'b0;     
                             end
               endcase
   end

endmodule
