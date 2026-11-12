//! Engine parity: a script both engines run must mean the same on each. Every primitive and
//! keyword the B-Rep engine takes builds the same box on it as on Manifold, and an argument
//! one engine refuses the other refuses with the same error. The B-Rep box is the kernel's
//! (its driver bounds every face by its surface's extremes); a STEP export's box, from its
//! vertices and circles, is checked against it for the shapes it can bound.

const std = @import("std");
const testing = std.testing;
const api = @import("../api.zig");
const kernel = @import("kernel.zig");
const geom = @import("../core/geometry_handle.zig");
const support = @import("../test_support.zig");
const Vfs = @import("../vfs/vfs.zig").Vfs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

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
    // The exact sphere and cone (M1); the mesh sphere has vertices on every axis
    "sphere(r: 2)",
    "sphere(d: 3, segments: 64)",
    "cylinder(r1: 2, r2: 1, h: 3, segments: 64)",
    "cylinder(r1: 1, r2: 2, h: 3, center: true, segments: 64)",
    "sphere(r: 2).translate(1, 2, 3).scale(2)",
    "cylinder(r1: 2, r2: 1, h: 3, segments: 64).rotate(x: 90)",
    // Extrusions (M1): planes and cylinders from the sketches
    "square(10).extrude(5)",
    "square(10, 4, center: true).extrude(3)",
    "circle(r: 2, segments: 64).extrude(3)",
    "polygon([[0, 0], [4, 0], [4, 3], [1, 5]]).extrude(2)",
    "square(10).translate(5, 0).extrude(1)",
    "square(10).extrude(5).translate(1, 2, 3).rotate(z: 90)",
    "regular_polygon(6, r: 5).extrude(2)",
    // Sketch booleans (M2), extruded: a plate with a hole, a union of two squares, the
    // lens of two circles, a difference that leaves two pieces
    "(square(10) - square(4).translate(3, 3)).extrude(2)",
    "(square(10) + square(10).translate(5, 5)).extrude(1)",
    "(square(4, center: true) & circle(r: 3, segments: 64)).extrude(1)",
    "(square(10) - square(2, 20).translate(4, -5)).extrude(1)",
    "(square(10) - circle(r: 2, segments: 64).translate(5, 5)).extrude(3)",
    // Offsets (M2), extruded: grown round (arcs at the corners), grown mitered, shrunk
    "square(10).offset(2).extrude(1)",
    "square(10).offset(2, join: :miter).extrude(1)",
    "square(10).offset(-2).extrude(1)",
    "(square(10) - circle(r: 2, segments: 64).translate(5, 5)).offset(1).extrude(1)",
    // Sweeps along one segment (M2, through the profile's outline): a line extrudes, an arc revolves
    "square(2).sweep(line([0, 0], [10, 0]))",
    "square(2).sweep(arc(center: [10, 0], r: 10, start: 180, sweep: 90), segments: 64)",
    // A profile across the axis: both engines cut it there and turn its part at x ≥ 0
    "square(4, center: true).revolve(segments: 64)",
    // Text (M2): its glyphs' chords filled by the even-odd rule on both engines, so exact
    "text(\"Hi\", size: 10).extrude(2)",
    // The hull of sketches (M2), of polygons: one with arcs is refused (`curved_hull`)
    "square(10).hull(square(4).translate(15, 5)).extrude(1)",
    // Revolutions (M1): the profile stood up, x the radius; the mesh engine's slices at
    // every quarter turn, where the extremes are (segments a multiple of 4)
    "square(4).revolve(segments: 64)",
    "square(2).translate(1, 0).revolve(deg: 90, segments: 64)",
    "square(2).translate(1, 0).revolve(deg: 270, segments: 64)",
    "square(2).translate(1, 0).revolve(deg: -90, segments: 64)",
    "polygon([[0, 0], [2, 0], [0, 3]]).revolve(segments: 64)",
    "circle(r: 1, segments: 64).translate(3, 0).revolve(segments: 64)",
    "square(2).translate(1, 0).revolve(segments: 64).translate(1, 2, 3).rotate(x: 90)",
    // Moves, turns, scales and mirrors (M0): the matrix is the images of the axes, then
    // the translation; a cylinder turned a quarter keeps its extremes on the axes
    "cube(2).translate(1, 2, 3)",
    "cube(1, 2, 3).translate(x: -1)",
    "cube(2).rotate(0, 0, 90)",
    "cube(2).rotate(30, 40, 50)",
    "cube(2).rotate(45)",
    "cube(2).scale(2)",
    "cube(1, 2, 3).scale(1, 2, 3)",
    "cube(2).mirror(1, 0, 0)",
    "cube(2).mirror([1, 1, 0])",
    "cube(2).transform([0, 1, 0, -1, 0, 0, 0, 0, 1, 1, 2, 3])",
    "cube(2).translate(1, 0, 0).rotate(z: 90).scale(2).mirror(0, 1, 0)",
    "cylinder(r: 1, h: 3, segments: 64).translate(1, 2, 3)",
    "cylinder(r: 1, h: 3, segments: 64).rotate(x: 90)",
    "cylinder(r: 1, h: 3, segments: 64).scale(2)",
    "cylinder(r: 1, h: 3, segments: 64).mirror(0, 0, 1)",
    "polyhedron([[0, 0, 0], [10, 0, 0], [0, 10, 0], [0, 0, 10]], [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]]).rotate(10, 20, 30).translate(-1, -2, -3)",
    // Sketches with arcs from the graph's leaves: the exact engine keeps the arcs, the
    // mesh engine chords them with their ends on the axes, so the boxes agree
    "square(4, round_r: 1, segments: 64).extrude(2)",
    "cube(3, round_r: 0.5, segments: 64)",
    "line([0, 0], [8, 0]).arc_to([10, 2], r: 2).line_to([10, 10]).line_to([0, 10]).close.extrude(2)",
    "(line([0, 0], [10, 0]) + arc(center: [10, 5], r: 5, start: -90, sweep: 180) + polyline([[10, 10], [0, 10]])).close.extrude(3)",
    // Booleans of solids with flat faces (M4): at a corner, a void, a chain, a hole through
    // a turned slab; cuts by a plane, level and slanted
    "cube(2) + cube(2).translate(1, 1, 1)",
    "cube(2) - cube(2).translate(1, 1, 1)",
    "cube(2) & cube(2).translate(1, 1, 1)",
    "cube(4) - cube(2).translate(1, 1, 1)",
    "cube(2) + cube(2).translate(1, 0, 0) + cube(2).translate(2, 0, 0)",
    "(square(10).extrude(5) - cube(2, 2, 7).translate(4, 4, -1)).rotate(z: 30)",
    "polyhedron([[0, 0, 0], [10, 0, 0], [0, 10, 0], [0, 0, 10]], [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]]) - cube(3)",
    "cube(4).trim_by_plane(0, 0, 1, 1)",
    "cube(4).rotate(30, 40, 50).trim_by_plane(1, 1, 0, 1)",
};

