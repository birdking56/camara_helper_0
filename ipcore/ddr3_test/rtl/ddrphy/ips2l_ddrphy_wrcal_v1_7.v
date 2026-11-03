////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_wrcal_v1_7 #(
  parameter       WRCAL_EN         = 1    ,
  parameter [7:0]   TRFC           = 8'd16,
  parameter [7:0]   TRCD           = 8'd2 ,
  parameter TEST_DATA_PATTERN0     = 64'h55_aa_55_aa_08_f7_08_f7,
  parameter TEST_DATA_PATTERN1     = 64'h7f_9f_7f_9f_80_fe_80_fe,
  parameter TEST_DATA_PATTERN2     = 64'hf0_0f_f0_0f_01_ff_01_ff,
  parameter TEST_DATA_PATTERN3     = 64'hdf_aa_df_aa_55_aa_55_aa,
  parameter MEM_ADDR_WIDTH         = 16,
  parameter MEM_BANKADDR_WIDTH     = 3 ,
  parameter MEM_DQ_WIDTH           = 16
)(
   input [4:0]    mc_wl              ,
   input          ddrphy_sysclk      ,
   input          ddrphy_rst_n       ,
   input          wrcal_start        ,
   output reg     wrcal_done         ,
   
   input             wrcal_check_pass   ,
   output reg [8:0]  write_calibration /* synthesis syn_preserve = 1 */ ,      //don't delete "/* synthesis syn_preserve = 1 */" !!
   output reg [8:0]  wrcal_move_en     /* synthesis syn_preserve = 1 */ ,      //don't delete "/* synthesis syn_preserve = 1 */" !!
   input             wrcal_move_done    ,
   
   output reg [MEM_BANKADDR_WIDTH-1:0]  wrcal_ba          ,
   output reg [MEM_ADDR_WIDTH-1:0]      wrcal_address     ,
   output reg wrcal_cs_n        ,
   output reg wrcal_ras_n       ,
   output reg wrcal_cas_n       ,
   output reg wrcal_we_n        ,
   output reg wrcal_cke         ,
   output reg wrcal_odt         ,
   output reg [MEM_DQ_WIDTH*8-1:0] wrcal_wrdata,
   output reg [3:0]  wrcal_wrdata_en,
   output [3:0]   dbg_wrcal         
);

  localparam WRCAL_IDLE             = 4'd0;  
  localparam WRCAL_REFRESH          = 4'd1;
  localparam WRCAL_REF_WAIT         = 4'd2;
  localparam WRCAL_ACT              = 4'd3;
  localparam WRCAL_WR               = 4'd4;
  localparam WRCAL_WR_WAIT          = 4'd5;
  localparam WRCAL_RD               = 4'd6;
  localparam WRCAL_RD_WAIT          = 4'd7;
  localparam WRCAL_RD_CHECK         = 4'd8;
  localparam WRCAL_PRE              = 4'd9;
  localparam WRCAL_DONE             = 4'd10;  

  localparam DFI_DQ_WIDTH = MEM_DQ_WIDTH * 8;

  reg [17:0]    cnt;
  reg [3:0]     wrcal_state;
  reg           cnt_trfc_pass;
  reg           ref_cnt_done;
  reg [1:0]     ref_cnt;
  reg [2:0]     wr_cnt;
  reg [2:0]     wr_cnt_d;
  reg           wr_enable;
  reg           wr_enable_d;
  wire [3:0]    bus_wr_enable   ;
  wire [3:0]    bus_wr_enable_d ;
  wire [DFI_DQ_WIDTH-1:0]    bus_wr_data    ;
  wire [DFI_DQ_WIDTH-1:0]    bus_wr_data_d  ;
  wire [63:0]   group0_data;
  wire [63:0]   group1_data;
  wire [63:0]   group2_data;
  wire [63:0]   group3_data;
  wire [MEM_DQ_WIDTH*8-1:0] pattern0;
  wire [MEM_DQ_WIDTH*8-1:0] pattern1;
  wire [MEM_DQ_WIDTH*8-1:0] pattern2;
  wire [MEM_DQ_WIDTH*8-1:0] pattern3;

