////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
//////////////////////////////////////////////////////////////
//Decription:
//Author: wxxiao
//Hitory: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_cpd_ctrl_v1_3 
(
input  dps_clk               ,
input  ddr_rstn              ,
input  ddrphy_cpd_start      ,
input  ddrphy_cpd_up_dnb     ,
input  ddrphy_cpd_lock       ,
input  gpll_dps_done         ,
output reg ddrphy_cpd_rstn   ,
output reg ddrphy_cpd_done   ,
output reg gpll_dps_en       ,
output reg gpll_dps_dir      ,

input       debug_cpd_offset_adj ,
input       debug_cpd_offset_dir ,
input [9:0] debug_cpd_offset,

output [3:0] debug_cpd_state,
output reg[9:0] debug_dps_cnt_dir0, 
output reg[9:0] debug_dps_cnt_dir1 

);

localparam  CPD_RST          = 4'd0;
localparam  CPD_CTRL         = 4'd1;
localparam  CPD_WAIT         = 4'd2;
localparam  CPD_DELAY        = 4'd3;
localparam  CPD_LOCK         = 4'd4;
localparam  CPD_DEC          = 4'd5;
localparam  CPD_OFFSET_JUDGE = 4'd6;
localparam  CPD_OFFSET_CTRL  = 4'd7;
localparam  CPD_OFFSET_WAIT  = 4'd8;
localparam  CPD_DONE         = 4'd9;

`ifdef IPS_DDR_SPEEDUP_SIM
localparam FAST_CPD = 1;
`else                                                              
localparam FAST_CPD = 0;      
`endif
  
`ifdef IPS_DDR_SPEEDUP_SIM                                                  
localparam DELAY_TIME  = 4'd0;
`else                                                              
localparam DELAY_TIME  = 4'd1;      
`endif  

