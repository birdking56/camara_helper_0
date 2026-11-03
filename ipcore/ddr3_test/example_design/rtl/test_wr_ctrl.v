`timescale 1ns/1ns
module test_wr_ctrl #(
    parameter          CTRL_ADDR_WIDTH      =    28,
    parameter          MEM_DQ_WIDTH         =    16,
    parameter          MEM_COL_ADDR_WIDTH   =    10,
    parameter          MEM_SPACE_AW         =    18
)(                        
    input                                clk                ,
    input                                rst_n              ,   
    input                                init_start         ,
    input                                write_en           ,
    output reg                           write_done_p       ,
    output reg                           init_done          ,

    input                                data_pattern_01    ,
    input                                random_data_en     ,

    output reg [CTRL_ADDR_WIDTH-1:0]     axi_awaddr          ,
    output reg                           axi_awuser_ap       ,    
    output reg [3:0]                     axi_awuser_id       ,
    output reg [3:0]                     axi_awlen           ,
    input                                axi_awready         ,
    output reg                           axi_awvalid         ,
          
    output reg [MEM_DQ_WIDTH*8-1:0]      axi_wdata        ,
    output     [MEM_DQ_WIDTH*8/8-1:0]    axi_wstrb        ,
    input                                axi_wready       ,
    //input [3:0]                          axi_wusero_id    , 
    //input                                axi_wusero_last  ,
    input                                stress_test      ,
    input                                wr_data_chg      ,
    output reg [2:0]                     state
);

localparam DQ_NUM = MEM_DQ_WIDTH/8;
localparam DQ_NUM_1 = DQ_NUM -1 ;

localparam AXI_ADDR_MAX = (1<<MEM_SPACE_AW);

localparam E_IDLE = 3'd0;
localparam E_WR   = 3'd1;
localparam E_END  = 3'd2;

reg [1:0] axi_wready_d;
reg [CTRL_ADDR_WIDTH:0] init_addr;
reg [CTRL_ADDR_WIDTH-1:0] normal_wr_addr;
wire [3:0] wr_data_addr;
wire [3:0] wr_data_addr0;
reg [15:0] req_wr_cnt     ;
reg [15:0] execute_wr_cnt ;
wire  write_finished ;
reg [7:0] cnt_len;
wire[7:0] prbs_out;

reg [8*MEM_DQ_WIDTH-1:0]    wrdata_reorder;
wire[8*MEM_DQ_WIDTH-1:0]    wrdata_pre;

wire[7:0]   wr_data_random_0;
wire[7:0]   wr_data_random_1;
wire[7:0]   wr_data_random_2;
wire[7:0]   wr_data_random_3;
wire[7:0]   wr_data_random_4;
wire[7:0]   wr_data_random_5;
wire[7:0]   wr_data_random_6;
wire[7:0]   wr_data_random_7;

wire [3:0]   data_0;
wire [3:0]   data_1;
wire [3:0]   data_2;
wire [3:0]   data_3;
wire [3:0]   data_4;
wire [3:0]   data_5;
wire [3:0]   data_6;
wire [3:0]   data_7;

wire [7:0]   wr_data_0;
wire [7:0]   wr_data_1;
wire [7:0]   wr_data_2;
wire [7:0]   wr_data_3;
wire [7:0]   wr_data_4;
wire [7:0]   wr_data_5;
wire [7:0]   wr_data_6;
wire [7:0]   wr_data_7;

reg         init_en        ;
reg         init_start_d ;
wire        init_start_neg;
wire [7:0]  prbs_data  ;
wire [8*MEM_DQ_WIDTH-1:0]       wrdata_ch ;
wire [8*MEM_DQ_WIDTH-1:0]       wrdata_prbs  ;
wire  [CTRL_ADDR_WIDTH:0]       random_rw_addr ;
wire  [3:0]                     random_axi_len ;
wire  [3:0]                     random_axi_id  ;
wire                            random_axi_ap  ;
wire  [20:0]                    prbs31_dout    ;

assign axi_wstrb = {MEM_DQ_WIDTH{1'b1}};


always @(posedge clk or negedge rst_n)
begin
   if (!rst_n) begin
      axi_awaddr     <= 'b0; 
      axi_awuser_ap  <= 'b0; 
      axi_awuser_id  <= 4'b0; 
      axi_awlen      <= 4'b0; 
      axi_awvalid    <= 1'b0;
//      cnt            <= 32'd0; 
      state          <= E_IDLE;
      write_done_p   <= 1'b0;
   end
   else begin
    if(init_start) begin
        axi_awlen <= 4'd15;
        axi_awuser_ap  <= 'b0;
        if (axi_awaddr < (AXI_ADDR_MAX - 8'd128)) begin
            axi_awvalid <= 1;
            if(axi_awvalid&axi_awready) begin
             axi_awaddr <= axi_awaddr + 8'd128;
             axi_awuser_id  <= axi_awuser_id + 1;
            end
        end
        else if(axi_awaddr == (AXI_ADDR_MAX - 8'd128)) begin
           if(axi_awvalid&axi_awready) 
           axi_awvalid <= 0;
        end
        else
         axi_awvalid <= 0;
    end
    else begin
        if ((state == E_IDLE) && write_en && write_finished) begin //add more condition for easy debug
         axi_awuser_id <= random_axi_id;
	 axi_awaddr <= random_rw_addr  ;
	   //    if (axi_awaddr < (AXI_ADDR_MAX - 8'd128))
           //     axi_awaddr <= axi_awaddr + 8'd128;
           // else
          //      axi_awaddr <= 0 ;  
   	    axi_awlen     <=4'd15 ;
   	    axi_awuser_ap <= random_axi_ap;
   	    end 
   	    case(state) 
  	     	 E_IDLE: begin
   	     	 	  if (write_en && write_finished)
   	     	 	     state <= E_WR;
   	     	 end
   	     	 E_WR: begin
   	     	 	  axi_awvalid <= 1'b1;   	     	 	  
   	     	 	  if (axi_awvalid&axi_awready) begin
   	     	 	     state <= E_END;
   	     	 	     write_done_p <= 1'b1;
   	     	 	     axi_awvalid <= 1'b0;
   	     	 	  end
   	     	 end
   	     	 E_END: begin
   	     	      axi_awvalid <= 1'b0;
   	     	 	  write_done_p <= 1'b0;
   	     	 	  if (write_finished)
   	     	 	     state <= E_IDLE;
   	     	 end
   	     	 default: begin
   	     	 	  state <= E_IDLE;
   	     	 end   	        
   	endcase 
    end
end
end

always @(posedge clk or negedge rst_n)
   if (!rst_n)
      axi_wready_d <= 2'd0;
   else
   	  axi_wready_d <= {axi_wready_d[0], axi_wready};

assign prbs_data = wr_data_chg ? (~prbs_out) : prbs_out ;

assign wrdata_pre = {{DQ_NUM{wr_data_7}},{DQ_NUM{wr_data_6}},{DQ_NUM{wr_data_5}},{prbs_data,{DQ_NUM_1{wr_data_4}}},{DQ_NUM{wr_data_3}},{DQ_NUM{wr_data_2}},{DQ_NUM{wr_data_1}},{DQ_NUM{wr_data_0}}};
assign wrdata_prbs = {{DQ_NUM{wr_data_7}},{DQ_NUM{wr_data_6}},{DQ_NUM{wr_data_5}},{DQ_NUM{wr_data_4}},{DQ_NUM{wr_data_3}},{DQ_NUM{wr_data_2}},{DQ_NUM{wr_data_1}},{DQ_NUM{wr_data_0}}};

assign wrdata_ch = stress_test ?  wrdata_reorder : wrdata_prbs  ;

always @(posedge clk or negedge rst_n) 
begin
   if (!rst_n) begin
     axi_wdata <= 'h0;
     init_addr <= 'd0;
     normal_wr_addr <= 'd0;
     init_done <= 0;   
   end
   else begin
    if(init_start) begin
      if(init_addr < AXI_ADDR_MAX)begin
        axi_wdata <= wrdata_ch ;
        if(axi_wready) begin 
        init_addr <= init_addr + 8;   
    end   
    end
    else begin
       axi_wdata <= 'h0;
       init_done <= 1; 
    end
    end
    else begin
        if(state == E_WR)begin 
        normal_wr_addr <= axi_awaddr;
        axi_wdata <= 'h0; 
        end
        else if(state == E_END) begin
        axi_wdata <= wrdata_ch ;
        if(axi_wready) begin
        normal_wr_addr <= normal_wr_addr + 8;
        end
        end   
        else
          axi_wdata <= 'h0;
    end
end
end


assign wr_data_addr0 = (init_start==1) ? init_addr[3:0] : normal_wr_addr[3:0];
assign wr_data_addr = (axi_wready == 1) ? (wr_data_addr0 + 8) : wr_data_addr0;


always @(posedge clk or negedge rst_n)
   if (!rst_n) begin
   	  req_wr_cnt     <= 16'd0;
   	  execute_wr_cnt <= 16'd0;
   end
   else if (!init_start)
   begin
   	  if (axi_awvalid & axi_awready) begin
//   	    if(axi_awlen == 4'd0)
//   	    req_wr_cnt <= req_wr_cnt + 16;
//   	    else
   	  	req_wr_cnt <= req_wr_cnt + axi_awlen + 1;
   	  end   	  
   	  if (axi_wready) begin
   	     execute_wr_cnt <= execute_wr_cnt + 1;
   	  end      
   end
   else begin
   	  req_wr_cnt     <= 16'd0;
   	  execute_wr_cnt <= 16'd0;   
end

assign write_finished = (req_wr_cnt == execute_wr_cnt);

assign  data_0 = wr_data_addr + 4'd0;
assign  data_1 = wr_data_addr + 4'd1;
assign  data_2 = wr_data_addr + 4'd2;
assign  data_3 = wr_data_addr + 4'd3;
assign  data_4 = wr_data_addr + 4'd4;
assign  data_5 = wr_data_addr + 4'd5;
assign  data_6 = wr_data_addr + 4'd6;
assign  data_7 = wr_data_addr + 4'd7;

//assign wr_data_0 = data_pattern_01 ? 8'hff : {wr_data_random_0,(wr_data_random_0 ^ data_0)};
//assign wr_data_1 = data_pattern_01 ? 8'h00 : {wr_data_random_1,(wr_data_random_1 ^ data_1)};
//assign wr_data_2 = data_pattern_01 ? 8'hff : {wr_data_random_2,(wr_data_random_2 ^ data_2)};
//assign wr_data_3 = data_pattern_01 ? 8'h00 : {wr_data_random_3,(wr_data_random_3 ^ data_3)};
//assign wr_data_4 = data_pattern_01 ? 8'hff : {wr_data_random_4,(wr_data_random_4 ^ data_4)};
//assign wr_data_5 = data_pattern_01 ? 8'h00 : {wr_data_random_5,(wr_data_random_5 ^ data_5)};
//assign wr_data_6 = data_pattern_01 ? 8'hff : {wr_data_random_6,(wr_data_random_6 ^ data_6)};
//assign wr_data_7 = data_pattern_01 ? 8'h00 : {wr_data_random_7,(wr_data_random_7 ^ data_7)};

assign wr_data_0 = data_pattern_01 ? 8'h7f : stress_test ? prbs_out : wr_data_random_0 ;
assign wr_data_1 = data_pattern_01 ? 8'h80 : stress_test ? prbs_out : wr_data_random_1 ;
assign wr_data_2 = data_pattern_01 ? 8'h7f : stress_test ? prbs_out : wr_data_random_2 ;
assign wr_data_3 = data_pattern_01 ? 8'h80 : stress_test ? prbs_out : wr_data_random_3 ;
assign wr_data_4 = data_pattern_01 ? 8'h7f : stress_test ? prbs_out : wr_data_random_4 ;
assign wr_data_5 = data_pattern_01 ? 8'h80 : stress_test ? prbs_out : wr_data_random_5 ;
assign wr_data_6 = data_pattern_01 ? 8'h7f : stress_test ? prbs_out : wr_data_random_6 ;
assign wr_data_7 = data_pattern_01 ? 8'h80 : stress_test ? prbs_out : wr_data_random_7 ;

assign wr_data_random_0 = random_data_en ? prbs_out : 7'b0 ;
assign wr_data_random_1 = random_data_en ? prbs_out : 7'b0 ;
assign wr_data_random_2 = random_data_en ? prbs_out : 7'b0 ;
assign wr_data_random_3 = random_data_en ? prbs_out : 7'b0 ;
assign wr_data_random_4 = random_data_en ? prbs_out : 7'b0 ;
assign wr_data_random_5 = random_data_en ? prbs_out : 7'b0 ;
assign wr_data_random_6 = random_data_en ? prbs_out : 7'b0 ;
assign wr_data_random_7 = random_data_en ? prbs_out : 7'b0 ;

always@(posedge clk or negedge rst_n)
    if(!rst_n)
        init_start_d <= 1'b0 ;
    else
        init_start_d <= init_start ;

assign init_start_neg = !init_start & init_start_d ;

always@(posedge clk or negedge rst_n)
    if(!rst_n)
        init_en <= 1'b0;
    else if(init_start_neg)
        init_en <= 1'b1;
  //  else if((axi_awaddr == 0) & axi_awvalid & axi_awready)
  //      init_en <= 1'b1;
    else 
        init_en <= 0 ;


prbs7_8bit u_prbs(
    .clk            (clk        ),
    .rstn           (rst_n      ),
    .init_en        (init_en    ),
    .prbs_gen       (axi_wready ) ,
    .prbs_din       (8'd0       ),
   .dout            (prbs_out   )
    );

integer i,j ;
always @(*) begin
      for (i=0; i<8; i=i+1)
         for (j=0; j<MEM_DQ_WIDTH; j=j+1)            
           wrdata_reorder[i*MEM_DQ_WIDTH+j] = wrdata_pre[j*8 + i];
end

prbs7_28bit  #(
.PRBS_INIT  (21'h7_336a),
.PRBS_GEN_EN (1'b1)
)
I_prbs31_128bit(
.clk       (clk),
.rstn      (rst_n),
.clk_en    (write_done_p),

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

endmodule