//refresh
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)
          cnt_trfc_pass  <= 1'b0;
     else
         cnt_trfc_pass   <= (TRFC == cnt[7:0]);
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)  begin
          ref_cnt_done  <= 1'b0;
          ref_cnt       <= 2'b0;
     end
     else if(wrcal_state == WRCAL_REFRESH) begin
         ref_cnt       <= ref_cnt + 2'b1;
         ref_cnt_done  <= (&ref_cnt);                   //refresh 4
     end
  end
  
    
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if (!ddrphy_rst_n) begin
         wrcal_state        <= WRCAL_IDLE;
         cnt                <= 0;
      end
      else begin
         case (wrcal_state)
            WRCAL_IDLE: begin
                           cnt <= 0;
                           if (wrcal_start)
                           wrcal_state <= WRCAL_REFRESH;
                         end

          WRCAL_REFRESH: begin                                   //refresh
                                cnt         <= 0;
                                wrcal_state <= WRCAL_REF_WAIT;
                         end

         WRCAL_REF_WAIT: begin
                              if(cnt_trfc_pass) begin            //delay trfc
                                 if(ref_cnt_done)  begin         //refresh 4
                                     wrcal_state   <= WRCAL_ACT ;
                                       cnt         <= 0;
                                 end
                                 else
                                     wrcal_state   <= WRCAL_REFRESH;
                              end
                              else
                                      cnt          <= cnt + 1'b1;
                            end
                            
               WRCAL_ACT : begin                                 //active bank 0 row 0
                              if(cnt == TRCD) begin
                                   wrcal_state   <= WRCAL_WR;
                                   cnt           <= 'b0;
                               end
                               else
                                   cnt           <= cnt + 1'b1;
                            end

                WRCAL_WR : begin                                //write row 0 burst 4
                               if(cnt[3]) begin
                                      cnt      <=   'b0;
                                      wrcal_state   <=  WRCAL_WR_WAIT;
                               end
                               else
                                    cnt           <= cnt + 1'b1;
                           end  
                     
            WRCAL_WR_WAIT : begin
                              if(cnt[2]) begin
                                cnt <= 'b0;
                                if(WRCAL_EN == 1)
                                wrcal_state <= WRCAL_RD;
                                else
                                wrcal_state <= WRCAL_PRE;
                              end
                              else
                                cnt       <= cnt + 1'b1;
                            end                         
                           
                 WRCAL_RD : begin
                              if(cnt[2]) begin
                                cnt <= 'b0;
                                wrcal_state <= WRCAL_RD_WAIT;
                              end
                              else
                                cnt  <= cnt + 1'b1;
                            end
                            
             WRCAL_RD_WAIT : begin
                               if(cnt[4]) begin
                                 cnt <= 'b0;
                                 wrcal_state <= WRCAL_RD_CHECK;
                               end
                               else
                                 cnt  <= cnt + 1'b1;
                             end
                             
              WRCAL_RD_CHECK : begin
                                 if(wrcal_check_pass) begin
                                    wrcal_state <= WRCAL_PRE;
                                    cnt <= 'b0;
                                 end
                                 else if(wrcal_move_done) begin
                                    wrcal_state <= WRCAL_WR;
                                    cnt <= 'b0;
                                 end
                                 else if (~cnt[4]) 
                                   cnt <= cnt + 1;
                               end
                               
                   WRCAL_PRE : begin
                                 if(cnt[4]) begin
                                   cnt <= 'b0;
                                   wrcal_state <= WRCAL_DONE;
                                   end
                                else
                                   cnt  <= cnt + 1'b1;
                               end                 
                               
                  WRCAL_DONE : begin
                                 if(cnt[3]) begin
                                    wrcal_state <= WRCAL_IDLE;
                                    cnt         <= 'h0;
                                 end
                                 else
                                 cnt  <=  cnt + 1'b1;
                               end
                               
                       default:  wrcal_state <= WRCAL_IDLE;
                       
                    endcase
      end
  end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
   if (!ddrphy_rst_n)
       wrcal_done   <=  1'b0;
   else if(wrcal_state == WRCAL_DONE)
   begin
       if(cnt[2:0]==3'b111)
       wrcal_done   <=  1'b1;    
   end
   else
       wrcal_done   <=  1'b0;
 end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if (!ddrphy_rst_n) begin
       write_calibration  <= 9'd0;
       wrcal_move_en      <= 9'd0;
    end
    else begin
       write_calibration <= {9{(wrcal_state != WRCAL_IDLE)}};
       wrcal_move_en     <= {9{(wrcal_state == WRCAL_RD_CHECK) && cnt[4]}};
    end
 end


  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n) begin
        wrcal_cs_n       <= 1'b1;
        wrcal_ras_n      <= 1'b0;
        wrcal_cas_n      <= 1'b0;
        wrcal_we_n       <= 1'b0;
        wrcal_ba         <= {MEM_BANKADDR_WIDTH{1'b0}};
        wrcal_address    <= {MEM_ADDR_WIDTH{1'b0}};
     end
     else  begin
        wrcal_cs_n       <= 1'b1;
        wrcal_ras_n      <= 1'b1;
        wrcal_cas_n      <= 1'b1;
        wrcal_we_n       <= 1'b1;
        wrcal_ba         <= {MEM_BANKADDR_WIDTH{1'b0}};
        wrcal_address    <= {MEM_ADDR_WIDTH{1'b0}};
        case(wrcal_state)
           WRCAL_REFRESH : begin //ref
                             wrcal_cs_n       <= 1'b0;
                             wrcal_ras_n      <= 1'b0;
                             wrcal_cas_n      <= 1'b0;
                             wrcal_we_n       <= 1'b1;
                           end

             WRCAL_ACT : begin //act
                           if(~|cnt)begin     //cnt = 0
                             wrcal_cs_n       <= 1'b0;
                             wrcal_ras_n      <= 1'b0;
                             wrcal_cas_n      <= 1'b1;
                             wrcal_we_n       <= 1'b1;
                           end
                         end

             WRCAL_WR : begin   //wr
                          if(cnt[4:0] < 5'd4) begin
                               wrcal_cs_n            <= 1'b0;
                               wrcal_ras_n           <= 1'b1;
                               wrcal_cas_n           <= 1'b0;
                               wrcal_we_n            <= 1'b0;
                               wrcal_address         <= {{(MEM_ADDR_WIDTH-5){1'b0}},cnt[1:0],3'b000};
                            end
                        end
                        
              WRCAL_RD : begin
                          if(cnt[4:0] < 5'd4) begin
                               wrcal_cs_n            <= 1'b0;
                               wrcal_ras_n           <= 1'b1;
                               wrcal_cas_n           <= 1'b0;
                               wrcal_we_n            <= 1'b1;
                               wrcal_address         <= {{(MEM_ADDR_WIDTH-5){1'b0}},cnt[1:0],3'b000};
                           end
                         end
                                                                     
              WRCAL_PRE: begin                                                   
                            if(cnt== 18'd4) begin                     
                                wrcal_cs_n          <= 1'b0 ;           
                                wrcal_ras_n         <= 1'b0 ;           
                                wrcal_cas_n         <= 1'b1 ;           
                                wrcal_we_n          <= 1'b0 ;         
                                wrcal_address       <= {{(MEM_ADDR_WIDTH-11){1'b0}},1'b1,10'h0};           
                             end                                        
                         end 
                              
//              WRCAL_DONE: begin
//                           if(~|cnt)begin
//                              wrcal_cs_n          <= 1'b0; 
//                              wrcal_ras_n         <= 1'b0; 
//                              wrcal_cas_n         <= 1'b1; 
//                              wrcal_we_n          <= 1'b0; 
//                              wrcal_address       <= {{(MEM_ADDR_WIDTH-11){1'b0}},1'b1,10'h0}; 
//                           end
//                         end
                            
          endcase
     end
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)
        wrcal_odt   <= 1'b0;
     else if(wrcal_state == WRCAL_WR)
        wrcal_odt   <= 1'b1;
     else
        wrcal_odt   <= 1'b0;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)
        wrcal_cke   <= 1'b0;
     else
        wrcal_cke   <= 1'b1;
  end

////--------------------DDR data write---------------------------------///
always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
   if (!ddrphy_rst_n) begin
   	  wr_enable  <= 1'b0;
   end
   else begin
   	  if (wrcal_state == WRCAL_WR) begin
   	     case (mc_wl[4:2])
            3'b000 : begin
                        if((cnt[4:0] == 5'd0)||(cnt[4:0] == 5'd1)||(cnt[4:0] == 5'd2)||(cnt[4:0] == 5'd3))
                           wr_enable  <= 1'b1;
                        else
                           wr_enable  <= 1'b0;
                      end
            3'b001 : begin
                       if((cnt[4:0] == 5'd1)||(cnt[4:0] == 5'd2)||(cnt[4:0] == 5'd3)||(cnt[4:0] == 5'd4))
   	                       wr_enable <= 1'b1;
   	                   else    	                        
                           wr_enable <= 1'b0;
                      end

            3'b010 : begin
                        if((cnt[4:0] == 5'd2)||(cnt[4:0] == 5'd3)||(cnt[4:0] == 5'd4)||(cnt[4:0] == 5'd5))
                           wr_enable   <= 1'b1;
                        else
                           wr_enable   <= 1'b0;
                      end

            3'b011 : begin
                        if((cnt[4:0] == 5'd3)||(cnt[4:0] == 5'd4)||(cnt[4:0] == 5'd5)||(cnt[4:0] == 5'd6))
                            wr_enable <= 1'b1;
                        else
                            wr_enable <= 1'b0;
                      end
                      
//            3'b100 : begin
//                       if((cnt[4:0] == 5'd4)||(cnt[4:0] == 5'd5)||(cnt[4:0] == 5'd6)||(cnt[4:0] == 5'd7))
//                            wr_enable <= 1'b1;
//                        else
//                            wr_enable <= 1'b0;
//                     end           
            default:
                    wr_enable <= 1'b0;
          endcase
       end
    else
         wr_enable <= 1'b0;
  end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if (!ddrphy_rst_n) begin
          wr_enable_d <= 1'b0;
          wr_cnt      <= 3'h0;
          wr_cnt_d    <= 3'h0;
     end
    else begin
         wr_enable_d <= wr_enable;
         wr_cnt_d    <= wr_cnt;
         if (wr_enable)
            wr_cnt  <= wr_cnt + 3'h1;
         else
            wr_cnt  <= 3'h0;
    end
 end

  assign bus_wr_enable   = {4{wr_enable}};
  assign bus_wr_enable_d = {4{wr_enable_d}};
  
  assign group0_data = {TEST_DATA_PATTERN0[56],TEST_DATA_PATTERN0[48],TEST_DATA_PATTERN0[40],TEST_DATA_PATTERN0[32],TEST_DATA_PATTERN0[24],TEST_DATA_PATTERN0[16],TEST_DATA_PATTERN0[8] ,TEST_DATA_PATTERN0[0],
                        TEST_DATA_PATTERN0[57],TEST_DATA_PATTERN0[49],TEST_DATA_PATTERN0[41],TEST_DATA_PATTERN0[33],TEST_DATA_PATTERN0[25],TEST_DATA_PATTERN0[17],TEST_DATA_PATTERN0[9] ,TEST_DATA_PATTERN0[1],
                        TEST_DATA_PATTERN0[58],TEST_DATA_PATTERN0[50],TEST_DATA_PATTERN0[42],TEST_DATA_PATTERN0[34],TEST_DATA_PATTERN0[26],TEST_DATA_PATTERN0[18],TEST_DATA_PATTERN0[10],TEST_DATA_PATTERN0[2],
                        TEST_DATA_PATTERN0[59],TEST_DATA_PATTERN0[51],TEST_DATA_PATTERN0[43],TEST_DATA_PATTERN0[35],TEST_DATA_PATTERN0[27],TEST_DATA_PATTERN0[19],TEST_DATA_PATTERN0[11],TEST_DATA_PATTERN0[3],
                        TEST_DATA_PATTERN0[60],TEST_DATA_PATTERN0[52],TEST_DATA_PATTERN0[44],TEST_DATA_PATTERN0[36],TEST_DATA_PATTERN0[28],TEST_DATA_PATTERN0[20],TEST_DATA_PATTERN0[12],TEST_DATA_PATTERN0[4],
                        TEST_DATA_PATTERN0[61],TEST_DATA_PATTERN0[53],TEST_DATA_PATTERN0[45],TEST_DATA_PATTERN0[37],TEST_DATA_PATTERN0[29],TEST_DATA_PATTERN0[21],TEST_DATA_PATTERN0[13],TEST_DATA_PATTERN0[5],
                        TEST_DATA_PATTERN0[62],TEST_DATA_PATTERN0[54],TEST_DATA_PATTERN0[46],TEST_DATA_PATTERN0[38],TEST_DATA_PATTERN0[30],TEST_DATA_PATTERN0[22],TEST_DATA_PATTERN0[14],TEST_DATA_PATTERN0[6],
                        TEST_DATA_PATTERN0[63],TEST_DATA_PATTERN0[55],TEST_DATA_PATTERN0[47],TEST_DATA_PATTERN0[39],TEST_DATA_PATTERN0[31],TEST_DATA_PATTERN0[23],TEST_DATA_PATTERN0[15],TEST_DATA_PATTERN0[7]};

  assign group1_data = {TEST_DATA_PATTERN1[56],TEST_DATA_PATTERN1[48],TEST_DATA_PATTERN1[40],TEST_DATA_PATTERN1[32],TEST_DATA_PATTERN1[24],TEST_DATA_PATTERN1[16],TEST_DATA_PATTERN1[8] ,TEST_DATA_PATTERN1[0],
                        TEST_DATA_PATTERN1[57],TEST_DATA_PATTERN1[49],TEST_DATA_PATTERN1[41],TEST_DATA_PATTERN1[33],TEST_DATA_PATTERN1[25],TEST_DATA_PATTERN1[17],TEST_DATA_PATTERN1[9] ,TEST_DATA_PATTERN1[1],
                        TEST_DATA_PATTERN1[58],TEST_DATA_PATTERN1[50],TEST_DATA_PATTERN1[42],TEST_DATA_PATTERN1[34],TEST_DATA_PATTERN1[26],TEST_DATA_PATTERN1[18],TEST_DATA_PATTERN1[10],TEST_DATA_PATTERN1[2],
                        TEST_DATA_PATTERN1[59],TEST_DATA_PATTERN1[51],TEST_DATA_PATTERN1[43],TEST_DATA_PATTERN1[35],TEST_DATA_PATTERN1[27],TEST_DATA_PATTERN1[19],TEST_DATA_PATTERN1[11],TEST_DATA_PATTERN1[3],
                        TEST_DATA_PATTERN1[60],TEST_DATA_PATTERN1[52],TEST_DATA_PATTERN1[44],TEST_DATA_PATTERN1[36],TEST_DATA_PATTERN1[28],TEST_DATA_PATTERN1[20],TEST_DATA_PATTERN1[12],TEST_DATA_PATTERN1[4],
                        TEST_DATA_PATTERN1[61],TEST_DATA_PATTERN1[53],TEST_DATA_PATTERN1[45],TEST_DATA_PATTERN1[37],TEST_DATA_PATTERN1[29],TEST_DATA_PATTERN1[21],TEST_DATA_PATTERN1[13],TEST_DATA_PATTERN1[5],
                        TEST_DATA_PATTERN1[62],TEST_DATA_PATTERN1[54],TEST_DATA_PATTERN1[46],TEST_DATA_PATTERN1[38],TEST_DATA_PATTERN1[30],TEST_DATA_PATTERN1[22],TEST_DATA_PATTERN1[14],TEST_DATA_PATTERN1[6],
                        TEST_DATA_PATTERN1[63],TEST_DATA_PATTERN1[55],TEST_DATA_PATTERN1[47],TEST_DATA_PATTERN1[39],TEST_DATA_PATTERN1[31],TEST_DATA_PATTERN1[23],TEST_DATA_PATTERN1[15],TEST_DATA_PATTERN1[7]};

  assign group2_data = {TEST_DATA_PATTERN2[56],TEST_DATA_PATTERN2[48],TEST_DATA_PATTERN2[40],TEST_DATA_PATTERN2[32],TEST_DATA_PATTERN2[24],TEST_DATA_PATTERN2[16],TEST_DATA_PATTERN2[8] ,TEST_DATA_PATTERN2[0],
                        TEST_DATA_PATTERN2[57],TEST_DATA_PATTERN2[49],TEST_DATA_PATTERN2[41],TEST_DATA_PATTERN2[33],TEST_DATA_PATTERN2[25],TEST_DATA_PATTERN2[17],TEST_DATA_PATTERN2[9] ,TEST_DATA_PATTERN2[1],
                        TEST_DATA_PATTERN2[58],TEST_DATA_PATTERN2[50],TEST_DATA_PATTERN2[42],TEST_DATA_PATTERN2[34],TEST_DATA_PATTERN2[26],TEST_DATA_PATTERN2[18],TEST_DATA_PATTERN2[10],TEST_DATA_PATTERN2[2],
                        TEST_DATA_PATTERN2[59],TEST_DATA_PATTERN2[51],TEST_DATA_PATTERN2[43],TEST_DATA_PATTERN2[35],TEST_DATA_PATTERN2[27],TEST_DATA_PATTERN2[19],TEST_DATA_PATTERN2[11],TEST_DATA_PATTERN2[3],
                        TEST_DATA_PATTERN2[60],TEST_DATA_PATTERN2[52],TEST_DATA_PATTERN2[44],TEST_DATA_PATTERN2[36],TEST_DATA_PATTERN2[28],TEST_DATA_PATTERN2[20],TEST_DATA_PATTERN2[12],TEST_DATA_PATTERN2[4],
                        TEST_DATA_PATTERN2[61],TEST_DATA_PATTERN2[53],TEST_DATA_PATTERN2[45],TEST_DATA_PATTERN2[37],TEST_DATA_PATTERN2[29],TEST_DATA_PATTERN2[21],TEST_DATA_PATTERN2[13],TEST_DATA_PATTERN2[5],
                        TEST_DATA_PATTERN2[62],TEST_DATA_PATTERN2[54],TEST_DATA_PATTERN2[46],TEST_DATA_PATTERN2[38],TEST_DATA_PATTERN2[30],TEST_DATA_PATTERN2[22],TEST_DATA_PATTERN2[14],TEST_DATA_PATTERN2[6],
                        TEST_DATA_PATTERN2[63],TEST_DATA_PATTERN2[55],TEST_DATA_PATTERN2[47],TEST_DATA_PATTERN2[39],TEST_DATA_PATTERN2[31],TEST_DATA_PATTERN2[23],TEST_DATA_PATTERN2[15],TEST_DATA_PATTERN2[7]};  

  assign group3_data = {TEST_DATA_PATTERN3[56],TEST_DATA_PATTERN3[48],TEST_DATA_PATTERN3[40],TEST_DATA_PATTERN3[32],TEST_DATA_PATTERN3[24],TEST_DATA_PATTERN3[16],TEST_DATA_PATTERN3[8] ,TEST_DATA_PATTERN3[0],
                        TEST_DATA_PATTERN3[57],TEST_DATA_PATTERN3[49],TEST_DATA_PATTERN3[41],TEST_DATA_PATTERN3[33],TEST_DATA_PATTERN3[25],TEST_DATA_PATTERN3[17],TEST_DATA_PATTERN3[9] ,TEST_DATA_PATTERN3[1],
                        TEST_DATA_PATTERN3[58],TEST_DATA_PATTERN3[50],TEST_DATA_PATTERN3[42],TEST_DATA_PATTERN3[34],TEST_DATA_PATTERN3[26],TEST_DATA_PATTERN3[18],TEST_DATA_PATTERN3[10],TEST_DATA_PATTERN3[2],
                        TEST_DATA_PATTERN3[59],TEST_DATA_PATTERN3[51],TEST_DATA_PATTERN3[43],TEST_DATA_PATTERN3[35],TEST_DATA_PATTERN3[27],TEST_DATA_PATTERN3[19],TEST_DATA_PATTERN3[11],TEST_DATA_PATTERN3[3],
                        TEST_DATA_PATTERN3[60],TEST_DATA_PATTERN3[52],TEST_DATA_PATTERN3[44],TEST_DATA_PATTERN3[36],TEST_DATA_PATTERN3[28],TEST_DATA_PATTERN3[20],TEST_DATA_PATTERN3[12],TEST_DATA_PATTERN3[4],
                        TEST_DATA_PATTERN3[61],TEST_DATA_PATTERN3[53],TEST_DATA_PATTERN3[45],TEST_DATA_PATTERN3[37],TEST_DATA_PATTERN3[29],TEST_DATA_PATTERN3[21],TEST_DATA_PATTERN3[13],TEST_DATA_PATTERN3[5],
                        TEST_DATA_PATTERN3[62],TEST_DATA_PATTERN3[54],TEST_DATA_PATTERN3[46],TEST_DATA_PATTERN3[38],TEST_DATA_PATTERN3[30],TEST_DATA_PATTERN3[22],TEST_DATA_PATTERN3[14],TEST_DATA_PATTERN3[6],
                        TEST_DATA_PATTERN3[63],TEST_DATA_PATTERN3[55],TEST_DATA_PATTERN3[47],TEST_DATA_PATTERN3[39],TEST_DATA_PATTERN3[31],TEST_DATA_PATTERN3[23],TEST_DATA_PATTERN3[15],TEST_DATA_PATTERN3[7]};
                          
  assign pattern0 = {{DFI_DQ_WIDTH/64{group0_data[63:56]}},{DFI_DQ_WIDTH/64{group0_data[55:48]}},{DFI_DQ_WIDTH/64{group0_data[47:40]}},{DFI_DQ_WIDTH/64{group0_data[39:32]}},{DFI_DQ_WIDTH/64{group0_data[31:24]}},{DFI_DQ_WIDTH/64{group0_data[23:16]}},{DFI_DQ_WIDTH/64{group0_data[15:8]}},{DFI_DQ_WIDTH/64{group0_data[7:0]}}};
  assign pattern1 = {{DFI_DQ_WIDTH/64{group1_data[63:56]}},{DFI_DQ_WIDTH/64{group1_data[55:48]}},{DFI_DQ_WIDTH/64{group1_data[47:40]}},{DFI_DQ_WIDTH/64{group1_data[39:32]}},{DFI_DQ_WIDTH/64{group1_data[31:24]}},{DFI_DQ_WIDTH/64{group1_data[23:16]}},{DFI_DQ_WIDTH/64{group1_data[15:8]}},{DFI_DQ_WIDTH/64{group1_data[7:0]}}};
  assign pattern2 = {{DFI_DQ_WIDTH/64{group2_data[63:56]}},{DFI_DQ_WIDTH/64{group2_data[55:48]}},{DFI_DQ_WIDTH/64{group2_data[47:40]}},{DFI_DQ_WIDTH/64{group2_data[39:32]}},{DFI_DQ_WIDTH/64{group2_data[31:24]}},{DFI_DQ_WIDTH/64{group2_data[23:16]}},{DFI_DQ_WIDTH/64{group2_data[15:8]}},{DFI_DQ_WIDTH/64{group2_data[7:0]}}};
  assign pattern3 = {{DFI_DQ_WIDTH/64{group3_data[63:56]}},{DFI_DQ_WIDTH/64{group3_data[55:48]}},{DFI_DQ_WIDTH/64{group3_data[47:40]}},{DFI_DQ_WIDTH/64{group3_data[39:32]}},{DFI_DQ_WIDTH/64{group3_data[31:24]}},{DFI_DQ_WIDTH/64{group3_data[23:16]}},{DFI_DQ_WIDTH/64{group3_data[15:8]}},{DFI_DQ_WIDTH/64{group3_data[7:0]}}};
  
  assign bus_wr_data   = (wr_cnt == 3'd0) ?  pattern0 :
                         (wr_cnt == 3'd1) ?  pattern1 :
                         (wr_cnt == 3'd2) ?  pattern2 : pattern3 ;

  assign bus_wr_data_d = (wr_cnt_d == 3'd0) ?  pattern0 :
                         (wr_cnt_d == 3'd1) ?  pattern1 :
                         (wr_cnt_d == 3'd2) ?  pattern2 : pattern3 ;
                         
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) begin
        wrcal_wrdata_en  <= 4'b0000;
        wrcal_wrdata     <= {DFI_DQ_WIDTH{1'b0}};
     end
     else begin
        case (mc_wl[1:0])
            2'b00:begin
                wrcal_wrdata_en  <= bus_wr_enable;
                wrcal_wrdata     <= bus_wr_data;
            end
            2'b01:begin
                wrcal_wrdata_en  <= {bus_wr_enable[2:0], bus_wr_enable_d[3]};
                wrcal_wrdata     <= {bus_wr_data[DFI_DQ_WIDTH*3/4-1 : 0], bus_wr_data_d[DFI_DQ_WIDTH-1: DFI_DQ_WIDTH*3/4]};
            end
            2'b10:begin
                wrcal_wrdata_en <= {bus_wr_enable[1:0], bus_wr_enable_d[3:2]};
                wrcal_wrdata    <= {bus_wr_data[DFI_DQ_WIDTH*2/4-1 : 0], bus_wr_data_d[DFI_DQ_WIDTH-1: DFI_DQ_WIDTH*2/4]};
            end
            2'b11:begin
                wrcal_wrdata_en <= {bus_wr_enable[0],bus_wr_enable_d[3:1]};
                wrcal_wrdata    <= {bus_wr_data[DFI_DQ_WIDTH*1/4-1 : 0], bus_wr_data_d[DFI_DQ_WIDTH-1: DFI_DQ_WIDTH*1/4]};
            end
            default:begin
                wrcal_wrdata_en <= 4'b0000;
                wrcal_wrdata     <= {DFI_DQ_WIDTH{1'b0}};
            end
        endcase
     end
  end

assign dbg_wrcal = wrcal_state;
// assign  wrcal_wrdata_mask = {(8*MEM_DM_WIDTH){1'b0}};

endmodule
