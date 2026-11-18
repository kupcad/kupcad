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
const mat = @import("../math/mat.zig");
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const mass = @import("../measure/mass.zig");
const decompose = @import("../construct/decompose.zig");
const check = @import("../topology/check.zig");
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
const types = @import("../topology/types.zig");
const VertexIndex = types.VertexIndex;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
const CLOSE = 1e-9;
/// OCCT's bug33361 (research/occt-tests.md, O6): four convex hexahedra from a real model,
/// their corners meant to meet 9.6e-5 to 1.7e-4 apart, coordinates near 128; its own
/// numbers, as the case gives them.
const BUG33361 = [4][8]Vec3{
    .{ .{ -13.1319809553115, 86.7822037750006, -0.00566973476865229 }, .{ -128.558636709231, 86.5345485791916, -0.00570258843333704 }, .{ -100.69915263562, -4.39311321186025, -0.00566084285433277 }, .{ -79.6175928285065, -4.39310160958954, -0.0056548256445943 }, .{ -14.129603767474, 86.2679145189996, -19.5413698283793 }, .{ -127.672333074639, 86.0243014066245, -19.5414021458256 }, .{ -99.9691824161271, -4.39312007067491, -19.5413606345018 }, .{ -80.240198192502, -4.39310921279638, -19.5413550033513 } },
    .{ .{ 127.874808332641, 87.0848242748098, -0.00573631640736139 }, .{ 4.13755363440343, 86.8193381629493, -0.00577153550167253 }, .{ 87.7714933163724, -4.39312459253253, -0.00571376462476536 }, .{ 108.964655532952, -4.39311292884125, -0.00570771556087379 }, .{ 127.250964034433, 86.5713396058731, -19.5413363036311 }, .{ 5.24619819968578, 86.3095706585265, -19.5413710296105 }, .{ 88.4127315018899, -4.39313150014382, -19.5413135815986 }, .{ 108.446956291808, -4.39312047427561, -19.5413078633248 } },
    .{ .{ 108.933394491783, -4.52270499989385, -0.0678854291688111 }, .{ 71.6392583557696, -4.82783796975667, 0.111191412258037 }, .{ 71.3588792617103, 151.745015502843, 0.0366204967163988 }, .{ 127.845048470054, 86.9672826319557, -0.202979251077327 }, .{ 109.955308180154, -5.58542764710532, 46.9881961078522 }, .{ 70.0688762581537, -5.90713971196433, 46.9762651891041 }, .{ 69.7567011034265, 151.061981157248, 47.828071244823 }, .{ 128.441716305279, 83.7679782847199, 47.4778456953173 } },
    .{ .{ -122.825413548196, 67.8222420317801, -0.00583425335077337 }, .{ 121.414994525437, 55.8353479065558, -0.00563439528369258 }, .{ 127.874867553719, 87.0848594871004, -0.00564196037409204 }, .{ -128.558663169796, 86.5344601820726, -0.00584644818335889 }, .{ -122.343446023918, 68.6316879811904, -19.5414411166127 }, .{ 121.07295954832, 56.6852348873057, -19.5412518461508 }, .{ 127.250997928568, 86.5713737315812, -19.5412353309277 }, .{ -127.67235532236, 86.0242158147956, -19.5414386144761 } },
};
/// OCCT's C6 and D4 (corpus_test.zig's `TURNED`): a box √31/4 long, ¼ or ½ wide, turned
/// 34.73° about its corner at the origin against the unit box.
const BAR_TURN = std.math.degreesToRadians(34.73);
const BAR_LENGTH = @sqrt(31.0) / 4.0;
/// The scales the probes take D4's neck to (3.85e-4 wide at 1: 19, 2, 1 and ½
/// intersection tolerances) and C6's spike (1.53e-3 at 1: 77, 2, 1 and ½).
const D4_SCALES = [_]f64{ 1, 0.104, 0.052, 0.026 };
const C6_SCALES = [_]f64{ 1, 0.026, 0.013, 0.0065 };
/// H7's bar (0.1 wide) thinned to these many intersection tolerances.
const H7_WIDTHS = [_]f64{ 5, 3, 1.5 };
/// How far the spec case's second box stands over the first's height and depth: within
/// the zone, and five intersection tolerances.
const OVERSIZES = [_]f64{ 1e-6, 1e-4 };

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

/// `op` of `a` and `b` refused as lying at the intersection tolerance to rounding.
fn expectAtTolerance(a: *const Body, b: *const Body, op: pipeline.Op) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    if (pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, null)) |result| {
        var made = result;
        made.deinit();
        std.debug.print("boolean {s}: a result, where the tolerance to rounding was expected\n", .{@tagName(op)});
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.Degenerate, err);
        try testing.expectEqual(diagnostics.Code.at_tolerance, diag.first().?.code);
    }
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
    // The identity of a cut: its two sides make the whole
    for ([_]struct { Vec3, f64 }{ .{ .{ 1, 1, 1 }, 2.0 / @sqrt(3.0) }, .{ .{ 1, 1, 0 }, @sqrt(2.0) } }) |plane| {
        const sides = try trim.splitByPlane(testing.allocator, &a, plane[0], plane[1], .{}, &diag);
        var front = sides[0];
        defer front.deinit();
        var back = sides[1];
        defer back.deinit();
        try testing.expectApproxEqAbs(@as(f64, 8), try volume(&front) + try volume(&back), CLOSE);
    }
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
    // The identities on each step of the chain
    try expectIdentities(&plate, &q1);
    var first = try sound(&plate, &q1, .difference);
    defer first.deinit();
    try expectIdentities(&first, &q3);
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
    try expectIdentities(&a, &b);
}

test "degeneracy: a box's face 1.5e-4 off a plate's side plane and 2 across it, turned 0.3 rad: the two meet nowhere, as in place" {
    // The 10K fuzz session on 2b26eef1 (the solids moved whole): at a tolerance of 2e-4 a
    // box's face y = 2.00015 lies within it of the plane of a plate's side y = 2, the box
    // 2 above the plate. Turned 0.3 rad about y, the plate's box in its trees grew over
    // the other's and faceFace took the two faces for one plane, sharing no vertex; the
    // box's face was given the plate's plane, moved 1.5e-4, and a hull's corner 1.5e-4
    // over it was on it in place and off it turned. Faces that share no merged vertex do
    // not meet: either way the operands meet nowhere and keep their planes
    const t = Tolerance.fromZone(1e-4);
    var plate = try helpers.boxAt(t, .{ -48, -48, 0 }, .{ 52, 2, 1 });
    defer plate.deinit();
    var block = try helpers.boxAt(t, .{ 1, 1, 3 }, .{ 4, 2.00015, 4 });
    defer block.deinit();
    for ([_]f64{ 0, 0.3 }) |angle| {
        var a = try turned(&plate, .{ 0, 0, 0 }, .{ 0, 1, 0 }, angle);
        defer a.deinit();
        var b = try turned(&block, .{ 0, 0, 0 }, .{ 0, 1, 0 }, angle);
        defer b.deinit();
        var report = pipeline.Report.init(testing.allocator);
        defer report.deinit();
        var joined = try helpers.soundReported(&a, &b, .@"union", &report);
        defer joined.deinit();
        try testing.expect(report.by_containment);
        // The rounding of the turned corners alone; the box's face moved would be 4.5e-4
        try testing.expect(report.shift < CLOSE);
        try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&joined));
    }
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
    try expectIdentities(&a, &b);
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

test "degeneracy: a cut whose corner touches the face it was cut from is pinched at a point, and a void touching it so, refused by design" {
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
    // Wholly inside, the cut is a void touching the side at its corner: shells of one solid
    // touching, refused by design as the pocket is (Leo, 2026-11-14: a void apart from its
    // outer shell, as STEP's brep_with_voids holds it); union and intersection are sound
    var inside = try tetrahedron(.{ 2, 1, 1 }, .{ 1, 0.5, 0.5 }, .{ 1, 1.5, 0.5 }, .{ 1, 1, 1.5 });
    defer inside.deinit();
    diag.clear();
    try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, &a, &inside, .difference, .{}, &diag, null));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    var whole = try sound(&a, &inside, .@"union");
    defer whole.deinit();
    try expectShape(&whole, 8, 6, 1);
    var held = try sound(&a, &inside, .intersection);
    defer held.deinit();
    try testing.expectApproxEqAbs(try volume(&inside), try volume(&held), CLOSE);
    // From outside, the corner on the face makes two solids touching at a point, which pass
    var outside = try tetrahedron(.{ 2, 1, 1 }, .{ 3, 0.5, 0.5 }, .{ 3, 1.5, 0.5 }, .{ 3, 1, 1.5 });
    defer outside.deinit();
    var both = try sound(&a, &outside, .@"union");
    defer both.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&both));
    var cut = try sound(&a, &outside, .difference);
    defer cut.deinit();
    try expectShape(&cut, 8, 6, 1);
    // The identities where every result is made: the corner from outside
    try expectIdentities(&a, &outside);
}

test "degeneracy: a sliver one intersection tolerance thick, crossed by a face, kept or collapsed" {
    // The solids fuzzer's second find (2026-11-13), reduced: a box overlapping another by
    // the intersection tolerance and standing out of its top, its sides crossing the top in
    // pieces that long. Just past the tolerance the sliver is kept: the paves put such a
    // piece's far end off the top's edge while its middle is within the zone of it, and the
    // paves decide (the piece is imprinted); a sample of the sliver's strip on the other's
    // face gives way to the next one. Just within it the faces lie in one plane and the
    // operands touch. Either way the identities hold to the slab the tolerance may count
    // either way (its thickness times the face it lies on) and what the results' faces
    // moved onto their coplanar groups' planes (the reports' shift, D28): just within, the
    // union's face above the top is the top's plane, the sliver's height under it.
    const xsect = tol.xsect;
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    for ([_]f64{ 1 + 1e-6, 1 - 1e-6 }) |by| {
        var b = try box(.{ 0.5, -1, 1 }, .{ 1.5, xsect * by, 3 });
        defer b.deinit();
        var reports: [3]pipeline.Report = .{ .init(testing.allocator), .init(testing.allocator), .init(testing.allocator) };
        defer for (&reports) |*r| r.deinit();
        var u = try helpers.soundReported(&a, &b, .@"union", &reports[0]);
        defer u.deinit();
        try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&u));
        var i = try helpers.soundReported(&a, &b, .intersection, &reports[1]);
        defer i.deinit();
        var d = try helpers.soundReported(&a, &b, .difference, &reports[2]);
        defer d.deinit();
        const slab = xsect * 1 * 1;
        const vi = try volume(&i);
        if (by > 1) try testing.expectApproxEqAbs(slab * by, vi, 1e-12) else try testing.expect(i.isEmpty());
        const va = try volume(&a);
        const vb = try volume(&b);
        try testing.expectApproxEqAbs(va + vb, try volume(&u) + vi, slab + reports[0].shift + reports[1].shift);
        try testing.expectApproxEqAbs(va - vi, try volume(&d), slab + reports[1].shift + reports[2].shift);
    }
}

test "degeneracy: a cut parallel to an edge just past the intersection tolerance leaves end faces narrower than the zone, refused by design; farther, made" {
    // The 10K fuzz session's find (2026-11-14), reduced: a plane 2.4e-5 from a box's edge,
    // past the intersection tolerance so the paves keep the edge off it, its edge's side
    // kept, a prism whose ends are right triangles the zone in inradius. The paves decide
    // distances and keep everything past the tolerance distinct; how narrow a face may be
    // is the checker's sliver rule, which a cut a distance d from an edge of dihedral
    // angle θ meets with end faces of inradius d·sin(θ/2)/(1 + sin(θ/2)): 0.41·d at a right
    // angle, under the zone until d is 1.2 tolerances. A result the model cannot hold is
    // refused, as the builder refuses such a body, by the checker's own finding.
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    // (x − z)/√2 ≥ 1/√2 − d: the part within d of the edge x = 1, z = 0
    const normal: Vec3 = .{ 1, 0, -1 };
    const edge = 1.0 / @sqrt(2.0);
    {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.Degenerate, trim.trimByPlane(testing.allocator, &a, normal, edge - 1.1 * tol.xsect, .{}, &diag, null));
        errdefer std.debug.print("{f}\n", .{diag});
        try testing.expectEqual(diagnostics.Code.sliver_face, diag.first().?.code);
        try testing.expectEqual(diagnostics.EntityKind.face, diag.first().?.entity.kind);
    }
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const d = 1.5 * tol.xsect;
    var kept = try trim.trimByPlane(testing.allocator, &a, normal, edge - d, .{}, &diag, null);
    defer kept.deinit();
    var report = try check.run(testing.allocator, &kept, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    // A right triangle d from its hypotenuse is d² in area, the prism 1 long
    try testing.expectApproxEqRel(d * d, try volume(&kept), 1e-6);
    try testing.expectEqual(@as(usize, 5), kept.counts().faces);
}

test "degeneracy: a hull through a cavity and its wall 1.5 tolerances thick (once pieces of one face in different shells): the wall below the minimum feature size, refused" {
    // The 10K fuzz session's second find (2026-11-14), the chain's last step: the box cuts
    // a face of the hull into a piece inside the cavity and one outside the box with a
    // notch where the box is, both in the face's plane, in different shells. The overlap
    // rules' sample of the inner piece lies in the notch, in the outer piece's plane but
    // off it; the outer piece's solid angle summed by a fan from one corner, whose
    // triangles overlap outside a face that is not convex, cancelled only by the signs of
    // the rounding of each one's height, and the shell wound 1 there: "shell 0 lies in
    // material". The booleans were right; their results are sound, the identities hold.
    const coarse = Tolerance.fromZone(1e-4);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const corners = [_]Vec3{ .{ 1.999995, 2.5, 2e-5 }, .{ -5e-6, 1, 4.00002 }, .{ 3.999995, 1.5, 4.00002 }, .{ 1.999995, 2.5, 2.00002 } };
    var h = try @import("../construct/hull.zig").hull(testing.allocator, coarse, &corners, &diag);
    defer h.deinit();
    const half = 1.5 * coarse.xsect / 2;
    var outer = try helpers.boxAt(coarse, .{ 0.23, 1, 1 }, .{ 1.98 + half, 4, 3 });
    defer outer.deinit();
    var cavity = try helpers.boxAt(coarse, .{ 0.48, 1.25, 1.25 }, .{ 1.98 - half, 3.75, 2.75 });
    defer cavity.deinit();
    var wall = try sound(&outer, &cavity, .difference);
    defer wall.deinit();
    // Since the operand precondition (2026-11-15, Leo: one refusal before the paves in
    // place of those added find by find) the wall is below the boolean's minimum feature
    // size: refused whatever reaches it, every operation either way round.
    try expectBelowFeatureSize(&h, &wall);
}

