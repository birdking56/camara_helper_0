//-----------------------------------------------------------------------------
// dgc_native_split.v
//
// Splits one row request at a 4 KiB byte boundary.
//
// Frozen reference: 接口冻结规范_v1.md section 8.
//
//   "请求不能跨 4 KiB 字节边界：当前 Column 地址为 10 bit，手册明确跨 Column 会
//    回卷；必须在边界拆请求，不能按普通线性突发假设自动跨行。"
//
// So a request is emitted as one or two native requests, never spanning a 4 KiB
// boundary. A row request is at most 7 beats of 32 bytes, and a 4 KiB page holds
// 128 beats, so at most one split can occur and second only ever describes a
// remainder.
//
// The aligned address is always 32-byte aligned, so the byte offset inside the page
// is a multiple of 32 and the number of beats left before the boundary is
// 128 - aligned_addr[11:5].
//
// The native port takes a 28-bit word address (byte address >> 2), so the byte
// address must stay below 1 GiB; `addr_ok` reports that the whole request fits and
// the caller must refuse to issue otherwise, never truncate.
//-----------------------------------------------------------------------------

module dgc_native_split (
    input  wire [31:0] aligned_addr,
    input  wire [4:0]  beats,          // 1..7

    output wire        cross,          // 1 = two native requests are needed
    output wire [4:0]  first_beats,
    output wire [4:0]  second_beats,
    output wire [31:0] second_addr,
    output wire        is_single,      // 1 = exactly one request
    output wire        addr_ok         // whole request inside the 28-bit word range
);

    localparam integer BEATS_PER_PAGE = 128;      // 4096 / 32

    wire [6:0]  beat_in_page = {2'd0, aligned_addr[11:5]};
    wire [6:0]  left_in_page = BEATS_PER_PAGE - beat_in_page;   // beats until the boundary

    wire [31:0] last_byte = aligned_addr + ({27'd0, beats} << 5) - 32'd1;

    assign cross = (aligned_addr[31:12] != last_byte[31:12]);

    // when crossing, the first request stops at the page boundary
    assign first_beats  = cross ? left_in_page[4:0] : beats;
    assign second_beats = cross ? (beats - left_in_page[4:0]) : 5'd0;
    // the second request starts at the NEXT page, not at the start of this one
    assign second_addr  = {aligned_addr[31:12] + 20'd1, 12'd0};

    // one request unless the split was needed; a split that produced an empty
    // second half is a bug, not a single request
    assign is_single = ~cross;

    // native word address is 28 bits, so the last byte must be below 2^30 = 1 GiB
    assign addr_ok = (last_byte < 32'h4000_0000);

endmodule
