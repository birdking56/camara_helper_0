////////////////////////////////////////////////////////////////       
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                          
// ALL RIGHTS REVERVED.                                                
////////////////////////////////////////////////////////////////       
//Description:                                                         
//Author: wxxiao                                                      
//History: v1.0                                                        
//////////////////////////////////////////////////////////////// 
`timescale 1ns/10ps  
module ips2l_ddrphy_drift_ctrl_v1_0
(
  input            ddrphy_sysclk          ,
  input            ddrphy_rst_n           ,
  input            calib_done             ,
  input      [1:0] dqs_drift              ,
  input            ddrphy_update_req      ,
  input            ddrphy_update_done     ,
  output reg [1:0] ddrphy_update_comp_val ,
  output reg       ddrphy_update_comp_dir 
);

reg [1:0] dqs_drift_d1;
reg [1:0] dqs_drift_d2;
reg [1:0] dqs_drift_now;
reg [1:0] dqs_drift_last;

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if (!ddrphy_rst_n) begin
    dqs_drift_d1  <= 2'b00;
    dqs_drift_d2  <= 2'b00;
    dqs_drift_now <= 2'b00;
//    dqs_drift_last<= 2'b00;
    end
    else if((!calib_done)||(ddrphy_update_req))
    begin
        dqs_drift_d1  <= dqs_drift;
        dqs_drift_d2  <= dqs_drift_d1;
        dqs_drift_now <= dqs_drift_d2;
//        dqs_drift_last<= dqs_drift_now;
    end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if (!ddrphy_rst_n) 
    dqs_drift_last<= 2'b00;
    else if((!calib_done)||(ddrphy_update_done))
    dqs_drift_last<= dqs_drift_now;
end

always @(dqs_drift_last or dqs_drift_now)
begin
    case (dqs_drift_last)
        2'b00:begin
            if (dqs_drift_now == 2'b01) begin
               ddrphy_update_comp_val <= 2'b1;
               ddrphy_update_comp_dir <= 1'b1; 
            end
            else if (dqs_drift_now == 2'b10) begin
               ddrphy_update_comp_val <= 2'b1;
               ddrphy_update_comp_dir <= 1'b0;                 
            end
            else begin
               ddrphy_update_comp_val <= 2'b0;
               ddrphy_update_comp_dir <= 1'b0;  
            end
        end
        2'b01:begin
             if (dqs_drift_now == 2'b11) begin
               ddrphy_update_comp_val <= 2'b1;
               ddrphy_update_comp_dir <= 1'b1; 
            end
            else if (dqs_drift_now == 2'b00) begin
               ddrphy_update_comp_val <= 2'b1;
               ddrphy_update_comp_dir <= 1'b0;                 
            end
            else begin
               ddrphy_update_comp_val <= 2'b0;
               ddrphy_update_comp_dir <= 1'b0;  
            end
        end
        2'b10:begin
             if (dqs_drift_now == 2'b00) begin
               ddrphy_update_comp_val <= 2'b1;
               ddrphy_update_comp_dir <= 1'b1; 
            end
            else if (dqs_drift_now == 2'b11) begin
               ddrphy_update_comp_val <= 2'b1;
               ddrphy_update_comp_dir <= 1'b0;                 
            end
            else begin
               ddrphy_update_comp_val <= 2'b0;
               ddrphy_update_comp_dir <= 1'b0;  
            end            
        end
        2'b11:begin
             if (dqs_drift_now == 2'b10) begin
               ddrphy_update_comp_val <= 2'b1;
               ddrphy_update_comp_dir <= 1'b1; 
            end
            else if (dqs_drift_now == 2'b01) begin
               ddrphy_update_comp_val <= 2'b1;
               ddrphy_update_comp_dir <= 1'b0;                 
            end
            else begin
               ddrphy_update_comp_val <= 2'b0;
               ddrphy_update_comp_dir <= 1'b0;  
            end            
        end
        default: begin
               ddrphy_update_comp_val <= 2'b0;
               ddrphy_update_comp_dir <= 1'b0;             
        end
    endcase        
end
   
endmodule