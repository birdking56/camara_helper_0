////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_data_slice_wrcal_v1_9 (
  input        ddrphy_sysclk     ,
  input        ddrphy_rst_n      ,
  input        wrcal_position_dyn_adj,
  input  [7:0] init_wrcal_position,

  output reg   wrcal_check_pass  ,
  input        write_calibration ,
  input        wrcal_move_en     ,
  output reg   wrcal_move_done   ,
  input        wrdata_check_pass ,
  
  input        dll_rstn          ,
  input        dll_update_n      ,
  output reg   dll_update_code_done,
  input  [7:0] dll_90_gray       ,
  input  [7:0] wrlvl_step        ,
  output reg [7:0] dll_90_bin    ,
  output reg [7:0] wl_p_dll_gray ,
  output reg [7:0]  wl_p_dll_bin ,
  output       wl_p_ov           ,
  output [3:0] dbg_slice_wrcal_state,
  output reg   wrcal_error
);

  localparam IDLE            = 4'd0;  
  localparam INIT_ADJ        = 4'd1; 
  localparam CHECK_LEFT      = 4'd2; 
  localparam MOVE_LEFT       = 4'd3;
  localparam INIT_ADJ_AGAIN  = 4'd4;
  localparam ADJ_AGAIN_DONE  = 4'd5;
  localparam CHECK_RIGHT     = 4'd6; 
  localparam MOVE_RIGHT      = 4'd7; 
  localparam CENTER          = 4'd8;
  localparam CENTER_ADJ_DONE = 4'd9;
  localparam CENTER_WR       = 4'd10;
  localparam CALIB_WAIT      = 4'd11;
  localparam MOVE_DONE       = 4'd12;
  localparam WR_ERROR        = 4'd13;
  

