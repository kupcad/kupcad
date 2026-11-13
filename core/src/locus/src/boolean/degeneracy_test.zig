//! The degeneracy corpus, planar part (KNOWLEDGE §11; research/solidcraft.md §1, tier 02):
//! one named test per configuration where operands meet in something thinner than a volume,
//! each result through the checker at level 2, the overlap rules and its report
//! (`pipeline_test.sound`), with its volume exact and the volume identities holding:
//! identical boxes, a cube inside a cube, a cube-shaped void, faces touching with equal and
//! with opposite normals, coplanar overlap, an edge on a face, an edge on an edge, a vertex
//! on a face, on an edge and on a vertex, a cut through a vertex and along an edge, a knife
//! edge, a mirrored copy united with its original, a pocket flush with the top, near-tangent
//! gaps and overlaps of 1e-3 and 1e-6, a knife-edge wedge, a V groove pinching the bottom to
//! a line and a pocket pinched to a face, walls 1e-4 apart joined, operands far from the
//! origin, two 1000-sided prisms and 64 pegs (their times are the benchmark's).

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const pipeline = @import("pipeline.zig");
const trim = @import("trim.zig");
const helpers = @import("pipeline_test.zig");
const box = helpers.box;
const sound = helpers.sound;
const volume = helpers.volume;
const expectShape = helpers.expectShape;
const expectIdentities = helpers.expectIdentities;
const shellKinds = helpers.shellKinds;
const turned = helpers.turned;
const Vec3 = vec.Vec3;
const VertexIndex = @import("../topology/types.zig").VertexIndex;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
const CLOSE = 1e-9;

fn polyhedron(points: []const Vec3, triangles: []const [3]u32) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return primitives.polyhedron(testing.allocator, tol, points, triangles, &diag);
}

/// A tetrahedron on `apex` and three other corners, wound outward.
fn tetrahedron(apex: Vec3, p: Vec3, q: Vec3, r: Vec3) !Body {
    // Outward: the base seen from the apex runs clockwise
    const n = vec.cross(vec.sub(q, p), vec.sub(r, p));
    const flip = vec.dot(n, vec.sub(apex, p)) > 0;
    const base: [3]u32 = if (flip) .{ 1, 3, 2 } else .{ 1, 2, 3 };
    return polyhedron(&.{ apex, p, q, r }, &.{ base, .{ 0, base[1], base[0] }, .{ 0, base[2], base[1] }, .{ 0, base[0], base[2] } });
}

fn warned(diag: *const Diagnostics, code: diagnostics.Code) usize {
    var n: usize = 0;
    for (diag.findings.items) |f| n += @intFromBool(f.severity == .warning and f.code == code);
    return n;
}

test "degeneracy: identical boxes" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try expectShape(&u, 8, 6, 1);
    var d = try sound(&a, &b, .difference);
    defer d.deinit();
    try testing.expect(d.isEmpty());
    try expectIdentities(&a, &b);
}

test "degeneracy: a cube inside a cube, and a cube-shaped void filled" {
    var outer = try box(.{ 0, 0, 0 }, .{ 4, 4, 4 });
    defer outer.deinit();
    var inner = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer inner.deinit();
    var u = try sound(&outer, &inner, .@"union");
    defer u.deinit();
    try expectShape(&u, 64, 6, 1);
    var i = try sound(&outer, &inner, .intersection);
    defer i.deinit();
    try expectShape(&i, 8, 6, 1);
    var hollow = try sound(&outer, &inner, .difference);
    defer hollow.deinit();
    try testing.expectEqual([2]usize{ 1, 1 }, shellKinds(&hollow));
    var filled = try sound(&hollow, &inner, .@"union");
    defer filled.deinit();
    try expectShape(&filled, 64, 6, 1);
    var none = try sound(&hollow, &inner, .intersection);
    defer none.deinit();
    try testing.expect(none.isEmpty());
    try expectIdentities(&outer, &inner);
    try expectIdentities(&hollow, &inner);
}

test "degeneracy: faces touching with equal normals, a box in another's corner" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try expectShape(&u, 8, 6, 1);
    var d = try sound(&a, &b, .difference);
    defer d.deinit();
    // Three faces notched, three whole, the notch's three
    try expectShape(&d, 7, 9, 1);
    try expectIdentities(&a, &b);
}