test "degeneracy: a hull through a wall 1.25 tolerances thick into its cavity (once its section met the cavity's side by a gap): the wall below the minimum feature size, refused" {
    // The 10K fuzz session's third run (2026-11-14, locus_solids), reduced: a hull's face
    // crosses the wall's two sides, its section along the outer one from a corner merged
    // onto the wall's edge (a gap of 9.7e-6) to where a hull edge enters, which lies over
    // the cavity's side 2.5e-5 off. The overlap rules took that section as lying in the
    // cavity's plane by its reach (the tolerance and its ends' larger gap, 2.97e-5) and
    // both its ends as on it, so the union's outer shell touched its own void there,
    // "pinched"; the paves had kept that end apart by its own reach, 2e-5. An edge lying
    // in a plane meets it at those of its ends within their own reach.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const corners = [_]Vec3{ .{ 1, 4, 2 }, .{ 3, 2, 1 }, .{ 1, 3, 1 }, .{ 4, 0, 2 }, .{ 4, 4, 2 }, .{ 0, 2, 1 }, .{ 3, 4, 1 } };
    var points: [corners.len]Vec3 = undefined;
    for (corners, &points) |c, *p| p.* = vec.add(c, .{ 5e-6, 0.5, -2e-5 });
    var h = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h.deinit();
    const half = 1.25 * tol.xsect / 2;
    var outer = try box(.{ -1.25, 2.99998, -2e-5 }, .{ 0.5 + half, 3.99998, 1.99998 });
    defer outer.deinit();
    var cavity = try box(.{ -1, 3.24998, 0.24998 }, .{ 0.5 - half, 3.74998, 1.74998 });
    defer cavity.deinit();
    var wall = try sound(&outer, &cavity, .difference);
    defer wall.deinit();
    // Since the operand precondition (2026-11-15, Leo: one refusal before the paves in
    // place of those added find by find) the wall is below the boolean's minimum feature
    // size: refused whatever reaches it, every operation either way round.
    try expectBelowFeatureSize(&h, &wall);
}

test "degeneracy: a plate 1.9 tolerances thick with a hull's edge on its bottom (once the plane chosen for two bottoms): the plate below the minimum feature size, refused" {
    // The 10K fuzz session's fourth run (2026-11-14, locus), reduced: a plate 1.9
    // tolerances thick with a hull's edge 1.4e-5 over its bottom, lying on it, and a second
    // plate whose bottom is 1e-5 under the first's. The paves found the bottoms in one
    // plane; with the second plate first, the group took its plane, which held the first
    // bottom's corners but not the hull's edge on it (2.4e-5 off, past the tolerance the
    // checker holds an edge to): the union failed the checker, the operands swapped. The
    // plane chosen holds every piece's line too: the first bottom's, either way round.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const half = 1.9 * tol.xsect / 2;
    var lower = try box(.{ 2, 1.00002, 3 - half + 1e-5 }, .{ 4, 4.00002, 3 + half + 1e-5 });
    defer lower.deinit();
    const corners = [_]Vec3{ .{ 0, 2, 3 }, .{ 1, 0, 4 }, .{ 4, 4, 3 }, .{ 4, 0, 0 }, .{ 0, 3, 2 }, .{ 1, 0, 2 }, .{ 0, 2, 2 } };
    var points: [corners.len]Vec3 = undefined;
    for (corners, &points) |c, *p| p.* = vec.add(c, .{ 1, 5e-6, 5e-6 });
    var h = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h.deinit();
    // Since the operand precondition (2026-11-15) a plate 1.9 tolerances thick is below
    // the boolean's minimum feature size: the chain stops at its first step
    try expectBelowFeatureSize(&lower, &h);
}

test "degeneracy: a strip of a face under the other's face rising at 26.6°, no sample clear of it, takes its side from the faces at its section" {
    // The 10K fuzz session's fourth run (2026-11-14, locus_solids), reduced: a hull's
    // ridge lies in a box's side 2.5e-5 above the side's bottom edge, its far face rising
    // from it at 26.6° to the side. The strip of the side under the ridge is inside the
    // hull, but no point of it is farther than 1.1e-5 from the hull's face, so every sample
    // lay within the zone of its boundary (`unclassified`). A fragment bordering a piece of
    // the other's boundary takes its side from the faces there (OCCT's IsInternalFace; Leo,
    // 2026-11-14): under the ridge, behind both the hull's faces, it is inside.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try box(.{ 1.998, 3, 2.999995 }, .{ 3.998, 4, 3.999995 });
    defer a.deinit();
    var b = try @import("../construct/hull.zig").hull(testing.allocator, tol, &.{ .{ 1.99999, 3, 0.00002 }, .{ 3.99999, 0, 3.00002 }, .{ -0.00001, 0, 3.00002 }, .{ -0.00001, 4, 1.00002 }, .{ 3.99999, 3, 3.00002 }, .{ 0.99999, 3, 3.00002 } }, &diag);
    defer b.deinit();
    try expectProbe(&a, &b);
}

test "degeneracy: a tetrahedron's tip through a box's top by 2.45e-5, its section's every sample within the zone of it, takes its side from the faces at its sections" {
    // The section of a regular tetrahedron's tip 2.45e-5 through the top is an equilateral
    // triangle 3e-5 a side (past the intersection tolerance) and 8.7e-6 in inradius, so no
    // sample of it, nor of the tip's faces under the top, is farther than the zone from the
    // other operand; neither has a twin. Each takes its side from the faces about its
    // pieces (OCCT's IsInternalFace; Leo, 2026-11-14): the top's triangle behind the tip's
    // three faces, inside; the tip's faces under the top, inside. Made, or refused for the
    // slivers left, never unclassified.
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    const depth = 2.45e-5;
    // A regular tetrahedron of height 1 standing on its tip: its base's circumradius √2/2
    const r = @sqrt(2.0) / 2.0;
    var corners: [4]Vec3 = undefined;
    corners[0] = .{ 0.5, 0.5, 1 - depth };
    for (0..3) |k| {
        const angle = std.math.pi / 2.0 + @as(f64, @floatFromInt(k)) * 2.0 * std.math.pi / 3.0;
        corners[k + 1] = .{ 0.5 + r * @cos(angle), 0.5 + r * @sin(angle), 2 - depth };
    }
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var tip = try @import("../construct/hull.zig").hull(testing.allocator, tol, &corners, &diag);
    defer tip.deinit();
    try expectProbe(&a, &tip);
}

test "degeneracy: a face in one plane with a wall's side 1.25 tolerances off its cavity (once the plane chosen): the wall below the minimum feature size, refused" {
    // The 10K fuzz session's sixth run (2026-11-15, locus_solids), reduced: a block in a
    // wall's material above its cavity, its side 7.5e-6 inside the wall's outer side, one
    // plane with it. The group took the first operand's plane, the block's, and moved the
    // wall's whole side 7.5e-6 in, 1.75e-5 from the cavity's side it was 2.5e-5 from: the
    // union's void touched its outer shell (the overlap rules: pinched). The plane chosen
    // keeps every face it moves off its own operand's features: the wall's here.
    const xsect = tol.xsect;
    var outer = try box(.{ 0.25, 0, 0 }, .{ 2 + 0.625 * xsect, 4, 2 });
    defer outer.deinit();
    var cavity = try box(.{ 0.5, 0.25, 0.25 }, .{ 2 - 0.625 * xsect, 3.75, 1.75 });
    defer cavity.deinit();
    var wall = try sound(&outer, &cavity, .difference);
    defer wall.deinit();
    var block = try box(.{ 1.9, 0.5, 1.8 }, .{ 2 + 0.25 * xsect, 1, 2 });
    defer block.deinit();
    // Since the operand precondition (2026-11-15) the wall is below the boolean's minimum
    // feature size, refused before a plane is chosen
    try expectBelowFeatureSize(&block, &wall);
}

test "degeneracy: two walls' sides in one plane, each 1.25 tolerances off its cavity: each wall below the minimum feature size, refused" {
    // Each wall's side is 2.5e-5 from its own cavity's side and 3.75e-6 past the plane
    // between them, over a strip where the walls meet; either side's plane takes the other
    // within 1.75e-5 of its cavity, so no plane of the group holds both apart
    const xsect = tol.xsect;
    const half = 0.1875 * xsect;
    var outer_a = try box(.{ 0, 0, 0 }, .{ 2 + half, 4, 2 });
    defer outer_a.deinit();
    var cavity_a = try box(.{ 0.25, 0.25, 0.25 }, .{ 2 + half - 1.25 * xsect, 3.75, 1.75 });
    defer cavity_a.deinit();
    var a = try sound(&outer_a, &cavity_a, .difference);
    defer a.deinit();
    var outer_b = try box(.{ 2 - half, 0, 1.8 }, .{ 4, 4, 4 });
    defer outer_b.deinit();
    var cavity_b = try box(.{ 2 - half + 1.25 * xsect, 0.25, 2.05 }, .{ 3.75, 3.75, 3.75 });
    defer cavity_b.deinit();
    var b = try sound(&outer_b, &cavity_b, .difference);
    defer b.deinit();
    // Refused by the provenance's plane choice until the operand precondition
    // (2026-11-15), which refuses either wall before the paves
    try expectBelowFeatureSize(&a, &b);
}

test "degeneracy: a hull's edge within the tolerance of a plate's two front edges 2.5e-5 apart: the plate below the minimum feature size, refused" {
    // The nightly solids fuzzer (2026-11-14, locus_solids), reduced: a plate 1.25
    // tolerances thick, a hull's edge rising at 45° across its front 1.9e-5 from the top
    // edge and 1.8e-6 from the bottom one. Its crossing with the top edge welded to the
    // bottom one's vertex, 1.8e-5 along it, and the top edge's piece ended at that vertex
    // 2.56e-5 off its line (the checker: a vertex off its curve's end). A crossing welds to
    // a vertex only within its reach of both edges; beyond it, the features are closer
    // than the minimum feature size, refused either way round.
    var plate = try box(.{ -0.5, 1, -7.5e-6 }, .{ 1.5, 2, 1.75e-5 });
    defer plate.deinit();
    const corners = [_]Vec3{ .{ 1, 1, 2 }, .{ 4, 4, 1 }, .{ 1, 4, 0 }, .{ 0, 3, 3 }, .{ 0, 0, 0 } };
    var points: [corners.len]Vec3 = undefined;
    for (corners, &points) |c, *p| p.* = vec.add(c, .{ -5e-6, 1e-5, -1 });
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer hull.deinit();
    // Refused at the weld (66cb4442) until the operand precondition (2026-11-15), which
    // refuses the plate, 2.5e-5 thick, before the paves
    try expectBelowFeatureSize(&plate, &hull);
}

test "degeneracy: a flat tetrahedron's face 3.8e-5 rad off a plate 1.25 tolerances thick, within the tolerance of its top and bottom at once: both below the minimum feature size, refused" {
    // The nightly solids fuzzer (2026-11-14, locus), reduced: a tetrahedron 1.9 tolerances
    // thick across a plate 1.25 thick, one top face rising 3.8e-5 rad from the plate's top
    // and within the tolerance of its top and its bottom at once over x 2.04–2.43. Their
    // sections, through merged vertices, lay at the band's edge, the face's piece over the
    // plate was classified against them (an edge with three faces), and with the plate
    // first the records made the union pinched and the intersection a sliver where the
    // tetrahedron first made both sound. No decision of the tolerance is consistent: the
    // plate's sides are closer than twice the tolerance where they do not meet, and the
    // face reaches both (Leo, 2026-11-15). Refused, every operation either way round. A
    // post crossing the plate steeply reaches both sides too, along its sections, which
    // lie 2.5e-5 apart where the paves put them: made and sound.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var tet = try @import("../construct/hull.zig").hull(testing.allocator, tol, &.{ .{ 2, 3.99999, -9e-6 }, .{ 4, 3.99999, -9e-6 }, .{ 3, 2.99999, 2.9e-5 }, .{ 3, 4.99999, 2.9e-5 } }, &diag);
    defer tet.deinit();
    var plate = try box(.{ 1, 3, -1.25e-5 }, .{ 3, 4, 1.25e-5 });
    defer plate.deinit();
    // Refused as a face sandwiched between two (d1743fcd), and a post through the plate
    // made, until the operand precondition (2026-11-15): the plate, 2.5e-5 thick, and
    // the tetrahedron, its edges 3.8e-5 apart, are below the boolean's minimum feature
    // size, refused whatever reaches them
    try expectBelowFeatureSize(&tet, &plate);
    var post = try box(.{ 1.5, 3.2, -1 }, .{ 2.5, 3.8, 1 });
    defer post.deinit();
    try expectBelowFeatureSize(&post, &plate);
}

test "degeneracy: a hull's edge ending 3.1e-5 over a slot's bottom, its line 2.4e-5 (the plate below the minimum feature size, refused), and two hulls' difference: made and sound" {
    // The nightly solids fuzzer (2026-11-15, locus_solids and locus), reduced: a hull's
    // edge crosses a plate 1.9 tolerances thick at its front, 1.4e-5 under its top front
    // edge, where the paves merged their crossing with a gap of 6.8e-6. The overlap rules
    // took the edge's end as on the slot's bottom by its curve's end, 2.4e-5 off, and the
    // reach of the vertex (the tolerance and its gap): the vertex itself is 3.1e-5 off, and
    // the hull's top "touched" the slot's bottom, pinched. An end is on a plane by its
    // vertex's own reach, as the paves put a vertex on a face; so too two hulls' (an
    // intersection's leftover touching its own face).
    const Hull = struct {
        fn of(corners: []const Vec3, shift: Vec3) !Body {
            var points: [8]Vec3 = undefined;
            for (corners, 0..) |c, i| points[i] = vec.add(c, shift);
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            return @import("../construct/hull.zig").hull(testing.allocator, tol, points[0..corners.len], &diag);
        }
    };
    var wedge = try Hull.of(&.{ .{ 2, 4, 2.5 }, .{ 2, 2, 0.5 }, .{ 4, 2, 2.5 }, .{ 2, 0, 1.5 } }, .{ -2e-5, -2e-5, 0 });
    defer wedge.deinit();
    var plate = try box(.{ 0.999995, 2.00002, 2 - 1.4e-5 }, .{ 3.999995, 3.00002, 2 + 2.4e-5 });
    defer plate.deinit();
    // The plate, 3.8e-5 thick, is below the boolean's minimum feature size since the
    // operand precondition (2026-11-15): refused; the two hulls are made
    try expectBelowFeatureSize(&wedge, &plate);
    var first = try Hull.of(&.{ .{ 3, 0, 2 }, .{ 1, 2, 0 }, .{ 3, 4, 4 }, .{ 4, 4, 3 } }, .{ 2e-5, -2e-5, 2e-5 });
    defer first.deinit();
    var second = try Hull.of(&.{ .{ 4, 3, 1 }, .{ 4, 4, 0 }, .{ 0, 4, 4 }, .{ 1, 2, 3 }, .{ 2, 2, 2 }, .{ 4, 3, 0 }, .{ 3, 3, 2 }, .{ 2, 2, 0 } }, .{ -2e-5, -5e-6, 1e-5 });
    defer second.deinit();
    try expectIdentities(&first, &second);
    try expectIdentities(&second, &first);
}

test "degeneracy: a hull's ridge through a flat tetrahedron 1.5 tolerances thick (once a needle the overlap rules misjudged): the tetrahedron below the minimum feature size, refused" {
    // The nightly solids fuzzer (2026-11-15, locus_solids), reduced: a hull's top edge,
    // turned 0.014 rad, runs through a tetrahedron 1.5 tolerances thick, merged with its
    // upper faces with a gap of 7.4e-6; the hull's two faces there cut its lower edge
    // 4.4e-5 apart. The intersection is a needle 1.5 long and 2.8e-5 thick, each vertex
    // beyond the tolerance of every face it is not on. The overlap rules took an edge of
    // one face to lie in the other's plane by the edge's reach at both ends, the larger
    // end gap's: its end with none, 2.6e-5 off, lay in it, the two faces in one plane
    // (`faces_intersect`). An end is on a plane by its vertex's own reach.
    const Hull = struct {
        fn of(corners: []const Vec3, angle: f64, shift: Vec3) !Body {
            var points: [6]Vec3 = undefined;
            for (corners, 0..) |c, i| points[i] = vec.add(.{ @cos(angle) * c[0] - @sin(angle) * c[1], @sin(angle) * c[0] + @cos(angle) * c[1], c[2] }, shift);
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            return @import("../construct/hull.zig").hull(testing.allocator, tol, points[0..corners.len], &diag);
        }
    };
    var ridge = try Hull.of(&.{ .{ 3, 4, 4 }, .{ 1, 0, 4 }, .{ 3, 4, 2 }, .{ 0, 3, 1 }, .{ 0, 3, 2 }, .{ 3, 4, 1 } }, 0.014, .{ 1, 2e-5, 2e-5 });
    defer ridge.deinit();
    var flat = try Hull.of(&.{ .{ 2, 2, 4 - 1.5e-5 }, .{ 4, 2, 4 - 1.5e-5 }, .{ 3, 1, 4 + 1.5e-5 }, .{ 3, 3, 4 + 1.5e-5 } }, 0, .{ 0, -2e-5, 0 });
    defer flat.deinit();
    // The tetrahedron, its edges 3e-5 apart, is below the boolean's minimum feature size
    // since the operand precondition (2026-11-15): refused. 86b72d89's rule (an edge in a
    // plane by its ends' own reach) stays in the overlap rules, which check any body
    try expectBelowFeatureSize(&ridge, &flat);
}

