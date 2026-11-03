

////////////////////////////////////////////////////////////////
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
////////////////////////////////////////////////////////////////
//Description:
//Author:  wxxiao
//History: v1.0
////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
module test_ddr #(

   parameter MEM_ROW_WIDTH        = 15         ,

   parameter MEM_COLUMN_WIDTH     = 10         ,

   parameter MEM_BANK_WIDTH       = 3          ,

  parameter MEM_DQ_WIDTH          = 32         ,

  parameter MEM_DQS_WIDTH         = 4

)(
input                                ref_clk_p                 ,
input                                ref_clk_n                 ,
input                                free_clk                  ,
input                                rst_board                 ,
output                               pll_lock                  ,
output                               ddrphy_cpd_lock           ,
output                               ddr_init_done             ,
//uart
input                                uart_rxd                  ,
output                               uart_txd                  ,


output                               mem_cs_n                  ,

output                               mem_rst_n                 ,
output                               mem_ck                    ,
output                               mem_ck_n                  ,
output                               mem_cke                   ,
output                               mem_ras_n                 ,
output                               mem_cas_n                 ,
output                               mem_we_n                  ,
output                               mem_odt                   ,
output      [MEM_ROW_WIDTH-1:0]      mem_a                     ,
output      [MEM_BANK_WIDTH-1:0]     mem_ba                    ,
inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs                   ,
inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs_n                 ,
inout       [MEM_DQ_WIDTH-1:0]       mem_dq                    ,
output      [MEM_DQ_WIDTH/8-1:0]     mem_dm                    ,
output reg                           heart_beat_led            ,
output                               err_flag_led

);


parameter CTRL_ADDR_WIDTH = MEM_ROW_WIDTH + MEM_BANK_WIDTH + MEM_COLUMN_WIDTH;
parameter TH_1S = 27'd33000000;
parameter REM_DQS_WIDTH = 9 - MEM_DQS_WIDTH;

wire                        core_clk                   ;
wire [CTRL_ADDR_WIDTH-1:0]  axi_awaddr                 ;
wire                        axi_awuser_ap              ;
wire [3:0]                  axi_awuser_id              ;
wire [3:0]                  axi_awlen                  ;
wire                        axi_awready                ;
wire                        axi_awvalid                ;
wire [MEM_DQ_WIDTH*8-1:0]   axi_wdata                  ;
wire [MEM_DQ_WIDTH*8/8-1:0] axi_wstrb                  ;
wire                        axi_wready                 ;
wire [3:0]                  axi_wusero_id              ;
wire                        axi_wusero_last            ;
wire [CTRL_ADDR_WIDTH-1:0]  axi_araddr                 ;
wire                        axi_aruser_ap              ;
wire [3:0]                  axi_aruser_id              ;
wire [3:0]                  axi_arlen                  ;
wire                        axi_arready                ;
wire                        axi_arvalid                ;
wire [MEM_DQ_WIDTH*8-1:0]   axi_rdata  /* synthesis syn_keep = 1 */;
wire                        axi_rvalid /* synthesis syn_keep = 1 */;
wire [3:0]                  axi_rid                    ;
wire                        axi_rlast                  ;
wire [CTRL_ADDR_WIDTH-1:0]  random_rw_addr             ;
wire [3:0]                  random_axi_id              ;
wire [3:0]                  random_axi_len             ;
wire                        random_axi_ap              ;
wire                        resetn                     ;
wire                        init_start                 ;
wire                        init_done                  ;
wire                        write_en                   ;
wire                        write_done_p               ;
wire                        read_en                    ;
wire                        read_done_p                ;

reg  [26:0]                 cnt                        ;
wire [7:0]                  err_cnt                    ;
wire                        free_clk_g                 ;

//***********************************************************************************
//uart ctrl
wire [31:0]                 ctrl_bus_0                 ;
wire [31:0]                 ctrl_bus_1                 ;
wire [31:0]                 ctrl_bus_2                 ;
wire [31:0]                 ctrl_bus_3                 ;
wire [31:0]                 ctrl_bus_4                 ;
wire [31:0]                 ctrl_bus_5                 ;
wire [31:0]                 ctrl_bus_6                 ;
wire [31:0]                 ctrl_bus_7                 ;
wire [31:0]                 ctrl_bus_8                 ;
wire [31:0]                 ctrl_bus_9                 ;
wire [31:0]                 ctrl_bus_10                ;
wire [31:0]                 ctrl_bus_11                ;
wire [31:0]                 ctrl_bus_12                ;

wire [31:0]                 status_bus_80              ;
wire [31:0]                 status_bus_81              ;
wire [31:0]                 status_bus_82              ;
wire [31:0]                 status_bus_83              ;
wire [31:0]                 status_bus_84              ;
wire [31:0]                 status_bus_85              ;
wire [31:0]                 status_bus_86              ;
wire [31:0]                 status_bus_87              ;
wire [31:0]                 status_bus_88              ;
wire [31:0]                 status_bus_89              ;
wire [31:0]                 status_bus_8a              ;
wire [31:0]                 status_bus_8b              ;
wire [31:0]                 status_bus_8c              ;
wire [31:0]                 status_bus_8d              ;
wire [31:0]                 status_bus_8e              ;
wire [31:0]                 status_bus_8f              ;

wire [31:0]                 status_bus_90              ;
wire [31:0]                 status_bus_91              ;
wire [31:0]                 status_bus_92              ;
wire [31:0]                 status_bus_93              ;
wire [31:0]                 status_bus_94              ;
wire [31:0]                 status_bus_95              ;
wire [31:0]                 status_bus_96              ;
wire [31:0]                 status_bus_97              ;
wire [31:0]                 status_bus_98              ;
wire [31:0]                 status_bus_99              ;
wire [31:0]                 status_bus_9a              ;
wire [31:0]                 status_bus_9b              ;
wire [31:0]                 status_bus_9c              ;
wire [31:0]                 status_bus_9d              ;
wire [31:0]                 status_bus_9e              ;
wire [31:0]                 status_bus_9f              ;

