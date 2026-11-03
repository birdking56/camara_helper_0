////////////////////////////////////////////////////////////////          
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                             
// ALL RIGHTS REVERVED.                                                   
////////////////////////////////////////////////////////////////          
//Description:                                                            
//Author:  wxxiao                                                         
//History: v1.0                                                           
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_dfi_v1_3 #(
    parameter [1:0] DDR_TYPE      = 2'b00 ,  //2'b00:DDR3  2'b01:DDR2  2'b10:LPDDR 
    parameter MEM_ADDR_WIDTH      = 16    ,
    parameter MEM_BANKADDR_WIDTH  = 3     ,
    parameter MEM_DQ_WIDTH        = 16,
    parameter MEM_DQS_WIDTH       = 2,  
    parameter MEM_DM_WIDTH        = 2           
)(
   input                             ddrphy_sysclk        ,
   input                             ddrphy_rst_n         ,
   input                             calib_done           ,
   input                             calib_rst            ,
   input [MEM_BANKADDR_WIDTH-1:0]    calib_ba             ,
   input [MEM_ADDR_WIDTH-1:0]        calib_address        ,
   input                             calib_cs_n           ,
   input                             calib_ras_n          ,
   input                             calib_cas_n          ,
   input                             calib_we_n           ,
   input                             calib_cke            ,
   input                             calib_odt            ,
   input [3:0]                       calib_wrdata_en      ,
   input [8*MEM_DQ_WIDTH-1:0]        calib_wrdata         ,
   input [8*MEM_DM_WIDTH-1:0]        calib_wrdata_mask    ,
   input                             read_valid           ,
   input [8*MEM_DQ_WIDTH-1:0]        o_read_data          ,
   
   input                             ddrphy_update        ,
//   input [1:0]                       update_type          ,
   output reg                        update_cal_req       ,
   input                             update_done          ,
   output reg                        ddrphy_update_done   ,
   input [4*MEM_ADDR_WIDTH-1:0]      dfi_address          ,
   input [4*MEM_BANKADDR_WIDTH-1:0]  dfi_bank             ,
   input [3:0]                       dfi_cs_n             ,
   input [3:0]                       dfi_cas_n            ,
   input [3:0]                       dfi_ras_n            ,
   input [3:0]                       dfi_we_n             ,
   input [3:0]                       dfi_cke              ,
   input [3:0]                       dfi_odt              ,
   input [3:0]                       dfi_wrdata_en        ,
   input [8*MEM_DQ_WIDTH-1:0]        dfi_wrdata           ,
   input [8*MEM_DM_WIDTH-1:0]        dfi_wrdata_mask      ,
   output[8*MEM_DQ_WIDTH-1:0]        dfi_rddata           ,
   output                            dfi_rddata_valid     ,
   input                             dfi_reset_n          ,
//   input                             dfi_ctrlupd_req      ,
//   output reg                        dfi_ctrlupd_ack      ,
   output reg                        dfi_phyupd_req       ,
   input                             dfi_phyupd_ack       ,
   output reg                        dfi_init_complete    ,
   output reg                        dfi_refresh          ,

   output [3:0]                       read_cmd             ,
   output reg [3:0]                   phy_ck               ,
   output                             phy_rst              ,
   output  [4*MEM_ADDR_WIDTH-1:0]     phy_addr             ,
   output  [4*MEM_BANKADDR_WIDTH-1:0] phy_ba               ,
   output  [3:0]                      phy_cs_n             ,
   output  [3:0]                      phy_ras_n            ,
   output  [3:0]                      phy_cas_n            ,
   output  [3:0]                      phy_we_n             ,
   output  [3:0]                      phy_cke              ,
   output  [3:0]                      phy_odt              ,
   output  [3:0]                      phy_wrdata_en        ,
   output  [8*MEM_DQ_WIDTH-1:0]       phy_wrdata           ,
   output  [8*MEM_DM_WIDTH-1:0]       phy_wrdata_mask       
  );

