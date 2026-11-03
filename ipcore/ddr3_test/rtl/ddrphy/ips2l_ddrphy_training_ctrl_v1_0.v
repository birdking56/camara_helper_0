////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                   
// ALL RIGHTS REVERVED.                                         
////////////////////////////////////////////////////////////////
//Description:                                                  
//Author:  wxxiao                                               
//History: v1.0                                                 
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_training_ctrl_v1_0
(
    input                ddrphy_sysclk                  ,
    input                ddrphy_rst_n                   ,
    input                ddrphy_rst_req                 ,
    output               ddrphy_rst_ack                 ,
    output reg           ddrphy_dqs_training_rstn  
);

parameter SRB_DQS_RST_TRAINING_HIGH_CLK = 3;

reg ddrphy_rst_req_d1; 
reg ddrphy_rst_req_d2;
reg ddrphy_rst_req_d3;
reg ddrphy_dqs_training_rstn_d;
wire ddrphy_rst_req_p;

always @ (posedge ddrphy_sysclk) 
begin
    ddrphy_rst_req_d1 <= ddrphy_rst_req;
    ddrphy_rst_req_d2 <= ddrphy_rst_req_d1;
    ddrphy_rst_req_d3 <= ddrphy_rst_req_d2;
end

assign ddrphy_rst_req_p = ddrphy_rst_req_d2 & ~ddrphy_rst_req_d3;

reg [2:0] dqs_rst_training_high_cnt;

always @ (posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if (!ddrphy_rst_n)
        dqs_rst_training_high_cnt <= 3'h0;
    else if (ddrphy_rst_req_p)
        dqs_rst_training_high_cnt <= SRB_DQS_RST_TRAINING_HIGH_CLK;
    else if (|dqs_rst_training_high_cnt)
        dqs_rst_training_high_cnt <= dqs_rst_training_high_cnt - 3'h1;
    else
        dqs_rst_training_high_cnt <= dqs_rst_training_high_cnt;
end

//CLK_AND_RST_PLAN = 1, not to reset clk for default plan
always @ (posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if (!ddrphy_rst_n)
        ddrphy_dqs_training_rstn <= 1'b0;
    else if (|dqs_rst_training_high_cnt)
        ddrphy_dqs_training_rstn <= 1'b0;
    else
        ddrphy_dqs_training_rstn <= 1'b1;
end

always @ (posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if (!ddrphy_rst_n)
        ddrphy_dqs_training_rstn_d <= 1'b0;
    else
        ddrphy_dqs_training_rstn_d <= ddrphy_dqs_training_rstn;
end

assign ddrphy_rst_ack = ddrphy_dqs_training_rstn & (~ddrphy_dqs_training_rstn_d);

endmodule