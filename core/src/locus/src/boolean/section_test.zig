//! Plane sections: a box at every kind of height (inside, on its bottom, on its top,
//! beside it); a cylinder, a sphere, a cone and a torus cut in exact circles and touched
//! (nothing); a cylinder lying down cut in lines and touched along its side; a plate with
//! a hole; a stepped solid of revolution at its step; a groove's floor (two faces rising
//! from one edge, which cancel); a tetrahedron by its corners; turned solids whose slices'
//! areas integrate to their volumes; two parts; a tab two zones wide, its end face a
//! side face no point of which is past the zone; and the refusals (a tilted cylinder's
//! ellipse, a free-form face, a sheet, a height that is not a number). Every section is
//! checked.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Affine = @import("../math/mat.zig").Affine;
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const Diagnostics = diagnostics.Diagnostics;
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const transform = @import("../construct/transform.zig");
const test_bodies = @import("../construct/test_bodies.zig");
const mass = @import("../measure/mass.zig");
const hull = @import("../construct/hull.zig");
const section = @import("section.zig");
const helpers = @import("pipeline_test.zig");
const degeneracy = @import("degeneracy_test.zig");
const sketch_query = @import("../sketch/query.zig");
const point_in_body = @import("../query/point_in_body.zig");
const FaceIndex = @import("../query/index.zig").FaceIndex;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;