test "degeneracy: a plate's top 1.8e-4 over a notch's ceiling, at a tolerance of 2e-4: a section and the notch's edge on one line stay two where joined they leave the plate's top, either way round" {
    // The 10K session (2026-11-15, locus_solids), reduced: a box less another leaves a
    // notch whose ceiling, z = 4.00002, is 1.8e-4 under a plate's top at a zone of 1e-4,
    // one plane. On the box's side the plate's top leaves a section whose line runs through
    // its merged vertices, from the plate's top down to the notch's corner; simplify joined
    // the notch's edge onto that line, its far end within the tolerance of the line, and
    // the joined edge ended 3.6e-4 under the plate's top (`edge_off_surface`, the plate
    // first). A join keeps an edge on its faces as the checker does
    var a = try box(.{ 0, 2e-5, 3.5 }, .{ 2, 3.00002, 4.5 });
    defer a.deinit();
    var b = try box(.{ 1.00002, 1.00002, 2e-5 }, .{ 4.00002, 4.00002, 4.00002 });
    defer b.deinit();
    var notched = try sound(&a, &b, .difference);
    defer notched.deinit();
    var plate = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ -97.98, -48, 2.0002 }, .{ 102.02, 52, 4.0002 });
    defer plate.deinit();
    try helpers.expectIdentitiesAtTolerance(&plate, &notched);
    try helpers.expectIdentitiesAtTolerance(&notched, &plate);
}

test "degeneracy: a union's top moved 7e-5 onto a box's plane, a hull's top 1.8e-4 from that plane and 2.5e-4 from its edges: refused" {
    // The nightly (2026-11-15, locus), reduced: a box's top 7e-5 over a plate's, at the
    // plate's tolerance of 2e-4, one plane: the union's top takes the box's, the larger
    // (D28: the plane moving the faces least), its edges on the plate's lines below. A hull's top over it is within the tolerance of the
    // plane and beyond it of the top's edge inside the hull's top: the faces were taken as
    // one plane, the edge imprinted on the hull's top, which the paves had kept off it
    // (`imprint_unmatched`). No decision of the tolerance is consistent: refused, every
    // operation either way round.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var small = try helpers.boxAt(Tolerance.fromZone(1e-5), .{ -49.50002, -48.00002, 2.00002 }, .{ 0.99998, 51.99998, 4.00002 });
    defer small.deinit();
    var plate = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ -7.9998, -2.9999, 0.99995 }, .{ 2.0002, 12.0001, 3.99995 });
    defer plate.deinit();
    var joined = try pipeline.boolean(testing.allocator, &small, &plate, .@"union", .{}, &diag, null);
    defer joined.deinit();
    const corners = [_]Vec3{ .{ 3, 0, 4 }, .{ 1, 4, 2 }, .{ 4, 2, 4 }, .{ 4, 1, 3 }, .{ 4, 0, 2 }, .{ 1, 2, 4 } };
    var points: [corners.len]Vec3 = undefined;
    for (corners, &points) |c, *q| q.* = vec.add(c, .{ 0.5, 5e-5, 2e-4 });
    var hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer hull.deinit();
    for ([2][2]*const Body{ .{ &joined, &hull }, .{ &hull, &joined } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var refusal = Diagnostics.init(testing.allocator);
            defer refusal.deinit();
            if (pipeline.boolean(testing.allocator, operands[0], operands[1], op, .{}, &refusal, null)) |made| {
                var result = made;
                result.deinit();
                return error.TestExpectedError;
            } else |e| {
                errdefer std.debug.print("{s}: {s}, {f}\n", .{ @tagName(op), @errorName(e), refusal });
                try testing.expectEqual(error.Degenerate, e);
                try testing.expectEqual(diagnostics.Code.below_feature_size, refusal.first().?.code);
                try testing.expect(std.mem.indexOf(u8, refusal.first().?.label, "its boundary inside that face beyond reach of its plane") != null);
            }
        }
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
    // hold to that displacement times the result's area, well within the fuzzer's slab.
    // The hull as the fuzzer moved it, by the intersection tolerance exactly, puts an end of
    // its edge that far from the box's face to rounding; its other end lies on that face's
    // plane, which settles that the edge does not cross it, so the end at the tolerance
    // decides nothing: made and sound either way round (refused at_tolerance until the
    // paves asked both ends first, step 1 of closing M4); moved by 1.95e-5 the crossings
    // are as they were (moved by 1.9e-5, nothing folds even without the rule)
    var a = try box(.{ 0, 1, 1 }, .{ 0.5, 2, 3 });
    defer a.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 4, 3, 4 }, .{ 4, 4, 4 }, .{ 1, 4, 3 }, .{ 0, 1, 0 }, .{ 3, 3, 4 }, .{ 0, 4, 0 } };
    var b0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer b0.deinit();
    var at = try helpers.moved(&b0, .{ 2e-5, -0.5, 0 });
    defer at.deinit();
    for ([2][2]*const Body{ .{ &at, &a }, .{ &a, &at } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
    }
    try helpers.expectIdentitiesAtTolerance(&at, &a);
    var b = try helpers.moved(&b0, .{ 1.95e-5, -0.5, 0 });
    defer b.deinit();
    var u = try sound(&b, &a, .@"union");
    defer u.deinit();
    var i = try sound(&b, &a, .intersection);
    defer i.deinit();
    var d = try sound(&b, &a, .difference);
    defer d.deinit();
    // The exact intersection, from its cross-sections in z (2026-11-13)
    const exact = 0.01666325428074834;
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
    try expectIdentities(&a, &c);
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

test "degeneracy: a corner touching a triangular face at its centroid" {
    // The nightly solids fuzzer's find (2026-11-13), reduced: the box's corner (1.5, 3, 3)
    // touches the hull's face (0.5, 3, 2), (3.5, 5, 3), (0.5, 1, 4) from outside at the
    // triangle's centroid, the only point classification sampled the face at: on the
    // box's boundary, the face was unclassified. A triangle now offers three samples
    // besides its centroid, the next tried
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0.5, 5, 4 }, .{ 0.5, 1, 4 }, .{ 3.5, 5, 3 }, .{ 0.5, 3, 2 }, .{ 0.5, 5, 2 } };
    var a = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer a.deinit();
    var b = try box(.{ 1.5, 1, 2 }, .{ 3.5, 3, 3 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
    var i = try sound(&a, &b, .intersection);
    defer i.deinit();
    try testing.expect(i.isEmpty());
    try expectIdentities(&a, &b);
}

test "degeneracy: a hull's edge across a box's floor, passing its corner within the tolerance: the corner is where it meets the corner's edge" {
    // The nightly solids fuzzer's find (2026-11-13, run 43411851511), reduced: a hull moved
    // by the zone touches the box from below along its edge (2.00001, 5, 2)–(4.00001, 1, 2),
    // which crosses the floor from its y = 5 edge to its x = 3 edge at (3, 3.00002, 2),
    // the intersection tolerance and a rounding from the corner (3, 3, 2). The overlap rules
    // took the floor's piece by that crossing and the side x = 3 to meet from (3, 5, 2) to
    // the corner: the gap's middle is within the zone of the piece, its end is not, and the
    // end was taken all the same. A piece of two faces' meet ends at crossings in both
    // (`planar_faces.meet`, on those two faces as they came). The boolean refused the input
    // for a while, the crossing lying the tolerance from the corner to rounding; but the
    // corner is 8.9e-6 from the hull's edge, on it (vertex–edge), and two straight edges
    // meet once (2026-11-16): the corner is where the hull's edge meets the side's, and the
    // crossing is never asked again. Made and sound either way round
    var b = try box(.{ 1, 3, 2 }, .{ 3, 5, 4 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 1, 1, 0 }, .{ 0, 3, 0 }, .{ 2, 2, 1 }, .{ 2, 3, 0 }, .{ 4, 0, 2 }, .{ 0, 2, 0 }, .{ 1, 0, 1 }, .{ 2, 4, 2 } };
    var c0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer c0.deinit();
    var c = try helpers.moved(&c0, .{ 1e-5, 1, 0 });
    defer c.deinit();
    try expectIdentities(&b, &c);
    try expectIdentities(&c, &b);
    // The floor's piece, a triangle (with an apex below it), against the box's side x = 3
    var floor = try tetrahedron(.{ 2.6, 4.3, 1 }, .{ 2.00001, 5, 2 }, .{ 3, 5, 2 }, .{ 3, 3.0000200000000006, 2 });
    defer floor.deinit();
    const planar_faces = @import("../intersect/planar_faces.zig");
    const top = types.FaceIndex.of(helpers.facing(&floor, .{ 0, 0, 1 }));
    const side = types.FaceIndex.of(helpers.facing(&b, .{ 1, 0, 0 }));
    var pieces: std.ArrayList(planar_faces.Piece) = .empty;
    defer pieces.deinit(testing.allocator);
    try testing.expectEqual(planar_faces.Relation.crossing, try planar_faces.meet(testing.allocator, &floor, top, &b, side, tol, &pieces, &diag));
    for (pieces.items) |piece| {
        for ([_]Vec3{ piece.a, piece.b }, [_]f64{ piece.gap_a, piece.gap_b }) |end, gap| {
            try testing.expect(try planar_faces.place(&floor, top, end, gap, tol, &diag) != .outside);
            try testing.expect(try planar_faces.place(&b, side, end, gap, tol, &diag) != .outside);
        }
    }
}

test "degeneracy: a hull's vertex the zone from a box's edge, a hull's edge from it crossing that edge again 4.1e-5 on: they meet once, at the vertex" {
    // The nightly solids fuzzer's find (2026-11-14, run 43515591144): a hull moved by the
    // zone in y has its vertex (2.5, 4.00001, 1) the zone from the box's edge x = 2.5,
    // y = 4, and a hull edge from it crosses that edge 4.1e-5 along: both points within the
    // intersection tolerance of both edges, the edges shared the piece between them, 14
    // degrees off each, and the faces about it were ordered by noise (an edge of four
    // coedges that did not pair). The second crossing then left the intersection a vertex
    // within the tolerance of two of its faces that meet nowhere near it, and the next
    // union was refused by the minimum feature size. Two straight edges meet once
    // (2026-11-16): the vertex, on the box's edge, is where the hull's edge meets it, no
    // second vertex is made, and both booleans are made and sound either way round
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 2, 2, 3 }, .{ 4, 3, 4 }, .{ 2, 3, 3 }, .{ 1, 0, 3 }, .{ 1, 1, 2 }, .{ 4, 4, 0 }, .{ 3, 2, 3 }, .{ 4, 1, 4 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    const place = mat.Affine.translate(.{ 0.5, 1e-5, 1 }).compose(&mat.Affine.scaleBy(.{ 0.5, 1, 1 }));
    var h = try @import("../construct/transform.zig").transform(testing.allocator, &h0, &place, .{}, &diag);
    defer h.deinit();
    var slab = try box(.{ 1, 3, 1 }, .{ 5, 7, 3 });
    defer slab.deinit();
    var piece = try sound(&h, &slab, .intersection);
    defer piece.deinit();
    var post = try box(.{ 2.5, 0, -1 }, .{ 3.5, 4, 3 });
    defer post.deinit();
    try expectIdentities(&piece, &post);
    try expectIdentities(&post, &piece);
}

test "degeneracy: a vertex the intersection tolerance off a face, its edge leaving it at a shallow angle" {
    // The nightly solids fuzzer's find (2026-11-13, run 43413453969), as it came: a hull
    // moved by the intersection tolerance cut from a turned box leaves vertices on the
    // plane x = 1.00002; a box with a face on x = 1 united with it takes them for points of
    // that face (vertex–face: within the tolerance), and an edge leaving one of them at 5°
    // crosses x = 1 exactly 2e-4 further, inside the face, where the boolean made no edge.
    // The overlap rules took that exact crossing for a point of both faces off one's
    // boundary; they now take a crossing as the boolean does, an end within the tolerance
    // and its gap being the edge's crossing. Moved by the tolerance exactly, as the fuzzer
    // moved it, the hull lies that far from the box to rounding: the boolean refuses
    // (`at_tolerance`); moved by 1.9e-5 the vertices are on the face and the edge crosses
    // as it did
    var a0 = try box(.{ 1, 1, 2 }, .{ 2, 3, 4 });
    defer a0.deinit();
    var a = try turned(&a0, .{ 2, 2, 2 }, .{ 1, 2, 3 }, std.math.pi / 4.0);
    defer a.deinit();
    var a_moved = try helpers.moved(&a, .{ -1, 0, -0.5 });
    defer a_moved.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0, 4, 1 }, .{ 3, 1, 2 }, .{ 1, 1, 0 }, .{ 1, 2, 0 }, .{ 1, 1, 4 }, .{ 2, 1, 2 }, .{ 1, 0, 3 } };
    var b0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer b0.deinit();
    var c = try box(.{ 1, 0.5, 3 }, .{ 4, 1.5, 4 });
    defer c.deinit();
    var at = try helpers.moved(&b0, .{ 2e-5, 1, 0 });
    defer at.deinit();
    var cut_at = try sound(&a_moved, &at, .difference);
    defer cut_at.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| try expectAtTolerance(&cut_at, &c, op);
    var b = try helpers.moved(&b0, .{ 1.9e-5, 1, 0 });
    defer b.deinit();
    var cut = try sound(&a_moved, &b, .difference);
    defer cut.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
        var r = try sound(&cut, &c, op);
        r.deinit();
    }
}

test "degeneracy: operands the intersection tolerance apart to rounding are refused, a hair either side decided" {
    // The nightly solids fuzzer's find (2026-11-13, run 43417538617): a hull moved by the
    // intersection tolerance exactly put its face 2.0000000000131e-5 from a box's, a
    // rounding past the tolerance, while its vertices' heights over the box's plane came out
    // a rounding inside it; the paves took the faces apart and the vertices on, a sliver
    // the tolerance wide was left that no sample could classify, and the shell did not
    // close. A distance within rounding of the tolerance is refused (`at_tolerance`), a
    // stage of the paves named; a hair either side is decided
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var at = try box(.{ 1 + tol.xsect, 0, 0 }, .{ 2, 1, 1 });
    defer at.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| try expectAtTolerance(&a, &at, op);
    // Within it: the faces touch, one solid; beyond it: two, a warned sliver of air between
    var touching = try box(.{ 1 + 0.95 * tol.xsect, 0, 0 }, .{ 2, 1, 1 });
    defer touching.deinit();
    var joined = try sound(&a, &touching, .@"union");
    defer joined.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&joined));
    var apart = try box(.{ 1 + 1.05 * tol.xsect, 0, 0 }, .{ 2, 1, 1 });
    defer apart.deinit();
    var both = try sound(&a, &apart, .@"union");
    defer both.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&both));
    // The find as it came
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 3, 3, 4 }, .{ 0, 1, 2 }, .{ 3, 1, 3 }, .{ 3, 1, 1 }, .{ 2, 2, 3 }, .{ 1, 4, 0 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    var h = try helpers.moved(&h0, .{ 2e-5, 0, 0 });
    defer h.deinit();
    var c = try box(.{ 1, 1, 2 }, .{ 3, 3, 4 });
    defer c.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| try expectAtTolerance(&h, &c, op);
}

