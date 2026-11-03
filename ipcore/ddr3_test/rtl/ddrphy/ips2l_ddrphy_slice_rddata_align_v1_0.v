////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                   
// ALL RIGHTS REVERVED.                                         
////////////////////////////////////////////////////////////////
//Description:                                                  
//Author:  wxxiao                                               
//History: v1.0                                                 
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module  ips2l_ddrphy_slice_rddata_align_v1_0 #(
  parameter MEM_DQ_WIDTH       = 16,
  parameter MEM_DQS_WIDTH      = 2
)(
  input                        ddrphy_sysclk    ,
  input                        ddrphy_rst_n     ,
                                   
  input [MEM_DQS_WIDTH-1:0]    dqs_read_valid   ,
  input [8*MEM_DQ_WIDTH-1:0]   dqs_read_data    ,

  output                       dqs_align_valid  ,
  output [8*MEM_DQ_WIDTH-1:0]  dqs_align_data   ,
  output reg                   align_error
  );                                      
      
  reg [8*MEM_DQ_WIDTH-1:0]  dqs_read_data_r   ;
  reg [MEM_DQS_WIDTH-1:0]   dqs_read_valid_r  ;
  integer i,j;                                 
  reg                      aligned_valid_comb; 
  reg [MEM_DQS_WIDTH-1:0]  read_valid_sel    ;
  reg [8*MEM_DQ_WIDTH-1:0] aligned_data_comb ;
  reg                      error_comb        ;
                                                  
  //***************************************************************
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)          
        dqs_read_data_r  <= {(8*MEM_DQ_WIDTH){1'b0}};
     else
        dqs_read_data_r  <= dqs_read_data ;
  end
                                         
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)                                  
        dqs_read_valid_r  <= {MEM_DQS_WIDTH{1'b0}};
     else if(|dqs_read_valid_r)  
         dqs_read_valid_r <= dqs_read_valid_r & dqs_read_valid;
     else
         dqs_read_valid_r <= dqs_read_valid;
  end
                                         
   always @(*) 
   begin                    
     if (|dqs_read_valid_r) begin //send out data
          aligned_valid_comb  = 1'b1;            
          read_valid_sel      = dqs_read_valid_r;
          error_comb          = ~(&(dqs_read_valid_r | dqs_read_valid));
     end                             
     else begin                      
          aligned_valid_comb = 1'b0; 
          read_valid_sel     = 2'b0; 
          error_comb         = 1'b0; 
     end                             
   end                               
                               
   always @(*) 
   begin                                   
   	 for (i=0;i<MEM_DQS_WIDTH;i=i+1) begin 
   	 	  if (read_valid_sel[i]) begin     
   	 	  	 for (j=0;j<64;j=j+1)          
   	 	        aligned_data_comb[i*64+j] = dqs_read_data_r[i*64+j];
   	 	  end                                                       
   	 	  else begin                                                
   	 	  	 for (j=0;j<64;j=j+1)                                   
   	 	        aligned_data_comb[i*64+j] = dqs_read_data[i*64+j];  
   	 	  end                                   
   	 end                                        
   end                                          
                
  assign dqs_align_valid =  aligned_valid_comb; 
  assign dqs_align_data  =  aligned_data_comb;  
     
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n)              
          align_error <= 1'b0; 
     else                            
     	  align_error <= error_comb;
  end
     
endmodule                            
