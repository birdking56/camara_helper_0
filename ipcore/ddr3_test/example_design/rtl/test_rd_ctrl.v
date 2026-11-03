`timescale 1ns/1ps


module test_rd_ctrl #(
   parameter CTRL_ADDR_WIDTH = 28,
   parameter MEM_DQ_WIDTH = 16,
   parameter MEM_COL_ADDR_WIDTH = 10,
   parameter MEM_SPACE_AW = 18
   
)(
   input clk,
   input rst_n,   
   input read_en,
   input data_pattern_01,
   input read_double_en,

   output reg                           read_done_p,
   
    output reg [CTRL_ADDR_WIDTH-1:0]    axi_araddr     ,
    output reg                          axi_aruser_ap  ,    
    output reg [3:0]                    axi_aruser_id  ,
    output reg [3:0]                    axi_arlen      ,
    input                               axi_arready    ,
    output reg                          axi_arvalid    ,

    input   [MEM_DQ_WIDTH*8-1:0]        axi_rdata      ,
    //input   [3:0]                       axi_rid        ,
    //input                               axi_rlast      ,
    input                               axi_rvalid     ,
    output reg [7:0]                    err_cnt,
    output reg                          err_flag_led   ,
    //input                               random_data_en ,
    output  reg[MEM_DQ_WIDTH*8-1:0]   err_data_out ,    
    output  reg[MEM_DQ_WIDTH*8-1:0]   err_flag_out ,    
    output  reg[2:0]                  rd_cnt_out   ,
    input                             manu_clear   ,
    output                            err_lock     ,
    input                             rd_data_chg  ,
    input                             stress_test  ,
    output reg [2:0]                  state        ,
    output reg    [2:0]               rd_cnt       ,
    output reg                        rd_dir_err   ,
    output reg [31:0]                 read_cmd_cnt ,
    output reg [MEM_DQ_WIDTH*8-1:0]   next_err_data ,
    output reg [MEM_DQ_WIDTH-1:0]     err_data_pre  ,
    output reg [MEM_DQ_WIDTH-1:0]     err_data_aft  ,
    output reg  [3:0]                 burst_cnt           
);

localparam E_IDLE = 3'd0;
localparam E_RD   = 3'd1;
localparam E_END  = 3'd2;
localparam DQ_NUM = MEM_DQ_WIDTH/8; 
localparam DQ_NUM_1 = DQ_NUM -1   ;

reg [15:0] req_rd_cnt;
reg [15:0] execute_rd_cnt;
wire  read_finished;

wire [MEM_DQ_WIDTH-1:0] rd_data0;
wire [MEM_DQ_WIDTH-1:0] rd_data1;
wire [MEM_DQ_WIDTH-1:0] rd_data2;
wire [MEM_DQ_WIDTH-1:0] rd_data3;
wire [MEM_DQ_WIDTH-1:0] rd_data4;
wire [MEM_DQ_WIDTH-1:0] rd_data5;
wire [MEM_DQ_WIDTH-1:0] rd_data6;
wire [MEM_DQ_WIDTH-1:0] rd_data7;

wire [3:0]   addr_0_mux;
wire [3:0]   addr_1_mux;
wire [3:0]   addr_2_mux;
wire [3:0]   addr_3_mux;
wire [3:0]   addr_4_mux;
wire [3:0]   addr_5_mux;
wire [3:0]   addr_6_mux;
wire [3:0]   addr_7_mux;

reg  [MEM_DQ_WIDTH*8-1:0]  rddata_reorder ;
wire [7:0]                 prbs_out  ;
reg  [CTRL_ADDR_WIDTH-1:0]    axi_araddr_pre  ;
reg  [CTRL_ADDR_WIDTH-1:0]    axi_araddr_d    ;
wire [3:0] rd_data_addr;
reg [MEM_DQ_WIDTH*8-1:0] data_err ;
reg [MEM_DQ_WIDTH*8-1:0] data_err_d ;

reg         axi_rvalid_d1;
//reg         axi_rvalid_d2;
reg [31:0] normal_rd_addr;
//reg [2:0] state;
//reg [7:0] cnt_len;
//reg[2:0] rd_cnt;
reg [MEM_DQ_WIDTH*8-1:0]      axi_rdata_d1 ;
reg [MEM_DQ_WIDTH*8-1:0]      axi_rdata_d2 ;
reg        lock     ;                 
reg        lock_d   ;
wire       lock_pos ;
reg        init_en  ;
wire [7:0]      prbs_data ;
reg  [7:0]  prbs_din ;
reg        read_finished_d      ;
wire       read_finished_pos  ;
reg        read_finished_pos_d  ;
reg  [1:0] idle_cnt        ;

wire  [CTRL_ADDR_WIDTH:0]       random_rw_addr ;
wire  [3:0]                     random_axi_len ;
wire  [3:0]                     random_axi_id  ;
wire                            random_axi_ap  ;
wire   [20:0]                   prbs31_dout    ;

reg    [15:0]                   execute_rd_cnt_err_loc   ;
reg    [15:0]                   execute_rd_cnt_err_loc_d ;
reg                             err_flag_led_d           ;
wire                            err_flag_led_pos         ;
reg    [15:0]                   execute_rd_cnt_err_loc_lock ;
reg                             check_pls                ;
//reg [MEM_DQ_WIDTH*8-1:0]        next_err_data            ;
reg                             data_check_pls           ;
reg                             read_done_p_d            ;
wire                            read_done_p_pos          ;
wire[MEM_DQ_WIDTH*8-1:0]        axi_rdata_gen            ;

assign err_lock = lock ;

always @(posedge clk or negedge rst_n)
begin
   if (!rst_n) begin
      axi_araddr_pre     <= 'b0; 
      axi_aruser_id  <= 'b0; 
      axi_arlen      <= 4'b0; 
      axi_arvalid    <= 1'b0; 
      axi_aruser_ap  <= 'b0;
      state          <= E_IDLE;
      read_done_p    <= 1'b0;
      rd_cnt <= 0;
      idle_cnt <= 2'd0 ;
   end
   else begin          
       if ((state == E_IDLE) & read_en & read_finished) 
           begin
               axi_aruser_id <= random_axi_id;
        //  if(axi_araddr_pre < 8064)
         //      if(read_finished_pos_d & (rd_cnt == 3'd0 ))  
         //          if(axi_araddr_pre < 8064)      
         //              axi_araddr_pre <= axi_araddr_pre + 128 ;
          //         else
           //            axi_araddr_pre <= 0 ;
            //   else
            //       axi_araddr_pre <= axi_araddr_pre  ;
               axi_araddr_pre <= random_rw_addr;
               axi_arlen <= 15; 
               axi_aruser_ap <= random_axi_ap;  	         
   	       end         
           case (state)
               E_IDLE: begin
		    read_done_p <= 1'b0 ;
                   if (read_en & read_finished)
                       begin
                       idle_cnt <= idle_cnt + 1 ;
                       if(idle_cnt == 2'd3 )
                           state <= E_RD;
                       else ;
                       end
//                      rd_cnt <= 0;
                   end
               E_RD: begin
		   idle_cnt <= 2'd0 ;
                   axi_arvalid <= 1'b1;                  
                   if (axi_arvalid&axi_arready) 
                   begin
                      axi_arvalid <= 1'b0; 
                      state <= E_END;
		  //    rd_cnt <= ~rd_cnt ;
                      if(read_double_en) 
                      begin
                      if(rd_cnt==4)
		      	      begin
        //           	          read_done_p <= 1'b1;
                      	  rd_cnt <= 3'd0 ;
                      	end 
                      	else 
                        begin
       //               	  read_done_p <= 1'b0;
                          rd_cnt <= rd_cnt + 1;
                        end
                      end
                      else
                      begin
       //                 read_done_p <= 1'b1;
                        rd_cnt <= 3'd0;
                      end
                   end
              end
              E_END: begin
                   axi_arvalid <= 1'b0;
              //     read_done_p <= 1'b0;
                   if (read_finished)
                      state <= E_IDLE;
	           if(read_finished & rd_cnt == 0)
                       read_done_p <= 1'b1 ;  
              end
              default: begin
              	  state <= E_IDLE;
              end
          endcase     
        end
end        

always @(posedge clk or negedge rst_n)
begin
    if (!rst_n) begin
    //     axi_araddr_d <= 32'd0 ;
         axi_araddr <= 32'd0 ;
    end
    else
        begin
    //     axi_araddr_d <= axi_araddr_pre ;
         axi_araddr <= axi_araddr_pre ;
        end
end

always @(posedge clk or negedge rst_n)
begin
   if (!rst_n) begin
     normal_rd_addr <= 32'd0;
//     cnt_len <= 8'd0; 
   end
   else begin 
    if(state == E_RD) begin 
      normal_rd_addr <= axi_araddr_pre;
//      cnt_len <= 8'd0;  
    end
    else if(state == E_END) begin
//      if(cnt_len <= axi_arlen) begin
        if(axi_rvalid) begin
          normal_rd_addr <= normal_rd_addr + 32'd8;
//          cnt_len <= cnt_len + 1;
        end
//    end
    end
end
end

always @(posedge clk or negedge rst_n)
   if (!rst_n) begin
   	  req_rd_cnt     <= 16'd0;
   	  execute_rd_cnt <= 16'd0;
   end
   else begin
   	  if (axi_arvalid & axi_arready) begin
//   	        if(axi_arlen == 4'd0)
//   	        req_rd_cnt <= req_rd_cnt + 16;
//   	        else
   	  	    req_rd_cnt <= req_rd_cnt + axi_arlen + 1;
   	  end   	  
   	  if (axi_rvalid) begin
   	     execute_rd_cnt <= execute_rd_cnt + 1;
   	  end      
   end

assign  read_finished = (req_rd_cnt == execute_rd_cnt);

always @(posedge clk or negedge rst_n)
    if (!rst_n)
        read_finished_d <= 1'b1 ;
    else
        read_finished_d <= read_finished ;

assign read_finished_pos =  read_finished & (~read_finished_d ) ;

always @(posedge clk or negedge rst_n)
    if (!rst_n)
        read_finished_pos_d <= 1'b1 ;
    else
        read_finished_pos_d <= read_finished_pos ;


//assign rd_data0 = axi_rdata[MEM_DQ_WIDTH-1:0];
//assign rd_data1 = axi_rdata[MEM_DQ_WIDTH*2-1:MEM_DQ_WIDTH];
//assign rd_data2 = axi_rdata[MEM_DQ_WIDTH*3-1:MEM_DQ_WIDTH*2];
//assign rd_data3 = axi_rdata[MEM_DQ_WIDTH*4-1:MEM_DQ_WIDTH*3];
//assign rd_data4 = axi_rdata[MEM_DQ_WIDTH*5-1:MEM_DQ_WIDTH*4];
//assign rd_data5 = axi_rdata[MEM_DQ_WIDTH*6-1:MEM_DQ_WIDTH*5];
//assign rd_data6 = axi_rdata[MEM_DQ_WIDTH*7-1:MEM_DQ_WIDTH*6];
//assign rd_data7 = axi_rdata[MEM_DQ_WIDTH*8-1:MEM_DQ_WIDTH*7];

assign axi_rdata_gen = stress_test ? rddata_reorder : axi_rdata ;

assign rd_data0 = stress_test ? rddata_reorder[MEM_DQ_WIDTH-1:0] : axi_rdata[MEM_DQ_WIDTH-1:0];
assign rd_data1 = stress_test ? rddata_reorder[MEM_DQ_WIDTH*2-1:MEM_DQ_WIDTH] : axi_rdata[MEM_DQ_WIDTH*2-1:MEM_DQ_WIDTH] ;
assign rd_data2 = stress_test ? rddata_reorder[MEM_DQ_WIDTH*3-1:MEM_DQ_WIDTH*2] : axi_rdata[MEM_DQ_WIDTH*3-1:MEM_DQ_WIDTH*2] ;
assign rd_data3 = stress_test ? rddata_reorder[MEM_DQ_WIDTH*4-1:MEM_DQ_WIDTH*3] : axi_rdata[MEM_DQ_WIDTH*4-1:MEM_DQ_WIDTH*3] ;
assign rd_data4 = stress_test ? rddata_reorder[MEM_DQ_WIDTH*5-1:MEM_DQ_WIDTH*4] : axi_rdata[MEM_DQ_WIDTH*5-1:MEM_DQ_WIDTH*4] ;
assign rd_data5 = stress_test ? rddata_reorder[MEM_DQ_WIDTH*6-1:MEM_DQ_WIDTH*5] : axi_rdata[MEM_DQ_WIDTH*6-1:MEM_DQ_WIDTH*5] ;
assign rd_data6 = stress_test ? rddata_reorder[MEM_DQ_WIDTH*7-1:MEM_DQ_WIDTH*6] : axi_rdata[MEM_DQ_WIDTH*7-1:MEM_DQ_WIDTH*6] ;
assign rd_data7 = stress_test ? rddata_reorder[MEM_DQ_WIDTH*8-1:MEM_DQ_WIDTH*7] : axi_rdata[MEM_DQ_WIDTH*8-1:MEM_DQ_WIDTH*7] ;

always @(posedge clk or negedge rst_n)
begin
    if(~rst_n)
    begin
        axi_rvalid_d1 <= 1'b0;
//        axi_rvalid_d2 <= 1'b0;
    end
    else
    begin
        axi_rvalid_d1 <= axi_rvalid;
//        axi_rvalid_d2 <= axi_rvalid_d1;
    end
end

always @(posedge clk or negedge rst_n)
    if(~rst_n)
        axi_rdata_d1  <= {MEM_DQ_WIDTH{8'h0}} ;
    else if( axi_rvalid )
        axi_rdata_d1 <= axi_rdata_gen ;
    else 
        axi_rdata_d1 <=  axi_rdata_d1 ;

always @(posedge clk or negedge rst_n)
    if(~rst_n)
        axi_rdata_d2  <= {MEM_DQ_WIDTH{8'h0}} ;
    else if( axi_rvalid_d1 )
        axi_rdata_d2 <=  axi_rdata_d1 ;
    else 
        axi_rdata_d2 <=  axi_rdata_d2 ;
    

assign rd_data_addr = normal_rd_addr[3:0];

assign addr_0_mux = rd_data_addr + 4'd0;
assign addr_1_mux = rd_data_addr + 4'd1;
assign addr_2_mux = rd_data_addr + 4'd2;
assign addr_3_mux = rd_data_addr + 4'd3;
assign addr_4_mux = rd_data_addr + 4'd4;
assign addr_5_mux = rd_data_addr + 4'd5;
assign addr_6_mux = rd_data_addr + 4'd6;
assign addr_7_mux = rd_data_addr + 4'd7;

always @(posedge clk or negedge rst_n)
begin
    if(~rst_n)
    begin
        data_err <= {MEM_DQ_WIDTH{8'h0}};
     //   data_err[1] <= 1;
     //   data_err[2] <= 1'b0;
     //   data_err[3] <= 1'b0;
     //   data_err[4] <= 1'b0;
     //   data_err[5] <= 1'b0;
     //   data_err[6] <= 1'b0;
     //   data_err[7] <= 1'b0;
    end
    else if(data_pattern_01) begin
        data_err[1*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*0] <= rd_data0 ^ {DQ_NUM{8'h7f}};
        data_err[2*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*1] <= rd_data1 ^ {DQ_NUM{8'h80}};
        data_err[3*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*2] <= rd_data2 ^ {DQ_NUM{8'h7f}};
        data_err[4*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*3] <= rd_data3 ^ {DQ_NUM{8'h80}};
        data_err[5*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*4] <= rd_data4 ^ {DQ_NUM{8'h7f}};
        data_err[6*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*5] <= rd_data5 ^ {DQ_NUM{8'h80}};
        data_err[7*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*6] <= rd_data6 ^ {DQ_NUM{8'h7f}};
        data_err[8*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*7] <= rd_data7 ^ {DQ_NUM{8'h80}};
    end
    else if( stress_test )
        begin
         data_err[1*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*0]<= (rd_data0 ^ {DQ_NUM{prbs_out}});
         data_err[2*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*1]<= (rd_data1 ^ {DQ_NUM{prbs_out}});
         data_err[3*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*2]<= (rd_data2 ^ {DQ_NUM{prbs_out}});
         data_err[4*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*3]<= (rd_data3 ^ {DQ_NUM{prbs_out}});
         data_err[5*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*4]<= (rd_data4 ^ {prbs_data,{DQ_NUM_1{prbs_out}}});
         data_err[6*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*5]<= (rd_data5 ^ {DQ_NUM{prbs_out}});
         data_err[7*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*6]<= (rd_data6 ^ {DQ_NUM{prbs_out}});
         data_err[8*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*7]<= (rd_data7 ^ {DQ_NUM{prbs_out}});      
        end
    else begin
        data_err[1*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*0]<= (rd_data0 ^ {DQ_NUM{prbs_out}});         //DATA_CHK(random_data_en,rd_data0,addr_0_mux);
        data_err[2*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*1]<= (rd_data1 ^ {DQ_NUM{prbs_out}});         //DATA_CHK(random_data_en,rd_data1,addr_1_mux);
        data_err[3*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*2]<= (rd_data2 ^ {DQ_NUM{prbs_out}});         //DATA_CHK(random_data_en,rd_data2,addr_2_mux);
        data_err[4*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*3]<= (rd_data3 ^ {DQ_NUM{prbs_out}});         //DATA_CHK(random_data_en,rd_data3,addr_3_mux);
        data_err[5*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*4]<= (rd_data4 ^ {DQ_NUM{prbs_out}});        //DATA_CHK(random_data_en,rd_data4,addr_4_mux);
        data_err[6*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*5]<= (rd_data5 ^ {DQ_NUM{prbs_out}});         //DATA_CHK(random_data_en,rd_data5,addr_5_mux);
        data_err[7*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*6]<= (rd_data6 ^ {DQ_NUM{prbs_out}});         //DATA_CHK(random_data_en,rd_data6,addr_6_mux);
        data_err[8*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*7]<= (rd_data7 ^ {DQ_NUM{prbs_out}});         //DATA_CHK(random_data_en,rd_data7,addr_7_mux);
    end   
end

assign prbs_data = rd_data_chg ? (~prbs_out) : prbs_out ;

assign err = |data_err;

function[MEM_DQ_WIDTH-1:0] DATA_CHK;
    input   random_data_en   ;
    input [MEM_DQ_WIDTH-1:0] data_in;
    input   [3:0]   addr;
    reg     [3:0]   data_random;
    reg     [MEM_DQ_WIDTH-1:0]  expect_data;
    begin
        data_random = data_in[7:4];
        expect_data = random_data_en ? {DQ_NUM{data_random,(data_random ^ addr)}} : {DQ_NUM{addr,addr}};
        DATA_CHK = data_in ^ expect_data;
    end
endfunction

always @(posedge clk or negedge rst_n)
begin
    if(~rst_n)
    begin
        err_cnt <= 8'b0;
        err_flag_led <= 1'b0;
    end
    else if(manu_clear)
    begin
        err_cnt <= 8'b0;
        err_flag_led <= 1'b0;
    end
    else if(err && axi_rvalid_d1)
    begin
        if(err_cnt == 8'hff)
            err_cnt <= err_cnt;
        else
            err_cnt <= err_cnt + 8'b1;
        err_flag_led <= 1'b1;
    end
end        
    
always@(posedge clk or negedge rst_n)
    if(~rst_n)
	lock <= 1'b0 ;
    else if(manu_clear)
	lock <= 1'b0 ;
    else if(err && axi_rvalid_d1)
	lock <= 1'b1 ;
    else 
	lock <= lock ;

always@(posedge clk or negedge rst_n)
    if(~rst_n)
	lock_d <= 1'b0 ;
    else 
	lock_d <= lock ;

assign lock_pos = lock & (~lock_d) ;


always@(posedge clk or negedge rst_n)
    if(~rst_n)
        data_err_d <=  {MEM_DQ_WIDTH{8'h0}} ;
    else 
        data_err_d <=  data_err  ;
   

always@(posedge clk or negedge rst_n)
    if(~rst_n)
        err_flag_out <=  {MEM_DQ_WIDTH{8'h0}} ;
    else if(lock_pos)
        err_flag_out <=  data_err_d ;
    else 
        err_flag_out <=  err_flag_out  ;
   
always@(posedge clk or negedge rst_n)
    if(~rst_n)
        err_data_out <=  {MEM_DQ_WIDTH{8'h0}} ;
    else if(lock_pos)
        err_data_out <=  axi_rdata_d2 ;
    else 
        err_data_out <=  err_data_out  ;

always@(posedge clk or negedge rst_n)
    if(~rst_n)
        err_data_aft <=  {MEM_DQ_WIDTH{1'b0}} ;
    else if(lock_pos)
        if(|data_err_d[1*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*0])
            err_data_aft <=  axi_rdata_d1[1*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*0] ;
        else if(|data_err_d[2*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*1]) 
            err_data_aft <=  axi_rdata_d1[2*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*1] ;
        else if(|data_err_d[3*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*2]) 
            err_data_aft <=  axi_rdata_d1[3*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*2] ;
        else if(|data_err_d[4*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*3]) 
            err_data_aft <=  axi_rdata_d1[4*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*3] ;
        else if(|data_err_d[5*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*4]) 
            err_data_aft <=  axi_rdata_d1[5*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*4] ;
        else if(|data_err_d[6*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*5]) 
            err_data_aft <=  axi_rdata_d1[6*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*5] ;
        else if(|data_err_d[7*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*6]) 
            err_data_aft <=  axi_rdata_d1[7*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*6];
        else 
            err_data_aft <=  axi_rdata_d1[8*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*7] ;
    else 
        err_data_aft <=  err_data_aft  ;

always@(posedge clk or negedge rst_n)
    if(~rst_n)
        err_data_pre <=  {MEM_DQ_WIDTH{1'b0}} ;
    else if(err_flag_led)
        err_data_pre <=  err_data_pre  ;
    else if(err && axi_rvalid_d1)
        if(|data_err[1*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*0])
            err_data_pre <= axi_rdata_d2[1*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*0] ;
        else if(|data_err[2*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*1]) 
            err_data_pre <=  axi_rdata_d2[2*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*1] ;
        else if(|data_err[3*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*2]) 
            err_data_pre <=  axi_rdata_d2[3*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*2] ;
        else if(|data_err[4*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*3]) 
            err_data_pre <=  axi_rdata_d2[4*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*3] ;
        else if(|data_err[5*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*4]) 
            err_data_pre <=  axi_rdata_d2[5*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*4] ;
        else if(|data_err[6*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*5]) 
            err_data_pre <=  axi_rdata_d2[6*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*5] ;
        else if(|data_err[7*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*6]) 
            err_data_pre <=  axi_rdata_d2[7*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*6] ;
        else 
            err_data_pre <=  axi_rdata_d2[8*MEM_DQ_WIDTH-1:MEM_DQ_WIDTH*7] ;
    else 
        err_data_pre <=  err_data_pre  ;

always@(posedge clk or negedge rst_n)
    if(~rst_n)
        rd_cnt_out <= 3'd0 ;
    else if(lock_pos)
        rd_cnt_out <= rd_cnt  ;
    else 
        rd_cnt_out <= rd_cnt_out  ;

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        init_en <= 1'b0;
    else if(axi_arvalid & axi_arready)
        init_en <= 1'b1;
    else 
        init_en <= 0 ;

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        prbs_din <= 8'b0;
    else if(read_finished_pos & (rd_cnt == 2'd0 ))
        prbs_din <= prbs_out ;
//    else if((axi_araddr == 0) & axi_arvalid & axi_arready)
//         prbs_din <= 8'b0;
    else 
        prbs_din <= prbs_din ;

prbs7_8bit u_prbs(
    .clk            (clk           ),
    .rstn           (rst_n         ),
    .prbs_gen       (axi_rvalid_d1 ),
    .prbs_din       ( prbs_din     ),
    .init_en        ( init_en      ),
    .dout           (prbs_out      )
    );

 integer i,j ;
always @(*) begin
      for (i=0; i<8; i=i+1)
         for (j=0; j<MEM_DQ_WIDTH; j=j+1)            
           rddata_reorder[j*8 + i] = axi_rdata[i*MEM_DQ_WIDTH+j];
end


prbs7_28bit  #(
.PRBS_INIT  (21'h7_336a),
.PRBS_GEN_EN (1'b1)
)
I_prbs7_28bit(
.clk       (clk),
.rstn      (rst_n),
.clk_en    (read_done_p),

.cnt_mode  (1'b0   ),
.din       (21'd0),
.dout      (prbs31_dout),
.insert_er (1'b0),
.error     ()
);

wire [CTRL_ADDR_WIDTH-1:0] random_rw_addr_mask = {CTRL_ADDR_WIDTH{1'b0}} + {MEM_SPACE_AW{1'b1}};

assign random_rw_addr  =  {prbs31_dout[20:0],7'b0} & random_rw_addr_mask;
assign random_axi_id   =  prbs31_dout[19:16];
assign random_axi_len  =  prbs31_dout[15:12];
//assign random_write_en =  prbs_dout[0];
assign random_axi_ap   =  1'b0;//prbs_dout[1];

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        read_done_p_d <= 1'b0 ;
    else
        read_done_p_d <= read_done_p ;
        
assign read_done_p_pos =  read_done_p & ( ~read_done_p_d ) ;       

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        read_cmd_cnt <= 31'b0 ;
    else if(manu_clear )
        read_cmd_cnt <= 31'b0 ;
    else if(read_done_p_pos & (~err_flag_led) )
        if( &read_cmd_cnt)
            read_cmd_cnt <= read_cmd_cnt ;
        else 
            read_cmd_cnt <= read_cmd_cnt + 1 ;
    else
        read_cmd_cnt <= read_cmd_cnt ;
        
always @(posedge clk or negedge rst_n)
    if(!rst_n)
        begin    
            execute_rd_cnt_err_loc <= 16'd0 ;
            execute_rd_cnt_err_loc_d <= 16'd0 ;
        end
    else
        begin
            execute_rd_cnt_err_loc <= execute_rd_cnt ;
            execute_rd_cnt_err_loc_d <= execute_rd_cnt_err_loc ;
        end

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        err_flag_led_d <= 1'b0 ; 
    else
        err_flag_led_d <= err_flag_led ;

assign err_flag_led_pos =  err_flag_led & (~err_flag_led_d ) ;

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        execute_rd_cnt_err_loc_lock <= 16'd0 ;
    else if(err_flag_led_pos)
        execute_rd_cnt_err_loc_lock <= execute_rd_cnt_err_loc_d ;
    else
        execute_rd_cnt_err_loc_lock <=  execute_rd_cnt_err_loc_lock ;

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        check_pls <= 1'b0 ;
    else if( read_done_p )
        check_pls <= 1'b0 ;
    else if( err_flag_led_pos )
        check_pls <= 1'b1 ;
    else
        check_pls <= check_pls ;

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        next_err_data <= {MEM_DQ_WIDTH{8'h0}} ;
    else if(check_pls)
        if(axi_rvalid)
            if(execute_rd_cnt == (execute_rd_cnt_err_loc_lock + 16)  )
                next_err_data <= axi_rdata_gen  ;
            else if(execute_rd_cnt == (execute_rd_cnt_err_loc_lock + 32) )
                next_err_data <= axi_rdata_gen  ;
            else if(execute_rd_cnt == (execute_rd_cnt_err_loc_lock + 48) )
                next_err_data <= axi_rdata_gen  ;
            else if(execute_rd_cnt == (execute_rd_cnt_err_loc_lock + 64) )
                next_err_data <= axi_rdata_gen  ;
            else
                next_err_data <= next_err_data ;
        else
            next_err_data <= next_err_data ;
    else
        next_err_data <= next_err_data ;

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        data_check_pls <= 1'b0 ;
    else if( read_done_p )
        data_check_pls <= 1'b0 ;
    else if(check_pls & (execute_rd_cnt == (execute_rd_cnt_err_loc_lock + 16) ) &  axi_rvalid)
        data_check_pls <= 1'b1 ;
    else
        data_check_pls <= data_check_pls ;


always @(posedge clk or negedge rst_n)
    if(!rst_n)
        rd_dir_err <= 1'b0 ;
    else if(manu_clear)
        rd_dir_err <= 1'b0 ;
    else if(err_flag_led_pos & (rd_cnt != 3'd1 ))
        rd_dir_err <= 1'b1 ;    
    else if(data_check_pls)
        if(err_data_out != next_err_data)
            rd_dir_err <= 1'b1 ;
        else
            rd_dir_err <= rd_dir_err ;
   else
       rd_dir_err <= rd_dir_err ;

always @(posedge clk or negedge rst_n)
    if(!rst_n)
        burst_cnt <= 4'h0 ;
    else if( manu_clear )
        burst_cnt <= 4'h0 ;
    else if (lock_pos )
        burst_cnt <= execute_rd_cnt_err_loc_d[3:0] ;
    else 
        burst_cnt <=  burst_cnt ;

 endmodule
    
      	  	
