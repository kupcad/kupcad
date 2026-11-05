const std = @import("std");
const testing = std.testing;
const stl = @import("stl.zig");
const registry = @import("../../stdlib/registry.zig");
const dag_evaluator = @import("../../vm/dag_evaluator.zig");
const VM = @import("../../vm/vm.zig").VM;
const Mesh = @import("imported_mesh.zig").Mesh;

fn parse(bytes: []const u8) !Mesh {
    var diag: stl.Diagnostic = .{};
    return stl.parseStlBuffer(testing.allocator, bytes, &diag) catch |err| {
        std.debug.print("stl: {s}\n", .{diag.message()});
        return err;
    };
}

fn expectRefused(bytes: []const u8, message: []const u8) !void {
    var diag: stl.Diagnostic = .{};
    try testing.expectError(error.Unreadable, stl.parseStlBuffer(testing.allocator, bytes, &diag));
    try testing.expectEqualStrings(message, diag.message());
}

/// A binary STL of `triangles` (each three corners), its header `header`, with `trailing`
/// bytes after the records.
fn binaryStl(comptime header: []const u8, comptime triangles: []const [3][3]f32, comptime trailing: []const u8) [84 + 50 * triangles.len + trailing.len]u8 {
    var bytes: [84 + 50 * triangles.len + trailing.len]u8 = @splat(0);
    @memcpy(bytes[0..header.len], header);
    std.mem.writeInt(u32, bytes[80..84], triangles.len, .little);
    for (triangles, 0..) |triangle, t| for (triangle, 0..) |corner, v| for (corner, 0..) |c, axis| {
        std.mem.writeInt(u32, bytes[84 + 50 * t + 12 + (3 * v + axis) * 4 ..][0..4], @bitCast(c), .little);
    };
    @memcpy(bytes[bytes.len - trailing.len ..], trailing);
    return bytes;
}

/// An ASCII STL of `facets` (each its lines between `facet normal 0 0 0` and `endfacet`).
fn asciiStl(comptime facets: []const []const u8) []const u8 {
    comptime var text: []const u8 = "solid t\n";
    inline for (facets) |facet| text = text ++ "facet normal 0 0 0\nouter loop\n" ++ facet ++ "endloop\nendfacet\n";
    return text ++ "endsolid t\n";
}

test "STL: binary triangle count cannot wrap the length check" {
    // 85_899_346 * 50 == 2^32 + 4, so in u32 math 84 + n*50 wraps to 88 and a
    // 100-byte buffer used to pass the check and then be read far out of bounds.
    // Not binary, then; as ASCII it has no facets.
    var data: [100]u8 = @splat(0);
    std.mem.writeInt(u32, data[80..84], 85_899_346, .little);
    try expectRefused(&data, "it isn't STL: as binary STL its header counts 85899346 triangles, and the 16 bytes after it hold 0; as ASCII STL it doesn't start with \"solid\"");
}

test "STL: an exported cube reads back as the same cube" {
    // There used to be a second, unused STL reader and writer (formats/stl.zig).
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const handle = try dag_evaluator.evaluateDAG(&vm, try vm.dag_builder.addCube(2, 3, 4, false));

    const bytes = try stl.buildStlBuffer(testing.allocator, handle);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 84 + 12 * 50), bytes.len);
    try testing.expectEqualStrings("KupCAD Export", bytes[0.."KupCAD Export".len]);
    try testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, bytes[80..84], .little));

    var mesh = try parse(bytes);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), mesh.points.len);
    try testing.expectEqual(@as(usize, 12), mesh.faces.len);
    var max: [3]f64 = @splat(0);
    for (mesh.points) |p| {
        for (&max, p) |*m, c| m.* = @max(m.*, c);
    }
    try testing.expectEqual([3]f64{ 2, 3, 4 }, max);
}

test "STL: ASCII files are read too" {
    const ascii =
        \\solid t
        \\facet normal 0 0 1
        \\ outer loop
        \\  vertex 0 0 0
        \\  vertex 1 0 0
        \\  vertex 0 1 0
        \\ endloop
        \\endfacet
        \\endsolid t
    ;
    var mesh = try parse(ascii);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), mesh.points.len);
    try testing.expectEqual([3]u32{ 0, 1, 2 }, mesh.faces[0]);
}

