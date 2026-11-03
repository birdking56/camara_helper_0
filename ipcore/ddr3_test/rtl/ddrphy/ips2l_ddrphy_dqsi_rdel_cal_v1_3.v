////////////////////////////////////////////////////////////////        
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                           
// ALL RIGHTS REVERVED.                                                  
////////////////////////////////////////////////////////////////        
//Description:                                                          
//Author:  wxxiao                                                       
//History: v1.0                                                         
////////////////////////////////////////////////////////////////    
`timescale 1ns/1ns
module ips2l_ddrphy_dqsi_rdel_cal_v1_3  #(
    parameter MIN_DQSI_WIN      = 9'd10
)(
    input            force_samp_position  ,
    input            samp_position_dyn_adj  ,
    input [7:0]      init_samp_position_even, 
    input [7:0]      init_samp_position_odd,

    input            ddrphy_sysclk        ,
    input            ddrphy_rst_n         ,
    input [7:0]      dll_90_bin           ,
    
    input            rdel_rvalid0         ,
    input            rdel_rvalid1         ,
    input            init_adj_rdel        ,
    output  reg      adj_rdel_done        ,
    
    input            rdel_calibration     ,
    output reg       rdel_calib_done      ,
    output reg       rdel_calib_error     ,
    
    input            rdel_move_en         ,
    output reg       rdel_move_done       ,
    
    input            eye_calibration      ,
    output reg       eyecal_check_pass    ,
    output           eyecal_move_done     ,
    input            eyecal_move_en       ,
    
    output reg       rdel_cal_vld         ,
    output reg [7:0] dqs_even_gray        ,
    output reg [7:0] dqs_odd_gray         ,
    output wire [7:0] dqs_even_bin        ,
    output wire [7:0] dqs_odd_bin         ,
    output reg [8:0] total_margin_even    ,
    output reg [8:0] total_margin_odd     ,
    
    output reg [7:0] idly_set             ,
    output     [3:0] dbg_slice_rdcal_state
              
);

`ifdef IPS_DDR_SPEEDUP_SIM 
localparam ADJ_STEP = 8'd5;
`else                      
localparam ADJ_STEP = 8'd1;
`endif

localparam IDLE            = 4'd0;
localparam INIT_RST        = 4'd1;
localparam INIT_ADJ        = 4'd2;
localparam ADJ_WAIT        = 4'd3;
localparam CHECK_LEFT      = 4'd4;
localparam MOVE_LEFT       = 4'd5;
localparam JUMP_RST        = 4'd6;
localparam JUMP            = 4'd7;
localparam CHECK_RIGHT     = 4'd8;
localparam MOVE_RIGHT      = 4'd9;
localparam CENTER          = 4'd10;
localparam CALIB_WAIT      = 4'd11;

reg [7:0]    dqs_delay_even;
reg [7:0]    dqs_delay_odd;
reg [7:0]    idly_set_even;
reg [7:0]    idly_set_odd;
reg [8:0]    total_delay_even;
reg [8:0]    total_delay_odd;
reg move_stop_even;
reg move_stop_odd;
reg rdel_ov_even;
reg rdel_ov_odd;
reg [3:0]    state;
reg [7:0]    cnt;
wire  [7:0]  init_dqsi_value_even;  
wire  [7:0]  init_dqsi_value_odd;
//wire rdel_rvalid;
reg rdel_calibration_d;
wire rdel_calibration_rising;  
reg eye_calibration_d    ;
wire eye_calibration_rising ;
reg        samp_position_dyn_adj_d1;
wire samp_position_dyn_adj_pos;
 
