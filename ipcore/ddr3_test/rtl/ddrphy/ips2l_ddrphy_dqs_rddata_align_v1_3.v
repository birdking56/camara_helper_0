////////////////////////////////////////////////////////////////   
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                      
// ALL RIGHTS REVERVED.                                            
////////////////////////////////////////////////////////////////   
//Description:                                                     
//Author:  wxxiao                                                  
//History: v1.0                                                    
////////////////////////////////////////////////////////////////   
`timescale 1ns/1ps                                                 
module ips2l_ddrphy_dqs_rddata_align_v1_3 #(
    parameter TEST_DATA_PATTERN0 = 64'h55_aa_55_aa_08_f7_08_f7,
    parameter TEST_DATA_PATTERN1 = 64'h7f_9f_7f_9f_80_fe_80_fe,
    parameter TEST_DATA_PATTERN2 = 64'hf0_0f_f0_0f_01_ff_01_ff,
    parameter TEST_DATA_PATTERN3 = 64'hdf_aa_df_aa_55_aa_55_aa
)(
    input               ddrphy_sysclk          ,
    input               ddrphy_rst_n           ,

    input               ddrphy_read_valid      ,
    input      [63:0]   ddrphy_rdata           ,
    output        	    read_valid             ,
    output     [63:0]   read_data              ,
    input               gate_adj_done          ,
    output reg          rddata_check_pass      ,
    input               dqs_gate_vld           ,
    input               bitslip_ctrl           ,
    output reg          bitslip_dq             ,
    
    input               write_calibration      ,
    input               wrcal_move_done        ,
    output reg          wrdata_check_pass      ,
    
    input               eye_calibration        ,
    input               eyecal_move_done       ,
    
    input               rdel_cal_vld           ,
    output reg          rdel_rvalid0           ,
    output reg          rdel_rvalid1           ,
    output     [7:0]    dbg_slice_rdchk_state 
   );

  localparam GDETECT_IDLE   = 3'd0;
  localparam GDETECT_DATA1  = 3'd1;
  localparam GDETECT_DATA2  = 3'd2;
  localparam GDETECT_JUDGE  = 3'd3;
  localparam GDETECT_WAIT   = 3'd4;
  
  localparam RDCHECK_IDLE  = 4'd0;
  localparam RDCHECK_DATA0 = 4'd1;
  localparam RDCHECK_DATA1 = 4'd2;
  localparam RDCHECK_DATA2 = 4'd3;
  localparam RDCHECK_DATA3 = 4'd4;
  localparam RDCHECK_JUDGE = 4'd5;
  localparam RDCHECK_WAIT  = 4'd6;

  localparam DATA_PATTERN0_EVEN = {TEST_DATA_PATTERN0[63],TEST_DATA_PATTERN0[61],TEST_DATA_PATTERN0[59],TEST_DATA_PATTERN0[57],TEST_DATA_PATTERN0[55],TEST_DATA_PATTERN0[53],TEST_DATA_PATTERN0[51],TEST_DATA_PATTERN0[49],
                                   TEST_DATA_PATTERN0[47],TEST_DATA_PATTERN0[45],TEST_DATA_PATTERN0[43],TEST_DATA_PATTERN0[41],TEST_DATA_PATTERN0[39],TEST_DATA_PATTERN0[37],TEST_DATA_PATTERN0[35],TEST_DATA_PATTERN0[33],
                                   TEST_DATA_PATTERN0[31],TEST_DATA_PATTERN0[29],TEST_DATA_PATTERN0[27],TEST_DATA_PATTERN0[25],TEST_DATA_PATTERN0[23],TEST_DATA_PATTERN0[21],TEST_DATA_PATTERN0[19],TEST_DATA_PATTERN0[17],
                                   TEST_DATA_PATTERN0[15],TEST_DATA_PATTERN0[13],TEST_DATA_PATTERN0[11],TEST_DATA_PATTERN0[9] ,TEST_DATA_PATTERN0[7] ,TEST_DATA_PATTERN0[5] ,TEST_DATA_PATTERN0[3] ,TEST_DATA_PATTERN0[1]};

  localparam DATA_PATTERN0_ODD = {TEST_DATA_PATTERN0[62],TEST_DATA_PATTERN0[60],TEST_DATA_PATTERN0[58],TEST_DATA_PATTERN0[56],TEST_DATA_PATTERN0[54],TEST_DATA_PATTERN0[52],TEST_DATA_PATTERN0[50],TEST_DATA_PATTERN0[48],
                                  TEST_DATA_PATTERN0[46],TEST_DATA_PATTERN0[44],TEST_DATA_PATTERN0[42],TEST_DATA_PATTERN0[40],TEST_DATA_PATTERN0[38],TEST_DATA_PATTERN0[36],TEST_DATA_PATTERN0[34],TEST_DATA_PATTERN0[32],
                                  TEST_DATA_PATTERN0[30],TEST_DATA_PATTERN0[28],TEST_DATA_PATTERN0[26],TEST_DATA_PATTERN0[24],TEST_DATA_PATTERN0[22],TEST_DATA_PATTERN0[20],TEST_DATA_PATTERN0[18],TEST_DATA_PATTERN0[16],
                                  TEST_DATA_PATTERN0[14],TEST_DATA_PATTERN0[12],TEST_DATA_PATTERN0[10],TEST_DATA_PATTERN0[8] ,TEST_DATA_PATTERN0[6] ,TEST_DATA_PATTERN0[4] ,TEST_DATA_PATTERN0[2] ,TEST_DATA_PATTERN0[0]};

  localparam DATA_PATTERN1_EVEN = {TEST_DATA_PATTERN1[63],TEST_DATA_PATTERN1[61],TEST_DATA_PATTERN1[59],TEST_DATA_PATTERN1[57],TEST_DATA_PATTERN1[55],TEST_DATA_PATTERN1[53],TEST_DATA_PATTERN1[51],TEST_DATA_PATTERN1[49],
                                   TEST_DATA_PATTERN1[47],TEST_DATA_PATTERN1[45],TEST_DATA_PATTERN1[43],TEST_DATA_PATTERN1[41],TEST_DATA_PATTERN1[39],TEST_DATA_PATTERN1[37],TEST_DATA_PATTERN1[35],TEST_DATA_PATTERN1[33],
                                   TEST_DATA_PATTERN1[31],TEST_DATA_PATTERN1[29],TEST_DATA_PATTERN1[27],TEST_DATA_PATTERN1[25],TEST_DATA_PATTERN1[23],TEST_DATA_PATTERN1[21],TEST_DATA_PATTERN1[19],TEST_DATA_PATTERN1[17],
                                   TEST_DATA_PATTERN1[15],TEST_DATA_PATTERN1[13],TEST_DATA_PATTERN1[11],TEST_DATA_PATTERN1[9] ,TEST_DATA_PATTERN1[7] ,TEST_DATA_PATTERN1[5] ,TEST_DATA_PATTERN1[3] ,TEST_DATA_PATTERN1[1]};

  localparam DATA_PATTERN1_ODD = {TEST_DATA_PATTERN1[62],TEST_DATA_PATTERN1[60],TEST_DATA_PATTERN1[58],TEST_DATA_PATTERN1[56],TEST_DATA_PATTERN1[54],TEST_DATA_PATTERN1[52],TEST_DATA_PATTERN1[50],TEST_DATA_PATTERN1[48],
                                  TEST_DATA_PATTERN1[46],TEST_DATA_PATTERN1[44],TEST_DATA_PATTERN1[42],TEST_DATA_PATTERN1[40],TEST_DATA_PATTERN1[38],TEST_DATA_PATTERN1[36],TEST_DATA_PATTERN1[34],TEST_DATA_PATTERN1[32],
                                  TEST_DATA_PATTERN1[30],TEST_DATA_PATTERN1[28],TEST_DATA_PATTERN1[26],TEST_DATA_PATTERN1[24],TEST_DATA_PATTERN1[22],TEST_DATA_PATTERN1[20],TEST_DATA_PATTERN1[18],TEST_DATA_PATTERN1[16],
                                  TEST_DATA_PATTERN1[14],TEST_DATA_PATTERN1[12],TEST_DATA_PATTERN1[10],TEST_DATA_PATTERN1[8] ,TEST_DATA_PATTERN1[6] ,TEST_DATA_PATTERN1[4] ,TEST_DATA_PATTERN1[2] ,TEST_DATA_PATTERN1[0]};

  localparam DATA_PATTERN2_EVEN = {TEST_DATA_PATTERN2[63],TEST_DATA_PATTERN2[61],TEST_DATA_PATTERN2[59],TEST_DATA_PATTERN2[57],TEST_DATA_PATTERN2[55],TEST_DATA_PATTERN2[53],TEST_DATA_PATTERN2[51],TEST_DATA_PATTERN2[49],
                                   TEST_DATA_PATTERN2[47],TEST_DATA_PATTERN2[45],TEST_DATA_PATTERN2[43],TEST_DATA_PATTERN2[41],TEST_DATA_PATTERN2[39],TEST_DATA_PATTERN2[37],TEST_DATA_PATTERN2[35],TEST_DATA_PATTERN2[33],
                                   TEST_DATA_PATTERN2[31],TEST_DATA_PATTERN2[29],TEST_DATA_PATTERN2[27],TEST_DATA_PATTERN2[25],TEST_DATA_PATTERN2[23],TEST_DATA_PATTERN2[21],TEST_DATA_PATTERN2[19],TEST_DATA_PATTERN2[17],
                                   TEST_DATA_PATTERN2[15],TEST_DATA_PATTERN2[13],TEST_DATA_PATTERN2[11],TEST_DATA_PATTERN2[9] ,TEST_DATA_PATTERN2[7] ,TEST_DATA_PATTERN2[5] ,TEST_DATA_PATTERN2[3] ,TEST_DATA_PATTERN2[1]};

  localparam DATA_PATTERN2_ODD = {TEST_DATA_PATTERN2[62],TEST_DATA_PATTERN2[60],TEST_DATA_PATTERN2[58],TEST_DATA_PATTERN2[56],TEST_DATA_PATTERN2[54],TEST_DATA_PATTERN2[52],TEST_DATA_PATTERN2[50],TEST_DATA_PATTERN2[48],
                                  TEST_DATA_PATTERN2[46],TEST_DATA_PATTERN2[44],TEST_DATA_PATTERN2[42],TEST_DATA_PATTERN2[40],TEST_DATA_PATTERN2[38],TEST_DATA_PATTERN2[36],TEST_DATA_PATTERN2[34],TEST_DATA_PATTERN2[32],
                                  TEST_DATA_PATTERN2[30],TEST_DATA_PATTERN2[28],TEST_DATA_PATTERN2[26],TEST_DATA_PATTERN2[24],TEST_DATA_PATTERN2[22],TEST_DATA_PATTERN2[20],TEST_DATA_PATTERN2[18],TEST_DATA_PATTERN2[16],
                                  TEST_DATA_PATTERN2[14],TEST_DATA_PATTERN2[12],TEST_DATA_PATTERN2[10],TEST_DATA_PATTERN2[8] ,TEST_DATA_PATTERN2[6] ,TEST_DATA_PATTERN2[4] ,TEST_DATA_PATTERN2[2] ,TEST_DATA_PATTERN2[0]};

  localparam DATA_PATTERN3_EVEN = {TEST_DATA_PATTERN3[63],TEST_DATA_PATTERN3[61],TEST_DATA_PATTERN3[59],TEST_DATA_PATTERN3[57],TEST_DATA_PATTERN3[55],TEST_DATA_PATTERN3[53],TEST_DATA_PATTERN3[51],TEST_DATA_PATTERN3[49],
                                   TEST_DATA_PATTERN3[47],TEST_DATA_PATTERN3[45],TEST_DATA_PATTERN3[43],TEST_DATA_PATTERN3[41],TEST_DATA_PATTERN3[39],TEST_DATA_PATTERN3[37],TEST_DATA_PATTERN3[35],TEST_DATA_PATTERN3[33],
                                   TEST_DATA_PATTERN3[31],TEST_DATA_PATTERN3[29],TEST_DATA_PATTERN3[27],TEST_DATA_PATTERN3[25],TEST_DATA_PATTERN3[23],TEST_DATA_PATTERN3[21],TEST_DATA_PATTERN3[19],TEST_DATA_PATTERN3[17],
                                   TEST_DATA_PATTERN3[15],TEST_DATA_PATTERN3[13],TEST_DATA_PATTERN3[11],TEST_DATA_PATTERN3[9] ,TEST_DATA_PATTERN3[7] ,TEST_DATA_PATTERN3[5] ,TEST_DATA_PATTERN3[3] ,TEST_DATA_PATTERN3[1]};

  localparam DATA_PATTERN3_ODD = {TEST_DATA_PATTERN3[62],TEST_DATA_PATTERN3[60],TEST_DATA_PATTERN3[58],TEST_DATA_PATTERN3[56],TEST_DATA_PATTERN3[54],TEST_DATA_PATTERN3[52],TEST_DATA_PATTERN3[50],TEST_DATA_PATTERN3[48],
                                  TEST_DATA_PATTERN3[46],TEST_DATA_PATTERN3[44],TEST_DATA_PATTERN3[42],TEST_DATA_PATTERN3[40],TEST_DATA_PATTERN3[38],TEST_DATA_PATTERN3[36],TEST_DATA_PATTERN3[34],TEST_DATA_PATTERN3[32],
                                  TEST_DATA_PATTERN3[30],TEST_DATA_PATTERN3[28],TEST_DATA_PATTERN3[26],TEST_DATA_PATTERN3[24],TEST_DATA_PATTERN3[22],TEST_DATA_PATTERN3[20],TEST_DATA_PATTERN3[18],TEST_DATA_PATTERN3[16],
                                  TEST_DATA_PATTERN3[14],TEST_DATA_PATTERN3[12],TEST_DATA_PATTERN3[10],TEST_DATA_PATTERN3[8] ,TEST_DATA_PATTERN3[6] ,TEST_DATA_PATTERN3[4] ,TEST_DATA_PATTERN3[2] ,TEST_DATA_PATTERN3[0]};

  reg          rdvalid_r1  ;
  reg [63:0]   rddata_r1   ;
  wire [63:0]  align_rdata ;
  wire [31:0]  align_rdata0;
  wire [31:0]  align_rdata1;  
  
  reg [2:0]   gdet_state;
  reg [2:0]   gdet_next_state;
  
  reg [3:0] rdchk_state0;
  reg [3:0] rdchk_next_state0; 
  reg [3:0] rdchk_state1;     
  reg [3:0] rdchk_next_state1;
    
  reg       dqs_gate_vld_r ; 
  wire      rdel_data_vld0 ;   //posedge clk data
  wire      rdel_data_vld1 ;   //negedge clk data
  reg       slip_en;
 
//*******************************************************************
// align read_valid and read_data 
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if (!ddrphy_rst_n) begin
        rddata_r1   <= 64'h0 ;
        rdvalid_r1  <= 1'b0  ;
     end
     else begin
        rddata_r1   <= ddrphy_rdata;
        rdvalid_r1  <= ddrphy_read_valid;
     end
  end
             
  assign  align_rdata   = rddata_r1 ;
  assign  align_rdata0  = {rddata_r1[63],rddata_r1[61],rddata_r1[59],rddata_r1[57],rddata_r1[55],rddata_r1[53],rddata_r1[51],rddata_r1[49],rddata_r1[47],rddata_r1[45],rddata_r1[43],rddata_r1[41],rddata_r1[39],rddata_r1[37],rddata_r1[35],rddata_r1[33],
                           rddata_r1[31],rddata_r1[29],rddata_r1[27],rddata_r1[25],rddata_r1[23],rddata_r1[21],rddata_r1[19],rddata_r1[17],rddata_r1[15],rddata_r1[13],rddata_r1[11],rddata_r1[9] ,rddata_r1[7] ,rddata_r1[5] ,rddata_r1[3] ,rddata_r1[1]};
  assign  align_rdata1  = {rddata_r1[62],rddata_r1[60],rddata_r1[58],rddata_r1[56],rddata_r1[54],rddata_r1[52],rddata_r1[50],rddata_r1[48],rddata_r1[46],rddata_r1[44],rddata_r1[42],rddata_r1[40],rddata_r1[38],rddata_r1[36],rddata_r1[34],rddata_r1[32],
                           rddata_r1[30],rddata_r1[28],rddata_r1[26],rddata_r1[24],rddata_r1[22],rddata_r1[20],rddata_r1[18],rddata_r1[16],rddata_r1[14],rddata_r1[12],rddata_r1[10],rddata_r1[8] ,rddata_r1[6] ,rddata_r1[4] ,rddata_r1[2] ,rddata_r1[0]};                                                            

  assign rdel_data_vld0 = (align_rdata0 == {8{4'h0}}) ? 1'b1 : 1'b0;   //posedge
  assign rdel_data_vld1 = (align_rdata1 == {8{4'hf}}) ? 1'b1 : 1'b0;   //negedge
  
//  assign align_dq =  align_rdata[3:0];
//*******************************************************************//                                                
//check data in dqs gate training procedure                                                                            
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) 
        gdet_state   <=  3'h0;
     else
        gdet_state   <= gdet_next_state;
  end

  always @(*) 
  begin
       gdet_next_state  = GDETECT_IDLE ;
       case(gdet_state)
          GDETECT_IDLE : begin
                            if(dqs_gate_vld)
                               gdet_next_state  = GDETECT_DATA1;
                         end
           
         GDETECT_DATA1 : begin
                            if(gate_adj_done | bitslip_ctrl)
                               gdet_next_state = GDETECT_IDLE; 
                            else if(rdvalid_r1 &&(align_rdata== 64'hb0b0_b0b0_b0b0_b0b0))
                               gdet_next_state = GDETECT_DATA2;
                            else 
                               gdet_next_state = GDETECT_DATA1;
                          end

        GDETECT_DATA2 :  begin
                            if(gate_adj_done | bitslip_ctrl)
                               gdet_next_state = GDETECT_IDLE;
                            else if(rdvalid_r1 &&(align_rdata== 64'hb0b0_b0b0_b0b0_b0b0)) 
                            begin
                               gdet_next_state  = GDETECT_JUDGE;
                            end
                            else 
                               gdet_next_state =  GDETECT_DATA2;
                         end
          
        GDETECT_JUDGE :  begin
                                gdet_next_state = GDETECT_WAIT;
                         end
              
        GDETECT_WAIT:  begin
                           if(gate_adj_done | bitslip_ctrl)
                               gdet_next_state = GDETECT_IDLE;
                           else
                               gdet_next_state = GDETECT_WAIT;
                        end
         endcase
   end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
     if(!ddrphy_rst_n)
        rddata_check_pass   <= 1'b0;
     else if(gdet_next_state == GDETECT_IDLE)
        rddata_check_pass   <= 1'b0;
     else if((gdet_state ==GDETECT_JUDGE)&&(align_rdata == 64'haaaa_aaaa_aaaa_aaaa))
        rddata_check_pass   <= 1'b1;
 end
 
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
     if(!ddrphy_rst_n)
     slip_en <= 1;
     else if(rddata_check_pass == 1)
     slip_en <= 0;
 end
 
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
     if(!ddrphy_rst_n)
     bitslip_dq <= 0;
     else if(slip_en == 1)
     bitslip_dq <= bitslip_ctrl;
     else
     bitslip_dq <= 0;
 end
 
//*******************************************************************//                                                
//check data in rdel training procedure
always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if (!ddrphy_rst_n) begin
      rdel_rvalid0  <= 1'b1;
   end
   else if(eye_calibration | write_calibration)
   begin
      if(rdchk_state0 == RDCHECK_JUDGE)
      rdel_rvalid0  <= 1'b1;
      else if(wrcal_move_done | eyecal_move_done)
      rdel_rvalid0  <= 1'b0;
   end   
   else begin
      if (rdel_cal_vld) begin   
         if (rdvalid_r1 & (~rdel_data_vld0))
            rdel_rvalid0 <= 1'b0;        
         end
         else begin
         rdel_rvalid0 <= 1'b1;
      end
   end
end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if (!ddrphy_rst_n) begin
      rdel_rvalid1  <= 1'b1;
   end
   else if(eye_calibration | write_calibration)
   begin
      if(rdchk_state1 == RDCHECK_JUDGE)
      rdel_rvalid1  <= 1'b1;
      else if(wrcal_move_done | eyecal_move_done)
      rdel_rvalid1  <= 1'b0;
   end   
   else begin
         if( rdel_cal_vld ) begin
         if (rdvalid_r1 & (~rdel_data_vld1))
            rdel_rvalid1 <= 1'b0;
         end
         else begin
         rdel_rvalid1 <= 1'b1;
      end
   end
end
   
//*******************************************************************//
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) 
        rdchk_state0   <=  4'h0;
     else
        rdchk_state0   <= rdchk_next_state0;
  end

  always @(*) 
  begin
       rdchk_next_state0  = RDCHECK_IDLE ;
       case(rdchk_state0)
        RDCHECK_IDLE : begin 
            if(eye_calibration | write_calibration)
            rdchk_next_state0 = RDCHECK_DATA0;
        end
        RDCHECK_DATA0: begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state0  = RDCHECK_IDLE;
            else if(rdvalid_r1 && (align_rdata0 == DATA_PATTERN0_EVEN))
            rdchk_next_state0  = RDCHECK_DATA1;
            else
            rdchk_next_state0  = RDCHECK_DATA0;
        end
        RDCHECK_DATA1: begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state0  = RDCHECK_IDLE;
            else if(rdvalid_r1 && (align_rdata0 == DATA_PATTERN1_EVEN))
            rdchk_next_state0  = RDCHECK_DATA2;
            else
            rdchk_next_state0  = RDCHECK_DATA1;            
        end
        RDCHECK_DATA2: begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state0  = RDCHECK_IDLE;
            else if(rdvalid_r1 && (align_rdata0 == DATA_PATTERN2_EVEN))
            rdchk_next_state0  = RDCHECK_DATA3;
            else
            rdchk_next_state0  = RDCHECK_DATA2;            
        end
        RDCHECK_DATA3: begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state0  = RDCHECK_IDLE;
            else if(rdvalid_r1 && (align_rdata0 == DATA_PATTERN3_EVEN))
            rdchk_next_state0  = RDCHECK_JUDGE;
            else
            rdchk_next_state0  = RDCHECK_DATA3;            
        end
        RDCHECK_JUDGE: begin
            rdchk_next_state0  = RDCHECK_WAIT;
        end
        RDCHECK_WAIT : begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state0  = RDCHECK_IDLE;
        end
    endcase
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
     if(!ddrphy_rst_n) 
        rdchk_state1   <=  4'h0;
     else
        rdchk_state1   <= rdchk_next_state1;
  end

  always @(*) 
  begin
       rdchk_next_state1  = RDCHECK_IDLE ;
       case(rdchk_state1)
        RDCHECK_IDLE : begin 
            if(eye_calibration | write_calibration)
            rdchk_next_state1 = RDCHECK_DATA0;
        end
        RDCHECK_DATA0: begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state1  = RDCHECK_IDLE;
            else if(rdvalid_r1 && (align_rdata1 == DATA_PATTERN0_ODD))
            rdchk_next_state1  = RDCHECK_DATA1;
            else
            rdchk_next_state1  = RDCHECK_DATA0;
        end
        RDCHECK_DATA1: begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state1  = RDCHECK_IDLE;
            else if(rdvalid_r1 && (align_rdata1 == DATA_PATTERN1_ODD))
            rdchk_next_state1  = RDCHECK_DATA2;
            else
            rdchk_next_state1  = RDCHECK_DATA1;            
        end
        RDCHECK_DATA2: begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state1  = RDCHECK_IDLE;
            else if(rdvalid_r1 && (align_rdata1 == DATA_PATTERN2_ODD))
            rdchk_next_state1  = RDCHECK_DATA3;
            else
            rdchk_next_state1  = RDCHECK_DATA2;            
        end
        RDCHECK_DATA3: begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state1  = RDCHECK_IDLE;
            else if(rdvalid_r1 && (align_rdata1 == DATA_PATTERN3_ODD))
            rdchk_next_state1  = RDCHECK_JUDGE;
            else
            rdchk_next_state1  = RDCHECK_DATA3;            
        end
        RDCHECK_JUDGE: begin
            rdchk_next_state1  = RDCHECK_WAIT;
        end
        RDCHECK_WAIT : begin
            if(wrcal_move_done | eyecal_move_done)
            rdchk_next_state1  = RDCHECK_IDLE;
        end
    endcase
  end

always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
begin
   if (!ddrphy_rst_n) begin
      wrdata_check_pass  <= 1'b1;
   end
   else if(write_calibration)
   begin
      if((rdchk_state0 == RDCHECK_JUDGE)&&(rdchk_state1 == RDCHECK_JUDGE))
      wrdata_check_pass  <= 1'b1;
      else if(wrcal_move_done)
      wrdata_check_pass  <= 1'b0;
   end
   else 
     wrdata_check_pass  <= 1'b0;
end

//*******************************************************************//
//using combinational output to save registers
assign read_valid  = rdvalid_r1 ;
assign read_data   = align_rdata;

assign dbg_slice_rdchk_state = {rdchk_state1,rdchk_state0};

endmodule
