////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_rdcal_v1_5 #(
  parameter [1:0]   DDR_TYPE       = 2'b00 ,  //2'b00:DDR3  2'b01:DDR2  2'b10:LPDDR
  parameter [7:0]   TRFC           = 8'd16 ,
  parameter [7:0]   TRCD           = 8'd2  ,
  parameter MEM_ADDR_WIDTH         = 16    ,
  parameter MEM_BANKADDR_WIDTH     = 3     ,
  parameter MEM_DQ_WIDTH           = 16    
)(
   input [4:0]    mc_wl              ,  
   input          ddrphy_sysclk      ,
   input          ddrphy_rst_n       ,

   input          rdcal_start        ,
   output reg     rdcal_done         ,

   output reg     ddrphy_rst_req     ,
   input          ddrphy_rst_ack     ,

   output reg     gatecal_start      ,
   input          gate_check_pass    ,
   input          gate_adj_done      ,
   input          gate_cal_error     ,
   output reg     gate_move_en       ,

   output reg     rddata_cal         , 
   input          rddata_check_pass  ,

   output reg     init_adj_rdel      ,
   input          adj_rdel_done      ,

   output reg     rdel_calibration   ,
   input          rdel_calib_done    ,
   input          rdel_calib_error   ,
   output reg     rdel_move_en       ,
   input          rdel_move_done     ,

   input          write_debug        ,
   input          dqgt_debug         ,
   input [7:0]    rdel_rd_cnt        ,
   
   output reg     bitslip_ctrl       ,
   output         rdcalib_error      ,
   output [4:0]   dbg_rdcal          ,

   output reg [MEM_BANKADDR_WIDTH-1:0]  rdcal_ba          ,
   output reg [MEM_ADDR_WIDTH-1:0]      rdcal_address     ,
   output reg rdcal_cs_n        ,
   output reg rdcal_ras_n       ,
   output reg rdcal_cas_n       ,
   output reg rdcal_we_n        ,
   output reg rdcal_cke         ,
   output reg rdcal_odt         ,
   output reg [MEM_DQ_WIDTH*8-1:0] rdcal_wrdata,
   output reg [3:0]  rdcal_wrdata_en   
  );

  //main control states
  localparam RDCAL_IDLE             = 5'd0;
  localparam RDCAL_RDEL_INIT        = 5'd1;  
  localparam RDCAL_REFRESH          = 5'd2;
  localparam RDCAL_REF_WAIT         = 5'd3;
  localparam RDCAL_WR_ACT           = 5'd4;
  localparam RDCAL_WR               = 5'd5;
  localparam RDCAL_GATECAL_STATRT   = 5'd6;
  localparam RDCAL_GATECAL_RD       = 5'd7;
  localparam RDCAL_GATE_CHECK       = 5'd8;  
  localparam RDCAL_GATECAL_RST      = 5'd9;
  localparam RDCAL_RDDATA_CHECK     = 5'd10;
  localparam RDCAL_BITSLIP          = 5'd11;
  localparam RDCAL_RDEL_MPR_PRE     = 5'd12;
  localparam RDCAL_OPEN_MPR         = 5'd13;
  localparam RDCAL_RDEL_CALIB       = 5'd14;
  localparam RDCAL_RDEL_TURN        = 5'd15;
  localparam RDCAL_CLOSE_MPR        = 5'd16;
  localparam RDCALIB_DONE           = 5'd17;
  localparam RDCAL_ERROR            = 5'd18;
  localparam RDCAL_GATECAL_ERROR    = 5'd19; 
  localparam RDCAL_RDEL_PRE         = 5'd20;

  localparam DFI_DQ_WIDTH = MEM_DQ_WIDTH * 8;
//  wire [63:0] pattern0 ;

  reg [7:0]     cnt;
  reg [4:0]     rdcal_state;
  reg [1:0]     ddrphy_rst_ack_r;
  reg [1:0]     ref_cnt;
  reg           cnt_trfc_pass;
  reg           ref_cnt_done  ;
  reg           rdcal_success ;
  reg [1:0]     wr_cnt;
  reg [1:0]     wr_cnt_d;
  reg           wr_enable;
  reg           wr_enable_d;
  reg  [3:0]    bslip_cnt;
  reg           bslip_start;
  wire [3:0]    bus_wr_enable   ;
  wire [3:0]    bus_wr_enable_d ;
  wire [DFI_DQ_WIDTH-1:0]    bus_wr_data    ;
  wire [DFI_DQ_WIDTH-1:0]    bus_wr_data_d  ;

