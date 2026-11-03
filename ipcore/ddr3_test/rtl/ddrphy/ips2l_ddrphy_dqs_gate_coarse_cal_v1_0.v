////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module  ips2l_ddrphy_dqs_gate_coarse_cal_v1_0(   
   input            ddrphy_sysclk    ,
   input            ddrphy_rst_n     ,
   input            gatecal_start    ,
   input            rddata_cal       ,
   
   input  [3:0]     read_cmd         ,
   input  [4:0]     mc_rl            ,

   input  [3:0]     coarse_slip_step ,
   output [3:0]     dqs_gate_ctrl    ,
   output reg       dqs_gate_vld
  );
  
  wire read_cmd_comb;
  reg [1:0] read_cmd_comb_r;
  reg [3:0] dqs_gate_pulse_src;
  reg [3:0] dqs_gate_pulse_src_nxt;
  reg [3:0] dqs_gate_pulse_src_nxt_r;

  reg [3:0] dqs_gate_pulse_r1;
  reg [3:0] dqs_gate_pulse_r2;
  reg [3:0] dqs_gate_pulse_r3;
  reg [3:0] dqs_gate_pulse_r4;
  reg [3:0] dqs_gate_ctrl_adj;
  reg [3:0] dqs_gate_ctrl_pos;


  reg [4:0] cnt;
  reg [3:0] read_en_slipped;
  reg [3:0] read_cmd_mux;
  reg [3:0] read_cmd_mux_r1 ;
  reg [3:0] read_cmd_mux_r2 ;
  reg [3:0] read_cmd_mux_r3 ;

assign read_cmd_comb = |read_cmd;

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)
        read_cmd_comb_r   <= 2'b00;
     else
        read_cmd_comb_r   <= {read_cmd_comb_r[0],read_cmd_comb};
  end

    always @(*)
    begin
        if(gatecal_start & read_cmd_comb & (~read_cmd_comb_r[1]))
            read_cmd_mux = read_cmd;
        else if(~gatecal_start)
            read_cmd_mux = read_cmd;
        else
            read_cmd_mux = 4'b0000;
    end
            
