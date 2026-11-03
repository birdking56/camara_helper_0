////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module ips2l_ddrphy_upcal_v1_0 #(
  parameter   MEM_DQS_WIDTH       = 2
)(                            
  input                            ddrphy_sysclk      ,
  input                            ddrphy_rst_n       ,
                                   
  input                            update_start       ,
  output reg                       update_done        ,
                                   
//  input                            dll_update_ack     ,
//  output reg                       dll_update_req     ,
 
  input [2*MEM_DQS_WIDTH-1:0]      update_comp_val    ,
  input [MEM_DQS_WIDTH-1:0]        update_comp_dir    ,
  output reg [2*MEM_DQS_WIDTH-1:0] comp_val           ,
  output reg [MEM_DQS_WIDTH-1:0]   comp_dir           ,
  output reg                       dqs_gate_comp_en   ,
  input                            dqs_gate_comp_done ,
  output [3:0]                     dbg_upcal  
);

localparam  UPCAL_IDLE           = 4'd0 ;
//localparam  UPCAL_DLL            = 4'd1 ;
localparam  UPCAL_READJ_DQS_STEP = 4'd1 ;
localparam  UPCAL_DONE           = 4'd2 ;

reg  [3:0]    upcal_state;
reg  [3:0]    upcal_state_next;
//reg  [1:0]    dll_update_ack_sync;  
reg  [7:0]    cnt;

//  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
//  begin
//     if(!ddrphy_rst_n)
//        dll_update_ack_sync  <= 2'b0 ;
//     else
//        dll_update_ack_sync  <= {dll_update_ack_sync[0],dll_update_ack};
//  end

// always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) 
// begin
//     if(!ddrphy_rst_n)
//        dll_update_req     <=  1'b0 ;
//     else 
//        dll_update_req     <= (upcal_state_next == UPCAL_DLL);
// end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
    if(!ddrphy_rst_n)
         begin
           comp_val <= {MEM_DQS_WIDTH{2'b00}};
           comp_dir <= {MEM_DQS_WIDTH{1'b0}};
           dqs_gate_comp_en <= 1'b0;
         end      
    else if (upcal_state_next == UPCAL_READJ_DQS_STEP)
         begin
           comp_val <= update_comp_val;
           comp_dir <= update_comp_dir;
           dqs_gate_comp_en <= 1'b1;
         end
     else 
         begin
           comp_val <= {MEM_DQS_WIDTH{2'b00}};
           comp_dir <= {MEM_DQS_WIDTH{1'b0}};
           dqs_gate_comp_en <= 1'b0;
         end
end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)
         upcal_state   <= UPCAL_IDLE;
     else 
         upcal_state   <= upcal_state_next;
  end

  always @(*)  
  begin
       upcal_state_next = UPCAL_IDLE;
       case (upcal_state)
               UPCAL_IDLE          : begin
                                        if(update_start)  begin
//                                           case(update_type)
//                                                2'b01: begin      
                                                           upcal_state_next = UPCAL_READJ_DQS_STEP ;
//                                                       end
//
//                                          2'b00,2'b11: begin
//                                                           upcal_state_next = UPCAL_DLL;
//                                                       end
//                                              default:   upcal_state_next = UPCAL_IDLE ;
//                                           endcase
                                        end
                                        else
                                               upcal_state_next = UPCAL_IDLE ;
                                     end

//               UPCAL_DLL           : begin
//                                       if(dll_update_ack_sync[1]) begin
//                                          case (update_type)
//                                                2'b00 :  upcal_state_next  = UPCAL_DONE ;
//                                                2'b11 :  upcal_state_next  = UPCAL_READJ_DQS_STEP;
//                                               default:  upcal_state_next  = UPCAL_DONE;
//                                          endcase
//                                       end
//                                       else
//                                           upcal_state_next  = UPCAL_DLL;
//                                     end                    

             UPCAL_READJ_DQS_STEP : begin
                                      // if(dqs_gate_adj_done)
                                       if (dqs_gate_comp_done)
                                          upcal_state_next  =  UPCAL_DONE ;
                                       else
                                          upcal_state_next  =  UPCAL_READJ_DQS_STEP ;
                                    end                                         

               UPCAL_DONE          : begin
                                        if(~|cnt)
                                           upcal_state_next = UPCAL_IDLE ;
                                        else
                                           upcal_state_next = UPCAL_DONE ;
                                     end
               default:
                       upcal_state_next = UPCAL_IDLE ;
            endcase
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n)
          cnt    <=  8'h0;
     else if(upcal_state_next == UPCAL_DONE)
     begin
          if(cnt[4])
             cnt   <= 8'h0 ;
          else
             cnt   <= cnt + 8'h1;
     end
     else
         cnt   <= 8'h0 ;
  end


 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
    if(!ddrphy_rst_n)
        update_done   <= 1'b0;
    else
        update_done    <= ((upcal_state_next == UPCAL_DONE)& cnt[4]) ;
 end

assign dbg_upcal = upcal_state_next;

endmodule
   
