const std = @import("std");
const testing = std.testing;
const obj = @import("obj.zig");
const kernel = @import("../../kernel/kernel.zig");

test "OBJ: parts from the kernel's handles alone, an object each, indexed across the file" {
    // The writer took the VM's Solids, and evaluated and named them itself
    const small = kernel.cube(&.{}, 1, 1, 1, false) orelse return error.KernelFailed;
    defer kernel.destruct(small);
    const large = kernel.cube(&.{}, 2, 2, 2, false) orelse return error.KernelFailed;
    defer kernel.destruct(large);

    const text = try obj.build(testing.allocator, &.{ .{ .handle = small, .name = "bolt" }, .{ .handle = large, .name = "bolt 2" } }, "rack", null);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "# KupCAD Export\n# millimetres, Z up\n# rack\no bolt\n"));
    try testing.expect(std.mem.indexOf(u8, text, "\no bolt 2\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mtllib") == null);
    try testing.expect(std.mem.indexOf(u8, text, "usemtl") == null);
    // 8 corners and 12 triangles a cube; the second cube's faces index its own vertices
    try testing.expectEqual(@as(usize, 16), std.mem.count(u8, text, "\nv "));
    try testing.expectEqual(@as(usize, 24), std.mem.count(u8, text, "\nf "));
    try testing.expectEqual(@as(usize, 24), std.mem.count(u8, text, "\nvn "));
    const second = text[std.mem.indexOf(u8, text, "\no bolt 2\n").?..];
    var lines = std.mem.tokenizeScalar(u8, second, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "f ")) continue;
        var corners = std.mem.tokenizeScalar(u8, line[2..], ' ');
        while (corners.next()) |corner| {
            const slashes = std.mem.indexOf(u8, corner, "//").?;
            const vertex = try std.fmt.parseInt(u32, corner[0..slashes], 10);
            const normal = try std.fmt.parseInt(u32, corner[slashes + 2 ..], 10);
            try testing.expect(vertex >= 9 and vertex <= 16);
            try testing.expect(normal >= 13 and normal <= 24);
        }
    }

    try testing.expectError(error.NoGeometry, obj.build(testing.allocator, &.{}, null, null));
}

test "OBJ: with a material library, the file names it and each run of faces its material" {
    const part = kernel.cube(&.{}, 1, 1, 1, false) orelse return error.KernelFailed;
    defer kernel.destruct(part);
    const text = try obj.build(testing.allocator, &.{.{ .handle = part, .name = "p" }}, null, "p.mtl");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\nmtllib p.mtl\no p\n") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\nusemtl default\n"));
}
