////////////////////////////////////////////////////////////////      
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                         
// ALL RIGHTS REVERVED.                                               
////////////////////////////////////////////////////////////////      
//Description:                                                        
//Author:  wxxiao                                                     
//History: v1.0                                                       
////////////////////////////////////////////////////////////////      
`timescale 1ns/1ps                                                    
module  ips2l_ddrphy_data_slice_wrlvl_v1_9 #(
   parameter [7:0] WL_MAX_STEP       = 8'hff,
   parameter [7:0] CK_MAX_STEP       = 8'hff,
   parameter [4:0] WL_MAX_CHECK      = 5'h1f
)( 
  input                ddrphy_sysclk           ,
  input                ddrphy_rst_n            ,
  
  input      [7:0]     init_wrlvl_step         ,                               
  input                wrlvl_dqs_req           ,
  input                wl_p_ov                 ,
  output reg           wrlvl_dqs_resp          ,
  output reg           wrlvl_error             ,
                                      
  output reg           wrlvl_gatei             ,
  input                wrlvl_dq                ,
  output reg           wrlvl_dqs               ,
  output reg           wrlvl_dqs_en            ,
            
  input                wrlvl_ck_dly_done       ,
  input                wrlvl_ck_dly_start      ,
  output  reg          wrlvl_ck_dly_flag       ,
  output  reg          ck_check_done           ,
  output  reg  [7:0]   ck_dly_set_bin_tra      ,    
  input                force_ck_dly_en         ,
  output reg [7:0]     wrlvl_step              ,
  output reg [7:0]     wrlvl_step_gray         ,
  output     [2:0]     dbg_slice_wrlvl_state
  );
  
  localparam WL_IDLE        = 3'd0;
  localparam WL_CTRL        = 3'd1;
  localparam WL_SEND_WAIT   = 3'd2;
  localparam WL_SEND        = 3'd3;
  localparam WL_DQS_CHECK   = 3'd4;
  localparam WL_ERROR       = 3'd5;
  localparam WL_DONE        = 3'd6;
  
  reg  [2:0]      wl_state             ;
  reg  [2:0]      wl_next_state        ;  
  
  reg  [7:0]      step_cnt             ;
  reg  [2:0]      wrlvl_dq_r           ;
  reg  [8:0]      wrlvl_dq_seq         ;
  reg             dq_rising            ;
  reg             dq_vld               ;
  reg  [4:0]      cnt                  ;
  reg  [7:0]      vld_init_cnt         ;
  reg             wl_done_flag;

  reg  [7:0]      ck_dly_step          ;
  reg  [11:0]     wrlvl_ck_check_seq   ;  
  reg             wrlvl_ck_dly_pass    ;
  

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)              
       wl_state   <= WL_IDLE;   
    else
       wl_state   <= wl_next_state ;
  end
       
  always @(*) 
  begin
      wl_next_state = WL_IDLE;
      case(wl_state)
           WL_IDLE  :  begin 
                         if(wrlvl_dqs_req) 
                            wl_next_state = WL_CTRL;
                         else
                            wl_next_state = WL_IDLE;
                       end       

          WL_CTRL  :  begin                                 
                         if((step_cnt == WL_MAX_STEP) || (ck_dly_step == CK_MAX_STEP))   
                            wl_next_state = WL_ERROR ;  
                         else if(wl_p_ov )  
                            wl_next_state = WL_ERROR ;  
                         else                               
                           wl_next_state = WL_SEND_WAIT;     
                      end                                   
                  
      WL_SEND_WAIT : begin                                //delay 16 cycle
                        if(cnt[4])
                            wl_next_state = WL_SEND;
                        else
                            wl_next_state = WL_SEND_WAIT; 
                     end

          WL_SEND  :  begin
                             wl_next_state = WL_DQS_CHECK ;
                       end     
                          
      WL_DQS_CHECK :  begin
                         if(cnt == WL_MAX_CHECK)
                            begin  
                              if(dq_rising)
                                 wl_next_state = WL_DONE;
                              else
                                 wl_next_state = WL_CTRL;
                            end
                         else
                         wl_next_state =  WL_DQS_CHECK;        
                       end
                                    
           WL_ERROR   :    wl_next_state = WL_ERROR ;
                        
           WL_DONE    :  begin
                            if(~wrlvl_dqs_req)
                               wl_next_state = WL_IDLE    ;
                            else
                               wl_next_state = WL_DONE    ;
                         end
       endcase
  end
       
///output           
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) 
         wrlvl_dqs_en  <= 1'b0 ;
    else if(wl_next_state != WL_IDLE)
         wrlvl_dqs_en  <= 1'b1;
     else
         wrlvl_dqs_en  <= 1'b0;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
        cnt <=  5'h0;
    else if(((wl_state == WL_IDLE) && ~wl_done_flag))
        if(&cnt)
            cnt <= cnt;
        else
            cnt <= cnt + 5'h1;    
    else if((wl_next_state == WL_DQS_CHECK)|(wl_next_state ==WL_SEND_WAIT))
        cnt <= cnt + 5'h1;
    else
        cnt   <= 5'h0; 
  end
     
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                         
       wrlvl_dqs   <= 1'b0;
    else 
       wrlvl_dqs   <= (wl_state == WL_SEND);
  end
       
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
   if(!ddrphy_rst_n)
     wrlvl_dqs_resp  <= 1'b0;
   else
      wrlvl_dqs_resp  <= (wl_next_state == WL_DONE);       
 end
    
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n) begin                                     
      step_cnt    <= 8'h0;
      ck_dly_step <= 8'h0;
    end
    else if (wl_next_state == WL_IDLE) begin
      step_cnt  <= init_wrlvl_step;  
      ck_dly_step <= 8'h0;
    end
    else if ((cnt==WL_MAX_CHECK) & (~dq_rising)) begin
      if ((~wrlvl_ck_dly_start) | force_ck_dly_en) begin 
        ck_dly_step <= ck_dly_step;
        step_cnt    <= step_cnt + 8'h1;
      end
      else begin
        ck_dly_step <= ck_dly_step + 8'h1;
        step_cnt    <= 8'h0;
      end
    end
end
     
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
   if(!ddrphy_rst_n)
      wrlvl_gatei   <= 1'b0 ;
   else if(wl_state == WL_IDLE)
   begin
       if(cnt == 5'h10)
           wrlvl_gatei   <= 1'b1;
       else if(cnt == 5'h1b)
           wrlvl_gatei   <= 1'b0 ;
   end
    else if(wl_next_state == WL_CTRL) begin
     if(wrlvl_ck_dly_start) begin
       if(ck_dly_step == 8'h0)
         wrlvl_gatei   <= 1'b1;
       else
         wrlvl_gatei   <= 1'b0;
     end
     else
       wrlvl_gatei     <= 1'b1;
   end
   else if((wl_next_state==WL_SEND_WAIT) & (cnt==5'ha))
      wrlvl_gatei   <= 1'b0;
 end
 
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n) begin
        wrlvl_step  <= 8'b0;
	ck_dly_set_bin_tra <= 8'h0;
    end
    else if(wl_state == WL_IDLE && cnt == 5'h15)
        wrlvl_step <= init_wrlvl_step;
    else if((wl_state == WL_SEND_WAIT) & (cnt==5'h4)) begin
      if ((~wrlvl_ck_dly_start) | force_ck_dly_en) begin
        wrlvl_step  <= step_cnt ;
        ck_dly_set_bin_tra   <= ck_dly_set_bin_tra;
      end
      else begin
        wrlvl_step           <= 8'h0;
        ck_dly_set_bin_tra   <= ck_dly_step;
      end
    end
end
        
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)  
       dq_vld   <= 1'b0;
    else if((wl_state == WL_DQS_CHECK)&(cnt==5'h8))
       dq_vld   <= 1'b1; 
    else if(wl_state == WL_DONE)
       dq_vld   <= 1'b0;
  end
  
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
       wl_done_flag <= 1'b0;
    else if(wrlvl_dqs_req)
       wl_done_flag <= 1'b0;
    else if(wl_state == WL_DONE)
       wl_done_flag <= 1'b1;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
       wrlvl_dq_r  <= 3'b111;
    else if(wrlvl_dqs_en & dq_vld)
       wrlvl_dq_r  <= {wrlvl_dq_r[1:0],wrlvl_dq};
    else
       wrlvl_dq_r  <= 3'b111;
  end
       
always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)  
begin
    if(!ddrphy_rst_n) begin
      wrlvl_ck_dly_flag  <= 1'b0;
      wrlvl_ck_dly_pass  <= 1'b0;
    end
    else if(force_ck_dly_en) begin 
      wrlvl_ck_dly_flag  <= wrlvl_ck_dly_flag;
      wrlvl_ck_dly_pass  <= wrlvl_ck_dly_pass;
    end
    else if (wrlvl_ck_dly_done) begin
      wrlvl_ck_dly_flag  <= 1'b0;
      wrlvl_ck_dly_pass  <= wrlvl_ck_dly_pass;
    end
    else if(wrlvl_dqs_en & dq_vld & (vld_init_cnt >= 8'ha)) begin
      if (wrlvl_ck_check_seq != 11'b00000000000) begin
        wrlvl_ck_dly_flag  <= 1'b1;
        wrlvl_ck_dly_pass  <= wrlvl_ck_dly_pass;
      end
      else begin
        wrlvl_ck_dly_flag  <= wrlvl_ck_dly_flag;
        wrlvl_ck_dly_pass  <= 1'b1;
      end
    end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)   
begin
    if(!ddrphy_rst_n)                                  
      vld_init_cnt    <= 8'h0;
    else if (wl_state == WL_DONE)
      vld_init_cnt    <= 8'h0;  
    else if (wl_state == WL_DQS_CHECK && cnt == 5'd12)
        vld_init_cnt    <= vld_init_cnt + 8'h1; 
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if(!ddrphy_rst_n)
      wrlvl_ck_check_seq  <= 11'b00000000000;
    else if(wrlvl_ck_dly_pass)
      wrlvl_ck_check_seq  <= 11'b00000000000;
    else if(wrlvl_dqs_en & dq_vld) begin
      if(wl_state == WL_DQS_CHECK && cnt == 5'd12) begin
        if(wrlvl_ck_dly_start)
          wrlvl_ck_check_seq <= {wrlvl_dq_r[2],wrlvl_ck_check_seq[10:1]};
        else
          wrlvl_ck_check_seq <= {wrlvl_ck_check_seq[9:0],wrlvl_dq_r[2]};
      end
    end
    else
      wrlvl_ck_check_seq  <= 11'b00000000000;
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)  
begin
    if(!ddrphy_rst_n)                                        
      ck_check_done  <= 1'b0;
    else if(wl_state == WL_DONE)
      ck_check_done  <= 1'b0;
    else if(dq_vld && (wl_state == WL_DQS_CHECK && cnt == 5'd13) && wrlvl_ck_dly_start && (wrlvl_ck_check_seq == 11'b00000000000))
      ck_check_done  <= 1'b1;
end       
       
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
       wrlvl_dq_seq <= 9'b111111111;
    else if(wrlvl_dqs_en & dq_vld) begin
       if(wl_state == WL_DQS_CHECK && cnt == 5'd12 && (~wrlvl_ck_dly_start))
          wrlvl_dq_seq <= {wrlvl_dq_seq[7:0],wrlvl_dq_r[2]};
      else if(wrlvl_ck_dly_start)
        wrlvl_dq_seq  <= 9'b111111111;
    end
    else
       wrlvl_dq_seq <= 9'b111111111;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
       dq_rising  <= 1'b0;
    else if(wl_state == WL_DONE)
       dq_rising  <= 1'b0;
    else if(dq_vld && (wl_state == WL_DQS_CHECK && cnt == 5'd13) && (wrlvl_ck_dly_pass | force_ck_dly_en) && (wrlvl_dq_seq == 9'b000000001))
       dq_rising  <= 1'b1;
  end
       
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                        
        wrlvl_error   <= 1'b0;
    else 
        wrlvl_error   <= (wl_state == WL_ERROR);
  end
 
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                        
    begin
        wrlvl_step_gray[7] <= 1'b0;
        wrlvl_step_gray[6] <= 1'b0;
        wrlvl_step_gray[5] <= 1'b0;
        wrlvl_step_gray[4] <= 1'b0;
        wrlvl_step_gray[3] <= 1'b0;
        wrlvl_step_gray[2] <= 1'b0;
        wrlvl_step_gray[1] <= 1'b0;
        wrlvl_step_gray[0] <= 1'b0;
    end
    else 
    begin
        wrlvl_step_gray[7] <= wrlvl_step[7];
        wrlvl_step_gray[6] <= wrlvl_step[7]^wrlvl_step[6];
        wrlvl_step_gray[5] <= wrlvl_step[6]^wrlvl_step[5];
        wrlvl_step_gray[4] <= wrlvl_step[5]^wrlvl_step[4];
        wrlvl_step_gray[3] <= wrlvl_step[4]^wrlvl_step[3];
        wrlvl_step_gray[2] <= wrlvl_step[3]^wrlvl_step[2];
        wrlvl_step_gray[1] <= wrlvl_step[2]^wrlvl_step[1];
        wrlvl_step_gray[0] <= wrlvl_step[1]^wrlvl_step[0];
    end
  end

assign dbg_slice_wrlvl_state = wl_state;

endmodule