test "STL: several parts are written as their union, from the kernel's handles alone" {
    // The writer took the VM, to check the engine's features and raise; its caller does
    const kernel = @import("../../kernel/kernel.zig");
    const small = kernel.cube(&.{}, 10, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destruct(small);
    const large = kernel.cube(&.{}, 20, 20, 20, false) orelse return error.KernelFailed;
    defer kernel.destruct(large);

    try testing.expectError(error.NoGeometry, stl.buildStlOfParts(testing.allocator, &.{}));
    const bytes = try stl.buildStlOfParts(testing.allocator, &.{ small, large });
    defer testing.allocator.free(bytes);
    var mesh = try parse(bytes);
    defer mesh.deinit(testing.allocator);
    // The small cube is inside the large one: their union is the large cube
    try testing.expectEqual(@as(usize, 12), mesh.faces.len);
    var max: [3]f64 = @splat(0);
    for (mesh.points) |p| {
        for (&max, p) |*m, c| m.* = @max(m.*, c);
    }
    try testing.expectEqual([3]f64{ 20, 20, 20 }, max);
}

test "STL: an engine that can't tessellate yet is an error, not an empty file" {
    const kernel = @import("../../kernel/kernel.zig");
    const part = kernel.cube(&.{ .engine = .brep_native }, 10, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destruct(part);
    try testing.expectError(error.EngineCannotTessellate, stl.buildStlBuffer(testing.allocator, part));
}

test "STL: an empty solid is an error, not a file with no triangles" {
    // It exported as an 84-byte file that KupCAD's own importer rejects, with exit 0.
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    const inner = try vm.dag_builder.addCube(1, 1, 1, false);
    const outer = try vm.dag_builder.addCube(2, 2, 2, false);
    const handle = try dag_evaluator.evaluateDAG(&vm, try vm.dag_builder.addBinary(.difference_op, inner, outer));
    try testing.expectError(error.NoGeometry, stl.buildStlBuffer(testing.allocator, handle));
}

test "STL: every exported solid reads back closed and consistently oriented" {
    // The reader welds equal positions, so a closed solid's triangles share their edges.
    const api = @import("../../api.zig");
    const mesh_check = @import("../../kernel/mesh_check.zig");
    for ([_][]const u8{
        "cube(10)",
        "sphere(5)",
        "cylinder(r: 3, h: 8)",
        "cube(10) - cylinder(r: 3, h: 30).translate(x: 5, y: 5, z: -10)",
        "cube(10) + sphere(4).translate(x: 10, y: 5, z: 5)",
        "[cube(2), sphere(1).translate(x: 5)]",
    }) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        const bytes = try api.buildModel(testing.allocator, testing.io, source, .{ .format = .stl });
        defer testing.allocator.free(bytes);
        var mesh = try parse(bytes);
        defer mesh.deinit(testing.allocator);
        try mesh_check.expectClosed(testing.allocator, mesh.faces);
    }
}

test "STL: a vertex that is NaN or infinite is an error, in either format" {
    // The parser took any float, and the mesh it made crashed the build where the DAG
    // checks its points (found by the importer fuzz test).
    try expectRefused(asciiStl(&.{"vertex nan 0 0\nvertex 1 0 0\nvertex 0 1 0\n"}), "line 4: the vertex coordinate \"nan\" isn't finite as the 32-bit float STL holds");
    try expectRefused(asciiStl(&.{"vertex 0 0 0\nvertex 1e39 0 0\nvertex 0 1 0\n"}), "line 5: the vertex coordinate \"1e39\" isn't finite as the 32-bit float STL holds");
    const binary = binaryStl("", &.{.{ .{ 0, 0, 0 }, .{ std.math.inf(f32), 0, 0 }, .{ 0, 1, 0 } }}, "");
    try expectRefused(&binary, "triangle 1: a vertex coordinate isn't finite");
}

test "STL: an ASCII file is read facet by facet, and what doesn't read names its line" {
    // A vertex that wasn't a number was skipped, every corner after it shifting into the next
    // triangle: `1O` imported "mended", and with repair: false failed on an edge from
    // [0, 0, 0] to [0, 0, 0].
    try expectRefused(asciiStl(&.{ "vertex 0 0 0\nvertex 10 0 0\nvertex 0 10 0\n", "vertex 0 0 0\nvertex 10 0 1O\nvertex 0 0 10\n" }), "line 12: the vertex coordinate \"1O\" isn't a number");
    const cases = [_]struct { text: []const u8, message: []const u8 }{
        .{ .text = asciiStl(&.{"vertex 0 0 0\nvertex 1 0 0\n"}), .message = "line 7: the facet on line 2 has 2 vertices: an STL facet is a triangle" },
        .{ .text = asciiStl(&.{"vertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nvertex 1 1 0\n"}), .message = "line 7: the facet on line 2 has more than 3 vertices: an STL facet is a triangle" },
        .{ .text = asciiStl(&.{"vertex 0 0\nvertex 1 0 0\nvertex 0 1 0\n"}), .message = "line 4: a vertex needs its x, y and z" },
        .{ .text = asciiStl(&.{"vertex 0 0 0 1\nvertex 1 0 0\nvertex 0 1 0\n"}), .message = "line 4: a vertex has more than its x, y and z: \"1\"" },
        .{ .text = "solid t\nvertex 0 0 0\n", .message = "line 2: a vertex outside a facet" },
        .{ .text = "solid t\nfacet normal 0 0 1\nfacet normal 0 0 1\n", .message = "line 3: a facet starts before the one on line 2 ends (endfacet)" },
        .{ .text = "solid t\nfacet normal 0 0 1\n", .message = "the facet on line 2 doesn't end (endfacet)" },
        .{ .text = "solid t\nendfacet\n", .message = "line 2: an endfacet ends no facet" },
        .{ .text = "solid t\ncolor 1 0 0\n", .message = "line 2: \"color\" isn't a word of ASCII STL" },
        .{ .text = "solid empty\nendsolid empty\n", .message = "it has no facet" },
        .{ .text = "not an stl at all", .message = "it isn't STL: too short for a binary STL (84 bytes at least) and not ASCII STL (which starts with \"solid\")" },
    };
    for (cases) |case| {
        errdefer std.debug.print("stl: {s}\n", .{case.text});
        try expectRefused(case.text, case.message);
    }
    // Windows line ends and a byte order mark are read past
    var mesh = try parse("\xEF\xBB\xBFsolid t\r\nfacet normal 0 0 1\r\nouter loop\r\nvertex 0 0 0\r\nvertex 1 0 0\r\nvertex 0 1 0\r\nendloop\r\nendfacet\r\nendsolid t\r\n");
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), mesh.faces.len);
}

