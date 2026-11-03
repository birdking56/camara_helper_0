// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.1
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_reset_ctrl_v1_3
(
    input        ddr_rstn                ,
    input        rst_clk                 ,
    input        ddrphy_sysclk           ,
    input        dll_lock                ,
    input        pll_lock                ,
   //debug
   input         dbg_gpll_scan_rst       ,
   input         dbg_gate_start          ,
   input         dbg_cpd_start           ,
   input         dbg_ddrphy_rst_n        ,
   //   
    output       rst_clk_adj_start       ,
    input        rst_clk_adj_done        ,
    output reg [5:0] tran_err_rst_cnt    ,
    output       ddrphy_init_fail        ,
    input        ddrphy_cpd_done         ,
    input        training_error          ,
    input        ddrphy_calib_done       ,
    output reg   ddrphy_cpd_start        ,
    output reg   dll_update_req_rst_ctrl ,
    input        dll_update_ack_rst_ctrl ,
    output       dll_tran_update_en      ,
    output reg   logic_rstn              ,
    output reg   phy_pll_rst             ,
    output       ddrphy_dll_rst_n        ,
    output       ddrphy_rst_n            ,
    output reg   ddrphy_iol_rst          ,
    output reg   ddrphy_dqs_rst          ,
    output reg [2:0]  ddrphy_ioclk_gate  /* synthesis syn_preserve = 1 */,  //don't delete "/* synthesis syn_preserve = 1 */" !!
    output [3:0]  debug_rst_state        
);

//parameter SRB_DQS_RST_TRAINING_HIGH_CLK = 4;

localparam e_IDLE          = 4'd0;
localparam e_WAIT          = 4'd1;
localparam e_PLL_LOCKED    = 4'd2;
localparam e_DLL_LOCKED    = 4'd3;
localparam e_DLL_UP_HOLD   = 4'd4;
localparam e_GATE_CLK      = 4'd5;
localparam e_GATE_OUT      = 4'd6;
localparam e_GATE_HOLD     = 4'd7;
localparam e_CPD_START     = 4'd8;
localparam e_CPD_DONE      = 4'd9;
localparam e_NORMAL        = 4'd10;