wire [31:0]                 status_bus_a0              ; 
wire [31:0]                 status_bus_a1              ; 
wire [31:0]                 status_bus_a2              ; 
wire [31:0]                 status_bus_a3              ; 
wire [31:0]                 status_bus_a4              ; 
wire [31:0]                 status_bus_a5              ; 
wire [31:0]                 status_bus_a6              ; 
wire [31:0]                 status_bus_a7              ; 
wire [31:0]                 status_bus_a8              ;
wire [31:0]                 status_bus_a9              ;
wire [31:0]                 status_bus_aa              ;
wire [31:0]                 status_bus_ab              ;          
wire [31:0]                 status_bus_ac              ;          
wire [31:0]                 status_bus_ad              ;          
wire [31:0]                 status_bus_ae              ;          
wire [31:0]                 status_bus_af              ;          

wire [31:0]                 status_bus_b0              ;          
wire [31:0]                 status_bus_b1              ;          
wire [31:0]                 status_bus_b2              ;          
wire [31:0]                 status_bus_b3              ;          
wire [31:0]                 status_bus_b4              ;          
wire [31:0]                 status_bus_b5              ;          
wire [31:0]                 status_bus_b6              ;          
wire [31:0]                 status_bus_b7              ;          
wire [31:0]                 status_bus_b8              ;          
wire [31:0]                 status_bus_b9              ;          
wire [31:0]                 status_bus_ba              ;          
wire [31:0]                 status_bus_bb              ;          
wire [31:0]                 status_bus_bc              ;          
wire [31:0]                 status_bus_bd              ;          
wire [31:0]                 status_bus_be              ;          
wire [31:0]                 status_bus_bf              ;

wire [31:0]                 status_bus_c0              ;          
wire [31:0]                 status_bus_c1              ;          
wire [31:0]                 status_bus_c2              ;          
wire [31:0]                 status_bus_c3              ;          
wire [31:0]                 status_bus_c4              ;          
wire [31:0]                 status_bus_c5              ;          
wire [31:0]                 status_bus_c6              ;          
wire [31:0]                 status_bus_c7              ;          
wire [31:0]                 status_bus_c8              ;          
wire [31:0]                 status_bus_c9              ;          
wire [31:0]                 status_bus_ca              ;          
wire [31:0]                 status_bus_cb              ;          
wire [31:0]                 status_bus_cc              ;          
wire [31:0]                 status_bus_cd              ;          
wire [31:0]                 status_bus_ce              ;          
wire [31:0]                 status_bus_cf              ;

wire [31:0]                 status_bus_d0              ;          
wire [31:0]                 status_bus_d1              ;          
wire [31:0]                 status_bus_d2              ;          
wire [31:0]                 status_bus_d3              ;          
wire [31:0]                 status_bus_d4              ;          
wire [31:0]                 status_bus_d5              ;          
wire [31:0]                 status_bus_d6              ;          
wire [31:0]                 status_bus_d7              ;          
wire [31:0]                 status_bus_d8              ;          
wire [31:0]                 status_bus_d9              ;          
wire [31:0]                 status_bus_da              ;          
wire [31:0]                 status_bus_db              ;          
wire [31:0]                 status_bus_dc              ;          
wire [31:0]                 status_bus_dd              ;          
wire [31:0]                 status_bus_de              ;          
wire [31:0]                 status_bus_df              ;

wire [31:0]                 status_bus_e0              ;
wire [31:0]                 status_bus_e1              ;
wire [31:0]                 status_bus_e2              ;
wire [31:0]                 status_bus_e3              ;
wire [31:0]                 status_bus_e4              ;

wire [31:0]                 status_bus_lock            ;
wire                        uart_read_req              ;
wire                        uart_read_ack              ;
wire [7:0]                  uart_read_addr             ;

wire                         free_clk_rst_n            ;
wire                         dbg_ddr_rst_n             ;
wire                         dbg_gate_start            ;
wire                         dbg_cpd_start             ;
wire                         dbg_ddrphy_rst_n          ;
wire                         dbg_gpll_scan_rst         ;
wire                         data_pattern_01           ;
wire                         random_data_en            ;
wire                         read_double_en            ;
wire                         dbg_test_start_en         ;
wire                         data_pattern_01_syn       ;
wire                         random_data_en_syn        ;
wire                         manu_clear_syn            ;
wire                         read_double_en_syn        ;
wire                         dbg_test_start_en_syn     ;
wire                         dbg_temp_rd               ;
wire                         dbg_volt_rd               ;
wire [15:0]                  adc_rdata                 ;
wire                         core_clk_rst_n            ;
wire [33:0]                  debug_calib_ctrl          ;
wire [66*MEM_DQS_WIDTH -1:0] debug_data                ;
wire [17*MEM_DQS_WIDTH -1:0] dbg_slice_status          ;
wire [22*MEM_DQS_WIDTH -1:0] dbg_slice_state           ;
wire [1:0]                   dbg_dll_upd_state         ;
wire [8:0]                   debug_gpll_dps_phase      ;
wire [66*9 -1:0]             status_debug_data         ;
wire [22*9 -1:0]             status_dbg_slice_state    ;
wire [3:0]                   test_main_state           ;
wire [2:0]                   test_wr_state             ;
wire [2:0]                   test_rd_state             ;

wire [2:0]                   dbg_rst_dps_state         ;
wire [5:0]                   dbg_tran_err_rst_cnt      ;
wire                         dbg_ddrphy_init_fail      ;

wire                         debug_cpd_offset_adj      ;
wire                         debug_cpd_offset_dir      ;
wire  [9:0]                  debug_cpd_offset          ;

wire                         force_read_clk_ctrl       ;
wire  [4*9-1:0]              init_slip_step            ;
wire  [3*9-1:0]              init_read_clk_ctrl        ;

wire                         align_error               ;
wire  [3:0]                  debug_rst_state           ;
wire  [3:0]                  debug_cpd_state           ;
wire  [9:0]                  debug_dps_cnt_dir0        ;
wire  [9:0]                  debug_dps_cnt_dir1        ;