reg [4*MEM_ADDR_WIDTH-1:0]     phy_addr_d             ;
reg [4*MEM_BANKADDR_WIDTH-1:0] phy_ba_d               ;
reg [3:0]                      phy_cs_n_d             ;
reg [3:0]                      phy_ras_n_d            ;
reg [3:0]                      phy_cas_n_d            ;
reg [3:0]                      phy_we_n_d             ;
reg [3:0]                      phy_cke_d              ;
reg [3:0]                      phy_odt_d              ;
reg [3:0]                      phy_wrdata_en_d        ;
reg [8*MEM_DQ_WIDTH-1:0]       phy_wrdata_d           ;
reg [8*MEM_DM_WIDTH-1:0]       phy_wrdata_mask_d      ;
reg [4*MEM_ADDR_WIDTH-1:0]     phy_addr_d1             ;
reg [4*MEM_BANKADDR_WIDTH-1:0] phy_ba_d1               ;
reg [3:0]                      phy_cs_n_d1             ;
reg [3:0]                      phy_ras_n_d1            ;
reg [3:0]                      phy_cas_n_d1            ;
reg [3:0]                      phy_we_n_d1             ;
reg [3:0]                      phy_cke_d1              ;
reg [3:0]                      phy_odt_d1              ;
reg [3:0]                      phy_wrdata_en_d1        ;
reg [8*MEM_DQ_WIDTH-1:0]       phy_wrdata_d1           ;
reg [8*MEM_DM_WIDTH-1:0]       phy_wrdata_mask_d1      ;

wire [3:0]                       w_phy_cs_n       ;
wire [3:0]                       w_phy_ras_n      ;
wire [3:0]                       w_phy_cas_n      ;
wire [3:0]                       w_phy_we_n       ;
wire [3:0]                       w_phy_cke        ;
wire [3:0]                       w_phy_odt        ;
wire [4*MEM_ADDR_WIDTH-1:0]      w_phy_addr       ;
wire [4*MEM_BANKADDR_WIDTH-1:0]  w_phy_ba         ;
wire [3:0]                       w_phy_wrdata_en  ;
wire [8*MEM_DQ_WIDTH-1:0]        w_phy_wrdata     ;
wire [8*MEM_DM_WIDTH-1:0]        w_phy_wrdata_mask;

reg  [3:0]                     dfi_cke_d           ;
reg  [3:0]                     dfi_refresh_gen     ;
wire                           dfi_refresh_gen_or  ;
reg                            dfi_refresh_gen_or_d1;
reg                            dfi_refresh_gen_or_d2;
reg                            dfi_refresh_gen_or_d3;

reg      calib_done_r;
wire     calib_done_or;

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) 
  begin
      if(!ddrphy_rst_n) 
           calib_done_r <= 1'b0;
      else
           calib_done_r <= calib_done;
  end

assign calib_done_or = calib_done || calib_done_r;