test "STL: a binary file is its counted triangles, past bytes after them and a header that says solid" {
    const triangle = [3][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    // Some writers start the header with "solid", as an ASCII file does
    const solid = binaryStl("solid part", &.{triangle}, "");
    // ... and some leave bytes after the last record
    const trailing = binaryStl("", &.{triangle}, "\x00\x01extra");
    for ([_][]const u8{ &solid, &trailing }) |bytes| {
        var mesh = try parse(bytes);
        defer mesh.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 3), mesh.points.len);
        try testing.expectEqual([3]u32{ 0, 1, 2 }, mesh.faces[0]);
    }
    try expectRefused(&binaryStl("", &.{}, ""), "it is a binary STL of no triangles");
}

test "STL: a corner written as -0 is the same point as one written as 0" {
    // Keyed on its bits, `-0 -0 0` was a point of its own: a closed tetrahedron had a hole,
    // "mended" with a warning, and refused with repair: false.
    const tetrahedron = asciiStl(&.{
        "vertex 0 0 0\nvertex 0 10 0\nvertex 10 0 0\n",
        "vertex -0 -0 0\nvertex 10 0 0\nvertex 0 0 10\n",
        "vertex 0 0 0\nvertex 0 0 10\nvertex 0 10 0\n",
        "vertex 10 0 0\nvertex 0 10 0\nvertex 0 0 10\n",
    });
    var mesh = try parse(tetrahedron);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), mesh.points.len);
    const mesh_repair = @import("../../core/mesh_repair.zig");
    try testing.expect((try mesh_repair.check(testing.allocator, .{ .points = mesh.points, .faces = mesh.faces })).closed());
}