test "degeneracy: faces touching with opposite normals, whole and in part" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1, 0, 0 }, .{ 2, 1, 1 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try expectShape(&u, 2, 6, 1);
    try expectIdentities(&a, &b);
    // Coplanar overlap: a box stacked across another's top, the faces sharing a unit square
    var low = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer low.deinit();
    var high = try box(.{ 1, 1, 1 }, .{ 3, 3, 2 });
    defer high.deinit();
    var stacked = try sound(&low, &high, .@"union");
    defer stacked.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&stacked));
    try testing.expectApproxEqAbs(@as(f64, 8), try volume(&stacked), CLOSE);
    var touch = try sound(&low, &high, .intersection);
    defer touch.deinit();
    try testing.expect(touch.isEmpty());
    try expectIdentities(&low, &high);
}

test "degeneracy: an edge lying on a face, inside it, and an edge on an edge" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    // A unit cube turned 45° about y, its lowest edge along y on the top face's middle
    var unit = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer unit.deinit();
    var leaning = try turned(&unit, .{ 0, 0, 0 }, vec.Y3, -std.math.pi / 4.0);
    defer leaning.deinit();
    var on_edge = try helpers.moved(&leaning, .{ 1, 0.5, 2 });
    defer on_edge.deinit();
    var u = try sound(&a, &on_edge, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
    try testing.expectApproxEqAbs(@as(f64, 9), try volume(&u), CLOSE);
    var d = try sound(&a, &on_edge, .difference);
    defer d.deinit();
    try testing.expectApproxEqAbs(@as(f64, 8), try volume(&d), CLOSE);
    try expectIdentities(&a, &on_edge);
    // Edge on edge, overlapping for half their length: two solids, a common block
    var b = try box(.{ 0, 0, 0 }, .{ 2, 1, 1 });
    defer b.deinit();
    var c = try box(.{ 1, 1, 1 }, .{ 3, 2, 2 });
    defer c.deinit();
    var pair = try sound(&b, &c, .@"union");
    defer pair.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&pair));
    try expectIdentities(&b, &c);
}

test "degeneracy: a vertex on a face, on an edge, on a vertex" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    // A tetrahedron's apex on the top face's middle, the rest above it
    var on_face = try tetrahedron(.{ 1, 1, 2 }, .{ 0.5, 0.5, 3 }, .{ 1.5, 0.5, 3 }, .{ 1, 1.5, 3 });
    defer on_face.deinit();
    var u = try sound(&a, &on_face, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
    try expectIdentities(&a, &on_face);
    // Its apex on the middle of the top front edge
    var on_edge = try tetrahedron(.{ 1, 0, 2 }, .{ 0.5, -0.5, 3 }, .{ 1.5, -0.5, 3 }, .{ 1, 0.5, 3 });
    defer on_edge.deinit();
    var v = try sound(&a, &on_edge, .@"union");
    defer v.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&v));
    try expectIdentities(&a, &on_edge);
    // Corner to corner
    var corner = try box(.{ 2, 2, 2 }, .{ 3, 3, 3 });
    defer corner.deinit();
    var w = try sound(&a, &corner, .@"union");
    defer w.deinit();
    try expectShape(&w, 9, 12, 2);
    try expectIdentities(&a, &corner);
}

test "degeneracy: a cut through three vertices exactly, and along two edges" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // x + y + z ≥ 2: the cube less the corner tetrahedron the plane cuts through three corners
    var through = try trim.trimByPlane(testing.allocator, &a, .{ 1, 1, 1 }, 2.0 / @sqrt(3.0), .{}, &diag, null);
    defer through.deinit();
    try testing.expectApproxEqAbs(@as(f64, 8 - 8.0 / 6.0), try volume(&through), 1e-9);
    try testing.expectEqual(@as(usize, 7), through.counts().faces);
    // x + y ≥ 2: along two vertical edges
    var along = try trim.trimByPlane(testing.allocator, &a, .{ 1, 1, 0 }, @sqrt(2.0), .{}, &diag, null);
    defer along.deinit();
    try testing.expectApproxEqAbs(@as(f64, 4), try volume(&along), 1e-9);
    try testing.expectEqual(@as(usize, 5), along.counts().faces);
}