wire  [64*9-1:0]             status_err_data_out       ;
wire  [64*9-1:0]             status_err_flag_out       ;
wire  [64*9-1:0]             status_next_err_data      ;
wire  [MEM_DQ_WIDTH*8-1:0]   err_data_out              ;
wire  [MEM_DQ_WIDTH*8-1:0]   err_flag_out              ;
wire  [2:0]                  err_rd_cnt_out            ;
wire                         manu_clear                ;
wire                         err_lock                  ;

wire                         samp_position_dyn_adj     ;
wire  [8*9-1:0]              init_samp_position_even   ;
wire  [8*9-1:0]              init_samp_position_odd    ;
wire                         wrcal_position_dyn_adj    ;
wire  [8*9-1:0]              init_wrcal_position       ;

wire                         rst_gpll_lock             ;
wire                         ref_clk                   ;

wire                         wr_data_chg               ;
wire                         rd_data_chg               ;
wire                         stress_test               ;
wire                         stress_test_syn           ;
wire                         stress_test_valid         ;
wire  [2:0]                  rd_cnt                    ;
wire                         rd_dir_err                ;
wire  [31:0]                 read_cmd_cnt              ; 
wire  [MEM_DQ_WIDTH*8-1:0]   next_err_data             ;
wire  [MEM_DQ_WIDTH-1:0]     err_data_pre              ;
wire  [MEM_DQ_WIDTH-1:0]     err_data_aft              ;
wire  [71:0]                 status_err_data_pre       ;
wire  [71:0]                 status_err_data_aft       ;
wire  [3:0]                  burst_cnt                 ;

wire                         gpll_lock                 ;
wire                         phy_pll_lock              ;

wire                         force_ck_dly_en           ;
wire  [7:0]                  force_ck_dly_set_bin      ;
wire  [7:0]                  ck_dly_set_bin            ;  

GTP_INBUFDS refclk_inbuf
(
    .O                          (ref_clk                      ),
    .I                          (ref_clk_p                    ),
    .IB                         (ref_clk_n                    )
);

GTP_CLKBUFG free_clk_ibufg
(
    .CLKOUT                     (free_clk_g                   ),
    .CLKIN                      (free_clk                     )
);