assign  w_phy_cs_n        = calib_done ?  dfi_cs_n    :  {3'b111,calib_cs_n }  ;                                       
assign  w_phy_ras_n       = calib_done ?  dfi_ras_n   :  {3'b111,calib_ras_n} ;                                       
assign  w_phy_cas_n       = calib_done ?  dfi_cas_n   :  {3'b111,calib_cas_n} ;                                       
assign  w_phy_we_n        = calib_done ?  dfi_we_n    :  {3'b111,calib_we_n } ;                                                                              
assign  w_phy_cke         = calib_done_or ? dfi_cke   : {4{calib_cke}};
assign  w_phy_odt         = calib_done ?  dfi_odt     : {4{calib_odt}};                                                                           
assign  w_phy_addr        = calib_done ?  dfi_address : {{(3*MEM_ADDR_WIDTH){1'b0}},calib_address};                                     
assign  w_phy_ba          = calib_done ?  dfi_bank    : {{(3*MEM_BANKADDR_WIDTH){1'b0}},calib_ba};                                                                                                                                                       
assign  w_phy_wrdata_en   = calib_done ? dfi_wrdata_en : calib_wrdata_en ;     
assign  w_phy_wrdata_mask = calib_done ? dfi_wrdata_mask : calib_wrdata_mask ;                                   
assign  w_phy_wrdata      = calib_done ? dfi_wrdata : calib_wrdata;                                              

assign  phy_rst     = calib_done ?  dfi_reset_n   : calib_rst         ; 

assign read_cmd[0] = {{w_phy_cke[0],w_phy_cs_n[0],w_phy_ras_n[0],w_phy_cas_n[0],w_phy_we_n[0]}==5'b10101};
assign read_cmd[1] = {{w_phy_cke[1],w_phy_cs_n[1],w_phy_ras_n[1],w_phy_cas_n[1],w_phy_we_n[1]}==5'b10101};
assign read_cmd[2] = {{w_phy_cke[2],w_phy_cs_n[2],w_phy_ras_n[2],w_phy_cas_n[2],w_phy_we_n[2]}==5'b10101};
assign read_cmd[3] = {{w_phy_cke[3],w_phy_cs_n[3],w_phy_ras_n[3],w_phy_cas_n[3],w_phy_we_n[3]}==5'b10101};

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n) begin
          phy_cs_n_d       <=4'b1111; 
          phy_ras_n_d      <=4'b1111;
          phy_cas_n_d      <=4'b1111;
          phy_we_n_d       <=4'b1111;
          phy_odt_d        <='b0;
          phy_addr_d       <='b0;
          phy_ba_d         <='b0;
          phy_wrdata_en_d  <='b0;
          phy_wrdata_d     <='b0;
          phy_wrdata_mask_d<='b0;
          if(DDR_TYPE == 2'b10)
          phy_cke_d        <=4'b1111;
          else
          phy_cke_d        <=4'b0000;
       end
       else begin
          phy_cs_n_d       <= w_phy_cs_n          ;
          phy_ras_n_d      <= w_phy_ras_n         ;
          phy_cas_n_d      <= w_phy_cas_n         ;
          phy_we_n_d       <= w_phy_we_n          ;
          phy_cke_d        <= w_phy_cke           ;
          phy_odt_d        <= w_phy_odt           ;
          phy_addr_d       <= w_phy_addr          ;
          phy_ba_d         <= w_phy_ba            ;
          phy_wrdata_en_d  <= w_phy_wrdata_en     ;
          phy_wrdata_d     <= w_phy_wrdata        ;
          phy_wrdata_mask_d<= w_phy_wrdata_mask   ;
       end
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n) begin
          phy_cs_n_d1       <=4'b1111; 
          phy_ras_n_d1      <=4'b1111;
          phy_cas_n_d1      <=4'b1111;
          phy_we_n_d1       <=4'b1111;
          phy_odt_d1        <='b0;
          phy_addr_d1       <='b0;
          phy_ba_d1         <='b0;
          phy_wrdata_en_d1  <='b0;
          phy_wrdata_d1     <='b0;
          phy_wrdata_mask_d1<='b0;
          if(DDR_TYPE == 2'b10)
          phy_cke_d1        <=4'b1111;
          else
          phy_cke_d1        <=4'b0000;
       end
       else begin
          phy_cs_n_d1       <= phy_cs_n_d         ;
          phy_ras_n_d1      <= phy_ras_n_d        ;
          phy_cas_n_d1      <= phy_cas_n_d        ;
          phy_we_n_d1       <= phy_we_n_d         ;
          phy_cke_d1        <= phy_cke_d          ;
          phy_odt_d1        <= phy_odt_d          ;
          phy_addr_d1       <= phy_addr_d         ;
          phy_ba_d1         <= phy_ba_d           ;
          phy_wrdata_en_d1  <= phy_wrdata_en_d    ;
          phy_wrdata_d1     <= phy_wrdata_d       ;
          phy_wrdata_mask_d1<= phy_wrdata_mask_d  ;
       end
  end

 assign  phy_cs_n        = (DDR_TYPE == 2'b00) ? phy_cs_n_d        : phy_cs_n_d1        ;
 assign  phy_ras_n       = (DDR_TYPE == 2'b00) ? phy_ras_n_d       : phy_ras_n_d1       ;
 assign  phy_cas_n       = (DDR_TYPE == 2'b00) ? phy_cas_n_d       : phy_cas_n_d1       ;
 assign  phy_we_n        = (DDR_TYPE == 2'b00) ? phy_we_n_d        : phy_we_n_d1        ;
 assign  phy_cke         = (DDR_TYPE == 2'b00) ? phy_cke_d         : phy_cke_d1         ;
 assign  phy_odt         = (DDR_TYPE == 2'b00) ? phy_odt_d         : phy_odt_d1         ;
 assign  phy_addr        = (DDR_TYPE == 2'b00) ? phy_addr_d        : phy_addr_d1        ;
 assign  phy_ba          = (DDR_TYPE == 2'b00) ? phy_ba_d          : phy_ba_d1          ;
 assign  phy_wrdata_en   = (DDR_TYPE == 2'b00) ? phy_wrdata_en_d   : phy_wrdata_en_d1   ;
 assign  phy_wrdata_mask = (DDR_TYPE == 2'b00) ? phy_wrdata_mask_d : phy_wrdata_mask_d1 ;
 assign  phy_wrdata      = (DDR_TYPE == 2'b00) ? phy_wrdata_d      : phy_wrdata_d1      ;

assign  dfi_rddata       =  calib_done ? o_read_data : {(8*MEM_DQ_WIDTH){1'b0}} ; 
assign  dfi_rddata_valid =  calib_done ? read_valid  : 1'b0;
  
///
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)
         dfi_init_complete   <= 1'b0;
     else if(calib_done)   
         dfi_init_complete   <= 1'b1;
  end

  reg [1:0] ddrphy_update_sync ;

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n) 
         ddrphy_update_sync <= 2'b0 ;
      else 
        ddrphy_update_sync  <= {ddrphy_update_sync[0],ddrphy_update};
  end
//
   always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
   begin
     if(!ddrphy_rst_n)  
         dfi_phyupd_req  <= 1'b0;
     else if (update_done | ddrphy_update_done)
         dfi_phyupd_req  <= 1'b0;
//      else if(ddrphy_update_sync[1] & ~dfi_ctrlupd_req) 
     else if(ddrphy_update_sync[1])
         dfi_phyupd_req  <= 1'b1;
   end
//phy update request
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)  
        update_cal_req   <= 1'b0;
     else if (update_done | ddrphy_update_done)
        update_cal_req   <= 1'b0;
 //    else if(dfi_phyupd_ack |dfi_ctrlupd_ack )
     else if(dfi_phyupd_ack)
        update_cal_req   <= 1'b1;
  end
//
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
     if(!ddrphy_rst_n) 
         ddrphy_update_done   <= 1'b0 ;
//     else if(~ddrphy_update_sync[1])
//         ddrphy_update_done   <= 1'b0 ;
//     else if(update_done & ~ dfi_ctrlupd_req)
//     else if(update_done )
     else
         ddrphy_update_done   <= update_done;
 end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)   
          phy_ck   <= 4'b0000;
//     else if (dfi_dram_clk_disable_tmp  & (!dfi_phyupd_req) & (!dfi_ctrlupd_req))
//          phy_ck   <= 4'b0000;
    else 
          phy_ck   <= 4'b0101; 
  end

/////////////////////////////////////////////////////////////////////////////////////

genvar gen_ref;
generate
    for(gen_ref=0; gen_ref<4; gen_ref=gen_ref+1) 
    begin : refresh_cmd
        always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
        begin
            if(!ddrphy_rst_n)   
                dfi_cke_d[gen_ref] <= 1'b0;
            else 
                dfi_cke_d[gen_ref] <= dfi_cke[gen_ref];
        end

        always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
        begin
            if(!ddrphy_rst_n)   
                dfi_refresh_gen[gen_ref] <= 1'b0;
            else if({dfi_cke_d[gen_ref],dfi_cke[gen_ref],dfi_cs_n[gen_ref],dfi_ras_n[gen_ref],dfi_cas_n[gen_ref],dfi_we_n[gen_ref]} == 6'b110001)
                dfi_refresh_gen[gen_ref] <= 1'b1;
            else
                dfi_refresh_gen[gen_ref] <= 1'b0;
        end
    end     
endgenerate

assign dfi_refresh_gen_or = |dfi_refresh_gen; 

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if(!ddrphy_rst_n)   
    begin
        dfi_refresh_gen_or_d1 <= 1'b0;
        dfi_refresh_gen_or_d2 <= 1'b0;
        dfi_refresh_gen_or_d3 <= 1'b0;
    end
    else 
    begin
        dfi_refresh_gen_or_d1 <= dfi_refresh_gen_or;
        dfi_refresh_gen_or_d2 <= dfi_refresh_gen_or_d1;
        dfi_refresh_gen_or_d3 <= dfi_refresh_gen_or_d2;
    end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if(!ddrphy_rst_n)   
        dfi_refresh <= 1'b0;
    else 
        dfi_refresh <= dfi_refresh_gen_or | dfi_refresh_gen_or_d1 | dfi_refresh_gen_or_d2 | dfi_refresh_gen_or_d3;
end

endmodule