const tol = tolerance.Tolerance.fromZone(1e-5);
const PI = std.math.pi;
/// Exact areas agree to rounding.
const EXACT = 1e-9;
/// The lines a tab runs between, out of a unit square below the upper one to x = 3 (find
/// cc's, 2026-11-22: a sheet with a strip 2e-5 wide, extruded): 2e-5 apart, two zones,
/// to rounding, so the trace across the tab's end face has its middle the zone from both
/// its edges, at the find's coordinates and others (their extrusion refused at the
/// tolerance since Option A); 1e-10 wider, made; and 3e-5 apart, past two zones.
const TAB_LINES = [_][2]f64{ .{ 4.99998, 5 }, .{ 0.99998, 1 }, .{ 6.99998, 7 }, .{ 4.99997, 4.99999 }, .{ 4.99996, 4.99998 }, .{ 4.99998, 5.00001 }, .{ 4.9999799999, 5 }, .{ 0.9999799999, 1 } };
/// How far the tabbed square is extruded, and the heights it is sliced at.
const TAB_EXTRUSION: f64 = 3;
const TAB_HEIGHTS = [_]f64{ 0, 0.5, 1.11, 1.5, 2.9 };
/// The slopes (degrees) of a wedge's face to the slicing plane under 30°, where a vertex
/// on the plane within the zone lies farther than the intersection tolerance from the
/// face's trace (its height over the sine), and how far that vertex is over the slicing
/// height (in zones, under it negative).
/// Find ea's shallow bottom (the solids oracle's slice on 9015ab26): a pentagonal prism to
/// z = 1 whose bottom rises along y at `SHALLOW_TILTS` (within the angular tolerance, at
/// most 1e-4 rad; past it, 0.02), its corner at `SHALLOW_CORNER` a zone's half under the
/// slicing height, on the plane by the zone and 0.05 from the bottom's trace there.
const SHALLOW_BOTTOM = [_]Vec2{ .{ 0, 0 }, .{ 1, 0 }, .{ 1.2, 0.55 }, .{ 1, 1 }, .{ 0, 1 } };
const SHALLOW_CORNER: usize = 2;
const SHALLOW_TILTS = [_]struct { slope: f64, refused: bool }{ .{ .slope = 1e-4, .refused = true }, .{ .slope = 6.3e-5, .refused = true }, .{ .slope = 0.02, .refused = false } };
const WEDGE_SLOPES = [_]f64{ 10, 20, 29 };
const WEDGE_RISES = [_]f64{ 0.4, 0.6, 0.9, -0.4, -0.6, -0.9 };
/// The height a wedge is sliced at.
const WEDGE_HEIGHT: f64 = 0.5;
/// Find ed (the solids oracle's slice on 42feb869, locus_solids), as the fuzzer drew it:
/// a plate 3 intersection tolerances thick about z = 4.5, less a hull whose top edge lies
/// in the plate's mid-plane across it, so the difference has a groove in the plate's
/// bottom up to a ridge at 4.5; sliced at 4.4999922, 7.8e-6 under the ridge, and a point
/// of the plate beside the groove.
const ED_PLATE = [2]Vec3{ .{ 1, 2, 4 - 3e-5 }, .{ 3, 3, 4 + 3e-5 } };
const ED_PLATE_MOVE: Vec3 = .{ 0, 0, 0.5 };
const ED_HULL = [_]Vec3{ .{ 1, 1, 1 }, .{ 3, 1, 0 }, .{ 1, 3, 3 }, .{ 2, 3, 4 }, .{ 4, 0, 0 }, .{ 1, 1, 4 } };
const ED_HULL_MOVE: Vec3 = .{ 0, 0.5, 0.5 };
const ED_HULL_NUDGE: Vec3 = .{ -5e-6, 0, 0 };
const ED_HEIGHT: f64 = 4.499992199999999;
const ED_POINT: Vec2 = .{ 1.42, 2.1299999999999994 };
/// The family about ed: a plate 6e-5 thick about z = 0, 2 by 1, less a prism whose ridge
/// lies in the plate's mid-plane, skewed across it, its walls falling at 45° and at 51°
/// (`RIDGE_FEET`, the feet's offsets in x a unit down), so that sliced under the ridge
/// within the zone the walls' traces lie at different distances from it; the depths under
/// the ridge it is sliced at (the find's 7.8e-6 among them) and a height over it; and the
/// moves in the plane (quarter turns, far out), each mirrored too.
const RIDGE_PLATE = [2]Vec3{ .{ 0, 0, -3e-5 }, .{ 2, 1, 3e-5 } };
const RIDGE_ENDS = [2]Vec3{ .{ 0.5, -1, 0 }, .{ 1, 2, 0 } };
const RIDGE_FEET = [2]f64{ -1, 0.8 };
const RIDGE_HEIGHTS = [_]f64{ -2e-6, -5e-6, -7.8e-6, -9.5e-6, 5e-6 };
const RIDGE_SHIFTS = [_]Vec3{ .{ 0, 0, 0 }, .{ 3e5, -2e5, 0 } };
/// Find ee (the solids oracle's slice on 4aaaef51, locus_solids), as the fuzzer drew it: a
/// plate 3 intersection tolerances thick, 1 square, its bottom at z = 1, united with a
/// plate 2.5 tolerances thick, 4 by 1, whose top lies 5e-6 over that bottom where the two
/// overlap, a strip 2e-3 wide; sliced at 0.99999385, 6.15e-6 under the upper's bottom and
/// 1.1e-5 under the lower's top, and a point of the lower plate only.
const EE_UPPER = [2]Vec3{ .{ 2, 2, 1 - 3e-5 }, .{ 3, 3, 1 + 3e-5 } };
const EE_UPPER_MOVES = [2]Vec3{ .{ 0, 0, 1e-5 }, .{ 2e-5, 2e-3, 2e-5 } };
const EE_LOWER = [2]Vec3{ .{ 0, 3, 1 - 2.5e-5 }, .{ 4, 4, 1 + 2.5e-5 } };
const EE_LOWER_NUDGE: Vec3 = .{ 0, 1.9999999943156583e-5, -2.000000005684342e-5 };
const EE_HEIGHT: f64 = 0.9999938499999641;
const EE_POINT: Vec2 = .{ 3.312, 3.024986239999971 };
/// The union of the two plates' footprints: the lower's 4, the upper's 1 less the
/// strip's 0.00198.
const EE_AREA: f64 = 4.99802;
/// The family about ee: a plate 5e-5 thick about z = 0, 4 by 1, and over it a plate 6e-5
/// thick, 1 by 1.002, overlapping it along a strip 2e-3 wide, its bottom `PARALLEL_OVERLAPS`
/// under the lower's top; sliced `PARALLEL_DEPTHS` under the upper's bottom (within the
/// zone of it, the lower's top past the zone over the plane); moved as the ridge family is.
const PARALLEL_LOWER = [2]Vec3{ .{ 0, 0, -2.5e-5 }, .{ 4, 1, 2.5e-5 } };
const PARALLEL_UPPER = [2]Vec2{ .{ 1, 0.998 }, .{ 2, 2 } };
const PARALLEL_UPPER_THICKNESS: f64 = 6e-5;
const PARALLEL_OVERLAPS = [_]f64{ 4e-6, 5e-6 };
const PARALLEL_DEPTHS = [_]f64{ 7e-6, 9e-6 };
/// The probes: a point of the lower plate only, of the strip where they overlap and of
/// neither (not of the upper only: the plane within the zone under its bottom, the section
/// holds the solid just above, the solid itself is outside there); and how near the
/// far-moved areas agree (the coordinates' rounding at 3e5 over the outline).
const PARALLEL_PROBES = [_]Vec2{ .{ 3.3, 0.5 }, .{ 1.5, 0.999 }, .{ 0.5, 1.5 } };
const PARALLEL_AREA_SLACK: f64 = 1e-6;

/// The section of `body` at `height`, checked as a sheet: valid, on `z = 0`.
fn sliced(body: *const Body, height: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sheet = try section.slice(testing.allocator, body, height, .{}, &diag);
    errdefer sheet.deinit();
    try testing.expectEqual(.sheet, sheet.kind);
    var report = try check.run(testing.allocator, &sheet, .geometric);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try f.format(&w);
        std.debug.print("checker: {s}\n", .{w.buffered()});
    }
    try testing.expect(report.ok());
    for (sheet.geometry.points.items) |p| try testing.expectEqual(@as(f64, 0), p[2]);
    return sheet;
}

