const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const os2 = ttf.tables.os2;

test "a windows descent of 32768" {
    // [KupCAD] usWinDescent is unsigned, read as an i16 and negated: 0x8000, -32768, overflowed
    // it. It saturates.
    var data: [78]u8 = @splat(0); // version 0
    std.mem.writeInt(u16, data[76..78], 0x8000, .big); // usWinDescent
    const table = try os2.parse(&data);
    try t.expectEqual(32767, table.windows_descender());
}