test "degeneracy: a vertex the tolerance off an edge in its end's strip, not its end, is refused" {
    // A tetrahedron's apex 1.5e-5 up a box's edge from its end and 1.5e-5 off it (the
    // intersection tolerance 2e-5): within the tolerance of the edge, where its end's ball
    // keeps it from being split, and 2.1e-5 from the end, too far to be it. The paves
    // skipped it; the faces about the edge met it where the edge had no vertex, a
    // fragment's loop split where the interferences found no point (IntersectionFailed).
    // Too near the end to split at, too far to merge: refused (OCCT validates its pave
    // blocks after splitting)
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try tetrahedron(.{ -1.5e-5, 0, 1.5e-5 }, .{ -1, -1, 0.5 }, .{ -1, 0.5, -1 }, .{ 0.5, -1, -1 });
    defer b.deinit();
    for ([_]pipeline.Op{ .@"union", .difference }) |op| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.TooSmallEdge, pipeline.boolean(testing.allocator, &a, &b, op, .{}, &diag, null));
        try testing.expectEqual(diagnostics.Code.edge_too_short, diag.first().?.code);
    }
}

test "degeneracy: two edges at a shallow angle, one's end on the other, meet once: no second crossing where they run within the tolerance" {
    // The solids fuzzer's find (2026-11-16, 10K session on cb4fcdbb), at one tolerance: a
    // box turned 0.007 rad about its front-right corner, that corner 3e-6 inside a plate's
    // front face and its bottom on the plate's bottom. The corner is on the plate's
    // front-bottom edge (vertex–edge), and the box's front-bottom edge, leaving it at 0.007
    // rad, stays within the tolerance of the plate's for 3e-3; edge–edge crossed the two
    // again 4.3e-4 on. At the bottom the front faces met there, at the top at the corner's
    // edge: the difference's two front faces passed through each other (faces_intersect)
    const angle = 0.007;
    var plate = try box(.{ -1, 1, 0 }, .{ 3, 3, 1 });
    defer plate.deinit();
    var b0 = try box(.{ 0, 1, 0 }, .{ 2, 2, 0.5 });
    defer b0.deinit();
    var b1 = try turned(&b0, .{ 2, 1, 0 }, .{ 0, 0, 1 }, angle);
    defer b1.deinit();
    var b = try helpers.moved(&b1, .{ 0, 3e-6, 0 });
    defer b.deinit();
    try expectIdentities(&b, &plate);
    try expectIdentities(&plate, &b);
}

test "degeneracy: a chain of edges on two lines 8.7e-5 apart is joined whole, either way round" {
    // The nightly solids fuzzer's find (2026-11-16, run 43773180777), as it came: a box
    // united with a turned hull, the hull's face crossing the box's top, then cut by a
    // plate (zone 1e-4) whose bottom lies 3e-5 under that top. The hull's face crosses the
    // two planes along two lines 8.7e-5 apart, within the intersection tolerance (2e-4),
    // and the result's edge along it is a chain of four vertices, two on each line.
    // Simplification joined vertex by vertex in their numbering: one way round each join
    // measured the next against the line the last left, and the second vertex stayed (8
    // vertices against 7). The chain is decided whole, by the lines its edges have
    const coarse = Tolerance.fromZone(1e-4);
    const Affine = mat.Affine;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b0 = try helpers.boxAt(tol, .{ 2, 3, 2 }, .{ 4, 4, 3 });
    defer b0.deinit();
    var b = try helpers.moved(&b0, .{ 5e-6, 2e-5, -2e-5 });
    defer b.deinit();
    const points = [_]Vec3{ .{ 4, 3, 2 }, .{ 4, 1, 3 }, .{ 0, 2, 2 }, .{ 0, 0, 2 }, .{ 4, 1, 1 }, .{ 1, 2, 3 }, .{ 1, 3, 0 }, .{ 4, 4, 0 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    // The generator's placement, composed as it composes it
    var place = Affine.translate(vec.ZERO3);
    place = Affine.rotateAbout(@splat(2), vec.normalized(.{ 1, 2, 3 }).?, std.math.pi).compose(&place);
    place = Affine.scaleBy(.{ 2, 2, 1 }).compose(&place);
    place = Affine.translate(vec.ZERO3).compose(&place);
    place = Affine.translate(.{ 0, 1.999999989037341e-5, -1.999999989037341e-5 }).compose(&place);
    var h = try @import("../construct/transform.zig").transform(testing.allocator, &h0, &place, .{}, &diag);
    defer h.deinit();
    var joined = try sound(&b, &h, .@"union");
    defer joined.deinit();
    var p0 = try helpers.boxAt(coarse, .{ -48, -48, 3 }, .{ 52, 102, 4 });
    defer p0.deinit();
    var plate = try helpers.moved(&p0, .{ 2e-2, 2e-4, -5e-5 });
    defer plate.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
        var forward = try sound(&joined, &plate, op);
        defer forward.deinit();
        var swapped = try sound(&plate, &joined, op);
        defer swapped.deinit();
        try testing.expectEqual(forward.counts(), swapped.counts());
    }
    // The plate's bottom moves onto the box's top, 3e-5 over the plate: the identities to
    // the report's shift (the plate less the rest is refused, `pinched`, as it was before
    // chains were joined whole: the result would touch itself inside one solid)
    try helpers.expectIdentitiesAtTolerance(&joined, &plate);
}

test "degeneracy: a plate's top and a box's 1.9e-4 apart, both planes holding the two at a tolerance of 2e-4, give one plane either way round" {
    // The nightly solids fuzzer's find (2026-11-16, run 43831843168), as it came: a turned
    // hull united with a box, then joined with a plate (zone 1e-4) whose top lies 1.9e-4
    // over the box's top. The paves find the two tops in one plane, and either top's
    // plane holds both within the intersection tolerance. The group took its first
    // operand's first face's plane, so A ∪ B lay in the box's top and B ∪ A in the
    // plate's, where the hull's section across the box's top edge is two edges, not one
    // line (22 vertices against 23). The group takes the plane nearest its points
    const coarse = Tolerance.fromZone(1e-4);
    const Affine = mat.Affine;
    const middle: Vec3 = @splat(2);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 3, 4, 0 }, .{ 3, 0, 3 }, .{ 3, 3, 3 }, .{ 1, 1, 4 }, .{ 2, 0, 4 }, .{ 0, 4, 3 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    // The generator's placements, composed as it composes them
    var place = Affine.rotateAbout(middle, .{ 1, 0, 0 }, std.math.pi / 2.0).compose(&Affine.translate(vec.ZERO3));
    place = Affine.translate(.{ -2e-5, -5e-6, -2e-3 }).compose(&Affine.translate(vec.ZERO3).compose(&place));
    var h = try @import("../construct/transform.zig").transform(testing.allocator, &h0, &place, .{}, &diag);
    defer h.deinit();
    var b0 = try helpers.boxAt(tol, .{ 0, 3, 1 }, .{ 4, 4, 3 });
    defer b0.deinit();
    var b = try helpers.moved(&b0, .{ 5e-6, 2e-3, 1e-5 });
    defer b.deinit();
    var joined = try sound(&h, &b, .@"union");
    defer joined.deinit();
    var p0 = try helpers.boxAt(coarse, .{ -48, -48, 0 }, .{ 52, 102, 3 });
    defer p0.deinit();
    var turn = Affine.rotateAbout(middle, .{ 0, 0, 1 }, 1e-6).compose(&Affine.translate(vec.ZERO3));
    turn = Affine.translate(.{ 1.9999999855049212e-4, -1.9999999855049212e-4, 1.9999999855049212e-4 }).compose(&Affine.translate(vec.ZERO3).compose(&turn));
    var plate = try @import("../construct/transform.zig").transform(testing.allocator, &p0, &turn, .{}, &diag);
    defer plate.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
        var forward = try sound(&joined, &plate, op);
        defer forward.deinit();
        var swapped = try sound(&plate, &joined, op);
        defer swapped.deinit();
        try testing.expectEqual(forward.counts(), swapped.counts());
    }
}

test "degeneracy: an edge on a face by its ends' reach and off it by its line is refused, never laid in the face" {
    // The 10K session's find on 7a1bfb5e (2026-11-16, the solids target), as it came: a
    // hull cut by a scaled box leaves corners with gaps of 5.3e-6 on its face x = 0.99998,
    // 2.1e-5 from a box's face x = 1.000005 (within the tolerance and their gaps), the
    // edge between them on its line 2.5e-5 from it. The section of the cut's floor with
    // the box's face took that edge for itself, and the union laid it in the box's face as
    // a slit, 2.5e-5 off the face's surface (`edge_off_surface`). An existing edge stands
    // for a section only where its line lies on the other face as the checker holds it
    const Affine = mat.Affine;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0, 1, 0 }, .{ 4, 2, 4 }, .{ 3, 2, 1 }, .{ 0, 0, 2 }, .{ 2, 0, 4 }, .{ 2, 1, 0 }, .{ 2, 0, 4 }, .{ 4, 1, 1 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    var h = try helpers.moved(&h0, .{ -5e-6, 2e-5, -5e-6 });
    defer h.deinit();
    // The generator's placement of the scaled box, composed as it composes it
    var c0 = try helpers.boxAt(tol, .{ 0, 0, 2 }, .{ 2, 2, 3 });
    defer c0.deinit();
    var place = Affine.translate(vec.ZERO3);
    place = Affine.scaleBy(.{ 0.5, 1, 0.5 }).compose(&place);
    place = Affine.translate(vec.ZERO3).compose(&place);
    place = Affine.translate(.{ -1.9999999971578292e-5, 2.000000002842171e-5, -5e-6 }).compose(&place);
    var c = try @import("../construct/transform.zig").transform(testing.allocator, &c0, &place, .{}, &diag);
    defer c.deinit();
    var cut = try sound(&h, &c, .intersection);
    defer cut.deinit();
    var b0 = try box(.{ 1, 0, 0 }, .{ 2, 4, 4 });
    defer b0.deinit();
    var b = try helpers.moved(&b0, .{ 5e-6, -1e-5, -2e-5 });
    defer b.deinit();
    try expectRefused(&cut, &b, .below_feature_size);
    try expectRefused(&b, &cut, .below_feature_size);
}

test "degeneracy: two faces a hair off parallel, within the tolerance of each other at three corners of where they meet and past it at the fourth, are one plane's or refused" {
    // The 10K session's find on e252409f (2026-11-16, both targets), at one tolerance: a
    // box's bottom tilted 4.7e-6 over a plate's top, 5e-6 above it at its corner inside the
    // plate, 1.5e-5 where the plate's sides cross it and 2.5e-5 at the plate's corner
    // inside it (the tolerance, 2e-5). Neither face lies in the other's plane by all its
    // corners, so the pair was taken to meet along their planes' line, and the three merged
    // vertices on both were ordered by the noise of the normals' cross product; the plate's
    // top kept the box's imprint, the box's bottom not the plate's, and the union kept both
    // where they meet, one on the other (`faces_intersect`). Merged vertices on both faces
    // off one line put them in one plane, where its rules decide them: the plate's corner
    // inside the box's bottom past the tolerance of its plane is refused
    var plate = try box(.{ 0, 0, -1 }, .{ 4, 4, 0 });
    defer plate.deinit();
    var b0 = try box(.{ 1, 1, 0 }, .{ 5, 5, 1 });
    defer b0.deinit();
    var b1 = try turned(&b0, .{ 1, 1, 0 }, .{ 1, -1, 0 }, 1e-5 / 3.0 * @sqrt(2.0));
    defer b1.deinit();
    var b = try helpers.moved(&b1, .{ 0, 0, 5e-6 });
    defer b.deinit();
    try expectRefused(&plate, &b, .below_feature_size);
    try expectRefused(&b, &plate, .below_feature_size);
}

test "degeneracy: faces at right angles sharing merged vertices, one off the others' line within its reach, cross along their line" {
    // The 10K session's find on 415e356d (2026-11-16, solids): a plate's top and a box's
    // side at right angles shared four merged vertices, one of them 1.8e-4 below the
    // others' line (the tolerance, 2e-4). Measured from the line through it, the others
    // were off one line, so the pair was taken for one plane, and a fragment of the plate's
    // top inside the box's side found no twin (`imprint_unmatched`). Here a prism's front,
    // notched down to 0.9 tolerances below the plate's top edge: the notch's apex, the first
    // of the three merged vertices on both faces, is the noisy one. Planes at an angle meet
    // along their own line, whatever the vertices on both
    var solid = try helpers.notchedPrism(tol, 1 - 0.9 * tol.xsect);
    defer solid.deinit();
    var plate = try box(.{ 0, 0, 0.5 }, .{ 10, 5, 1 });
    defer plate.deinit();
    try expectAllSound(&solid, &plate);
}

test "degeneracy: a notch's apex on a face turned 0.3 rad from it, 3 tolerances off where they cross, touches it there" {
    // The edge-case matrix (2026-11-16): a plate against a notched front, turned 0.3 rad
    // about its top edge, the notch's apex 3 tolerances under that edge and within the
    // tolerance of the plate's front, as are the notch's sides down to it: the two fronts
    // touch along the edge and down and up the notch's sides. The overlap rules joined
    // those pieces into one run, judged as one straight segment whose middle, over the
    // notch, is in neither face (`faces_intersect`); each piece is judged by itself, as
    // the paves cut them
    var solid = try helpers.notchedPrism(tol, 1 - 3 * tol.xsect);
    defer solid.deinit();
    var upright = try box(.{ 0, 0, 0.5 }, .{ 10, 5, 1 });
    defer upright.deinit();
    var plate = try turned(&upright, .{ 0, 0, 1 }, vec.X3, 0.3);
    defer plate.deinit();
    try expectAllSound(&solid, &plate);
}

test "degeneracy: a plate's front inside a notch 1.25 tolerances deep under its edge is outside the notched solid, the union's sliver refused" {
    // The edge-case matrix (2026-11-16): a plate's front in one plane with a notched
    // front, the notch's apex 1.25 tolerances under the plate's top edge: the plate's
    // front inside the notch is a triangle 2.5e-5 a side, every point within the tolerance
    // of the notch's sides, so no ray decides it, and its seams along the notch's edges
    // were read as undecided (the notched front in its plane). Beyond the edge from that
    // front, the notch's side alone bounds the material: outside it. The intersection and
    // the difference are made; the union keeps the triangle, a sliver, refused
    var solid = try helpers.notchedPrism(tol, 1 - 1.25 * tol.xsect);
    defer solid.deinit();
    var plate = try box(.{ 0, 0, 0.5 }, .{ 10, 5, 1 });
    defer plate.deinit();
    for ([2][2]*const Body{ .{ &solid, &plate }, .{ &plate, &solid } }) |operands| {
        for ([_]pipeline.Op{ .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, operands[0], operands[1], .@"union", .{}, &diag, null));
        try testing.expectEqual(diagnostics.Code.sliver_face, diag.first().?.code);
    }
}