fn areaOf(sheet: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(sheet, .{}, &diag)).area;
}

/// The section's area at `height`, against `want` (relative), and its face count.
fn expectSection(body: *const Body, height: f64, want: f64, faces: usize) !void {
    var sheet = try sliced(body, height);
    defer sheet.deinit();
    try testing.expectEqual(faces, sheet.counts().faces);
    if (want == 0) return testing.expect(sheet.isEmpty());
    try testing.expectApproxEqRel(want, try areaOf(&sheet), EXACT);
}

/// How many of the section's edges are arcs (its circles cut exact, not as polygons).
fn arcs(body: *const Body, height: f64) !usize {
    var sheet = try sliced(body, height);
    defer sheet.deinit();
    var n: usize = 0;
    for (sheet.edges.items) |e| n += @intFromBool(e.curve.kind == .circle);
    return n;
}

fn turned(body: *const Body, affine: Affine) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return transform.transform(testing.allocator, body, &affine, .{}, &diag);
}

fn expectRefused(body: *const Body, height: f64, err: diagnostics.Error) !diagnostics.Finding {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(err, section.slice(testing.allocator, body, height, .{}, &diag));
    return diag.first().?;
}

test "slice: a box inside, on its bottom (its bottom square), on its top and beside it (nothing)" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 10, 4, 6, false, &diag);
    defer box.deinit();
    try expectSection(&box, 3, 40, 1);
    try expectSection(&box, 0, 40, 1);
    try expectSection(&box, 1e-12, 40, 1);
    try expectSection(&box, 6, 0, 0);
    try expectSection(&box, -1, 0, 0);
    try expectSection(&box, 7, 0, 0);
    // The square is the box's own: its corners
    var sheet = try sliced(&box, 2);
    defer sheet.deinit();
    try testing.expectEqual(@as(usize, 4), sheet.counts().vertices);
    for (sheet.geometry.points.items) |p| {
        try testing.expect(p[0] == 0 or p[0] == 10);
        try testing.expect(p[1] == 0 or p[1] == 4);
    }
}

test "slice: a cylinder, a sphere, a cone and a torus are cut in exact circles; touching them gives nothing" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cyl = try primitives.cylinder(testing.allocator, tol, 5, 10, false, &diag);
    defer cyl.deinit();
    try expectSection(&cyl, 3, 25 * PI, 1);
    try expectSection(&cyl, 0, 25 * PI, 1);
    try expectSection(&cyl, 10, 0, 0);
    try testing.expect(try arcs(&cyl, 3) >= 1);
    var ball = try primitives.sphere(testing.allocator, tol, 5, &diag);
    defer ball.deinit();
    try expectSection(&ball, 3, 16 * PI, 1);
    try expectSection(&ball, -3, 16 * PI, 1);
    try expectSection(&ball, 0, 25 * PI, 1);
    try expectSection(&ball, 5, 0, 0);
    try expectSection(&ball, -5, 0, 0);
    try testing.expect(try arcs(&ball, 1) >= 1);
    var cone = try primitives.cone(testing.allocator, tol, 5, 2, 6, false, &diag);
    defer cone.deinit();
    try expectSection(&cone, 2, 16 * PI, 1);
    var spike = try primitives.cone(testing.allocator, tol, 3, 0, 6, false, &diag);
    defer spike.deinit();
    try expectSection(&spike, 4, PI, 1);
    try expectSection(&spike, 6, 0, 0);
    var ring = try primitives.torus(testing.allocator, tol, 5, 1, &diag);
    defer ring.deinit();
    try expectSection(&ring, 0, 20 * PI, 1);
    try expectSection(&ring, 0.5, 20 * PI * @sqrt(0.75), 1);
    try expectSection(&ring, 1, 0, 0);
    try expectSection(&ring, -1, 0, 0);
}

test "slice: a cylinder lying down is cut in a band between two lines, and touched along its sides gives nothing" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cyl = try primitives.cylinder(testing.allocator, tol, 2, 10, false, &diag);
    defer cyl.deinit();
    // Turned a right angle about x: its axis along −y, its side from z = −2 to 2
    var lying = try turned(&cyl, Affine.rotate(vec.X3, PI / 2.0));
    defer lying.deinit();
    try expectSection(&lying, 0, 40, 1);
    try expectSection(&lying, 1, 20 * @sqrt(3.0), 1);
    try expectSection(&lying, -1.5, 20 * @sqrt(1.75), 1);
    try expectSection(&lying, 2, 0, 0);
    try expectSection(&lying, -2, 0, 0);
}

