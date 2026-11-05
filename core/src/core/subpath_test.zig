const std = @import("std");
const testing = std.testing;
const under = @import("subpath.zig").under;

test "under: a path inside a folder is its path from there, by either separator" {
    try testing.expectEqualStrings("c.kup", under("/a/b/c.kup", "/a/b").?);
    try testing.expectEqualStrings("c/d.kup", under("/a/b/c/d.kup", "/a/b").?);
    try testing.expectEqualStrings("p\\x.kup", under("C:\\work\\p\\x.kup", "C:\\work").?);
    try testing.expectEqualStrings("c.kup", under("C:/work\\c.kup", "C:/work").?);
    // A root ends in its separator
    try testing.expectEqualStrings("etc", under("/etc", "/").?);
    try testing.expectEqualStrings("x.kup", under("C:\\x.kup", "C:\\").?);
}

test "under: a neighbour sharing the folder's name, the folder itself and an outsider aren't inside" {
    try testing.expectEqual(null, under("/a/bc/d.kup", "/a/b"));
    try testing.expectEqual(null, under("/a/b.kup", "/a/b"));
    try testing.expectEqual(null, under("/a/b", "/a/b"));
    try testing.expectEqual(null, under("/a/b/", "/a/b"));
    try testing.expectEqual(null, under("/a", "/a/b"));
    try testing.expectEqual(null, under("/other/b/c", "/a/b"));
    try testing.expectEqual(null, under("/a/b/c", ""));
}
