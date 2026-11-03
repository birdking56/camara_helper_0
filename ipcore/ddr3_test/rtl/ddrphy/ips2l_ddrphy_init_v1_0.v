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
module  ips2l_ddrphy_init_v1_0 #(
  parameter [1:0]   DDR_TYPE      = 2'b00    ,    //2'b00:DDR3  2'b01:DDR2  2'b10:LPDDR
  parameter [19:0]  T200US        = 20'd20000,
  parameter [19:0]  T500US        = 20'd50000,
  parameter [7:0]   T400NS        = 8'd40    ,
  parameter [7:0]   TMRD          = 8'd1     ,
  parameter [7:0]   TMOD          = 8'd3     ,
  parameter [7:0]   TXPR          = 8'd17    , 
  parameter [7:0]   TRP           = 8'd2     ,
  parameter [7:0]   TRFC          = 8'd16    ,
  parameter [9:0]   TZQINIT       = 10'd128  ,
  parameter [3:0]   REF_CNT       = 4'd9     ,
  parameter MEM_ADDR_WIDTH        = 16       ,
  parameter MEM_BANKADDR_WIDTH    = 3    
)(
  input             ddrphy_sysclk,
  input             ddrphy_rst_n ,

  input             init_start   ,
  output reg        init_done    ,

  input [15:0]      mr0          ,
  input [15:0]      mr1          ,
  input [15:0]      mr2          ,
  input [15:0]      mr3          ,
  output [3:0]      dbg_init     ,
  
  output reg        init_rst     ,
  output reg [MEM_BANKADDR_WIDTH-1:0]  init_ba      ,
  output reg [MEM_ADDR_WIDTH-1:0]      init_address ,
  output reg        init_cs_n    ,
  output reg        init_ras_n   ,
  output reg        init_cas_n   ,
  output reg        init_we_n    ,
  output reg        init_cke     ,
  output            init_odt
 );

  localparam  INIT_IDLE         = 4'h0;
  localparam  INIT_WAIT_RESET   = 4'h1;
  localparam  INIT_WAIT_CKE     = 4'h2;
  localparam  INIT_WAIT_TXPR    = 4'h3;
  localparam  INIT_LOAD_MR      = 4'h4;
  localparam  INIT_WAIT_TMRD    = 4'h5;
  localparam  INIT_WAIT_TMOD    = 4'h6;
  localparam  INIT_ZQCL         = 4'h7;
  localparam  INIT_WAIT_TZQINIT = 4'h8;
  localparam  INIT_DONE         = 4'h9;
  localparam  INIT_PREA         = 4'ha; 
  localparam  INIT_PREA_WAIT    = 4'hb;
  localparam  INIT_ARF          = 4'hc;
  localparam  INIT_WAIT_ARF     = 4'hd;
  localparam  INIT_LOAD_MR_DDR2 = 4'he;
  localparam  INIT_MR_DDR2_WAIT = 4'hf;
  
  localparam  LOAD_MR2     = 2'b00;
  localparam  LOAD_MR3     = 2'b01;
  localparam  LOAD_MR1     = 2'b10;
  localparam  LOAD_MR0     = 2'b11;
  localparam  LOAD_DONE    = 2'b11;
  localparam  LOAD_LP_DONE = 2'b01;
 

  reg [3:0]  init_state      ;
  reg [3:0]  init_next_state ;

  reg [19:0] cnt_t200us;
  reg [19:0] cnt_t500us;
  reg [7:0]  cnt_cmd   ;
  reg        cnt_cke_pass;
  reg        cnt_pwron_pass;
  reg        cnt_txpr_pass;
  reg        cnt_prea_pass;
  reg        cnt_arf_pass;
  reg [3:0]  arf_cnt     ;
  reg        arf_done    ;  
  reg        ocd_cal_done;
  reg [1:0]  ocd_cal_cnt ;  
  reg        cnt_tmrd_pass;
  reg        cnt_tmod_pass;
  reg        mr_load_done;
  reg [1:0]  mr_load_cnt;
  reg        cnt_tzqinit_pass;
  reg [9:0]  cnt_tzqinit ;
  wire [7:0] txpr;

  assign  txpr = (DDR_TYPE==2'b00) ? TXPR : T400NS;

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
         cnt_t200us      <= 20'h0 ;
      else if(init_start)
         cnt_t200us      <= cnt_t200us + 20'h1;
      else
        cnt_t200us      <= 20'h0 ;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
         cnt_pwron_pass  <= 1'b0 ;
      else if((init_state == INIT_IDLE) & init_start)
         cnt_pwron_pass  <= 1'b0 ;
      else if(!cnt_pwron_pass)
         cnt_pwron_pass  <= (cnt_t200us == T200US);
  end


  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n) 
  begin
    if(!ddrphy_rst_n)                             
       cnt_t500us <= 20'h0;
    else if(init_state == INIT_IDLE) 
       cnt_t500us <= 20'h0;
    else if(init_next_state == INIT_WAIT_CKE)
       cnt_t500us      <= cnt_t500us + 20'h1 ;
  end
  
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
    if(!ddrphy_rst_n)                                 
        cnt_cke_pass  <= 1'b0;
    else if((init_state == INIT_IDLE) & init_start)
        cnt_cke_pass  <= 1'b0; 
    else if(!cnt_cke_pass)
    begin
        if(|DDR_TYPE)
        cnt_cke_pass <= (cnt_t500us == T200US);
        else
        cnt_cke_pass <= (cnt_t500us == T500US);
    end
  end
    
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
         cnt_cmd       <= 8'h0;
      else
        case(init_next_state)                      
           INIT_PREA_WAIT,                 
           INIT_WAIT_ARF ,       
           INIT_WAIT_TXPR,
           INIT_WAIT_TMRD,
        INIT_MR_DDR2_WAIT,
           INIT_WAIT_TMOD:
                           cnt_cmd <= cnt_cmd +8'h1;

                 default:  cnt_cmd <= 8'h0;
        endcase
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
         cnt_txpr_pass  <= 1'b0;
      else
         cnt_txpr_pass  <= (cnt_cmd == txpr);
  end

 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
      if(!ddrphy_rst_n)                                 
         cnt_prea_pass  <= 1'b0;                        
      else                                              
         cnt_prea_pass  <= (cnt_cmd == TRP);
 end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)                                 
         cnt_arf_pass  <= 1'b0;                         
      else                                              
         cnt_arf_pass  <= (cnt_cmd == TRFC);
  end
         
 always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
 begin
      if(!ddrphy_rst_n) begin                           
         arf_cnt    <= 4'b0;                            
         arf_done   <= 1'b0;                            
      end                                               
      else if(init_state == INIT_ARF )begin             
         arf_cnt    <= arf_cnt + 4'b1;                  
         arf_done   <= (arf_cnt == REF_CNT - 4'b1);
      end 
 end        

                                                                                                                               
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)                                   
         cnt_tmrd_pass  <= 1'b0;                          
      else                                                
         cnt_tmrd_pass  <= (cnt_cmd == TMRD);
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
         cnt_tmod_pass  <= 1'b0;
      else
         cnt_tmod_pass  <= (cnt_cmd == TMOD);
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n) begin
         mr_load_done   <= 1'b0;
         mr_load_cnt    <= 2'b0;
      end
      else if(init_next_state == INIT_IDLE) begin
         mr_load_done   <= 1'b0;
         mr_load_cnt    <= 2'b0;
      end
      else if(init_next_state == INIT_LOAD_MR)begin
        mr_load_cnt     <= mr_load_cnt + 2'b1;
        if(~DDR_TYPE[1])  
           mr_load_done    <= (mr_load_cnt == LOAD_DONE);
        else
           mr_load_done    <= (mr_load_cnt == LOAD_LP_DONE);
      end
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n) begin
         ocd_cal_cnt   <= 2'b0;
         ocd_cal_done  <= 1'b0;
      end
      else if(init_state == INIT_IDLE)begin
         ocd_cal_cnt   <= 2'b0;
         ocd_cal_done  <= 1'b0;
     end
     else if(init_next_state == INIT_LOAD_MR_DDR2)begin
         ocd_cal_cnt   <= ocd_cal_cnt + 2'b01;
         ocd_cal_done  <= (ocd_cal_cnt[1]);
     end
  end

   always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
   begin
       if(!ddrphy_rst_n)  begin
          cnt_tzqinit        <= 10'h0;
          cnt_tzqinit_pass   <= 1'b0;
       end
       else if (init_next_state == INIT_WAIT_TZQINIT) begin
          cnt_tzqinit       <= cnt_tzqinit + 10'h1;
          cnt_tzqinit_pass  <= (cnt_tzqinit == TZQINIT);
      end
      else  begin
          cnt_tzqinit        <= 10'h0;
          cnt_tzqinit_pass   <= 1'b0;
      end
   end


  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
        init_state  <= INIT_IDLE ;
      else
        init_state  <= init_next_state ;
  end

