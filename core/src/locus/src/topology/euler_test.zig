const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const types = @import("types.zig");
const Body = @import("body.zig").Body;
const traverse = @import("traverse.zig");
const euler = @import("euler.zig");
const check = @import("check.zig");
const Vec3 = vec.Vec3;
const CoedgeIndex = types.CoedgeIndex;
const VertexIndex = types.VertexIndex;

const tol = Tolerance.fromZone(1e-5);

/// The unit cube's points, lines and planes in a body's geometry, for the Euler sequences.
const Kit = struct {
    body: Body,
    points: [8]geometry.PointIndex,
    planes: [6]geometry.SurfaceRef,

    const corners = [8]Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } };
    /// bottom, top, front (y = 0), right (x = 1), back (y = 1), left (x = 0)
    const plane_frames = [6]geometry.Frame{
        geometry.Frame.init(.{ 0, 0, 0 }, vec.Y3, vec.neg(vec.Z3)),
        geometry.Frame.init(.{ 0, 0, 1 }, vec.X3, vec.Z3),
        geometry.Frame.init(.{ 0, 0, 0 }, vec.X3, vec.neg(vec.Y3)),
        geometry.Frame.init(.{ 1, 0, 0 }, vec.Y3, vec.X3),
        geometry.Frame.init(.{ 0, 1, 0 }, vec.neg(vec.X3), vec.Y3),
        geometry.Frame.init(.{ 0, 0, 0 }, vec.neg(vec.Y3), vec.neg(vec.X3)),
    };
    const BOTTOM = 0;
    const TOP = 1;
    const FRONT = 2;
    const RIGHT = 3;
    const BACK = 4;
    const LEFT = 5;

    fn init(allocator: std.mem.Allocator) !Kit {
        var kit: Kit = .{ .body = Body.init(allocator, tol), .points = undefined, .planes = undefined };
        errdefer kit.body.deinit();
        for (corners, 0..) |p, i| kit.points[i] = try kit.body.geometry.addPoint(allocator, p);
        for (plane_frames, 0..) |f, i| kit.planes[i] = try kit.body.geometry.addPlane(allocator, .{ .frame = f });
        return kit;
    }

    fn deinit(self: *Kit) void {
        self.body.deinit();
    }

    /// The edge geometry from corner `i` to corner `j`: the line through them, `t` from 0
    /// to their distance.
    fn line(self: *Kit, i: usize, j: usize) !euler.EdgeGeometry {
        const l = curves.Line.through(corners[i], corners[j]).?;
        const ref = try self.body.geometry.addLine(self.body.allocator, l);
        return .{ .curve = ref, .t0 = 0, .t1 = vec.distance(corners[i], corners[j]) };
    }

    /// The vertex index of corner `i` (vertices are made in the order the sequence makes
    /// them, so the kit finds them by point).
    fn vertexAt(self: *const Kit, i: usize) VertexIndex {
        for (self.body.vertices.items, 0..) |v, k| {
            if (!v.tombstone and v.point == self.points[i]) return VertexIndex.of(k);
        }
        unreachable;
    }

    /// The coedge of `loop` that starts at corner `i`.
    fn startingIn(self: *const Kit, loop: types.LoopIndex, i: usize) !CoedgeIndex {
        const v = self.vertexAt(i);
        var it = traverse.Coedges.init(&self.body, loop);
        while (try it.next()) |c| if (self.body.coedgeStart(c) == v) return c;
        unreachable;
    }

    /// The coedge of `loop` that ends at corner `i`.
    fn endingIn(self: *const Kit, loop: types.LoopIndex, i: usize) !CoedgeIndex {
        const v = self.vertexAt(i);
        var it = traverse.Coedges.init(&self.body, loop);
        while (try it.next()) |c| if (self.body.coedgeEnd(c) == v) return c;
        unreachable;
    }

    /// The live coedge leaving corner `a` towards corner `b`.
    fn coedgeFromTo(self: *const Kit, a: usize, b: usize) CoedgeIndex {
        const va = self.vertexAt(a);
        const vb = self.vertexAt(b);
        for (self.body.coedges.items, 0..) |c, k| {
            if (c.tombstone) continue;
            const idx = CoedgeIndex.of(k);
            if (self.body.coedgeStart(idx) == va and self.body.coedgeEnd(idx) == vb) return idx;
        }
        unreachable;
    }
};

