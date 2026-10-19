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

fn expectFile(importer: []const u8, spec: []const u8, expected: []const u8) !void {
    const got = try import_path.resolveFile(testing.allocator, importer, spec);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "Import path: a file is the importer's neighbour, or a package's, as a module is" {
    try expectFile("parts/main.kup", "./logo.stl", "parts/logo.stl");
    try expectFile("parts/main.kup", "../data/machine.json", "data/machine.json");
    // A package ships its data: it was read from the root, where it isn't
    try expectFile("parts/main.kup", "hardware/data/screws.json", ".kupcad/pkg/hardware/data/screws.json");
    try expectFile("parts/main.kup", "/etc/data.json", "/etc/data.json");
}

test "Import path: a package import is looked up by alias among the linked packages" {
    try expectResolves("parts/main.kup", "hardware", ".kupcad/pkg/hardware/main.kup");
    try expectResolves("parts/main.kup", "hardware/screws.kup", ".kupcad/pkg/hardware/screws.kup");
    try expectResolves("parts/main.kup", "/etc/x.kup", "/etc/x.kup");
}
