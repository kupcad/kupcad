const std = @import("std");
const testing = std.testing;
const stl = @import("stl.zig");
const stl_format = @import("../../formats/stl.zig");

test "STL: binary triangle count cannot wrap the length check" {
    // 85_899_346 * 50 == 2^32 + 4, so in u32 math 84 + n*50 wraps to 88 and a
    // 100-byte buffer used to pass the check and then be read far out of bounds.
    var data: [100]u8 = @splat(0);
    std.mem.writeInt(u32, data[80..84], 85_899_346, .little);
    try testing.expectError(error.InvalidStl, stl_format.readBinary(testing.allocator, &data));
    // The importer must not trust the count either (falls back to ASCII, which finds no facets).
    try testing.expectError(error.InvalidStl, stl.parseStlBuffer(testing.allocator, &data));
}