/// What the B-Rep engine refuses and the mesh engine builds: a non-uniform scale of a
/// curved part has no exact surfaces (architecture D20), so it is refused rather than
/// approximated; the mesh engine, which has no exact surfaces to keep, scales its mesh.
/// And booleans of curved solids, until Locus's M5.
const BREP_REFUSES = [_][]const u8{
    "cylinder(r: 1, h: 3, segments: 64).scale(1, 2, 1)",
    "cylinder(r: 1, h: 3, segments: 64).transform([2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])",
    // A boolean or a plane's cut of a curved solid waits for M5 (`curved_boolean`)
    "cube(2) - cylinder(r: 0.5, h: 3, segments: 64)",
    "cylinder(r: 1, h: 3, segments: 64).trim_by_plane(0, 0, 1, 1)",
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
    // M3's: a section, the queries, a material
    "cube(10).slice(\"a\")",
    "cube(10).slice(Number::NAN)",
    "cube(10).slice(Number::INFINITY)",
    "cube(10).contains?([1, 2])",
    "cube(10).contains?(\"a\")",
    "cube(10).ray_cast([0, 0, 0], [0, 0, 0])",
    "cube(10).ray_cast([0, 0], [1, 1, 1])",
    "cube(10).min_gap(cube(1), -1)",
    "cube(10).min_gap(square(1))",
    "cube(10).material(color: \"red\")",
    "cube(10).material(alpha: 2)",
};

