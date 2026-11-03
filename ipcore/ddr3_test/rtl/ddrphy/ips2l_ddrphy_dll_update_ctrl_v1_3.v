////////////////////////////////////////////////////////////////      
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                         
// ALL RIGHTS REVERVED.                                               
////////////////////////////////////////////////////////////////      
//Description:                                                        
//Author:  wxxiao                                                     
//History: v1.0                                                       
////////////////////////////////////////////////////////////////      
`timescale 1ns/1ps                                                    
module ips2l_ddrphy_dll_update_ctrl_v1_3(
input            rst_clk               ,
input            ddr_rstn               ,
input            dfi_refresh            ,
input            dll_update_req_rst_ctrl,
input            dll_update_code_done   ,
input            dbg_dll_update_en      ,
output reg       dll_update_ack_rst_ctrl,
input            dll_tran_update_en     ,
//input            dll_update_req_training,
//output reg       dll_update_ack_training,
output           dll_freeze             ,
output reg       dll_update_n           ,
output     [1:0] dbg_dll_upd_state
);

localparam IDLE     = 2'd0;
localparam DLL_UP   = 2'd1;
localparam WAIT     = 2'd2;
localparam ACK      = 2'd3;

reg [1:0]   dll_update_req_rst_ctrl_d;
reg [1:0]   state;
reg [3:0]   cnt;
reg         dll_update_code_done_d1;
reg         dll_update_code_done_d2;
reg         dll_update_code_done_d3;
wire        dll_update_code_done_pos;
reg [1:0]   dfi_refresh_d    ;
reg [18:0]  dll_freeze_cnt  ;


//*****************************************************
//update from rst_ctrl is async while update req from training is sync
always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn) begin
      dll_update_req_rst_ctrl_d <= 2'd0;
   end
   else begin
      dll_update_req_rst_ctrl_d <= {dll_update_req_rst_ctrl_d[0], dll_update_req_rst_ctrl};
   end
end

always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn)
      dfi_refresh_d <= 2'b0;
   else
      dfi_refresh_d <= {dfi_refresh_d[0],dfi_refresh};
end


wire update_req = dll_update_req_rst_ctrl_d[1] | (dbg_dll_update_en & dll_tran_update_en & dfi_refresh_d[1]);

always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn) begin
      dll_update_code_done_d1 <= 0; 
      dll_update_code_done_d2 <= 0;
      dll_update_code_done_d3 <= 0;
   end
   else begin
      dll_update_code_done_d1 <= dll_update_code_done; 
      dll_update_code_done_d2 <= dll_update_code_done_d1;
      dll_update_code_done_d3 <= dll_update_code_done_d2;
   end
end

assign dll_update_code_done_pos = dll_update_code_done_d2 & (~dll_update_code_done_d3);

always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn) begin
      state                <= IDLE;
      cnt                  <= 4'd0;
   end
   else begin
      case (state)
         IDLE: begin
            cnt   <= 4'd0;
            if (update_req) begin
               state <= DLL_UP;
            end
         end
         DLL_UP: begin //assert dll_update_n; capture DLL step
            if (cnt[1]) begin
               state <= WAIT;
               cnt   <= 4'd0;
            end
            else
               cnt <= cnt + 4'd1;
         end
         WAIT: begin
            if (cnt[1]) begin
               if(dll_update_code_done_pos == 1)
               begin
                  cnt   <= 4'd0;
                  state <= ACK;
               end
            end
            else
               cnt <= cnt + 4'd1;
         end
         ACK: begin
            cnt   <= 4'd0;
            if (~update_req)
               state <= IDLE;
         end
         default:
            state <= IDLE;
      endcase
   end
end
   
always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn) begin
      dll_update_ack_rst_ctrl <= 1'b0;
      dll_update_n            <= 1'b0;
   end
   else begin
      if (state == ACK)
         dll_update_ack_rst_ctrl <= 1'b1;
      else
         dll_update_ack_rst_ctrl <= 1'b0;

      if (state == DLL_UP)
         dll_update_n <= 1'b0; //when cnt = 0/1
      else
         dll_update_n <= 1'b1;
   end
end
 
always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn)
      dll_freeze_cnt  <= 19'd0;
   else if(dll_tran_update_en)
      dll_freeze_cnt  <= dll_freeze_cnt + 19'd1;
   else
      dll_freeze_cnt  <= 19'd0;
end

`ifdef IPS_DDR_SPEEDUP_SIM
assign dll_freeze = dll_freeze_cnt[8];
`else
assign dll_freeze = dll_freeze_cnt[18];
`endif

assign dbg_dll_upd_state = state;

endmodule