test "degeneracy: a knife edge, four faces at one line, two solids" {
    var plate = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer plate.deinit();
    var q1 = try box(.{ -1, -1, -1 }, .{ 1, 1, 2 });
    defer q1.deinit();
    var q3 = try box(.{ 1, 1, -1 }, .{ 3, 3, 2 });
    defer q3.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // The two other quarters of the plate are left, touching along x = y = 1
    var knife = try pipeline.chain(testing.allocator, &.{ &plate, &q1, &q3 }, .difference, .{}, &diag, null);
    defer knife.deinit();
    try expectShape(&knife, 2, 12, 2);
    try testing.expectEqual(@as(usize, 1), warned(&diag, .solids_touch));
}

test "degeneracy: a mirrored copy united with its original, and a pocket flush with the top" {
    // A wedge with its square side on x = 0, mirrored across that plane: a whole prism
    const wedge_points = [_]Vec3{ .{ 0, 0, 0 }, .{ 0, 2, 0 }, .{ 0, 2, 2 }, .{ 0, 0, 2 }, .{ 1, 0, 0 }, .{ 1, 2, 0 } };
    const wedge_triangles = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 3, 2 }, .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 0, 4, 3 }, .{ 1, 2, 5 }, .{ 2, 3, 4 }, .{ 2, 4, 5 } };
    var wedge = try polyhedron(&wedge_points, &wedge_triangles);
    defer wedge.deinit();
    var mirror = try helpers.mirrored(&wedge, vec.X3);
    defer mirror.deinit();
    var whole = try sound(&wedge, &mirror, .@"union");
    defer whole.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&whole));
    try testing.expectApproxEqAbs(@as(f64, 4), try volume(&whole), CLOSE);
    // A pocket whose top is the top's plane: the top a face with a hole
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var pocket = try box(.{ 0.5, 0.5, 1 }, .{ 1.5, 1.5, 2 });
    defer pocket.deinit();
    var cut = try sound(&a, &pocket, .difference);
    defer cut.deinit();
    // Six faces, the top holed; the pocket's floor and four walls
    try expectShape(&cut, 7, 11, 1);
    try testing.expectEqual(@as(usize, 12), cut.counts().loops);
    try expectIdentities(&a, &pocket);
}

test "degeneracy: near-tangent gaps and overlaps of 1e-3 and 1e-6" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    // Apart by 1e-3 (fifty intersection tolerances): two solids, the faces warned of
    var gap = try box(.{ 1 + 1e-3, 0, 0 }, .{ 2, 1, 1 });
    defer gap.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var apart = try pipeline.boolean(testing.allocator, &a, &gap, .@"union", .{}, &diag, null);
    defer apart.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&apart));
    try testing.expect(warned(&diag, .nearly_coplanar) >= 1);
    try expectIdentities(&a, &gap);
    // Overlapping by 1e-3: one solid, a slab that thin in common
    var lap = try box(.{ 1 - 1e-3, 0, 0 }, .{ 2, 1, 1 });
    defer lap.deinit();
    var slab = try sound(&a, &lap, .intersection);
    defer slab.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1e-3), try volume(&slab), 1e-12);
    try expectIdentities(&a, &lap);
    // Apart and overlapping by 1e-6, within the zone: one solid, face to face; the vertices
    // moved to meet lay on the line the faces merged across, which simplification took
    // away with them, so the result is the exact box and says so
    for ([_]f64{ 1e-6, -1e-6 }) |by| {
        var near = try box(.{ 1 + by, 0, 0 }, .{ 2, 1, 1 });
        defer near.deinit();
        var r = pipeline.Report.init(testing.allocator);
        defer r.deinit();
        var joined = try helpers.reported(&a, &near, .@"union", .{}, &r);
        defer joined.deinit();
        try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&joined));
        try testing.expectEqual(@as(usize, 6), joined.counts().faces);
        try testing.expectApproxEqAbs(@as(f64, 2), try volume(&joined), 1e-5);
        try testing.expectEqual(pipeline.Report.Quality.exact, r.quality());
        try testing.expect(r.coincident);
        var thin = try sound(&a, &near, .intersection);
        defer thin.deinit();
        try testing.expect(thin.isEmpty());
    }
}

