const std = @import("std");
const testing = std.testing;
const import_path = @import("import_path.zig");

fn expectResolves(importer: []const u8, spec: []const u8, expected: []const u8) !void {
    const got = try import_path.resolve(testing.allocator, importer, spec);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "Import path: a relative import is the importing file's neighbour" {
    try expectResolves("parts/main.kup", "./hw.kup", "parts/hw.kup");
    try expectResolves("parts/sub/main.kup", "../lib/hw.kup", "parts/lib/hw.kup");
    try expectResolves("main.kup", "./hw.kup", "hw.kup");
    try expectResolves("", "./hw.kup", "hw.kup");
    // Leaving the root stays visible, for the VFS to refuse.
    try expectResolves("main.kup", "../outside.kup", "../outside.kup");
}

test "Import path: an asset is the importer's neighbour, or from the root" {
    const near = try import_path.resolveFile(testing.allocator, "parts/main.kup", "./logo.stl");
    defer testing.allocator.free(near);
    try testing.expectEqualStrings("parts/logo.stl", near);
    const rooted = try import_path.resolveFile(testing.allocator, "parts/main.kup", "assets/logo.stl");
    defer testing.allocator.free(rooted);
    try testing.expectEqualStrings("assets/logo.stl", rooted);
}

test "Import path: a package import is looked up by alias among the linked packages" {
    try expectResolves("parts/main.kup", "hardware", ".kupcad/pkg/hardware/main.kup");
    try expectResolves("parts/main.kup", "hardware/screws.kup", ".kupcad/pkg/hardware/screws.kup");
    try expectResolves("parts/main.kup", "/etc/x.kup", "/etc/x.kup");
}