test "slice: a plate with a hole is a face with a hole; a stepped solid at its step is its upper part" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var square = try primitives.square(testing.allocator, tol, 10, 10, true, &diag);
    defer square.deinit();
    var hole = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer hole.deinit();
    const sketch_boolean = @import("../sketch/boolean.zig");
    var plate_sheet = try sketch_boolean.boolean(testing.allocator, &.{ &square, &hole }, .difference, .{}, &diag);
    defer plate_sheet.deinit();
    var plate = try sweep.extrude(testing.allocator, &plate_sheet, .{ 0, 0, 3 }, .{}, &diag);
    defer plate.deinit();
    try expectSection(&plate, 1.5, 100 - 4 * PI, 1);
    var sheet = try sliced(&plate, 1.5);
    defer sheet.deinit();
    try testing.expectEqual(@as(usize, 2), sheet.counts().loops);
    // A step: radius 4 up to 2, radius 2 up to 5, revolved about y and stood up
    var profile = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 2 }, .{ 2, 2 }, .{ 2, 5 }, .{ 0, 5 } }, &diag);
    defer profile.deinit();
    var lathe = try sweep.revolve(testing.allocator, &profile, vec.ZERO3, vec.Y3, 2 * PI, .{}, &diag);
    defer lathe.deinit();
    var stepped = try turned(&lathe, Affine.rotate(vec.X3, PI / 2.0));
    defer stepped.deinit();
    try expectSection(&stepped, 1, 16 * PI, 1);
    try expectSection(&stepped, 2, 4 * PI, 1);
    try expectSection(&stepped, 0, 16 * PI, 1);
    try expectSection(&stepped, 5, 0, 0);
}

test "slice: two faces rising from one edge on the plane (a groove's floor) cancel; above it they bound a band" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var profile = try primitives.polygon(testing.allocator, tol, &.{ .{ -5, 2 }, .{ 0, 0 }, .{ 5, 2 }, .{ 5, 5 }, .{ -5, 5 } }, &diag);
    defer profile.deinit();
    var prism = try sweep.extrude(testing.allocator, &profile, .{ 0, 0, 10 }, .{}, &diag);
    defer prism.deinit();
    // The profile's y up: its floor the edge along y = 0 at the valley
    var groove = try turned(&prism, Affine.rotate(vec.X3, PI / 2.0));
    defer groove.deinit();
    try expectSection(&groove, 0, 0, 0);
    try expectSection(&groove, 1, 50, 1);
    try expectSection(&groove, 2, 100, 1);
    try expectSection(&groove, 4, 100, 1);
}

test "slice: a tetrahedron by its corners: its base, a scaled triangle, its apex" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0, 0, 0 }, .{ 6, 0, 0 }, .{ 0, 6, 0 }, .{ 0, 0, 6 } };
    const triangles = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 0, 3, 2 } };
    var tetra = try primitives.polyhedron(testing.allocator, tol, &points, &triangles, &diag);
    defer tetra.deinit();
    try expectSection(&tetra, 0, 18, 1);
    try expectSection(&tetra, 3, 4.5, 1);
    try expectSection(&tetra, 4, 2, 1);
    try expectSection(&tetra, 6, 0, 0);
}

/// The volume by Simpson's rule over `n` slices between `low` and `high`.
fn integrated(body: *const Body, low: f64, high: f64, n: usize) !f64 {
    const step = (high - low) / @as(f64, @floatFromInt(n));
    var sum: f64 = 0;
    for (0..n + 1) |k| {
        var sheet = try sliced(body, low + step * @as(f64, @floatFromInt(k)));
        defer sheet.deinit();
        const weight: f64 = if (k == 0 or k == n) 1 else if (k % 2 == 1) 4 else 2;
        sum += weight * (if (sheet.isEmpty()) 0 else try areaOf(&sheet));
    }
    return sum * step / 3;
}

test "slice: the areas of a turned box's and a turned sphere's slices integrate to their volumes" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 4, 5, 6, true, &diag);
    defer box.deinit();
    var tilted = try turned(&box, Affine.rotateXyzDegrees(30, 40, 10));
    defer tilted.deinit();
    const bounds = try @import("../topology/bbox.zig").bodyBounds(&tilted);
    // The area is piecewise quadratic in the height: Simpson's rule is exact on each piece,
    // and the pieces' ends cost little at this count
    try testing.expectApproxEqRel(@as(f64, 120), try integrated(&tilted, bounds.min[2], bounds.max[2], 120), 1e-3);
    var ball = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer ball.deinit();
    var moved = try turned(&ball, Affine.translate(.{ 1, 2, 3 }).compose(&Affine.rotateXyzDegrees(20, 70, 0)));
    defer moved.deinit();
    try testing.expectApproxEqRel(4.0 / 3.0 * PI * 27.0, try integrated(&moved, 0, 6, 12), EXACT);
}

test "slice: two parts are two faces" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var two = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } }, &.{ .{ 5, 0 }, .{ 8, 0 }, .{ 8, 3 }, .{ 5, 3 } } }, &diag);
    defer two.deinit();
    var blocks = try sweep.extrude(testing.allocator, &two, .{ 0, 0, 4 }, .{}, &diag);
    defer blocks.deinit();
    try expectSection(&blocks, 2, 13, 2);
}

