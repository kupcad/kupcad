//! Booleans of boxes whose answers are known: overlapping at a corner, sharing a plane,
//! a hole cut through, a void left inside, apart, touching along a face and along an edge,
//! identical; the volume identities of booleans; empty operands; a curved operand refused.
//! Every result passes the checker to level 2 and the overlap rules (query/overlap.zig),
//! the oracle the solid overlap rules were written first to be.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const primitives = @import("../construct/primitives.zig");
const transform = @import("../construct/transform.zig");
const mat = @import("../math/mat.zig");
const mass = @import("../measure/mass.zig");
const overlap = @import("../query/overlap.zig");
const pipeline = @import("pipeline.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Op = pipeline.Op;

const tol = Tolerance.fromZone(1e-5);
const CLOSE = 1e-9;

/// A box from `lo` to `hi`.
fn box(lo: Vec3, hi: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var unit = try primitives.box(testing.allocator, tol, hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], false, &diag);
    defer unit.deinit();
    return transform.transform(testing.allocator, &unit, &mat.Affine.translate(lo), .{}, &diag);
}

/// `a op b`, checked: every rule of the checker and the overlap rules pass it.
fn sound(a: *const Body, b: *const Body, op: Op) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var result = pipeline.boolean(testing.allocator, a, b, op, .{}, &diag) catch |e| {
        std.debug.print("boolean {s}: {f}\n", .{ @tagName(op), diag });
        return e;
    };
    errdefer result.deinit();
    var report = try check.run(testing.allocator, &result, .global);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        std.debug.print("boolean {s}, the checker: {f}\n", .{ @tagName(op), f });
        return error.TestUnexpectedResult;
    }
    overlap.check(testing.allocator, &result, .{}, &diag) catch |e| {
        std.debug.print("boolean {s}, the overlap rules: {f}\n", .{ @tagName(op), diag });
        return e;
    };
    return result;
}

fn volume(body: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(body, .{}, &diag)).volume;
}

/// The result's volume, faces and shells.
fn expectShape(body: *const Body, want_volume: f64, faces: usize, shells: usize) !void {
    try testing.expectApproxEqAbs(want_volume, try volume(body), CLOSE);
    const counts = body.counts();
    try testing.expectEqual(faces, counts.faces);
    try testing.expectEqual(shells, counts.shells);
}

/// The volume identities: V(A ∪ B) + V(A ∩ B) = V(A) + V(B), V(A − B) = V(A) − V(A ∩ B).
fn expectIdentities(a: *const Body, b: *const Body) !void {
    var u = try sound(a, b, .@"union");
    defer u.deinit();
    var i = try sound(a, b, .intersection);
    defer i.deinit();
    var d = try sound(a, b, .difference);
    defer d.deinit();
    const va = try volume(a);
    const vb = try volume(b);
    const vi = try volume(&i);
    try testing.expectApproxEqAbs(va + vb, try volume(&u) + vi, CLOSE);
    try testing.expectApproxEqAbs(va - vi, try volume(&d), CLOSE);
}

test "boolean: two boxes overlapping at a corner, every operation, and the identities" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    // Each box's three faces away from the other whole, its other three notched
    try expectShape(&u, 15, 12, 1);
    var i = try sound(&a, &b, .intersection);
    defer i.deinit();
    try expectShape(&i, 1, 6, 1);
    try testing.expectEqual(@as(usize, 8), i.counts().vertices);
    var d = try sound(&a, &b, .difference);
    defer d.deinit();
    // Three notched faces, three whole, the notch's three
    try expectShape(&d, 7, 9, 1);
    try expectIdentities(&a, &b);
    try expectIdentities(&b, &a);
}

test "boolean: boxes sharing their top and bottom planes, merged there into one face each" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 0 }, .{ 3, 3, 1 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    // An eight-sided prism: top, bottom, eight sides
    try expectShape(&u, 7, 10, 1);
    var i = try sound(&a, &b, .intersection);
    defer i.deinit();
    try expectShape(&i, 1, 6, 1);
    var d = try sound(&a, &b, .difference);
    defer d.deinit();
    // An L: top, bottom, six sides
    try expectShape(&d, 3, 8, 1);
    try expectIdentities(&a, &b);
}