test "degeneracy: a corner put on an edge between gapped ends, off the edge's line past the tolerance, carries the gap it needs" {
    // The 10K session's find on 06478dc2 (2026-11-16, solids), reduced: a box at a zone of
    // 1e-4 whose top's corners at y = 2.5 lie their gap of 1e-4 under its plane (what a
    // chain's merges leave), and a tetrahedron's apex 1e-4 off the box's side, 1.9e-4 under
    // its top edge at y = 2: 1.49e-4 from the segment between the edge's ends, on it by the
    // tolerance (2e-4), and 2.15e-4 from the edge's line, which the union's edge keeps (in
    // the find 1.68e-4 and 2.06e-4). The apex had no gap and the checker refused the union
    // (`vertex_off_curve`); its gap now covers the distance
    var block = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ 3, 0, 2 }, .{ 4, 2.5, 3 });
    defer block.deinit();
    for (block.vertices.items) |*v| {
        const p = &block.geometry.points.items[@backingInt(v.point)];
        if (p[1] != 2.5 or p[2] != 3) continue;
        p[2] -= 1e-4;
        v.gap = 1e-4;
    }
    var report = try check.run(testing.allocator, &block, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    var t = try tetrahedron(.{ 3 - 1e-4, 2, 3 - 1.9e-4 }, .{ 2, 4, 0 }, .{ 1, 2, 4 }, .{ 2, 0, 2 });
    defer t.deinit();
    try expectAllSound(&block, &t);
}

test "degeneracy: a hull's ridge through a thin plate, from the plate's side at 26.6°, joins them through the slit's mouth, no pinch" {
    // The 10K session's find on b1053969 (2026-11-16, solids), its operands as the chain
    // left them: a hull whose left face lies within the tolerance of a plate's left side,
    // its ridge in the plate's top, the plate 3 tolerances thick. The union's underside
    // has a slit where the hull passes through it, whose mouth on the side is 9e-5 long,
    // its sides at 26.6° to the side's edge, the mouth's middle 2.01e-5 from them. The
    // overlap rules placed that middle with the mouth's ends' gaps (2.5e-6), on the slit's
    // side within reach, and inside the joined left face: the faces "touched", a pinch. A
    // gap's middle is no vertex and is placed with no gap, as the paves place it. The
    // plate less the hull is refused by design (the ridge leaves it pinched at a corner)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0.499995, 1.9999799999999432, 4.00001 }, .{ 1.999995, 2.999979999999943, 1e-05 }, .{ 0.499995, 3.999979999999943, 1e-05 }, .{ 0.499995, -2.000000005684342e-05, 2.00001 }, .{ 0.999995, 2.999979999999943, 4.00001 } };
    var ridge = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer ridge.deinit();
    var plate = try box(.{ 0.5, 0.5, 3.9999500000000636 }, .{ 4.5, 3.5, 4.000010000000064 });
    defer plate.deinit();
    for ([2][2]*const Body{ .{ &ridge, &plate }, .{ &plate, &ridge } }) |operands| {
        var joined = try sound(operands[0], operands[1], .@"union");
        joined.deinit();
    }
    try expectProbe(&ridge, &plate);
}

test "degeneracy: a ridge under a flat tetrahedron's corner, where its top and bottom are within the tolerance, cuts off a band thinner than it: refused" {
    // The 10K session's find on b1053969 (2026-11-16, locus), its operands as the chain
    // left them: a hull whose horizontal ridge passes 1.3e-5 under the front corner of a
    // tetrahedron 2.1 tolerances thick at its middle, where its top and bottom are within
    // the tolerance of each other. The union imprinted the ridge and cut off the corner's
    // triangle of the bottom, 0.3 across, which lay wholly within the tolerance of the top
    // over it; the overlap rules found the result's faces on each other. A kept piece of a
    // face lying on another kept face of its operand facing apart is refused (Leo: the
    // fragment rule), either way round
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const ridge_points = [_]Vec3{ .{ 1.3381837175357336, 0.7471433042130544, -2e-05 }, .{ -0.503713391573891, 3.317632564928533, 3.99998 }, .{ 2.953336489125606, 2.2935202066613396, 0.99998 }, .{ 2.2935202066613396, 1.0426635108743938, 2.99998 }, .{ 1.7024797933386606, 2.953336489125606, 3.99998 }, .{ 2.589040413322679, 0.08732702174878793, 0.99998 } };
    const flat_points = [_]Vec3{ .{ -0.999995, 4, 3.999959000000071 }, .{ 1.000005, 4, 3.999959000000071 }, .{ 5e-06, 3, 4.000001000000071 }, .{ 5e-06, 5, 4.000001000000071 } };
    const hull = @import("../construct/hull.zig");
    var ridge = try hull.hull(testing.allocator, tol, &ridge_points, &diag);
    defer ridge.deinit();
    var flat = try hull.hull(testing.allocator, tol, &flat_points, &diag);
    defer flat.deinit();
    for ([2][2]*const Body{ .{ &ridge, &flat }, .{ &flat, &ridge } }) |operands| {
        var refused = Diagnostics.init(testing.allocator);
        defer refused.deinit();
        try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, operands[0], operands[1], .@"union", .{}, &refused, null));
        try testing.expectEqual(diagnostics.Code.below_feature_size, refused.first().?.code);
    }
    try expectProbe(&ridge, &flat);
}

test "degeneracy: a hull's edge across a thin plate's side at 15.5°, within the tolerance of it over the crossing, reads no side there" {
    // The 10K session's find on 2b26eef1 (2026-11-16, locus), its operands as the chain
    // left them: a plate 2.1 tolerances thick whose side a hull's edge crosses at 15.5°,
    // within the tolerance of the side over the whole crossing, 6.6e-5 long, and of both
    // its long edges. The paves put that piece of the edge on the side, splitting it; the
    // side's piece inside the hull read its seam from the edge's wedge as if the edge ran
    // in its plane, 2.2° off the hull's face there: outside, against the plate's top beside
    // it, inside, and the two clear seams of one component were refused. An edge across a
    // fragment's plane bounds no region of it (its faces cut the plane along their own
    // lines): its wedge reads no side, and the side's pieces take their component's and a
    // ray's (Leo, 2026-11-17)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 9.999999717180685e-10, 0.4999999989999999, -1 }, .{ 1.0000000009999999, 0.4999999999999998, 3 }, .{ -1.000000001, 2.499999998, 1 }, .{ 0.9999999989999999, 2.5, 3 }, .{ 2.000000002, -0.49999999900000014, 1 }, .{ 1.999999943436137e-09, -0.5000000010000002, 1 }, .{ 0.9999999989999999, 2.5, 1 }, .{ 1.999999998, 3.500000001, -1 } };
    var hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer hull.deinit();
    var plate = try box(.{ -0.002, 1.0000049999999994, -2.1000000000270802e-05 }, .{ 0.998, 3.0000049999999994, 2.0999999999826713e-05 });
    defer plate.deinit();
    try expectAllSound(&hull, &plate);
}

test "degeneracy: a hull's edge across a box's side at 28°, laid in it as a slit by its ends' reach, pairs by the planes that hold it" {
    // The 10K session's find on 600148f2 (2026-11-17, locus), its operands as the chain
    // left them: a hull's corner 1e-5 inside a box's side, its edge leaving at 28° to the
    // side's plane and crossing the box's edge 2.5e-5 on, both ends within reach of the
    // side, that piece of the edge laid in the side as a slit. The union's edge there has
    // four uses, the hull's two faces and the slit's two sides; read about the hull's edge,
    // the side's material took in a hull's face and the four did not pair
    // (`edge_coedge_count`; on 415e356d the side was left unclassified). A wedge is read
    // only about an edge in its face's plane: the side, holding the edge by reach alone,
    // pairs its own two uses, the hull's faces theirs, two solids touching along the slit
    // (Leo, 2026-11-17, as for a fragment's wedge)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0.9999900004999999, 7.9999800000001136, 6.000019999999999 }, .{ 0.49998999949999995, 7.9999800000001136, 2.000020002 }, .{ 0.9999900009999999, 5.9999800000001136, 8.00002 }, .{ 0.4999900004999999, 1.9999800000001138, 6.000020001999999 }, .{ -1.0000500000082742e-05, 1.9999800000001138, 2.000020004 }, .{ 1.4999899989999999, 3.9999800000001136, 1.9997999999886874e-05 } };
    var hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer hull.deinit();
    var side = try box(.{ -1, -1.9999999957367437e-05, 1.999995 }, .{ 0, 2.9999800000000425, 2.999995 });
    defer side.deinit();
    try expectAllSound(&hull, &side);
    var u = try sound(&hull, &side, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
}

test "degeneracy: a tetrahedron's tip 2.1e-4 over a box's top at a tolerance of 1e-4, its edges' crossings merged into one vertex, pinches the difference's pocket at a point" {
    // The 10K session's find on 600148f2 (2026-11-17, locus_solids), reduced to its box
    // and tetrahedron: in through the box's front, its tip past the top by just over the
    // intersection tolerance (2e-4), its three edges crossing the top within it of each
    // other, one merged vertex, the top given no section. The difference's pocket meets the
    // top at that point, inside one solid, as a tetrahedron's corner on it would: a pinch
    // (refused by design), which assembly took only for an operand's own vertex there,
    // and the overlap rules found in the result
    var a = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ -0.0001, 1.9999, 0.9998 }, .{ 3.9999, 3.9999, 1.99979 });
    defer a.deinit();
    var through = try tetrahedron(.{ 5e-5, 3, 2 }, .{ 4.00005, 0, -1 }, .{ 2.00005, 0, 0 }, .{ 2.00005, 0, -1 });
    defer through.deinit();
    try expectPinched(&a, &through);
    for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
        var made = try sound(&a, &through, op);
        made.deinit();
    }
}

test "degeneracy: a pyramid's bottom 0.4° off a box's top, its corner past the tolerance over it but its plane within the zone of it, is classified by that corner" {
    // The 10K session's find on c3a83ee8 (2026-11-17, locus_solids), reduced: a face
    // whose corner lay its zone off its plane (a merged vertex of an earlier boolean),
    // crossing a box's face at 0.4°, within the angular tolerance. The piece the box's face
    // cut off at the corner lies within the zone of that face all over (the corner 2.1e-5
    // over it, past the intersection tolerance, its plane 1.2e-5 there), so every sample
    // of it was on the box's boundary, its section read nothing at that angle, and it was
    // left unclassified. The paves put the corner on nothing of the box: a ray from it
    // decides the piece
    const p = 1.2e-5;
    const d = 0.9e-5;
    const z = struct {
        // The bottom's plane, through its three corners at x = 2 and 4
        fn at(x: f64) f64 {
            return 1 + p - 0.007 * x;
        }
    };
    const points = [_]Vec3{ .{ 0, 0, z.at(0) + d }, .{ 2, -1, z.at(2) }, .{ 2, 1, z.at(2) }, .{ 4, 0, z.at(4) }, .{ 2, 0, 3 } };
    // The bottom's far triangle first, its plane the record the near one shares
    var pyramid = try polyhedron(&points, &.{ .{ 1, 2, 3 }, .{ 0, 2, 1 }, .{ 4, 0, 1 }, .{ 4, 1, 3 }, .{ 4, 3, 2 }, .{ 4, 2, 0 } });
    defer pyramid.deinit();
    var b = try box(.{ -5, -5, 1 }, .{ 5, 5, 8 });
    defer b.deinit();
    try expectAllSound(&pyramid, &b);
}

test "degeneracy: a plate less a plate nudged against it is an L-shaped wall 2.5e-4 and 4e-4 thick under a top within the tolerance of the other's, sound" {
    // The 10K session's find on c3a83ee8 (2026-11-17, locus), as the fuzzer drew it: two
    // plates 100 by 150 at a zone of 1e-4, each nudged, their tops 1e-4 apart (in one
    // plane), the difference a wall along two sides. The wall's top, an L across the whole
    // plate, has corners up to 1e-4 apart in height; the checker's own fans from the middle
    // of its UV box swept 7500 of area whose heights did not cancel and measured the shell
    // -0.376, inside out. The one measure (`integrals.shellSense`) takes the plane's region
    // and the ribbons down to it
    const at = Tolerance.fromZone(1e-4);
    const na: Vec3 = .{ -5e-5, 1.9999999855049283e-4, -1.9999999855049283e-4 };
    const nb: Vec3 = .{ 2.000000014495072e-4, -1.9999999855049283e-4, -1e-4 };
    var a = try helpers.boxAt(at, vec.add(.{ 2, -48, 2 }, na), vec.add(.{ 102, 102, 4 }, na));
    defer a.deinit();
    var b = try helpers.boxAt(at, vec.add(.{ 2, -48, 1 }, nb), vec.add(.{ 102, 102, 4 }, nb));
    defer b.deinit();
    for ([2][2]*const Body{ .{ &a, &b }, .{ &b, &a } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
    }
    // The tops, 1e-4 apart, are one plane: the identities hold to what that moved
    try helpers.expectIdentitiesAtTolerance(&a, &b);
}

test "degeneracy: a box's top lying in a long plate's bottom, the plate's far end its reach off the top's plane to rounding, is made either way round" {
    // The 10K session's find on 0fce3ff4 (2026-11-18, locus), its mechanism: faces sharing
    // merged vertices are coplanar when either lies in the other's plane. The box's top
    // lies in the plate's plane outright (its far corners 2e-7 off it); the plate's bottom
    // rises to the intersection tolerance exactly at its far end, at its reach of the
    // top's plane to rounding. Asked the box's top first, coplanar; asked the plate's
    // first, refused (at_tolerance): made one way round and refused the other. Both asked,
    // then decided (`canonical.either`): coplanar either way
    const xs = tol.xsect;
    var a = try box(.{ 0, 0, -1 }, .{ 1, 1, 0 });
    defer a.deinit();
    const points = [_]Vec3{ .{ 0, 0, 0 }, .{ 100, 0, xs }, .{ 100, 1, xs }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 100, 0, 1 }, .{ 100, 1, 1 }, .{ 0, 1, 1 } };
    var plate = try polyhedron(&points, &.{ .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 4, 5, 6 }, .{ 4, 6, 7 }, .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 3, 7, 6 }, .{ 3, 6, 2 }, .{ 0, 4, 7 }, .{ 0, 7, 3 }, .{ 1, 2, 6 }, .{ 1, 6, 5 } });
    defer plate.deinit();
    for ([2][2]*const Body{ .{ &a, &plate }, .{ &plate, &a } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
    }
    // The faces are one plane, the plate's bottom moved onto it by up to 2e-7
    try helpers.expectIdentitiesAtTolerance(&a, &plate);
}

test "degeneracy: a box's bottom the intersection tolerance over another's top, beside it, is made, not refused by the nearly-coplanar warning" {
    // The same find's second refusal: the paves' warning of faces parallel a hair apart
    // (`nearly_coplanar`) settled its "in the plane" at the tolerance to rounding as a
    // refusal. A warning decides nothing and refuses nothing (`incidence.holds`)
    var a = try box(.{ 0, 0, -1 }, .{ 1, 1, 0 });
    defer a.deinit();
    var b = try box(.{ 1 + 5e-4, 0, tol.xsect }, .{ 2, 1, 1 });
    defer b.deinit();
    try expectAllSound(&a, &b);
}