test "degeneracy: a knife-edge wedge cut into a box" {
    var a = try box(.{ 0, 0, 0 }, .{ 4, 4, 2 });
    defer a.deinit();
    // A wedge 1e-3 wide at its back, sharp along x = 1 inside the box, through its height
    const w: f64 = 1e-3;
    const points = [_]Vec3{ .{ 1, 2, -1 }, .{ 5, 2 - w / 2, -1 }, .{ 5, 2 + w / 2, -1 }, .{ 1, 2, 3 }, .{ 5, 2 - w / 2, 3 }, .{ 5, 2 + w / 2, 3 } };
    const triangles = [_][3]u32{ .{ 0, 2, 1 }, .{ 3, 4, 5 }, .{ 0, 1, 4 }, .{ 0, 4, 3 }, .{ 1, 2, 5 }, .{ 1, 5, 4 }, .{ 2, 0, 3 }, .{ 2, 3, 5 } };
    var wedge = try polyhedron(&points, &triangles);
    defer wedge.deinit();
    var slit = try sound(&a, &wedge, .difference);
    defer slit.deinit();
    // The wedge's part within the box: a triangle of base w·3/4 and height 3, 2 deep
    const inside = 0.5 * (w * 3.0 / 4.0) * 3.0 * 2.0;
    try testing.expectApproxEqAbs(@as(f64, 32 - inside), try volume(&slit), 1e-9);
    try expectIdentities(&a, &wedge);
}

/// A V-shaped prism along y from `lo` to `hi`: its cross-section the triangle (1, 0), (2, 2),
/// (0, 2) in x and z, its bottom edge on z = 0.
fn vGroove(lo: f64, hi: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var triangle = try primitives.polygon(testing.allocator, tol, &.{ .{ 1, 0 }, .{ 2, 2 }, .{ 0, 2 } }, &diag);
    defer triangle.deinit();
    var along = try @import("../construct/sweep.zig").extrude(testing.allocator, &triangle, .{ 0, 0, hi - lo }, .{}, &diag);
    defer along.deinit();
    // A quarter turn about x takes y to z and z to −y: the prism from y = −(hi − lo) to 0
    var stood = try turned(&along, .{ 0, 0, 0 }, vec.X3, std.math.pi / 2.0);
    defer stood.deinit();
    return helpers.moved(&stood, .{ 0, hi, 0 });
}

test "degeneracy: a V groove pinching the bottom to a line splits; a pocket pinched to a face is refused by design" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer a.deinit();
    // A V groove right across, its bottom edge on the bottom face: two solids touching along it
    var groove = try vGroove(-1, 3);
    defer groove.deinit();
    var split = try sound(&a, &groove, .difference);
    defer split.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&split));
    // Each half a quadrilateral prism: the square less the groove's triangle at height ≤ 1
    try testing.expectApproxEqAbs(@as(f64, 4 - 2 * 0.5 * 1 * 0.5 * 2), try volume(&split), 1e-9);
    try expectIdentities(&a, &groove);
    // The same groove stopped short of the far side: one solid touching itself along the
    // bottom's line, which one shell cannot hold
    var short = try vGroove(-1, 1);
    defer short.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, &a, &short, .difference, .{}, &diag, null));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
}

test "degeneracy: walls 1e-4 apart joined stay two solids, warned of" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1 + 1e-4, 0, 0 }, .{ 2, 1, 1 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var joined = try pipeline.boolean(testing.allocator, &a, &b, .@"union", .{}, &diag, null);
    defer joined.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&joined));
    try testing.expectApproxEqAbs(@as(f64, 2 - 1e-4), try volume(&joined), CLOSE);
    try testing.expect(warned(&diag, .nearly_coplanar) >= 1);
}

test "degeneracy: operands moved to (1000, -700, 300)" {
    const far: Vec3 = .{ 1000, -700, 300 };
    var a = try box(far, vec.add(far, .{ 2, 2, 2 }));
    defer a.deinit();
    var b = try box(vec.add(far, .{ 1, 1, 1 }), vec.add(far, .{ 3, 3, 3 }));
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try testing.expectEqual(@as(usize, 12), u.counts().faces);
    try testing.expectApproxEqAbs(@as(f64, 15), try volume(&u), 1e-8);
    var i = try sound(&a, &b, .intersection);
    defer i.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1), try volume(&i), 1e-8);
}

