////////////////////////////////////////////////////////////////          
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                             
// ALL RIGHTS REVERVED.                                                   
////////////////////////////////////////////////////////////////          
//Description:                                                            
//Author:  wxxiao                                                         
//History: v1.1                                                           
////////////////////////////////////////////////////////////////          

`timescale 1ns/1ps                                                        
module ips2l_ddrphy_gatecal_v1_6 #(
    parameter  GATE_MODE       =  0
)(
    input [2:0]      init_read_clk_ctrl   ,
    input [3:0]      init_slip_step       ,
    input            force_read_clk_ctrl  ,

    input            ddrphy_sysclk        ,
    input            ddrphy_rst_n         ,
    input [1:0]      comp_val             ,
    input            comp_dir             ,
    input            dqs_gate_comp_en     ,
    output reg       dqs_gate_comp_done   ,

    input            gatecal_start        ,
    output reg       gate_check_pass      ,
    output reg       gate_adj_done        ,
    output reg       gate_cal_error       ,
    input            dqs_gate_vld         ,
    input            gate_move_en         ,

    output [3:0]     coarse_slip_step     ,
    output [2:0]     read_clk_ctrl        ,
    output reg [3:0] gate_win_size        ,
    input            ddrphy_dgts          ,
    input            dqs_gate_sample      ,
    output [2:0]     dbg_slice_gate_state  
   );  

  localparam GATECAL_IDLE       = 3'd0;
  localparam GATECAL_LOAD_INIT  = 3'd1;
  localparam GATECAL_JUDGE      = 3'd2;
  localparam GATECAL_WAIT       = 3'd3;
  localparam GATECAL_DONE       = 3'd4;
  localparam GATECAL_ERROR      = 3'd5;

  reg [2:0]  gate_state        ;
  reg [2:0]  gate_state_next   ;
  reg [6:0]  gate_value        ;
  reg [6:0]  golden_value      ;
  reg [3:0]  dgts_cnt          ;
  reg [2:0]  ddrphy_dgts_r     ;
  reg        dqs_gate_vld_r    ;
  reg        dgts_vld          ;
  reg [2:0]  dgts_vld_cnt      ;
  wire       dqs_gate_vld_n    ;
  wire       ddrphy_dgts_p     ;
  reg        dgts_latch        ; 
//  reg [3:0]  valid_cnt         ;
  reg [2:0]  dqs_gate_sample_r ;
  reg        sample_done       ;
  reg [2:0]  sample_reg        ;
  reg        dqs_gate_comp_en_r;
  wire       dqs_gate_comp_en_p;
  wire       sync_gate_sample  ;

  assign  coarse_slip_step = gate_value[6:3];
  assign  read_clk_ctrl    = {gate_value[2:0]};

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
           gate_state    <=  GATECAL_IDLE ;
      else
           gate_state    <=  gate_state_next ;
  end

   always @ (*) 
   begin
          gate_state_next  = GATECAL_IDLE;
        case(gate_state) 
            GATECAL_IDLE :  begin
                               if(gatecal_start)
                                  gate_state_next = GATECAL_LOAD_INIT;
                               else
                                 gate_state_next = GATECAL_IDLE;
                            end

        GATECAL_LOAD_INIT : begin
                                 gate_state_next = GATECAL_JUDGE ;
                           end
          
          GATECAL_JUDGE  : begin
                              if(dqs_gate_vld_n) begin
                                if(GATE_MODE == 0) begin
                                    if(dgts_cnt == 4'd6)
                                         gate_state_next = GATECAL_DONE ;
                                    else if(gate_value[6]) begin
                                         if(dgts_cnt > 4'd4) 
                                            gate_state_next = GATECAL_DONE;
                                         else 
                                            gate_state_next = GATECAL_ERROR;
                                    end
                                    else
                                     gate_state_next = GATECAL_WAIT;
                                end
                                else if(GATE_MODE == 1) begin
                                    if(sample_done)
                                    gate_state_next = GATECAL_DONE ;
                                    else if(gate_value[6])
                                    gate_state_next = GATECAL_ERROR;
                                    else
                                    gate_state_next = GATECAL_WAIT;
                                end
                              end
                              else
                                 gate_state_next = GATECAL_JUDGE ;
                          end

          GATECAL_WAIT  :  begin
                              if(gate_move_en)
                                  gate_state_next = GATECAL_JUDGE;
                              else 
                                  gate_state_next = GATECAL_WAIT;
                            end

          GATECAL_DONE  :  begin
                              if(~gatecal_start)
                                 gate_state_next = GATECAL_IDLE ;
                              else
                                 gate_state_next = GATECAL_DONE ;
                           end

          GATECAL_ERROR : gate_state_next =  GATECAL_ERROR ;

          endcase
   end
   
//
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                                  
        dqs_gate_vld_r  <= 1'b0; 
     else
        dqs_gate_vld_r  <= dqs_gate_vld;
  end

  assign dqs_gate_vld_n  = ~dqs_gate_vld & dqs_gate_vld_r;

   always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
   begin
      if(!ddrphy_rst_n)
          gate_adj_done    <=  1'b0 ;
      else if (gate_move_en | (gate_state_next == GATECAL_IDLE))
          gate_adj_done    <=  1'b0;
      else if (dqs_gate_vld_n) 
          gate_adj_done    <=  1'b1;
  end

   always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
   begin
      if(!ddrphy_rst_n)
         gate_cal_error  <=  1'b0 ;
      else if (gate_state_next == GATECAL_ERROR)
        gate_cal_error   <= 1'b1;
   end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n) 
        gate_value   <=  7'h0 ;
    else  if(force_read_clk_ctrl)
            gate_value   <= {init_slip_step,init_read_clk_ctrl};
          else if(gate_state_next == GATECAL_LOAD_INIT)
            gate_value   <= {init_slip_step,init_read_clk_ctrl};
          else if(gate_state_next == GATECAL_IDLE)
          begin
            if(golden_value[0] == 1'b1)
              gate_value  <= golden_value + 7'h1;
            else
              gate_value  <= golden_value;
          end
          else if(gate_move_en & (~sample_done)) 
            gate_value   <= gate_value + 7'h2;
  end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n)   
        ddrphy_dgts_r  <=  3'b000;
    else 
        ddrphy_dgts_r  <= {ddrphy_dgts_r[1:0],ddrphy_dgts};
 end

  assign  ddrphy_dgts_p = (ddrphy_dgts_r[2:1] == 2'b01);

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n) 
        dgts_latch   <= 1'b0;
    else if(gate_state_next == GATECAL_JUDGE) begin
            if(ddrphy_dgts_p)
               dgts_latch   <= 1'b1;
    end
    else
        dgts_latch   <= 1'b0;
 end


 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n) 
     dqs_gate_comp_en_r <= 1'b0;
    else
     dqs_gate_comp_en_r <= dqs_gate_comp_en;
 end
 
 assign dqs_gate_comp_en_p = ((~dqs_gate_comp_en_r) & dqs_gate_comp_en);

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n) 
     dqs_gate_comp_done <= 1'b0;
    else
      if (dqs_gate_comp_en)
        dqs_gate_comp_done <= 1'b1;
      else if(dqs_gate_comp_en==0)
        dqs_gate_comp_done <= 1'b0;
 end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n) 
       golden_value    <= 7'h0 ;
    else if ((gate_state_next == GATECAL_IDLE) & gatecal_start)
        golden_value    <= 7'h0 ;
    else if ((dgts_cnt > 4'h3) && (dgts_vld == 1) && (GATE_MODE == 0))
        golden_value    <= gate_value - {4'd0,dgts_cnt[3:1]};
    else if ((sample_done==1) && (dqs_gate_vld_n==1) && (GATE_MODE==1))
        golden_value    <= gate_value - 7'd4;
    else if(dqs_gate_comp_en_p)
        begin
          if(comp_dir)
           golden_value <= golden_value + comp_val;
          else
           golden_value <= golden_value - comp_val;
        end
 end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n) 
         dgts_vld_cnt   <= 3'b0;
    else if ((gate_state_next == GATECAL_JUDGE) & ddrphy_dgts_r[1] & dgts_latch )
    begin
       if(dgts_vld_cnt < 3'b111)
       dgts_vld_cnt   <= dgts_vld_cnt + 3'b1;
    end 
    else
         dgts_vld_cnt   <= 3'b0;
 end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n) 
         dgts_vld    <= 1'b0;
    else if(dgts_vld_cnt == 3'b101)
         dgts_vld    <= 1'b1;
    else
         dgts_vld    <= 1'b0;
 end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n)
       dgts_cnt   <=  4'h0 ;
    else if (gate_state_next == GATECAL_IDLE)
       dgts_cnt   <= 4'h0;
    else if (dgts_vld & (~sync_gate_sample)) 
       dgts_cnt    <= dgts_cnt + 4'h1;
 end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n)
       gate_check_pass   <= 1'b0;
    else if(gate_state_next == GATECAL_IDLE)
       gate_check_pass   <= 1'b0;
    else if(gate_state_next == GATECAL_DONE)
       gate_check_pass   <= 1'b1;
 end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
      if(!ddrphy_rst_n)
         gate_win_size   <= 4'b0;
      else
        begin
          if (gatecal_start)
              if (gate_check_pass)
               gate_win_size <= dgts_cnt; 
              else
                gate_win_size <= 4'b000;
        end
 end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n)   
        dqs_gate_sample_r  <=  3'b000;
    else 
        dqs_gate_sample_r  <= {dqs_gate_sample_r[1:0],dqs_gate_sample};
 end
 
 assign  sync_gate_sample = dqs_gate_sample_r[2];


 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin       
    if(!ddrphy_rst_n) 
    sample_reg <= 3'b101;
    else if (gate_state_next == GATECAL_IDLE)
    sample_reg <= 3'b101;
    else if(dqs_gate_vld_n)
    sample_reg  <= {sample_reg[1:0],sync_gate_sample};
 end
 
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin       
    if(!ddrphy_rst_n) 
    sample_done <= 0;
    else if (gate_state_next == GATECAL_IDLE)
    sample_done <= 0;
    else if(sample_reg == 3'b001)
    sample_done <= 1;
 end

assign dbg_slice_gate_state = gate_state;
endmodule
