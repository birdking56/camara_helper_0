////////////////////////////////////////////////////////////////     
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                        
// ALL RIGHTS REVERVED.                                              
////////////////////////////////////////////////////////////////     
//Description:                                                       
//Author:  wxxiao                                                    
//History: v1.0                                                      
////////////////////////////////////////////////////////////////     

`timescale 1ns/1ps                                                   
module  ips2l_ddrphy_data_slice_v1_9 #(
   parameter [1:0] DDR_TYPE      = 2'b00 ,  //2'b00:DDR3  2'b01:DDR2  2'b10:LPDDR
   parameter TEST_DATA_PATTERN0  = 64'h55_aa_55_aa_08_f7_08_f7,
   parameter TEST_DATA_PATTERN1  = 64'h7f_9f_7f_9f_80_fe_80_fe,
   parameter TEST_DATA_PATTERN2  = 64'hf0_0f_f0_0f_01_ff_01_ff,
   parameter TEST_DATA_PATTERN3  = 64'hdf_aa_df_aa_55_aa_55_aa,
   parameter GATE_MODE           = 0    ,
   parameter SC_LDO_CTRL         = 2'b00,
   parameter SC_DLY_2X           = 1'b0 ,    //1'b0  1x delay chain, 1'b1 2x delay chain   
   parameter WL_MAX_STEP         = 8'hff,
   parameter WL_MAX_CHECK        = 5'h1f,
   parameter MIN_DQSI_WIN        = 9'd10   
)( 
  input [4:0]      mc_rl                ,
  input            force_read_clk_ctrl  ,
  input [2:0]      init_read_clk_ctrl   ,
  input [3:0]      init_slip_step       ,
  input            force_samp_position  ,
  input            samp_position_dyn_adj,
  input [7:0]      init_samp_position_even, 
  input [7:0]      init_samp_position_odd,
 
  input            ddrphy_sysclk        ,
  input            ddrphy_rst_n         ,
  input            phy_clk_p            ,
  input            sysclk_p             ,
  input            ddrphy_dqs_rst       ,
  input            ddrphy_dqs_training_rstn,
  input            ddrphy_iol_rst       ,
//wrlvl   
  input [7:0]      init_wrlvl_step      ,
  input            wrlvl_dqs_req        ,
  output           wrlvl_dqs_resp       ,
  output           wrlvl_error          ,  
  output           ck_check_done        ,
  output           wrlvl_ck_dly_flag    ,
  output  [7:0]    ck_dly_set_bin_tra   ,
  input            wrlvl_ck_dly_done    ,
  input            wrlvl_ck_dly_start   ,
  input            force_ck_dly_en      ,
//dqs    
  input            gatecal_start        ,
  output           gate_check_pass      ,
  output           gate_adj_done        ,
  output           gate_cal_error       ,
  input            gate_move_en         ,
  input            rddata_cal           ,
  output           rddata_check_pass    ,
 
  input            wrcal_position_dyn_adj,
  input  [7:0]     init_wrcal_position   , 
  output           wrcal_check_pass     ,
  input            write_calibration    ,
  input            wrcal_move_en        ,
  output           wrcal_move_done      ,
  output           wrcal_error          ,
    
  input            eye_calibration      ,
  output           eyecal_check_pass    ,
  output           eyecal_move_done     ,
  input            eyecal_move_en       ,

  input [3:0]      read_cmd             ,

  input [1:0]      comp_val             ,
  input            comp_dir             ,
  input            dqs_gate_comp_en     ,
  output           dqs_gate_comp_done   ,
  output [1:0]     dqs_drift            ,
  output           dll_lock             ,
  input            dll_rstn             ,
  input            dll_freeze           ,
  input            dll_update_n         ,
  output           dll_update_code_done ,

  input            init_adj_rdel        ,
  output           adj_rdel_done        ,
  input            rdel_calibration     ,
  output           rdel_calib_done      ,
  output           rdel_calib_error     ,
  input            rdel_move_en         ,
  output           rdel_move_done       ,
  input            bitslip_ctrl         ,
//rdata  
  output    	   read_valid           ,
  output [63:0]    read_data            ,
//wdata
  input [3:0]      phy_wrdata_en        ,
  input [7:0]      phy_wrdata_mask      ,
  input [63:0]     phy_wrdata           ,
  inout            dqs                  ,
  inout            dqs_n                ,
  inout [7:0]      dq                   ,
  output           dm                   ,
  output [21:0]    dbg_slice_state      ,
  output [65:0]    debug_data
  ); 

                              
//wl
  wire            wrlvl_dqs       ;
  wire            wrlvl_dqs_en    ;
                                   
  wire            dqs_gate_vld    ;
//rdel 
  wire            rdel_cal_vld    ;

wire wrlvl_dq;
wire rdel_ov;
wire ddrphy_read_valid;
wire [63:0] ddrphy_rdata; 
wire ddrphy_dgts;
wire ddrphy_gatei;
wire rdel_rvalid0;
wire rdel_rvalid1;
wire [7:0] wrlvl_step;
wire [2:0] rdel_ctrl;
wire [3:0] dqs_gate_ctrl;
wire [2:0] read_clk_ctrl; 
wire [7:0] adj_wrdq_en     ;
wire [63:0]adj_wrdq        ;
wire [7:0] adj_wrdqs_en    ;
wire [7:0] adj_wrdqs       ;
wire [7:0] adj_wrdata_mask ;
wire wclk /* pragma PAP_TIM_MASK_CLOCK_ATTR = 1 */;
wire wclk_del /* pragma PAP_TIM_MASK_CLOCK_ATTR = 1 */;
wire ioclk_dq;
wire dqsi_del /* pragma PAP_TIM_MASK_CLOCK_ATTR = 1 */;
wire dqsi_del_inv /* pragma PAP_TIM_MASK_CLOCK_ATTR = 1 */;
wire [2:0] ififo_waddr;
wire [2:0] ififo_raddr;
wire dqs_in /* pragma PAP_TIM_MASK_CLOCK_ATTR = 1 */;
wire dqso;
wire dqsot;
wire dqst;
wire [7:0] pado;
wire [7:0] padot;
wire padt;
wire [7:0] dq_in;
wire [7:0] dq_in_dly;
wire pado_dm;
wire padot_dm;

wire [3:0] coarse_slip_step;  
wire [3:0] gate_win_size;

wire [7:0] dll_90_bin;
wire [7:0] dll_90_gray;
wire [7:0] dll_45_gray;
wire [7:0] wl_p_dll_gray;
wire [7:0] wrlvl_step_gray;
wire [7:0] dqs_even_gray;
wire [7:0] dqs_odd_gray;
wire dqs_gate_sample;
wire wl_p_ov;

wire wrdata_check_pass;

wire phy_clk_2x_n     ;
wire phy_clk_2x_p     ;
wire sysclkb_n        ;
wire sysclkb_p        ;
wire [7:0] idly_set   ;
wire wrlvl_gatei      ;
wire [7:0] dqs_even_bin        ;
wire [7:0] dqs_odd_bin         ;
wire [8:0] total_margin_even   ;
wire [8:0] total_margin_odd    ;
wire [7:0] wl_p_dll_bin        ;   
wire wrcal_gatei   ;
wire do_cas_out;
wire to_cas_out;
wire term_cas_out;

wire [2:0]   dbg_slice_wrlvl_state;
wire [3:0]   dbg_slice_wrcal_state;
wire [2:0]   dbg_slice_gate_state;
wire [3:0]   dbg_slice_rdcal_state;
wire [7:0]   dbg_slice_rdchk_state;

assign dbg_slice_state = {dbg_slice_wrlvl_state,dbg_slice_wrcal_state,dbg_slice_gate_state,dbg_slice_rdcal_state,dbg_slice_rdchk_state};

assign debug_data[3:0] = coarse_slip_step;
assign debug_data[6:4] = read_clk_ctrl[2:0];
assign debug_data[10:7] = gate_win_size[3:0];
assign debug_data[11]  = gate_check_pass;
assign debug_data[12]  = rddata_check_pass;
assign debug_data[20:13]  = dqs_even_bin;                                                                                                        
assign debug_data[28:21] = dqs_odd_bin;
assign debug_data[37:29] = total_margin_even;
assign debug_data[46:38] = total_margin_odd ;
assign debug_data[47]    = eyecal_check_pass;
assign debug_data[55:48] = wrlvl_step;
assign debug_data[56]    = wl_p_ov;
assign debug_data[57]    = wrlvl_dq;
assign debug_data[65:58] = wl_p_dll_bin;

assign wrlvl_dq = |dq_in_dly;
assign wrcal_gatei = wrcal_move_en;

assign ddrphy_gatei = (write_calibration == 1) ? wrcal_gatei : wrlvl_gatei;

assign dqsi_del_inv = ~dqsi_del;

 ips2l_ddrphy_data_slice_wrlvl_v1_9 #(
  .WL_MAX_STEP              (WL_MAX_STEP              ),
  .WL_MAX_CHECK             (WL_MAX_CHECK             )
 ) ddrphy_data_slice_wrlvl(               
  .ddrphy_sysclk            (ddrphy_sysclk            ),
  .ddrphy_rst_n             (ddrphy_rst_n             ),
                                                      
  .init_wrlvl_step          (init_wrlvl_step          ),   
  .wrlvl_dqs_req            (wrlvl_dqs_req            ),
  .wrlvl_dqs_resp           (wrlvl_dqs_resp           ),
  .wl_p_ov                  (wl_p_ov                  ),
  .wrlvl_error              (wrlvl_error              ),
                                                      
  .wrlvl_gatei              (wrlvl_gatei              ),
  .wrlvl_dq                 (wrlvl_dq                 ),
  .wrlvl_dqs                (wrlvl_dqs                ),
  .wrlvl_dqs_en             (wrlvl_dqs_en             ),
  
  .wrlvl_ck_dly_flag        (wrlvl_ck_dly_flag       ),
  .wrlvl_ck_dly_done        (wrlvl_ck_dly_done       ), 
  .wrlvl_ck_dly_start       (wrlvl_ck_dly_start      ),   
  .ck_check_done            (ck_check_done           ),
  .ck_dly_set_bin_tra       (ck_dly_set_bin_tra      ),
  .force_ck_dly_en          (force_ck_dly_en         ),
                                                      
  .wrlvl_step               (wrlvl_step               ),
  .wrlvl_step_gray          (wrlvl_step_gray          ),
  .dbg_slice_wrlvl_state    (dbg_slice_wrlvl_state    )
  );

ips2l_ddrphy_data_slice_wrcal_v1_9  ddrphy_data_slice_wrcal(
  .ddrphy_sysclk            (ddrphy_sysclk            ),
  .ddrphy_rst_n             (ddrphy_rst_n             ),
  .wrcal_position_dyn_adj   (wrcal_position_dyn_adj   ),
  .init_wrcal_position      (init_wrcal_position      ),
  .wrcal_check_pass         (wrcal_check_pass         ),
  .write_calibration        (write_calibration        ),
  .wrcal_move_en            (wrcal_move_en            ),
  .wrcal_move_done          (wrcal_move_done          ),
  .wrdata_check_pass        (wrdata_check_pass        ),

  .dll_rstn                 (dll_rstn                 ),
  .dll_update_n             (dll_update_n             ),
  .dll_update_code_done     (dll_update_code_done     ),                                        
  .dll_90_gray              (dll_90_gray              ),
  .wrlvl_step               (wrlvl_step               ),
  .dll_90_bin               (dll_90_bin               ),
  .wl_p_dll_gray            (wl_p_dll_gray            ),
  .wl_p_dll_bin             (wl_p_dll_bin             ),
  .wl_p_ov                  (wl_p_ov                  ),
  .dbg_slice_wrcal_state    (dbg_slice_wrcal_state    ),
  .wrcal_error              (wrcal_error              )
);


 ips2l_ddrphy_data_slice_dqs_gate_cal_v1_6 #(
  .GATE_MODE                (GATE_MODE                )
 )ddrphy_data_slice_dqs_gate_cal(
  .mc_rl                    (mc_rl                    ),
  .init_read_clk_ctrl       (init_read_clk_ctrl       ),       
  .init_slip_step           (init_slip_step           ),
  .force_read_clk_ctrl      (force_read_clk_ctrl      ),       

  .ddrphy_sysclk            (ddrphy_sysclk            ),
  .ddrphy_rst_n             (ddrphy_rst_n             ),

  .gatecal_start            (gatecal_start            ),
  .gate_check_pass          (gate_check_pass          ),
  .gate_adj_done            (gate_adj_done            ),
  .gate_cal_error           (gate_cal_error           ),
  .gate_move_en             (gate_move_en             ), 
  .rddata_cal               (rddata_cal               ),

  .read_cmd                 (read_cmd                 ), 

  .comp_val                 (comp_val                 ),
  .comp_dir                 (comp_dir                 ),
  .dqs_gate_comp_en         (dqs_gate_comp_en         ),
  .dqs_gate_comp_done       (dqs_gate_comp_done       ),
  
  .ddrphy_dgts              (ddrphy_dgts              ), 
  .dqs_gate_sample          (dqs_gate_sample          ),
  .dqs_gate_vld             (dqs_gate_vld             ),
  .coarse_slip_step         (coarse_slip_step         ),
  .gate_win_size            (gate_win_size            ),
  .dqs_gate_ctrl            (dqs_gate_ctrl            ),
  .read_clk_ctrl            (read_clk_ctrl            ),
  .dbg_slice_gate_state     (dbg_slice_gate_state     )
  );     

 ips2l_ddrphy_dqsi_rdel_cal_v1_3 #(
  .MIN_DQSI_WIN             (MIN_DQSI_WIN             )
 )ddrphy_dqsi_rdel_cal(  
  .force_samp_position      (force_samp_position      ), 
  .samp_position_dyn_adj    (samp_position_dyn_adj    ), 
  .init_samp_position_even  (init_samp_position_even  ),
  .init_samp_position_odd   (init_samp_position_odd   ),

  .ddrphy_sysclk            (ddrphy_sysclk            ),
  .ddrphy_rst_n             (ddrphy_rst_n             ),
  .dll_90_bin               (dll_90_bin               ),
  .rdel_rvalid0             (rdel_rvalid0             ),
  .rdel_rvalid1             (rdel_rvalid1             ),
  .init_adj_rdel            (init_adj_rdel            ),  
  .adj_rdel_done            (adj_rdel_done            ),     
                            
  .rdel_calibration         (rdel_calibration         ),
  .rdel_calib_done          (rdel_calib_done          ),
  .rdel_calib_error         (rdel_calib_error         ),    
                            
  .rdel_move_en             (rdel_move_en             ),
  .rdel_move_done           (rdel_move_done           ), 
                            
  .eye_calibration          (eye_calibration          ),
  .eyecal_check_pass        (eyecal_check_pass        ),
  .eyecal_move_done         (eyecal_move_done         ),
  .eyecal_move_en           (eyecal_move_en           ),
                            
  .rdel_cal_vld             (rdel_cal_vld             ),
  .dqs_even_gray            (dqs_even_gray            ),
  .dqs_odd_gray             (dqs_odd_gray             ),
  .dqs_even_bin             (dqs_even_bin             ),
  .dqs_odd_bin              (dqs_odd_bin              ),
  .total_margin_even        (total_margin_even        ),
  .total_margin_odd         (total_margin_odd         ),
  .idly_set                 (idly_set                 ),
  .dbg_slice_rdcal_state    (dbg_slice_rdcal_state    )
);
                                                                 
 ips2l_ddrphy_dqs_rddata_align_v1_3 #(
  .TEST_DATA_PATTERN0       (TEST_DATA_PATTERN0       ),
  .TEST_DATA_PATTERN1       (TEST_DATA_PATTERN1       ),
  .TEST_DATA_PATTERN2       (TEST_DATA_PATTERN2       ),
  .TEST_DATA_PATTERN3       (TEST_DATA_PATTERN3       )
 )ddrphy_dqs_rddata_align(  
  .ddrphy_sysclk            (ddrphy_sysclk            ),
  .ddrphy_rst_n             (ddrphy_rst_n             ),

  .ddrphy_read_valid        (ddrphy_read_valid        ),
  .ddrphy_rdata             (ddrphy_rdata             ),
  .read_valid               (read_valid               ),
  .read_data                (read_data                ),
  .gate_adj_done            (gate_adj_done            ),
  .rddata_check_pass        (rddata_check_pass        ),
  .bitslip_ctrl             (bitslip_ctrl             ),
  .bitslip_dq               (bitslip_dq               ),

  .dqs_gate_vld             (dqs_gate_vld             ),  
  
  .write_calibration        (write_calibration        ),
  .wrcal_move_done          (wrcal_move_done          ),
  .wrdata_check_pass        (wrdata_check_pass        ),
  
  .eye_calibration          (eye_calibration          ),
  .eyecal_move_done         (eyecal_move_done         ),
  
  .rdel_cal_vld             (rdel_cal_vld             ),
  .rdel_rvalid0             (rdel_rvalid0             ), 
  .rdel_rvalid1             (rdel_rvalid1             ),
  .dbg_slice_rdchk_state    (dbg_slice_rdchk_state    )
);

 ips2l_ddrphy_wdata_path_adj_v1_3 #(
  .DQ_WIDTH                 (8                        )
 )ddrphy_wdata_path_adj(  
  .ddrphy_sysclk            (ddrphy_sysclk            ),
  .ddrphy_rst_n             (ddrphy_rst_n             ), 
                                                      
  .phy_wrdata_en            (phy_wrdata_en            ),
  .phy_wrdata_mask          (phy_wrdata_mask          ),
  .phy_wrdata               (phy_wrdata               ),
  .wrlvl_dqs_en             (wrlvl_dqs_en             ),
  .wrlvl_dqs                (wrlvl_dqs                ),
                                                      
  .adj_wrdq_en              (adj_wrdq_en              ),
  .adj_wrdq                 (adj_wrdq                 ),
  .adj_wrdqs_en             (adj_wrdqs_en             ),
  .adj_wrdqs                (adj_wrdqs                ),
  .adj_wrdata_mask          (adj_wrdata_mask          )
   );

GTP_DDC_E2 #(
 .CLKA_GATE_EN              ("TRUE"                   ),         
 .WCLK_DELAY_SEL            ("FALSE"                  ),        
 .DDC_MODE                  ("QUAD_RATE"              ),    
 .R_EXTEND                  ("FALSE"                  ),        
 .DELAY_SEL                 (SC_DLY_2X                ),      
 .GRS_EN                    ("TRUE"                   ),         
 .IFIFO_GENERIC             ("FALSE"                  ),        
 .RADDR_INIT                (3'b000                   ),         
 .DATA_RATE                 (SC_LDO_CTRL              )     
)u_ddc_dq(
    //output
  .WCLK                     (wclk                     ),
  .WCLK_DELAY               (wclk_del                 ),
  .DQSI_DELAY               (dqsi_del                 ),
  .DQSIB_DELAY              (                         ),
  .DGTS                     (ddrphy_dgts              ),
  .IFIFO_WADDR              (ififo_waddr              ),
  .IFIFO_RADDR              (ififo_raddr              ),
  .READ_VALID               (ddrphy_read_valid        ),
  .DQS_DRIFT                (dqs_drift                ),
  .DRIFT_DETECT_ERR         (                         ),
  .DQS_DRIFT_STATUS         (                         ),
  .DQS_SAMPLE               (dqs_gate_sample          ),
  .RST                      (ddrphy_dqs_rst           ),
  .RST_TRAINING_N           (ddrphy_dqs_training_rstn ),
  .CLKA                     (phy_clk_p                ),
  .CLKB                     (sysclk_p                 ),
  .DQSI                     (dqs_in                   ),
  .DQSIB                    (                         ),
  .DELAY_STEP0              (wrlvl_step_gray          ),
  .DELAY_STEP1              (dqs_even_gray            ),
  .DELAY_STEP2              (dqs_odd_gray             ),
  .DELAY_STEP3              (dll_45_gray              ),
  .DELAY_STEP4              (wl_p_dll_gray            ),
  .DQS_GATE_CTRL            (dqs_gate_ctrl            ),
  .GATE_SEL                 (read_clk_ctrl[2]         ),
  .CLK_GATE_CTRL            (read_clk_ctrl[1:0]       ),
  .CLKA_GATE                (ddrphy_gatei             )
 );

GTP_DLL_E2 #(
   .GRS_EN              ("TRUE"),         
   .CAL_INIT            (8'b00011111),    
   .DELAY_STEP_OFFSET   (0),          
   .DELAY_SEL           (SC_DLY_2X),      
   .FAST_LOCK           ("FALSE"),        
   .FDIV                (2'b10),          
   .INT_CLK             (1'b0),           
   .UPD_DLY             (2'b01)           
)u_dll_dq(
    .CLKIN         (phy_clk_p),           // IOCLK_2X
    .SYS_CLK       (sysclk_p),            // SYSCLK
    .PWD           (dll_freeze),          // DLL_FREEZE
    .RST           (~dll_rstn),     
    .UPDATE_N      (dll_update_n),     
    .LOCK          (dll_lock),     
    .DELAY_STEP    (dll_90_gray),                    // DLL_90CODE_GRAY
    .DELAY_STEP1   (dll_45_gray)                  // DLL_45CODE_GRAY
    );

GTP_OSERDES_E2 #(
   .GRS_EN           ("TRUE"),               
   .OSERDES_MODE     ("HMSDR8TO1"), 
   .TSERDES_EN       ("TRUE"),       
   .UPD0_SHIFT_EN    ("FALSE"),                 
   .UPD1_SHIFT_EN    ("FALSE"),                 
   .INIT_SET         (2'b00),                
   .GRS_TYPE_DQ      ("RESET"),              
   .LRS_TYPE_DQ0     ("ASYNC_RESET"),        
   .LRS_TYPE_DQ1     ("ASYNC_RESET"),        
   .LRS_TYPE_DQ2     ("ASYNC_RESET"),        
   .LRS_TYPE_DQ3     ("ASYNC_RESET"),        
   .GRS_TYPE_TQ      ("RESET"),              
   .LRS_TYPE_TQ0     ("ASYNC_RESET"),        
   .LRS_TYPE_TQ1     ("ASYNC_RESET"),        
   .LRS_TYPE_TQ2     ("ASYNC_RESET"),        
   .LRS_TYPE_TQ3     ("ASYNC_RESET"),        
   .TRI_EN           ("TRUE"),              
   .TBYTE_EN         ("FALSE"),              
   .MIPI_EN          ("FALSE"),              
   .OCASCADE_EN      ("FALSE")               
)u_tserdes0_dqs(
   .RST             (ddrphy_iol_rst), 
   .OCE             (1'b1),
   .TCE             (1'b1),
   .OCLKDIV         (sysclk_p),
   .SERCLK          (phy_clk_p),
   .OCLK            (wclk),
   .MIPI_CTRL       (1'b0),
   .UPD0_SHIFT      (1'b0),
   .UPD1_SHIFT      (1'b0),
   .OSHIFTIN0       (1'b0),
   .OSHIFTIN1       (1'b0),
   .DI              (adj_wrdqs_en),
   .TI              (8'd0),
   .TBYTE_IN        (),
   .OSHIFTOUT0      (),
   .OSHIFTOUT1      (),
   .TQ              (),
   .DO              (dqst)
);

GTP_OSERDES_E2 #(
   .GRS_EN           ("TRUE"),                
   .OSERDES_MODE     ("HMSDR8TO1"),  
   .TSERDES_EN       ("TRUE"),         
   .UPD0_SHIFT_EN    ("FALSE"),                  
   .UPD1_SHIFT_EN    ("FALSE"),                  
   .INIT_SET         (2'b00),                 
   .GRS_TYPE_DQ      ("RESET"),               
   .LRS_TYPE_DQ0     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ1     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ2     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ3     ("ASYNC_RESET"),         
   .GRS_TYPE_TQ      ("RESET"),               
   .LRS_TYPE_TQ0     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ1     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ2     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ3     ("ASYNC_RESET"),         
   .TRI_EN           ("TRUE"),               
   .TBYTE_EN         ("FALSE"),               
   .MIPI_EN          ("FALSE"),               
   .OCASCADE_EN      ("FALSE")                
)u_tserdes1_dq(
   .RST             (ddrphy_iol_rst), 
   .OCE             (1'b1),
   .TCE             (1'b1),
   .OCLKDIV         (sysclk_p),
   .SERCLK          (phy_clk_p),
   .OCLK            (wclk_del),
   .MIPI_CTRL       (1'b0),
   .UPD0_SHIFT      (1'b0),
   .UPD1_SHIFT      (1'b0),
   .OSHIFTIN0       (1'b0),
   .OSHIFTIN1       (1'b0),
   .DI              (adj_wrdq_en),
   .TI              (8'd0),
   .TBYTE_IN        (),
   .OSHIFTOUT0      (),
   .OSHIFTOUT1      (),
   .TQ              (),
   .DO              (padt)
);

GTP_OSERDES_E2 #(
   .GRS_EN           ("TRUE"),                
   .OSERDES_MODE     ("HMSDR8TO1"), 
   .TSERDES_EN       ("FALSE"),          
   .UPD0_SHIFT_EN    ("FALSE"),                  
   .UPD1_SHIFT_EN    ("FALSE"),                  
   .INIT_SET         (2'b00),                 
   .GRS_TYPE_DQ      ("RESET"),               
   .LRS_TYPE_DQ0     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ1     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ2     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ3     ("ASYNC_RESET"),         
   .GRS_TYPE_TQ      ("RESET"),               
   .LRS_TYPE_TQ0     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ1     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ2     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ3     ("ASYNC_RESET"),         
   .TRI_EN           ("TRUE"),               
   .TBYTE_EN         ("TRUE"),               
   .MIPI_EN          ("FALSE"),               
   .OCASCADE_EN      ("FALSE")                
)u_oserdes_dqs(
   .RST             (ddrphy_dqs_rst), 
   .OCE             (1'b1),
   .TCE             (1'b1),
   .OCLKDIV         (sysclk_p),
   .SERCLK          (phy_clk_p),
   .OCLK            (wclk),
   .MIPI_CTRL       (1'b0),
   .UPD0_SHIFT      (1'b0),
   .UPD1_SHIFT      (1'b0),
   .OSHIFTIN0       (1'b0),
   .OSHIFTIN1       (1'b0),
   .DI              (adj_wrdqs),
   .TI              (),
   .TBYTE_IN        (dqst),
   .OSHIFTOUT0      (),
   .OSHIFTOUT1      (),
   .TQ              (dqsot),
   .DO              (dqso)
);


generate
if (DDR_TYPE == 2'b10) begin     //LPDDR
GTP_IOBUF u_iobuf_dqs(
   .O                                    (dqs_in),
   .IO                                   (dqs),   
   .I                                    (dqso),
   .T                                    (dqsot)
);
end
else begin
GTP_IOBUFCO u_iobufco_dqs(
    .O            (dqs_in),
    .IO           (dqs   ), 
    .IOB          (dqs_n ),
    .I            (dqso  ), 
    .T            (dqsot  )
    );
end
endgenerate


//DQ
genvar i;
generate
for (i=0; i<8; i=i+1)
begin: dq_loop

GTP_OSERDES_E2 #(
   .GRS_EN           ("TRUE"),                
   .OSERDES_MODE     ("HMSDR8TO1"), 
   .TSERDES_EN       ("FALSE"),          
   .UPD0_SHIFT_EN    ("FALSE"),                  
   .UPD1_SHIFT_EN    ("FALSE"),                  
   .INIT_SET         (2'b00),                 
   .GRS_TYPE_DQ      ("RESET"),               
   .LRS_TYPE_DQ0     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ1     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ2     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ3     ("ASYNC_RESET"),         
   .GRS_TYPE_TQ      ("RESET"),               
   .LRS_TYPE_TQ0     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ1     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ2     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ3     ("ASYNC_RESET"),         
   .TRI_EN           ("TRUE"),               
   .TBYTE_EN         ("TRUE"),               
   .MIPI_EN          ("FALSE"),               
   .OCASCADE_EN      ("FALSE")                
)u_oserdes_dq(
   .RST             (ddrphy_dqs_rst), 
   .OCE             (1'b1),
   .TCE             (1'b1),
   .OCLKDIV         (sysclk_p),
   .SERCLK          (phy_clk_p),
   .OCLK            (wclk_del),
   .MIPI_CTRL       (1'b0),
   .UPD0_SHIFT      (1'b0),
   .UPD1_SHIFT      (1'b0),
   .OSHIFTIN0       (1'b0),
   .OSHIFTIN1       (1'b0),
   .DI              (adj_wrdq[i*8+7: i*8]),
   .TI              (),
   .TBYTE_IN        (padt),
   .OSHIFTOUT0      (),
   .OSHIFTOUT1      (),
   .TQ              (padot[i]),
   .DO              (pado[i])
);

 GTP_IODELAY_E2 #(
 .DELAY_STEP_SEL     ("PORT"), 
 .DELAY_STEP_VALUE   (8'd0)   
 )u_iodelay_dq(
 .DO                 (dq_in_dly[i]),
 .DI                 (dq_in[i]),
 .DELAY_SEL          (SC_DLY_2X),
 .DELAY_STEP         (idly_set)  
 );

GTP_ISERDES_E2 #(
    .ISERDES_MODE     ("HMDDR1TO8"),         
    .CASCADE_MODE     ("MASTER"),           
    .BITSLIP_EN       ("TRUE"),           
    .GRS_EN           ("TRUE"),            
    .NUM_ICE          (1'b0),              
    .GRS_TYPE_Q0      ("RESET"),           
    .GRS_TYPE_Q1      ("RESET"),           
    .GRS_TYPE_Q2      ("RESET"),           
    .GRS_TYPE_Q3      ("RESET"),           
    .LRS_TYPE_Q0      ("ASYNC_RESET"),     
    .LRS_TYPE_Q1      ("ASYNC_RESET"),     
    .LRS_TYPE_Q2      ("ASYNC_RESET"),     
    .LRS_TYPE_Q3      ("ASYNC_RESET")      
)u_iserdes_dq(
    .RST             (ddrphy_dqs_rst),
    .ICE0            (1'b1),
    .ICE1            (1'b1),
    .DESCLK          (phy_clk_p),
    .ICLK            (dqsi_del),
    .ICLKB           (dqsi_del_inv),
    .OCLK            (wclk_del),
    .ICLKDIV         (sysclk_p),
    .DI              (dq_in_dly[i]),
    .BITSLIP         (bitslip_dq),
    .ISHIFTIN0       (1'b0),
    .ISHIFTIN1       (1'b0),
    .IFIFO_WADDR     (ififo_waddr),
    .IFIFO_RADDR     (ififo_raddr),
    .DO              (ddrphy_rdata[i*8+7:i*8]),
    .ISHIFTOUT0      (),
    .ISHIFTOUT1      ()
);

// input parts  
GTP_IOBUF u_iobuf_dq
     (
     .O  (dq_in[i]),
     .IO (dq[i]),
     .I  (pado[i]),
     .T  (padot[i])
     );   

end
endgenerate

GTP_OSERDES_E2 #(
   .GRS_EN           ("TRUE"),                
   .OSERDES_MODE     ("HMSDR8TO1"), 
   .TSERDES_EN       ("FALSE"),          
   .UPD0_SHIFT_EN    ("FALSE"),                  
   .UPD1_SHIFT_EN    ("FALSE"),                  
   .INIT_SET         (2'b00),                 
   .GRS_TYPE_DQ      ("RESET"),               
   .LRS_TYPE_DQ0     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ1     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ2     ("ASYNC_RESET"),         
   .LRS_TYPE_DQ3     ("ASYNC_RESET"),         
   .GRS_TYPE_TQ      ("RESET"),               
   .LRS_TYPE_TQ0     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ1     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ2     ("ASYNC_RESET"),         
   .LRS_TYPE_TQ3     ("ASYNC_RESET"),         
   .TRI_EN           ("TRUE"),               
   .TBYTE_EN         ("TRUE"),               
   .MIPI_EN          ("FALSE"),               
   .OCASCADE_EN      ("FALSE")                
)u_oserdes_dm(
   .RST             (ddrphy_dqs_rst), 
   .OCE             (1'b1),
   .TCE             (1'b1),
   .OCLKDIV         (sysclk_p),
   .SERCLK          (phy_clk_p),
   .OCLK            (wclk_del),
   .MIPI_CTRL       (1'b0),
   .UPD0_SHIFT      (1'b0),
   .UPD1_SHIFT      (1'b0),
   .OSHIFTIN0       (1'b0),
   .OSHIFTIN1       (1'b0),
   .DI              (adj_wrdata_mask),
   .TI              (),
   .TBYTE_IN        (padt),
   .OSHIFTOUT0      (),
   .OSHIFTOUT1      (),
   .TQ              (padot_dm),
   .DO              (pado_dm)
);

GTP_OUTBUFT u_outbuft_dm
(
    .O   (dm),
    .I   (pado_dm), 
    .T   (padot_dm)
);
        
endmodule
