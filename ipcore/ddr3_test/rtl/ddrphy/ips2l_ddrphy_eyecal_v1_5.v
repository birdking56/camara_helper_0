////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_eyecal_v1_5 #(
  parameter [7:0]   TRFC           = 8'd16,
  parameter [7:0]   TRCD           = 8'd2 ,
  parameter MEM_ADDR_WIDTH         = 16   ,
  parameter MEM_BANKADDR_WIDTH     = 3    ,
  parameter MEM_DQ_WIDTH           = 16   
)(
   input          ddrphy_sysclk      ,
   input          ddrphy_rst_n       ,

   input          eyecal_start       ,
   output reg     eyecal_done        ,
   output reg     eye_calibration    ,
   input          eyecal_check_pass  ,
   input          eyecal_move_done   ,
   output reg     eyecal_move_en     ,
   input          eye_calibration_error ,
   output         eyecalib_error     ,

   output reg [MEM_BANKADDR_WIDTH-1:0]  eyecal_ba          ,
   output reg [MEM_ADDR_WIDTH-1:0]      eyecal_address     ,
   output reg eyecal_cs_n        ,
   output reg eyecal_ras_n       ,
   output reg eyecal_cas_n       ,
   output reg eyecal_we_n        ,
   output reg eyecal_cke         ,
   output     eyecal_odt         ,
   output [3:0]  dbg_eyecal        
);

  localparam EYECAL_IDLE       = 4'd0;
  localparam EYECAL_REFRESH    = 4'd1;
  localparam EYECAL_REF_WAIT   = 4'd2;
  localparam EYECAL_ACT        = 4'd3;
  localparam EYECAL_RD         = 4'd4;
  localparam EYECAL_RD_WAIT    = 4'd5;
  localparam EYECAL_RD_CHECK   = 4'd6;
  localparam EYECAL_PRE        = 4'd7;
  localparam EYECAL_DONE       = 4'd8;
  localparam EYECAL_ERROR      = 4'd9;

  reg [7:0]     cnt;
  reg [3:0]     eyecal_state;
  reg           cnt_trfc_pass;
  reg           ref_cnt_done;
  reg [1:0]     ref_cnt;


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
     else if(eyecal_state == EYECAL_REFRESH) begin
         ref_cnt       <= ref_cnt + 2'b1;
         ref_cnt_done  <= (&ref_cnt);                   //refresh 4
     end
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if (!ddrphy_rst_n) begin
         eyecal_state       <= EYECAL_IDLE;
         cnt                <= 0;
      end
      else 
      begin
         case (eyecal_state)
            EYECAL_IDLE: begin
                           cnt <= 0;
                           if (eyecal_start)
                           eyecal_state <= EYECAL_REFRESH;
                         end

          EYECAL_REFRESH: begin                                   //refresh
                                cnt          <= 0;
                                eyecal_state <= EYECAL_REF_WAIT;
                         end

         EYECAL_REF_WAIT: begin
                              if(cnt_trfc_pass) begin            //delay trfc
                                 if(ref_cnt_done)  begin         //refresh 4
                                     eyecal_state   <= EYECAL_ACT ;
                                     cnt            <= 0;
                                 end
                                 else
                                     eyecal_state   <= EYECAL_REFRESH;
                              end
                              else
                                      cnt          <= cnt + 1'b1;
                            end
                            
               EYECAL_ACT : begin                                 //active bank 0 row 0
                              if(cnt == TRCD) begin
                                   eyecal_state   <= EYECAL_RD;
                                   cnt            <= 'b0;
                               end
                               else
                                   cnt           <= cnt + 1'b1;
                            end
                            
                 EYECAL_RD : begin
                              if(cnt[2]) begin
                                cnt <= 'b0;
                                eyecal_state <= EYECAL_RD_WAIT;
                              end
                              else
                                cnt  <= cnt + 1'b1;
                            end
                            
             EYECAL_RD_WAIT : begin
                               if(cnt[4]) begin
                                 cnt <= 'b0;
                                 eyecal_state <= EYECAL_RD_CHECK;
                               end
                               else
                                 cnt  <= cnt + 1'b1;
                             end
                             
              EYECAL_RD_CHECK : begin
                                 if(eyecal_check_pass) begin
                                    eyecal_state <= EYECAL_PRE;
                                    cnt <= 'b0;
                                 end
                                 else if(eyecal_move_done) begin
                                    eyecal_state <= EYECAL_RD;
                                    cnt <= 'b0;
                                 end
                                 else if (~cnt[5]) 
                                   cnt <= cnt + 1;
                               end
                               
                   EYECAL_PRE : begin
                                 if(cnt[4]) begin
                                   cnt <= 'b0;
                                   if(eye_calibration_error )
                                       eyecal_state <= EYECAL_ERROR ;
                                   else     
                                       eyecal_state <= EYECAL_DONE;
                                   end
                                else
                                   cnt  <= cnt + 1'b1;
                               end                 
                               
                  EYECAL_DONE : begin
                                 if(cnt[3]) begin
                                    eyecal_state <= EYECAL_IDLE;
                                    cnt         <= 'h0;
                                 end
                                 else
                                 cnt  <=  cnt + 1'b1;
                               end
                  EYECAL_ERROR:begin
                                 eyecal_state <= EYECAL_ERROR;
                                 cnt <= cnt;
                               end
                       default: begin  
                                eyecal_state <= EYECAL_IDLE;
                       end
                       
                    endcase
      end
  end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
   if (!ddrphy_rst_n)
       eyecal_done   <=  1'b0;
   else if(eyecal_state == EYECAL_DONE)
   begin
       if(cnt[2:0]==3'b111)
       eyecal_done   <=  1'b1;    
   end
   else
       eyecal_done   <=  1'b0;
 end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if (!ddrphy_rst_n) begin
       eye_calibration  <= 1'b0;
       eyecal_move_en   <= 1'b0;
    end
    else begin
       eye_calibration <= (eyecal_state != EYECAL_IDLE);
       eyecal_move_en  <= (eyecal_state == EYECAL_RD_CHECK) && cnt[5];
    end
 end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n) begin
        eyecal_cs_n       <= 1'b1;
        eyecal_ras_n      <= 1'b0;
        eyecal_cas_n      <= 1'b0;
        eyecal_we_n       <= 1'b0;
        eyecal_ba         <= {MEM_BANKADDR_WIDTH{1'b0}};
        eyecal_address    <= {MEM_ADDR_WIDTH{1'b0}};
     end
     else  begin
        eyecal_cs_n       <= 1'b1;
        eyecal_ras_n      <= 1'b1;
        eyecal_cas_n      <= 1'b1;
        eyecal_we_n       <= 1'b1;
        eyecal_ba         <= {MEM_BANKADDR_WIDTH{1'b0}};
        eyecal_address    <= {MEM_ADDR_WIDTH{1'b0}};
        case(eyecal_state)
           EYECAL_REFRESH : begin //ref
                             eyecal_cs_n       <= 1'b0;
                             eyecal_ras_n      <= 1'b0;
                             eyecal_cas_n      <= 1'b0;
                             eyecal_we_n       <= 1'b1;
                           end

             EYECAL_ACT : begin //act
                           if(~|cnt)begin     //cnt = 0
                             eyecal_cs_n       <= 1'b0;
                             eyecal_ras_n      <= 1'b0;
                             eyecal_cas_n      <= 1'b1;
                             eyecal_we_n       <= 1'b1;
                           end
                         end

              EYECAL_RD : begin
                          if(cnt[4:0] < 5'd4) begin
                               eyecal_cs_n            <= 1'b0;
                               eyecal_ras_n           <= 1'b1;
                               eyecal_cas_n           <= 1'b0;
                               eyecal_we_n            <= 1'b1;
                               eyecal_address         <= {{(MEM_ADDR_WIDTH-5){1'b0}},cnt[1:0],3'b000};
                           end
                         end
                                                                     
              EYECAL_PRE: begin                                                   
                            if(cnt== 8'd4) begin                     
                                eyecal_cs_n          <= 1'b0 ;           
                                eyecal_ras_n         <= 1'b0 ;           
                                eyecal_cas_n         <= 1'b1 ;           
                                eyecal_we_n          <= 1'b0 ;         
                                eyecal_address       <= {{(MEM_ADDR_WIDTH-11){1'b0}},1'b1,10'h0};           
                             end                                        
                         end 
                            
          endcase
     end
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)
        eyecal_cke   <= 1'b0;
     else
        eyecal_cke   <= 1'b1;
  end

 assign eyecal_odt = 1'b0;     

 assign dbg_eyecal = eyecal_state;       
 assign eyecalib_error = eyecal_state == EYECAL_ERROR ;
endmodule
