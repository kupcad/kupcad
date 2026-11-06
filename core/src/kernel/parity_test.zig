//! Engine parity: a script both engines run must mean the same on each. Every primitive and
//! keyword the B-Rep engine takes builds the same box on it as on Manifold, and an argument
//! one engine refuses the other refuses with the same error. B-Rep measures nothing yet, so
//! its box is read from its STEP export: the vertices, and each circle's exact extent.

const std = @import("std");
const testing = std.testing;
const api = @import("../api.zig");
const kernel = @import("kernel.zig");
const geom = @import("../core/geometry_handle.zig");
const support = @import("../test_support.zig");
const Vfs = @import("../vfs/vfs.zig").Vfs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

/// STEP writes coordinates with six decimals.
/// The STEP export writes every number at full precision; the box read from it is exact to
/// floating point.
const STEP_TOLERANCE = 1e-9;
/// What the B-Rep scripts start with.
const BREP_CONFIG = "CAD.config(engine: :brep)\n";

/// Shapes both engines build. A cylinder's sides are a multiple of 4, so Manifold's polygon
/// reaches the circle's extremes on both axes (B-Rep's circle is exact).
const SHAPES = [_][]const u8{
    "cube(2)",
    "cube(1, 2, 3)",
    "cube(1, 2)",
    "cube(x: 1, y: 2, z: 3)",
    "cube(size: 3)",
    "cube(2, center: true)",
    "cube(1, 2, 3, center: true)",
    "cylinder(r: 1, h: 3, segments: 64)",
    "cylinder(d: 2, h: 3, segments: 64)",
    "cylinder(r: 1.5, h: 2, center: true, segments: 64)",
    "cylinder(r1: 1, r2: 1, h: 2, segments: 64)",
    "cylinder(r: 1, segments: 64)",
    "cylinder(h: 2, segments: 64)",
    "cylinder(2, d: 3, h: 1, segments: 64)",
};

/// Arguments both engines must refuse, with the same error.
const REFUSED = [_][]const u8{
    "cube(-1)",
    "cube(0, 1, 1)",
    "cube(Number::INFINITY)",
    "cube(2, center: 1)",
    "cube(2, sise: 3)",
    "cylinder(r: -1, h: 2)",
    "cylinder(r: 1, d: 2, h: 2)",
    "cube(size: 3, x: 1)",
    "cylinder(r: 1, h: 2, segments: 2049)",
    "polygon([[0, 0], [4, 0], [4, 3]], round_r: -1)",
    "polygon([[0, 0], [4, 0], [4, 3]], round_r: 5)",
    "polyline([[0, 0], [4, 0], [4, 3]]).chamfer(4)",
};

test "parity: each shape both engines build has the same box on each" {
    for (SHAPES) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        const mesh_box = try manifoldBox(source);
        const brep_box = try brepBox(source);
        for (0..3) |k| {
            try testing.expectApproxEqAbs(mesh_box.min[k], brep_box.min[k], STEP_TOLERANCE);
            try testing.expectApproxEqAbs(mesh_box.max[k], brep_box.max[k], STEP_TOLERANCE);
        }
    }
}

test "parity: an argument one engine refuses, the other refuses the same way" {
    inline for (REFUSED) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        const mesh_script = comptime support.rescued(source);
        const brep_script = comptime BREP_CONFIG ++ support.rescued(source);
        var buf: [256]u8 = undefined;
        const on_mesh = try rescuedMessage(mesh_script, &buf);
        try testing.expect(!std.mem.eql(u8, on_mesh, "no error"));
        var brep_buf: [256]u8 = undefined;
        try testing.expectEqualStrings(on_mesh, try rescuedMessage(brep_script, &brep_buf));
    }
}