test "slice: a tilted cylinder's ellipse, a free-form face, a sheet and a height that is not a number are refused" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cyl = try primitives.cylinder(testing.allocator, tol, 2, 10, false, &diag);
    defer cyl.deinit();
    var tilted = try turned(&cyl, Affine.rotate(vec.X3, PI / 6.0));
    defer tilted.deinit();
    const ellipse = try expectRefused(&tilted, 3, error.NotImplemented);
    try testing.expectEqual(.not_implemented, ellipse.code);
    try testing.expectEqual(.face, ellipse.entity.kind);
    // Below the box's free-form top only its flat sides are cut
    var patch = try test_bodies.patchTopBox(testing.allocator, tol, 1, &diag);
    defer patch.deinit();
    try expectSection(&patch, 2, 6, 1);
    const free = try expectRefused(&patch, 4.2, error.NotImplemented);
    try testing.expectEqual(.face, free.entity.kind);
    var square = try primitives.square(testing.allocator, tol, 1, 1, false, &diag);
    defer square.deinit();
    _ = try expectRefused(&square, 0, error.InvalidInput);
    _ = try expectRefused(&cyl, std.math.nan(f64), error.InvalidInput);
}

test "slice: an empty solid's section is empty" {
    var empty = Body.empty(testing.allocator, tol);
    defer empty.deinit();
    try expectSection(&empty, 0, 0, 0);
}

test "slice: a box tilted the zone each way across its bottom and top, at them: its bottom square, and nothing" {
    // On the plane is decided once per vertex: the bottom's corners all lie within the
    // zone of z = 0, so the bottom lies in the plane though its box is 1.8e-5 tall. By that
    // box the bottom was not in the plane while its edges, their ends within the zone,
    // were, and the section at the bottom was empty
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 10, 4, 6, false, &diag);
    defer box.deinit();
    // Tilted about x through the middle of the box: its faces' long sides 0.9e-5 under
    // and over their planes' middle heights
    var tilted = try turned(&box, Affine.rotateAbout(.{ 5, 2, 3 }, vec.X3, 4.5e-6));
    defer tilted.deinit();
    var bottom = try sliced(&tilted, 0);
    defer bottom.deinit();
    try testing.expectEqual(@as(usize, 1), bottom.counts().faces);
    try testing.expectApproxEqRel(@as(f64, 40), try areaOf(&bottom), 1e-9);
    try expectSection(&tilted, 6, 0, 0);
}

/// Point `p` turned `quarter` quarter turns about the origin, then mirrored in the y axis
/// when `mirrored`: exact.
fn quarterTurned(p: Vec2, quarter: usize, mirrored: bool) Vec2 {
    var q = p;
    for (0..quarter) |_| {
        const turned_once: Vec2 = .{ -q[1], q[0] };
        q = turned_once;
    }
    return if (mirrored) .{ -q[0], q[1] } else q;
}

test "slice: a side face two zones wide (a tab's end) bounds the section at every height, turned and mirrored" {
    // The 2D chain fuzzer's find cc (2026-11-22): the trace across the tab's end face, its
    // middle the zone from both the face's edges, was taken for the face's boundary and
    // dropped, and the section's outline left open: no area at every height but the
    // bottom (there the bottom edges bound it). A piece between two of the points where a
    // face's boundary meets the plane is in the face or out of it whole: decided by the
    // face's loops. A tab exactly the intersection tolerance wide (two zones) to rounding is
    // refused when extruded, the rules the sweep runs on what it made asking whether its
    // end face's middle is within reach of a wall's edge, at the reach to rounding
    // (`at_tolerance`, Option A, D27); a tab a hair wider is made and sliced
    var made: usize = 0;
    for (TAB_LINES) |lines| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("tab between {d} and {d}, quarter turns {d}, mirrored {}\n", .{ lines[0], lines[1], quarter, mirrored });
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const low = lines[1] - 1;
        const drawn = [_]Vec2{ .{ 0, low }, .{ 1, low }, .{ 1, lines[0] }, .{ 3, lines[0] }, .{ 3, lines[1] }, .{ 0, lines[1] } };
        var points: [drawn.len]Vec2 = undefined;
        // Mirrored, the outline taken backwards, so it runs counter-clockwise still
        for (drawn, 0..) |p, i| points[if (mirrored) drawn.len - 1 - i else i] = quarterTurned(p, quarter, mirrored);
        var sheet = try primitives.polygon(testing.allocator, tol, &points, &diag);
        defer sheet.deinit();
        const want = try areaOf(&sheet);
        var solid = sweep.extrude(testing.allocator, &sheet, .{ 0, 0, TAB_EXTRUSION }, .{}, &diag) catch |e| {
            if (e != error.Degenerate or diag.first().?.code != .at_tolerance) return e;
            try testing.expect(@abs(@abs(lines[1] - lines[0]) - tol.xsect) < 1e-12);
            continue;
        };
        defer solid.deinit();
        made += 1;
        for (TAB_HEIGHTS) |z| {
            errdefer std.debug.print("at {d}\n", .{z});
            try expectSection(&solid, z, want, 1);
        }
    };
    try testing.expect(made >= 3 * 4 * 2);
}