test "boolean: a hole cut through a box, and a void left inside one" {
    var a = try box(.{ 0, 0, 0 }, .{ 3, 3, 3 });
    defer a.deinit();
    var drill = try box(.{ 1, 1, -1 }, .{ 2, 2, 4 });
    defer drill.deinit();
    var holed = try sound(&a, &drill, .difference);
    defer holed.deinit();
    // Six outer faces, the top and bottom with a hole each, four inner sides
    try expectShape(&holed, 24, 10, 1);
    try testing.expectEqual(@as(usize, 12), holed.counts().loops);
    var inner = try box(.{ 1, 1, 1 }, .{ 2, 2, 2 });
    defer inner.deinit();
    var hollow = try sound(&a, &inner, .difference);
    defer hollow.deinit();
    try expectShape(&hollow, 26, 12, 2);
    try expectIdentities(&a, &drill);
    try expectIdentities(&a, &inner);
}

test "boolean: boxes apart, touching along a face, touching along an edge" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var apart = try box(.{ 2, 0, 0 }, .{ 3, 1, 1 });
    defer apart.deinit();
    var two = try sound(&a, &apart, .@"union");
    defer two.deinit();
    try expectShape(&two, 2, 12, 2);
    var none = try sound(&a, &apart, .intersection);
    defer none.deinit();
    try testing.expect(none.isEmpty());
    var same = try sound(&a, &apart, .difference);
    defer same.deinit();
    try expectShape(&same, 1, 6, 1);
    // Side by side: one box, the faces on x = 1 gone, the sides on one plane merged
    var side = try box(.{ 1, 0, 0 }, .{ 2, 1, 1 });
    defer side.deinit();
    var joined = try sound(&a, &side, .@"union");
    defer joined.deinit();
    try expectShape(&joined, 2, 6, 1);
    try testing.expectEqual(@as(usize, 8), joined.counts().vertices);
    var touching = try sound(&a, &side, .intersection);
    defer touching.deinit();
    try testing.expect(touching.isEmpty());
    // Edge to edge: two solids, an edge each along the line they touch on
    var corner = try box(.{ 1, 1, 0 }, .{ 2, 2, 1 });
    defer corner.deinit();
    var pair = try sound(&a, &corner, .@"union");
    defer pair.deinit();
    try expectShape(&pair, 2, 12, 2);
    try testing.expectEqual(@as(usize, 24), pair.counts().edges);
    try expectIdentities(&a, &side);
    try expectIdentities(&a, &corner);
}

test "boolean: a box with itself, and a box flush inside another's corner" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var twin = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer twin.deinit();
    var u = try sound(&a, &twin, .@"union");
    defer u.deinit();
    try expectShape(&u, 8, 6, 1);
    var i = try sound(&a, &twin, .intersection);
    defer i.deinit();
    try expectShape(&i, 8, 6, 1);
    var d = try sound(&a, &twin, .difference);
    defer d.deinit();
    try testing.expect(d.isEmpty());
    // A pocket flush with three faces of the corner
    var pocket = try box(.{ 1, 1, 1 }, .{ 2, 2, 2 });
    defer pocket.deinit();
    var notched = try sound(&a, &pocket, .difference);
    defer notched.deinit();
    try expectShape(&notched, 7, 9, 1);
    try expectIdentities(&a, &pocket);
}

test "boolean: an empty operand answers at once; a curved one is refused naming its face" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var empty = Body.empty(testing.allocator, tol);
    empty.kind = .solid;
    defer empty.deinit();
    var u = try sound(&a, &empty, .@"union");
    defer u.deinit();
    try expectShape(&u, 1, 6, 1);
    var d = try sound(&empty, &a, .difference);
    defer d.deinit();
    try testing.expect(d.isEmpty());
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cylinder = try primitives.cylinder(testing.allocator, tol, 1, 1, false, &diag);
    defer cylinder.deinit();
    try testing.expectError(error.NotImplemented, pipeline.boolean(testing.allocator, &a, &cylinder, .@"union", .{}, &diag));
    try testing.expectEqual(diagnostics.EntityKind.face, diag.first().?.entity.kind);
}

/// `body` turned by `angle` about `axis` through `origin`.
fn turned(body: *const Body, origin: Vec3, axis: Vec3, angle: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return transform.transform(testing.allocator, body, &mat.Affine.rotateAbout(origin, vec.normalized(axis).?, angle), .{}, &diag);
}