/// A regular prism of `n` sides of circumradius `r` about `(cx, cy)`, from z = 0 to `h`.
fn prism(n: usize, r: f64, cx: f64, cy: f64, h: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = try testing.allocator.alloc(vec.Vec2, n);
    defer testing.allocator.free(points);
    for (points, 0..) |*p, k| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        p.* = .{ cx + r * @cos(t), cy + r * @sin(t) };
    }
    var sheet = try primitives.polygon(testing.allocator, tol, points, &diag);
    defer sheet.deinit();
    return @import("../construct/sweep.zig").extrude(testing.allocator, &sheet, .{ 0, 0, h }, .{}, &diag);
}

test "degeneracy: two 1000-sided prisms overlapping, and 64 pegs joined to a plate" {
    var p = try prism(1000, 10, 0, 0, 5);
    defer p.deinit();
    var q = try prism(1000, 10, 5, 0, 5);
    defer q.deinit();
    try expectIdentities(&p, &q);
    var u = try sound(&p, &q, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&u));
    // 64 pegs standing on a plate, apart from each other: one solid
    var plate = try box(.{ 0, 0, 0 }, .{ 16, 16, 1 });
    defer plate.deinit();
    var pegs: [64]Body = undefined;
    var made: usize = 0;
    defer for (pegs[0..made]) |*g| g.deinit();
    for (0..8) |i| for (0..8) |j| {
        const x: f64 = @floatFromInt(2 * i);
        const y: f64 = @floatFromInt(2 * j);
        pegs[made] = try box(.{ x + 0.5, y + 0.5, 1 }, .{ x + 1.5, y + 1.5, 3 });
        made += 1;
    };
    var operands: [65]*const Body = undefined;
    operands[0] = &plate;
    for (pegs[0..made], operands[1..]) |*g, *o| o.* = g;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var studded = try pipeline.chain(testing.allocator, &operands, .@"union", .{}, &diag, null);
    defer studded.deinit();
    try expectShape(&studded, 256 + 64 * 2, 6 + 64 * 5, 1);
}

test "degeneracy: a cut whose corner touches the face it was cut from is pinched at a point, refused by design" {
    // The solids fuzzer's first find (2026-11-13): a tetrahedron through a box's bottom, its
    // apex on the box's side from within; the pocket the difference leaves, open at the
    // bottom, meets that side at one point no edge records, inside one solid
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var through = try tetrahedron(.{ 2, 1, 1 }, .{ 0.5, 0.5, -1 }, .{ 0.5, 1.5, -1 }, .{ 1.5, 1, -1 });
    defer through.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, &a, &through, .difference, .{}, &diag, null));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    var u = try sound(&a, &through, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&u));
    var i = try sound(&a, &through, .intersection);
    defer i.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&i));
    // Wholly inside, the cut is a void touching the side at its corner: two shells, which
    // pass
    var inside = try tetrahedron(.{ 2, 1, 1 }, .{ 1, 0.5, 0.5 }, .{ 1, 1.5, 0.5 }, .{ 1, 1, 1.5 });
    defer inside.deinit();
    var hollow = try sound(&a, &inside, .difference);
    defer hollow.deinit();
    try testing.expectEqual([2]usize{ 1, 1 }, shellKinds(&hollow));
    try testing.expectApproxEqAbs(8 - try volume(&inside), try volume(&hollow), CLOSE);
    // From outside, the corner on the face makes two solids touching at a point, which pass
    var outside = try tetrahedron(.{ 2, 1, 1 }, .{ 3, 0.5, 0.5 }, .{ 3, 1.5, 0.5 }, .{ 3, 1, 1.5 });
    defer outside.deinit();
    var both = try sound(&a, &outside, .@"union");
    defer both.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&both));
    var cut = try sound(&a, &outside, .difference);
    defer cut.deinit();
    try expectShape(&cut, 8, 6, 1);
}