/// The area of the convex section of the tetrahedron of corners `corners` at height `z`:
/// its edges' crossings of the plane, taken about their centroid.
fn tetrahedronSection(corners: [4]Vec3, z: f64) f64 {
    var points: [6]Vec2 = undefined;
    var n: usize = 0;
    for (0..4) |i| for (i + 1..4) |j| {
        const a = corners[i];
        const b = corners[j];
        if ((a[2] - z) * (b[2] - z) >= 0) continue;
        const t = (z - a[2]) / (b[2] - a[2]);
        points[n] = .{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) };
        n += 1;
    };
    var c: Vec2 = .{ 0, 0 };
    for (points[0..n]) |p| c = .{ c[0] + p[0] / @as(f64, @floatFromInt(n)), c[1] + p[1] / @as(f64, @floatFromInt(n)) };
    const Around = struct {
        c: Vec2,
        fn less(self: @This(), p: Vec2, q: Vec2) bool {
            return std.math.atan2(p[1] - self.c[1], p[0] - self.c[0]) < std.math.atan2(q[1] - self.c[1], q[0] - self.c[0]);
        }
    };
    std.mem.sort(Vec2, points[0..n], Around{ .c = c }, Around.less);
    var twice: f64 = 0;
    for (0..n) |i| {
        const p = points[i];
        const q = points[(i + 1) % n];
        twice += p[0] * q[1] - q[0] * p[1];
    }
    return @abs(twice) / 2;
}

test "slice: a vertex on the plane within the zone, on a face at under 30° to it, bounds that face's trace, turned and mirrored" {
    // A tetrahedron with a face at `WEDGE_SLOPES` to the slicing plane, one corner of it
    // `WEDGE_RISES` zones over the height (on the plane, `sideOf`), one over it and one
    // under: the face's trace runs from that corner to the crossing of the other two's
    // edge. The corner lies its height over the sine of the slope from the trace, past the
    // intersection tolerance under 30°, and was dropped as a mark, the face's trace left
    // with one: the outline open at the corner (the audit of decisions made twice,
    // 2026-11-22). A point the cuts put on the plane is the face's mark, not measured again
    for (WEDGE_SLOPES) |degrees| for (WEDGE_RISES) |rise| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("slope {d}°, corner {d} zones over, quarter turns {d}, mirrored {}\n", .{ degrees, rise, quarter, mirrored });
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const slope = @tan(degrees * PI / 180);
        const v_z = WEDGE_HEIGHT + rise * tol.zone;
        const drawn = [4]Vec3{ .{ 0, 0, v_z }, .{ 1, 1, v_z + slope }, .{ -1, 1, v_z - slope }, .{ 0, 0.5, WEDGE_HEIGHT - 1 } };
        var corners: [4]Vec3 = undefined;
        for (drawn, 0..) |p, i| {
            const q = quarterTurned(.{ p[0], p[1] }, quarter, mirrored);
            corners[i] = .{ q[0], q[1], p[2] };
        }
        var solid = try hull.hull(testing.allocator, tol, &corners, &diag);
        defer solid.deinit();
        var sheet = try sliced(&solid, WEDGE_HEIGHT);
        defer sheet.deinit();
        try testing.expectEqual(@as(usize, 1), sheet.counts().faces);
        // The corner taken onto the plane moves the section by under its height
        try testing.expectApproxEqRel(tetrahedronSection(corners, WEDGE_HEIGHT), try areaOf(&sheet), 1e-3);
    };
}

