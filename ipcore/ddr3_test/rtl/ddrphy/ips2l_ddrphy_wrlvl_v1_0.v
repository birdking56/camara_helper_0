////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module   ips2l_ddrphy_wrlvl_v1_0 #(
  parameter [7:0]   TMOD        = 8'd3,
  parameter [7:0]   TRFC        = 8'd16,
  parameter MEM_ADDR_WIDTH      = 16,
  parameter MEM_BANKADDR_WIDTH  = 3
)(

  input [15:0]       mr1_ddr3       ,
  input              ddrphy_sysclk  ,
  input              ddrphy_rst_n   ,

  input              wrlvl_start    ,
  output reg         wrlvl_done     ,
  input              wrlvl_error    ,

  output reg         wrlvl_dqs_req  ,
  input              wrlvl_dqs_resp ,

  output [3:0]       dbg_wrlvl      ,

  output reg [MEM_BANKADDR_WIDTH-1:0]   wrlvl_ba       ,
  output reg [MEM_ADDR_WIDTH-1:0]       wrlvl_address  ,
  output reg  wrlvl_cs_n     ,
  output reg  wrlvl_ras_n    ,
  output reg  wrlvl_cas_n    ,
  output reg  wrlvl_we_n     ,
  output reg  wrlvl_cke      ,
  output reg  wrlvl_odt
 );

  localparam   WRLVL_IDLE          = 4'd0;
  localparam   WRLVL_LOAD_MR1      = 4'd1;
  localparam   WRLVL_WAIT_DQSEN    = 4'd2;
  localparam   WRLVL_TRAIN_STATRT  = 4'd3;
  localparam   WRLVL_WAIT          = 4'd4;
  localparam   WRLVL_ODT_WAIT      = 4'd5;
  localparam   WRLVL_LOAD_MR1_WAIT = 4'd6;
  localparam   WRLVL_TRAIN_DONE    = 4'd7;
  localparam   WRLVL_TRAIN_ERROR   = 4'd8;

  reg [3:0]  wrlvl_state        ;
  reg [3:0]  wrlvl_next_state   ;

  reg [7:0]  cmd_cnt ;

  reg        cnt_tmod_pass ;
  reg        cnt_twldqsen_pass ;
  reg        wrlvl_dqs_resp_r ;

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
         wrlvl_state  <= WRLVL_IDLE ;
      else
         wrlvl_state  <= wrlvl_next_state ;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
          cmd_cnt   <= 8'b0;
      else
        case(wrlvl_next_state)
            WRLVL_WAIT_DQSEN,
            WRLVL_LOAD_MR1_WAIT,
            WRLVL_ODT_WAIT: cmd_cnt <= cmd_cnt + 8'b1;
            default       : cmd_cnt   <= 8'b0;
        endcase
  end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n)
       wrlvl_dqs_resp_r  <= 1'b0;
    else if(wrlvl_next_state == WRLVL_IDLE)
       wrlvl_dqs_resp_r  <= 1'b0;
    else if(wrlvl_dqs_resp)               //write leveling training done
       wrlvl_dqs_resp_r  <= 1'b1;   
 end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
       cnt_tmod_pass   <= 1'b0;
    else
       cnt_tmod_pass   <= (cmd_cnt == TMOD);
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
       cnt_twldqsen_pass  <= 1'b0;
    else
       cnt_twldqsen_pass <= cmd_cnt[5] ;  //twldqsen:25   32
  end

  always @(*) 
  begin
       wrlvl_next_state =  WRLVL_IDLE ;
    case(wrlvl_state)
         WRLVL_IDLE : if(wrlvl_start)
                           wrlvl_next_state = WRLVL_LOAD_MR1 ;

        WRLVL_LOAD_MR1 : if(wrlvl_dqs_resp_r)                         //write leveling training done
                              wrlvl_next_state = WRLVL_LOAD_MR1_WAIT;
                         else
                              wrlvl_next_state = WRLVL_WAIT_DQSEN;

        WRLVL_WAIT_DQSEN : begin
                              if(cnt_twldqsen_pass)                   //delay twldqsen
                                 wrlvl_next_state = WRLVL_TRAIN_STATRT;
                              else
                                 wrlvl_next_state = WRLVL_WAIT_DQSEN;
                           end

        WRLVL_TRAIN_STATRT :   wrlvl_next_state = WRLVL_WAIT ;        //training start,wrlvl_dqs_req = 1

        WRLVL_WAIT :    begin                                         //write leveling training process
                           if(wrlvl_error)
                                 wrlvl_next_state = WRLVL_TRAIN_ERROR;
                           else if(wrlvl_dqs_resp)                         //write leveling training done
                                 wrlvl_next_state = WRLVL_ODT_WAIT;
                           else
                                 wrlvl_next_state = WRLVL_WAIT;
                        end

        WRLVL_ODT_WAIT : begin                                       //delay
                            if(cmd_cnt[4])
                                wrlvl_next_state = WRLVL_LOAD_MR1;
                            else
                                wrlvl_next_state = WRLVL_ODT_WAIT;
                         end

        WRLVL_LOAD_MR1_WAIT :begin
                               if(cnt_tmod_pass)            //delay tmod
                                  wrlvl_next_state = WRLVL_TRAIN_DONE ;
                               else
                                  wrlvl_next_state = WRLVL_LOAD_MR1_WAIT;
                             end

        WRLVL_TRAIN_DONE :     wrlvl_next_state = WRLVL_IDLE ;   
        
        WRLVL_TRAIN_ERROR :begin
                               wrlvl_next_state = WRLVL_TRAIN_ERROR ;
                           end

    endcase
  end


  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
          wrlvl_cke   <= 1'b0;
      else
          wrlvl_cke   <= 1'b1;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
        wrlvl_odt   <= 1'b0;
      else if ((wrlvl_next_state ==WRLVL_WAIT_DQSEN) & (cmd_cnt == TMOD))
        wrlvl_odt   <= 1'b1;
      else if(wrlvl_dqs_resp)
        wrlvl_odt   <= 1'b0;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)  begin
          wrlvl_ba       <= {MEM_BANKADDR_WIDTH{1'b0}};
          wrlvl_address  <= {MEM_ADDR_WIDTH{1'b0}};
          wrlvl_cs_n     <= 1'b1;
          wrlvl_ras_n    <= 1'b1;
          wrlvl_cas_n    <= 1'b1;
          wrlvl_we_n     <= 1'b1;
      end
      else
        case(wrlvl_next_state)
           WRLVL_LOAD_MR1  : begin
                                 wrlvl_cs_n      <= 1'b0;
                                 wrlvl_ras_n     <= 1'b0;
                                 wrlvl_cas_n     <= 1'b0;
                                 wrlvl_we_n      <= 1'b0;
                                 wrlvl_ba        <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b01};
                               begin
                                 if(wrlvl_dqs_resp_r)
                                    wrlvl_address  <= {{(MEM_ADDR_WIDTH-13){1'b0}},mr1_ddr3[12:8],1'b0,mr1_ddr3[6:0]}; //write leveling disable
                                else
                                    wrlvl_address  <= {{(MEM_ADDR_WIDTH-13){1'b0}},mr1_ddr3[12:8],1'b1,mr1_ddr3[6:0]}; //write leveling enable
                              end
                            end

         default      :  begin
                            wrlvl_cs_n      <= 1'b1;
                            wrlvl_ras_n     <= 1'b1;
                            wrlvl_cas_n     <= 1'b1;
                            wrlvl_we_n      <= 1'b1;
                            wrlvl_ba        <= {MEM_BANKADDR_WIDTH{1'b0}};
                            wrlvl_address   <= {MEM_ADDR_WIDTH{1'b0}};
                         end
     endcase
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
       wrlvl_dqs_req   <= 1'b0;
   else if (wrlvl_dqs_resp)            ///clear wrlvl_dqs_req
       wrlvl_dqs_req   <= 1'b0;
    else if(wrlvl_next_state == WRLVL_TRAIN_STATRT)
       wrlvl_dqs_req   <= 1'b1;
  end


  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
       wrlvl_done   <= 1'b0;
    else
       wrlvl_done   <= (wrlvl_next_state == WRLVL_TRAIN_DONE);
  end

  assign  dbg_wrlvl  = wrlvl_next_state;

endmodule