`ifdef IPS_DDR_SPEEDUP_SIM 
localparam UPDATE_TIME = 32'd500;
`else                      
localparam UPDATE_TIME = 32'd1000;
`endif

reg  [3:0]    state                     ;
reg  [1:0]    pll_lock_d                ;
reg  [1:0]    dll_lock_d                ;
reg  [7:0]    cnt                       ;
reg  [1:0]    dll_update_ack_rst_ctrl_d ;
//reg  [1:0]    dll_update_ack_training_d ;
reg  [1:0]    ddrphy_cpd_done_d         ;
reg  [31:0]   dll_update_cnt            ;
reg  [1:0]    training_error_d          ;
reg  [1:0]    ddrphy_calib_done_d       ;
reg           ddrphy_ioclk_gate_d       ;
//wire        dll_lock_pose             ;
reg  [1:0]    dbg_gpll_scan_rst_d       ;
reg  [2:0]    dbg_gate_start_d          ;
reg  [2:0]    dbg_cpd_start_d           ;
wire          dbg_gate_start_pos        ;
wire          dbg_cpd_start_pos         ;
reg           ddrphy_rst_n_rg           ;
reg           ddrphy_dll_rst_n_rg       ;
reg           ddrphy_cpd_start_d        ;
reg           ddrphy_cpd_start_d0       ;
reg           ddrphy_cpd_start_d1       ;
wire          pll_lock_deb              ;
reg           tran_err_rst_sta          ;
reg           rst_clk_adj_done_d1       ;
reg           rst_clk_adj_done_d2       ;
reg           rst_clk_adj_done_d3       ;
wire          rst_clk_adj_done_pos      ;
reg           training_error_latch      ;

assign debug_rst_state = state;

//assign dll_lock_pose = dll_lock_d == 2'b01;
 
always @(posedge rst_clk or negedge logic_rstn)
begin
   if (!logic_rstn) begin
      pll_lock_d                   <= 2'd0;
      dll_lock_d                   <= 2'd0;
      dll_update_ack_rst_ctrl_d    <= 2'd0;
      ddrphy_cpd_done_d            <= 2'd0;
      training_error_d             <= 2'd0;
      ddrphy_calib_done_d          <= 2'd0;
      dbg_gpll_scan_rst_d          <= 2'd0;
      dbg_gate_start_d             <= 3'd0;
      dbg_cpd_start_d              <= 3'd0;
   end
   else begin
      pll_lock_d                   <= {pll_lock_d[0], pll_lock};
      dll_lock_d                   <= {dll_lock_d[0], dll_lock};      
      dll_update_ack_rst_ctrl_d    <= {dll_update_ack_rst_ctrl_d[0],dll_update_ack_rst_ctrl};
      ddrphy_cpd_done_d            <= {ddrphy_cpd_done_d[0],ddrphy_cpd_done};
      training_error_d             <= {training_error_d[0],training_error};
      ddrphy_calib_done_d          <= {ddrphy_calib_done_d[0],ddrphy_calib_done};
      dbg_gpll_scan_rst_d          <= {dbg_gpll_scan_rst_d[0],dbg_gpll_scan_rst};
      dbg_gate_start_d             <= {dbg_gate_start_d[1:0],dbg_gate_start};
      dbg_cpd_start_d              <= {dbg_cpd_start_d[1:0],dbg_cpd_start};
   end
end

assign dbg_gate_start_pos = ~dbg_gate_start_d[2] & dbg_gate_start_d[1];
assign dbg_cpd_start_pos  = ~dbg_cpd_start_d[2]  & dbg_cpd_start_d[1];

always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn)
   begin
       rst_clk_adj_done_d1 <= 1'b0;
       rst_clk_adj_done_d2 <= 1'b0;
       rst_clk_adj_done_d3 <= 1'b0;
   end
   else
   begin
       rst_clk_adj_done_d1 <= rst_clk_adj_done;
       rst_clk_adj_done_d2 <= rst_clk_adj_done_d1;
       rst_clk_adj_done_d3 <= rst_clk_adj_done_d2;
   end
end

assign rst_clk_adj_done_pos = rst_clk_adj_done_d2 & (~rst_clk_adj_done_d3);

ips2l_ddrphy_rst_debounce_v1_0 #(
    .RISE_CNTR_WIDTH  (19               ),
`ifdef IPS_DDR_SPEEDUP_SIM
    .RISE_CNTR_VALUE  (19'h00200        ),
`else
    .RISE_CNTR_VALUE  (19'h40000        ),
`endif
    .ACTIVE_HIGH      (1'b0             ) // 0 : active@low, 1 : active@high
)
ddrphy_pll_lock_debounce
(
    .clk              (rst_clk          ),
    .rst_n            (ddr_rstn         ),
    .signal_b         (pll_lock_d[1]    ),
    .signal_deb       (pll_lock_deb     )
);

always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn) begin
      state <= e_IDLE;
      cnt   <= 8'd0; 
   end
   else begin
         case (state)
            e_IDLE: begin
               if (cnt == 8'd200) begin
                  state <= e_WAIT;
                  cnt   <= 8'd0;
               end
               else begin
                  state <= e_IDLE;
                  cnt <= cnt + 8'd1;   
               end
            end
            e_WAIT:begin
               cnt <= 8'd0;
               if (pll_lock_deb == 1'b1)
               state <= e_PLL_LOCKED; 
               else  
               state <= e_WAIT;
            end
            e_PLL_LOCKED: begin //wait for DLL lock
               if (cnt == 8'd100) begin
                  if (dll_lock_d[1] == 1'b1)
                     state <= e_DLL_LOCKED;
               end
               else begin
                  state <= e_PLL_LOCKED;
                  cnt <= cnt + 8'd1;
               end
            end
            e_DLL_LOCKED: begin
               cnt <= 8'd0;
               if (dll_update_ack_rst_ctrl_d[1] == 1'b1)
               state <= e_DLL_UP_HOLD;
               else
               state <= e_DLL_LOCKED;
            end
            e_DLL_UP_HOLD: begin
               cnt <= 8'd0;               
               if (dll_update_ack_rst_ctrl_d[1] == 1'b0)
               state <= e_GATE_CLK;
               else
               state <= e_DLL_UP_HOLD;
            end
            e_GATE_CLK: begin
               if (cnt == 8'd8) begin
                  cnt   <= 8'd0;
                  state <= e_GATE_OUT;
               end
               else begin
                  cnt   <= cnt + 8'd1;
                  state <= e_GATE_CLK;
               end
            end
            e_GATE_OUT: begin
               if (cnt == 8'd8) begin
                  state <= e_GATE_HOLD;
                  cnt   <= 8'd0;
               end
               else begin
                  state <= e_GATE_OUT;
                  cnt <= cnt + 8'd1;
               end
            end
            e_GATE_HOLD: begin //switch back to clkdiv out
               if (cnt == 8'd8) begin
                  cnt   <= 8'd0;
                  if(dbg_gpll_scan_rst_d[1])
                      state <= e_NORMAL;
                  else
                      state <= e_CPD_START;
               end
               else begin
                  cnt <= cnt + 8'd1;
                  state <= e_GATE_HOLD;
               end
            end
            e_CPD_START:begin
                state <= e_CPD_DONE;
            end
            e_CPD_DONE:begin
                if(ddrphy_cpd_done_d[1] == 1)
                state <= e_NORMAL;
            end
            e_NORMAL: begin
              cnt   <= 8'd0; 
              if (((pll_lock_deb == 1'b0) || tran_err_rst_sta) && (~dbg_gpll_scan_rst_d[1]))
              state <= e_IDLE;
              else if(dbg_gate_start_pos)
              state <= e_GATE_CLK;
              else if(dbg_cpd_start_pos)
              state <= e_CPD_START;
              else
              state <= e_NORMAL;
            end
            default: begin
                state <= e_IDLE;
            end
         endcase   
   end
end

always@(*)
begin
    if((state == e_NORMAL) && training_error_d[1])
        if(tran_err_rst_cnt == 6'd0)             // 6'd0 not control by rst_clk_adj_done_pos
            tran_err_rst_sta <= 1'b1;
        else if(tran_err_rst_cnt[1:0] != 2'b00)  //tran_err_rst_cnt is not integer multiple of four;
            tran_err_rst_sta <= 1'b1;
        else if(rst_clk_adj_done_pos)            //tran_err_rst_cnt is integer multiple of four, and tran_err_rst_cnt is not zero;
            tran_err_rst_sta <= 1'b1;
        else
            tran_err_rst_sta <= 1'b0;
    else
        tran_err_rst_sta <= 1'b0;
end

always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn)
       tran_err_rst_cnt <= 6'd0;
   else if(tran_err_rst_sta && (~tran_err_rst_cnt[5]))
       tran_err_rst_cnt <= tran_err_rst_cnt + 6'd1;
   else;
end

always @(posedge rst_clk or negedge ddr_rstn)
begin
    if (!ddr_rstn)
        training_error_latch <= 1'b0 ;
    else if((state == e_NORMAL) & training_error_d[1])
        training_error_latch <= tran_err_rst_cnt[2] ;
    else
        training_error_latch <= training_error_latch ;
end

assign rst_clk_adj_start = training_error_latch;

assign ddrphy_init_fail  = tran_err_rst_cnt[5] & training_error_d[1];
 
always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn) begin
        ddrphy_dll_rst_n_rg     <= 1'b0;
        ddrphy_rst_n_rg         <= 1'b0;
        ddrphy_dqs_rst          <= 1'b1;
        ddrphy_iol_rst          <= 1'b1;
        ddrphy_ioclk_gate_d     <= 1'b1;
        dll_update_req_rst_ctrl <= 1'b0;
        ddrphy_cpd_start_d      <= 1'b0;
        logic_rstn              <= 1'b0;
        phy_pll_rst             <= 1'b1;
   end
   else begin
        ddrphy_dll_rst_n_rg     <= ~((state == e_IDLE) || (state == e_WAIT));    //release dll reset after pll is locked
        dll_update_req_rst_ctrl <= state == e_DLL_LOCKED;      
        ddrphy_rst_n_rg         <= (state == e_NORMAL) && (dbg_ddrphy_rst_n == 1'b1);
        ddrphy_dqs_rst          <= (state == e_GATE_CLK);
        ddrphy_iol_rst          <= (state == e_GATE_CLK)&&(cnt[2] == 1);
        ddrphy_cpd_start_d      <= state == e_CPD_START;
        ddrphy_ioclk_gate_d     <= ((state == e_GATE_CLK)||(state == e_GATE_OUT));
        logic_rstn              <= (state != e_IDLE);
        phy_pll_rst             <=  state == e_IDLE;
   end
end

always @(posedge rst_clk or negedge ddr_rstn)
begin
    if (!ddr_rstn)
    begin
        ddrphy_cpd_start_d0 <= 1'b0;
        ddrphy_cpd_start_d1 <= 1'b0;
        ddrphy_cpd_start <= 1'b0;
    end
    else
    begin
        ddrphy_cpd_start_d0 <= ddrphy_cpd_start_d;
        ddrphy_cpd_start_d1 <= ddrphy_cpd_start_d0;
        ddrphy_cpd_start <= ddrphy_cpd_start_d1 | ddrphy_cpd_start_d0 | ddrphy_cpd_start_d;
    end
end

always @(posedge rst_clk or negedge ddr_rstn)
begin
   if (!ddr_rstn)
   ddrphy_ioclk_gate <= 3'b111;
   else
   ddrphy_ioclk_gate <= {3{ddrphy_ioclk_gate_d}};
end

assign dll_tran_update_en = (state == e_NORMAL)&&(ddrphy_calib_done_d[1] == 1);

ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH    (1                     ),
    .DFT_VALUE     (1'b0                  )
) u_ddrphy_rstn_sync(
    .clk           (ddrphy_sysclk         ),
    .rst_n         (ddrphy_rst_n_rg       ),
    .sig_async     (1'b1                  ),
    .sig_synced    (ddrphy_rst_n          )
);

ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH    (1                     ),
    .DFT_VALUE     (1'b0                  )
) u_dll_rst_sync(
    .clk           (ddrphy_sysclk         ),
    .rst_n         (ddrphy_dll_rst_n_rg   ),
    .sig_async     (1'b1                  ),
    .sig_synced    (ddrphy_dll_rst_n      )
);

endmodule 