test "slice: a face crossing the plane parallel to it within the angular tolerance is refused below the feature size (find ea)" {
    // Find ea: a wedge 6e-5 thick, its bottom 6.3e-5 rad off the slicing plane, sliced
    // across it. Two of the bottom's corners lay within the zone of the plane (on it), 0.12
    // from the bottom's trace: the faces rising from them put the section's boundary at
    // the corners, the bottom at its trace, and the outline was left open, no area, where
    // the solid holds material. A face crossing the plane parallel to it within the angular
    // tolerance lies within the zone of the plane over a strip no outline holds consistently
    // (`Section.steepEnough`). Here a pentagonal prism whose bottom rises along y, its
    // corner the zone's half under the plane: refused, turned and mirrored; past the
    // angular tolerance, sliced
    for (SHALLOW_TILTS) |tilt| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("slope {d}, quarter turns {d}, mirrored {}\n", .{ tilt.slope, quarter, mirrored });
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const at = tilt.slope * SHALLOW_BOTTOM[SHALLOW_CORNER][1] + tol.zone / 2;
        var points: [2 * SHALLOW_BOTTOM.len]Vec3 = undefined;
        for (SHALLOW_BOTTOM, 0..) |p, i| {
            const q = quarterTurned(p, quarter, mirrored);
            points[i] = .{ q[0], q[1], tilt.slope * p[1] };
            points[SHALLOW_BOTTOM.len + i] = .{ q[0], q[1], 1 };
        }
        var prism = try hull.hull(testing.allocator, tol, &points, &diag);
        defer prism.deinit();
        if (tilt.refused) {
            try testing.expectError(error.Degenerate, section.slice(testing.allocator, &prism, at, .{}, &diag));
            try testing.expectEqual(diagnostics.Code.below_feature_size, diag.first().?.code);
            continue;
        }
        var cut = try section.slice(testing.allocator, &prism, at, .{}, &diag);
        defer cut.deinit();
        // The solid just above the plane: the bottom below it, where y < at / slope, to
        // the strip the corner on the plane by the zone moves the outline across (the zone
        // over the slope, along the prism's width)
        try testing.expectApproxEqAbs(clippedArea(&SHALLOW_BOTTOM, at / tilt.slope), try areaOf(&cut), tol.zone / tilt.slope * 1.2);
    };
}

/// The area of the convex polygon `ring` where y is below `y_max` (one clip, shoelace).
fn clippedArea(ring: []const Vec2, y_max: f64) f64 {
    var clipped: [2 * SHALLOW_BOTTOM.len]Vec2 = undefined;
    var n: usize = 0;
    for (ring, 0..) |p, i| {
        const q = ring[(i + 1) % ring.len];
        if (p[1] <= y_max) {
            clipped[n] = p;
            n += 1;
        }
        if ((p[1] < y_max) != (q[1] < y_max)) {
            const t = (y_max - p[1]) / (q[1] - p[1]);
            clipped[n] = .{ p[0] + t * (q[0] - p[0]), y_max };
            n += 1;
        }
    }
    var twice: f64 = 0;
    for (clipped[0..n], 0..) |p, i| {
        const q = clipped[(i + 1) % n];
        twice += p[0] * q[1] - q[0] * p[1];
    }
    return @abs(twice) / 2;
}

test "slice: a groove's walls falling from a ridge on the plane within the zone give nothing, whichever is nearer the ridge (find ed)" {
    // Find ed: the plate less the hull keeps a groove in its bottom up to the hull's ridge
    // in the plate's mid-plane, and the section 7.8e-6 under the ridge has the ridge on
    // the plane: the solid just above it is the whole plate. Each wall falling from the
    // ridge traced a piece between the ridge's ends, which was the ridge when its middle
    // lay within the zone of it in 3D: 1.0e-5 from one wall's, 1.05e-5 from the other's,
    // so one wall bounded the section and its other side was lost, the plate's point beside
    // the groove inside the solid and outside the section. A piece between the two ends of
    // the face's edge on the plane is that edge, by record (`Section.ownEdgeInPlane`)
    const t = tolerance.Tolerance.fromZone(1e-5);
    var drawn = try helpers.boxAt(t, ED_PLATE[0], ED_PLATE[1]);
    defer drawn.deinit();
    var plate = try helpers.moved(&drawn, ED_PLATE_MOVE);
    defer plate.deinit();
    var tool = try degeneracy.fuzzHullPlaced(&ED_HULL, vec.Z3, 0, null, ED_HULL_MOVE, ED_HULL_NUDGE);
    defer tool.deinit();
    var grooved = try helpers.sound(&plate, &tool, .difference);
    defer grooved.deinit();
    var sheet = try sliced(&grooved, ED_HEIGHT);
    defer sheet.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expect(try sketch_query.contains(&sheet, ED_POINT, 0, &diag));
    try testing.expectEqual(@as(usize, 1), sheet.counts().faces);
    try testing.expectApproxEqRel(@as(f64, 2), try areaOf(&sheet), EXACT);
}

test "slice: the family about ed, a ridge's walls at two slopes, sliced under it within the zone and over it, turned, mirrored and moved far" {
    var plate = try helpers.box(RIDGE_PLATE[0], RIDGE_PLATE[1]);
    defer plate.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var points: [6]Vec3 = undefined;
    for (RIDGE_ENDS, 0..) |end, i| {
        points[3 * i] = end;
        for (RIDGE_FEET, 0..) |foot, k| points[3 * i + 1 + k] = vec.add(end, .{ foot, 0, -1 });
    }
    var prism = try hull.hull(testing.allocator, tol, &points, &diag);
    defer prism.deinit();
    var grooved = try helpers.sound(&plate, &prism, .difference);
    defer grooved.deinit();
    for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| for (RIDGE_SHIFTS) |shift| for (RIDGE_HEIGHTS) |height| {
        errdefer std.debug.print("quarter turns {d}, mirrored {}, shifted {any}, sliced at {e}\n", .{ quarter, mirrored, shift, height });
        var place = Affine.translate(shift).compose(&Affine.rotate(vec.Z3, @as(f64, @floatFromInt(quarter)) * PI / 2.0));
        if (mirrored) place = place.compose(&Affine.mirror(vec.X3));
        var moved = try turned(&grooved, place);
        defer moved.deinit();
        // The ridge on the plane: the solid just above it, the whole plate
        try expectSection(&moved, height, 2, 1);
    };
}

