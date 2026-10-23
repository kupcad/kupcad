const std = @import("std");
const testing = std.testing;
const api = @import("../../api.zig");
const support = @import("../../test_support.zig");

/// What an OBJ file holds, counted line by line: the objects' names, the vertices and
/// normals, and each face's indices checked against them.
const Summary = struct {
    objects: std.ArrayList([]const u8) = .empty,
    comments: std.ArrayList([]const u8) = .empty,
    materials: std.ArrayList([]const u8) = .empty,
    library: ?[]const u8 = null,
    vertices: usize = 0,
    normals: usize = 0,
    faces: usize = 0,

    fn deinit(self: *Summary) void {
        self.objects.deinit(testing.allocator);
        self.comments.deinit(testing.allocator);
        self.materials.deinit(testing.allocator);
    }

    fn read(text: []const u8) !Summary {
        var summary: Summary = .{};
        errdefer summary.deinit();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "# ")) {
                try summary.comments.append(testing.allocator, line[2..]);
            } else if (std.mem.startsWith(u8, line, "o ")) {
                try summary.objects.append(testing.allocator, line[2..]);
            } else if (std.mem.startsWith(u8, line, "mtllib ")) {
                summary.library = line["mtllib ".len..];
            } else if (std.mem.startsWith(u8, line, "usemtl ")) {
                try summary.materials.append(testing.allocator, line["usemtl ".len..]);
            } else if (std.mem.startsWith(u8, line, "v ")) {
                try expectNumbers(line[2..], 3);
                summary.vertices += 1;
            } else if (std.mem.startsWith(u8, line, "vn ")) {
                try expectNumbers(line[3..], 3);
                summary.normals += 1;
            } else if (std.mem.startsWith(u8, line, "f ")) {
                // "f 1//1 2//1 3//1": each vertex and normal written so far
                var corners = std.mem.tokenizeScalar(u8, line[2..], ' ');
                var count: usize = 0;
                while (corners.next()) |corner| : (count += 1) {
                    var refs = std.mem.splitSequence(u8, corner, "//");
                    const vertex = try std.fmt.parseInt(usize, refs.next().?, 10);
                    const normal = try std.fmt.parseInt(usize, refs.next() orelse return error.NoNormal, 10);
                    try testing.expect(vertex >= 1 and vertex <= summary.vertices);
                    try testing.expect(normal >= 1 and normal <= summary.normals);
                }
                try testing.expectEqual(@as(usize, 3), count);
                summary.faces += 1;
            } else return error.UnknownLine;
        }
        return summary;
    }

    fn expectNumbers(text: []const u8, count: usize) !void {
        var fields = std.mem.tokenizeScalar(u8, text, ' ');
        var n: usize = 0;
        while (fields.next()) |field| : (n += 1) _ = try std.fmt.parseFloat(f64, field);
        try testing.expectEqual(count, n);
    }
};

fn exportObj(source: []const u8) ![]const u8 {
    return exportObjWith(source, .{});
}

fn exportObjWith(source: []const u8, options: api.ExportOptions) ![]const u8 {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, source));
    return api.exportModelFromVm(testing.allocator, &vm, .obj, options);
}

test "OBJ: a cube is one object of 8 vertices and 12 faces, each with its own normal" {
    const text = try exportObj("cube(2, 3, 4)");
    defer testing.allocator.free(text);
    var summary = try Summary.read(text);
    defer summary.deinit();
    try testing.expectEqualStrings("KupCAD Export", summary.comments.items[0]);
    try testing.expectEqual(@as(usize, 1), summary.objects.items.len);
    try testing.expectEqualStrings("part 1", summary.objects.items[0]);
    try testing.expectEqual(@as(usize, 8), summary.vertices);
    try testing.expectEqual(@as(usize, 12), summary.normals);
    try testing.expectEqual(@as(usize, 12), summary.faces);
    // The top face's normal, as written: unit, no negative zero
    try testing.expect(std.mem.find(u8, text, "vn 0 0 1\n") != null);
    try testing.expect(std.mem.find(u8, text, "-0 ") == null);
    // No material without a library asked for
    try testing.expect(summary.library == null);
    try testing.expectEqual(@as(usize, 0), summary.materials.items.len);
}

test "OBJ: with a library, the faces name their materials and the library describes them" {
    const source = "red = cube(1).material(color: \"#FF0000\", alpha: 0.5)\n[red + cube(1).translate(x: 0.5), cube(2).translate(z: 5)]";
    const text = try exportObjWith(source, .{ .mtl_name = "part.mtl" });
    defer testing.allocator.free(text);
    var summary = try Summary.read(text);
    defer summary.deinit();
    try testing.expectEqualStrings("part.mtl", summary.library.?);
    // The union's faces are red where they came from `red`, default elsewhere; the second
    // object is all default
    try testing.expectEqual(@as(usize, 3), summary.materials.items.len);
    try testing.expect(std.mem.eql(u8, summary.materials.items[0], "material_1") or std.mem.eql(u8, summary.materials.items[1], "material_1"));
    try testing.expectEqualStrings("default", summary.materials.items[2]);

    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, source));
    const library = try api.exportMaterialLibrary(testing.allocator, &vm);
    defer testing.allocator.free(library);
    try testing.expectEqualStrings("# KupCAD Export\nnewmtl default\nKd 0.8 0.8 0.8\nKa 0.8 0.8 0.8\nd 1\nnewmtl material_1\nKd 1 0 0\nKa 1 0 0\nd 0.5\n", library);
}

test "OBJ: each copy of a part is its own object, named after the part and numbered" {
    const text = try exportObj("lid = cube(1).named(\"lid\")\nassemble(name: \"Box\", parts: [lid, lid.translate(x: 5), cube(2)])");
    defer testing.allocator.free(text);
    var summary = try Summary.read(text);
    defer summary.deinit();
    try testing.expectEqualStrings("Box", summary.comments.items[summary.comments.items.len - 1]);
    try testing.expectEqual(@as(usize, 3), summary.objects.items.len);
    try testing.expectEqualStrings("lid", summary.objects.items[0]);
    try testing.expectEqualStrings("lid 2", summary.objects.items[1]);
    try testing.expectEqualStrings("part 2", summary.objects.items[2]);
    try testing.expectEqual(@as(usize, 24), summary.vertices);
    try testing.expectEqual(@as(usize, 36), summary.faces);
    // The second object's faces index past the first's 8 vertices
    const second = std.mem.find(u8, text, "o lid 2\n").?;
    const face = std.mem.find(u8, text[second..], "\nf ").? + second + 3;
    try testing.expect(try std.fmt.parseInt(usize, text[face .. face + std.mem.findScalar(u8, text[face..], '/').?], 10) > 8);
}

test "OBJ: a name keeps to its line" {
    // A name with a line break would start another statement of the file
    const text = try exportObj("cube(1).named(\"two\\nlines\")");
    defer testing.allocator.free(text);
    var summary = try Summary.read(text);
    defer summary.deinit();
    try testing.expectEqualStrings("two lines", summary.objects.items[0]);
}