////
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n) begin
        read_cmd_mux_r1 <= 4'b0;
        read_cmd_mux_r2 <= 4'b0;
        read_cmd_mux_r3 <= 4'b0;
    end
    else begin
       read_cmd_mux_r1 <= read_cmd_mux  ;
       read_cmd_mux_r2 <= read_cmd_mux_r1 ;
       read_cmd_mux_r3 <= read_cmd_mux_r2 ;
    end
  end

     always @(*)
         case (coarse_slip_step)
             4'd0:       read_en_slipped = read_cmd_mux;
             4'd1:       read_en_slipped = {read_cmd_mux[2:0],read_cmd_mux_r1[3]};
             4'd2:       read_en_slipped = {read_cmd_mux[1:0],read_cmd_mux_r1[3:2]};
             4'd3:       read_en_slipped = {read_cmd_mux[0],  read_cmd_mux_r1[3:1]};
             4'd4:       read_en_slipped = read_cmd_mux_r1;
             4'd5:       read_en_slipped = {read_cmd_mux_r1[2:0],read_cmd_mux_r2[3]};
             4'd6:       read_en_slipped = {read_cmd_mux_r1[1:0],read_cmd_mux_r2[3:2]};
             4'd7:       read_en_slipped = {read_cmd_mux_r1[0],  read_cmd_mux_r2[3:1]};
             4'd8:       read_en_slipped = read_cmd_mux_r2;
             4'd9:       read_en_slipped = {read_cmd_mux_r2[2:0],read_cmd_mux_r3[3]};
             4'd10:      read_en_slipped = {read_cmd_mux_r2[1:0],read_cmd_mux_r3[3:2]};
             4'd11:      read_en_slipped = {read_cmd_mux_r2[0],  read_cmd_mux_r3[3:1]};
             4'd12:      read_en_slipped = read_cmd_mux_r3;
             default:    read_en_slipped = read_cmd_mux;
         endcase

    // generate the dqs_gate_pulse
    always @(*) 
    begin
        if(read_en_slipped[0]==1'b1) begin
            dqs_gate_pulse_src      = 4'b1111;
            dqs_gate_pulse_src_nxt  = 4'b0000;
        end 
        else if(read_en_slipped[1]==1'b1) begin
            dqs_gate_pulse_src      = {3'b111, dqs_gate_pulse_src_nxt_r[0]};
            dqs_gate_pulse_src_nxt  = 4'b0001;
        end
        else if(read_en_slipped[2]==1'b1) begin
            dqs_gate_pulse_src      = {2'b11, dqs_gate_pulse_src_nxt_r[1:0]};
            dqs_gate_pulse_src_nxt  = 4'b0011;
        end
        else if(read_en_slipped[3]==1'b1) begin
            dqs_gate_pulse_src      = {1'b1, dqs_gate_pulse_src_nxt_r[2:0]};
            dqs_gate_pulse_src_nxt  = 4'b0111;
        end
        else begin
            dqs_gate_pulse_src      = dqs_gate_pulse_src_nxt_r;   
            dqs_gate_pulse_src_nxt  = 4'b0000;
        end 
    end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) begin
     	 dqs_gate_pulse_src_nxt_r <= 4'b0000;
     end
     else begin
     	 dqs_gate_pulse_src_nxt_r <= dqs_gate_pulse_src_nxt;
     end
  end

///
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) begin
         dqs_gate_pulse_r1   <= 4'b00;
         dqs_gate_pulse_r2   <= 4'b00;
         dqs_gate_pulse_r3   <= 4'b00;
         dqs_gate_pulse_r4   <= 4'b00;
     end
     else  begin
         dqs_gate_pulse_r1   <= dqs_gate_pulse_src ;
         dqs_gate_pulse_r2   <= dqs_gate_pulse_r1  ;
         dqs_gate_pulse_r3   <= dqs_gate_pulse_r2  ;
         dqs_gate_pulse_r4   <= dqs_gate_pulse_r3  ;
     end
  end

     always @(*)
         case (mc_rl)
            
             5'd5:   dqs_gate_ctrl_adj = dqs_gate_pulse_src;
            
             5'd6:   dqs_gate_ctrl_adj = {dqs_gate_pulse_src[2:0],dqs_gate_pulse_r1[3]};
             
             5'd7:   dqs_gate_ctrl_adj = {dqs_gate_pulse_src[1:0],dqs_gate_pulse_r1[3:2]};
             
             5'd8:   dqs_gate_ctrl_adj = {dqs_gate_pulse_src[0],dqs_gate_pulse_r1[3:1]};

             5'd9:   dqs_gate_ctrl_adj = dqs_gate_pulse_r1;

             5'd10:  dqs_gate_ctrl_adj = {dqs_gate_pulse_r1[2:0],dqs_gate_pulse_r2[3]};
       
             5'd11:  dqs_gate_ctrl_adj = {dqs_gate_pulse_r1[1:0],dqs_gate_pulse_r2[3:2]};

             5'd12:  dqs_gate_ctrl_adj = {dqs_gate_pulse_r1[0],dqs_gate_pulse_r2[3:1]};
 
             5'd13:  dqs_gate_ctrl_adj = dqs_gate_pulse_r2;

             5'd14:  dqs_gate_ctrl_adj = {dqs_gate_pulse_r2[2:0],dqs_gate_pulse_r3[3]};
      
             5'd15:  dqs_gate_ctrl_adj = {dqs_gate_pulse_r2[1:0],dqs_gate_pulse_r3[3:2]};

             5'd16:  dqs_gate_ctrl_adj = {dqs_gate_pulse_r2[0],dqs_gate_pulse_r3[3:1]};
    
             5'd17:  dqs_gate_ctrl_adj = dqs_gate_pulse_r3;

             5'd18:  dqs_gate_ctrl_adj = {dqs_gate_pulse_r3[2:0],dqs_gate_pulse_r4[3]};

          default:   dqs_gate_ctrl_adj =  dqs_gate_pulse_src;
        endcase

     always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) // register output
     begin
         if(!ddrphy_rst_n)
             dqs_gate_ctrl_pos  <= 4'b0000;
         else
             dqs_gate_ctrl_pos  <= dqs_gate_ctrl_adj;
     end

 assign  dqs_gate_ctrl =  dqs_gate_ctrl_pos;

 //*************************************************************************************************************
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) // register output
 begin
     if(!ddrphy_rst_n) begin
        dqs_gate_vld  <= 1'b0;
        cnt           <= 5'b0;
     end
     else begin
        if (gatecal_start | rddata_cal) begin
           if (dqs_gate_ctrl_pos != 4'd0) begin
               dqs_gate_vld  <= 1'b1;
               cnt           <= 4'b0;
           end
           else if (cnt==5'd10) begin
              dqs_gate_vld <= 1'b0;
              cnt          <= 4'b0;
           end
           else
              cnt <= cnt + 4'b1;
        end
        else begin
           dqs_gate_vld  <= 1'b0;
           cnt           <= 4'b0;
        end
     end
 end

endmodule
