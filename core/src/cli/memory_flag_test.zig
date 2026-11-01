const std = @import("std");
const testing = std.testing;
const memory_flag = @import("memory_flag.zig");

const GB = 1024 * 1024 * 1024;

test "memory_flag: a size is a whole number with a unit, in any case, or bytes alone" {
    try testing.expectEqual(@as(?usize, 8 * GB), memory_flag.parseSize("8GB"));
    try testing.expectEqual(@as(?usize, 8 * GB), memory_flag.parseSize("8gb"));
    try testing.expectEqual(@as(?usize, 512 * 1024 * 1024), memory_flag.parseSize("512MB"));
    try testing.expectEqual(@as(?usize, 64 * 1024), memory_flag.parseSize("64KB"));
    try testing.expectEqual(@as(?usize, 100), memory_flag.parseSize("100B"));
    try testing.expectEqual(@as(?usize, 65536), memory_flag.parseSize("65536"));
}

test "memory_flag: zero, a fraction, a sign, another unit, a unit alone or an overflow is no size" {
    for ([_][]const u8{ "", "0", "0GB", "1.5GB", "-1GB", "+1GB", "8G", "8 GB", "GB", "B", "8TB", "99999999999999999999GB" }) |text| {
        errdefer std.debug.print("'{s}'\n", .{text});
        try testing.expectEqual(@as(?usize, null), memory_flag.parseSize(text));
    }
}

test "memory_flag: the flag wins over the project's limit, which wins over the command's default" {
    // The flag's, whether the project asks for less or for more, as `-p` wins over a default:
    // a cloned project can't lift the host's limit, and a setting raised takes
    try testing.expectEqual(@as(?usize, 8 * GB), memory_flag.limitFor(100, 8 * GB, null));
    try testing.expectEqual(@as(?usize, 8 * GB), memory_flag.limitFor(100 * GB, 8 * GB, GB));
    try testing.expectEqual(@as(?usize, 8 * GB), memory_flag.limitFor(null, 8 * GB, GB));
    // No flag: the project's, else the command's (build: none; watch, lsp: interactive)
    try testing.expectEqual(@as(?usize, 100 * GB), memory_flag.limitFor(100 * GB, null, GB));
    try testing.expectEqual(@as(?usize, 100), memory_flag.limitFor(100, null, null));
    try testing.expectEqual(@as(?usize, GB), memory_flag.limitFor(null, null, GB));
    try testing.expectEqual(@as(?usize, null), memory_flag.limitFor(null, null, null));
}