test "degeneracy: a sliver one intersection tolerance thick, crossed by a face, kept or collapsed" {
    // The solids fuzzer's second find (2026-11-13), reduced: a box overlapping another by
    // the intersection tolerance and standing out of its top, its sides crossing the top in
    // pieces that long. Just past the tolerance the sliver is kept: the paves put such a
    // piece's far end off the top's edge while its middle is within the zone of it, and the
    // paves decide (the piece is imprinted); a sample of the sliver's strip on the other's
    // face gives way to the next one. Just within it the faces lie in one plane and the
    // operands touch. Either way the identities hold to the slab the tolerance may count
    // either way: its thickness times the face it lies on.
    const xsect = tol.xsect;
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    for ([_]f64{ 1 + 1e-6, 1 - 1e-6 }) |by| {
        var b = try box(.{ 0.5, -1, 1 }, .{ 1.5, xsect * by, 3 });
        defer b.deinit();
        var u = try sound(&a, &b, .@"union");
        defer u.deinit();
        try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&u));
        var i = try sound(&a, &b, .intersection);
        defer i.deinit();
        var d = try sound(&a, &b, .difference);
        defer d.deinit();
        const slab = xsect * 1 * 1;
        const vi = try volume(&i);
        if (by > 1) try testing.expectApproxEqAbs(slab * by, vi, 1e-12) else try testing.expect(i.isEmpty());
        const va = try volume(&a);
        const vb = try volume(&b);
        try testing.expectApproxEqAbs(va + vb, try volume(&u) + vi, slab);
        try testing.expectApproxEqAbs(va - vi, try volume(&d), slab);
    }
}

test "degeneracy: an edge lying across two coplanar faces of the other, touching them" {
    // The solids fuzzer's third find (2026-11-13): a box's edge lies in the plane of two
    // triangles of a hull (x + y = 3.5), across their shared diagonal, from one triangle's
    // edge to inside the other; merged, the hull's face holds the contact as a chain of
    // slits from its boundary, which simplification once took for a bridge and removed
    var a = try box(.{ 0.5, 0, 1 }, .{ 1.5, 2, 3 });
    defer a.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 1, 3.5, 1 }, .{ 4, -0.5, 4 }, .{ 0, 3.5, 2 }, .{ 1, 2.5, 2 }, .{ 1, 2.5, 4 } };
    var b = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
    try expectIdentities(&a, &b);
}

test "degeneracy: an edge passing a box's edge within the tolerance and crossing its face at a shallow angle" {
    // The solids fuzzer's fifth find (2026-11-13), reduced: a hull's edge, direction
    // (1, 3, 3), passes 1.9e-5 from the box's edge at x = 0.5, y = 2 (within the
    // intersection tolerance, so edge–edge makes a vertex there) and crosses the box's face
    // x = 0.5 at 13° 5.7e-5 away; the box's edge crosses the hull's face 3x − z = 6e-5 as
    // near. Two more vertices there made the two faces meet along a bent chain both kept,
    // a fold the overlap rules refuse. An edge meets a plane once: the crossings are the
    // vertex the edges already have on the faces. The exact intersection's top is an edge
    // 6e-5 long that is now that vertex, 5.4e-5 above it: its volume, and the identities,
    // hold to that displacement times the result's area, well within the fuzzer's slab
    var a = try box(.{ 0, 1, 1 }, .{ 0.5, 2, 3 });
    defer a.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 4, 3, 4 }, .{ 4, 4, 4 }, .{ 1, 4, 3 }, .{ 0, 1, 0 }, .{ 3, 3, 4 }, .{ 0, 4, 0 } };
    var b0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer b0.deinit();
    var b = try helpers.moved(&b0, .{ 2e-5, -0.5, 0 });
    defer b.deinit();
    var u = try sound(&b, &a, .@"union");
    defer u.deinit();
    var i = try sound(&b, &a, .intersection);
    defer i.deinit();
    var d = try sound(&b, &a, .difference);
    defer d.deinit();
    // The exact intersection, from its cross-sections in z (2026-11-13)
    const exact = 0.016663166786673865;
    const measured = try @import("../measure/mass.zig").mass(&i, .{}, &diag);
    const apex = 6e-5 * measured.area;
    const vi = measured.volume;
    try testing.expectApproxEqAbs(exact, vi, apex);
    try testing.expectEqual(@as(usize, 5), i.counts().faces);
    const va = try volume(&a);
    const vb = try volume(&b);
    try testing.expectApproxEqAbs(va + vb, try volume(&u) + vi, 2 * apex);
    try testing.expectApproxEqAbs(vb - vi, try volume(&d), 2 * apex);
}