/// Each operation of `a` and `b`, either way round, made and sound; the identities.
fn expectAllSound(a: *const Body, b: *const Body) !void {
    for ([2][2]*const Body{ .{ a, b }, .{ b, a } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
    }
    try expectIdentities(a, b);
}

test "degeneracy: an edge passing another within the tolerance in its end's strip, the end not on it, is refused either way round" {
    // The locus fuzzer's find (2026-11-16, 10K session on cb4fcdbb), at one tolerance: a
    // tetrahedron's corner in a plate's top, 2.2e-5 from its edge (beyond the tolerance,
    // 2e-5: not on it), its edge leaving down past the plate's edge 9.8e-6 away, 1.97e-5
    // from the corner, in the corner's strip. Edge–edge skipped the crossing as the
    // corner's; edge–face then crossed the plate's edge with the tetrahedron's face from
    // whichever operand came first, outside the strip one way round (made) and inside it
    // the other (refused). Too near the corner to split at, too far to be it: refused
    // either way round, as `endStrip` refuses a vertex there
    const h: Vec3 = .{ 2.2e-5, 0, 1 };
    var plate = try box(.{ 0, -5, -1 }, .{ 10, 5, 1 });
    defer plate.deinit();
    var t = try tetrahedron(h, vec.add(h, .{ -2, 0, -1 }), vec.add(h, .{ 1, 3, -1 }), vec.add(h, .{ -2, 2, 3 }));
    defer t.deinit();
    for ([2][2]*const Body{ .{ &t, &plate }, .{ &plate, &t } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            try testing.expectError(error.TooSmallEdge, pipeline.boolean(testing.allocator, operands[0], operands[1], op, .{}, &diag, null));
            try testing.expectEqual(diagnostics.Code.edge_too_short, diag.first().?.code);
        }
    }
}

/// Each operation of `a` and `b`, either way round, refused before the paves: one of them
/// has two features that do not meet nearer than twice the intersection tolerance and
/// their gaps (`pipeline.featureSize`, the minimum feature size).
fn expectBelowFeatureSize(a: *const Body, b: *const Body) !void {
    for ([2][2]*const Body{ .{ a, b }, .{ b, a } }) |operands| {
        try expectRefused(operands[0], operands[1], .below_feature_size);
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, operands[0], operands[1], .@"union", .{}, &diag, null));
        try testing.expect(std.mem.indexOf(u8, diag.first().?.label, "two features of") != null);
    }
}

/// Each operation of `a` and `b` refused with `code`.
fn expectRefused(a: *const Body, b: *const Body, code: diagnostics.Code) !void {
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        if (pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, null)) |result| {
            var made = result;
            made.deinit();
            std.debug.print("{s} was not refused\n", .{@tagName(op)});
            return error.TestExpectedError;
        } else |_| {}
        errdefer std.debug.print("{s}: {f}\n", .{ @tagName(op), diag });
        try testing.expectEqual(code, diag.first().?.code);
    }
}

test "degeneracy: a face through a plate 1.5 tolerances thick, past it all round, is refused: the plate's top and bottom both lie in its plane" {
    // research/consistent-tolerances.md's first probe (2026-11-14): the box's top at the
    // plate's mid-height is within the intersection tolerance of the plate's top and bottom
    // (and its sides, 3e-5 tall, lay in its plane by their corners' heights); no merged
    // vertex is within reach of two of the plate's faces (the box's corners are outside it),
    // so the minimum feature size never saw the pair, and the imprint reached its guard
    // (`imprint_unmatched`). The top and bottom in the box's plane, not in one: refused
    var plate = try box(.{ 0, 0, 0 }, .{ 10, 10, 1.5 * tol.xsect });
    defer plate.deinit();
    var b = try box(.{ -5, -5, -5 }, .{ 15, 15, 0.75 * tol.xsect });
    defer b.deinit();
    try expectRefused(&plate, &b, .below_feature_size);
}

test "degeneracy: a face inside a wall 1.5 tolerances thick is refused: the wall's two faces both lie in its plane, not in one" {
    // The second probe: a cavity's face 3e-5 behind the outer face x = 10, and a box whose
    // face lies between the two, in the plane of each (within the tolerance) but of
    // neither's; the imprints disagreed (`imprint_unmatched`)
    var outer = try box(.{ 0, 0, 0 }, .{ 10, 10, 10 });
    defer outer.deinit();
    var cavity = try box(.{ 5, 1, 1 }, .{ 10 - 1.5 * tol.xsect, 9, 9 });
    defer cavity.deinit();
    var walled = try sound(&outer, &cavity, .difference);
    defer walled.deinit();
    var b = try box(.{ 10 - 0.75 * tol.xsect, 0.5, 0.5 }, .{ 20, 9.5, 9.5 });
    defer b.deinit();
    try expectRefused(&walled, &b, .below_feature_size);
}

test "degeneracy: a face between a flat tetrahedron's opposite edges is refused: both edges lie in its plane, crossing there" {
    // The third probe: a valid tetrahedron whose opposite edges are 1.5e-5 apart (every
    // pair of its faces shares an edge, so the overlap rules see only boundary contacts),
    // and a box whose top lies between them; both edges are imprinted on the box's top and
    // cross in its plane where no merged vertex is (`imprint_unmatched`)
    const h = 0.75 * tol.xsect;
    var tetra = try tetrahedron(.{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, h }, .{ 0, 1, h });
    defer tetra.deinit();
    var b = try box(.{ -20, -20, -5 }, .{ 20, 20, h / 2 });
    defer b.deinit();
    try expectRefused(&tetra, &b, .below_feature_size);
}

test "degeneracy: an edge between corners with gaps, crossed by an edge of a face its face lies in by those gaps, meets it or is refused, never put beside it" {
    // The 10K session's find (2026-11-16, locus), reduced: a box at a zone of 1e-4 whose
    // bottom's front corners lie 3.5e-5 under its plane with that gap and the edge between
    // them on a line 7e-5 under it (as a chain's merges leave them), and a box whose bottom is 1.8e-4 over that plane, its side crossing the
    // front edge. The bottoms are one plane by the corners' reach (2.15e-4 within 2.35e-4);
    // edge–edge measured the crossing edges' 2.15e-4 against the tolerance alone (2e-4),
    // apart, and the crossing went on the box's front face beside the edge: the bottom's
    // overlay cut a piece where the paves put no point (`imprint_unmatched`). Two edges
    // meet within the tolerance and both edges' gaps; here the crossing would need a
    // vertex past the zone from both: refused, every operation either way round
    const coarse = Tolerance.fromZone(1e-4);
    var a = try helpers.boxAt(coarse, .{ 1.5, 1.00005, 2e-5 }, .{ 3.5, 2.002, 3.00002 });
    defer a.deinit();
    for (a.vertices.items) |*v| {
        const p = &a.geometry.points.items[@backingInt(v.point)];
        if (p[1] != 1.00005 or p[2] != 2e-5) continue;
        p[2] -= 3.5e-5;
        v.gap = 3.5e-5;
    }
    // The front bottom edge's own line 7e-5 under the plane, its corners within their gap
    for (a.edges.items) |e| {
        const p0 = a.point(e.start);
        const p1 = a.point(e.end);
        if (e.curve.kind != .line or p0[1] != 1.00005 or p1[1] != 1.00005 or p0[2] > 0 or p1[2] > 0) continue;
        a.geometry.lines.items[e.curve.index].o[2] = -5e-5;
    }
    var report = try check.run(testing.allocator, &a, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.first() == null);
    var b = try helpers.boxAt(coarse, .{ 0.2499, 0.9998, 2e-4 }, .{ 2.0002, 2.9998, 2.0002 });
    defer b.deinit();
    try expectRefused(&a, &b, .gap_too_large);
    try expectRefused(&b, &a, .gap_too_large);
}

test "degeneracy: a face along a flat tetrahedron's knife edges, past its thick middle, is refused: within the tolerance of two of its faces at once" {
    // The 10K session's find (2026-11-16, locus_solids), as the edge-case matrix draws it:
    // a tetrahedron 2.1 tolerances thick (past the minimum feature size, its opposite
    // edges 4.2e-5 apart), its faces meeting at about 4e-5 rad, and a box's top through its
    // middle covering it only past a diagonal, away from the thick middle. There the top
    // is within the zone of the tetrahedron's upper and lower faces at once, which meet at
    // a knife edge, and a piece of it inside the tetrahedron had no sample off its
    // boundary (`unclassified`). The two faces facing apart within the tolerance of one
    // point of a face parallel to them bound a feature thinner than twice it there,
    // whether they meet or not: refused, every operation either way round
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const half = 2.1e-5;
    const points = [_]Vec3{ .{ 1, 2, -half }, .{ 3, 2, -half }, .{ 2, 1, half }, .{ 2, 3, half } };
    var knife = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer knife.deinit();
    var b0 = try box(.{ 2.4, -2, -1 }, .{ 6, 6, 0 });
    defer b0.deinit();
    var top = try turned(&b0, .{ 2.4, 2, 0 }, .{ 0, 0, 1 }, 0.6);
    defer top.deinit();
    try expectRefused(&knife, &top, .below_feature_size);
    try expectRefused(&top, &knife, .below_feature_size);
}

test "degeneracy: a hull's edge through a flat tetrahedron's knife, within the tolerance of its top and bottom 0.23 from the knife edge, is refused" {
    // The 10K session's find on a5301ce8 (2026-11-18, locus_solids), its operands as the
    // chain left them: a tetrahedron 2.1 tolerances thick at its middle, its faces meeting
    // at 6e-5 rad, and a hull whose bottom edge runs through it 2e-6 to 7.5e-6 off its
    // bottom, its faces crossing the top steeply. No merged vertex lies within reach of
    // both the top and the bottom, but the edge between two does, from the knife edge to
    // 0.23 from it; the union kept the notch in the hull's face between the edge and its
    // section with the top as narrow as the tetrahedron there, touching the bottom
    // (`pinched` by the overlap rules). A pave block within reach of two faces facing
    // apart at an angle within the angular tolerance, away from where they meet, is below
    // the minimum feature size, as a merged vertex there is: refused, every operation
    // either way round
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const flat_points = [_]Vec3{ .{ -2.000000005684342e-5, 3.000005, 0.9999990000000568 }, .{ 1.9999799999999432, 3.000005, 0.9999990000000568 }, .{ 0.9999799999999431, 2.000005, 1.0000410000000568 }, .{ 0.9999799999999431, 4.000005, 1.0000410000000568 } };
    const hull_points = [_]Vec3{ .{ 1.5, 2.999995, 4.000005 }, .{ 3.5, 2.999995, 4.000005 }, .{ 0.5, 3.999995, 1.000005 }, .{ 1.5, -0.000005, 2.000005 }, .{ 2.5, 0.999995, 1.000005 }, .{ 0.5, 1.999995, 3.000005 } };
    const hull = @import("../construct/hull.zig");
    var flat = try hull.hull(testing.allocator, tol, &flat_points, &diag);
    defer flat.deinit();
    var steep = try hull.hull(testing.allocator, tol, &hull_points, &diag);
    defer steep.deinit();
    try expectRefused(&flat, &steep, .below_feature_size);
    try expectRefused(&steep, &flat, .below_feature_size);
}

test "degeneracy: a flat tetrahedron 1.5 tolerances thick, its face 3e-4 rad off a plate's top: below the minimum feature size, refused" {
    // The gap draws' first find (2026-11-14), at a zone of 1e-4: the tetrahedron's upper
    // edge 5e-5 over the plate's top and its lower 2.5e-4 under it, so its upper faces
    // cross the top at 3e-4 rad 1/6 from the edge; the paves take the edge's ends for where
    // they meet (an edge meets a plane once), and the faces lie under the top within the
    // zone of it but toward their lower corner, where neither centroid reached
    // (`unclassified`). The tetrahedron is all but inside the plate: the intersection is it,
    // the union the plate
    const t = Tolerance.fromZone(1e-4);
    const top = 3 + 5e-5;
    var plate = try helpers.boxAt(t, .{ -10, -10, 5e-5 }, .{ 10, 10, top });
    defer plate.deinit();
    const half = 0.75 * t.xsect;
    // The upper edge 5e-5 over the top, the lower 2.5e-4 under it
    const mid = top + 5e-5 - half;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var tetra = try @import("../construct/hull.zig").hull(testing.allocator, t, &.{ .{ -1, 2, mid - half }, .{ 1, 2, mid - half }, .{ 0, 1, mid + half }, .{ 0, 3, mid + half } }, &diag);
    defer tetra.deinit();
    // Classified by a point clear of the plate until the operand precondition
    // (2026-11-15): the tetrahedron, 1.5 tolerances thick, is below the boolean's minimum
    // feature size, refused
    try expectBelowFeatureSize(&plate, &tetra);
}

test "degeneracy: a plane between a flat tetrahedron's edges 3e-5 apart: below the minimum feature size, the split refused" {
    // The gap draws' second find (2026-11-14): a tetrahedron whose opposite edges are 1.5
    // intersection tolerances apart, cut by the plane x = z between them at 45°; the cut's
    // section on the plane is a triangle 2 long and 4.2e-5 across, its centroid a third of
    // the way across, the zone from the upper face, and no candidate clear of the
    // tetrahedron but its incenter (`unclassified`)
    const h = 0.75 * tol.xsect;
    var flat = try tetrahedron(.{ -1, 0, -h }, .{ 1, 0, -h }, .{ 0, -1, h }, .{ 0, 1, h });
    defer flat.deinit();
    var tetra = try helpers.moved(&flat, .{ -2e-5, -2e-5, -5e-6 });
    defer tetra.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // Split and classified at the section's incenter until the operand precondition
    // (2026-11-15): the tetrahedron, its edges 3e-5 apart, is below the minimum feature
    // size of the boolean a split is, refused
    try testing.expectError(error.Degenerate, trim.splitByPlane(testing.allocator, &tetra, .{ 1, 0, -1 }, 0, .{}, &diag));
    try testing.expectEqual(diagnostics.Code.below_feature_size, diag.first().?.code);
}

test "degeneracy: a void touching its outer shell along a line, at a point, or another void at a corner is refused by design; a solid in a cavity touching it is two solids" {
    // research/manifold-parity.md (2026-11-14): shells of one solid touch nowhere (a void
    // apart from its outer shell and every other void, ISO 10303-42), solids may touch.
    // A diamond prism's edge on a cube's face, cut out: it was one shell through a two-edge
    // loop of zero width on that face (genus 0, OpenCascade's InvalidImbricationOfWires)
    var cube = try box(.{ 0, 0, 0 }, .{ 4, 4, 4 });
    defer cube.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var outline = try primitives.polygon(testing.allocator, tol, &.{ .{ 2, 0 }, .{ 3, 1 }, .{ 2, 2 }, .{ 1, 1 } }, &diag);
    defer outline.deinit();
    var diamond0 = try @import("../construct/sweep.zig").extrude(testing.allocator, &outline, .{ 0, 0, 2 }, .{}, &diag);
    defer diamond0.deinit();
    var diamond = try helpers.moved(&diamond0, .{ 0, 0, 1 });
    defer diamond.deinit();
    try expectPinched(&cube, &diamond);
    // A tetrahedron's one corner on the cube's bottom (it passed by the void's vertex order)
    var tet = try tetrahedron(.{ 2, 2, 0 }, .{ 3, 1.5, 2 }, .{ 1, 1.5, 2 }, .{ 2, 3, 2 });
    defer tet.deinit();
    try expectPinched(&cube, &tet);
    // Two voids touching corner to corner
    var big = try box(.{ 0, 0, 0 }, .{ 6, 6, 6 });
    defer big.deinit();
    var first = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer first.deinit();
    var hollow = try sound(&big, &first, .difference);
    defer hollow.deinit();
    var second = try box(.{ 3, 3, 3 }, .{ 5, 5, 5 });
    defer second.deinit();
    try expectPinched(&hollow, &second);
    // An octahedron in a hollow cube's cavity, its corners on the floor and the roof: a
    // solid touching the cavity of another, two solids, which pass
    var cavity = try box(.{ 1, 1, 1 }, .{ 5, 5, 5 });
    defer cavity.deinit();
    var shell = try sound(&big, &cavity, .difference);
    defer shell.deinit();
    var octa = try @import("../construct/hull.zig").hull(testing.allocator, tol, &.{ .{ 3, 3, 1 }, .{ 3, 3, 5 }, .{ 3, 1.5, 3 }, .{ 3, 4.5, 3 }, .{ 1.5, 3, 3 }, .{ 4.5, 3, 3 } }, &diag);
    defer octa.deinit();
    var both = try sound(&shell, &octa, .@"union");
    defer both.deinit();
    try testing.expectEqual([2]usize{ 2, 1 }, shellKinds(&both));
    try testing.expectApproxEqAbs(216 - 64 + try volume(&octa), try volume(&both), CLOSE);
    const parts = try @import("../construct/decompose.zig").decompose(testing.allocator, &both, .{}, &diag);
    defer {
        for (parts) |*part| part.deinit();
        testing.allocator.free(parts);
    }
    try testing.expectEqual(@as(usize, 2), parts.len);
}

