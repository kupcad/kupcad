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
pub fn box(lo: Vec3, hi: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var unit = try primitives.box(testing.allocator, tol, hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], false, &diag);
    defer unit.deinit();
    return transform.transform(testing.allocator, &unit, &mat.Affine.translate(lo), .{}, &diag);
}

/// `a op b`, checked: every rule of the checker and the overlap rules pass it, and its
/// report fits it.
pub fn sound(a: *const Body, b: *const Body, op: Op) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var result = pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, &r) catch |e| {
        std.debug.print("boolean {s}: {f}\n", .{ @tagName(op), diag });
        return e;
    };
    errdefer result.deinit();
    try expectReportFits(&r, a, b, &result, op);
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

/// The report of a boolean that succeeded: its operation, no refusal's stage, every face
/// of the result made from some input face, every entry naming live faces, an input face
/// preserved in one result face alone, and a reversed face only from the second operand of
/// a difference.
fn expectReportFits(r: *const pipeline.Report, a: *const Body, b: *const Body, result: *const Body, op: Op) !void {
    try testing.expectEqual(op, r.op);
    try testing.expectEqual(@as(?pipeline.Stage, null), r.failed_in);
    const covered = try testing.allocator.alloc(bool, result.faces.items.len);
    defer testing.allocator.free(covered);
    @memset(covered, false);
    for (r.faces.items) |m| {
        const input = if (m.operand == 0) a else b;
        try testing.expect(m.input < input.faces.items.len and !input.faces.items[m.input].flags.tombstone);
        try testing.expect(m.result < result.faces.items.len and !result.faces.items[m.result].flags.tombstone);
        covered[m.result] = true;
        if (m.reversed) try testing.expect(op == .difference and m.operand == 1);
        if (m.role == .preserved) {
            var results: usize = 0;
            for (r.faces.items) |n| results += @intFromBool(n.operand == m.operand and n.input == m.input);
            try testing.expectEqual(@as(usize, 1), results);
        }
    }
    for (result.faces.items, covered) |f, c| if (!f.flags.tombstone) try testing.expect(c);
}

pub fn volume(body: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(body, .{}, &diag)).volume;
}

/// The result's volume, faces and shells.
pub fn expectShape(body: *const Body, want_volume: f64, faces: usize, shells: usize) !void {
    try testing.expectApproxEqAbs(want_volume, try volume(body), CLOSE);
    const counts = body.counts();
    try testing.expectEqual(faces, counts.faces);
    try testing.expectEqual(shells, counts.shells);
}

/// The volume identities: V(A ∪ B) + V(A ∩ B) = V(A) + V(B), V(A − B) = V(A) − V(A ∩ B).
pub fn expectIdentities(a: *const Body, b: *const Body) !void {
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
    try testing.expectError(error.NotImplemented, pipeline.boolean(testing.allocator, &a, &cylinder, .@"union", .{}, &diag, null));
    try testing.expectEqual(diagnostics.EntityKind.face, diag.first().?.entity.kind);
}

/// `body` moved by `by`.
pub fn moved(body: *const Body, by: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return transform.transform(testing.allocator, body, &mat.Affine.translate(by), .{}, &diag);
}

/// `body` mirrored across the plane through the origin normal to `normal`.
pub fn mirrored(body: *const Body, normal: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return transform.transform(testing.allocator, body, &mat.Affine.mirror(normal), .{}, &diag);
}

/// `body` turned by `angle` about `axis` through `origin`.
pub fn turned(body: *const Body, origin: Vec3, axis: Vec3, angle: f64) !Body {
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

test "boolean: a box touching another's face along a line from inside; the difference, pinched along it, is refused by design" {
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
    // itself along an edge, which no shell's Euler–Poincaré count admits, refused by design
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, &a, &b, .difference, .{}, &diag, null));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    try testing.expectEqual(diagnostics.EntityKind.shell, diag.first().?.entity.kind);
}

