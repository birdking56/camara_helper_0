////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2015 Shenzhen Pango Microsystems CO.,LTD                       
// All Rights Reserved.                                                         
////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module test_main_ctrl #(
parameter CTRL_ADDR_WIDTH = 28,
parameter MEM_DQ_WIDTH = 16,
parameter MEM_SPACE_AW = 18
)(
   input clk,
   input rst_n,
   
   input ddrc_init_done,
   output reg init_start,
   input init_done,
   output reg write_en,
   input  write_done_p,
   output reg read_en,
   input  read_done_p,
   output reg  wr_data_chg,
   output reg rd_data_chg,
   input  dbg_test_start_en ,
   output reg [3:0] state   ,
   input  stress_test       ,
   output reg stress_test_valid  ,
   input   [2:0]  rd_cnt
);

wire [127:0] prbs_dout;
wire random_write_en;
reg  [5:0]  wr_cmd_cnt ;

localparam E_IDLE      = 4'd0;
localparam E_INIT      = 4'd1;
localparam E_WR        = 4'd2;
localparam E_RD        = 4'd3;
localparam E_END       = 4'd4;

always @(posedge clk or negedge rst_n)
    if (!rst_n)
        stress_test_valid <= 1'b0 ;
    else if(wr_cmd_cnt == 6'd0)
        stress_test_valid <=  stress_test ;
    else   
        stress_test_valid <= stress_test_valid ;

//reg [3:0] state;
always @(posedge clk or negedge rst_n)
   if (!rst_n) begin
      state    <= E_IDLE;
      write_en <= 1'b0;
      read_en  <= 1'b0;
      init_start <= 1'b0;
   end
   else begin
            case (state)
               E_IDLE: begin
                  if (ddrc_init_done)
                     //state <= E_INIT;
                     state <= E_WR;
                     else
                     state <= E_IDLE;
               end
               E_INIT : begin
                init_start <= 1'b1;
                if(init_done) begin
                state <= E_WR;
                init_start <= 1'b0;
            end
            end
               E_WR: begin
                  if (write_done_p) begin
                     write_en <= 1'b0;
                     state <= E_END;
                  end
                  else
                     write_en <= 1'b1;
               end
               E_RD: begin
                  if (read_done_p) begin
                     read_en <= 1'b0;
                     state <= E_END;
                  end
                  else
                     read_en <= 1'b1;                  
               end               
               E_END: begin
                  if(~dbg_test_start_en)
                     state <= E_END;
               	  else if (~wr_cmd_cnt[5])  // ((random_write_en & ~stress_test) | (stress_test & (~wr_cmd_cnt[5])))
               	     state <= E_WR;
               	  else
               	     state <= E_RD;
               end
               default: begin
                  state <= E_IDLE;
               end                                               
      endcase
   end
   
always @(posedge clk or negedge rst_n)
   if (!rst_n) 
       wr_cmd_cnt <= 6'd0 ;
   else if(((state ==2) & write_done_p ) | ((state==3) & read_done_p) ) 
       wr_cmd_cnt <= wr_cmd_cnt + 1;
   else 
       wr_cmd_cnt <= wr_cmd_cnt ;
       
//assign wr_data_chg = wr_cmd_cnt[5:4] == 2'b01 ;
//assign rd_data_chg = wr_cmd_cnt[5:4] == 2'b11 ;

always @(posedge clk or negedge rst_n)
    if (!rst_n) 
        wr_data_chg <= 1'b0 ;
    else if((wr_cmd_cnt == 6'h10) &  write_done_p)
        wr_data_chg <= 1'b1;
    else if((wr_cmd_cnt ==6'h0) & write_done_p )
        wr_data_chg <= 1'b0;
    else ; 

always @(posedge clk or negedge rst_n)
    if (!rst_n) 
        rd_data_chg <= 1'b0 ;
    else if((wr_cmd_cnt[5:4] == 2'b11) & (rd_cnt == 3'b1))
        rd_data_chg <= 1'b1;
    else if( wr_cmd_cnt[5:4] == 2'b10 )
        rd_data_chg <= 1'b0;
    else ;
   
assign prbs_clk_en = write_done_p | read_done_p;

endmodule