/// The faces of a body as their loops' corner sequences, canonically rotated and sorted:
/// two bodies with equal signatures are the same cube whatever the indices.
const Signature = struct {
    faces: std.ArrayList([]u8),

    fn of(allocator: std.mem.Allocator, body: *const Body) !Signature {
        var sig = Signature{ .faces = .empty };
        errdefer sig.deinit(allocator);
        var shells = traverse.Shells.init(body);
        while (try shells.next()) |s| {
            var faces = traverse.Faces.init(body, s);
            while (try faces.next()) |f| {
                var text: std.ArrayList(u8) = .empty;
                errdefer text.deinit(allocator);
                var loops = traverse.Loops.init(body, f);
                while (try loops.next()) |l| {
                    // The cycle of corner numbers, rotated to start at its least
                    var cycle: std.ArrayList(u8) = .empty;
                    defer cycle.deinit(allocator);
                    var it = traverse.Coedges.init(body, l);
                    while (try it.next()) |c| {
                        try cycle.append(allocator, @intCast(@backingInt(body.vertex(body.coedgeStart(c)).point)));
                    }
                    if (cycle.items.len > 0) std.mem.rotate(u8, cycle.items, std.mem.indexOfMin(u8, cycle.items));
                    try text.append(allocator, '[');
                    for (cycle.items) |k| try text.print(allocator, "{d} ", .{k});
                    try text.append(allocator, ']');
                }
                try sig.faces.append(allocator, try text.toOwnedSlice(allocator));
            }
        }
        std.mem.sort([]u8, sig.faces.items, {}, lessThan);
        return sig;
    }

    fn lessThan(_: void, a: []u8, b: []u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn deinit(self: *Signature, allocator: std.mem.Allocator) void {
        for (self.faces.items) |f| allocator.free(f);
        self.faces.deinit(allocator);
    }

    fn eql(a: *const Signature, b: *const Signature) bool {
        if (a.faces.items.len != b.faces.items.len) return false;
        for (a.faces.items, b.faces.items) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }
};

fn expectValid(body: *const Body, level: check.Level) !void {
    var report = try check.run(testing.allocator, body, level);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try f.format(&w);
        std.debug.print("checker: {s}\n", .{w.buffered()});
    }
    try testing.expect(report.ok());
}

fn expectCounts(body: *const Body, v: usize, e: usize, f: usize, l: usize, s: usize) !void {
    const c = body.counts();
    try testing.expectEqual(v, c.vertices);
    try testing.expectEqual(e, c.edges);
    try testing.expectEqual(f, c.faces);
    try testing.expectEqual(l, c.loops);
    try testing.expectEqual(s, c.shells);
    try testing.expectEqual(2 * e - countOpen(body), c.coedges);
}

fn countOpen(body: *const Body) usize {
    var n: usize = 0;
    for (body.coedges.items) |c| {
        if (!c.tombstone and c.partner == .none) n += 1;
    }
    return n;
}

/// The lamina of the bottom square: a vertex, three spurs, and the closing mef, leaving the
/// bottom face and a face on `other` sharing its four edges. The vertices come in the
/// order of `order`'s corners.
fn lamina(kit: *Kit, order: [4]usize, bottom: usize, other: usize) !void {
    const b = &kit.body;
    const start = try euler.mvfs(b, kit.points[order[0]], kit.planes[bottom], true, .outer);
    var after: CoedgeIndex = .none;
    var from = start.vertex;
    var i: usize = 1;
    while (i < 4) : (i += 1) {
        const r = try euler.mevSpur(b, start.loop, after, from, kit.points[order[i]], try kit.line(order[i - 1], order[i]));
        after = r.out;
        from = r.vertex;
    }
    // Close: from the first vertex's coedge to the last vertex's back coedge
    const a = kit.coedgeFromTo(order[0], order[1]);
    const c = kit.coedgeFromTo(order[3], order[2]);
    _ = try euler.mef(b, a, c, try kit.line(order[0], order[3]), kit.planes[other], true);
}