test "parity: a mesh wound inward is the solid it bounds, on either engine" {
    // Manifold turned an inward mesh around and the B-Rep engine kept it, inside out (its
    // STEP planes faced into it): the mesh is turned once, before either engine. A script's
    // polyhedron and an imported mesh wound inward are the one wound outward, its points in
    // the same order (the STL's, as they first appear), on both.
    const outward = "polyhedron([[0, 0, 0], [10, 0, 0], [0, 10, 0], [0, 0, 10]], [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]])";
    const inward = [_][]const u8{
        "polyhedron([[0, 0, 0], [10, 0, 0], [0, 10, 0], [0, 0, 10]], [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]])",
        "import_stl(\"in.stl\", repair: false)",
    };
    var files = MemoryVfs.init(testing.allocator);
    defer files.deinit();
    try files.vfs().writeFile("in.stl", tetrahedronStl(&.{ .{ 0, 1, 2 }, .{ 0, 3, 1 }, .{ 0, 2, 3 }, .{ 1, 3, 2 } }));
    const expected = try stepOf(outward, files.vfs());
    defer testing.allocator.free(expected);
    for (inward) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        var vm = try support.initVm();
        defer vm.deinit();
        vm.vfs = files.vfs();
        var script: std.Io.Writer.Allocating = .init(testing.allocator);
        defer script.deinit();
        try script.writer.print("r = ({s}).volume", .{source});
        try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
        try testing.expectApproxEqAbs(@as(f64, 1000.0 / 6.0), vm.globals.get("r").?.asNumber(), 1e-9);
        const step = try stepOf(source, files.vfs());
        defer testing.allocator.free(step);
        try testing.expectEqualStrings(expected, step);
    }
}

test "parity: coordinates past what the kernel computes with are refused alike, on either engine" {
    // An arc of radius 1e300 crashed Manifold's sketch boolean; past 1e100 the engines'
    // products of coordinates overflow a double
    const cases = [_][]const u8{
        "cube(1e101)",
        "cylinder(r: 1, h: 1e300)",
        "polyhedron([[0, 0, 0], [1e101, 0, 0], [0, 1, 0], [0, 0, 1]], [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]])",
    };
    for (cases) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        var messages: [2][]const u8 = undefined;
        for ([_][]const u8{ "", BREP_CONFIG }, [_]api.ExportFormat{ .stl, .step }, &messages) |prelude, format, *message| {
            const script = try std.mem.concat(testing.allocator, u8, &.{ prelude, source });
            defer testing.allocator.free(script);
            var diag: api.BuildDiagnostic = .{};
            errdefer diag.deinit(testing.allocator);
            try testing.expectError(error.RuntimeError, api.buildModel(testing.allocator, testing.io, script, .{ .format = format, .diagnostic = &diag }));
            message.* = diag.message.?;
        }
        defer for (messages) |message| testing.allocator.free(message);
        try testing.expect(std.mem.endsWith(u8, messages[0], ": a coordinate reaches past 1e100 mm from the origin, the most the geometry kernel computes with"));
        try testing.expectEqualStrings(messages[0], messages[1]);
    }
}

/// The STEP file of `source` built on the B-Rep engine, reading `files`.
fn stepOf(source: []const u8, files: Vfs) ![]const u8 {
    const brep = try std.mem.concat(testing.allocator, u8, &.{ BREP_CONFIG, source });
    defer testing.allocator.free(brep);
    return api.buildModel(testing.allocator, testing.io, brep, .{ .format = .step, .vfs = files });
}

/// An ASCII STL of the tetrahedron of corners (0, 0, 0) and 10 along each axis, of `faces`.
fn tetrahedronStl(comptime faces: []const [3]u8) []const u8 {
    const corners = [_][]const u8{ "0 0 0", "10 0 0", "0 10 0", "0 0 10" };
    comptime var text: []const u8 = "solid t\n";
    inline for (faces) |f| {
        text = text ++ "facet normal 0 0 0\nouter loop\n";
        inline for (f) |corner| text = text ++ "vertex " ++ corners[corner] ++ "\n";
        text = text ++ "endloop\nendfacet\n";
    }
    return text ++ "endsolid t\n";
}

/// What the script leaves in `r`, a string, copied into `buf`.
fn rescuedMessage(source: []const u8, buf: []u8) ![]const u8 {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, source));
    const r = vm.globals.get("r") orelse return error.MissingGlobal;
    const text = r.asString().chars;
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

fn manifoldBox(source: []const u8) !geom.BoundingBox {
    var vm = try support.initVm();
    defer vm.deinit();
    var script: std.Io.Writer.Allocating = .init(testing.allocator);
    defer script.deinit();
    try script.writer.print("r = {s}", .{source});
    try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
    const handle = try vm.ensureConcrete(vm.globals.get("r") orelse return error.MissingGlobal);
    try testing.expectEqual(geom.EngineType.manifold, handle.engine);
    return kernel.boundingBox(handle) orelse error.NoBounds;
}

