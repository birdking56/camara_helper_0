`timescale 1ns/1ps
`ifndef DGC_HEAD_STEP
`define DGC_HEAD_STEP 4
`endif
module tb_unpack_matrix;
    localparam integer STEP=`DGC_HEAD_STEP;
    reg clk=0; always #2.921 clk=~clk;
    reg rst_n=0, row_load=0, beat_valid=0, fill_ready=1;
    reg [4:0] row_head_skip=0, row_beats_total=0;
    reg [7:0] row_valid_bytes=0;
    reg [5:0] row_local_y=0;
    reg row_set=0,row_last=0,row_tile_last=0;
    reg [15:0] row_tile_tag=0;
    reg [255:0] beat_data=0;
    wire beat_ready,fill_valid,fill_set,fill_row_last,fill_tile_last,row_done;
    wire [15:0] fill_tile_tag;
    wire [5:0] fill_x,fill_y;
    wire [1:0] fill_count;
    wire [23:0] fill_rgb0,fill_rgb1;
    dgc_unpack #(.HEAD_SKIP_BYTES(STEP)) dut (
        .clk(clk),.rst_n(rst_n),.row_load(row_load),.row_head_skip(row_head_skip),
        .row_valid_bytes(row_valid_bytes),.row_beats_total(row_beats_total),.row_local_y(row_local_y),
        .row_set(row_set),.row_tile_tag(row_tile_tag),.row_last(row_last),.row_tile_last(row_tile_last),
        .beat_valid(beat_valid),.beat_ready(beat_ready),.beat_data(beat_data),
        .fill_valid(fill_valid),.fill_ready(fill_ready),.fill_set(fill_set),.fill_tile_tag(fill_tile_tag),
        .fill_x(fill_x),.fill_y(fill_y),.fill_count(fill_count),.fill_rgb0(fill_rgb0),.fill_rgb1(fill_rgb1),
        .fill_row_last(fill_row_last),.fill_tile_last(fill_tile_last),.row_done(row_done)
    );
    integer errors=0, rows=0, total_pixels=0, total_disc=0;
    integer pixels=0, head=0, received=0, beats_seen=0, disc_seen=0, done_seen=0;
    integer bp=0, gaps=0, timeout_count=0;
    reg [31:0] rng=32'h84e12837;
    reg held=0;
    wire [94:0] payload={fill_set,fill_tile_tag,fill_x,fill_y,fill_count,
                         fill_rgb0,fill_rgb1,fill_row_last,fill_tile_last};
    reg [94:0] held_payload;
    function [7:0] pixel_byte(input integer idx);
        pixel_byte=(idx*7+row_tile_tag*13+3)&255;
    endfunction
    function [23:0] pixel_rgb(input integer px);
        pixel_rgb={pixel_byte(px*3+2),pixel_byte(px*3+1),pixel_byte(px*3)};
    endfunction
    function [255:0] make_beat(input integer b);
        integer k,a;
        begin
            make_beat=0;
            for(k=0;k<32;k=k+1) begin
                a=b*32+k-head;
                make_beat[k*8+:8]=(a>=0 && a<pixels*3) ? pixel_byte(a) : 8'hee;
            end
        end
    endfunction
    task fail(input [8*100-1:0] msg);
        begin
            errors=errors+1;
            if(errors<8) $display("TEST_FAIL: %0s row=%0d head=%0d pixels=%0d received=%0d",msg,rows,head,pixels,received);
        end
    endtask
    always @(negedge clk) begin
        rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
        fill_ready=bp ? (rng[0]|rng[1]) : 1;
    end
    always @(posedge clk) begin
        if(!rst_n || row_load) held=0;
        else begin
            if(held && (!fill_valid || payload!==held_payload)) fail("fill payload changed while stalled");
            held=fill_valid && !fill_ready;
            if(held) held_payload=payload;
            if(beat_valid && beat_ready) beats_seen=beats_seen+1;
            if(dut.disc_phase && dut.accepted) begin disc_seen=disc_seen+1;total_disc=total_disc+1;end
            if(fill_valid && fill_ready) begin
                if(fill_count!=1 && fill_count!=2) fail("zero/invalid pixel record");
                if(fill_x!==received[5:0] || fill_y!==row_local_y || fill_set!==row_set || fill_tile_tag!==row_tile_tag)
                    fail("pixel metadata or sequence mismatch");
                if(fill_rgb0!==pixel_rgb(received)) fail("first pixel bytes mismatch");
                if(fill_count==2 && fill_rgb1!==pixel_rgb(received+1)) fail("second pixel bytes mismatch");
                if(fill_row_last!==(row_last && received+fill_count==pixels)) fail("row_last misaligned");
                if(fill_tile_last!==(row_tile_last && row_last && received+fill_count==pixels)) fail("tile_last misaligned");
                received=received+fill_count;total_pixels=total_pixels+fill_count;
            end
            if(row_done) begin
                done_seen=done_seen+1;
                if(received!=pixels || beats_seen!=row_beats_total) fail("row retired before pixels/beats completed");
            end
        end
    end
    task run_row(input integer h,p);
        integer b,n,waited;
        begin
            @(negedge clk);
            head=h;pixels=p;received=0;beats_seen=0;disc_seen=0;done_seen=0;
            n=(h+3*p+31)/32;
            row_head_skip=h;row_valid_bytes=3*p;row_beats_total=n;
            row_local_y=rows%64;row_set=rows%2;row_tile_tag=16'h1000+rows;
            row_last=(rows%3)!=0;row_tile_last=(rows%5)==0;
            bp=rows%2;gaps=(rows%3)==1;row_load=1;
            @(negedge clk);row_load=0;
            for(b=0;b<n;b=b+1) begin
                if(gaps) repeat(rng%5) @(negedge clk);
                beat_data=make_beat(b);beat_valid=1;
                @(posedge clk);
                while(!beat_ready) @(posedge clk);
                @(negedge clk);beat_valid=0;
            end
            waited=0;
            while(!done_seen && waited<1000) begin @(negedge clk);waited=waited+1;end
            if(!done_seen) fail("row timeout");
            if(received!=p) fail("wrong pixel count");
            if(disc_seen!=h/STEP+h%STEP) fail("unexpected discard work");
            repeat(2) @(negedge clk);
            if(done_seen!=1) fail("duplicate row retirement");
            rows=rows+1;
        end
    endtask
    integer h,p;
    initial begin
        repeat(8) @(negedge clk);rst_n=1;
        for(h=0;h<32;h=h+1)
            for(p=1;p<=64;p=p+1) run_row(h,p);
        $display("TEST_INFO: unpack step=%0d rows=%0d pixels=%0d discard_cycles=%0d errors=%0d",STEP,rows,total_pixels,total_disc,errors);
        if(errors==0 && rows==2048 && total_pixels==66560) $display("TEST_PASS");
        else $display("TEST_FAIL_COUNT %0d",errors);
        $finish;
    end
endmodule