/// The difference of `a` and `b` refused by design (`pinched`).
fn expectPinched(a: *const Body, b: *const Body) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    if (pipeline.boolean(testing.allocator, a, b, .difference, .{}, &diag, null)) |result| {
        var made = result;
        made.deinit();
        return error.TestExpectedError;
    } else |e| {
        errdefer std.debug.print("{f}\n", .{diag});
        try testing.expectEqual(error.Degenerate, e);
    }
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    try testing.expectEqual(diagnostics.EntityKind.shell, diag.first().?.entity.kind);
}

test "degeneracy: a corner 2.3e-5 under one with a gap of 6.4e-6 merges with it by both reaches, a ball past the zone, refused" {
    // research/consistent-tolerances.md's gapped corner: two boxes 9e-6 apart at an edge,
    // united, leave its ends merged with a gap of 6.36e-6; a box whose top corner lies
    // 2.3e-5 under one is within the tolerance and that gap of it, as vertex–edge and
    // vertex–face reach, but vertex–vertex reached the tolerance alone, left the two apart,
    // and an edge of one was found ending at the other: refused as an edge 0 long of 3.
    // Merged, their ball's radius is past the zone (`gap_too_large`), naming the vertex
    var p = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer p.deinit();
    var q = try box(.{ 1.000009, 1.000009, 0 }, .{ 2, 2, 1 });
    defer q.deinit();
    var u = try sound(&p, &q, .@"union");
    defer u.deinit();
    var g: Vec3 = undefined;
    var gap: f64 = 0;
    for (u.vertices.items, 0..) |v, i| if (!v.tombstone and v.gap > gap and u.point(VertexIndex.of(i))[2] == 0) {
        gap = v.gap;
        g = u.point(VertexIndex.of(i));
    };
    try testing.expectApproxEqAbs(@as(f64, 6.36e-6), gap, 1e-8);
    var r = try box(.{ g[0] - 3, g[1] - 3, -3 }, .{ g[0], g[1], -2.3e-5 });
    defer r.deinit();
    try expectRefused(&u, &r, .gap_too_large);
}

fn areaOf(body: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(body, .{}, &diag)).area;
}

/// The unit box and a box `lo`–`hi` turned `angle` about the z axis through `pivot`.
fn unitAndTurned(lo: Vec3, hi: Vec3, pivot: Vec3, angle: f64) ![2]Body {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    errdefer a.deinit();
    var b = try box(lo, hi);
    defer b.deinit();
    return .{ a, try turned(&b, pivot, vec.Z3, angle) };
}

test "degeneracy: OCCT's H9, a hole through the box touching its side along a line, refused pinched; the rest made" {
    // After OCCT `tests/boolean/bop*_simple/H9`: its coordinates and areas; volumes and
    // counts worked out here. A square ½ on a side turned 30° about (¼,¼), corners (¼,¼),
    // (¼ + √3/4, ½), (√3/4, ½ + √3/4) and (0, ¼ + √3/4), the last on the side x = 0 to the
    // turn's rounding. The difference is the box with a square hole through it whose edge
    // lies on the side: one shell touching itself along a line, which OCCT keeps (area
    // 7.5) and Locus refuses by design. The intersection is the turned box (2 · ¼ + 2 ·
    // 1, ¼), the union the box, the swapped difference empty
    var pair = try unitAndTurned(.{ 0.25, 0.25, 0 }, .{ 0.75, 0.75, 1 }, .{ 0.25, 0.25, 0 }, std.math.degreesToRadians(30.0));
    defer for (&pair) |*body| body.deinit();
    try expectPinched(&pair[0], &pair[1]);
    var i = try sound(&pair[0], &pair[1], .intersection);
    defer i.deinit();
    try expectShape(&i, 0.25, 6, 1);
    try testing.expectApproxEqAbs(@as(f64, 2.5), try areaOf(&i), CLOSE);
    var u = try sound(&pair[0], &pair[1], .@"union");
    defer u.deinit();
    try expectShape(&u, 1, 6, 1);
    try testing.expectEqual(@as(usize, 8), u.counts().vertices);
    var s = try sound(&pair[1], &pair[0], .difference);
    defer s.deinit();
    try testing.expect(s.isEmpty());
}

test "degeneracy: H9's void, the turned box inside the box but for its edge on the side, refused pinched" {
    // research/occt-tests.md (O5): H9's turned box cut to z from ¼ to ¾, so the difference
    // is a void whose edge (0, ¼ + √3/4) lies on the side x = 0 along a segment: a void
    // touching its outer shell along a line, which no STEP solid holds (P1, Leo's
    // decision); OCCT has no such case of its own. The intersection is the turned box
    var pair = try unitAndTurned(.{ 0.25, 0.25, 0.25 }, .{ 0.75, 0.75, 0.75 }, .{ 0.25, 0.25, 0 }, std.math.degreesToRadians(30.0));
    defer for (&pair) |*body| body.deinit();
    try expectPinched(&pair[0], &pair[1]);
    var i = try sound(&pair[0], &pair[1], .intersection);
    defer i.deinit();
    try expectShape(&i, 0.125, 6, 1);
}

test "degeneracy: OCCT's N3, a box under the box, its top's corner on the box's bottom edge: the bottom's one loop through that corner twice" {
    // After OCCT `tests/boolean/bop*_simple/N3`: its coordinates and areas; volumes and
    // counts worked out here. H9's turned square under the box (z from −1 to 0), its top
    // inside the box's bottom but for its corner (0, ¼ + √3/4, 0) on the bottom's edge.
    // The union is one solid whose bottom face is the square less the turned one: a hole
    // touching the outer boundary at that corner, one loop passing it twice (a hole loop
    // of its own sharing the corner would leave V − E + F − (L − F) one short of 2). The
    // box's 8 corners and the turned box's 8, one of them splitting the box's edge: V 16,
    // E 12 + 1 + 12, F 6 + 5, a loop each (16 − 25 + 11 = 2); area 6 + 5/2 − 2 · ¼, volume
    // 1¼. Nothing in common; each difference its first operand
    var pair = try unitAndTurned(.{ 0.25, 0.25, -1 }, .{ 0.75, 0.75, 0 }, .{ 0.25, 0.25, 0 }, std.math.degreesToRadians(30.0));
    defer for (&pair) |*body| body.deinit();
    var u = try sound(&pair[0], &pair[1], .@"union");
    defer u.deinit();
    try expectShape(&u, 1.25, 11, 1);
    try testing.expectApproxEqAbs(@as(f64, 8), try areaOf(&u), CLOSE);
    const counts = u.counts();
    try testing.expectEqual(@as(usize, 16), counts.vertices);
    try testing.expectEqual(@as(usize, 25), counts.edges);
    try testing.expectEqual(@as(usize, 11), counts.loops);
    // The corner on the edge, and the one loop that passes it twice
    const corner: Vec3 = .{ 0, 0.25 + @sqrt(3.0) / 4.0, 0 };
    var at: ?VertexIndex = null;
    for (u.vertices.items, 0..) |v, k| if (!v.tombstone and vec.length(vec.sub(u.point(VertexIndex.of(k)), corner)) < 1e-9) {
        at = VertexIndex.of(k);
    };
    var twice: usize = 0;
    for (u.loops.items, 0..) |l, k| {
        if (l.tombstone or l.first == .none) continue;
        var passes: usize = 0;
        var coedges = @import("../topology/traverse.zig").Coedges.init(&u, types.LoopIndex.of(k));
        while (try coedges.next()) |c| passes += @intFromBool(u.coedgeStart(c) == at.?);
        if (passes == 2) twice += 1 else try testing.expect(passes < 2);
    }
    try testing.expectEqual(@as(usize, 1), twice);
    // Touching face to face, nothing inside the other: the contacts are the turned box's
    // four top corners, the one on the edge among them
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var again = try helpers.reported(&pair[0], &pair[1], .@"union", .{}, &r);
    again.deinit();
    try testing.expectEqual(@as(usize, 4), r.contacts.items.len);
    var at_corner: usize = 0;
    for (r.contacts.items) |p| {
        try testing.expectApproxEqAbs(@as(f64, 0), p[2], 1e-12);
        at_corner += @intFromBool(vec.length(vec.sub(p, corner)) < 1e-9);
    }
    try testing.expectEqual(@as(usize, 1), at_corner);
    var i = try sound(&pair[0], &pair[1], .intersection);
    defer i.deinit();
    try testing.expect(i.isEmpty());
    var d = try sound(&pair[0], &pair[1], .difference);
    defer d.deinit();
    try expectShape(&d, 1, 6, 1);
    var s = try sound(&pair[1], &pair[0], .difference);
    defer s.deinit();
    try expectShape(&s, 0.25, 6, 1);
    try expectIdentities(&pair[0], &pair[1]);
}

test "degeneracy: OCCT's F5, G2 and G8, what a turned box inside the box leaves: rings of solids touching along edges" {
    // After OCCT `tests/boolean/bop*_simple/F5`, `G2` and `G8`: their coordinates and
    // areas; volumes and counts worked out here. Each difference is the box less a prism
    // whose corners lie on its sides, so its solids are prisms touching along the vertical
    // edges at those corners: one warning per edge, each solid's volume and faces. F5: the
    // diamond on the edge midpoints leaves four triangles of legs ½, a ring (⅛ each). G2:
    // corners (¼,0), (1,⅜) and (0,½) on the sides leave the triangles (0,0) (¼,0) (0,½)
    // and (¼,0) (1,0) (1,⅜) and the pentagon (0,½) (¾,⅞) (1,⅜) (1,1) (0,1), a ring of three
    // (1/16, 9/64, 21/64). G8: corners (0,¼) and (√3/4,0) leave the triangle they make with
    // the origin and the rest of the box, a heptagon, touching at both (√3/32, ¾ − √3/32)
    const Ring = struct { name: []const u8, lo: Vec3, size: Vec3, turn: f64, touching: usize, volumes: []const f64, faces: []const usize };
    const sqrt3: f64 = @sqrt(3.0);
    const rings = [_]Ring{
        .{ .name = "F5", .lo = .{ 0, 0.5, 0 }, .size = .{ std.math.sqrt2 / 2.0, std.math.sqrt2 / 2.0, 1 }, .turn = std.math.degreesToRadians(-45.0), .touching = 4, .volumes = &.{ 0.125, 0.125, 0.125, 0.125 }, .faces = &.{ 5, 5, 5, 5 } },
        .{ .name = "G2", .lo = .{ 0.25, 0, 0 }, .size = .{ 3 * @sqrt(5.0) / 8.0, @sqrt(5.0) / 4.0, 1 }, .turn = std.math.atan2(@as(f64, 1), 2), .touching = 3, .volumes = &.{ 1.0 / 16.0, 9.0 / 64.0, 21.0 / 64.0 }, .faces = &.{ 5, 5, 7 } },
        .{ .name = "G8", .lo = .{ 0, 0.25, 0 }, .size = .{ 0.5, 0.5, 1 }, .turn = std.math.degreesToRadians(-30.0), .touching = 2, .volumes = &.{ sqrt3 / 32, 0.75 - sqrt3 / 32 }, .faces = &.{ 5, 9 } },
    };
    for (rings) |ring| {
        errdefer std.debug.print("{s}\n", .{ring.name});
        var pair = try unitAndTurned(ring.lo, vec.add(ring.lo, ring.size), ring.lo, ring.turn);
        defer for (&pair) |*body| body.deinit();
        var d = try sound(&pair[0], &pair[1], .difference);
        defer d.deinit();
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var again = try pipeline.boolean(testing.allocator, &pair[0], &pair[1], .difference, .{}, &diag, null);
        again.deinit();
        try testing.expectEqual(ring.touching, warned(&diag, .solids_touch));
        const parts = try decompose.decompose(testing.allocator, &d, .{}, &diag);
        defer {
            for (parts) |*part| part.deinit();
            testing.allocator.free(parts);
        }
        try testing.expectEqual(ring.volumes.len, parts.len);
        // Smallest first, as the rows list them
        var order: [4]usize = .{ 0, 1, 2, 3 };
        var volumes: [4]f64 = undefined;
        for (parts, 0..) |*part, k| volumes[k] = try volume(part);
        std.mem.sort(usize, order[0..parts.len], volumes[0..parts.len], struct {
            fn lessThan(v: []const f64, x: usize, y: usize) bool {
                return v[x] < v[y];
            }
        }.lessThan);
        for (order[0..parts.len], ring.volumes, ring.faces) |k, want_volume, want_faces| {
            try testing.expectApproxEqAbs(want_volume, volumes[k], CLOSE);
            try testing.expectEqual(want_faces, parts[k].counts().faces);
        }
    }
}

test "degeneracy: OCCT's Q9, a turned box's edge lying in the other's top as it crosses it: one edge there in every result" {
    // After OCCT `tests/boolean/bop*_simple/Q9`: its coordinates and areas; volumes and
    // counts worked out here (corpus_test.zig's `TURNED` has them). The turned box's edge
    // from (1,1,3) to (2,1,3) lies in the big box's top: imprinted from both operands' faces
    // and the section, it must be one edge of each result, not two, nor split
    var a = try box(.{ 0, 0, 0 }, .{ 3, 3, 3 });
    defer a.deinit();
    var b0 = try box(.{ 1, 1, 3 }, .{ 2, 2, 4 });
    defer b0.deinit();
    var b = try turned(&b0, .{ 1, 1, 3 }, vec.X3, std.math.degreesToRadians(-30.0));
    defer b.deinit();
    const Pair = struct { first: *const Body, second: *const Body, op: pipeline.Op };
    for ([_]Pair{ .{ .first = &a, .second = &b, .op = .intersection }, .{ .first = &a, .second = &b, .op = .difference }, .{ .first = &a, .second = &b, .op = .@"union" }, .{ .first = &b, .second = &a, .op = .difference } }) |p| {
        errdefer std.debug.print("{s}{s}\n", .{ @tagName(p.op), if (p.first == &b) ", swapped" else "" });
        var r = try sound(p.first, p.second, p.op);
        defer r.deinit();
        var on: usize = 0;
        var length: f64 = 0;
        for (r.edges.items) |e| {
            if (e.flags.tombstone) continue;
            const s = r.point(e.start);
            const t = r.point(e.end);
            const along = @abs(s[1] - 1) < 1e-9 and @abs(s[2] - 3) < 1e-9 and @abs(t[1] - 1) < 1e-9 and @abs(t[2] - 3) < 1e-9;
            if (!along) continue;
            on += 1;
            length += @abs(t[0] - s[0]);
        }
        try testing.expectEqual(@as(usize, 1), on);
        try testing.expectApproxEqAbs(@as(f64, 1), length, CLOSE);
    }
}