// assign rdel_rvalid = rdel_rvalid0|rdel_rvalid1;
 assign dqsi_move_en = rdel_move_en | eyecal_move_en;
 assign eyecal_move_done = rdel_move_done;
 
 wire  [7:0]  dqsi_step_minus_even;
 wire  [7:0]  dqsi_step_plus_even;   
 wire  [7:0]  dqsi_step_minus_odd;
 wire  [7:0]  dqsi_step_plus_odd; 
 
 assign   dqsi_step_plus_even  = dll_90_bin + {1'b0,init_samp_position_even[6:0]};
 assign   dqsi_step_minus_even = dll_90_bin - {1'b0,init_samp_position_even[6:0]};
 
 assign   dqsi_step_plus_odd  = dll_90_bin + {1'b0,init_samp_position_odd[6:0]};
 assign   dqsi_step_minus_odd = dll_90_bin - {1'b0,init_samp_position_odd[6:0]}; 

assign init_dqsi_value_even = init_samp_position_even[7] ? (dqsi_step_minus_even[7] ? 8'h0 : dqsi_step_minus_even ) :(dqsi_step_plus_even[7]? 8'h7f :dqsi_step_plus_even ) ;  
assign init_dqsi_value_odd = init_samp_position_odd[7] ? (dqsi_step_minus_odd[7] ? 8'h0 : dqsi_step_minus_odd ) :(dqsi_step_plus_odd[7]? 8'h7f :dqsi_step_plus_odd ) ; 

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if(!ddrphy_rst_n) 
        samp_position_dyn_adj_d1 <= 1'b0;
    else 
        samp_position_dyn_adj_d1 <= samp_position_dyn_adj;
end

assign samp_position_dyn_adj_pos = ~samp_position_dyn_adj_d1 & samp_position_dyn_adj;

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if(!ddrphy_rst_n) begin
      state <= IDLE;
      cnt   <= 8'd0;
   end
   else begin
      case (state)
         IDLE: begin
            cnt   <= 0;
            if (init_adj_rdel)
               state <= INIT_RST;
            else if ((rdel_calibration | eye_calibration) & (~force_samp_position))
               state <= CHECK_LEFT;
         end
         INIT_RST: begin
            if (cnt[3]) begin
               cnt   <= 0;
               state <= INIT_ADJ;               
            end
            else
               cnt   <= cnt + 1;
         end
         INIT_ADJ: begin
            if (cnt[2])
               state <= ADJ_WAIT;
            else
               cnt <= cnt + 1;
         end
         ADJ_WAIT: begin
            state <= IDLE;
         end         
         CHECK_LEFT: begin
            cnt   <= 0;
            if (dqsi_move_en) begin
               if ((move_stop_even|rdel_ov_even) && (move_stop_odd|rdel_ov_odd ))
                  state <= JUMP_RST;
               else
                  state <= MOVE_LEFT;               
            end   
         end
         MOVE_LEFT: begin
            if (cnt[3]) begin
               if (~dqsi_move_en)
                  state <= CHECK_LEFT;
            end
            else
               cnt <= cnt + 1;
         end
         JUMP_RST: begin
            if (cnt[3]) begin
               cnt   <= 0;
               state <= JUMP;               
            end
            else
               cnt   <= cnt + 1;            
         end
         JUMP: begin
            if (cnt[2]) begin
               if (~dqsi_move_en)
                  state <= CHECK_RIGHT;
            end
            else
               cnt <= cnt + 1;
         end
         CHECK_RIGHT: begin
            cnt   <= 0;
            if (dqsi_move_en) begin
               if ((move_stop_even|rdel_ov_even) && (move_stop_odd|rdel_ov_odd ))
                  state <= CENTER;
               else 
                  state <= MOVE_RIGHT;            
            end
         end
         MOVE_RIGHT: begin
            if (cnt[3]) begin
               if (~dqsi_move_en)
                  state <= CHECK_RIGHT;
            end
            else
               cnt <= cnt + 1;
         end
         CENTER: begin
            if (cnt[3]) begin
               if (~dqsi_move_en)
                  state <= CALIB_WAIT;
            end
            else
               cnt <= cnt + 1;
         end
         CALIB_WAIT: begin
            if ((~rdel_calibration)&&(~eye_calibration))
               state <= IDLE;
         end
         default: begin
            state <= IDLE;
         end
      endcase
   end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if(!ddrphy_rst_n)
    move_stop_even <= 0;
    else if((state == CHECK_LEFT)&&(dqsi_move_en)&&(!rdel_rvalid0))
    move_stop_even <= 1;
    else if((state == CHECK_RIGHT)&&(dqsi_move_en)&&(!rdel_rvalid0))
    move_stop_even <= 1;
    else if((state == IDLE)||(state == JUMP_RST))
    move_stop_even <= 0;
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if(!ddrphy_rst_n)
    move_stop_odd <= 0;
    else if((state == CHECK_LEFT)&&(dqsi_move_en)&&(!rdel_rvalid1))
    move_stop_odd <= 1;
    else if((state == CHECK_RIGHT)&&(dqsi_move_en)&&(!rdel_rvalid1))
    move_stop_odd <= 1;
    else if((state == IDLE)||(state == JUMP_RST))
    move_stop_odd <= 0;
end


always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
  if(!ddrphy_rst_n) begin
      dqs_delay_even <= 8'd0;
      idly_set_even <= 8'd0;
      rdel_ov_even <= 0;
  end
  else begin
        case (state)
           IDLE    : begin
               idly_set_even <= 8'd0;
               rdel_ov_even <= 1'b0;
               if(samp_position_dyn_adj_pos)
                   if(init_samp_position_even[7])
                       dqs_delay_even <= dqs_delay_even - {1'b0,init_samp_position_even[6:0]};
                   else
                       dqs_delay_even <= dqs_delay_even + {1'b0,init_samp_position_even[6:0]};
               else
                   dqs_delay_even <= dqs_delay_even;
           end
           INIT_RST: begin
              dqs_delay_even <= init_dqsi_value_even;
              idly_set_even <= 8'd0;
              rdel_ov_even <= 0;
           end
           MOVE_LEFT: begin
              if((cnt == 'h0)&&(move_stop_even == 0)) begin
                  if(dqs_delay_even > (ADJ_STEP - 8'd1)) begin
                      dqs_delay_even <= dqs_delay_even - ADJ_STEP;
                      idly_set_even <= 8'd0;
                      rdel_ov_even <= 0;
                  end
                  else if (dqs_delay_even == 8'd0)                 
                  begin
                      if(idly_set_even < (8'd255 - ADJ_STEP))
                      begin
                         rdel_ov_even <= 0;
                         idly_set_even <= idly_set_even + ADJ_STEP;
                      end
                      else begin
                         rdel_ov_even <= 1;
                         idly_set_even <= 8'd255;
                      end
                  end
                  else 
                  begin
                      dqs_delay_even <= 8'd0;
                      idly_set_even <= idly_set_even;
                      rdel_ov_even <= rdel_ov_even; 
                  end
             end
           end
           JUMP_RST: begin //same as INIT_RST
              dqs_delay_even <= init_dqsi_value_even;
              rdel_ov_even <= 0;
           end         
           MOVE_RIGHT: begin
              if((cnt == 'h0)&&(move_stop_even == 0)) begin
                  if(dqs_delay_even < (8'd255 - ADJ_STEP)) begin
                      dqs_delay_even <= dqs_delay_even + ADJ_STEP;
                      rdel_ov_even <= 0;
                  end
                  else begin
                      dqs_delay_even <= 8'd255;
                      rdel_ov_even <= 1;
                  end
              end
           end
           CENTER: begin
              dqs_delay_even <= total_delay_even[8:1] - {1'b0,idly_set_even[7:1]};
              rdel_ov_even <= 0;
           end         
           default: begin
              dqs_delay_even <= dqs_delay_even;
              idly_set_even <= idly_set_even;
              rdel_ov_even <= rdel_ov_even;
           end
        endcase
  end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
  if(!ddrphy_rst_n) begin
      total_delay_even <= 9'd0;
  end
  else begin
      if(state == IDLE)
      total_delay_even <= 9'd0;
      else if((state == CHECK_LEFT)&&(dqsi_move_en)&&(move_stop_even|rdel_ov_even)&&(move_stop_odd|rdel_ov_odd ))
      total_delay_even <= total_delay_even + dqs_delay_even;
      else if((state == CHECK_RIGHT)&&(dqsi_move_en)&&(move_stop_even|rdel_ov_even)&&(move_stop_odd|rdel_ov_odd ))
      total_delay_even <= total_delay_even + dqs_delay_even;
  end      
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if(!ddrphy_rst_n) begin
       dqs_delay_odd <= 8'd0;
       idly_set_odd <= 8'd0;
       rdel_ov_odd <= 0;
   end
   else begin
         case (state)
           IDLE    : begin
               idly_set_odd <= 8'd0;
               rdel_ov_odd <= 1'b0;
               if(samp_position_dyn_adj_pos)
                   if(init_samp_position_odd[7])
                       dqs_delay_odd <= dqs_delay_odd - {1'b0,init_samp_position_odd[6:0]};
                   else
                       dqs_delay_odd <= dqs_delay_odd + {1'b0,init_samp_position_odd[6:0]};
               else
                   dqs_delay_odd <= dqs_delay_odd;
           end
            INIT_RST: begin
               dqs_delay_odd <= init_dqsi_value_odd;
               idly_set_odd <= 8'd0;
               rdel_ov_odd <= 0;
            end
            MOVE_LEFT: begin
               if((cnt == 'h0)&&(move_stop_odd == 0)) begin
                   if(dqs_delay_odd > (ADJ_STEP - 8'd1)) begin
                       dqs_delay_odd <= dqs_delay_odd - ADJ_STEP;
                       idly_set_odd <= 8'd0;
                       rdel_ov_odd <= 0;
                   end
                   else if (dqs_delay_odd == 8'd0)                 
                   begin
                       if(idly_set_odd < (8'd255 - ADJ_STEP))
                       begin
                          rdel_ov_odd <= 0;
                          idly_set_odd <= idly_set_odd + ADJ_STEP;
                       end
                       else begin
                          rdel_ov_odd <= 1;
                          idly_set_odd <= 8'd255;
                       end
                   end
                   else 
                   begin
                       dqs_delay_odd <= 8'd0;
                       idly_set_odd <= idly_set_odd;
                       rdel_ov_odd <= rdel_ov_odd; 
                   end
              end
            end
            JUMP_RST: begin //same as INIT_RST
               dqs_delay_odd <= init_dqsi_value_odd;
               rdel_ov_odd <= 0;
            end         
            MOVE_RIGHT: begin
               if((cnt == 'h0)&&(move_stop_odd == 0)) begin
                   if(dqs_delay_odd < (8'd255 - ADJ_STEP)) begin
                       dqs_delay_odd <= dqs_delay_odd + ADJ_STEP;
                       rdel_ov_odd <= 0;
                   end
                   else begin
                       dqs_delay_odd <= 8'd255;
                       rdel_ov_odd <= 1;
                   end
               end
            end
            CENTER: begin
               dqs_delay_odd <= total_delay_odd[8:1] - {1'b0,idly_set_odd[7:1]};
               rdel_ov_odd <= 0;
            end         
            default: begin
               dqs_delay_odd <= dqs_delay_odd;
               idly_set_odd <= idly_set_odd;
               rdel_ov_odd <= rdel_ov_odd;
            end
         endcase
   end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) 
begin
   if(!ddrphy_rst_n) begin
       total_delay_odd <= 9'd0;
   end
   else begin
       if(state == IDLE)
       total_delay_odd <= 9'd0;
       else if((state == CHECK_LEFT)&&(dqsi_move_en)&&(move_stop_even|rdel_ov_even)&&(move_stop_odd|rdel_ov_odd ))
       total_delay_odd <= total_delay_odd + dqs_delay_odd;
       else if((state == CHECK_RIGHT)&&(dqsi_move_en)&&(move_stop_even|rdel_ov_even)&&(move_stop_odd|rdel_ov_odd ))
       total_delay_odd <= total_delay_odd + dqs_delay_odd;
   end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if(!ddrphy_rst_n) 
   begin
       idly_set <= 8'd0;
   end
   else if((state == MOVE_LEFT)||(state == CHECK_LEFT))
   begin
       if(idly_set_even >= idly_set_odd)
       idly_set <= idly_set_even[7:0];
       else 
       idly_set <= idly_set_odd[7:0];
   end
   else
      idly_set <= 8'd0;
end

//****************************************************************************************
assign rdel_calibration_rising = rdel_calibration & (~rdel_calibration_d);
assign eye_calibration_rising = eye_calibration & (~eye_calibration_d) ;
always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if(!ddrphy_rst_n) begin
      rdel_calibration_d <= 0;
      total_margin_even  <= 9'd0;
      eye_calibration_d  <= 0 ;
   end
   else begin
      rdel_calibration_d <= rdel_calibration;
      eye_calibration_d <= eye_calibration ;
      if (rdel_calibration_rising)
         total_margin_even <= 0;
      else if (eye_calibration_rising)
         total_margin_even <= 0 ;
      else if (((state == MOVE_LEFT)|(state == MOVE_RIGHT)) && (cnt == 'h0) && (move_stop_even == 0)) //check is valid
         total_margin_even <= total_margin_even + ADJ_STEP; 
   end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if(!ddrphy_rst_n) begin
      total_margin_odd  <= 9'd0;
   end
   else begin
      if (rdel_calibration_rising)
         total_margin_odd <= 0;  
      else if (eye_calibration_rising)
         total_margin_odd <= 0;
      else if (((state == MOVE_LEFT)|(state == MOVE_RIGHT)) && (cnt == 'h0) && (move_stop_odd == 0)) //check is valid
         total_margin_odd <= total_margin_odd + ADJ_STEP; 
   end
end


  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) 
        adj_rdel_done  <= 1'b0; 
     else if((state == INIT_ADJ) & (cnt[2]))
        adj_rdel_done  <= 1'b1;
     else if(~init_adj_rdel)
        adj_rdel_done  <= 1'b0;
  end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n) 
       rdel_move_done <= 1'b0;
    else if((rdel_calib_done)|(eyecal_check_pass))
       rdel_move_done <= 1'b1;
    else if(((state == MOVE_LEFT) & cnt[3])|((state == MOVE_RIGHT) & cnt[3]) |
            ((state == JUMP) & (cnt[2]))| ((state == CENTER) & (cnt [3])))
       rdel_move_done <= 1'b1;
    else
       rdel_move_done <= 1'b0;   
 end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n) 
       rdel_calib_done <= 1'b0;
    else 
       rdel_calib_done <= ((state == CALIB_WAIT) & rdel_calibration) | force_samp_position ;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n) 
       eyecal_check_pass <= 1'b0;
    else 
       eyecal_check_pass <= ((state == CALIB_WAIT) & eye_calibration) | force_samp_position ;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)
        rdel_cal_vld <= 1'b0;
     else
        rdel_cal_vld <= rdel_calibration & (~rdel_move_en);
  end
  
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
    if(!ddrphy_rst_n)
       rdel_calib_error  <= 1'b0;
    else if((state ==IDLE)&(rdel_calibration | eye_calibration))
       rdel_calib_error  <= 1'b0;
    else if(state == CALIB_WAIT)
       rdel_calib_error  <=  ((total_margin_even < MIN_DQSI_WIN)||(total_margin_odd < MIN_DQSI_WIN)) & (~force_samp_position);

assign dqs_even_bin =  dqs_delay_even[7:0];
assign dqs_odd_bin  = dqs_delay_odd[7:0];

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)
     dqs_even_gray <= 8'd0;
     else begin
       dqs_even_gray[7] <= dqs_even_bin[7];
       dqs_even_gray[6] <= dqs_even_bin[7] ^ dqs_even_bin[6];
       dqs_even_gray[5] <= dqs_even_bin[6] ^ dqs_even_bin[5];
       dqs_even_gray[4] <= dqs_even_bin[5] ^ dqs_even_bin[4];
       dqs_even_gray[3] <= dqs_even_bin[4] ^ dqs_even_bin[3];
       dqs_even_gray[2] <= dqs_even_bin[3] ^ dqs_even_bin[2];
       dqs_even_gray[1] <= dqs_even_bin[2] ^ dqs_even_bin[1];
       dqs_even_gray[0] <= dqs_even_bin[1] ^ dqs_even_bin[0];     
     end
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)
     dqs_odd_gray <= 8'd0;
     else begin
       dqs_odd_gray[7] <= dqs_odd_bin[7];
       dqs_odd_gray[6] <= dqs_odd_bin[7] ^ dqs_odd_bin[6];
       dqs_odd_gray[5] <= dqs_odd_bin[6] ^ dqs_odd_bin[5];
       dqs_odd_gray[4] <= dqs_odd_bin[5] ^ dqs_odd_bin[4];
       dqs_odd_gray[3] <= dqs_odd_bin[4] ^ dqs_odd_bin[3];
       dqs_odd_gray[2] <= dqs_odd_bin[3] ^ dqs_odd_bin[2];
       dqs_odd_gray[1] <= dqs_odd_bin[2] ^ dqs_odd_bin[1];
       dqs_odd_gray[0] <= dqs_odd_bin[1] ^ dqs_odd_bin[0];     
     end
  end

assign dbg_slice_rdcal_state = state;

endmodule