test "boolean: tilted boxes, no plane on an axis: the identities, and a diamond's corners cut off a cube" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b0 = try box(.{ 0.5, 0.5, 0.5 }, .{ 2.5, 2.5, 2.5 });
    defer b0.deinit();
    var b = try turned(&b0, .{ 1.5, 1.5, 1.5 }, .{ 1, 2, 3 }, 0.4);
    defer b.deinit();
    try expectIdentities(&a, &b);
    try expectIdentities(&b, &a);
    // A cube turned 45° about z and about x stands on an edge through the first's centre:
    // their intersection keeps the volume of neither
    var c = try turned(&a, .{ 1, 1, 1 }, .{ 0, 0, 1 }, std.math.pi / 4.0);
    defer c.deinit();
    var d = try turned(&c, .{ 1, 1, 1 }, .{ 1, 0, 0 }, std.math.pi / 4.0);
    defer d.deinit();
    try expectIdentities(&a, &d);
    var i = try sound(&a, &d, .intersection);
    defer i.deinit();
    const vi = try volume(&i);
    try testing.expect(vi > 4 and vi < 8);
}

test "boolean: a chain, a box joined to a box and a slot cut through both, as one solid" {
    var a = try box(.{ 0, 0, 0 }, .{ 4, 2, 1 });
    defer a.deinit();
    var b = try box(.{ 3, 0, 0 }, .{ 5, 2, 3 });
    defer b.deinit();
    var joined = try sound(&a, &b, .@"union");
    defer joined.deinit();
    // An L in section: two ends, six faces around; 8 + 12 less the 2 they share
    try expectShape(&joined, 18, 8, 1);
    var slot = try box(.{ 1, 0.5, -1 }, .{ 4.5, 1.5, 4 });
    defer slot.deinit();
    var cut = try sound(&joined, &slot, .difference);
    defer cut.deinit();
    // The slot takes 3 of the low arm and 4.5 of the tower, 1 of it counted twice
    try testing.expectApproxEqAbs(18 - (3 + 4.5 - 1), try volume(&cut), CLOSE);
    try expectIdentities(&joined, &slot);
}

test "boolean: solids touching along a line, the line inside a face of one: a slit, kept as an edge" {
    // From outside: a box turned 45° about z stands on its edge against the back of
    // another, along a line from inside that face to its top (simplify once took the slit's
    // tip, a corner of the turned box, with the slit: 2026-11-12)
    var a = try box(.{ 0, 2, 0 }, .{ 3, 3, 4 });
    defer a.deinit();
    var b0 = try box(.{ 1, 3, 1 }, .{ 3, 4, 4 });
    defer b0.deinit();
    var b = try turned(&b0, .{ 1, 3, 1 }, vec.Z3, std.math.pi / 4.0);
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    // Twelve faces, the back one with the slit in it: a top edge split at its end, the slit
    // one edge per solid there
    try expectShape(&u, 12 + 6, 12, 2);
    // Each box's 12 edges, `a`'s top edge in two and the slit; the turned box's corners,
    // two of them on the slit's ends, `a`'s split vertex one of those
    try testing.expectEqual(@as(usize, 26), u.counts().edges);
    try testing.expectEqual(@as(usize, 16), u.counts().vertices);
    try expectIdentities(&a, &b);
    // A solid's edge lying in another's face, the two touching along it: the face keeps
    // the edge (merged across it, the line would lie inside the face)
    var c = try box(.{ 2, 3, 3 }, .{ 4, 4, 4 });
    defer c.deinit();
    var d0 = try box(.{ 0, 2, 3 }, .{ 3, 4, 4 });
    defer d0.deinit();
    var d = try turned(&d0, .{ 0, 2, 3 }, vec.Z3, std.math.pi / 4.0);
    defer d.deinit();
    var ud = try sound(&c, &d, .@"union");
    defer ud.deinit();
    try expectShape(&ud, 8, 6 + 7, 2);
    try expectIdentities(&c, &d);
}

test "boolean: a box touching another's face along a line from inside; the difference, pinched along it, is refused" {
    var a = try box(.{ 0, 3, 1 }, .{ 2, 4, 4 });
    defer a.deinit();
    var b0 = try box(.{ 1, 3, 2 }, .{ 4, 4, 4 });
    defer b0.deinit();
    var b = try turned(&b0, .{ 1, 3, 2 }, vec.Z3, std.math.pi / 4.0);
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    var i = try sound(&a, &b, .intersection);
    defer i.deinit();
    try testing.expectApproxEqAbs(try volume(&a) + try volume(&b), try volume(&u) + try volume(&i), CLOSE);
    // The pocket left in `a` meets its front face along the line: one shell touching
    // itself along an edge, which no shell's Euler–Poincaré count admits (the degeneracy
    // corpus's pinches, M4)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.NotValid, pipeline.boolean(testing.allocator, &a, &b, .difference, .{}, &diag));
    try testing.expectEqual(diagnostics.Code.euler_poincare, diag.first().?.code);
}