generate
if (DDR_TYPE == 2'b00) begin    //DDR3
  always @(*) begin
      init_next_state = INIT_IDLE ;
    case(init_state)
         INIT_IDLE  :     if(init_start) 
                              init_next_state = INIT_WAIT_RESET;
                          else
                              init_next_state = INIT_IDLE;

         INIT_WAIT_RESET : if(cnt_pwron_pass)                    //ddr3 delay 200us    
                              init_next_state = INIT_WAIT_CKE;
                           else
                              init_next_state = INIT_WAIT_RESET;

         INIT_WAIT_CKE : begin
                           if(cnt_cke_pass)               //ddr3 delay 500us
                              init_next_state = INIT_WAIT_TXPR;
                           else
                              init_next_state = INIT_WAIT_CKE;
                         end

         INIT_WAIT_TXPR: begin                                   //ddr3
                           if(cnt_txpr_pass)                 //delay txpr        
                              init_next_state = INIT_LOAD_MR;
                           else
                              init_next_state = INIT_WAIT_TXPR;
                         end
                         
         INIT_LOAD_MR :  init_next_state  =  INIT_WAIT_TMRD;     //mr_load_cnt + 1

         INIT_WAIT_TMRD : if(mr_load_done)                       //mr_load_done = 1
                             init_next_state = INIT_WAIT_TMOD;
                          else if(cnt_tmrd_pass)                 //delay tmrd
                             init_next_state = INIT_LOAD_MR;
                          else
                             init_next_state = INIT_WAIT_TMRD;

         INIT_WAIT_TMOD: begin      
                           if(cnt_tmod_pass)              //delay tmod                                                                                                                                  
                             init_next_state = INIT_ZQCL ;
                           else
                             init_next_state = INIT_WAIT_TMOD;
                         end

         INIT_ZQCL :      init_next_state = INIT_WAIT_TZQINIT ;  //ddr3

         INIT_WAIT_TZQINIT : if(cnt_tzqinit_pass)                //delay tzqinit
                                init_next_state = INIT_DONE;
                             else
                                init_next_state = INIT_WAIT_TZQINIT;   
                                                                                                                                                                                                    
         INIT_DONE         :  init_next_state = INIT_IDLE ;
         
         default: init_next_state = INIT_IDLE ;

     endcase
  end
end

else if(DDR_TYPE == 2'b01) begin    //DDR2
  always @(*) begin
      init_next_state = INIT_IDLE ;
    case(init_state)
         INIT_IDLE  :     if(init_start)
                             init_next_state = INIT_WAIT_CKE;
                          else
                             init_next_state = INIT_IDLE;

         INIT_WAIT_CKE : begin
                           if(cnt_cke_pass)
                              init_next_state = INIT_WAIT_TXPR;
                           else
                              init_next_state = INIT_WAIT_CKE;
                         end

         INIT_WAIT_TXPR: begin
                           if(cnt_txpr_pass) 
                              init_next_state = INIT_PREA ;
                           else
                              init_next_state = INIT_WAIT_TXPR;
                         end
                         
             INIT_PREA:   init_next_state = INIT_PREA_WAIT;           
                         
         INIT_PREA_WAIT : begin
                            if(cnt_prea_pass)begin    
                               if(mr_load_done) 
                                  init_next_state = INIT_ARF;                 
                               else        
                                  init_next_state = INIT_LOAD_MR; 
                            end
                          else
                            init_next_state = INIT_PREA_WAIT ;
                          end
                       
        INIT_ARF     :  init_next_state = INIT_WAIT_ARF;  
        
        INIT_WAIT_ARF: begin 
                          if(cnt_arf_pass)begin
                             if(arf_done)
                               init_next_state = INIT_LOAD_MR_DDR2;
                             else
                               init_next_state = INIT_ARF;
                          end
                          else
                            init_next_state = INIT_WAIT_ARF;
                       end
                        
         INIT_LOAD_MR :  init_next_state  =  INIT_WAIT_TMRD;

         INIT_WAIT_TMRD : if(mr_load_done)
                             init_next_state = INIT_WAIT_TMOD;
                          else if(cnt_tmrd_pass)
                             init_next_state = INIT_LOAD_MR;
                          else
                             init_next_state = INIT_WAIT_TMRD;

         INIT_WAIT_TMOD: begin      
                           if(cnt_tmod_pass)
                             init_next_state = INIT_PREA;
                           else
                             init_next_state = INIT_WAIT_TMOD;
                         end
                                
         INIT_LOAD_MR_DDR2 :  init_next_state = INIT_MR_DDR2_WAIT ;

         INIT_MR_DDR2_WAIT : if(cnt_tmrd_pass) 
                                if(ocd_cal_done)
                                   init_next_state = INIT_DONE ;
                                else
                                   init_next_state = INIT_LOAD_MR_DDR2;
                             else
                                init_next_state = INIT_MR_DDR2_WAIT;
                                                                                                                                                                        
         INIT_DONE         :  init_next_state = INIT_IDLE ;
         
         default: init_next_state = INIT_IDLE ;

    endcase
  end    
end

else if(DDR_TYPE == 2'b10) begin    //LPDDR
  always @(*) begin
      init_next_state = INIT_IDLE ;
    case(init_state)
         INIT_IDLE  :     if(init_start)
                              init_next_state = INIT_WAIT_CKE;
                          else
                              init_next_state = INIT_IDLE;
         INIT_WAIT_CKE : begin
                           if(cnt_cke_pass)
                              init_next_state = INIT_PREA; 
                           else
                              init_next_state = INIT_WAIT_CKE;
                         end
                         
             INIT_PREA:   init_next_state = INIT_PREA_WAIT;           
                         
         INIT_PREA_WAIT : begin
                            if(cnt_prea_pass)begin    
//                               if(mr_load_done) 
                                  init_next_state = INIT_ARF;                  
//                               else
//                                  init_next_state = INIT_ARF;
                            end
                          else
                            init_next_state = INIT_PREA_WAIT ;
                          end
                       
        INIT_ARF     :  init_next_state = INIT_WAIT_ARF;  
        
        INIT_WAIT_ARF: begin 
                          if(cnt_arf_pass)begin
                             if(arf_done)
                               init_next_state = INIT_LOAD_MR;
                             else
                               init_next_state = INIT_ARF;
                          end
                          else
                            init_next_state = INIT_WAIT_ARF;
                        end
                        
         INIT_LOAD_MR :  init_next_state  =  INIT_WAIT_TMRD;

         INIT_WAIT_TMRD : if(mr_load_done)
                             init_next_state = INIT_WAIT_TMOD;
                          else if(cnt_tmrd_pass)
                             init_next_state = INIT_LOAD_MR;
                          else
                             init_next_state = INIT_WAIT_TMRD;

         INIT_WAIT_TMOD: begin      
                           if(cnt_tmod_pass)
                              init_next_state = INIT_DONE;
                           else
                             init_next_state = INIT_WAIT_TMOD;
                         end
                                                                                                                                                                        
         INIT_DONE         :  init_next_state = INIT_IDLE ;

     endcase
  end
end
endgenerate


  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
        init_done  <= 1'b0;
      else
        init_done  <= (init_next_state == INIT_DONE);
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
          init_rst  <= 1'b0;
      else
          init_rst  <= cnt_pwron_pass ;
  end

  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n)
      begin
        if(DDR_TYPE == 2'b10)
        init_cke  <= 1'b1;
        else
        init_cke  <= 1'b0;
      end
      else if(DDR_TYPE == 2'b10)   //LPDDR
           init_cke  <= 1'b1;
      else
           init_cke  <=  cnt_cke_pass;
  end

  assign init_odt = 1'b0;

generate
if (DDR_TYPE == 2'b00) begin    //DDR3
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n) begin
          init_ba       <= {MEM_BANKADDR_WIDTH{1'b0}};
          init_address  <= {MEM_ADDR_WIDTH{1'b0}};
          init_cs_n     <= 1'b1;
          init_ras_n    <= 1'b0;
          init_cas_n    <= 1'b0;
          init_we_n     <= 1'b0;
      end
      else  begin
        case(init_next_state)    
                                 
              INIT_LOAD_MR: begin                                                       //write MR
                                init_cs_n     <= 1'b0;
                                init_ras_n    <= 1'b0;
                                init_cas_n    <= 1'b0;
                                init_we_n     <= 1'b0;
                              case(mr_load_cnt)
                                  LOAD_MR2: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b10};
                                              init_address    <= mr2[MEM_ADDR_WIDTH-1:0];
                                            end

                                  LOAD_MR3: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b11};
                                              init_address    <= mr3[MEM_ADDR_WIDTH-1:0];
                                           end

                                  LOAD_MR1: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b01};
                                              init_address    <= mr1[MEM_ADDR_WIDTH-1:0];
                                            end

                                  LOAD_MR0: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b00};
                                              init_address    <= mr0[MEM_ADDR_WIDTH-1:0];
                                            end
                              endcase
                         end

                INIT_ZQCL :  begin                                                  //ZQ Calibration Long
                                init_cs_n        <= 1'b0;
                                init_ras_n       <= 1'b1;
                                init_cas_n       <= 1'b1;
                                init_we_n        <= 1'b0;
                                init_ba          <= {MEM_BANKADDR_WIDTH{1'b0}};
                                init_address     <= {{(MEM_ADDR_WIDTH-11){1'b0}},1'b1,10'h0};
                             end
                                                                                                                                                                                             
                default  :   begin
                                init_ba       <= {MEM_BANKADDR_WIDTH{1'b0}};
                                init_address  <= {MEM_ADDR_WIDTH{1'b0}};
                                init_cs_n     <= 1'b1;
                                init_ras_n    <= 1'b1;
                                init_cas_n    <= 1'b1;
                                init_we_n     <= 1'b1;
                             end
           endcase
        end
  end
end

else if(DDR_TYPE == 2'b01) begin    //DDR2
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n) begin
          init_ba       <= {MEM_BANKADDR_WIDTH{1'b0}};
          init_address  <= {MEM_ADDR_WIDTH{1'b0}};
          init_cs_n     <= 1'b1;
          init_ras_n    <= 1'b0;
          init_cas_n    <= 1'b0;
          init_we_n     <= 1'b0;
      end
      else  begin
        case(init_next_state)    
                INIT_PREA : begin
                              init_cs_n        <= 1'b0;   
                              init_ras_n       <= 1'b0;  
                              init_cas_n       <= 1'b1;  
                              init_we_n        <= 1'b0; 
                              init_ba          <= {MEM_BANKADDR_WIDTH{1'b0}};
                              init_address     <= {{(MEM_ADDR_WIDTH-11){1'b0}},1'b1,10'h0};
                            end   
                INIT_ARF  : begin
                               init_cs_n        <= 1'b0;                
                               init_ras_n       <= 1'b0;    
                               init_cas_n       <= 1'b0;    
                               init_we_n        <= 1'b1; 
                               init_ba          <= {MEM_BANKADDR_WIDTH{1'b0}};
                               init_address     <= {MEM_ADDR_WIDTH{1'b0}};
                            end                                                          
              INIT_LOAD_MR: begin                                                       //write MR
                                init_cs_n     <= 1'b0;
                                init_ras_n    <= 1'b0;
                                init_cas_n    <= 1'b0;
                                init_we_n     <= 1'b0;
                              case(mr_load_cnt)
                                  LOAD_MR2: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b10};
                                              init_address    <= mr2[MEM_ADDR_WIDTH-1:0];
                                            end

                                  LOAD_MR3: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b11};
                                              init_address    <= mr3[MEM_ADDR_WIDTH-1:0];
                                           end

                                  LOAD_MR1: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b01};
                                              init_address    <= mr1[MEM_ADDR_WIDTH-1:0];
                                            end

                                  LOAD_MR0: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b00};
                                              init_address    <= mr0[MEM_ADDR_WIDTH-1:0];
                                            end
                              endcase
                         end
         INIT_LOAD_MR_DDR2 : begin
                               init_cs_n       <= 1'b0; 
                               init_ras_n      <= 1'b0; 
                               init_cas_n      <= 1'b0; 
                               init_we_n       <= 1'b0;
                               case(ocd_cal_cnt)
                                    2'b00 :  begin
                                               init_ba[1:0]    <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b00};   
                                               init_address    <= {mr0[MEM_ADDR_WIDTH-1:9],1'b0,mr0[7:0]};   
                                             end
                                     
                                    2'b01 : begin
                                               init_ba[1:0]    <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b01}; 
                                               init_address    <= {mr1[MEM_ADDR_WIDTH-1:10],3'b111,mr1[6:0]}; 
                                            end
                                     
                                    2'b10 : begin
                                               init_ba[1:0]    <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b01}; 
                                               init_address    <= {mr1[MEM_ADDR_WIDTH-1:10],3'b000,mr1[6:0]};
                                            end 
                               endcase
                             end                         
                                                                                                                                                                                             
                default  :   begin
                                init_ba       <= {MEM_BANKADDR_WIDTH{1'b0}};
                                init_address  <= {MEM_ADDR_WIDTH{1'b0}};
                                init_cs_n     <= 1'b1;
                                init_ras_n    <= 1'b1;
                                init_cas_n    <= 1'b1;
                                init_we_n     <= 1'b1;
                             end
           endcase
        end
  end    
end

else if(DDR_TYPE == 2'b10) begin    //LPDDR
  always @(posedge ddrphy_sysclk or negedge ddrphy_rst_n)
  begin
      if(!ddrphy_rst_n) begin
          init_ba       <= {MEM_BANKADDR_WIDTH{1'b0}};
          init_address  <= {MEM_ADDR_WIDTH{1'b0}};
          init_cs_n     <= 1'b1;
          init_ras_n    <= 1'b0;
          init_cas_n    <= 1'b0;
          init_we_n     <= 1'b0;
      end
      else  begin
        case(init_next_state)    
                INIT_PREA : begin
                              init_cs_n        <= 1'b0;   
                              init_ras_n       <= 1'b0;  
                              init_cas_n       <= 1'b1;  
                              init_we_n        <= 1'b0; 
                              init_ba          <= {MEM_BANKADDR_WIDTH{1'b0}};
                              init_address     <= {{(MEM_ADDR_WIDTH-11){1'b0}},1'b1,10'h0};
                            end   
                INIT_ARF  : begin
                               init_cs_n        <= 1'b0;                
                               init_ras_n       <= 1'b0;    
                               init_cas_n       <= 1'b0;    
                               init_we_n        <= 1'b1; 
                               init_ba          <= {MEM_BANKADDR_WIDTH{1'b0}};
                               init_address     <= {MEM_ADDR_WIDTH{1'b0}};
                            end                                                          
              INIT_LOAD_MR: begin                                                       //write MR
                                init_cs_n     <= 1'b0;
                                init_ras_n    <= 1'b0;
                                init_cas_n    <= 1'b0;
                                init_we_n     <= 1'b0;
                              case(mr_load_cnt)
                                  LOAD_MR2: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b00};
                                              init_address    <= mr0[MEM_ADDR_WIDTH-1:0];
                                            end

                                  LOAD_MR3: begin
                                              init_ba         <= {{(MEM_BANKADDR_WIDTH-2){1'b0}},2'b10};
                                              init_address    <= mr2[MEM_ADDR_WIDTH-1:0];
                                           end
                              endcase
                         end
                                                                                                                                                                                             
                default  :   begin
                                init_ba       <= {MEM_BANKADDR_WIDTH{1'b0}};
                                init_address  <= {MEM_ADDR_WIDTH{1'b0}};
                                init_cs_n     <= 1'b1;
                                init_ras_n    <= 1'b1;
                                init_cas_n    <= 1'b1;
                                init_we_n     <= 1'b1;
                             end
           endcase
        end
  end    
end
endgenerate
        
 assign  dbg_init = init_state;

endmodule


