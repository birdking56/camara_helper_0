////////////////////////////////////////////////////////////////    
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                       
// ALL RIGHTS REVERVED.                                             
////////////////////////////////////////////////////////////////    
//Description:                                                      
//Author:  wxxiao                                                   
//History: v1.0                                                     
////////////////////////////////////////////////////////////////    
`timescale 1ns/1ps   
module ips2l_ddrphy_main_ctrl_v1_9 #(
   //parameter
   parameter [1:0] DDR_TYPE     = 2'b00 ,  //2'b00:DDR3  2'b01:DDR2  2'b10:LPDDR
   parameter       EYECAL_EN    = 1     
)(
   //port             
   input      ddrphy_sysclk ,
   input      ddrphy_rst_n ,
                         
   input      update_cal_req,
                    
   output reg init_start   ,
   input      init_done    ,
   
   input      wrlvl_en     ,
   output reg wrlvl_start  ,
   input      wrlvl_done   ,

   output reg rdcal_start  ,
   input      rdcal_done   ,

   output reg wrcal_start  ,
   input      wrcal_done   ,
   
   output reg eyecal_start ,
   input      eyecal_done  ,
                      
   output reg update_start ,
   input      update_done  ,
                      
   output [7:0] dbg_main   ,

   input    wrlvl_error      ,
   input    gate_cal_error   ,
   input    rdel_calib_error ,
   input    wrcal_error      ,

//   input      enter_dpd   ,
//   input      exit_dpd    ,                      
   output reg calib_done  

  );
  
  localparam  IDLE_PHASE   =4'h0;
  localparam  INIT_PHASE   =4'h1;
  localparam  WRLVL_PHASE  =4'h2;
  localparam  RDCAL_PHASE  =4'h3;
  localparam  WRCAL_PHASE  =4'h4;
  localparam  EYECAL_PHASE =4'h5;
  localparam  UPDATE_PHASE =4'h6;
  localparam  DDRC_PHASE   =4'h7;
  
  reg [3:0] main_state;   
  reg [3:0] main_next_state;
  reg [3:0] error_status /* synthesis PAP_MARK_DEBUG = "1" */;
    
  
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)
        main_state  <= IDLE_PHASE;
    else 
        main_state  <= main_next_state;
  end
  
  always @(*) 
  begin
        main_next_state = main_state;  
    case(main_state)      
          IDLE_PHASE   : main_next_state = INIT_PHASE ; 
          
          INIT_PHASE   : if(init_done)
                           begin
                            if((wrlvl_en == 1)&&(DDR_TYPE == 2'b00))          //WL enable & DDR3
                                main_next_state = WRLVL_PHASE;
//                            else  if (exit_dpd)
//                                main_next_state = DDRC_PHASE;
                            else 
                                main_next_state = RDCAL_PHASE;   
                           end                       
                          else 
                                main_next_state = INIT_PHASE ;
          
          WRLVL_PHASE  : if(wrlvl_done)                      //write levling done
                            main_next_state = RDCAL_PHASE ;
                         else 
                            main_next_state = WRLVL_PHASE ;
          
          RDCAL_PHASE  : if(rdcal_done) begin                      //read calibration done
//                            if(WRCAL_EN == 1)
                            main_next_state = WRCAL_PHASE;
//                            else
//                            main_next_state = DDRC_PHASE;
                         end
                         else 
                            main_next_state = RDCAL_PHASE; 
                            
          WRCAL_PHASE : if(wrcal_done) begin                     //write calibration done
                           if(EYECAL_EN == 1)
                           main_next_state = EYECAL_PHASE;
                           else
                           main_next_state = DDRC_PHASE;
                         end
                         else 
                            main_next_state = WRCAL_PHASE;
                            
          EYECAL_PHASE : if(eyecal_done)                   //sample calibration done
                            main_next_state = DDRC_PHASE;
                         else 
                            main_next_state = EYECAL_PHASE;
                            
          DDRC_PHASE   : if(update_cal_req)                  //update calibration request
                            main_next_state = UPDATE_PHASE;
                         else begin
//                            if(exit_dpd & enter_dpd)
//                              main_next_state =  INIT_PHASE;
//                            else
                            main_next_state = DDRC_PHASE ;
                        end
                          
          UPDATE_PHASE : if(update_done)                     //update calibration done
                            main_next_state = DDRC_PHASE;
                         else
                            main_next_state = UPDATE_PHASE;
            
      endcase
  end
  
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)  
       init_start  <= 1'b0;
    else if(main_next_state == INIT_PHASE)
       init_start  <= 1'b1;
    else 
       init_start  <= 1'b0;
  end
              
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                             
       wrlvl_start  <= 1'b0;                       
    else if(main_next_state == WRLVL_PHASE)        
       wrlvl_start  <= 1'b1;                       
    else                                          
       wrlvl_start  <= 1'b0;                    
  end
       
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                           
       rdcal_start  <= 1'b0;                    
    else if(main_next_state == RDCAL_PHASE)     
       rdcal_start  <= 1'b1;                    
    else                                        
       rdcal_start  <= 1'b0;   
  end
       
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                                     
       wrcal_start  <= 1'b0;                              
    else if(main_next_state == WRCAL_PHASE)               
       wrcal_start  <= 1'b1;                              
    else                                                  
       wrcal_start  <= 1'b0;                           
  end
   
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                                     
       eyecal_start  <= 1'b0;                              
    else if(main_next_state == EYECAL_PHASE)               
       eyecal_start  <= 1'b1;                              
    else                                                  
       eyecal_start  <= 1'b0;                           
  end
   
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                             
       update_start  <= 1'b0;                      
    else if(main_next_state == UPDATE_PHASE)       
       update_start  <= 1'b1;                      
    else                                          
       update_start  <= 1'b0;  
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                                   
        calib_done  <= 1'b0;
    else if(main_next_state == DDRC_PHASE) 
        calib_done  <= 1'b1;   
    else
        calib_done  <= 1'b0;   
  end


always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) begin
    if (!ddrphy_rst_n)
        error_status <= 4'd0;
    else begin
        if (main_state == IDLE_PHASE) 
            error_status <= 4'd0;		
        else if ((main_state == WRLVL_PHASE) & wrlvl_error)
            error_status <= 4'd1;
        else if ((main_state == RDCAL_PHASE) & gate_cal_error)
            error_status <= 4'd2;
        else if ((main_state == RDCAL_PHASE) & rdel_calib_error)
            error_status <= 4'd3;
        else if ((main_state == WRCAL_PHASE) & wrcal_error)
            error_status <= 4'd4;
        else if ((main_state == EYECAL_PHASE) & rdel_calib_error)
            error_status <= 4'd5;
    	else
            error_status <= error_status;
    end
end

assign dbg_main =  {error_status,main_state} ;   
       
endmodule           
    
    
                                         
  
  
  

  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