/// The cube by sweeping a lamina: spurs up from the base's corners (in `up_order`), then a
/// mef per side (in `side_order`), the last closing the top.
fn sweptCube(allocator: std.mem.Allocator, base: [4]usize, lift: [4]usize, up_order: [4]usize, side_order: [4]usize, bottom: usize, top: usize, sides: [4]usize) !Kit {
    var kit = try Kit.init(allocator);
    errdefer kit.deinit();
    const b = &kit.body;
    try lamina(&kit, base, bottom, top);
    const top_loop = b.face(topFace(b, kit.planes[top])).first_loop;
    // Spurs up, each in the top face's loop after the coedge that ends at its corner
    for (up_order) |k| {
        const after = try kit.endingIn(top_loop, base[k]);
        _ = try euler.mevSpur(b, top_loop, after, kit.vertexAt(base[k]), kit.points[lift[k]], try kit.line(base[k], lift[k]));
    }
    // Sides: an edge between the lifted corners of each side, from the top loop's coedges
    // starting there; the old loop stays the top's
    for (side_order) |k| {
        const c0 = lift[k];
        const c1 = lift[(k + 1) % 4];
        const a = try kit.startingIn(top_loop, c0);
        const c = try kit.startingIn(top_loop, c1);
        _ = try euler.mef(b, a, c, try kit.line(c0, c1), kit.planes[sides[k]], true);
    }
    return kit;
}

fn topFace(body: *const Body, plane: geometry.SurfaceRef) types.FaceIndex {
    for (body.faces.items, 0..) |f, i| {
        if (!f.flags.tombstone and f.surface.eql(plane)) return types.FaceIndex.of(i);
    }
    unreachable;
}

test "the cube built five ways is the same cube: counts, the checker, and the faces' corner cycles" {
    const allocator = testing.allocator;
    // 1. Mäntylä's: the bottom square 0 1 2 3, swept up to 4 5 6 7
    var one = try sweptCube(allocator, .{ 0, 1, 2, 3 }, .{ 4, 5, 6, 7 }, .{ 0, 1, 2, 3 }, .{ 0, 1, 2, 3 }, Kit.BOTTOM, Kit.TOP, .{ Kit.FRONT, Kit.RIGHT, Kit.BACK, Kit.LEFT });
    defer one.deinit();
    // 2. From the top down
    var two = try sweptCube(allocator, .{ 4, 7, 6, 5 }, .{ 0, 3, 2, 1 }, .{ 0, 1, 2, 3 }, .{ 0, 1, 2, 3 }, Kit.TOP, Kit.BOTTOM, .{ Kit.LEFT, Kit.BACK, Kit.RIGHT, Kit.FRONT });
    defer two.deinit();
    // 3. The spurs and sides in another order
    var three = try sweptCube(allocator, .{ 0, 1, 2, 3 }, .{ 4, 5, 6, 7 }, .{ 3, 1, 0, 2 }, .{ 2, 0, 3, 1 }, Kit.BOTTOM, Kit.TOP, .{ Kit.FRONT, Kit.RIGHT, Kit.BACK, Kit.LEFT });
    defer three.deinit();
    // 4. Swept sideways: the front square, lifted along y
    var four = try sweptCube(allocator, .{ 0, 4, 5, 1 }, .{ 3, 7, 6, 2 }, .{ 0, 1, 2, 3 }, .{ 0, 1, 2, 3 }, Kit.FRONT, Kit.BACK, .{ Kit.LEFT, Kit.TOP, Kit.RIGHT, Kit.BOTTOM });
    defer four.deinit();
    // 5. Face by face: the front face first, then each neighbour grown from it
    var five = try faceByFaceCube(allocator);
    defer five.deinit();

    const kits = [_]*Kit{ &one, &two, &three, &four, &five };
    var first_sig: ?Signature = null;
    defer if (first_sig) |*s| s.deinit(allocator);
    for (kits) |kit| {
        try expectCounts(&kit.body, 8, 12, 6, 6, 1);
        try expectValid(&kit.body, .geometric);
        var sig = try Signature.of(allocator, &kit.body);
        if (first_sig) |*s| {
            defer sig.deinit(allocator);
            errdefer {
                for (s.faces.items) |f| std.debug.print("first: {s}\n", .{f});
                for (sig.faces.items) |f| std.debug.print("this:  {s}\n", .{f});
            }
            try testing.expect(s.eql(&sig));
        } else {
            first_sig = sig;
        }
    }
    try testing.expectEqual(@as(usize, 6), first_sig.?.faces.items.len);
}