test "boolean: warnings name what they concern: faces a hair from one plane, solids touching along an edge" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    // A top five hundred-thousandths above the other's: a step that thin in the union
    var b = try box(.{ 0.5, 0.25, 0.25 }, .{ 1.5, 0.75, 1 + 5e-5 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var u = try pipeline.boolean(testing.allocator, &a, &b, .@"union", .{}, &diag, null);
    defer u.deinit();
    var near: usize = 0;
    for (diag.findings.items) |f| {
        if (f.code != .nearly_coplanar) continue;
        near += 1;
        try testing.expectEqual(diagnostics.Severity.warning, f.severity);
        try testing.expectEqual(diagnostics.EntityKind.face, f.entity.kind);
        try testing.expectApproxEqAbs(@as(f64, 5e-5), f.measured, 1e-12);
    }
    try testing.expectEqual(@as(usize, 1), near);
    // Edge to edge: one warning, naming an edge of the result
    var corner = try box(.{ 1, 1, 0 }, .{ 2, 2, 1 });
    defer corner.deinit();
    diag.clear();
    var pair = try pipeline.boolean(testing.allocator, &a, &corner, .@"union", .{}, &diag, null);
    defer pair.deinit();
    try testing.expectEqual(@as(usize, 1), diag.warnings());
    const w = diag.findings.items[0];
    try testing.expectEqual(diagnostics.Code.solids_touch, w.code);
    try testing.expectEqual(diagnostics.EntityKind.edge, w.entity.kind);
    try testing.expect(w.entity.index < pair.edges.items.len);
}

/// `a op b` with its report.
pub fn reported(a: *const Body, b: *const Body, op: Op, options: pipeline.Options, r: *pipeline.Report) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return pipeline.boolean(testing.allocator, a, b, op, options, &diag, r);
}

pub fn roleOf(r: *const pipeline.Report, operand: u32, input: u32) ?pipeline.Role {
    for (r.faces.items) |m| if (m.operand == operand and m.input == input) return m.role;
    return null;
}

/// The face of `body` facing along `normal`.
pub fn facing(body: *const Body, normal: Vec3) u32 {
    for (body.faces.items, 0..) |f, i| {
        if (f.flags.tombstone) continue;
        if (vec.dot(@import("../query/in_face.zig").outwardNormal(body, @import("../topology/types.zig").FaceIndex.of(i), .{ 0, 0 }), normal) > 0.5) return @intCast(i);
    }
    unreachable;
}

test "report: overlapping at a corner, the faces away from the other preserved, the rest split, exact, no contact" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b.deinit();
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var u = try reported(&a, &b, .@"union", .{}, &r);
    defer u.deinit();
    try testing.expectEqual(pipeline.Report.Quality.exact, r.quality());
    try testing.expect(!r.coincident);
    try testing.expectEqual(@as(usize, 0), r.contacts.items.len);
    for ([_]Vec3{ vec.X3, vec.Y3, vec.Z3 }) |n| {
        try testing.expectEqual(pipeline.Role.preserved, roleOf(&r, 0, facing(&a, vec.neg(n))).?);
        try testing.expectEqual(pipeline.Role.split, roleOf(&r, 0, facing(&a, n)).?);
        try testing.expectEqual(pipeline.Role.preserved, roleOf(&r, 1, facing(&b, n)).?);
    }
    // Every result face from one input face here: twelve entries, one per face
    try testing.expectEqual(@as(usize, 12), r.faces.items.len);
    // In a difference the second's notch faces are its faces inside the first, reversed
    var d_report = pipeline.Report.init(testing.allocator);
    defer d_report.deinit();
    var d = try reported(&a, &b, .difference, .{}, &d_report);
    defer d.deinit();
    var reversed: usize = 0;
    for (d_report.faces.items) |m| reversed += @intFromBool(m.reversed);
    try testing.expectEqual(@as(usize, 3), reversed);
}

