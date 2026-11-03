////////////////////////////////////////////////////////////////   
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                      
// ALL RIGHTS REVERVED.                                            
////////////////////////////////////////////////////////////////   
//Description:                                                     
//Author:  wxxiao                                                  
//History: v1.0                                                    
////////////////////////////////////////////////////////////////   
`timescale 1ns/1ps  
module ips2l_ddrphy_calib_top_v1_9 #(
   parameter [1:0]   DDR_TYPE     =  2'b00     ,  //2'b00:DDR3  2'b01:DDR2  2'b10:LPDDR
   parameter         WRCAL_EN     =  1         ,
   parameter         EYECAL_EN    =  1         ,
   parameter [19:0]  T200US       =  20'd20000 ,
   parameter [19:0]  T500US       =  20'd50000 ,
   parameter [7:0]   T400NS       =  8'd40     ,
   parameter [7:0]   TMRD         =  8'd1      ,
   parameter [7:0]   TMOD         =  8'd3      ,
   parameter [7:0]   TXPR         =  8'd17     ,
   parameter [7:0]   TRP          =  8'd2      ,
   parameter [9:0]   TZQINIT      =  10'd128   ,
   parameter [7:0]   TRFC         =  8'd16     ,
   parameter [7:0]   TRCD         =  8'd2      ,
   parameter [3:0]   REF_CNT      =  4'd9      ,
   parameter  TEST_DATA_PATTERN0  =  64'h55_aa_55_aa_08_f7_08_f7,
   parameter  TEST_DATA_PATTERN1  =  64'h7f_9f_7f_9f_80_fe_80_fe,
   parameter  TEST_DATA_PATTERN2  =  64'hf0_0f_f0_0f_01_ff_01_ff,
   parameter  TEST_DATA_PATTERN3  =  64'hdf_aa_df_aa_55_aa_55_aa,
   parameter  MEM_ADDR_WIDTH      =  16        ,
   parameter  MEM_BANKADDR_WIDTH  =  3         ,
   parameter  MEM_DQ_WIDTH        =  16        ,
   parameter  MEM_DM_WIDTH        =  2         ,
   parameter  MEM_DQS_WIDTH       =  2         

)(     
///parameter
  input [4:0]     mc_wl               ,
  input [15:0]    mr0                 ,
  input [15:0]    mr1                 ,
  input [15:0]    mr2                 ,
  input [15:0]    mr3                 ,
  
//clk                                 
  input           ddrphy_sysclk        ,
  input           ddrphy_rst_n        ,
  output          calib_done          ,
  output          update_done         ,

  output          ddrphy_rst_req      ,
  input           ddrphy_rst_ack      ,

  input           wrlvl_en           ,
  output          wrlvl_dqs_req      ,
  input           wrlvl_dqs_resp     ,
  input           wrlvl_error        ,
  
  output          gatecal_start      ,   
  input           gate_check_pass    ,
  input           gate_adj_done      ,
  input           gate_cal_error     ,
  output          gate_move_en       ,

  output          rddata_cal         , 
  input           rddata_check_pass  ,

  output          init_adj_rdel       ,
  input           adj_rdel_done       ,

  output          rdel_calibration    ,
  input           rdel_calib_done     ,
  input           rdel_calib_error    ,
  output          rdel_move_en        ,
  input           rdel_move_done      ,
  output          bitslip_ctrl        ,
  
  input           wrcal_check_pass   , 
  output  [8:0]   write_calibration  ,
  output  [8:0]   wrcal_move_en      ,
  input           wrcal_move_done    ,
  input           wrcal_error        ,

  output          eye_calibration    ,  
  input           eyecal_check_pass  ,
  input           eyecal_move_done   ,
  output          eyecal_move_en     ,

  input           write_debug         ,
  input           dqgt_debug          ,
  input  [7:0]    rdel_rd_cnt         ,
  
  output reg      dfi_error           ,
  output [33:0]   debug_calib_ctrl    ,
  
  input           update_cal_req     ,
  input  [2*MEM_DQS_WIDTH-1:0]     update_comp_val    ,
  input  [MEM_DQS_WIDTH-1:0]       update_comp_dir    ,
  output  [2*MEM_DQS_WIDTH-1:0]    comp_val           ,
  output  [MEM_DQS_WIDTH-1:0]      comp_dir           ,
  output          dqs_gate_comp_en   ,
  input           dqs_gate_comp_done ,    

  output [MEM_BANKADDR_WIDTH-1:0]  calib_ba      ,
  output [MEM_ADDR_WIDTH-1:0]      calib_address ,
  output          calib_cs_n          ,
  output          calib_ras_n         ,
  output          calib_cas_n         ,
  output          calib_we_n          ,
  output          calib_cke           ,
  output          calib_odt           ,
  output          calib_rst           ,
  output [3:0]    calib_wrdata_en     ,
  output [MEM_DQ_WIDTH*8-1:0]   calib_wrdata     ,
  output [MEM_DM_WIDTH*8-1:0]   calib_wrdata_mask                
  );

  wire        init_start   ;
  wire        init_done    ;
  wire        init_rst     ;
  wire [MEM_BANKADDR_WIDTH-1:0]  init_ba      ;
  wire [MEM_ADDR_WIDTH-1:0]      init_address ;
  wire        init_cs_n    ;
  wire        init_ras_n   ;
  wire        init_cas_n   ;
  wire        init_we_n    ;
  wire        init_cke     ;
  wire        init_odt     ;
  wire [7:0]  dbg_main     ;
  wire [3:0]  dbg_init     ;
  wire [3:0]  dbg_wrcal    ;
  wire [3:0]  dbg_eyecal   ;

  wire        wrlvl_start  ;
  wire        wrlvl_done   ;
  wire [MEM_BANKADDR_WIDTH-1:0]  wrlvl_ba     ;
  wire [MEM_ADDR_WIDTH-1:0]      wrlvl_address;
  wire        wrlvl_cs_n   ;
  wire        wrlvl_ras_n  ;
  wire        wrlvl_cas_n  ;
  wire        wrlvl_we_n   ;
  wire        wrlvl_cke    ;
  wire        wrlvl_odt    ;
  wire [3:0]  dbg_wrlvl    ;

  wire        rdcal_start  ;
  wire        rdcal_done   ;
  wire [MEM_BANKADDR_WIDTH-1:0]  rdcal_ba       ;
  wire [MEM_ADDR_WIDTH-1:0]      rdcal_address  ;
  wire        rdcal_cs_n     ;
  wire        rdcal_ras_n    ;
  wire        rdcal_cas_n    ;
  wire        rdcal_we_n     ;
  wire        rdcal_cke      ;
  wire        rdcal_odt      ;
  wire        ddrphy_rst_rreq;
  wire        rdcalib_error  ;
  wire [MEM_DQ_WIDTH*8-1:0] rdcal_wrdata      ;
  wire [3:0]  rdcal_wrdata_en   ; 

  wire        wrcal_start  ;
  wire        wrcal_done   ;
  wire [MEM_BANKADDR_WIDTH-1:0]  wrcal_ba       ;
  wire [MEM_ADDR_WIDTH-1:0]      wrcal_address  ;
  wire        wrcal_cs_n     ;
  wire        wrcal_ras_n    ;
  wire        wrcal_cas_n    ;
  wire        wrcal_we_n     ;
  wire        wrcal_cke      ;
  wire        wrcal_odt      ;
  wire [MEM_DQ_WIDTH*8-1:0] wrcal_wrdata      ;
  wire [3:0]  wrcal_wrdata_en   ;

  wire        eyecal_start  ;
  wire        eyecal_done   ;
  wire [MEM_BANKADDR_WIDTH-1:0]  eyecal_ba       ;
  wire [MEM_ADDR_WIDTH-1:0]      eyecal_address  ;
  wire        eyecal_cs_n     ;
  wire        eyecal_ras_n    ;
  wire        eyecal_cas_n    ;
  wire        eyecal_we_n     ;
  wire        eyecal_cke      ;
  wire        eyecal_odt      ;

  wire        update_start      ;

  wire [4:0]  dbg_rdcal         ;
  wire        calib_error       ;
  wire [3:0]  dbg_upcal;
  wire        eyecalib_error    ;

  assign  calib_error        = wrlvl_error | rdcalib_error | eyecalib_error;
  assign  calib_wrdata       = update_start ? {(MEM_DQ_WIDTH*8){1'b0}}  :
                               wrcal_start ? wrcal_wrdata : rdcal_wrdata ;       
  assign  calib_wrdata_en    = update_start ? 4'b0000                   : 
                               wrcal_start ? wrcal_wrdata_en : rdcal_wrdata_en   ;
  assign  calib_wrdata_mask  = {(MEM_DM_WIDTH*8){1'b0}};

  assign  ddrphy_rst_req = ddrphy_rst_rreq;
  assign  calib_rst      = init_rst;

  assign  debug_calib_ctrl = {dbg_main,dbg_init,dbg_wrlvl,dbg_rdcal,dbg_wrcal,dbg_eyecal,dbg_upcal,calib_error};  //8 4 4 5 4 4 4 1

  always@(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(~ddrphy_rst_n)
        dfi_error <= 1'b0;
    else 
        dfi_error <= calib_error;
  end

  ips2l_ddrphy_main_ctrl_v1_9 #(
   .DDR_TYPE        (DDR_TYPE      ),
//   .WRCAL_EN        (WRCAL_EN      ),
   .EYECAL_EN       (EYECAL_EN     )
  )ddrphy_main_ctrl(
   //port             
   .ddrphy_sysclk   (ddrphy_sysclk  ),
   .ddrphy_rst_n    (ddrphy_rst_n   ),
   .update_cal_req  (update_cal_req ),  
   .init_start      (init_start     ),
   .init_done       (init_done      ),
   .wrlvl_en        (wrlvl_en       ),
   .wrlvl_start     (wrlvl_start    ),
   .wrlvl_done      (wrlvl_done     ),                      
   .rdcal_start     (rdcal_start    ),
   .rdcal_done      (rdcal_done     ),
   .wrcal_start     (wrcal_start    ),
   .wrcal_done      (wrcal_done     ),
   .eyecal_start    (eyecal_start   ),
   .eyecal_done     (eyecal_done    ),   
   .update_start    (update_start   ),
   .update_done     (update_done    ),
   .dbg_main        (dbg_main       ),
   .calib_done      (calib_done     ),
   .wrlvl_error	    (wrlvl_error    ),
   .gate_cal_error  (gate_cal_error ),
   .rdel_calib_error(rdel_calib_error),
   .wrcal_error     (wrcal_error    )
   
//   .enter_dpd       (1'b0           ),
//   .exit_dpd        (1'b0           )
  );

  ips2l_ddrphy_init_v1_0 #( 
  .DDR_TYPE            (DDR_TYPE          ),
  .T200US              (T200US            ),
  .T500US              (T500US            ),
  .T400NS              (T400NS            ),
  .TMRD                (TMRD              ),
  .TMOD                (TMOD              ),
  .TXPR                (TXPR              ),
  .TRP                 (TRP               ),
  .TRFC                (TRFC              ),
  .TZQINIT             (TZQINIT           ),
  .REF_CNT             (REF_CNT           ),
  .MEM_ADDR_WIDTH      (MEM_ADDR_WIDTH    ),
  .MEM_BANKADDR_WIDTH  (MEM_BANKADDR_WIDTH)
  )ddrphy_init(
  .ddrphy_sysclk   (ddrphy_sysclk ),
  .ddrphy_rst_n   (ddrphy_rst_n ),

  .init_start     (init_start   ),
  .init_done      (init_done    ), 
  .mr0            (mr0          ),
  .mr1            (mr1          ),
  .mr2            (mr2          ),
  .mr3            (mr3          ),
  .dbg_init       (dbg_init     ),

  .init_rst       (init_rst     ),
  .init_ba        (init_ba      ),
  .init_address   (init_address ),
  .init_cs_n      (init_cs_n    ),
  .init_ras_n     (init_ras_n   ),
  .init_cas_n     (init_cas_n   ),
  .init_we_n      (init_we_n    ),
  .init_cke       (init_cke     ),
  .init_odt       (init_odt     )
 );

 ips2l_ddrphy_wrlvl_v1_0 #(
  .TMOD                (TMOD              ),
  .TRFC                (TRFC              ),
  .MEM_ADDR_WIDTH      (MEM_ADDR_WIDTH    ),
  .MEM_BANKADDR_WIDTH  (MEM_BANKADDR_WIDTH)
 )ddrphy_wrlvl(
  .mr1_ddr3        (mr1            ),
  .ddrphy_sysclk   (ddrphy_sysclk  ),
  .ddrphy_rst_n    (ddrphy_rst_n   ),

  .wrlvl_start     (wrlvl_start    ),
  .wrlvl_done      (wrlvl_done     ),
  .wrlvl_error     (wrlvl_error    ),
  .wrlvl_dqs_req   (wrlvl_dqs_req  ),
  .wrlvl_dqs_resp  (wrlvl_dqs_resp ),
  .dbg_wrlvl       (dbg_wrlvl      ),

  .wrlvl_ba        (wrlvl_ba       ),
  .wrlvl_address   (wrlvl_address  ),
  .wrlvl_cs_n      (wrlvl_cs_n     ),
  .wrlvl_ras_n     (wrlvl_ras_n    ),
  .wrlvl_cas_n     (wrlvl_cas_n    ),
  .wrlvl_we_n      (wrlvl_we_n     ),
  .wrlvl_cke       (wrlvl_cke      ),
  .wrlvl_odt       (wrlvl_odt      )
 );
                     
  ips2l_ddrphy_rdcal_v1_5 #(    
  .DDR_TYPE            (DDR_TYPE           ),
  .TRFC                (TRFC               ),
  .TRCD                (TRCD               ),
  .MEM_ADDR_WIDTH      (MEM_ADDR_WIDTH     ),
  .MEM_BANKADDR_WIDTH  (MEM_BANKADDR_WIDTH ),
  .MEM_DQ_WIDTH        (MEM_DQ_WIDTH       )
  )ddrphy_rdcal(
   .mc_wl              (mc_wl             ),
   .ddrphy_sysclk      (ddrphy_sysclk     ),
   .ddrphy_rst_n       (ddrphy_rst_n      ),
   .rdcal_start        (rdcal_start       ),
   .rdcal_done         (rdcal_done        ),

   .ddrphy_rst_req     (ddrphy_rst_rreq   ),
   .ddrphy_rst_ack     (ddrphy_rst_ack    ),

   .gatecal_start      (gatecal_start     ),
   .gate_check_pass    (gate_check_pass   ),
   .gate_adj_done      (gate_adj_done     ),
   .gate_cal_error     (gate_cal_error    ),
   .gate_move_en       (gate_move_en      ),

   .rddata_cal         (rddata_cal        ), 
   .rddata_check_pass  (rddata_check_pass ),
   .init_adj_rdel      (init_adj_rdel     ),
   .adj_rdel_done      (adj_rdel_done     ),

   .rdel_calibration   (rdel_calibration  ),
   .rdel_calib_done    (rdel_calib_done   ),
   .rdel_calib_error   (rdel_calib_error  ),
   .rdel_move_en       (rdel_move_en      ),
   .rdel_move_done     (rdel_move_done    ),

   .write_debug        (write_debug       ),
   .dqgt_debug         (dqgt_debug        ),
   .rdel_rd_cnt        (rdel_rd_cnt       ),

   .bitslip_ctrl       (bitslip_ctrl      ),
   .rdcalib_error      (rdcalib_error     ),
   .dbg_rdcal          (dbg_rdcal         ),

   .rdcal_ba           (rdcal_ba          ),
   .rdcal_address      (rdcal_address     ),
   .rdcal_cs_n         (rdcal_cs_n        ),
   .rdcal_ras_n        (rdcal_ras_n       ),
   .rdcal_cas_n        (rdcal_cas_n       ),
   .rdcal_we_n         (rdcal_we_n        ),
   .rdcal_cke          (rdcal_cke         ),
   .rdcal_odt          (rdcal_odt         ),
   .rdcal_wrdata       (rdcal_wrdata      ),
   .rdcal_wrdata_en    (rdcal_wrdata_en   )
  );

ips2l_ddrphy_wrcal_v1_7 #(
  .WRCAL_EN            (WRCAL_EN           ),
  .TRFC                (TRFC               ),
  .TRCD                (TRCD               ),
  .TEST_DATA_PATTERN0  (TEST_DATA_PATTERN0 ),
  .TEST_DATA_PATTERN1  (TEST_DATA_PATTERN1 ),
  .TEST_DATA_PATTERN2  (TEST_DATA_PATTERN2 ),
  .TEST_DATA_PATTERN3  (TEST_DATA_PATTERN3 ),
  .MEM_ADDR_WIDTH      (MEM_ADDR_WIDTH     ),
  .MEM_BANKADDR_WIDTH  (MEM_BANKADDR_WIDTH ),
  .MEM_DQ_WIDTH        (MEM_DQ_WIDTH       )
)ddrphy_wrcal(
   .mc_wl              (mc_wl              ),
   .ddrphy_sysclk      (ddrphy_sysclk      ),
   .ddrphy_rst_n       (ddrphy_rst_n       ),
   .wrcal_start        (wrcal_start        ),
   .wrcal_done         (wrcal_done         ),

   .wrcal_check_pass   (wrcal_check_pass   ),
   .write_calibration  (write_calibration  ),
   .wrcal_move_en      (wrcal_move_en      ),
   .wrcal_move_done    (wrcal_move_done    ),
   
   .wrcal_ba           (wrcal_ba          ),
   .wrcal_address      (wrcal_address     ),
   .wrcal_cs_n         (wrcal_cs_n        ),
   .wrcal_ras_n        (wrcal_ras_n       ),
   .wrcal_cas_n        (wrcal_cas_n       ),
   .wrcal_we_n         (wrcal_we_n        ),
   .wrcal_cke          (wrcal_cke         ),
   .wrcal_odt          (wrcal_odt         ),
   .wrcal_wrdata       (wrcal_wrdata      ),
   .wrcal_wrdata_en    (wrcal_wrdata_en   ),
   .dbg_wrcal          (dbg_wrcal         )
);

ips2l_ddrphy_eyecal_v1_5 #(
  .TRFC                (TRFC               ),
  .TRCD                (TRCD               ),
  .MEM_ADDR_WIDTH      (MEM_ADDR_WIDTH     ),
  .MEM_BANKADDR_WIDTH  (MEM_BANKADDR_WIDTH ),
  .MEM_DQ_WIDTH        (MEM_DQ_WIDTH       )
)ddrphy_eyecal(
   .ddrphy_sysclk      (ddrphy_sysclk     ),
   .ddrphy_rst_n       (ddrphy_rst_n      ),
                                          
   .eyecal_start       (eyecal_start      ),
   .eyecal_done        (eyecal_done       ),
   .eye_calibration    (eye_calibration   ),
   .eyecal_check_pass  (eyecal_check_pass ),
   .eyecal_move_done   (eyecal_move_done  ),
   .eyecal_move_en     (eyecal_move_en    ),
   .eye_calibration_error (rdel_calib_error ),   
   .eyecalib_error     (eyecalib_error    ),  
                                       
   .eyecal_ba          (eyecal_ba         ),
   .eyecal_address     (eyecal_address    ),
   .eyecal_cs_n        (eyecal_cs_n       ),
   .eyecal_ras_n       (eyecal_ras_n      ),
   .eyecal_cas_n       (eyecal_cas_n      ),
   .eyecal_we_n        (eyecal_we_n       ),
   .eyecal_cke         (eyecal_cke        ),
   .eyecal_odt         (eyecal_odt        ),
   .dbg_eyecal         (dbg_eyecal        )
);

   ips2l_ddrphy_calib_mux_v1_0 #(
     .DDR_TYPE            (DDR_TYPE          ),  
     .MEM_ADDR_WIDTH      (MEM_ADDR_WIDTH    ),
     .MEM_BANKADDR_WIDTH  (MEM_BANKADDR_WIDTH)
     )ddrphy_calib_mux (
     .ddrphy_sysclk       (ddrphy_sysclk    ),
     .ddrphy_rst_n        (ddrphy_rst_n     ),
                                            
     .init_start          (init_start       ),
     .init_ba             (init_ba          ),
     .init_address        (init_address     ),
     .init_cs_n           (init_cs_n        ),
     .init_ras_n          (init_ras_n       ),
     .init_cas_n          (init_cas_n       ),
     .init_we_n           (init_we_n        ),
     .init_cke            (init_cke         ),
     .init_odt            (init_odt         ),
                                            
     .wrlvl_start         (wrlvl_start      ),
     .wrlvl_ba            (wrlvl_ba         ),
     .wrlvl_address       (wrlvl_address    ),
     .wrlvl_cs_n          (wrlvl_cs_n       ),
     .wrlvl_ras_n         (wrlvl_ras_n      ),
     .wrlvl_cas_n         (wrlvl_cas_n      ),
     .wrlvl_we_n          (wrlvl_we_n       ),
     .wrlvl_cke           (wrlvl_cke        ),
     .wrlvl_odt           (wrlvl_odt        ),
                                            
     .rdcal_start         (rdcal_start      ),
     .rdcal_ba            (rdcal_ba         ),
     .rdcal_address       (rdcal_address    ),
     .rdcal_cs_n          (rdcal_cs_n       ),
     .rdcal_ras_n         (rdcal_ras_n      ),
     .rdcal_cas_n         (rdcal_cas_n      ),
     .rdcal_we_n          (rdcal_we_n       ),
     .rdcal_cke           (rdcal_cke        ),
     .rdcal_odt           (rdcal_odt        ),

     .wrcal_start         (wrcal_start      ),
     .wrcal_ba            (wrcal_ba         ),
     .wrcal_address       (wrcal_address    ),
     .wrcal_cs_n          (wrcal_cs_n       ),
     .wrcal_ras_n         (wrcal_ras_n      ),
     .wrcal_cas_n         (wrcal_cas_n      ),
     .wrcal_we_n          (wrcal_we_n       ),
     .wrcal_cke           (wrcal_cke        ),
     .wrcal_odt           (wrcal_odt        ),
                          
     .eyecal_start        (eyecal_start     ),
     .eyecal_ba           (eyecal_ba        ),
     .eyecal_address      (eyecal_address   ),
     .eyecal_cs_n         (eyecal_cs_n      ),
     .eyecal_ras_n        (eyecal_ras_n     ),
     .eyecal_cas_n        (eyecal_cas_n     ),
     .eyecal_we_n         (eyecal_we_n      ),
     .eyecal_cke          (eyecal_cke       ),
     .eyecal_odt          (eyecal_odt       ),
                          
     .update_start        (update_start     ), 
                                            
     .calib_ba            (calib_ba         ),
     .calib_address       (calib_address    ),
     .calib_cs_n          (calib_cs_n       ),
     .calib_ras_n         (calib_ras_n      ),
     .calib_cas_n         (calib_cas_n      ),
     .calib_we_n          (calib_we_n       ),
     .calib_cke           (calib_cke        ),
     .calib_odt           (calib_odt        )
    );

   ips2l_ddrphy_upcal_v1_0 #(
     .MEM_DQS_WIDTH      (MEM_DQS_WIDTH     )
   )ddrphy_upcal(
     .ddrphy_sysclk      (ddrphy_sysclk     ), 
     .ddrphy_rst_n       (ddrphy_rst_n      ), 
     
     .update_start       (update_start      ), 
     .update_done        (update_done       ), 
   
 //    .dll_update_ack     (dll_update_ack    ), 
//     .dll_update_req     (dll_update_req    ), 

     .update_comp_val    (update_comp_val   ),
     .update_comp_dir    (update_comp_dir   ),

     .comp_val           (comp_val          ),
     .comp_dir           (comp_dir          ),
     .dqs_gate_comp_en   (dqs_gate_comp_en  ),
     .dqs_gate_comp_done (dqs_gate_comp_done),
     .dbg_upcal          (dbg_upcal         )
    );

endmodule  