/// The cube one face at a time: the front square as a lamina with the "rest" face, then
/// the rest face split by mef into right, back, left, bottom and top.
fn faceByFaceCube(allocator: std.mem.Allocator) !Kit {
    var kit = try Kit.init(allocator);
    errdefer kit.deinit();
    const b = &kit.body;
    // The front square (clockwise from outside, as the swept cubes' bases) with the "rest"
    // face on the top's plane: the rest loop runs 1 5 4 0 and every other face is cut from
    // it by mef, whose new face takes the loop from `b` around to `a`'s predecessor; the
    // last cut leaves the top
    try lamina(&kit, .{ 0, 4, 5, 1 }, Kit.FRONT, Kit.TOP);
    const rest = b.face(topFace(b, kit.planes[Kit.TOP])).first_loop;
    // Right face 2 1 5 6: spurs 1 → 2 and 5 → 6, then the edge 6 → 2
    _ = try euler.mevSpur(b, rest, try kit.endingIn(rest, 1), kit.vertexAt(1), kit.points[2], try kit.line(1, 2));
    _ = try euler.mevSpur(b, rest, try kit.endingIn(rest, 5), kit.vertexAt(5), kit.points[6], try kit.line(5, 6));
    _ = try euler.mef(b, try kit.startingIn(rest, 6), try kit.startingIn(rest, 2), try kit.line(6, 2), kit.planes[Kit.RIGHT], true);
    // Back face 3 2 6 7: spurs 2 → 3 and 6 → 7, then 7 → 3
    _ = try euler.mevSpur(b, rest, try kit.endingIn(rest, 2), kit.vertexAt(2), kit.points[3], try kit.line(2, 3));
    _ = try euler.mevSpur(b, rest, try kit.endingIn(rest, 6), kit.vertexAt(6), kit.points[7], try kit.line(6, 7));
    _ = try euler.mef(b, try kit.startingIn(rest, 7), try kit.startingIn(rest, 3), try kit.line(7, 3), kit.planes[Kit.BACK], true);
    // Bottom 0 1 2 3: the edge 3 → 0; left 4 0 3 7: the edge 7 → 4; the rest is the top
    _ = try euler.mef(b, try kit.startingIn(rest, 3), try kit.startingIn(rest, 0), try kit.line(3, 0), kit.planes[Kit.BOTTOM], true);
    _ = try euler.mef(b, try kit.startingIn(rest, 7), try kit.startingIn(rest, 4), try kit.line(7, 4), kit.planes[Kit.LEFT], true);
    return kit;
}

test "mvfs and kvfs: a shell of one face, one loop, one vertex; and back to nothing" {
    var kit = try Kit.init(testing.allocator);
    defer kit.deinit();
    const r = try euler.mvfs(&kit.body, kit.points[0], kit.planes[Kit.BOTTOM], true, .outer);
    try expectCounts(&kit.body, 1, 0, 1, 1, 1);
    try expectValid(&kit.body, .geometric);
    try testing.expectEqual(r.vertex, kit.body.loop(r.loop).vertex);
    try euler.kvfs(&kit.body, r.shell);
    try expectCounts(&kit.body, 0, 0, 0, 0, 0);
    try testing.expect(kit.body.isEmpty());
    var remap = try kit.body.compact();
    defer remap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), kit.body.vertices.items.len);
}

test "mevSpur and kevSpur: a spur grows from a vertex loop and from a loop's coedge, and goes again" {
    var kit = try Kit.init(testing.allocator);
    defer kit.deinit();
    const b = &kit.body;
    const start = try euler.mvfs(b, kit.points[0], kit.planes[Kit.BOTTOM], true, .outer);
    const spur = try euler.mevSpur(b, start.loop, .none, start.vertex, kit.points[1], try kit.line(0, 1));
    try expectCounts(b, 2, 1, 1, 1, 1);
    try testing.expectEqual(spur.back, b.coedge(spur.out).next);
    try testing.expectEqual(spur.out, b.coedge(spur.back).next);
    const second = try euler.mevSpur(b, start.loop, spur.out, spur.vertex, kit.points[2], try kit.line(1, 2));
    try expectCounts(b, 3, 2, 1, 1, 1);
    try testing.expectEqual(@as(usize, 4), try traverse.loopLength(b, start.loop));
    try expectValid(b, .geometric);
    // The wrong anchor is refused and changes nothing
    try testing.expectError(error.Invalid, euler.mevSpur(b, start.loop, spur.out, start.vertex, kit.points[3], try kit.line(0, 3)));
    try euler.kevSpur(b, second.out);
    try expectCounts(b, 2, 1, 1, 1, 1);
    try euler.kevSpur(b, spur.out);
    try expectCounts(b, 1, 0, 1, 1, 1);
    try testing.expectEqual(start.vertex, b.loop(start.loop).vertex);
    try testing.expectEqual(CoedgeIndex.none, b.loop(start.loop).first);
    try expectValid(b, .geometric);
}