test "report: boxes touching face to face, coincident, their contacts the shared square's corners, the tops merged" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1, 0, 0 }, .{ 2, 1, 1 });
    defer b.deinit();
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var u = try reported(&a, &b, .@"union", .{}, &r);
    defer u.deinit();
    try testing.expect(r.coincident);
    try testing.expectEqual(@as(usize, 4), r.contacts.items.len);
    for (r.contacts.items) |p| try testing.expectEqual(@as(f64, 1), p[0]);
    try testing.expectEqual(pipeline.Role.merged, roleOf(&r, 0, facing(&a, vec.Z3)).?);
    try testing.expectEqual(pipeline.Role.preserved, roleOf(&r, 0, facing(&a, vec.neg(vec.X3))).?);
    // The faces they touched by are in no face of the result
    try testing.expectEqual(@as(?pipeline.Role, null), roleOf(&r, 0, facing(&a, vec.X3)));
    try testing.expectEqual(@as(?pipeline.Role, null), roleOf(&r, 1, facing(&b, vec.neg(vec.X3))));
}

test "report: boxes touching along an edge, and at a corner a hair apart, approximate by the gap" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var edge = try box(.{ 1, 1, 0 }, .{ 2, 2, 1 });
    defer edge.deinit();
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var u = try reported(&a, &edge, .@"union", .{}, &r);
    defer u.deinit();
    try testing.expect(!r.coincident);
    try testing.expectEqual(@as(usize, 2), r.contacts.items.len);
    try testing.expectEqual(pipeline.Report.Quality.exact, r.quality());
    // A corner five millionths off the other's: one vertex at their middle
    var corner = try box(.{ 1 + 5e-6, 1, 1 }, .{ 2, 2, 2 });
    defer corner.deinit();
    var q = pipeline.Report.init(testing.allocator);
    defer q.deinit();
    var v = try reported(&a, &corner, .@"union", .{}, &q);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 1), q.contacts.items.len);
    switch (q.quality()) {
        .exact => return error.TestUnexpectedResult,
        .approximate => |gap| try testing.expectApproxEqAbs(@as(f64, 2.5e-6), gap, 1e-12),
    }
}

/// The host names at the roots of `tag` in `table`, through splits, merges and pairs.
fn rootNames(table: *const @import("../topology/tags.zig").Table, tag: @import("../topology/types.zig").Tag, out: *std.ArrayList(u32)) !void {
    const row = table.row(tag) orelse return;
    switch (row.source) {
        .named => |n| try out.append(testing.allocator, n),
        .split => |parent| try rootNames(table, parent, out),
        .merged, .pair => |parents| for (parents) |t| try rootNames(table, t, out),
    }
}

test "report: the result's faces carry their input faces' tags, split and merged under the host's operation" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 0 }, .{ 3, 3, 1 });
    defer b.deinit();
    for ([2]*Body{ &a, &b }, [2]u32{ 100, 200 }) |body, base| {
        for (body.faces.items, 0..) |*f, i| f.tag = try body.tags.named(testing.allocator, 1, base + @as(u32, @intCast(i)));
    }
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var u = try reported(&a, &b, .@"union", .{ .tag_op = 7 }, &r);
    defer u.deinit();
    var names: std.ArrayList(u32) = .empty;
    defer names.deinit(testing.allocator);
    for (r.faces.items) |m| {
        names.clearRetainingCapacity();
        try rootNames(&u.tags, u.face(@import("../topology/types.zig").FaceIndex.of(m.result)).tag, &names);
        const want: u32 = (if (m.operand == 0) @as(u32, 100) else 200) + m.input;
        try testing.expect(std.mem.indexOfScalar(u32, names.items, want) != null);
        // A row the boolean made is under its operation
        const row = u.tags.row(u.face(@import("../topology/types.zig").FaceIndex.of(m.result)).tag).?;
        if (row.source != .named) try testing.expectEqual(@as(u32, 7), row.op);
    }
    // The merged top names both tops
    names.clearRetainingCapacity();
    const top = for (r.faces.items) |m| {
        if (m.operand == 0 and m.input == facing(&a, vec.Z3)) break m.result;
    } else unreachable;
    try rootNames(&u.tags, u.face(@import("../topology/types.zig").FaceIndex.of(top)).tag, &names);
    try testing.expect(std.mem.indexOfScalar(u32, names.items, 100 + facing(&a, vec.Z3)) != null);
    try testing.expect(std.mem.indexOfScalar(u32, names.items, 200 + facing(&b, vec.Z3)) != null);
}