test "slice: a plate's top a hair over the plane, under another plate's walls on it, holds the plate under them (find ee)" {
    // Find ee: the upper plate's bottom and the lower's top 5e-6 apart are one plane where
    // the plates overlap, and the section 6.15e-6 under that bottom has it on the plane,
    // the lower's top 1.1e-5 over it. The upper's walls rise from their bottom edges on the
    // plane, and the lower's top, parallel to the plane within the angular tolerance, rises
    // from the same edges facing up, the lower plate under it: its side holds material
    // too. Decided by its normal's tilt, it took no part, the upper's walls bounded the
    // section across the lower plate, which was lost. A face parallel to the plane bounds
    // the section by its vertices' sides of the plane (`Section.edgeInPlane`)
    const t = tolerance.Tolerance.fromZone(1e-5);
    var drawn_upper = try helpers.boxAt(t, EE_UPPER[0], EE_UPPER[1]);
    defer drawn_upper.deinit();
    var moved_upper = try helpers.moved(&drawn_upper, EE_UPPER_MOVES[0]);
    defer moved_upper.deinit();
    var upper = try helpers.moved(&moved_upper, EE_UPPER_MOVES[1]);
    defer upper.deinit();
    var drawn_lower = try helpers.boxAt(t, EE_LOWER[0], EE_LOWER[1]);
    defer drawn_lower.deinit();
    var lower = try helpers.moved(&drawn_lower, EE_LOWER_NUDGE);
    defer lower.deinit();
    var joined = try helpers.sound(&upper, &lower, .@"union");
    defer joined.deinit();
    var sheet = try sliced(&joined, EE_HEIGHT);
    defer sheet.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expect(try sketch_query.contains(&sheet, EE_POINT, 0, &diag));
    try testing.expectEqual(@as(usize, 1), sheet.counts().faces);
    try testing.expectApproxEqAbs(EE_AREA, try areaOf(&sheet), PARALLEL_AREA_SLACK);
}

test "slice: the family about ee, a plate on another a hair into it, sliced within the zone under it, agrees with the solid turned, mirrored and moved far" {
    // Each section holds the probes the solid holds (a probe on its boundary, within the
    // zone, skipped), and its area is the same in every placement
    var lower = try helpers.box(PARALLEL_LOWER[0], PARALLEL_LOWER[1]);
    defer lower.deinit();
    for (PARALLEL_OVERLAPS) |overlap| for (PARALLEL_DEPTHS) |depth| {
        const bottom = PARALLEL_LOWER[1][2] - overlap;
        var upper = try helpers.box(.{ PARALLEL_UPPER[0][0], PARALLEL_UPPER[0][1], bottom }, .{ PARALLEL_UPPER[1][0], PARALLEL_UPPER[1][1], bottom + PARALLEL_UPPER_THICKNESS });
        defer upper.deinit();
        var joined = try helpers.sound(&upper, &lower, .@"union");
        defer joined.deinit();
        var area: ?f64 = null;
        for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| for (RIDGE_SHIFTS) |shift| {
            errdefer std.debug.print("overlap {e}, {e} under the upper's bottom, quarter turns {d}, mirrored {}, shifted {any}\n", .{ overlap, depth, quarter, mirrored, shift });
            var place = Affine.translate(shift).compose(&Affine.rotate(vec.Z3, @as(f64, @floatFromInt(quarter)) * PI / 2.0));
            if (mirrored) place = place.compose(&Affine.mirror(vec.X3));
            var moved = try turned(&joined, place);
            defer moved.deinit();
            const z = bottom - depth;
            var sheet = try sliced(&moved, z);
            defer sheet.deinit();
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            var index = try FaceIndex.build(testing.allocator, &moved, &diag);
            defer index.deinit(testing.allocator);
            for (PARALLEL_PROBES) |probe| {
                const p = place.point(.{ probe[0], probe[1], z });
                const place_of = try point_in_body.classify(testing.allocator, &moved, &index, p, .{}, &diag);
                if (place_of == .boundary) continue;
                errdefer std.debug.print("the probe {any}: the solid says {t}\n", .{ probe, place_of });
                try testing.expectEqual(place_of == .inside, try sketch_query.contains(&sheet, .{ p[0], p[1] }, 0, &diag));
            }
            const got = try areaOf(&sheet);
            if (area) |want| try testing.expectApproxEqAbs(want, got, PARALLEL_AREA_SLACK) else area = got;
        };
    };
}
