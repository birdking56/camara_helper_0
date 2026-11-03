module ips2l_ddrphy_rst_clk_phase_adj_v1_0 
#(
    parameter PHASE_ADJ_DIR  = 0 ,
    parameter PHASE_ADJ_STEP = 8 
)
(
input                dps_clk               ,
input                ddr_rstn              ,
input                rst_clk_adj_start     ,
input                rst_clk_dps_done      ,
output    reg[2:0]   cpd_state             ,
output    reg        rst_clk_adj_done      ,
output    reg        rst_clk_adj_dir       ,
output    reg        rst_clk_adj_en                


);

localparam  CPD_RST          = 3'd0;
localparam  CPD_OFFSET_JUDGE = 3'd1;
localparam  CPD_OFFSET_CTRL  = 3'd2;
localparam  CPD_OFFSET_WAIT  = 3'd3;
localparam  CPD_DONE         = 3'd4;

`ifdef IPS_DDR_SPEEDUP_SIM
localparam FAST_CPD = 1;
`else                                                              
localparam FAST_CPD = 0;      
`endif

reg  [1:0]      rst_clk_dps_done_d         ;
reg  [9:0]      cpd_offset_cnt             ;
reg  [5:0]      time_out                   ;
reg  [3:0]      rst_clk_adj_start_d        ;
wire            rst_clk_adj_chg            ;
reg  [2:0]      cnt                        ;

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)begin       
        rst_clk_dps_done_d          <= 2'b00  ;
        rst_clk_adj_start_d <= 4'b0   ;
    end
    else begin        
        rst_clk_dps_done_d          <= {rst_clk_dps_done_d[0],rst_clk_dps_done};
        rst_clk_adj_start_d <= {rst_clk_adj_start_d[2:0],rst_clk_adj_start};
    end
end

assign  rst_clk_adj_chg = rst_clk_adj_start_d[2] ^ rst_clk_adj_start_d[3]  ;

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
        cpd_state <= CPD_RST;
    else begin
        case(cpd_state)
            CPD_RST:
                if(rst_clk_adj_chg)
                    cpd_state <= CPD_OFFSET_JUDGE ;
                else
                    cpd_state <= CPD_RST ;
            CPD_OFFSET_JUDGE : 
            	if(cpd_offset_cnt == PHASE_ADJ_STEP)
            		cpd_state <= CPD_DONE;
            	else 
            		cpd_state <= CPD_OFFSET_CTRL;           
            CPD_OFFSET_CTRL :
            	cpd_state <= CPD_OFFSET_WAIT;
            CPD_OFFSET_WAIT : 
            	if((rst_clk_dps_done_d[1] == 1'b1) || (time_out == 6'd20))
            		cpd_state <= CPD_OFFSET_JUDGE ;
                else
                    cpd_state <= CPD_OFFSET_WAIT  ; 
            CPD_DONE:
                if (cnt[2])
                    cpd_state <= CPD_RST;   
                else
                    cpd_state <= CPD_DONE ;         
            default:
                cpd_state <= CPD_RST;
        endcase
    end
end

always @(posedge dps_clk or negedge ddr_rstn)
    if(!ddr_rstn)
        cnt <= 3'd0 ;
    else if(cpd_state == CPD_DONE )
        cnt <= cnt + 1;
    else
        cnt <= 3'd0 ;

always @(posedge dps_clk or negedge ddr_rstn)
    if(!ddr_rstn)
        rst_clk_adj_done <= 1'd0  ;
    else if(cpd_state == CPD_DONE )
        rst_clk_adj_done <= 1'b1  ;
    else
        rst_clk_adj_done <= 1'b0  ;

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
        rst_clk_adj_en  <= 0;
    else if((cpd_state == CPD_RST) || (cpd_state == CPD_DONE))
    	rst_clk_adj_en  <= 0;
    else if(cpd_state == CPD_OFFSET_CTRL)
    	rst_clk_adj_en  <= 1;
    else
        rst_clk_adj_en  <= FAST_CPD;
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
        rst_clk_adj_dir <= 0;
    else if(cpd_state == CPD_OFFSET_CTRL)
    	rst_clk_adj_dir <= PHASE_ADJ_DIR  ;
end

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    	cpd_offset_cnt <= 4'd0  ;
    else if(cpd_state == CPD_DONE)
    	cpd_offset_cnt <= 4'd0  ;
    else if(rst_clk_dps_done_d[1])
        cpd_offset_cnt <= cpd_offset_cnt + 4'd1;
    else 
        cpd_offset_cnt <= cpd_offset_cnt  ;
end  

always @(posedge dps_clk or negedge ddr_rstn)
begin
    if(!ddr_rstn)
    	time_out <= 6'd0;
    else if(cpd_state == CPD_OFFSET_WAIT)
    	time_out <= time_out + 6'd1;
    else 
    	time_out <= 6'd0;
end


endmodule 