`ifdef IPS_DDR_SPEEDUP_SIM 
localparam ADJ_STEP = 8'd5;
`else                   
localparam ADJ_STEP = 8'd1;
`endif

reg [3:0]  state;
reg [7:0]  cnt;
//reg [7:0]  wl_p_dll_bin;
reg        wrcal_ov;

wire [8:0] init_wl_p_step;
reg  [8:0] dq_step_add;
reg [7:0] dll_90_gray_d1;
reg [7:0] dll_90_gray_d2;
reg dll_update_d1;
wire dll_update_pos;
reg [7:0] dll_90_bin_d;
reg [3:0] delay_cnt;
wire [7:0] wrcal_step_plus;
wire [7:0] wrcal_step_minus;
wire [7:0] init_wrcal_value;
reg        wrcal_position_dyn_adj_d1;
wire       wrcal_position_dyn_adj_pos;

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if(!ddrphy_rst_n) 
        wrcal_position_dyn_adj_d1 <= 1'b0;
    else 
        wrcal_position_dyn_adj_d1 <= wrcal_position_dyn_adj;
end

assign wrcal_position_dyn_adj_pos = ~wrcal_position_dyn_adj_d1 & wrcal_position_dyn_adj;

always @(posedge ddrphy_sysclk or negedge dll_rstn)
begin
    if(!dll_rstn)
    begin
        state <= IDLE;
        cnt <= 8'd0;
    end
    else 
    begin
        case(state)
            IDLE       : begin
                cnt <= 8'd0;
                if(write_calibration)
                state <= INIT_ADJ;
                else 
                state <= IDLE;
            end
            
            INIT_ADJ   : begin
               state <= CHECK_LEFT;
               cnt <= 8'd0;
            end
            
            CHECK_LEFT : begin
                cnt <= 8'd0;
                if(~write_calibration)
                state <= IDLE;
                else if(wrcal_move_en)
                begin
                    if((~wrdata_check_pass)|| wrcal_ov)
                    state <= INIT_ADJ_AGAIN;
                    else
                    state <= MOVE_LEFT;
                end
            end
            
            MOVE_LEFT  : begin
               if (cnt[3]) begin
                  if (~wrcal_move_en)
                     state <= CHECK_LEFT;
                  end
                  else
                  cnt <= cnt + 1;
               end
               
            INIT_ADJ_AGAIN   : begin
               if (cnt[3]) begin
//                  if (wl_p_dll_bin == init_wl_p_step)
                     state <= ADJ_AGAIN_DONE;
                  end
                  else
                  cnt <= cnt + 1;
            end

            ADJ_AGAIN_DONE : begin
               cnt <= 8'd0;
               if(~wrcal_move_en)
               state <= CHECK_RIGHT;
            end
            
            CHECK_RIGHT: begin
                cnt <= 8'd0;
                if(wrcal_move_en)
                begin
                    if((~wrdata_check_pass)|| wrcal_ov)
                    state <= CENTER;
                    else
                    state <= MOVE_RIGHT;
                end               
            end
            
            MOVE_RIGHT : begin
               if (cnt[3]) begin
                  if (~wrcal_move_en)
                     state <= CHECK_RIGHT;
                  end
                  else
                  cnt <= cnt + 1;              
            end
            
            CENTER     : begin
               if (cnt[3]) begin
//                  if (wl_p_dll_bin == dq_step_add[8:1])
                     state <= CENTER_ADJ_DONE;
                  end
                  else
                  cnt <= cnt + 1;                
            end
            
            CENTER_ADJ_DONE: begin
               cnt <= 8'd0;
               if(~wrcal_move_en)
               state <= CENTER_WR;
            end
            
            CENTER_WR : begin
                cnt <= 8'd0;
                if(wrcal_move_en)
                begin
                    if(wrdata_check_pass)
                    state <= CALIB_WAIT;
                    else
                    state <= WR_ERROR;
                end               
            end
            
            CALIB_WAIT : begin
                cnt <= 8'd0;
                if(~write_calibration)
                state <= MOVE_DONE;
                else 
                state <= CALIB_WAIT;               
            end
            
            MOVE_DONE : begin
                cnt <= 8'd0;
                if(write_calibration)
                state <= IDLE;                
            end
            
            WR_ERROR: state <= WR_ERROR; 
            default:
            state <= IDLE;
    endcase
    end
end

always @(posedge ddrphy_sysclk or negedge dll_rstn)
begin
  if(!dll_rstn) begin
      wl_p_dll_bin <= 8'd0;
      wrcal_ov <= 0;
  end
  else begin
        case (state)
           IDLE : begin
              wl_p_dll_bin <= init_wl_p_step[7:0];
              wrcal_ov <= 0;
           end
           //INIT_ADJ   : begin
           //    wrcal_ov <= 0;
           //    if(wrcal_position_dyn_adj_pos)
           //        if(init_wrcal_position[7])
           //            wl_p_dll_bin <= init_wl_p_step - {1'b0,init_wrcal_position[6:0]};
           //        else
           //            wl_p_dll_bin <= init_wl_p_step + {1'b0,init_wrcal_position[6:0]};
           //    else
           //        wl_p_dll_bin <= init_wl_p_step;
           //end
           INIT_ADJ: begin
              wl_p_dll_bin <= init_wl_p_step[7:0];
              wrcal_ov <= 0;
           end
           INIT_ADJ_AGAIN: begin
              wrcal_ov <= 0;
  //            if(wl_p_dll_bin < init_wl_p_step)
  //            wl_p_dll_bin <= wl_p_dll_bin + 8'd1;
  //            else if(wl_p_dll_bin > init_wl_p_step)
  //            wl_p_dll_bin <= wl_p_dll_bin - 8'd1;
              wl_p_dll_bin <= init_wl_p_step[7:0];
           end
           MOVE_LEFT: begin
              if(cnt == 8'h0) begin
                  if(wl_p_dll_bin > (ADJ_STEP - 8'd1)) begin
                      wl_p_dll_bin <= wl_p_dll_bin - ADJ_STEP;
                      wrcal_ov <= 0;
                  end
                  else begin
                      wl_p_dll_bin <= wl_p_dll_bin;
                      wrcal_ov <= 1;
                  end
             end
           end       
           MOVE_RIGHT: begin
              if(cnt == 8'h0) begin
                  if(wl_p_dll_bin < (8'd255 - ADJ_STEP)) begin
                      wl_p_dll_bin <= wl_p_dll_bin + ADJ_STEP;
                      wrcal_ov <= 0;
                  end
                  else begin
                      wl_p_dll_bin <= wl_p_dll_bin;
                      wrcal_ov <= 1;
                  end
              end
           end
           CENTER: begin
              wrcal_ov <= 0;
  //            if(wl_p_dll_bin < dq_step_add[8:1])
  //            wl_p_dll_bin <= wl_p_dll_bin + 8'd1;
  //            else if(wl_p_dll_bin > dq_step_add[8:1])
  //            wl_p_dll_bin <= wl_p_dll_bin - 8'd1;
              wl_p_dll_bin <= dq_step_add[8:1];
           end         
           MOVE_DONE: begin
               wrcal_ov <= 0;
               if(wrcal_position_dyn_adj_pos)
                   if(init_wrcal_position[7])
                       wl_p_dll_bin <= wl_p_dll_bin - {1'b0,init_wrcal_position[6:0]};
                   else
                       wl_p_dll_bin <= wl_p_dll_bin + {1'b0,init_wrcal_position[6:0]};
               else
                   wl_p_dll_bin <= wl_p_dll_bin;
           end         
           default: begin
              wl_p_dll_bin <= wl_p_dll_bin;
              wrcal_ov <= wrcal_ov;
           end
        endcase
          
  end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if(!ddrphy_rst_n)
   wrcal_check_pass <= 0;
   else if(state == CALIB_WAIT)
   wrcal_check_pass <= 1;
   else
   wrcal_check_pass <= 0;
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if(!ddrphy_rst_n)
   wrcal_move_done <= 0;
   else if(wrcal_check_pass == 1)
   wrcal_move_done <= 1;
   else if(((state == MOVE_LEFT) & cnt[3])|((state == MOVE_RIGHT) & cnt[3]) |
            (state == ADJ_AGAIN_DONE) | (state == CENTER_ADJ_DONE) | (state == CALIB_WAIT))
   wrcal_move_done <= 1;
   else
   wrcal_move_done <= 0;
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
  if(!ddrphy_rst_n) begin
      dq_step_add <= 9'd0;
  end
  else begin
      if(state == IDLE)
      dq_step_add <= 9'd0;
      else if((state == CHECK_LEFT)&&(wrcal_move_en)&&((~ wrdata_check_pass) || wrcal_ov))
      dq_step_add <= dq_step_add + wl_p_dll_bin;
      else if((state == CHECK_RIGHT)&&(wrcal_move_en)&&((~ wrdata_check_pass) || wrcal_ov))
      dq_step_add <= dq_step_add + wl_p_dll_bin;
  end
end

always @(posedge ddrphy_sysclk or negedge dll_rstn)
begin 
    if(!dll_rstn)
       dll_update_d1 <= 0;
    else
       dll_update_d1 <= dll_update_n;
end

assign dll_update_pos = (~dll_update_d1) & dll_update_n;

always @(posedge ddrphy_sysclk or negedge dll_rstn)
begin 
    if(!dll_rstn)
    delay_cnt <= 4'd0;
    else if(dll_update_pos)
    delay_cnt <= 4'd0;
    else if(delay_cnt < 4'd3)
    delay_cnt <= delay_cnt + 4'd1;
end

always @(posedge ddrphy_sysclk or negedge dll_rstn)
begin 
    if(!dll_rstn)
    dll_update_code_done <= 0;
    else if(delay_cnt == 4'd3)
    dll_update_code_done <= 1;
    else
    dll_update_code_done <= 0;
end

always @(posedge ddrphy_sysclk or negedge dll_rstn)
begin 
    if(!dll_rstn) begin
       dll_90_gray_d1 <= 8'd0;
       dll_90_gray_d2 <= 8'd0;
    end
    else begin
       dll_90_gray_d1 <= dll_90_gray;
       dll_90_gray_d2 <= dll_90_gray_d1;
    end
end

always @(posedge ddrphy_sysclk or negedge dll_rstn)
begin 
    if(!dll_rstn)
    dll_90_bin_d <= 8'd0;
    else begin
       dll_90_bin_d[7] <= dll_90_gray_d2[7];
       dll_90_bin_d[6] <= dll_90_bin_d[7]^dll_90_gray_d2[6];
       dll_90_bin_d[5] <= dll_90_bin_d[6]^dll_90_gray_d2[5];
       dll_90_bin_d[4] <= dll_90_bin_d[5]^dll_90_gray_d2[4];
       dll_90_bin_d[3] <= dll_90_bin_d[4]^dll_90_gray_d2[3];
       dll_90_bin_d[2] <= dll_90_bin_d[3]^dll_90_gray_d2[2];
       dll_90_bin_d[1] <= dll_90_bin_d[2]^dll_90_gray_d2[1];
       dll_90_bin_d[0] <= dll_90_bin_d[1]^dll_90_gray_d2[0];
    end
end

always @(posedge ddrphy_sysclk or negedge dll_rstn)
begin 
    if(!dll_rstn)
    dll_90_bin <= 8'd0;
    else if(dll_update_code_done == 1)
    dll_90_bin <= dll_90_bin_d;
end
 
 assign   wrcal_step_plus  = dll_90_bin + {1'b0,init_wrcal_position[6:0]};
 assign   wrcal_step_minus = dll_90_bin - {1'b0,init_wrcal_position[6:0]};
 
assign init_wrcal_value = init_wrcal_position[7] ? (wrcal_step_minus[7] ? 8'h0 : wrcal_step_minus ):
                                                   (wrcal_step_plus[7]? 8'h7f :wrcal_step_plus ) ;  

assign init_wl_p_step = {1'b0,init_wrcal_value} + {1'b0,wrlvl_step};
assign wl_p_ov = init_wl_p_step[8];

always @(posedge ddrphy_sysclk or negedge dll_rstn)
begin
   if(!dll_rstn)
   wl_p_dll_gray <= 8'd0;
   else begin
       wl_p_dll_gray[7] <= wl_p_dll_bin[7];
       wl_p_dll_gray[6] <= wl_p_dll_bin[7]^wl_p_dll_bin[6];
       wl_p_dll_gray[5] <= wl_p_dll_bin[6]^wl_p_dll_bin[5];
       wl_p_dll_gray[4] <= wl_p_dll_bin[5]^wl_p_dll_bin[4];
       wl_p_dll_gray[3] <= wl_p_dll_bin[4]^wl_p_dll_bin[3];
       wl_p_dll_gray[2] <= wl_p_dll_bin[3]^wl_p_dll_bin[2];
       wl_p_dll_gray[1] <= wl_p_dll_bin[2]^wl_p_dll_bin[1];
       wl_p_dll_gray[0] <= wl_p_dll_bin[1]^wl_p_dll_bin[0];
   end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if(!ddrphy_rst_n) 
        wrcal_error <= 1'b0;
    else if(state == WR_ERROR)
        wrcal_error <= 1'b1;
    else 
        wrcal_error <= 1'b0;
end

assign dbg_slice_wrcal_state = state;

endmodule