/// A trace sink keeping the phases' names, and the report's text.
const Sink = struct {
    var phases: [16][32]u8 = undefined;
    var lengths: [16]usize = undefined;
    var count: usize = 0;
    var report: [4096]u8 = undefined;
    var report_len: usize = 0;

    fn write(_: ?*anyopaque, _: []const u8, phase: []const u8, text: []const u8) void {
        if (count < phases.len) {
            const n = @min(phase.len, 32);
            @memcpy(phases[count][0..n], phase[0..n]);
            lengths[count] = n;
            count += 1;
        }
        if (std.mem.eql(u8, phase, "report")) {
            report_len = @min(text.len, report.len);
            @memcpy(report[0..report_len], text[0..report_len]);
        }
    }

    fn has(phase: []const u8) bool {
        for (0..count) |i| if (std.mem.eql(u8, phases[i][0..lengths[i]], phase)) return true;
        return false;
    }
};

test "report: the trace gets it beside the phases; a refusal's names the stage it failed in" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b.deinit();
    Sink.count = 0;
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var u = try reported(&a, &b, .@"union", .{ .common = .{ .trace = .{ .write = Sink.write } } }, &r);
    defer u.deinit();
    for ([_][]const u8{ "arguments", "assembled", "simplified", "report" }) |phase| try testing.expect(Sink.has(phase));
    try testing.expect(std.mem.indexOf(u8, Sink.report[0..Sink.report_len], "\"quality\": \"exact\"") != null);
    // A slab too thin to split where the other's face crosses it: refused in edge–face,
    // which the report and the trace's report say
    const xsect = tol.xsect;
    var slab = try box(.{ 0, 0, 0 }, .{ 1, 1, 3 * xsect });
    defer slab.deinit();
    var cut = try box(.{ 0.25, 0.25, 1.5 * xsect }, .{ 2, 2, 1 });
    defer cut.deinit();
    Sink.count = 0;
    var refused = pipeline.Report.init(testing.allocator);
    defer refused.deinit();
    try testing.expectError(error.TooSmallEdge, reported(&slab, &cut, .difference, .{ .common = .{ .trace = .{ .write = Sink.write } } }, &refused));
    try testing.expectEqual(@as(?pipeline.Stage, .edge_face), refused.failed_in);
    try testing.expect(std.mem.indexOf(u8, Sink.report[0..Sink.report_len], "\"failed_in\": \"edge_face\"") != null);
    // A curved operand, refused before any interference
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cylinder = try primitives.cylinder(testing.allocator, tol, 1, 1, false, &diag);
    defer cylinder.deinit();
    var curved = pipeline.Report.init(testing.allocator);
    defer curved.deinit();
    try testing.expectError(error.NotImplemented, reported(&a, &cylinder, .@"union", .{}, &curved));
    try testing.expectEqual(@as(?pipeline.Stage, .operands), curved.failed_in);
}

/// The shells' kinds of `body`: outer shells and voids.
pub fn shellKinds(body: *const Body) [2]usize {
    var kinds = [2]usize{ 0, 0 };
    for (body.shells.items) |s| {
        if (s.tombstone) continue;
        kinds[@intFromBool(s.kind == .void)] += 1;
    }
    return kinds;
}