test "parity: each shape both engines build has the same box on each" {
    for (SHAPES) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        const mesh_box = try boxOn(.manifold, source);
        const brep_box = try boxOn(.brep_native, source);
        for (0..3) |k| {
            try testing.expectApproxEqAbs(mesh_box.min[k], brep_box.min[k], STEP_TOLERANCE);
            try testing.expectApproxEqAbs(mesh_box.max[k], brep_box.max[k], STEP_TOLERANCE);
        }
    }
}

/// Whether a STEP export's vertices and whole circles reach the solid's extent: not a
/// sphere's (its extent is in no vertex and not in its one meridian circle), and not a
/// partial revolution's (a sweep along an arc is one), nor a sketch intersection's (their
/// arcs are written as whole circles, which reach further).
fn stepBoxReaches(source: []const u8) bool {
    for ([_][]const u8{ "sphere", "deg:", "arc(", "&" }) |word| if (std.mem.indexOf(u8, source, word) != null) return false;
    return true;
}

test "parity: a STEP export's vertices and circles bound what the kernel bounds, for the shapes they reach" {
    for (SHAPES) |source| {
        if (!stepBoxReaches(source)) continue;
        errdefer std.debug.print("script: {s}\n", .{source});
        const brep_box = try boxOn(.brep_native, source);
        const step_box = try stepBoxOf(source);
        for (0..3) |k| {
            try testing.expectApproxEqAbs(brep_box.min[k], step_box.min[k], STEP_TOLERANCE);
            try testing.expectApproxEqAbs(brep_box.max[k], step_box.max[k], STEP_TOLERANCE);
        }
    }
}

/// How far a mesh's volume may fall short of the exact one: nothing for a polyhedral
/// shape, and for a curved one the chords' share. A circle of n segments loses
/// 1 − (n/2π) sin(2π/n) of its area (0.16% at 64); a sphere's mesh is coarser than that.
/// Null for a curved shape at the mesh engine's default resolution, which depends on the
/// size and is no bound this test can state.
fn volumeBound(source: []const u8) ?f64 {
    const curved = for ([_][]const u8{ "cylinder", "circle", "sphere", "revolve", "offset(", "arc(", "arc_to(", "round_r" }) |word| {
        if (std.mem.indexOf(u8, source, word) != null) break true;
    } else false;
    if (!curved) return 1e-9;
    // A round offset's arcs have the mesh engine's default segments, few at this size
    if (std.mem.indexOf(u8, source, "offset(") != null) return if (std.mem.indexOf(u8, source, "circle") != null) null else 2e-2;
    return if (std.mem.indexOf(u8, source, "segments: 64") != null) 1e-2 else null;
}

test "parity: each shape's volume agrees on both engines within the chordal bound" {
    for (SHAPES) |source| {
        const bound = volumeBound(source) orelse continue;
        errdefer std.debug.print("script: {s}\n", .{source});
        // A mesh falls short of a convex curve and reaches past a concave one (a round
        // hole's chords leave more plate), either way within the chords' share
        const mesh = try volumeOn(.manifold, source);
        const exact = try volumeOn(.brep_native, source);
        try testing.expectApproxEqRel(exact, mesh, bound);
    }
}

/// A solid on the B-Rep engine and what its volume must be under a change of it.
const BREP_INVARIANTS = [_]struct { base: []const u8, changed: []const u8, factor: f64 }{
    .{ .base = "cylinder(r: 2, h: 5, segments: 64)", .changed = "cylinder(r: 2, h: 5, segments: 64).translate(3, -2, 9).rotate(37, 11, 5)", .factor = 1 },
    .{ .base = "sphere(r: 2)", .changed = "sphere(r: 2).mirror([1, 1, 0])", .factor = 1 },
    .{ .base = "square(2, 3).translate(1, 0).revolve(segments: 64)", .changed = "square(2, 3).translate(1, 0).revolve(segments: 64).scale(2)", .factor = 8 },
    .{ .base = "circle(r: 2, segments: 64).extrude(3)", .changed = "circle(r: 2, segments: 64).extrude(3).rotate(x: 90).translate(z: 4)", .factor = 1 },
    .{ .base = "cylinder(r1: 2, r2: 1, h: 3, segments: 64)", .changed = "cylinder(r1: 2, r2: 1, h: 3, segments: 64).mirror(0, 0, 1)", .factor = 1 },
};