`ifdef IPS_DDR_SPEEDUP_SIM
localparam S_DELAY_TIME = 8'd0;
`else 
localparam S_DELAY_TIME = 8'd200;
`endif

reg [3:0] cpd_state;
reg [2:0] cpd_up_d;
reg [1:0] cpd_lock_d;
reg [1:0] dps_done_d;
reg [3:0] delay_cnt;
reg [5:0] time_out;
reg       ddrphy_cpd_start_d0;
reg       ddrphy_cpd_start_d1;
reg [7:0] sure_delay;
reg [9:0] cpd_offset_cnt;
reg       dps_timeout;
reg [2:0] debug_cpd_offset_adj_d;
reg       debug_cpd_offset_adj_pos;

assign debug_cpd_state = cpd_state;

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    cpd_up_d <= 3'b000;
    else
    cpd_up_d <= {cpd_up_d[1:0],ddrphy_cpd_up_dnb};
end


always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)begin
        cpd_lock_d <= 2'b00;
        dps_done_d <= 2'b00;
        ddrphy_cpd_start_d0 <= 0;
        ddrphy_cpd_start_d1 <= 0;
        debug_cpd_offset_adj_d <= 3'b0;
        debug_cpd_offset_adj_pos <= 1'b0;
    end
    else begin
        cpd_lock_d <= {cpd_lock_d[0],ddrphy_cpd_lock};
        dps_done_d <= {dps_done_d[0],gpll_dps_done};
        ddrphy_cpd_start_d0 <= ddrphy_cpd_start;
        ddrphy_cpd_start_d1 <= ddrphy_cpd_start_d0;
        debug_cpd_offset_adj_d <= {debug_cpd_offset_adj_d[1:0],debug_cpd_offset_adj};
        debug_cpd_offset_adj_pos <= ~debug_cpd_offset_adj_d[2] & debug_cpd_offset_adj_d[1];
    end
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    	delay_cnt <= 4'd0;
    else if(cpd_state == CPD_DELAY)
    	delay_cnt <= delay_cnt + 4'd1;
    else 
    	delay_cnt <= 4'd0;
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    	time_out <= 6'd0;
    else if((cpd_state == CPD_WAIT) || (cpd_state == CPD_OFFSET_WAIT))
    	time_out <= time_out + 6'd1;
    else 
    	time_out <= 6'd0;
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    cpd_state <= CPD_RST;
    else begin
        case(cpd_state)
            CPD_RST:begin
                if(ddrphy_cpd_start_d1)
                	cpd_state <= CPD_DELAY;
            end
            CPD_CTRL:begin
                  if(cpd_lock_d[1] == 1'b1)
                  	cpd_state <= CPD_LOCK;
                  else 
                  	cpd_state <= CPD_WAIT;
            end
            CPD_WAIT:begin
                if((dps_done_d[1] == 1'b1)||(time_out == 6'd20))
                	cpd_state <= CPD_DELAY;
            end
            CPD_DELAY:begin
                if(delay_cnt == DELAY_TIME)
                begin
                    if(cpd_lock_d[1] == 1'b1)
                    	cpd_state <= CPD_LOCK;
                    else
                    	cpd_state <= CPD_CTRL;
                end
            end
            CPD_LOCK:begin
                if(cpd_up_d != 3'b000)
                	cpd_state <= CPD_DEC;
                else if((cpd_up_d == 3'b000)&&(sure_delay == S_DELAY_TIME))
                	cpd_state <= CPD_OFFSET_JUDGE;
            end
            CPD_DEC:begin
                cpd_state <= CPD_WAIT;
            end

            CPD_OFFSET_JUDGE : begin
            	if(cpd_offset_cnt == debug_cpd_offset)
            		cpd_state <= CPD_DONE;
            	else 
            		cpd_state <= CPD_OFFSET_CTRL;
            end
            CPD_OFFSET_CTRL : begin
            	cpd_state <= CPD_OFFSET_WAIT;
            end 
            CPD_OFFSET_WAIT : begin
            	if((dps_done_d[1] == 1'b1) || (time_out == 6'd20))
             		cpd_state <= CPD_OFFSET_JUDGE;
            end
            CPD_DONE:begin
                if(debug_cpd_offset_adj_pos)
                    cpd_state <= CPD_OFFSET_JUDGE;
                else
                    cpd_state <= CPD_DONE;
            end
            default:
            cpd_state <= CPD_RST;
        endcase
    end
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    sure_delay <= 8'd0;
    else if(cpd_state == CPD_LOCK)
    sure_delay <= sure_delay + 8'd1;
    else 
    sure_delay <= 8'd0;
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    gpll_dps_en <= 0;
    else if((cpd_state == CPD_RST) || (cpd_state == CPD_DONE))
    	gpll_dps_en <= 0;
    else if((cpd_state == CPD_DEC) || (cpd_state == CPD_CTRL) || (cpd_state == CPD_OFFSET_CTRL))
    	gpll_dps_en <= 1;
    else
    gpll_dps_en <= FAST_CPD;
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    gpll_dps_dir <= 0;
    else if(cpd_state == CPD_CTRL)
    gpll_dps_dir <= ~cpd_up_d[2];
    else if(cpd_state == CPD_DEC)
    	gpll_dps_dir <= 0;
    else if(cpd_state == CPD_OFFSET_CTRL)
    	gpll_dps_dir <= debug_cpd_offset_dir;
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    	cpd_offset_cnt <= 10'd0;
    else if(cpd_state == CPD_DONE)
    	cpd_offset_cnt <= 10'd0;
    else if(dps_done_d[1] && (cpd_state == CPD_OFFSET_WAIT)) begin
    	if(cpd_offset_cnt == 10'd1023)
    		cpd_offset_cnt <= cpd_offset_cnt;
    	else 
    		cpd_offset_cnt <= cpd_offset_cnt + 10'd1;
    end
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
        dps_timeout <= 1'b0;
    else if((cpd_state == CPD_WAIT) & (time_out == 6'd20))
        dps_timeout <= 1'b1;
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    	debug_dps_cnt_dir0 <= 10'd0;
    else if(gpll_dps_en & (~gpll_dps_dir) & (~dps_timeout)) begin
    	if(debug_dps_cnt_dir0 == 10'd1023)
    		debug_dps_cnt_dir0 <= debug_dps_cnt_dir0;
    	else 
    		debug_dps_cnt_dir0 <= debug_dps_cnt_dir0 + 1'b1;
    end
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    	debug_dps_cnt_dir1 <= 10'd0;
    else if(gpll_dps_en & gpll_dps_dir & (~dps_timeout)) begin
    	if(debug_dps_cnt_dir1 == 10'd1023)
    		debug_dps_cnt_dir1 <= debug_dps_cnt_dir1;
    	else 
    		debug_dps_cnt_dir1 <= debug_dps_cnt_dir1 + 1'b1;
    end
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    begin
        ddrphy_cpd_rstn <= 1'b0;
        ddrphy_cpd_done <= 1'b0;
    end
    else
    begin
        ddrphy_cpd_rstn <= ~(cpd_state == CPD_RST);
        ddrphy_cpd_done <= cpd_state == CPD_DONE;
    end
end

endmodule