///********************************main code************************
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
     else if(rdcal_state == RDCAL_REFRESH) begin
         ref_cnt       <= ref_cnt + 2'b1;
         ref_cnt_done  <= (&ref_cnt);                   //refresh 4
     end
  end

generate
if (DDR_TYPE == 2'b00) begin    //DDR3
////state
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if (!ddrphy_rst_n) begin
         rdcal_state        <= RDCAL_IDLE;
         cnt               <= 0;
      end
      else begin
         case (rdcal_state)
            RDCAL_IDLE: begin
                           cnt <= 0;
                           if (rdcal_start)
                                rdcal_state <= RDCAL_RDEL_INIT;
                         end

        RDCAL_RDEL_INIT: begin                                   //init_adj_rdel = 1
                              if (adj_rdel_done)                 //init adj rdel done
                                  rdcal_state <= RDCAL_REFRESH;
                         end

          RDCAL_REFRESH: begin                                   //refresh
                                cnt         <= 0;
                                rdcal_state <= RDCAL_REF_WAIT;
                         end

         RDCAL_REF_WAIT: begin
                              if(cnt_trfc_pass) begin            //delay trfc
                                 if(ref_cnt_done)  begin         //refresh 4
                                     rdcal_state   <= RDCAL_WR_ACT ;
                                       cnt         <= 0;
                                 end
                                 else
                                     rdcal_state   <= RDCAL_REFRESH;
                              end
                              else
                                      cnt          <= cnt + 1'b1;
                            end

            RDCAL_WR_ACT : begin                                 //active bank 0 row 0
                              if(cnt == TRCD) begin
                                   rdcal_state   <= RDCAL_WR;
                                   cnt           <= 'b0;
                               end
                               else
                                   cnt           <= cnt + 1'b1;
                            end

                RDCAL_WR : begin                                //write row 0 burst 4
                               if(cnt[2]) begin
                                      cnt      <=   'b0;
                                  begin
                                      if(write_debug)
                                         rdcal_state   <=  RDCAL_WR;
                                      else
                                         rdcal_state   <= RDCAL_GATECAL_STATRT;
                                  end
                               end
                               else
                                    cnt           <= cnt + 1'b1;
                           end
                           
     RDCAL_GATECAL_STATRT: begin                                //gatecal_start = 1
                              rdcal_state  <= RDCAL_GATECAL_RD;
                           end

        RDCAL_GATECAL_RD: begin                                 //read once
                             if(cnt[1]) begin
                                 cnt            <= 'b0;
                                 rdcal_state    <= RDCAL_GATE_CHECK ;
                             end
                             else
                             cnt   <= cnt + 1'b1;
                         end
                         
        RDCAL_GATE_CHECK: begin
                             if (gate_adj_done)                 //single adjust complete  
                                  rdcal_state  <=  RDCAL_GATECAL_RST;
                             else if (gate_cal_error)           //gate fail
                                  rdcal_state  <=  RDCAL_GATECAL_ERROR ;
                             else
                                     rdcal_state  <=  RDCAL_GATE_CHECK ;
                          end

       RDCAL_GATECAL_RST: begin                                 //ddrphy_rst_req  = 1 
                            if(ddrphy_rst_ack_r[1]) begin       //gate_move_en = 1
                                if (dqgt_debug)
                                    rdcal_state <= RDCAL_GATECAL_RD;
                                else if(gate_check_pass) begin //gate process done
                                    if(rdcal_success)    //rdcal rdel calibration done
//                                        rdcal_state  <=  RDCALIB_DONE;
                                          rdcal_state  <= RDCAL_RDDATA_CHECK;
                                    else                
//                                        rdcal_state   <=  RDCAL_RDDATA_CHECK;
                                        rdcal_state   <= RDCAL_RDEL_MPR_PRE;
                                end
                                else if(bslip_start)
                                      rdcal_state  <= RDCAL_RDDATA_CHECK; 
                                else
                                      rdcal_state   <=  RDCAL_GATECAL_RD;
                            end
                            else
                                 rdcal_state  <= RDCAL_GATECAL_RST;
                         end
  //need add dqs_cal_error,when rdel adjust to boundary ,the calibration is fail.
      RDCAL_RDDATA_CHECK: begin
                             if(rddata_check_pass) begin       //read data check pass
                                 cnt   <= 'h0;
//                                 rdcal_state    <= RDCAL_RDEL_MPR_PRE; //ddr3
                                 rdcal_state    <= RDCALIB_DONE;
                             end
                             else if (cnt[5]) begin    /// key point,delay
                                 if(bslip_cnt[3] == 1)
                                 rdcal_state    <= RDCAL_ERROR;
                                 else 
                                 rdcal_state    <= RDCAL_BITSLIP;
//                                 rdcal_state    <= RDCAL_ERROR;
//                                    rdcal_state     <= RDCAL_RDEL_BASE_ADJ;
                                    cnt             <= 'h0;
                             end
                             else   begin
                                  rdcal_state   <= RDCAL_RDDATA_CHECK ;
                                  cnt           <= cnt + 1'b1; 
                             end
                         end

         RDCAL_BITSLIP: begin
            if(cnt[5]) begin
                rdcal_state    <= RDCAL_GATECAL_RST;
                cnt   <= 'h0;
            end
            else begin
                rdcal_state   <= RDCAL_BITSLIP ;
                cnt           <= cnt + 1'b1;
            end
        end
//     RDCAL_RDEL_BASE_ADJ: begin                                //reinit_adj_rdel = 1
//                            if (stop_with_error)               //manual stop
//                                  rdcal_state <= RDCAL_ERROR;
//                            else if (adj_rdel_done) begin      //adj_rdel_done
//                                    cnt        <= 0;
//                                    rdcal_state  <= RDCAL_GATECAL_STATRT;
//                            end
//                            else
//                               cnt <= cnt + 1;
//                         end

    RDCAL_RDEL_MPR_PRE: begin                                  //prechage all banks
                            if(cnt[2]) begin
                               cnt            <= 'h0 ;
                               rdcal_state    <= RDCAL_OPEN_MPR;
                            end
                            else  begin
                               rdcal_state    <= RDCAL_RDEL_MPR_PRE;
                               cnt            <= cnt + 1'b1;
                            end
                        end

            RDCAL_OPEN_MPR: begin                              //open MPR
                               if (cnt[4]) begin
                                  rdcal_state <= RDCAL_RDEL_CALIB;
                                  cnt         <= 'b0;
                               end
                               else begin
                                  cnt         <= cnt + 1'b1;
                               end
                            end  
                                                                                                                                    
            RDCAL_RDEL_CALIB: begin
                                if (rdel_rd_cnt==8'b0)         // for read data eye measure
                                   begin
                                     rdcal_state  <= RDCAL_RDEL_CALIB;
                                     cnt     <= cnt + 1'b1;
                                   end
                                else begin
                                  if(cnt==rdel_rd_cnt)
                                    rdcal_state  <= RDCAL_RDEL_TURN;
                                  else
                                    cnt          <= cnt +1'b1;
                                end
                              end

            RDCAL_RDEL_TURN: begin
                               if (rdel_calib_done) begin
                                  cnt         <= 'b0;
                                  rdcal_state  <= RDCAL_CLOSE_MPR;
                               end
                               else if (rdel_move_done) begin
                                  cnt         <= 0;
                                  rdcal_state <= RDCAL_RDEL_CALIB;
                               end
                               else if (~cnt[5]) //wait for remain data is finished
                                   cnt <= cnt + 1;
                            end

            RDCAL_CLOSE_MPR: begin
                                if (cnt[5]) begin
                                   cnt  <= 'b0;
                                   begin
                                     if (rdel_calib_error)
                                        rdcal_state <= RDCAL_ERROR;
                                     else
                                        rdcal_state <= RDCAL_REFRESH;
                                   end
                                end
                                else
                                   cnt <= cnt + 1;
                             end                       

            RDCAL_ERROR:  rdcal_state  <= RDCAL_ERROR;

    RDCAL_GATECAL_ERROR:  rdcal_state  <= RDCAL_GATECAL_ERROR ;
          

           RDCALIB_DONE: begin
                             if(cnt[3]) begin
                                rdcal_state <= RDCAL_IDLE;
                                cnt         <= 'h0;
                             end
                             else
                             cnt  <=  cnt + 1'b1;
                         end

            default:             rdcal_state <= RDCAL_IDLE;

          endcase
      end
    end
end

else  begin    //DDR2 LPDDR
////state
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if (!ddrphy_rst_n) begin
         rdcal_state        <= RDCAL_IDLE;
         cnt               <= 0;
      end
      else begin
         case (rdcal_state)
            RDCAL_IDLE: begin
                           cnt <= 0;
                           if (rdcal_start)
                                rdcal_state <= RDCAL_RDEL_INIT;
                         end

        RDCAL_RDEL_INIT: begin                                   //init_adj_rdel = 1
                              if (adj_rdel_done)                 //init adj rdel done
                                  rdcal_state <= RDCAL_REFRESH;
                         end

          RDCAL_REFRESH: begin                                   //refresh
                                cnt         <= 0;
                                rdcal_state <= RDCAL_REF_WAIT;
                         end

         RDCAL_REF_WAIT: begin
                              if(cnt_trfc_pass) begin            //delay trfc
                                 if(ref_cnt_done)  begin         //refresh 4
                                     rdcal_state   <= RDCAL_WR_ACT ;
                                       cnt         <= 0;
                                 end
                                 else
                                     rdcal_state   <= RDCAL_REFRESH;
                              end
                              else
                                      cnt          <= cnt + 1'b1;
                            end

            RDCAL_WR_ACT : begin                                 //active bank 0 row 0
                              if(cnt == TRCD) begin
                                   rdcal_state   <= RDCAL_WR;
                                   cnt           <= 'b0;
                               end
                               else
                                   cnt           <= cnt + 1'b1;
                            end

                RDCAL_WR : begin                                //write row 0 burst 4
                               if(cnt[2]) begin
                                      cnt      <=   'b0;
                                  begin
                                      if(write_debug)
                                         rdcal_state   <=  RDCAL_WR;
                                      else
                                         rdcal_state   <= RDCAL_GATECAL_STATRT;
                                  end
                               end
                               else
                                    cnt           <= cnt + 1'b1;
                           end
                           
     RDCAL_GATECAL_STATRT: begin                                //gatecal_start = 1
                              rdcal_state  <= RDCAL_GATECAL_RD;
                           end

        RDCAL_GATECAL_RD: begin                                 //read once
                             if(cnt[1]) begin
                                 cnt            <= 'b0;
                                 rdcal_state    <= RDCAL_GATE_CHECK ;
                             end
                             else
                             cnt  <=  cnt + 1'b1;
                         end
                         
        RDCAL_GATE_CHECK: begin
                             if (gate_adj_done)                 //single adjust complete  
                                  rdcal_state  <=  RDCAL_GATECAL_RST;
                             else if (gate_cal_error)           //gate fail
                                  rdcal_state  <=  RDCAL_GATECAL_ERROR ;
                             else
                                     rdcal_state  <=  RDCAL_GATE_CHECK ;
                          end

       RDCAL_GATECAL_RST: begin                                 //ddrphy_rst_req  = 1 
                            if(ddrphy_rst_ack_r[1]) begin       //gate_move_en = 1
                                if (dqgt_debug)
                                    rdcal_state <= RDCAL_GATECAL_RD;
                                else if(gate_check_pass) begin //gate process done
                                    if(rdcal_success)    //rdcal rdel calibration done
                                        rdcal_state  <=  RDCAL_RDDATA_CHECK;
                                    else                
                                        rdcal_state   <=  RDCAL_RDEL_CALIB;
                                end
                                else if(bslip_start)
                                      rdcal_state  <= RDCAL_RDDATA_CHECK;
                                else
                                      rdcal_state   <=  RDCAL_GATECAL_RD;
                            end
                            else
                                 rdcal_state  <= RDCAL_GATECAL_RST;
                         end          
                         
  //need add dqs_cal_error,when rdel adjust to boundary ,the calibration is fail.
      RDCAL_RDDATA_CHECK: begin
                             if(rddata_check_pass) begin   
                                 cnt   <= 'h0;
                                 rdcal_state    <= RDCALIB_DONE ;
                             end
                             else if (cnt[5]) begin    /// key point,delay
                                 if(bslip_cnt[3] == 1)
                                 rdcal_state    <= RDCAL_ERROR;
                                 else 
                                 rdcal_state    <= RDCAL_BITSLIP;
                                 cnt             <= 'h0;
                             end
                             else   begin
                                  rdcal_state   <= RDCAL_RDDATA_CHECK ;
                                  cnt           <= cnt + 1'b1; 
                             end
                         end

         RDCAL_BITSLIP: begin
            if(cnt[5]) begin
                rdcal_state    <= RDCAL_GATECAL_RST;
                cnt   <= 'h0;
            end
            else begin
                rdcal_state   <= RDCAL_BITSLIP ;
                cnt           <= cnt + 1'b1;
            end
        end
                                                                                                                                    
            RDCAL_RDEL_CALIB: begin
                                if(cnt==rdel_rd_cnt)
                                  rdcal_state  <= RDCAL_RDEL_TURN;
                                else
                                  cnt          <= cnt +1'b1;
                              end

            RDCAL_RDEL_TURN: begin
                               if (rdel_calib_done) begin
                                  cnt         <= 'b0;
                                  rdcal_state  <= RDCAL_RDEL_PRE ;
                               end
                               else if (rdel_move_done) begin
                                  cnt         <= 0;
                                  rdcal_state <= RDCAL_RDEL_CALIB;
                               end
                               else if (~cnt[5]) //wait for remain data is finished
                                   cnt <= cnt + 1;
                            end

           RDCAL_RDEL_PRE : begin
                               if (cnt[5]) begin    
                                  cnt    <= 'b0;
                                  begin                      
                                    if (rdel_calib_error)                   
                                      rdcal_state <= RDCAL_ERROR;  
                                    else                                    
                                     rdcal_state <= RDCAL_REFRESH;  
                                  end      
                               end                                        
                               else                                       
                                  cnt <= cnt + 1; 
                            end                        

            RDCAL_ERROR:  rdcal_state  <= RDCAL_ERROR;

    RDCAL_GATECAL_ERROR:  rdcal_state  <= RDCAL_GATECAL_ERROR ;

           RDCALIB_DONE: begin
                             if(cnt[3]) begin
                                rdcal_state <= RDCAL_IDLE;
                                cnt         <= 'h0;
                             end
                             else
                             cnt  <=  cnt + 1'b1;
                         end

            default:             rdcal_state <= RDCAL_IDLE;

          endcase
      end    
    end
end
endgenerate

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if (!ddrphy_rst_n)
    bslip_cnt <= 4'd0;
    else if(rdcal_state == RDCAL_IDLE)
    bslip_cnt <= 4'd0;
    else if((rdcal_state == RDCAL_RDDATA_CHECK) && cnt[5])
    bslip_cnt <= bslip_cnt + 4'd1;
  end
  
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if (!ddrphy_rst_n)
    bitslip_ctrl <= 0;
    else if((rdcal_state == RDCAL_BITSLIP)&& ((cnt[5:0] < 6'd2) || (cnt[5:0] == 6'd5) || (cnt[5:0] == 6'd6) ))
    bitslip_ctrl <= 1;
    else
    bitslip_ctrl <= 0;
  end

///output
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if (!ddrphy_rst_n)
       rdcal_success   <= 1'b0 ;
    else if(rdcal_state == RDCAL_IDLE)
       rdcal_success   <= 1'b0; 
//    else if (rddata_check_pass)
    else if (rdcal_state == RDCAL_RDEL_CALIB)
       rdcal_success   <= 1'b1;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if (!ddrphy_rst_n)
       bslip_start   <= 1'b0 ;
    else if(rdcal_state == RDCALIB_DONE)
       bslip_start   <= 1'b0; 
    else if (rdcal_state == RDCAL_BITSLIP)
       bslip_start   <= 1'b1;
  end
   
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)
          gatecal_start   <=  1'b0 ;
     else if((~dqgt_debug) & (ddrphy_rst_ack_r[1] & gate_check_pass))
          gatecal_start   <= 1'b0;
     else if(rdcal_state == RDCAL_GATECAL_STATRT)
          gatecal_start   <=  1'b1;
  end
     
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)
          gate_move_en    <= 1'b0 ;
     else if (ddrphy_rst_ack_r[1] & (rdcal_state == RDCAL_GATECAL_RST))
          gate_move_en    <= 1'b1;
     else 
          gate_move_en    <= 1'b0 ;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)
            rddata_cal   <=  1'b0;
     else if (rdcal_state == RDCAL_RDDATA_CHECK) begin
            if(~|cnt)
               rddata_cal   <= 1'b1 ;
            else if (cnt[5])
               rddata_cal   <= 1'b0 ;
     end
     else
         rddata_cal  <= 1'b0;
  end

///----------------rdel relate logic----------------------//////////
//adjust RDEL base setting
always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if (!ddrphy_rst_n) 
      init_adj_rdel     <= 1'b0;
   else 
      init_adj_rdel     <= (rdcal_state == RDCAL_RDEL_INIT) & (~adj_rdel_done);
end              

//*************************************************************************************
//adjust RDEL calibration
always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if (!ddrphy_rst_n) begin
      rdel_calibration <= 1'b0;
      rdel_move_en     <= 1'b0;
   end
   else begin
      rdel_calibration <= (rdcal_state == RDCAL_RDEL_CALIB) || (rdcal_state == RDCAL_RDEL_TURN);
      rdel_move_en     <= (rdcal_state == RDCAL_RDEL_TURN) && cnt[5];
   end
end   

/////------------------read calibration error----------------//////////
  assign rdcalib_error = ((rdcal_state == RDCAL_ERROR)||(rdcal_state ==RDCAL_GATECAL_ERROR));
///--------------------read calibration done--------------//////////
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
   if (!ddrphy_rst_n)
       rdcal_done   <=  1'b0;
   else if(rdcal_state == RDCALIB_DONE)
   begin
       if(cnt[2:0]==3'b111)
       rdcal_done   <=  1'b1;    
   end
   else
       rdcal_done   <=  1'b0;
 end         
    
 // assign rdcal_done    = (rdcal_state == RDCALIB_DONE);
////******************************************************************///
///rset state
///*******************************************************************///
///input
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if (!ddrphy_rst_n)
        ddrphy_rst_ack_r   <= 2'd0;
    else
        ddrphy_rst_ack_r   <= {ddrphy_rst_ack_r[0],ddrphy_rst_ack};
 end

///output
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if (!ddrphy_rst_n)
       ddrphy_rst_req     <= 1'b0;
    else
       ddrphy_rst_req     <= rdcal_state == RDCAL_GATECAL_RST;
 end      

//*******************DDR Command*************************************///
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)
        rdcal_odt   <= 1'b0;
     else if(rdcal_state == RDCAL_WR)
        rdcal_odt   <= 1'b1;
     else
        rdcal_odt   <= 1'b0;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)
        rdcal_cke   <= 1'b0;
     else
        rdcal_cke   <= 1'b1;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n) begin
        rdcal_cs_n       <= 1'b1;
        rdcal_ras_n      <= 1'b0;
        rdcal_cas_n      <= 1'b0;
        rdcal_we_n       <= 1'b0;
        rdcal_ba         <= {MEM_BANKADDR_WIDTH{1'b0}};
        rdcal_address    <= {MEM_ADDR_WIDTH{1'b0}};
     end
     else  begin
        rdcal_cs_n       <= 1'b1;
        rdcal_ras_n      <= 1'b1;
        rdcal_cas_n      <= 1'b1;
        rdcal_we_n       <= 1'b1;
        rdcal_ba         <= {MEM_BANKADDR_WIDTH{1'b0}};
        rdcal_address    <= {MEM_ADDR_WIDTH{1'b0}};
        case(rdcal_state)
           RDCAL_REFRESH : begin //ref
                             rdcal_cs_n       <= 1'b0;
                             rdcal_ras_n      <= 1'b0;
                             rdcal_cas_n      <= 1'b0;
                             rdcal_we_n       <= 1'b1;
                           end

          RDCAL_WR_ACT : begin //act
                           if(~|cnt)begin     //cnt = 0
                             rdcal_cs_n       <= 1'b0;
                             rdcal_ras_n      <= 1'b0;
                             rdcal_cas_n      <= 1'b1;
                             rdcal_we_n       <= 1'b1;
                           end
                         end

             RDCAL_WR : begin   //wr
                          //if(bl && (cnt[4:0] < 5'd4)) begin  
                          if(cnt[4:0] < 5'd2) begin
                               rdcal_cs_n            <= 1'b0;
                               rdcal_ras_n           <= 1'b1;
                               rdcal_cas_n           <= 1'b0;
                               rdcal_we_n            <= 1'b0;
                               rdcal_address         <= {{(MEM_ADDR_WIDTH-5){1'b0}},cnt[1:0],3'b000};
                            end
                        end

     RDCAL_GATECAL_RD: begin
                             if(cnt == 8'h0)
                               begin
                                  rdcal_cs_n            <= 1'b0;
                                  rdcal_ras_n           <= 1'b1;
                                  rdcal_cas_n           <= 1'b0;
                                  rdcal_we_n            <= 1'b1;
                               end
                         end
  
     RDCAL_RDDATA_CHECK: begin
                             if(cnt < 8'h2)
                               begin
                                  rdcal_cs_n            <= 1'b0;
                                  rdcal_ras_n           <= 1'b1;
                                  rdcal_cas_n           <= 1'b0;
                                  rdcal_we_n            <= 1'b1;
                               end
                          end

   RDCAL_RDEL_MPR_PRE: begin
                         if(~|cnt) begin
                             rdcal_cs_n            <= 1'b0;
                             rdcal_ras_n           <= 1'b0;
                             rdcal_cas_n           <= 1'b1;
                             rdcal_we_n            <= 1'b0;
                             rdcal_address         <= {{(MEM_ADDR_WIDTH-11){1'b0}},1'b1,10'h0};
                         end
                       end
                                                                                                                                                     
        RDCAL_OPEN_MPR : begin
                            if (~|cnt) begin
                                 rdcal_cs_n          <= 1'b0;
                                 rdcal_ras_n         <= 1'b0;
                                 rdcal_cas_n         <= 1'b0;
                                 rdcal_we_n          <= 1'b0;
                                 rdcal_address       <= {{(MEM_ADDR_WIDTH-3){1'b0}},1'b1,2'h0};
                                 rdcal_ba            <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'h3};
                            end
                         end

            RDCAL_RDEL_CALIB: begin  //rd
                                if(cnt < 8'd10 )
                                begin
                                    rdcal_cs_n          <= 1'b0;
                                    rdcal_ras_n         <= 1'b1;
                                    rdcal_cas_n         <= 1'b0;
                                    rdcal_we_n          <= 1'b1;
                                    rdcal_address       <= {{(MEM_ADDR_WIDTH-13){1'b0}},13'h8};
                                end 
                             end 
                                                                     
             RDCAL_RDEL_PRE: begin                                                   
                                 if(cnt== 8'd4) begin                     
                                     rdcal_cs_n          <= 1'b0 ;           
                                     rdcal_ras_n         <= 1'b0 ;           
                                     rdcal_cas_n         <= 1'b1 ;           
                                     rdcal_we_n          <= 1'b0 ;         
                                     rdcal_address       <= {{(MEM_ADDR_WIDTH-11){1'b0}},1'b1,10'h0};           
                                  end                                        
                              end 
                              
               RDCALIB_DONE:begin
                              if(~|cnt)begin
                                 rdcal_cs_n          <= 1'b0; 
                                 rdcal_ras_n         <= 1'b0; 
                                 rdcal_cas_n         <= 1'b1; 
                                 rdcal_we_n          <= 1'b0; 
                                 rdcal_address       <= {{(MEM_ADDR_WIDTH-11){1'b0}},1'b1,10'h0}; 
                              end
                            end

            RDCAL_CLOSE_MPR: begin
                               if (cnt[5:0]==6'd12) begin
                                  rdcal_cs_n          <= 1'b0;
                                  rdcal_ras_n         <= 1'b0;
                                  rdcal_cas_n         <= 1'b0;
                                  rdcal_we_n          <= 1'b0;
                                  rdcal_ba            <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'h3};
                               end
                            end
            endcase
     end
  end

////--------------------DDR data write---------------------------------///

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if (!ddrphy_rst_n) begin
   	  wr_enable  <= 1'b0;
   end
   else begin
   	  if (rdcal_state == RDCAL_WR) begin
   	     case (mc_wl[4:2])
            3'b000 : begin
                        if((cnt[4:0] == 5'd0)||(cnt[4:0] == 5'd1))
                           wr_enable  <= 1'b1;
                        else
                           wr_enable  <= 1'b0;
                      end
            3'b001 : begin
                       if((cnt[4:0] == 5'd1)||(cnt[4:0] == 5'd2))
   	                       wr_enable <= 1'b1;
   	                   else    	                        
                           wr_enable <= 1'b0;
                      end

            3'b010 : begin
                        if((cnt[4:0] == 5'd2)||(cnt[4:0] == 5'd3))
                           wr_enable   <= 1'b1;
                        else
                           wr_enable   <= 1'b0;
                      end

   	        3'b011 : begin
   	                    if((cnt[4:0] == 5'd3)||(cnt[4:0] == 5'd4))
   	                        wr_enable <= 1'b1;
   	                    else
   	                        wr_enable <= 1'b0;
   	                  end
   	        default:
   	                wr_enable <= 1'b0;
   	      endcase
   	   end
   	else
   	     wr_enable <= 1'b0;
  end
end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if (!ddrphy_rst_n) begin
       	  wr_enable_d <= 1'b0;
       	  wr_cnt      <= 2'h0;
       	  wr_cnt_d    <= 2'h0;
     end
    else begin
    	 wr_enable_d <= wr_enable;
    	 wr_cnt_d    <= wr_cnt;
    	 if (wr_enable)
    	    wr_cnt  <= wr_cnt + 2'h1;
    	 else
    	    wr_cnt  <= 2'h0;
    end
 end

  assign bus_wr_enable   = {4{wr_enable}};
  assign bus_wr_enable_d = {4{wr_enable_d}};

  assign bus_wr_data   = (wr_cnt == 2'd0) ? {{DFI_DQ_WIDTH/2{1'b0}}, {DFI_DQ_WIDTH/4{1'b1}}, {DFI_DQ_WIDTH/8{1'b0}},{DFI_DQ_WIDTH/8{1'b1}}} :
                         (wr_cnt == 2'd1) ? {{DFI_DQ_WIDTH/8{1'b1}},{DFI_DQ_WIDTH/8{1'b0}},{DFI_DQ_WIDTH/8{1'b1}},{DFI_DQ_WIDTH/8{1'b0}},{DFI_DQ_WIDTH/8{1'b1}}, {DFI_DQ_WIDTH/8{1'b0}}, {DFI_DQ_WIDTH/8{1'b1}},{DFI_DQ_WIDTH/8{1'b0}}} :
                         {{DFI_DQ_WIDTH/2{1'b0}}, {DFI_DQ_WIDTH/4{1'b1}}, {DFI_DQ_WIDTH/8{1'b0}},{DFI_DQ_WIDTH/8{1'b1}}};
                         
  assign bus_wr_data_d = (wr_cnt_d == 2'd0) ? {{DFI_DQ_WIDTH/2{1'b0}}, {DFI_DQ_WIDTH/4{1'b1}}, {DFI_DQ_WIDTH/8{1'b0}},{DFI_DQ_WIDTH/8{1'b1}}} :
                         (wr_cnt_d == 2'd1) ? {{DFI_DQ_WIDTH/8{1'b1}},{DFI_DQ_WIDTH/8{1'b0}},{DFI_DQ_WIDTH/8{1'b1}},{DFI_DQ_WIDTH/8{1'b0}},{DFI_DQ_WIDTH/8{1'b1}}, {DFI_DQ_WIDTH/8{1'b0}}, {DFI_DQ_WIDTH/8{1'b1}},{DFI_DQ_WIDTH/8{1'b0}}} :
                         {{DFI_DQ_WIDTH/2{1'b0}}, {DFI_DQ_WIDTH/4{1'b1}}, {DFI_DQ_WIDTH/8{1'b0}},{DFI_DQ_WIDTH/8{1'b1}}};

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) begin
        rdcal_wrdata_en  <= 4'b0000;
        rdcal_wrdata     <= {DFI_DQ_WIDTH{1'b0}};
     end
     else begin
        case (mc_wl[1:0])
            2'b00:begin
                rdcal_wrdata_en  <= bus_wr_enable;
                rdcal_wrdata     <= bus_wr_data;
            end
            2'b01:begin
                rdcal_wrdata_en  <= {bus_wr_enable[2:0], bus_wr_enable_d[3]};
                rdcal_wrdata     <= {bus_wr_data[DFI_DQ_WIDTH*3/4-1 : 0], bus_wr_data_d[DFI_DQ_WIDTH-1: DFI_DQ_WIDTH*3/4]};
            end
            2'b10:begin
                rdcal_wrdata_en <= {bus_wr_enable[1:0], bus_wr_enable_d[3:2]};
                rdcal_wrdata    <= {bus_wr_data[DFI_DQ_WIDTH*2/4-1 : 0], bus_wr_data_d[DFI_DQ_WIDTH-1: DFI_DQ_WIDTH*2/4]};
            end
            2'b11:begin
                rdcal_wrdata_en <= {bus_wr_enable[0],bus_wr_enable_d[3:1]};
                rdcal_wrdata    <= {bus_wr_data[DFI_DQ_WIDTH*1/4-1 : 0], bus_wr_data_d[DFI_DQ_WIDTH-1: DFI_DQ_WIDTH*1/4]};
            end
            default:begin
                rdcal_wrdata_en <= 4'b0000;
                rdcal_wrdata     <= {DFI_DQ_WIDTH{1'b0}};
            end
        endcase
     end
  end

 assign  dbg_rdcal = rdcal_state;   

endmodule

