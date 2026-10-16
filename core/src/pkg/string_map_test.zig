const std = @import("std");
const testing = std.testing;
const string_map = @import("string_map.zig");

/// Sets a new key and replaces an existing one's value, as the resolver records a parent's
/// dependency and `pkg add` a project's.
fn putTwice(allocator: std.mem.Allocator) !void {
    var map = string_map.StringMap.init(allocator);
    defer string_map.deinitOwned(allocator, &map);
    try string_map.putOwned(allocator, &map, "screws", "github.com/kupcad/screws@v1");
    try string_map.putOwned(allocator, &map, "screws", "github.com/kupcad/screws@v2");
    try testing.expectEqualStrings("github.com/kupcad/screws@v2", map.get("screws").?);
}

test "StringMap: putOwned leaks nothing and leaves nothing freed in the map, whichever allocation fails" {
    // The resolver freed the old URL before copying the new one: a failed copy left the
    // freed URL in the lockfile's map, freed again when the lockfile was.
    try testing.checkAllAllocationFailures(testing.allocator, putTwice, .{});
}

test "StringMap: sortKeys orders byte-wise" {
    var keys = [_][]const u8{ "b", "B", "a", "ab" };
    string_map.sortKeys(&keys);
    try testing.expectEqualStrings("B", keys[0]);
    try testing.expectEqualStrings("a", keys[1]);
    try testing.expectEqualStrings("ab", keys[2]);
    try testing.expectEqualStrings("b", keys[3]);
}