assign status_dbg_slice_state = {{22*REM_DQS_WIDTH{1'b0}},dbg_slice_state};
assign status_debug_data      = {{66*REM_DQS_WIDTH{1'b0}},debug_data     };
assign status_err_data_out    = {{64*REM_DQS_WIDTH{1'b0}},err_data_out   };
assign status_err_flag_out    = {{64*REM_DQS_WIDTH{1'b0}},err_flag_out   };
assign status_next_err_data   = {{64*REM_DQS_WIDTH{1'b0}},next_err_data  };
assign status_err_data_pre    = {{ 8*REM_DQS_WIDTH{1'b0}},err_data_pre   };
assign status_err_data_aft    = {{ 8*REM_DQS_WIDTH{1'b0}},err_data_aft   };

//control bus 0
parameter DFT_CTRL_BUS_0 = 32'h0000_1001;
assign dbg_ddr_rst_n     = ctrl_bus_0[0];
assign dbg_gate_start    = ctrl_bus_0[4];
assign dbg_cpd_start     = ctrl_bus_0[8];
assign dbg_ddrphy_rst_n  = ctrl_bus_0[12];
assign dbg_gpll_scan_rst = ctrl_bus_0[16];

//control bus 1
parameter DFT_CTRL_BUS_1  = 32'h1001_1110;
assign data_pattern_01   = ctrl_bus_1[0];
assign manu_clear        = ctrl_bus_1[1];
assign random_data_en    = ctrl_bus_1[4];
assign read_double_en    = ctrl_bus_1[8];
assign dbg_test_start_en = ctrl_bus_1[12];
assign dbg_temp_rd       = ctrl_bus_1[20];
assign dbg_volt_rd       = ctrl_bus_1[24];
assign stress_test       = ctrl_bus_1[28];

//control bus 2
parameter DFT_CTRL_BUS_2    = 32'h00_00_00_00;
assign debug_cpd_offset_adj = ctrl_bus_2[0];
assign debug_cpd_offset_dir = ctrl_bus_2[4];
assign debug_cpd_offset     = ctrl_bus_2[17:8];

//control bus 3
parameter DFT_CTRL_BUS_3        = 32'h00_00_00_00;
assign force_read_clk_ctrl      = ctrl_bus_3[0];
assign init_read_clk_ctrl       = ctrl_bus_3[27:1];
assign init_slip_step[35:32]    = ctrl_bus_3[31:28];

//control bus 4
parameter DFT_CTRL_BUS_4        = 32'h00_00_00_00;
assign init_slip_step[31:0]     = ctrl_bus_4[31:0];

//control bus 5
parameter DFT_CTRL_BUS_5          = 32'h00_00_00_00;
assign wrcal_position_dyn_adj     = ctrl_bus_5[0];
assign init_wrcal_position[71:64] = ctrl_bus_5[11:4];

//control bus 6
parameter DFT_CTRL_BUS_6          = 32'h00_00_00_00;
assign init_wrcal_position[63:32] = ctrl_bus_6[31:0];

//control bus 7
parameter DFT_CTRL_BUS_7          = 32'h00_00_00_00;
assign init_wrcal_position[31:0]  = ctrl_bus_7[31:0];

//control bus 8
parameter DFT_CTRL_BUS_8              = 32'h05_00_00_00;
assign samp_position_dyn_adj          = ctrl_bus_8[0];
assign init_samp_position_even[71:64] = ctrl_bus_8[11:4];
assign init_samp_position_odd[71:64]  = ctrl_bus_8[19:12];
assign force_ck_dly_en                = ctrl_bus_8[20];
assign force_ck_dly_set_bin           = ctrl_bus_8[31:24];

//control bus 9
parameter DFT_CTRL_BUS_9              = 32'h00_00_00_00;
assign init_samp_position_even[63:32] = ctrl_bus_9[31:0];

//control bus 10
parameter DFT_CTRL_BUS_10             = 32'h00_00_00_00;
assign init_samp_position_even[31:0]  = ctrl_bus_10[31:0];

//control bus 11
parameter DFT_CTRL_BUS_11            = 32'h00_00_00_00;
assign init_samp_position_odd[63:32] = ctrl_bus_11[31:0];

//control bus 12
parameter DFT_CTRL_BUS_12            = 32'h00_00_00_00;
assign init_samp_position_odd[31:0]  = ctrl_bus_12[31:0];

//status
assign status_bus_80 = {align_error,dbg_ddrphy_init_fail,dbg_tran_err_rst_cnt,1'b0,dbg_rst_dps_state,3'b0,heart_beat_led,
                        3'b0,ddr_init_done,3'b0,ddrphy_cpd_lock,2'b0,rst_gpll_lock,pll_lock,phy_pll_lock,gpll_lock,rd_dir_err,err_flag_led};
assign status_bus_81 = {2'b0,debug_calib_ctrl[29:0]};
assign status_bus_82 = {24'b0,ck_dly_set_bin};
assign status_bus_83 = {28'b0,debug_calib_ctrl[33:30]};
assign status_bus_84 = 32'b0;
assign status_bus_85 = 32'b0;
assign status_bus_86 = 32'b0;
assign status_bus_87 = 32'b0;
assign status_bus_88 = 32'b0;
assign status_bus_89 = 32'b0;
assign status_bus_8a = {debug_rst_state,debug_cpd_state,7'b0,debug_gpll_dps_phase,8'b0};
assign status_bus_8b = {adc_rdata[15:4],1'b0,test_rd_state,1'b0,test_wr_state,test_main_state,err_cnt};
assign status_bus_8c = {err_lock,err_rd_cnt_out,2'b0,debug_dps_cnt_dir1,6'b0,debug_dps_cnt_dir0};
assign status_bus_8d = read_cmd_cnt;
assign status_bus_8e = {28'h0,burst_cnt};
assign status_bus_8f = 32'b0;

assign status_bus_90 = status_debug_data[32*0 +: 32];
assign status_bus_91 = status_debug_data[32*1 +: 32];
assign status_bus_92 = status_debug_data[32*2 +: 32];
assign status_bus_93 = status_debug_data[32*3 +: 32];
assign status_bus_94 = status_debug_data[32*4 +: 32];
assign status_bus_95 = status_debug_data[32*5 +: 32];
assign status_bus_96 = status_debug_data[32*6 +: 32];
assign status_bus_97 = status_debug_data[32*7 +: 32];
assign status_bus_98 = status_debug_data[32*8 +: 32];
assign status_bus_99 = status_debug_data[32*9 +: 32];
assign status_bus_9a = status_debug_data[32*10 +: 32];
assign status_bus_9b = status_debug_data[32*11 +: 32];
assign status_bus_9c = status_debug_data[32*12 +: 32];
assign status_bus_9d = status_debug_data[32*13 +: 32];
assign status_bus_9e = status_debug_data[32*14 +: 32];
assign status_bus_9f = status_debug_data[32*15 +: 32];

assign status_bus_a0 = status_debug_data[32*16 +: 32];
assign status_bus_a1 = status_debug_data[32*17 +: 32];
assign status_bus_a2 = {14'b0,status_debug_data[32*18 +: 18]};
assign status_bus_a3 = status_dbg_slice_state[32*0 +: 32];
assign status_bus_a4 = status_dbg_slice_state[32*1 +: 32];
assign status_bus_a5 = status_dbg_slice_state[32*2 +: 32];
assign status_bus_a6 = status_dbg_slice_state[32*3 +: 32];
assign status_bus_a7 = status_dbg_slice_state[32*4 +: 32];
assign status_bus_a8 = status_dbg_slice_state[32*5 +: 32];
assign status_bus_a9 = {26'b0,status_dbg_slice_state[32*6 +: 6]};
assign status_bus_aa = status_err_flag_out[32*0 +: 32];
assign status_bus_ab = status_err_flag_out[32*1 +: 32];
assign status_bus_ac = status_err_flag_out[32*2 +: 32];
assign status_bus_ad = status_err_flag_out[32*3 +: 32];
assign status_bus_ae = status_err_flag_out[32*4 +: 32];
assign status_bus_af = status_err_flag_out[32*5 +: 32];

assign status_bus_b0 = status_err_flag_out[32*6 +: 32];
assign status_bus_b1 = status_err_flag_out[32*7 +: 32];
assign status_bus_b2 = status_err_flag_out[32*8 +: 32];
assign status_bus_b3 = status_err_flag_out[32*9 +: 32];
assign status_bus_b4 = status_err_flag_out[32*10 +: 32];
assign status_bus_b5 = status_err_flag_out[32*11 +: 32];
assign status_bus_b6 = status_err_flag_out[32*12 +: 32];
assign status_bus_b7 = status_err_flag_out[32*13 +: 32];
assign status_bus_b8 = status_err_flag_out[32*14 +: 32];
assign status_bus_b9 = status_err_flag_out[32*15 +: 32];
assign status_bus_ba = status_err_flag_out[32*16 +: 32];
assign status_bus_bb = status_err_flag_out[32*17 +: 32];
assign status_bus_bc = status_err_data_out[32*0 +: 32];
assign status_bus_bd = status_err_data_out[32*1 +: 32];
assign status_bus_be = status_err_data_out[32*2 +: 32];
assign status_bus_bf = status_err_data_out[32*3 +: 32];

assign status_bus_c0 = status_err_data_out[32*4 +: 32];
assign status_bus_c1 = status_err_data_out[32*5 +: 32];
assign status_bus_c2 = status_err_data_out[32*6 +: 32];
assign status_bus_c3 = status_err_data_out[32*7 +: 32];
assign status_bus_c4 = status_err_data_out[32*8 +: 32];
assign status_bus_c5 = status_err_data_out[32*9 +: 32];
assign status_bus_c6 = status_err_data_out[32*10 +: 32];
assign status_bus_c7 = status_err_data_out[32*11 +: 32];
assign status_bus_c8 = status_err_data_out[32*12 +: 32];
assign status_bus_c9 = status_err_data_out[32*13 +: 32];
assign status_bus_ca = status_err_data_out[32*14 +: 32];
assign status_bus_cb = status_err_data_out[32*15 +: 32];
assign status_bus_cc = status_err_data_out[32*16 +: 32];
assign status_bus_cd = status_err_data_out[32*17 +: 32];
assign status_bus_ce = status_next_err_data[32*0 +: 32];
assign status_bus_cf = status_next_err_data[32*1 +: 32];

assign status_bus_d0 = status_next_err_data[32*2 +: 32];
assign status_bus_d1 = status_next_err_data[32*3 +: 32];
assign status_bus_d2 = status_next_err_data[32*4 +: 32];
assign status_bus_d3 = status_next_err_data[32*5 +: 32];
assign status_bus_d4 = status_next_err_data[32*6 +: 32];
assign status_bus_d5 = status_next_err_data[32*7 +: 32];
assign status_bus_d6 = status_next_err_data[32*8 +: 32];
assign status_bus_d7 = status_next_err_data[32*9 +: 32];
assign status_bus_d8 = status_next_err_data[32*10 +: 32];
assign status_bus_d9 = status_next_err_data[32*11 +: 32];
assign status_bus_da = status_next_err_data[32*12 +: 32];
assign status_bus_db = status_next_err_data[32*13 +: 32];
assign status_bus_dc = status_next_err_data[32*14 +: 32];
assign status_bus_dd = status_next_err_data[32*15 +: 32];
assign status_bus_de = status_next_err_data[32*16 +: 32];
assign status_bus_df = status_next_err_data[32*17 +: 32];

assign status_bus_e0 = status_err_data_pre[32*0 +: 32];
assign status_bus_e1 = status_err_data_pre[32*1 +: 32];
assign status_bus_e2 = {16'b0,status_err_data_aft[32*2 +: 8],status_err_data_pre[32*2 +: 8]};
assign status_bus_e3 = status_err_data_aft[32*0 +: 32];
assign status_bus_e4 = status_err_data_aft[32*1 +: 32];

//control signal sync
ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH                 (1                            ),
    .DFT_VALUE                  (1'b1                         )
) u_test_start_en_sync(
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .sig_async                  (dbg_test_start_en            ),
    .sig_synced                 (dbg_test_start_en_syn        )
);

ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH                 (1                            ),
    .DFT_VALUE                  (1'b0                         )
) u_read_double_en_sync(
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .sig_async                  (read_double_en               ),
    .sig_synced                 (read_double_en_syn           )
);

ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH                 (1                            ),
    .DFT_VALUE                  (1'b0                         )
) u_random_data_en_sync(
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .sig_async                  (random_data_en               ),
    .sig_synced                 (random_data_en_syn           )
);

ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH                 (1                            ),
    .DFT_VALUE                  (1'b0                         )
) u_manu_clear_sync(
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .sig_async                  (manu_clear                   ),
    .sig_synced                 (manu_clear_syn               )
);

ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH                 (1                            ),
    .DFT_VALUE                  (1'b0                         )
) u_data_pattern_01_sync(
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .sig_async                  (data_pattern_01              ),
    .sig_synced                 (data_pattern_01_syn          )
);

//reset sync
ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH                 (1                            ),
    .DFT_VALUE                  (1'b0                         )
) u_free_clk_rst_sync (
    .clk                        (free_clk_g                   ),
    .rst_n                      (rst_board                    ),
    .sig_async                  (1'b1                         ),
    .sig_synced                 (free_clk_rst_n               )
);

ips2l_rst_sync_v1_3 #(
    .DATA_WIDTH                 (1                            ),
    .DFT_VALUE                  (1'b0                         )
) u_stress_test_sync(
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .sig_async                  (stress_test                  ),
    .sig_synced                 (stress_test_syn              )
);

ips2l_uart_ctrl_top_32bit # (
    `ifdef IPS_DDR_SPEEDUP_SIM
    .CLK_DIV_P                  (16'd18                       ),
    `else
    .CLK_DIV_P                  (16'd72                       ), //115200bps for 50MHz clk.
    `endif
    .DFT_CTRL_BUS_0             (DFT_CTRL_BUS_0               ),
    .DFT_CTRL_BUS_1             (DFT_CTRL_BUS_1               ),
    .DFT_CTRL_BUS_2             (DFT_CTRL_BUS_2               ),
    .DFT_CTRL_BUS_3             (DFT_CTRL_BUS_3               ),
    .DFT_CTRL_BUS_4             (DFT_CTRL_BUS_4               ),
    .DFT_CTRL_BUS_5             (DFT_CTRL_BUS_5               ),
    .DFT_CTRL_BUS_6             (DFT_CTRL_BUS_6               ),
    .DFT_CTRL_BUS_7             (DFT_CTRL_BUS_7               ),
    .DFT_CTRL_BUS_8             (DFT_CTRL_BUS_8               ),
    .DFT_CTRL_BUS_9             (DFT_CTRL_BUS_9               ),
    .DFT_CTRL_BUS_10            (DFT_CTRL_BUS_10              ),
    .DFT_CTRL_BUS_11            (DFT_CTRL_BUS_11              ),
    .DFT_CTRL_BUS_12            (DFT_CTRL_BUS_12              )
) u_ips2l_uart_ctrl (
    .rst_n                      (free_clk_rst_n               ),
    .clk                        (free_clk_g                   ),

    .txd                        (uart_txd                     ),
    .rxd                        (uart_rxd                     ),

    .read_req                   (uart_read_req                ),
    .read_ack                   (uart_read_ack                ),
    .uart_rd_addr               (uart_read_addr               ),

    .ctrl_bus_0                 (ctrl_bus_0                   ),
    .ctrl_bus_1                 (ctrl_bus_1                   ),
    .ctrl_bus_2                 (ctrl_bus_2                   ),
    .ctrl_bus_3                 (ctrl_bus_3                   ),
    .ctrl_bus_4                 (ctrl_bus_4                   ),
    .ctrl_bus_5                 (ctrl_bus_5                   ),
    .ctrl_bus_6                 (ctrl_bus_6                   ),
    .ctrl_bus_7                 (ctrl_bus_7                   ),
    .ctrl_bus_8                 (ctrl_bus_8                   ),
    .ctrl_bus_9                 (ctrl_bus_9                   ),
    .ctrl_bus_10                (ctrl_bus_10                  ),
    .ctrl_bus_11                (ctrl_bus_11                  ),
    .ctrl_bus_12                (ctrl_bus_12                  ),

    .status_bus                 (status_bus_lock              )
);

uart_rd_lock u_uart_rd_lock
(
    .core_clk                   (core_clk                     ),
    .core_rst_n                 (core_clk_rst_n               ),

    .uart_read_req              (uart_read_req                ),
    .uart_read_ack              (uart_read_ack                ),
    .uart_read_addr             (uart_read_addr               ),

    .status_bus_80              (status_bus_80                ),
    .status_bus_81              (status_bus_81                ),
    .status_bus_82              (status_bus_82                ),
    .status_bus_83              (status_bus_83                ),
    .status_bus_84              (status_bus_84                ),
    .status_bus_85              (status_bus_85                ),
    .status_bus_86              (status_bus_86                ),
    .status_bus_87              (status_bus_87                ),
    .status_bus_88              (status_bus_88                ),
    .status_bus_89              (status_bus_89                ),
    .status_bus_8a              (status_bus_8a                ),
    .status_bus_8b              (status_bus_8b                ),
    .status_bus_8c              (status_bus_8c                ),
    .status_bus_8d              (status_bus_8d                ),
    .status_bus_8e              (status_bus_8e                ),
    .status_bus_8f              (status_bus_8f                ),

    .status_bus_90              (status_bus_90                ),
    .status_bus_91              (status_bus_91                ),
    .status_bus_92              (status_bus_92                ),
    .status_bus_93              (status_bus_93                ),
    .status_bus_94              (status_bus_94                ),
    .status_bus_95              (status_bus_95                ),
    .status_bus_96              (status_bus_96                ),
    .status_bus_97              (status_bus_97                ),
    .status_bus_98              (status_bus_98                ),
    .status_bus_99              (status_bus_99                ),
    .status_bus_9a              (status_bus_9a                ),
    .status_bus_9b              (status_bus_9b                ),
    .status_bus_9c              (status_bus_9c                ),
    .status_bus_9d              (status_bus_9d                ),
    .status_bus_9e              (status_bus_9e                ),
    .status_bus_9f              (status_bus_9f                ),

    .status_bus_a0              (status_bus_a0                ),
    .status_bus_a1              (status_bus_a1                ),
    .status_bus_a2              (status_bus_a2                ),
    .status_bus_a3              (status_bus_a3                ),
    .status_bus_a4              (status_bus_a4                ),
    .status_bus_a5              (status_bus_a5                ),
    .status_bus_a6              (status_bus_a6                ),
    .status_bus_a7              (status_bus_a7                ),
    .status_bus_a8              (status_bus_a8                ),
    .status_bus_a9              (status_bus_a9                ),
    .status_bus_aa              (status_bus_aa                ),
    .status_bus_ab              (status_bus_ab                ),
    .status_bus_ac              (status_bus_ac                ),
    .status_bus_ad              (status_bus_ad                ),
    .status_bus_ae              (status_bus_ae                ),
    .status_bus_af              (status_bus_af                ),

    .status_bus_b0              (status_bus_b0                ),
    .status_bus_b1              (status_bus_b1                ),
    .status_bus_b2              (status_bus_b2                ),
    .status_bus_b3              (status_bus_b3                ),
    .status_bus_b4              (status_bus_b4                ),
    .status_bus_b5              (status_bus_b5                ),
    .status_bus_b6              (status_bus_b6                ),
    .status_bus_b7              (status_bus_b7                ),
    .status_bus_b8              (status_bus_b8                ),
    .status_bus_b9              (status_bus_b9                ),
    .status_bus_ba              (status_bus_ba                ),
    .status_bus_bb              (status_bus_bb                ),
    .status_bus_bc              (status_bus_bc                ),
    .status_bus_bd              (status_bus_bd                ),
    .status_bus_be              (status_bus_be                ),
    .status_bus_bf              (status_bus_bf                ),

    .status_bus_c0              (status_bus_c0                ),
    .status_bus_c1              (status_bus_c1                ),
    .status_bus_c2              (status_bus_c2                ),
    .status_bus_c3              (status_bus_c3                ),
    .status_bus_c4              (status_bus_c4                ),
    .status_bus_c5              (status_bus_c5                ),
    .status_bus_c6              (status_bus_c6                ),
    .status_bus_c7              (status_bus_c7                ),
    .status_bus_c8              (status_bus_c8                ),
    .status_bus_c9              (status_bus_c9                ),
    .status_bus_ca              (status_bus_ca                ),
    .status_bus_cb              (status_bus_cb                ),
    .status_bus_cc              (status_bus_cc                ),
    .status_bus_cd              (status_bus_cd                ),
    .status_bus_ce              (status_bus_ce                ),
    .status_bus_cf              (status_bus_cf                ),

    .status_bus_d0              (status_bus_d0                ),
    .status_bus_d1              (status_bus_d1                ),
    .status_bus_d2              (status_bus_d2                ),
    .status_bus_d3              (status_bus_d3                ),
    .status_bus_d4              (status_bus_d4                ),
    .status_bus_d5              (status_bus_d5                ),
    .status_bus_d6              (status_bus_d6                ),
    .status_bus_d7              (status_bus_d7                ),
    .status_bus_d8              (status_bus_d8                ),
    .status_bus_d9              (status_bus_d9                ),
    .status_bus_da              (status_bus_da                ),
    .status_bus_db              (status_bus_db                ),
    .status_bus_dc              (status_bus_dc                ),
    .status_bus_dd              (status_bus_dd                ),
    .status_bus_de              (status_bus_de                ),
    .status_bus_df              (status_bus_df                ),

    .status_bus_e0              (status_bus_e0                ),
    .status_bus_e1              (status_bus_e1                ),
    .status_bus_e2              (status_bus_e2                ),
    .status_bus_e3              (status_bus_e3                ),
    .status_bus_e4              (status_bus_e4                ),

    .status_bus_lock            (status_bus_lock              )
);

//***********************************************************************************

assign resetn = dbg_ddr_rst_n & rst_board;

ips2l_rst_sync_v1_3 u_core_clk_rst_sync(
    .clk                        (core_clk                     ),
    .rst_n                      (resetn                       ),
    .sig_async                  (~dbg_gate_start              ),
    .sig_synced                 (core_clk_rst_n               )
);

//***********************************************************************************

`ifdef IPS_DDR_SPEEDUP_SIM
parameter MEM_SPACE_AW = 18; //to reduce simulation time
`else
parameter MEM_SPACE_AW = CTRL_ADDR_WIDTH;
`endif

//***********************************************************************************
always@(posedge core_clk or negedge core_clk_rst_n)
begin
   if (!core_clk_rst_n)
      cnt <= 27'd0;
   else if ( cnt >= TH_1S )
      cnt <= 27'd0;
   else
      cnt <= cnt + 27'd1;
end

always @(posedge core_clk or negedge core_clk_rst_n)
begin
   if (!core_clk_rst_n)
      heart_beat_led <= 1'd1;
   else if ( cnt >= TH_1S )
      heart_beat_led <= ~heart_beat_led;
end
ddr3_test #(
    .MEM_ROW_WIDTH              (MEM_ROW_WIDTH                ),
    .MEM_COLUMN_WIDTH           (MEM_COLUMN_WIDTH             ),
    .MEM_BANK_WIDTH             (MEM_BANK_WIDTH               ),
    .MEM_DQ_WIDTH               (MEM_DQ_WIDTH                 ),
    .MEM_DM_WIDTH               (MEM_DQS_WIDTH                ),
    .MEM_DQS_WIDTH              (MEM_DQS_WIDTH                ),
    .CTRL_ADDR_WIDTH            (CTRL_ADDR_WIDTH              )
  )I_ips_ddr_top(
    .ref_clk                    (ref_clk                      ),
    .resetn                     (resetn                       ),
    .core_clk                   (core_clk                     ),
    .pll_lock                   (pll_lock                     ),
    .phy_pll_lock               (phy_pll_lock                 ),
    .gpll_lock                  (gpll_lock                    ),
    .rst_gpll_lock              (rst_gpll_lock                ),
    .ddrphy_cpd_lock            (ddrphy_cpd_lock              ),
    .ddr_init_done              (ddr_init_done                ),

    .axi_awaddr                 (axi_awaddr                   ),
    .axi_awuser_ap              (axi_awuser_ap                ),
    .axi_awuser_id              (axi_awuser_id                ),
    .axi_awlen                  (axi_awlen                    ),
    .axi_awready                (axi_awready                  ),
    .axi_awvalid                (axi_awvalid                  ),

    .axi_wdata                  (axi_wdata                    ),
    .axi_wstrb                  (axi_wstrb                    ),
    .axi_wready                 (axi_wready                   ),
    .axi_wusero_id              (axi_wusero_id                ),
    .axi_wusero_last            (axi_wusero_last              ),

    .axi_araddr                 (axi_araddr                   ),
    .axi_aruser_ap              (axi_aruser_ap                ),
    .axi_aruser_id              (axi_aruser_id                ),
    .axi_arlen                  (axi_arlen                    ),
    .axi_arready                (axi_arready                  ),
    .axi_arvalid                (axi_arvalid                  ),

    .axi_rdata                  (axi_rdata                    ),
    .axi_rid                    (axi_rid                      ),
    .axi_rlast                  (axi_rlast                    ),
    .axi_rvalid                 (axi_rvalid                   ),

    .apb_clk                    (1'b0                         ),
    .apb_rst_n                  (1'b0                         ),
    .apb_sel                    (1'b0                         ),
    .apb_enable                 (1'b0                         ),
    .apb_addr                   (8'd0                         ),
    .apb_write                  (1'b0                         ),
    .apb_ready                  (                             ),
    .apb_wdata                  (16'd0                        ),
    .apb_rdata                  (                             ),


    .mem_cs_n                   (mem_cs_n                     ),

    .mem_rst_n                  (mem_rst_n                    ),
    .mem_ck                     (mem_ck                       ),
    .mem_ck_n                   (mem_ck_n                     ),
    .mem_cke                    (mem_cke                      ),
    .mem_ras_n                  (mem_ras_n                    ),
    .mem_cas_n                  (mem_cas_n                    ),
    .mem_we_n                   (mem_we_n                     ),
    .mem_odt                    (mem_odt                      ),
    .mem_a                      (mem_a                        ),
    .mem_ba                     (mem_ba                       ),
    .mem_dqs                    (mem_dqs                      ),
    .mem_dqs_n                  (mem_dqs_n                    ),
    .mem_dq                     (mem_dq                       ),
    .mem_dm                     (mem_dm                       ),

    //debug
    .dbg_gate_start             (dbg_gate_start               ),
    .dbg_cpd_start              (dbg_cpd_start                ),
    .dbg_ddrphy_rst_n           (dbg_ddrphy_rst_n             ),
    .dbg_gpll_scan_rst          (dbg_gpll_scan_rst            ),

    .samp_position_dyn_adj      (samp_position_dyn_adj        ),
    .init_samp_position_even    (init_samp_position_even[8*MEM_DQS_WIDTH -1:0]),
    .init_samp_position_odd     (init_samp_position_odd[8*MEM_DQS_WIDTH -1:0] ),

    .wrcal_position_dyn_adj     (wrcal_position_dyn_adj       ),
    .init_wrcal_position        (init_wrcal_position[8*MEM_DQS_WIDTH -1:0]    ),

    .force_read_clk_ctrl        (force_read_clk_ctrl          ),
    .init_slip_step             (init_slip_step[4*MEM_DQS_WIDTH-1:0]          ),
    .init_read_clk_ctrl         (init_read_clk_ctrl[3*MEM_DQS_WIDTH-1:0]      ),

    .debug_calib_ctrl           (debug_calib_ctrl             ),
    .dbg_dll_upd_state          (dbg_dll_upd_state            ),
    .dbg_slice_status           (dbg_slice_status             ),
    .dbg_slice_state            (dbg_slice_state              ),
    .debug_data                 (debug_data                   ),
    .debug_gpll_dps_phase       (debug_gpll_dps_phase         ),

    .dbg_rst_dps_state          (dbg_rst_dps_state            ),
    .dbg_tran_err_rst_cnt       (dbg_tran_err_rst_cnt         ),
    .dbg_ddrphy_init_fail       (dbg_ddrphy_init_fail         ),

    .debug_cpd_offset_adj       (debug_cpd_offset_adj         ),
    .debug_cpd_offset_dir       (debug_cpd_offset_dir         ),
    .debug_cpd_offset           (debug_cpd_offset             ),
    .debug_dps_cnt_dir0         (debug_dps_cnt_dir0           ),
    .debug_dps_cnt_dir1         (debug_dps_cnt_dir1           ),

    .force_ck_dly_en            (force_ck_dly_en              ),
    .force_ck_dly_set_bin       (force_ck_dly_set_bin         ),
    .ck_dly_set_bin             (ck_dly_set_bin               ),

    .align_error                (align_error                  ),
    .debug_rst_state            (debug_rst_state              ),
    .debug_cpd_state            (debug_cpd_state              )

  );

//***********************************************************************************
test_main_ctrl #(
    .CTRL_ADDR_WIDTH            (CTRL_ADDR_WIDTH              ),
    .MEM_DQ_WIDTH               (MEM_DQ_WIDTH                 ),
    .MEM_SPACE_AW               (MEM_SPACE_AW                 )
) u_test_main_ctrl (
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .ddrc_init_done             (ddr_init_done                ),
    .init_start                 (init_start                   ),
    .init_done                  (init_done                    ),
    .write_en                   (write_en                     ),
    .write_done_p               (write_done_p                 ),
    .read_en                    (read_en                      ),
    .read_done_p                (read_done_p                  ),
    .wr_data_chg                (wr_data_chg                  ),
    .rd_data_chg                (rd_data_chg                  ),
    .dbg_test_start_en          (dbg_test_start_en_syn        ),
    .state                      (test_main_state              ),
    .stress_test                (stress_test_syn              ),
    .stress_test_valid          (stress_test_valid            ),
    .rd_cnt                     (rd_cnt                       )   
);

test_wr_ctrl #(
    .CTRL_ADDR_WIDTH            (CTRL_ADDR_WIDTH              ),
    .MEM_DQ_WIDTH               (MEM_DQ_WIDTH                 ),
    .MEM_COL_ADDR_WIDTH         (MEM_COLUMN_WIDTH             ),
    .MEM_SPACE_AW               (MEM_SPACE_AW                 )
) u_test_wr_ctrl (
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .init_start                 (init_start                   ),
    .write_en                   (write_en                     ),
    .write_done_p               (write_done_p                 ),
    .init_done                  (init_done                    ),
    .data_pattern_01            (data_pattern_01_syn          ),
    .random_data_en             (random_data_en_syn           ),
    .axi_awaddr                 (axi_awaddr                   ),
    .axi_awuser_ap              (axi_awuser_ap                ),
    .axi_awuser_id              (axi_awuser_id                ),
    .axi_awlen                  (axi_awlen                    ),
    .axi_awready                (axi_awready                  ),
    .axi_awvalid                (axi_awvalid                  ),
    .axi_wdata                  (axi_wdata                    ),
    .axi_wstrb                  (axi_wstrb                    ),
    .axi_wready                 (axi_wready                   ),
    .state                      (test_wr_state                ),
    .wr_data_chg                (wr_data_chg                  ), 
    .stress_test                (stress_test_valid            ) 
);


test_rd_ctrl #(
    .CTRL_ADDR_WIDTH            (CTRL_ADDR_WIDTH              ),
    .MEM_DQ_WIDTH               (MEM_DQ_WIDTH                 ),
    .MEM_SPACE_AW               (MEM_SPACE_AW                 )
)u_test_rd_ctrl(
    .clk                        (core_clk                     ),
    .rst_n                      (core_clk_rst_n               ),
    .read_en                    (read_en                      ),
    .data_pattern_01            (data_pattern_01_syn          ),
    .read_double_en             (read_double_en_syn           ),
    .read_done_p                (read_done_p                  ),
    .axi_araddr                 (axi_araddr                   ),
    .axi_aruser_ap              (axi_aruser_ap                ),
    .axi_aruser_id              (axi_aruser_id                ),
    .axi_arlen                  (axi_arlen                    ),
    .axi_arready                (axi_arready                  ),
    .axi_arvalid                (axi_arvalid                  ),

    .axi_rdata                  (axi_rdata                    ),
    .axi_rvalid                 (axi_rvalid                   ),
    .err_cnt                    (err_cnt                      ),
    .err_flag_led               (err_flag_led                 ),
    .err_data_out               (err_data_out                 ),
    .err_flag_out               (err_flag_out                 ),
    .rd_cnt_out                 (err_rd_cnt_out               ),
    .manu_clear                 (manu_clear_syn               ),
    .err_lock                   (err_lock                     ),
    .state                      (test_rd_state                ),
    .rd_data_chg                (rd_data_chg                  ),   
    .stress_test                (stress_test_valid            ),
    .rd_cnt                     (rd_cnt                       ),
    .rd_dir_err                 (rd_dir_err                   ),
    .read_cmd_cnt               (read_cmd_cnt                 ),
    .next_err_data              (next_err_data                ),
    .err_data_pre               (err_data_pre                 ),
    .err_data_aft               (err_data_aft                 ),
    .burst_cnt                  (burst_cnt                    )        
);

adc_ctrl u_adc_ctrl(
    .clk                        (free_clk_g                   ),
    .rst_n                      (free_clk_rst_n               ),
    .dbg_temp_rd                (dbg_temp_rd                  ),
    .dbg_volt_rd                (dbg_volt_rd                  ),
    .pdata                      (adc_rdata                    )
);

endmodule