test "mef and kef: a loop splits into two faces and merges back; the signature is unchanged" {
    var kit = try Kit.init(testing.allocator);
    defer kit.deinit();
    const b = &kit.body;
    try lamina(&kit, .{ 0, 1, 2, 3 }, Kit.BOTTOM, Kit.TOP);
    try expectCounts(b, 4, 4, 2, 2, 1);
    try expectValid(b, .structural);
    var before = try Signature.of(testing.allocator, b);
    defer before.deinit(testing.allocator);
    // A diagonal across the bottom: two triangles
    const r = try euler.mef(b, kit.coedgeFromTo(0, 1), kit.coedgeFromTo(2, 3), try kit.line(0, 2), kit.planes[Kit.BOTTOM], true);
    try expectCounts(b, 4, 5, 3, 3, 1);
    try expectValid(b, .structural);
    try testing.expectEqual(@as(usize, 3), try traverse.loopLength(b, r.loop));
    try testing.expectEqual(@as(usize, 3), try traverse.loopLength(b, b.coedge(r.in_old).loop));
    try euler.kef(b, r.in_new);
    try expectCounts(b, 4, 4, 2, 2, 1);
    try expectValid(b, .structural);
    var after = try Signature.of(testing.allocator, b);
    defer after.deinit(testing.allocator);
    try testing.expect(before.eql(&after));
    // mef with the two coedges in different loops is refused
    try testing.expectError(error.Invalid, euler.mef(b, kit.coedgeFromTo(0, 1), kit.coedgeFromTo(1, 0), try kit.line(0, 1), kit.planes[Kit.BOTTOM], true));
}

test "mevSplitEdge and kevJoin: an edge splits at a parameter and joins again" {
    var kit = try Kit.init(testing.allocator);
    defer kit.deinit();
    const b = &kit.body;
    try lamina(&kit, .{ 0, 1, 2, 3 }, Kit.BOTTOM, Kit.TOP);
    var before = try Signature.of(testing.allocator, b);
    defer before.deinit(testing.allocator);
    const mid = try b.geometry.addPoint(testing.allocator, .{ 0.5, 0, 0 });
    const c = kit.coedgeFromTo(0, 1);
    const r = try euler.mevSplitEdge(b, c, 0.5, mid);
    try expectCounts(b, 5, 5, 2, 2, 1);
    try expectValid(b, .structural);
    try testing.expectEqual(@as(f64, 0.5), b.edge(b.coedge(c).edge).t1);
    try testing.expectEqual(@as(f64, 0.5), b.edge(r.edge).t0);
    try testing.expectEqual(@as(f64, 1), b.edge(r.edge).t1);
    try testing.expectEqual(r.forward, b.coedge(c).next);
    try testing.expectEqual(r.backward, b.coedge(b.coedge(c).partner).prev);
    // Splitting through the reverse coedge is the same split
    try testing.expectError(error.Invalid, euler.mevSplitEdge(b, c, 0.7, mid));
    try euler.kevJoin(b, c);
    try expectCounts(b, 4, 4, 2, 2, 1);
    try expectValid(b, .structural);
    var after = try Signature.of(testing.allocator, b);
    defer after.deinit(testing.allocator);
    try testing.expect(before.eql(&after));
}