test "invariants on the B-Rep engine: a move or a mirror keeps the volume exactly, a scale cubes it" {
    for (BREP_INVARIANTS) |case| {
        errdefer std.debug.print("scripts: {s} | {s}\n", .{ case.base, case.changed });
        const base = try volumeOn(.brep_native, case.base);
        const changed = try volumeOn(.brep_native, case.changed);
        try testing.expectApproxEqRel(base * case.factor, changed, 1e-9);
    }
}

test "parity: a non-uniform scale of a curved part, and a boolean of one, are refused on the B-Rep engine and built on the mesh engine" {
    for (BREP_REFUSES) |source| {
        errdefer std.debug.print("script: {s}\n", .{source});
        _ = try boxOn(.manifold, source);
        try testing.expectError(error.RuntimeError, stepBoxOf(source));
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

/// The kernel's box of what `source` builds on `engine`.
fn boxOn(engine: geom.EngineType, source: []const u8) !geom.BoundingBox {
    var vm = try support.initVm();
    defer vm.deinit();
    var script: std.Io.Writer.Allocating = .init(testing.allocator);
    defer script.deinit();
    try script.writer.print("{s}r = {s}", .{ if (engine == .brep_native) BREP_CONFIG else "", source });
    try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
    const handle = try vm.ensureConcrete(vm.globals.get("r") orelse return error.MissingGlobal);
    try testing.expectEqual(engine, handle.engine);
    return kernel.boundingBox(handle) orelse error.NoBounds;
}

/// The vertex and triangle counts of the mesh of what `source` builds on `engine`.
fn meshCountsOn(engine: geom.EngineType, source: []const u8) ![2]usize {
    var vm = try support.initVm();
    defer vm.deinit();
    var script: std.Io.Writer.Allocating = .init(testing.allocator);
    defer script.deinit();
    try script.writer.print("{s}r = {s}", .{ if (engine == .brep_native) BREP_CONFIG else "", source });
    try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
    const handle = try vm.ensureConcrete(vm.globals.get("r") orelse return error.MissingGlobal);
    try testing.expectEqual(engine, handle.engine);
    const mesh = kernel.getMesh(testing.allocator, handle) orelse return error.NoMesh;
    defer testing.allocator.free(mesh.vert_props);
    defer testing.allocator.free(mesh.tri_verts);
    return .{ mesh.vert_props.len / mesh.num_prop, mesh.tri_verts.len / 3 };
}

test "parity: a cylinder's and a cone's meshes have the vertices and triangles on both engines (the circle grid), a cube's and a rounded cube's too" {
    for ([_][]const u8{
        "cube(10)",
        "cylinder(r: 5, h: 15)",
        // A corner radius whose circle gets 8 segments, a multiple of four: each quarter
        // arc then has the same grid points on both engines
        "cube(10, round_r: 2.5).translate(1, 2, 3)",
        // Not here: `segments:` is the mesh engine's drawing override, which the exact
        // engine ignores for the resolution's grid, as documented; the mesh engine cuts
        // both caps of a frustum with the larger one's count and each corner of a rounded
        // square with a share of its circle's count, where Locus cuts every circle on the
        // grid its own radius gets and an arc onto that grid (the documented rule), so
        // `cylinder(r1:, r2:)` and `round_r: 2` (7 a turn) agree in volume (above) but
        // not in counts
    }) |source| {
        errdefer std.debug.print("source: {s}\n", .{source});
        const mesh_engine = try meshCountsOn(.manifold, source);
        const brep = try meshCountsOn(.brep_native, source);
        try testing.expectEqual(mesh_engine[0], brep[0]);
        try testing.expectEqual(mesh_engine[1], brep[1]);
    }
}

/// The Number or the Array of Numbers `expression` evaluates to on `engine`, after
/// `setup` (statements building the shapes).
fn numbersOn(engine: geom.EngineType, setup: []const u8, expression: []const u8, out: []f64) ![]f64 {
    var vm = try support.initVm();
    defer vm.deinit();
    var script: std.Io.Writer.Allocating = .init(testing.allocator);
    defer script.deinit();
    try script.writer.print("{s}{s}\nr = {s}", .{ if (engine == .brep_native) BREP_CONFIG else "", setup, expression });
    try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
    const r = vm.globals.get("r") orelse return error.MissingGlobal;
    if (!r.isArray()) {
        out[0] = numberOf(r);
        return out[0..1];
    }
    const items = r.asArray().items.items;
    for (items, 0..) |item, i| out[i] = numberOf(item);
    return out[0..items.len];
}

/// A Number as itself, a Boolean as 1 or 0.
fn numberOf(v: anytype) f64 {
    if (v.isBool()) return if (v.asBool()) 1 else 0;
    return v.asNumber();
}

test "parity: contains?, ray_cast and min_gap agree on both engines, curved parts within the chordal bound" {
    const setup =
        \\b = cube(10)
        \\c = cylinder(r: 5, h: 10).translate(x: 30)
        \\s = sphere(r: 4).translate(y: 30)
        \\far = cube(2).translate(x: 60)
    ;
    // The cylinder's polygon at 16 a turn reaches 5·cos(π/16) = 4.904 between its corners
    const bound = 5 * (1 - @cos(std.math.pi / 16.0)) + 4 * (1 - @cos(std.math.pi / 13.0));
    const cases = [_]struct { expr: []const u8, slack: f64 }{
        .{ .expr = "[b.contains?([5, 5, 5]), b.contains?([10, 5, 5]), b.contains?([11, 5, 5]), b.contains?([-0.5, 5, 5])]", .slack = 0 },
        .{ .expr = "[c.contains?([30, 0, 5]), c.contains?([34.8, 0, 5]), c.contains?([35.5, 0, 5]), c.contains?([33.6, 3.6, 5])]", .slack = 0 },
        .{ .expr = "[s.contains?([0, 30, 0]), s.contains?([0, 30, 3.8]), s.contains?([0, 30, 4.5])]", .slack = 0 },
        // Through the box and the cylinder along x at y = 5 (the cylinder's axis level is
        // y = 0, so at y = 0: in at x = 25 and out at 35, its polygon's corners on the axis)
        .{ .expr = "b.ray_cast([-10, 5, 5], [50, 5, 5]).map { |h| [h[\"distance\"], h[\"crossing\"]] }.flatten", .slack = 0 },
        .{ .expr = "c.ray_cast([10, 0, 5], [50, 0, 5]).map { |h| [h[\"distance\"], h[\"crossing\"]] }.flatten", .slack = 0 },
        .{ .expr = "s.ray_cast([0, 30, -10], [0, 30, 10]).map { |h| h[\"crossing\"] }", .slack = 0 },
        .{ .expr = "b.min_gap(far)", .slack = 1e-9 },
        .{ .expr = "b.min_gap(c)", .slack = bound },
        .{ .expr = "s.min_gap(c)", .slack = bound },
        .{ .expr = "b.min_gap(far, 10)", .slack = 0 },
    };
    for (cases) |case| {
        errdefer std.debug.print("expression: {s}\n", .{case.expr});
        var mesh_buf: [32]f64 = undefined;
        var brep_buf: [32]f64 = undefined;
        const mesh_engine = try numbersOn(.manifold, setup, case.expr, &mesh_buf);
        const brep = try numbersOn(.brep_native, setup, case.expr, &brep_buf);
        try testing.expectEqual(mesh_engine.len, brep.len);
        for (mesh_engine, brep) |m, x| try testing.expectApproxEqAbs(m, x, case.slack + 1e-9);
    }
}

test "parity: a slice has the same area on both engines, the solid just above the plane, a circle's within the chordal bound" {
    const setup =
        \\b = cube(10, 4, 6)
        \\c = cylinder(r: 5, h: 10, segments: 64)
        \\lying = cylinder(r: 2, h: 10, segments: 64).rotate(x: 90)
    ;
    // A circle of 64 sides misses r² (π − 32 sin(2π/64)) of its disc
    const disc = 25 * (std.math.pi - 32 * @sin(2 * std.math.pi / 64.0));
    const cases = [_]struct { expr: []const u8, slack: f64 }{
        // Inside, on the bottom (its square), on the top and beside it (nothing)
        .{ .expr = "[b.slice(3).area, b.slice(0).area, b.slice(6).area, b.slice(7).area, b.slice(-1).area]", .slack = 0 },
        .{ .expr = "[c.slice(4).area, c.slice(0).area]", .slack = disc },
        .{ .expr = "c.slice(10).area", .slack = 0 },
        // Through the axis of a lying cylinder: a band as wide as its diameter (the polygon
        // has corners there); touching its top nothing
        .{ .expr = "[lying.slice(0).area, lying.slice(2).area]", .slack = 0 },
    };
    for (cases) |case| {
        errdefer std.debug.print("expression: {s}\n", .{case.expr});
        var mesh_buf: [8]f64 = undefined;
        var brep_buf: [8]f64 = undefined;
        const mesh_engine = try numbersOn(.manifold, setup, case.expr, &mesh_buf);
        const brep = try numbersOn(.brep_native, setup, case.expr, &brep_buf);
        try testing.expectEqual(mesh_engine.len, brep.len);
        for (mesh_engine, brep) |m, x| try testing.expectApproxEqAbs(m, x, case.slack + 1e-9);
    }
}

/// The kernel's volume of what `source` builds on `engine`.
fn volumeOn(engine: geom.EngineType, source: []const u8) !f64 {
    var vm = try support.initVm();
    defer vm.deinit();
    var script: std.Io.Writer.Allocating = .init(testing.allocator);
    defer script.deinit();
    try script.writer.print("{s}r = {s}", .{ if (engine == .brep_native) BREP_CONFIG else "", source });
    try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
    const handle = try vm.ensureConcrete(vm.globals.get("r") orelse return error.MissingGlobal);
    try testing.expectEqual(engine, handle.engine);
    return kernel.volume(handle);
}

/// The box of the B-Rep solid the script builds, read from its STEP export.
fn stepBoxOf(source: []const u8) !geom.BoundingBox {
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

/// The material slot of every vertex of the mesh `source` builds on `engine`, sorted and
/// without repeats, into `out`.
fn slotsOn(engine: geom.EngineType, source: []const u8, out: []u32) ![]u32 {
    var vm = try support.initVm();
    defer vm.deinit();
    var script: std.Io.Writer.Allocating = .init(testing.allocator);
    defer script.deinit();
    try script.writer.print("{s}r = {s}", .{ if (engine == .brep_native) BREP_CONFIG else "", source });
    try testing.expectEqual(.ok, try support.runOn(&vm, script.written()));
    const handle = try vm.ensureConcrete(vm.globals.get("r") orelse return error.MissingGlobal);
    try testing.expectEqual(engine, handle.engine);
    const mesh = kernel.getMesh(testing.allocator, handle) orelse return error.NoMesh;
    defer testing.allocator.free(mesh.vert_props);
    defer testing.allocator.free(mesh.tri_verts);
    var n: usize = 0;
    var v: usize = 0;
    while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
        const slot: u32 = if (mesh.num_prop < 4) kernel.DEFAULT_MATERIAL_SLOT else @intFromFloat(mesh.vert_props[v + 3]);
        if (std.mem.indexOfScalar(u32, out[0..n], slot) == null) {
            out[n] = slot;
            n += 1;
        }
    }
    std.mem.sort(u32, out[0..n], {}, std.sort.asc(u32));
    return out[0..n];
}

test "parity: a material is every vertex's on both engines, moved or not; none is the default" {
    for ([_]struct { source: []const u8, slots: []const u32 }{
        .{ .source = "cube(10)", .slots = &.{kernel.DEFAULT_MATERIAL_SLOT} },
        .{ .source = "cube(10).material(color: \"#ff0000\")", .slots = &.{kernel.materialSlot(0)} },
        .{ .source = "cylinder(r: 2, h: 3).material(color: \"#00ff00\").translate(5, 0, 0).rotate(x: 30)", .slots = &.{kernel.materialSlot(0)} },
        .{ .source = "sphere(2).material(color: \"#ff0000\").material(color: \"#0000ff\")", .slots = &.{kernel.materialSlot(1)} },
    }) |case| {
        errdefer std.debug.print("script: {s}\n", .{case.source});
        var mesh_buf: [8]u32 = undefined;
        var brep_buf: [8]u32 = undefined;
        try testing.expectEqualSlices(u32, case.slots, try slotsOn(.manifold, case.source, &mesh_buf));
        try testing.expectEqualSlices(u32, case.slots, try slotsOn(.brep_native, case.source, &brep_buf));
    }
}