test "degeneracy: vertices merged past the zone are refused, the vertex named" {
    // The solids fuzzer's sixth find (2026-11-13): a merged vertex's ball is the result's
    // vertex's gap, which the zone bounds; the gap a chain's earlier boolean recorded plus
    // half the distance to the other operand's vertex (or two vertices exactly the
    // intersection tolerance apart, the centre's rounding past the zone) made a result its
    // own last check refused. The merge refuses it, naming the vertex, at vertex–vertex
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1 + 1e-5, 1, 1 }, .{ 2, 2, 2 });
    defer b.deinit();
    var corner: ?usize = null;
    for (a.vertices.items, 0..) |v, i| {
        if (!v.tombstone and vec.distance(a.point(VertexIndex.of(i)), .{ 1, 1, 1 }) == 0) corner = i;
    }
    for ([_]f64{ 0.8e-5, 0.4e-5 }) |recorded| {
        a.vertices.items[corner.?].gap = recorded;
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var r = pipeline.Report.init(testing.allocator);
        defer r.deinit();
        if (pipeline.boolean(testing.allocator, &a, &b, .@"union", .{}, &diag, &r)) |result| {
            var kept = result;
            kept.deinit();
            try testing.expect(recorded + 0.5e-5 <= tol.zone);
        } else |err| {
            const f = diag.first().?;
            if (recorded + 0.5e-5 <= tol.zone) {
                // Within the zone: whatever else the touching corners are, not this
                try testing.expect(f.code != .gap_too_large);
                continue;
            }
            try testing.expectEqual(error.Degenerate, err);
            try testing.expectEqual(diagnostics.Code.gap_too_large, f.code);
            try testing.expectEqual(diagnostics.EntityKind.vertex, f.entity.kind);
            try testing.expectEqual(@as(u32, @intCast(corner.?)), f.entity.index);
            try testing.expectApproxEqAbs(1.3e-5, f.measured, 1e-12);
            try testing.expectEqual(@as(?pipeline.Stage, .vertex_vertex), r.failed_in);
        }
    }
}

/// Whether some face of `body` has a loop of one vertex.
fn hasPointLoop(body: *const Body) bool {
    for (body.loops.items) |l| if (!l.tombstone and l.first == .none) return true;
    return false;
}

/// The containment table and the general path give the same body for `a` and `b` apart.
fn expectTableAgrees(a: *const Body, b: *const Body) !void {
    for ([_]pipeline.Op{ .@"union", .difference, .intersection }) |op| {
        var fast = pipeline.Report.init(testing.allocator);
        defer fast.deinit();
        var by_table = try helpers.reported(a, b, op, .{}, &fast);
        defer by_table.deinit();
        var slow = pipeline.Report.init(testing.allocator);
        defer slow.deinit();
        var by_path = try helpers.reported(a, b, op, .{ .fast_paths = false }, &slow);
        defer by_path.deinit();
        try testing.expect(fast.by_containment);
        try testing.expectEqual(by_path.counts(), by_table.counts());
        try testing.expectApproxEqAbs(try volume(&by_path), try volume(&by_table), CLOSE);
    }
}

test "degeneracy: a hole that was a lone slit leaves no point in the face; a point in a face is no fragment" {
    // The solids fuzzer's seventh find (2026-11-13): two boxes joined with a face in one
    // plane (y = 3), the first's corner edges lying in the second's face; merged, a hole of
    // the face was a lone slit, its spur's far vertex went and its near one was left a loop
    // of one vertex (the pass's edge counts, stale once a bridge had gone, said something
    // else used it). The next boolean, with a box apart, went by the containment table,
    // which sewed that loop as an empty one: an edge with three uses
    var a = try box(.{ 0.5, 0, 1 }, .{ 3.5, 3, 2 });
    defer a.deinit();
    var c = try box(.{ 3, 2, -0.5 }, .{ 5, 3, 3.5 });
    defer c.deinit();
    var joined = try sound(&a, &c, .@"union");
    defer joined.deinit();
    try testing.expect(!hasPointLoop(&joined));
    var above = try box(.{ 1.5, 1, 4 }, .{ 2.5, 2, 5 });
    defer above.deinit();
    try expectTableAgrees(&joined, &above);
    // A point in a face (a valid body: `mvh`) bounds nothing, on either path
    var dotted = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer dotted.deinit();
    const top = helpers.facing(&dotted, .{ 0, 0, 1 });
    const centre = try dotted.geometry.addPoint(testing.allocator, .{ 1, 1, 2 });
    _ = try @import("../topology/euler.zig").mvh(&dotted, @import("../topology/types.zig").FaceIndex.of(top), centre);
    try testing.expect(hasPointLoop(&dotted));
    var away = try box(.{ 5, 0, 0 }, .{ 6, 1, 1 });
    defer away.deinit();
    try expectTableAgrees(&dotted, &away);
}
