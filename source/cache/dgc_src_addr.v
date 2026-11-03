//-----------------------------------------------------------------------------
// dgc_src_addr.v
//
// The source cache address mapping, isolated as pure combinational logic so it can
// be verified exhaustively before anything with timing is built on top of it.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   local bank = {local_y[0], local_x[0]}
//   address    = (local_y >> 1)*32 + (local_x >> 1)
//   physical   = set*4 + local bank
//
// model/dgc_source_cache_ref.py already proved the mapping is bijective and that a
// 64x64 block uses exactly addresses 0..1023 in every bank. This module is the RTL
// expression of that mapping; the testbench re-proves the same properties on the
// hardware form, because a shift or a concatenation is easy to get wrong even when
// the formula is understood.
//
// Two lookup ports are provided: the first for a fill's first pixel, the second for
// its second pixel, which is at local_x+1 on the same row and therefore lands in
// the bank with the opposite x parity.
//-----------------------------------------------------------------------------

module dgc_src_addr (
    input  wire        cache_set,
    input  wire [5:0]  lx,
    input  wire [5:0]  ly,

    output wire [2:0]  bank,          // physical bank, 0..7
    output wire [9:0]  addr,
    output wire [1:0]  local_bank     // 0..3 inside the set
);

    assign local_bank = {ly[0], lx[0]};
    assign bank       = {cache_set, ly[0], lx[0]};
    assign addr       = {ly[5:1], 5'd0} + {5'd0, lx[5:1]};

endmodule
