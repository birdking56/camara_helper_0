////////////////////////////////////////////////////////////////    
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC                       
// ALL RIGHTS REVERVED.                                             
////////////////////////////////////////////////////////////////    
//Description:                                                      
//Author:  wxxiao                                                   
//History: v1.0                                                     
////////////////////////////////////////////////////////////////    
`timescale 1ns/1ps                                                  
module ips2l_ddrphy_data_slice_dqs_gate_cal_v1_6 #(
    parameter  GATE_MODE       =  0
)(
    input [4:0]    mc_rl                ,
    input [2:0]    init_read_clk_ctrl   ,       
    input [3:0]    init_slip_step       ,
    input          force_read_clk_ctrl  ,       
                              
    input          ddrphy_sysclk        ,
    input          ddrphy_rst_n         ,

    input          gatecal_start        ,
    output         gate_check_pass      ,
    output         gate_adj_done        ,
    output         gate_cal_error       ,
    input          gate_move_en         , 
    input          rddata_cal           ,

    input  [3:0]   read_cmd             , 

    input [1:0]    comp_val             ,
    input          comp_dir             ,
    input          dqs_gate_comp_en     ,
    output         dqs_gate_comp_done   ,
                       
    input          ddrphy_dgts          , 
    input          dqs_gate_sample      ,
    output         dqs_gate_vld         ,
    output [3:0]   coarse_slip_step     ,
    output [3:0]   gate_win_size        ,
    output [3:0]   dqs_gate_ctrl        ,
    output [2:0]   read_clk_ctrl        ,
    output [2:0]   dbg_slice_gate_state
  );     

  ips2l_ddrphy_dqs_gate_coarse_cal_v1_0  ddrphy_dqs_gate_coarse_cal(                     
      .mc_rl             (mc_rl            ),
      .ddrphy_sysclk     (ddrphy_sysclk    ),
      .ddrphy_rst_n      (ddrphy_rst_n     ),
                                           
      .read_cmd          (read_cmd         ),
      .gatecal_start     (gatecal_start    ),
      .rddata_cal        (rddata_cal       ),
      
      .coarse_slip_step  (coarse_slip_step ),
      .dqs_gate_ctrl     (dqs_gate_ctrl    ),
      .dqs_gate_vld      (dqs_gate_vld     )
   );                                                               
 
  ips2l_ddrphy_gatecal_v1_6 #(
      .GATE_MODE           (GATE_MODE           )
   )ddrphy_gatecal(
      .init_read_clk_ctrl  (init_read_clk_ctrl  ),    
      .init_slip_step      (init_slip_step      ),    
      .force_read_clk_ctrl (force_read_clk_ctrl ),    

      .ddrphy_sysclk       (ddrphy_sysclk       ),    
      .ddrphy_rst_n        (ddrphy_rst_n        ),    

      .comp_val            (comp_val            ) ,
      .comp_dir            (comp_dir            ) ,
      .dqs_gate_comp_en    (dqs_gate_comp_en    ),
      .dqs_gate_comp_done  (dqs_gate_comp_done  ),

      .gatecal_start       (gatecal_start       ),    
      .gate_check_pass     (gate_check_pass     ),    
      .gate_adj_done       (gate_adj_done       ),    
      .gate_cal_error      (gate_cal_error      ),    
      .dqs_gate_vld        (dqs_gate_vld        ),    
      .gate_move_en        (gate_move_en        ),    

      .coarse_slip_step    (coarse_slip_step    ),    
      .read_clk_ctrl       (read_clk_ctrl       ), 
      .gate_win_size       (gate_win_size       ),   
      .ddrphy_dgts         (ddrphy_dgts         ),
      .dqs_gate_sample     (dqs_gate_sample     ),
      .dbg_slice_gate_state(dbg_slice_gate_state)
    );    
                

endmodule                                                       