/// The box of the B-Rep solid the script builds, read from its STEP export.
fn brepBox(source: []const u8) !geom.BoundingBox {
    const step = try api.buildModel(testing.allocator, testing.io, source, .{ .format = .step });
    defer testing.allocator.free(step);
    return stepBox(testing.allocator, step);
}

/// The bounds of a STEP file's vertices and circles. A circle's extent along an axis is
/// its radius times the sine of the angle between that axis and its normal.
fn stepBox(allocator: std.mem.Allocator, step: []const u8) !geom.BoundingBox {
    var entities: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    defer entities.deinit(allocator);
    var lines = std.mem.splitScalar(u8, step, '\n');
    while (lines.next()) |line| {
        if (line.len < 2 or line[0] != '#') continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        try entities.put(allocator, try std.fmt.parseInt(u32, line[1..eq], 10), line[eq + 1 ..]);
    }

    var box: geom.BoundingBox = .{ .min = @splat(std.math.inf(f64)), .max = @splat(-std.math.inf(f64)) };
    var it = entities.valueIterator();
    while (it.next()) |body| {
        if (std.mem.startsWith(u8, body.*, "VERTEX_POINT(")) {
            const p = try point(&entities, try refs(body.*, 0));
            for (0..3) |k| {
                box.min[k] = @min(box.min[k], p[k]);
                box.max[k] = @max(box.max[k], p[k]);
            }
        } else if (std.mem.startsWith(u8, body.*, "CIRCLE(")) {
            const placement = entities.get(try refs(body.*, 0)) orelse return error.BadStep;
            const center = try point(&entities, try refs(placement, 0));
            const normal = try numbers(entities.get(try refs(placement, 1)) orelse return error.BadStep);
            const close = std.mem.findScalarLast(u8, body.*, ')') orelse return error.BadStep;
            const comma = std.mem.findScalarLast(u8, body.*[0..close], ',') orelse return error.BadStep;
            const radius = try std.fmt.parseFloat(f64, body.*[comma + 1 .. close]);
            for (0..3) |k| {
                const reach = radius * @sqrt(@max(0, 1 - normal[k] * normal[k]));
                box.min[k] = @min(box.min[k], center[k] - reach);
                box.max[k] = @max(box.max[k], center[k] + reach);
            }
        }
    }
    if (box.min[0] > box.max[0]) return error.NoBounds;
    return box;
}

/// The `n`th `#id` an entity's body names.
fn refs(body: []const u8, n: usize) !u32 {
    var rest = body;
    var seen: usize = 0;
    while (std.mem.findScalar(u8, rest, '#')) |at| {
        var end = at + 1;
        while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
        if (seen == n) return std.fmt.parseInt(u32, rest[at + 1 .. end], 10);
        seen += 1;
        rest = rest[end..];
    }
    return error.BadStep;
}

fn point(entities: *const std.AutoHashMapUnmanaged(u32, []const u8), id: u32) ![3]f64 {
    return numbers(entities.get(id) orelse return error.BadStep);
}

/// The three numbers of a CARTESIAN_POINT or DIRECTION: `NAME('',(x,y,z));`.
fn numbers(body: []const u8) ![3]f64 {
    const open = std.mem.findScalarLast(u8, body, '(') orelse return error.BadStep;
    const close = std.mem.findScalarPos(u8, body, open, ')') orelse return error.BadStep;
    var out: [3]f64 = undefined;
    var parts = std.mem.splitScalar(u8, body[open + 1 .. close], ',');
    for (&out) |*v| v.* = try std.fmt.parseFloat(f64, parts.next() orelse return error.BadStep);
    return out;
}

test "parity: a STEP box counts every vertex and each circle's full extent" {
    // A circle of radius 2 about Z at (1, 0, 5), and one vertex below it.
    const step =
        \\#1=CARTESIAN_POINT('',(1.000000,0.000000,5.000000));
        \\#2=DIRECTION('',(0.000000,0.000000,1.000000));
        \\#3=DIRECTION('',(1.000000,0.000000,0.000000));
        \\#4=AXIS2_PLACEMENT_3D('',#1,#2,#3);
        \\#5=CIRCLE('',#4,2.000000);
        \\#6=CARTESIAN_POINT('',(0.000000,0.000000,-1.000000));
        \\#7=VERTEX_POINT('',#6);
    ;
    const box = try stepBox(testing.allocator, step);
    try testing.expectEqual([3]f64{ -1, -2, -1 }, box.min);
    try testing.expectEqual([3]f64{ 3, 2, 5 }, box.max);
}