test "mevSplitVertex and kevMerge: a vertex's fan moves to a new vertex and merges back" {
    var kit = try sweptCube(testing.allocator, .{ 0, 1, 2, 3 }, .{ 4, 5, 6, 7 }, .{ 0, 1, 2, 3 }, .{ 0, 1, 2, 3 }, Kit.BOTTOM, Kit.TOP, .{ Kit.FRONT, Kit.RIGHT, Kit.BACK, Kit.LEFT });
    defer kit.deinit();
    const b = &kit.body;
    var before = try Signature.of(testing.allocator, b);
    defer before.deinit(testing.allocator);
    // At corner 0 three edges meet (to 1, 3, 4); move the one to 4 onto a new vertex at
    // the same point, with a zero-length edge between (the geometry of a chamfer's start)
    const a = kit.coedgeFromTo(0, 4);
    var it = traverse.Umbrella.initFrom(b, a);
    _ = try it.next();
    const next_around = (try it.next()).?;
    // (the edge's geometry is a stand-in: the structural rules are what this tests)
    const r = try euler.mevSplitVertex(b, a, next_around, kit.points[0], try kit.line(0, 4));
    try expectCounts(b, 9, 13, 6, 6, 1);
    try expectValid(b, .structural);
    try testing.expectEqual(r.vertex, b.coedgeStart(a));
    try euler.kevMerge(b, r.out);
    try expectCounts(b, 8, 12, 6, 6, 1);
    try expectValid(b, .geometric);
    var after = try Signature.of(testing.allocator, b);
    defer after.deinit(testing.allocator);
    try testing.expect(before.eql(&after));
}

test "kemr and mekr: a bridge edge goes leaving a ring, and comes back joining it" {
    var kit = try Kit.init(testing.allocator);
    defer kit.deinit();
    const b = &kit.body;
    // A square lamina whose bottom face gets an inner square through a bridge: build the
    // inner square as spurs from corner 0 inside the bottom loop
    try lamina(&kit, .{ 0, 1, 2, 3 }, Kit.BOTTOM, Kit.TOP);
    const inner = [4]Vec3{ .{ 0.25, 0.25, 0 }, .{ 0.75, 0.25, 0 }, .{ 0.75, 0.75, 0 }, .{ 0.25, 0.75, 0 } };
    var ip: [4]geometry.PointIndex = undefined;
    for (inner, 0..) |p, i| ip[i] = try b.geometry.addPoint(testing.allocator, p);
    const bottom_loop = b.coedge(kit.coedgeFromTo(0, 1)).loop;
    const bridge_line = try b.geometry.addLine(testing.allocator, curves.Line.through(Kit.corners[0], inner[0]).?);
    const bridge = try euler.mevSpur(b, bottom_loop, kit.coedgeFromTo(3, 0), kit.vertexAt(0), ip[0], .{ .curve = bridge_line, .t0 = 0, .t1 = vec.distance(Kit.corners[0], inner[0]) });
    var from = bridge.vertex;
    var after = bridge.out;
    var i: usize = 1;
    while (i < 4) : (i += 1) {
        const l = try b.geometry.addLine(testing.allocator, curves.Line.through(inner[i - 1], inner[i]).?);
        const r = try euler.mevSpur(b, bottom_loop, after, from, ip[i], .{ .curve = l, .t0 = 0, .t1 = vec.distance(inner[i - 1], inner[i]) });
        from = r.vertex;
        after = r.out;
    }
    // Close the inner square with mef... which would make a face; instead make the inner
    // loop with mef then kemr the bridge: mef from inner 0 to inner 3
    const l03 = try b.geometry.addLine(testing.allocator, curves.Line.through(inner[0], inner[3]).?);
    const c_in0_in1 = b.coedge(bridge.out).next;
    const c_in3_in2 = b.coedge(after).partner;
    const closing = try euler.mef(b, c_in0_in1, c_in3_in2, .{ .curve = l03, .t0 = 0, .t1 = 0.5 }, kit.planes[Kit.BOTTOM], true);
    try expectCounts(b, 8, 9, 3, 3, 1);
    try expectValid(b, .structural);
    var before = try Signature.of(testing.allocator, b);
    defer before.deinit(testing.allocator);
    // mef gave the new face the loop from b around to a's predecessor: the outer square
    // with the bridge twice; the old loop kept the inner square
    try testing.expectEqual(@as(usize, 4), try traverse.loopLength(b, bottom_loop));
    const big = b.coedge(bridge.out).loop;
    try testing.expectEqual(closing.loop, big);
    try testing.expectEqual(@as(usize, 10), try traverse.loopLength(b, big));
    // The bridge is used twice by that loop: kill it, leaving two loops of the face
    const ring = try euler.kemr(b, bridge.out);
    try expectCounts(b, 8, 8, 3, 4, 1);
    try expectValid(b, .structural);
    try testing.expectEqual(@as(usize, 4), try traverse.loopLength(b, ring));
    try testing.expectEqual(@as(usize, 4), try traverse.loopLength(b, big));
    try testing.expectEqual(b.loop(big).face, b.loop(ring).face);
    // And back: an edge from corner 0 to inner 0 joins the two loops again
    _ = try euler.mekr(b, kit.coedgeFromTo(0, 1), b.loop(big).first, .{ .curve = bridge_line, .t0 = 0, .t1 = vec.distance(Kit.corners[0], inner[0]) });
    try expectCounts(b, 8, 9, 3, 3, 1);
    try expectValid(b, .structural);
    var after_sig = try Signature.of(testing.allocator, b);
    defer after_sig.deinit(testing.allocator);
    try testing.expect(before.eql(&after_sig));
}