test "degeneracy: OCCT's bug25354_33 and _34, a turned box touching a box at one point: a corner on an edge, two edges crossing" {
    // After OCCT `tests/bugs/modalg_5/bug25354_33` and `_34`: their coordinates and their
    // section's one vertex; measures and counts worked out here. A cube of 10 under and in
    // front of the cube of 10 at the origin, turned −45° about the z axis through
    // (5,0,0): its top (in the other's bottom's plane) a diamond whose corner (5,0,0) lies
    // on the other's edge y = z = 0. _34 raises it by 6 and turns it 45° about the x axis
    // through (5,0,0) too: its vertical edge through that point now crosses the other's
    // edge there, both at an inner point. Either way they touch at that point alone: the
    // union two cubes (12 faces, 1200, 2000), nothing in common, the difference the first,
    // and the report's one contact the point
    var a = try box(.{ 0, 0, 0 }, .{ 10, 10, 10 });
    defer a.deinit();
    for ([_]bool{ false, true }) |skew| {
        errdefer std.debug.print("{s}\n", .{if (skew) "bug25354_34" else "bug25354_33"});
        var b0 = try box(.{ 5, -10, if (skew) -4 else -10 }, .{ 15, 0, if (skew) 6 else 0 });
        defer b0.deinit();
        var b1 = try turned(&b0, .{ 5, 0, 0 }, vec.Z3, std.math.degreesToRadians(-45.0));
        defer b1.deinit();
        var b = if (skew) try turned(&b1, .{ 5, 0, 0 }, vec.X3, std.math.degreesToRadians(45.0)) else try b1.clone(testing.allocator);
        defer b.deinit();
        var u = try sound(&a, &b, .@"union");
        defer u.deinit();
        try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
        try testing.expectEqual(@as(usize, 12), u.counts().faces);
        try testing.expectApproxEqAbs(@as(f64, 2000), try volume(&u), CLOSE);
        try testing.expectApproxEqAbs(@as(f64, 1200), try areaOf(&u), CLOSE);
        var i = try sound(&a, &b, .intersection);
        defer i.deinit();
        try testing.expect(i.isEmpty());
        var d = try sound(&a, &b, .difference);
        defer d.deinit();
        try expectShape(&d, 1000, 6, 1);
        try testing.expectEqual(@as(usize, 8), d.counts().vertices);
        for ([_]pipeline.Op{ .@"union", .difference }) |op| {
            var r = pipeline.Report.init(testing.allocator);
            defer r.deinit();
            var again = try helpers.reported(&a, &b, op, .{}, &r);
            again.deinit();
            try testing.expectEqual(@as(usize, 1), r.contacts.items.len);
            try testing.expect(vec.length(vec.sub(r.contacts.items[0], .{ 5, 0, 0 })) < 1e-9);
        }
        try expectIdentities(&a, &b);
    }
}

/// A probe's operation (research/occt-tests.md §4 a): a result `sound` passes, or null,
/// refused with a code of `pipeline.REFUSALS` (`refused`), never a guard's. `shift` gets
/// the result's reported shift.
fn madeOrRefused(a: *const Body, b: *const Body, op: pipeline.Op, refused: *?diagnostics.Code, shift: *f64) !?Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var report = pipeline.Report.init(testing.allocator);
    defer report.deinit();
    refused.* = null;
    shift.* = 0;
    if (pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, &report)) |result| {
        var made = result;
        made.deinit();
        shift.* = report.shift;
        return try sound(a, b, op);
    } else |e| {
        errdefer std.debug.print("{s}: {s}, {f}\n", .{ @tagName(op), @errorName(e), diag });
        const code = diag.first().?.code;
        try testing.expect(std.mem.indexOfScalar(diagnostics.Code, &pipeline.REFUSALS, code) != null);
        refused.* = code;
        return null;
    }
}

/// The probes' oracle, weaker by design than the corpus's: each operation of `a` and `b`,
/// and of `b` and `a`, made and sound or refused by type; the volume identities among
/// those made, to the slab the tolerance may count either way (its thickness over both
/// operands' faces) and the results' reported shifts; the union and the intersection the
/// same either way round, both made (their solids alike, their volumes within that slab)
/// or both refused with one code.
fn expectProbe(a: *const Body, b: *const Body) !void {
    const ops = [_]pipeline.Op{ .@"union", .intersection, .difference };
    var results: [2][3]?Body = @splat(@splat(null));
    defer for (&results) |*row| for (row) |*r| if (r.*) |*body| body.deinit();
    var codes: [2][3]?diagnostics.Code = undefined;
    var shifts: [2][3]f64 = undefined;
    var volumes: [2][3]f64 = @splat(@splat(0));
    for ([2][2]*const Body{ .{ a, b }, .{ b, a } }, 0..) |operands, k| {
        errdefer std.debug.print("{s} first\n", .{if (k == 0) "a" else "b"});
        for (ops, 0..) |op, j| {
            results[k][j] = try madeOrRefused(operands[0], operands[1], op, &codes[k][j], &shifts[k][j]);
            if (results[k][j]) |*r| volumes[k][j] = try volume(r);
        }
    }
    const slab = tol.xsect * (try areaOf(a) + try areaOf(b));
    const operand_volumes = [2]f64{ try volume(a), try volume(b) };
    for (0..2) |k| {
        errdefer std.debug.print("{s} first\n", .{if (k == 0) "a" else "b"});
        const made = [3]bool{ results[k][0] != null, results[k][1] != null, results[k][2] != null };
        if (made[0] and made[1]) try testing.expectApproxEqAbs(operand_volumes[0] + operand_volumes[1], volumes[k][0] + volumes[k][1], slab + shifts[k][0] + shifts[k][1]);
        if (made[1] and made[2]) try testing.expectApproxEqAbs(operand_volumes[k] - volumes[k][1], volumes[k][2], slab + shifts[k][1] + shifts[k][2]);
    }
    for (0..2) |j| {
        errdefer std.debug.print("{s} either way round: {any} and {any}\n", .{ @tagName(ops[j]), codes[0][j], codes[1][j] });
        try testing.expectEqual(codes[0][j], codes[1][j]);
        if (results[0][j]) |*r| {
            try testing.expectEqual(shellKinds(r), shellKinds(&results[1][j].?));
            try testing.expectApproxEqAbs(volumes[0][j], volumes[1][j], slab + shifts[0][j] + shifts[1][j]);
        }
    }
}

test "degeneracy: OCCT's D4 and C6 scaled until the neck and the spike are 2, 1 and ½ intersection tolerances: made and sound, or refused by type" {
    // research/occt-tests.md §2 C: one geometry at several scales, the feature the
    // tolerance has to decide on shrinking past it: D4's neck between the bar's end and
    // the box's corner, C6's spike past the box's side
    for ([_][]const f64{ &D4_SCALES, &C6_SCALES }, [_]f64{ 0.5, 0.25 }) |scales, width| {
        for (scales) |s| {
            errdefer std.debug.print("{s} at scale {d}\n", .{ if (width == 0.5) "D4" else "C6", s });
            var a = try box(.{ 0, 0, 0 }, .{ s, s, s });
            defer a.deinit();
            var b0 = try box(.{ 0, 0, 0 }, .{ s * BAR_LENGTH, s * width, s });
            defer b0.deinit();
            var b = try turned(&b0, .{ 0, 0, 0 }, vec.Z3, BAR_TURN);
            defer b.deinit();
            try expectProbe(&a, &b);
        }
    }
}

test "degeneracy: OCCT's H7 thinned to 5, 3 and 1.5 intersection tolerances, the twin path on a sliver: made and sound, or refused alike either way round" {
    // research/occt-tests.md §4 a (research-review item 2's open question): H7's bar,
    // whose top and bottom lie in the box's, as thin as a few tolerances, so its common
    // part with the box is a strip of coincident faces that thin
    for (H7_WIDTHS) |n| {
        errdefer std.debug.print("{d} intersection tolerances wide\n", .{n});
        var pair = try unitAndTurned(.{ 0, 0.25, 0 }, .{ n * tol.xsect, 0.75, 1 }, .{ 0, 0.25, 0 }, std.math.degreesToRadians(240.0));
        defer for (&pair) |*body| body.deinit();
        try expectProbe(&pair[0], &pair[1]);
    }
}

test "degeneracy: OCCT's spec case, a box 1e-6 and 1e-4 taller and deeper than the one it is joined to, united either way round" {
    // After OCCT's `dox/specification/boolean_operations` §11a.1.1, case 2: a cube of 10
    // and the next box along x, 10 + δ high and deep. Within the zone (δ = 1e-6) the tops
    // and backs are one plane each (D28: the plane moving the faces least, here the two
    // alike to rounding and taken by the planes' fixed order, z = 10 and y = 10), so either
    // union is the same box, 6 faces, 20 · 10², to its reported shift;
    // at five intersection tolerances (δ = 1e-4) the steps stay, both unions the same nine
    // faces (the ends, bottom and front whole, two tops, two backs, the second's L-shaped
    // strip at x = 10 left uncovered), 1000 + 10 · (10 + δ)²
    for (OVERSIZES) |over| {
        errdefer std.debug.print("{e} over\n", .{over});
        var a = try box(.{ 0, 0, 0 }, .{ 10, 10, 10 });
        defer a.deinit();
        var b = try box(.{ 10, 0, 0 }, .{ 20, 10 + over, 10 + over });
        defer b.deinit();
        try expectProbe(&a, &b);
        const within = over < tol.zone;
        for ([_]bool{ false, true }) |swapped| {
            errdefer std.debug.print("{s}\n", .{if (swapped) "b ∪ a" else "a ∪ b"});
            var r = pipeline.Report.init(testing.allocator);
            defer r.deinit();
            var u = try helpers.reported(if (swapped) &b else &a, if (swapped) &a else &b, .@"union", .{}, &r);
            defer u.deinit();
            try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&u));
            try testing.expectEqual(@as(usize, if (within) 6 else 9), u.counts().faces);
            const side = if (within) 10 else 10 + over;
            const want = if (within) 20 * side * side else 1000 + 10 * side * side;
            if (within) try testing.expect(r.shift > 0);
            try testing.expectApproxEqAbs(want, try volume(&u), r.shift + CLOSE);
        }
    }
}

test "degeneracy: OCCT's bug33361, four hexahedra whose corners miss by 1e-4, joined one by one: made and sound, or refused by type" {
    // Dirty input (research/occt-tests.md, O6; OCCT checks the shape only): each
    // hexahedron as the hull of its corners, the fold of OCCT's fuses, each step by the
    // probes' oracle; a step refused ends the fold
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var solids: [4]Body = undefined;
    var built: usize = 0;
    defer for (solids[0..built]) |*s| s.deinit();
    for (&BUG33361, &solids) |*corners, *s| {
        s.* = try @import("../construct/hull.zig").hull(testing.allocator, tol, corners, &diag);
        built += 1;
    }
    var current = try solids[0].clone(testing.allocator);
    defer current.deinit();
    for (solids[1..], 1..) |*next, k| {
        errdefer std.debug.print("step {d}\n", .{k});
        try expectProbe(&current, next);
        var refused: ?diagnostics.Code = null;
        var shift: f64 = 0;
        const made = try madeOrRefused(&current, next, .@"union", &refused, &shift) orelse break;
        current.deinit();
        current = made;
    }
}

test "degeneracy: a box's top bent 1.5e-5 off a line at its middle corner, a plate hinged on it, meet along that line either way round" {
    // Step 1 of closing M4 (order symmetry): two faces parallel within the angle sharing
    // three merged vertices meet along their line when every vertex lies within its reach
    // of it. The line ran from the first merged vertex, the first operand's: from the bent
    // corner the far corner was 3e-5 off it (beyond reach: one plane, then refused
    // below_feature_size), between the corners the bent one was 1.5e-5 off (a line, made).
    // The line through the two farthest apart is the vertices' own
    const d = 1.5e-5;
    const slope = 0.005;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // The pentagon from the bent corner, so that the box numbers it first
    var outline = try primitives.polygon(testing.allocator, tol, &.{ .{ 5, d }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 0 } }, &diag);
    defer outline.deinit();
    var raised = try @import("../construct/sweep.zig").extrude(testing.allocator, &outline, .{ 0, 0, 1 }, .{}, &diag);
    defer raised.deinit();
    var a = try helpers.moved(&raised, .{ 0, 0, -1 });
    defer a.deinit();
    // The plate's bottom rises from the box's front edge at the slope, its front leaning out
    // (upright, it would hold both of the box's front walls in its plane)
    const corners = [_]Vec3{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 10 * slope }, .{ 0, 10, 10 * slope }, .{ 0, -1, 1 }, .{ 10, -1, 1 }, .{ 10, 10, 1 }, .{ 0, 10, 1 } };
    var b = try @import("../construct/hull.zig").hull(testing.allocator, tol, &corners, &diag);
    defer b.deinit();
    try expectAllSound(&a, &b);
}

test "degeneracy: a box over the notch of an L-shaped top, its bottom the intersection tolerance over the top's plane, is apart from it, not refused" {
    // Step 1 of closing M4 (order symmetry): "on a face" is on its plane and not outside
    // it. Vertex–face, edge–face's paves and the feature-size rule asked the plane first
    // and refused a vertex at its reach of it to rounding, though the vertex lay over the
    // notch, outside the face, where its height decides nothing (`pave.placeOnFace`)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var outline = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 0.5 }, .{ 0.5, 0.5 }, .{ 0.5, 1 }, .{ 0, 1 } }, &diag);
    defer outline.deinit();
    var raised = try @import("../construct/sweep.zig").extrude(testing.allocator, &outline, .{ 0, 0, 1 }, .{}, &diag);
    defer raised.deinit();
    var l = try helpers.moved(&raised, .{ 0, 0, -1 });
    defer l.deinit();
    var b = try box(.{ 0.6, 0.6, tol.xsect }, .{ 0.9, 0.9, 1 });
    defer b.deinit();
    try expectAllSound(&l, &b);
}

test "degeneracy: a tetrahedron's edge 2.7e-5 from where two boxes' faces meet, their union's section edges lie on their faces within the gaps carried onto them" {
    // The locus fuzzer's find (2026-11-18, 10K session on a5301ce8, au), reduced: a
    // tetrahedron's edge passes 2.7e-5 from the corner where a box's side and top meet a
    // second box's side (beyond the intersection tolerance, 2e-5, of the corner, within it
    // and the gaps of the faces). The merged vertex there lay past the intersection
    // tolerance off the second box's side, within its gap; the section lines drawn through
    // it left that plane by as much, and their edges, made with no gap, were off their
    // face (`edge_off_surface`). Each
    // edge's gap covers its line's height over its faces' planes, and its ends' gaps cover
    // its own (`pipeline.coverFaces`, OCCT's CorrectCurveOnSurface and UpdateVertex). The
    // union is made; the difference, the corner's edge touching the tetrahedron's within
    // the tolerance, is refused by design (`pinched`)
    var t = try tetrahedron(.{ 3.5, 3, 5 }, .{ 0.5, 4, 2 }, .{ 1.5, 0, 3 }, .{ 4.5, 0, 1 });
    defer t.deinit();
    var a = try box(.{ -tol.xsect, 3, 2.5 }, .{ 2 - tol.xsect, 4, 3.5 });
    defer a.deinit();
    var b = try box(.{ 1, 0.5 - tol.xsect, 1 }, .{ 3, 3.5 - tol.xsect, 4 });
    defer b.deinit();
    var ta = try sound(&t, &a, .@"union");
    defer ta.deinit();
    var both = try sound(&ta, &b, .@"union");
    defer both.deinit();
    try expectProbe(&ta, &b);
}