test "containment: operands that meet nowhere are answered by the table as the general path answers them" {
    var outer = try box(.{ 0, 0, 0 }, .{ 6, 6, 6 });
    defer outer.deinit();
    var inner = try box(.{ 2, 2, 2 }, .{ 3, 3, 3 });
    defer inner.deinit();
    var away = try box(.{ 10, 0, 0 }, .{ 11, 1, 1 });
    defer away.deinit();
    var cavity = try box(.{ 1, 1, 1 }, .{ 5, 5, 5 });
    defer cavity.deinit();
    var hollow = try sound(&outer, &cavity, .difference);
    defer hollow.deinit();
    var twins = try sound(&inner, &away, .@"union");
    defer twins.deinit();
    // A box inside, a box around, apart, a box in a hollow's cavity, a two-shell operand
    // one of whose shells is inside a box
    const pairs = [_][2]*const Body{ .{ &outer, &inner }, .{ &inner, &outer }, .{ &inner, &away }, .{ &hollow, &inner }, .{ &inner, &hollow }, .{ &twins, &outer }, .{ &outer, &twins } };
    for (pairs) |pair| for ([_]Op{ .@"union", .difference, .intersection }) |op| {
        var fast = pipeline.Report.init(testing.allocator);
        defer fast.deinit();
        var by_table = try reported(pair[0], pair[1], op, .{}, &fast);
        defer by_table.deinit();
        var slow = pipeline.Report.init(testing.allocator);
        defer slow.deinit();
        var by_path = try reported(pair[0], pair[1], op, .{ .fast_paths = false }, &slow);
        defer by_path.deinit();
        errdefer std.debug.print("{s}: table {d} faces, {d} shells; path {d} faces, {d} shells\n", .{ @tagName(op), by_table.counts().faces, by_table.counts().shells, by_path.counts().faces, by_path.counts().shells });
        try testing.expect(fast.by_containment);
        try testing.expect(!slow.by_containment);
        try testing.expectApproxEqAbs(try volume(&by_path), try volume(&by_table), CLOSE);
        try testing.expectEqual(by_path.counts(), by_table.counts());
        try testing.expectEqual(shellKinds(&by_path), shellKinds(&by_table));
        try testing.expectEqualSlices(pipeline.FaceMap, slow.faces.items, fast.faces.items);
    };
    // The answers themselves: a box in a cavity stays, a void in a void is none
    var floating = try sound(&hollow, &inner, .@"union");
    defer floating.deinit();
    try testing.expectEqual([2]usize{ 2, 1 }, shellKinds(&floating));
    try testing.expectApproxEqAbs(@as(f64, 216 - 64 + 1), try volume(&floating), CLOSE);
    var pocket = try sound(&outer, &inner, .difference);
    defer pocket.deinit();
    try testing.expectEqual([2]usize{ 1, 1 }, shellKinds(&pocket));
    var none = try sound(&hollow, &inner, .intersection);
    defer none.deinit();
    try testing.expect(none.isEmpty());
}

test "boolean: operands with several shells and voids: a cavity filled, two solids joined, a wall cut" {
    var outer = try box(.{ 0, 0, 0 }, .{ 4, 4, 4 });
    defer outer.deinit();
    var cavity = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer cavity.deinit();
    var hollow = try sound(&outer, &cavity, .difference);
    defer hollow.deinit();
    // The cavity filled exactly: the void's faces and the filler's touch, both go
    var filled = try sound(&hollow, &cavity, .@"union");
    defer filled.deinit();
    try expectShape(&filled, 64, 6, 1);
    try expectIdentities(&hollow, &cavity);
    // Two boxes apart joined by a bar: one solid
    var left = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer left.deinit();
    var right = try box(.{ 3, 0, 0 }, .{ 4, 1, 1 });
    defer right.deinit();
    var pair = try sound(&left, &right, .@"union");
    defer pair.deinit();
    var bar = try box(.{ 0.5, 0.25, 0.25 }, .{ 3.5, 0.75, 0.75 });
    defer bar.deinit();
    var joined = try sound(&pair, &bar, .@"union");
    defer joined.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&joined));
    try testing.expectApproxEqAbs(@as(f64, 2 + 2 * 0.25), try volume(&joined), CLOSE);
    try expectIdentities(&pair, &bar);
    // A box through the hollow's wall into its cavity
    var through = try box(.{ 2, 2, 2 }, .{ 5, 3, 3 });
    defer through.deinit();
    try expectIdentities(&hollow, &through);
    var part = try sound(&hollow, &through, .intersection);
    defer part.deinit();
    // The wall's thickness of it: from x = 3 to 4
    try testing.expectApproxEqAbs(@as(f64, 1), try volume(&part), CLOSE);
}