test "kfmrh and mfkrh: a face becomes a ring of another and back; mvh and kvh" {
    var kit = try Kit.init(testing.allocator);
    defer kit.deinit();
    const b = &kit.body;
    try lamina(&kit, .{ 0, 1, 2, 3 }, Kit.BOTTOM, Kit.TOP);
    // The top face's loop becomes a ring of the bottom face (a lamina with a hole: no
    // geometric sense, a topological one: genus rises)
    const bottom = b.loop(b.coedge(kit.coedgeFromTo(0, 1)).loop).face;
    const top = topFace(b, kit.planes[Kit.TOP]);
    const top_loop = b.face(top).first_loop;
    try euler.kfmrh(b, bottom, top);
    try expectCounts(b, 4, 4, 1, 2, 1);
    try expectValid(b, .structural);
    try testing.expectEqual(bottom, b.loop(top_loop).face);
    const again = try euler.mfkrh(b, top_loop, kit.planes[Kit.TOP], true);
    try expectCounts(b, 4, 4, 2, 2, 1);
    try testing.expectEqual(top_loop, b.face(again).first_loop);
    try expectValid(b, .structural);
    // An isolated vertex in the bottom face
    const centre = try b.geometry.addPoint(testing.allocator, .{ 0.5, 0.5, 0 });
    const hole = try euler.mvh(b, bottom, centre);
    try expectCounts(b, 5, 4, 2, 3, 1);
    try expectValid(b, .structural);
    try euler.kvh(b, hole);
    try expectCounts(b, 4, 4, 2, 2, 1);
    try expectValid(b, .structural);
    // Two shells merge when the hole face is in another shell
    const other = try euler.mvfs(b, kit.points[4], kit.planes[Kit.TOP], true, .outer);
    try expectCounts(b, 5, 4, 3, 3, 2);
    try testing.expectError(error.Invalid, euler.kfmrh(b, bottom, bottom));
    // mvfs's face has a loop without coedges: kfmrh takes it as a ring all the same
    try euler.kfmrh(b, bottom, other.face);
    try expectCounts(b, 5, 4, 2, 3, 1);
    try expectValid(b, .structural);
}

test "sliceEdge and mergeVertices" {
    var kit = try Kit.init(testing.allocator);
    defer kit.deinit();
    const b = &kit.body;
    try lamina(&kit, .{ 0, 1, 2, 3 }, Kit.BOTTOM, Kit.TOP);
    const c = kit.coedgeFromTo(0, 1);
    const r = try euler.sliceEdge(b, c, try kit.line(0, 1), kit.planes[Kit.FRONT], true);
    try expectCounts(b, 4, 5, 3, 3, 1);
    try expectValid(b, .structural);
    try testing.expectEqual(@as(usize, 2), try traverse.loopLength(b, b.face(r.face).first_loop));
    // A second shell: a spur from corner 4 to a point; merging the spur's far vertex into
    // corner 2 joins the shells at a vertex, which the structural rules allow
    const other = try euler.mvfs(b, kit.points[4], kit.planes[Kit.TOP], true, .outer);
    const spur = try euler.mevSpur(b, other.loop, .none, other.vertex, kit.points[6], try kit.line(4, 6));
    try expectCounts(b, 6, 6, 4, 4, 2);
    try euler.mergeVertices(b, kit.vertexAt(2), spur.vertex);
    try expectCounts(b, 5, 6, 4, 4, 2);
    try expectValid(b, .structural);
    try testing.expectEqual(kit.vertexAt(2), b.coedgeEnd(spur.out));
    try testing.expectError(error.Invalid, euler.mergeVertices(b, kit.vertexAt(2), kit.vertexAt(2)));
}
