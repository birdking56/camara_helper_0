////////////////////////////////////////////////////////////////       
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                          
// ALL RIGHTS REVERVED.                                                
////////////////////////////////////////////////////////////////       
//Description:                                                         
//Author: wxxiao                                                      
//History: v1.0                                                        
//////////////////////////////////////////////////////////////// 
`timescale 1ns/10ps  
module   ips2l_ddrphy_info_v1_0 #(
  parameter [1:0]   DDR_TYPE     = 2'b00    ,  //2'b00:DDR3  2'b01:DDR2  2'b10:LPDDR
  parameter MEM_ADDR_WIDTH       = 16       ,
  parameter MEM_BANKADDR_WIDTH   = 3        ,
  parameter [15:0]  MR0_DDR3     = 16'd0    ,
  parameter [15:0]  MR1_DDR3     = 16'd0    ,
  parameter [15:0]  MR2_DDR3     = 16'd0    ,
  parameter [15:0]  MR3_DDR3     = 16'd0    ,
  parameter [15:0]  MR_DDR2      = 16'd0    ,
  parameter [15:0]  EMR1_DDR2    = 16'd0    ,
  parameter [15:0]  EMR2_DDR2    = 16'd0    ,
  parameter [15:0]  EMR3_DDR2    = 16'd0    ,
  parameter [15:0]  MR_LPDDR     = 16'd0    ,
  parameter [15:0]  EMR_LPDDR    = 16'd0    
)(
   input               ddrphy_sysclk,
   input               ddrphy_rst_n ,
   input               calib_done   ,
   input [4*MEM_ADDR_WIDTH-1:0]     phy_addr    ,
   input [4*MEM_BANKADDR_WIDTH-1:0] phy_ba      ,
   input [3:0]         phy_cs_n    ,
   input [3:0]         phy_cas_n   ,
   input [3:0]         phy_ras_n   ,
   input [3:0]         phy_we_n    ,
   input [3:0]         phy_cke     ,
   output [4:0]        mc_rl       ,
   output [4:0]        mc_wl       ,
   output reg [15:0]   mr0         ,
   output reg [15:0]   mr1         ,
   output reg [15:0]   mr2         ,
   output reg [15:0]   mr3        
  );
  
  wire [3:0] phy_mrs_0 ;
  wire [3:0] phy_mrs_1 ;
  wire [3:0] phy_mrs_2 ;
  wire [3:0] phy_mrs_3 ;
  wire [1:0] ddr3_mr_al;
  wire [2:0] ddr3_mr_cwl;
  wire [3:0] ddr3_mr_cl;
  reg  [3:0] ddr3_mc_cl;
  reg  [3:0] ddr3_mc_al;
  reg  [3:0] ddr3_mc_cwl;
  wire [2:0] ddr2_mc_al ;
  wire [2:0] ddr2_mc_cl ;
  wire [2:0] lpddr_mc_cl;

  assign  phy_mrs_0  = {phy_cs_n[0],phy_cas_n[0],phy_ras_n[0],phy_we_n[0]} ;
  assign  phy_mrs_1  = {phy_cs_n[1],phy_cas_n[1],phy_ras_n[1],phy_we_n[1]} ;
  assign  phy_mrs_2  = {phy_cs_n[2],phy_cas_n[2],phy_ras_n[2],phy_we_n[2]} ;
  assign  phy_mrs_3  = {phy_cs_n[3],phy_cas_n[3],phy_ras_n[3],phy_we_n[3]} ;
    
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) 
 begin    
    if(!ddrphy_rst_n) begin
        if(DDR_TYPE == 2'b00)    //DDR3
        begin
            mr0  <= MR0_DDR3;
            mr1  <= MR1_DDR3;
            mr2  <= MR2_DDR3;
            mr3  <= MR3_DDR3;
        end
        else if(DDR_TYPE == 2'b01)    //DDR2
        begin
            mr0  <= MR_DDR2;
            mr1  <= EMR1_DDR2;
            mr2  <= EMR2_DDR2;
            mr3  <= EMR3_DDR2;
        end
        else if(DDR_TYPE == 2'b10)    //LPDDR
        begin
            mr0  <= MR_LPDDR;
            mr1  <= 16'd0;
            mr2  <= EMR_LPDDR;
            mr3  <= 16'd0;
        end
    end
    else if((phy_cke == 4'b1111)&&(calib_done == 1)) begin
            if(~|phy_mrs_0) begin 
                 case(phy_ba[1:0])
                      2'b00: mr0 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[MEM_ADDR_WIDTH-1:0]};
    
                      2'b01: mr1 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[MEM_ADDR_WIDTH-1:0]};

                      2'b10: mr2 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[MEM_ADDR_WIDTH-1:0]};

                      2'b11: mr3 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[MEM_ADDR_WIDTH-1:0]};
                 endcase
               end
             else if(~|phy_mrs_1) begin
                   case(phy_ba[MEM_BANKADDR_WIDTH+1:MEM_BANKADDR_WIDTH])
                        2'b00: mr0 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[2*MEM_ADDR_WIDTH-1:MEM_ADDR_WIDTH]};
    
                        2'b01: mr1 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[2*MEM_ADDR_WIDTH-1:MEM_ADDR_WIDTH]};

                        2'b10: mr2 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[2*MEM_ADDR_WIDTH-1:MEM_ADDR_WIDTH]};

                        2'b11: mr3 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[2*MEM_ADDR_WIDTH-1:MEM_ADDR_WIDTH]};
                    endcase
            end
            else if(~|phy_mrs_2) begin
                   case(phy_ba[2*MEM_BANKADDR_WIDTH+1:2*MEM_BANKADDR_WIDTH])
                        2'b00: mr0 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[3*MEM_ADDR_WIDTH-1:2*MEM_ADDR_WIDTH]};
    
                        2'b01: mr1 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[3*MEM_ADDR_WIDTH-1:2*MEM_ADDR_WIDTH]};

                        2'b10: mr2 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[3*MEM_ADDR_WIDTH-1:2*MEM_ADDR_WIDTH]};

                        2'b11: mr3 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[3*MEM_ADDR_WIDTH-1:2*MEM_ADDR_WIDTH]};
                    endcase                
            end
            else if(~|phy_mrs_3) begin
                   case(phy_ba[3*MEM_BANKADDR_WIDTH+1:3*MEM_BANKADDR_WIDTH])
                        2'b00: mr0 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[4*MEM_ADDR_WIDTH-1:3*MEM_ADDR_WIDTH]};
    
                        2'b01: mr1 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[4*MEM_ADDR_WIDTH-1:3*MEM_ADDR_WIDTH]};

                        2'b10: mr2 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[4*MEM_ADDR_WIDTH-1:3*MEM_ADDR_WIDTH]};

                        2'b11: mr3 <= {{(16-MEM_ADDR_WIDTH){1'b0}},phy_addr[4*MEM_ADDR_WIDTH-1:3*MEM_ADDR_WIDTH]};
                    endcase                
            end
    end
 end

  assign  ddr3_mr_al   = mr1[4:3];
  assign  ddr3_mr_cwl  = mr2[5:3];
  assign  ddr3_mr_cl   = {mr0[6:4],mr0[2]};
  
  assign  ddr2_mc_al = mr1[5:3];
  assign  ddr2_mc_cl = mr0[6:4];
  
  assign  lpddr_mc_cl = mr0[6:4];

  always @(*) 
  begin    
     case(ddr3_mr_cl)  
         4'b0010 :  ddr3_mc_cl = 4'b0101;
         4'b0100 :  ddr3_mc_cl = 4'b0110;
         4'b0110 :  ddr3_mc_cl = 4'b0111;
         4'b1000 :  ddr3_mc_cl = 4'b1000;
         4'b1010 :  ddr3_mc_cl = 4'b1001;
         4'b1100 :  ddr3_mc_cl = 4'b1010;
        default  :  ddr3_mc_cl = 4'b0000;
     endcase                             
  end                                    

  always @(*) 
  begin                       
     case(ddr3_mr_al)                     
         2'b00 :  ddr3_mc_al = 4'b0000;   
         2'b01 :  ddr3_mc_al = ddr3_mc_cl - 4'b01;
         2'b10 :  ddr3_mc_al = ddr3_mc_cl - 4'b10;
      default  :  ddr3_mc_al  = 4'b0000; 
     endcase                               
  end  
   
  always @(*)
  begin
         case(ddr3_mr_cwl)
              3'b000: ddr3_mc_cwl = 4'd5;
              3'b001: ddr3_mc_cwl = 4'd6;
              3'b010: ddr3_mc_cwl = 4'd7;
              3'b011: ddr3_mc_cwl = 4'd8;
             default: ddr3_mc_cwl = 4'd5;
         endcase
     end
              
  assign  mc_rl  = (DDR_TYPE == 2'b00) ? ({1'b0,ddr3_mc_al} + {1'b0,ddr3_mc_cl}) :
                   (DDR_TYPE == 2'b01) ? ({2'b00,ddr2_mc_al} + {2'b00,ddr2_mc_cl}) :
                   (DDR_TYPE == 2'b10) ? {2'b00,lpddr_mc_cl} : 5'h0;
                    
  assign  mc_wl  = (DDR_TYPE == 2'b00) ? ({1'b0,ddr3_mc_al} + {1'b0,ddr3_mc_cwl}) :
                   (DDR_TYPE == 2'b01) ? ({2'b00,ddr2_mc_al} + {2'b00,ddr2_mc_cl} - 5'h1) :
                   (DDR_TYPE == 2'b10) ? 5'h1 : 5'h0;

endmodule   