test "chain: unions, differences and intersections folded from the left, the report followed through the steps" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1, 0, 0 }, .{ 3, 1, 1 });
    defer b.deinit();
    var c = try box(.{ 2, 0, 0 }, .{ 4, 1, 1 });
    defer c.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var row = try pipeline.chain(testing.allocator, &.{ &a, &b, &c }, .@"union", .{}, &diag, &r);
    defer row.deinit();
    // One bar, four long: six faces, each from faces of the operands
    try expectShape(&row, 4, 6, 1);
    // The first's bottom merged with the others' into the bar's; its far end kept whole
    try testing.expectEqual(pipeline.Role.merged, roleOf(&r, 0, facing(&a, vec.neg(vec.Z3))).?);
    try testing.expectEqual(pipeline.Role.preserved, roleOf(&r, 0, facing(&a, vec.neg(vec.X3))).?);
    try testing.expectEqual(pipeline.Role.preserved, roleOf(&r, 2, facing(&c, vec.X3)).?);
    for (r.faces.items) |m| try testing.expect(m.operand <= 2 and m.result < row.faces.items.len);
    // Two holes drilled through a slab
    var slab = try box(.{ 0, 0, 0 }, .{ 5, 2, 1 });
    defer slab.deinit();
    var drill1 = try box(.{ 1, 0.5, -1 }, .{ 2, 1.5, 2 });
    defer drill1.deinit();
    var drill2 = try box(.{ 3, 0.5, -1 }, .{ 4, 1.5, 2 });
    defer drill2.deinit();
    var holes = pipeline.Report.init(testing.allocator);
    defer holes.deinit();
    var drilled = try pipeline.chain(testing.allocator, &.{ &slab, &drill1, &drill2 }, .difference, .{}, &diag, &holes);
    defer drilled.deinit();
    try expectShape(&drilled, 10 - 2, 6 + 8, 1);
    var reversed: usize = 0;
    for (holes.faces.items) |m| {
        if (m.reversed) {
            reversed += 1;
            try testing.expect(m.operand == 1 or m.operand == 2);
        }
    }
    try testing.expectEqual(@as(usize, 8), reversed);
    // What all three hold: the middle unit
    var common = try pipeline.chain(testing.allocator, &.{ &a, &b, &c }, .intersection, .{}, &diag, null);
    defer common.deinit();
    try testing.expect(common.isEmpty());
    var middle = try pipeline.chain(testing.allocator, &.{ &a, &b }, .intersection, .{}, &diag, null);
    defer middle.deinit();
    try expectShape(&middle, 1, 6, 1);
    // One operand: its copy
    var alone = try pipeline.chain(testing.allocator, &.{&a}, .difference, .{}, &diag, null);
    defer alone.deinit();
    try expectShape(&alone, 2, 6, 1);
}

test "chain: an empty step goes on; a refusal names its step and stage" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 2, 0, 0 }, .{ 3, 1, 1 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // Nothing left after the first step, the next union gives the third back
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var gone = try pipeline.chain(testing.allocator, &.{ &a, &a, &b }, .difference, .{}, &diag, &r);
    defer gone.deinit();
    try testing.expect(gone.isEmpty());
    var back = try pipeline.chain(testing.allocator, &.{ &a, &b, &b }, .intersection, .{}, &diag, null);
    defer back.deinit();
    try testing.expect(back.isEmpty());
    // A slab too thin to split, cut in the second step
    const xsect = tol.xsect;
    var slab = try box(.{ 0, 0, 0 }, .{ 1, 1, 3 * xsect });
    defer slab.deinit();
    var big = try box(.{ -1, -1, -1 }, .{ 2, 2, 2 });
    defer big.deinit();
    var cut = try box(.{ 0.25, 0.25, 1.5 * xsect }, .{ 2, 2, 1 });
    defer cut.deinit();
    var failed = pipeline.Report.init(testing.allocator);
    defer failed.deinit();
    try testing.expectError(error.TooSmallEdge, pipeline.chain(testing.allocator, &.{ &slab, &big, &cut }, .intersection, .{}, &diag, &failed));
    try testing.expectEqual(@as(?u32, 2), failed.failed_step);
    try testing.expectEqual(@as(?pipeline.Stage, .edge_face), failed.failed_in);
}
