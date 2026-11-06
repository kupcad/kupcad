const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const types = @import("types.zig");
const Body = @import("body.zig").Body;
const traverse = @import("traverse.zig");
const tags = @import("tags.zig");

const tol = Tolerance.fromZone(1e-5);

/// A sheet of one triangular face on the plane z = 0, its three edges with one coedge
/// each: the smallest body with every table in use.
fn triangle(allocator: std.mem.Allocator) !Body {
    var b = Body.init(allocator, tol);
    errdefer b.deinit();
    b.kind = .sheet;
    const pts = [_]vec.Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    var v: [3]types.VertexIndex = undefined;
    for (pts, 0..) |p, i| v[i] = try b.addVertex(.{ .point = try b.geometry.addPoint(allocator, p) });
    const plane = try b.geometry.addPlane(allocator, .{ .frame = geometry.Frame.world });
    const shell = try b.addShell(.{ .kind = .sheet });
    b.appendShell(shell);
    const face = try b.addFace(.{ .surface = plane, .shell = shell });
    b.appendFace(shell, face);
    const loop = try b.addLoop(.{ .face = face });
    b.appendLoop(face, loop);
    var c: [3]types.CoedgeIndex = undefined;
    for (0..3) |i| {
        const line = try b.geometry.addLine(allocator, @import("../geometry/curves.zig").Line.through(pts[i], pts[(i + 1) % 3]).?);
        const e = try b.addEdge(.{ .curve = line, .t0 = 0, .t1 = vec.distance(pts[i], pts[(i + 1) % 3]), .start = v[i], .end = v[(i + 1) % 3] });
        c[i] = try b.addCoedge(.{ .edge = e, .same_sense = true, .loop = loop });
        b.edge(e).coedge = c[i];
        b.vertex(v[i]).coedge = c[i];
    }
    for (0..3) |i| {
        b.coedge(c[i]).next = c[(i + 1) % 3];
        b.coedge(c[i]).prev = c[(i + 2) % 3];
    }
    b.loop(loop).first = c[0];
    return b;
}

test "Body: the empty body, the triangle's tables, and the traversals" {
    var e = Body.empty(testing.allocator, tol);
    defer e.deinit();
    try testing.expect(e.isEmpty());
    try testing.expectEqual(@as(usize, 0), e.counts().faces);

    var b = try triangle(testing.allocator);
    defer b.deinit();
    try testing.expect(!b.isEmpty());
    const c = b.counts();
    try testing.expectEqual(Body.Counts{ .vertices = 3, .edges = 3, .coedges = 3, .loops = 1, .faces = 1, .shells = 1 }, c);

    var shells = traverse.Shells.init(&b);
    const s = (try shells.next()).?;
    try testing.expectEqual(@as(?types.ShellIndex, null), try shells.next());
    var faces = traverse.Faces.init(&b, s);
    const f = (try faces.next()).?;
    try testing.expectEqual(@as(?types.FaceIndex, null), try faces.next());
    var loops = traverse.Loops.init(&b, f);
    const l = (try loops.next()).?;
    try testing.expectEqual(@as(?types.LoopIndex, null), try loops.next());
    try testing.expectEqual(@as(usize, 3), try traverse.loopLength(&b, l));
    var coedges = traverse.Coedges.init(&b, l);
    var seen: usize = 0;
    var prev_end: types.VertexIndex = .none;
    while (try coedges.next()) |ce| : (seen += 1) {
        // Each coedge starts where the previous ended
        if (prev_end != .none) try testing.expectEqual(prev_end, b.coedgeStart(ce));
        prev_end = b.coedgeEnd(ce);
    }
    try testing.expectEqual(@as(usize, 3), seen);
    // The umbrella of a sheet vertex stops at the boundary: one coedge leaves it
    var umbrella = traverse.Umbrella.init(&b, types.VertexIndex.of(0));
    try testing.expect((try umbrella.next()) != null);
    try testing.expectEqual(@as(?types.CoedgeIndex, null), try umbrella.next());
    const pair = traverse.coedgesOfEdge(&b, types.EdgeIndex.of(0));
    try testing.expectEqual(types.CoedgeIndex.of(0), pair[0]);
    try testing.expectEqual(types.CoedgeIndex.none, pair[1]);
}

test "Body: a corrupt cycle is an error, never a hang" {
    var b = try triangle(testing.allocator);
    defer b.deinit();
    // Make the loop's third coedge point back to the second: a cycle that never returns to the first
    b.coedge(types.CoedgeIndex.of(2)).next = types.CoedgeIndex.of(1);
    var coedges = traverse.Coedges.init(&b, types.LoopIndex.of(0));
    var result: traverse.Error!?types.CoedgeIndex = null;
    var n: usize = 0;
    while (n < 10) : (n += 1) {
        result = coedges.next();
        if (result) |r| {
            if (r == null) break;
        } else |_| break;
    }
    try testing.expectError(error.Corrupt, result);
}

test "Body: clone is independent, checkpoint restores, compact renumbers and remaps" {
    var b = try triangle(testing.allocator);
    defer b.deinit();
    var copy = try b.clone(testing.allocator);
    defer copy.deinit();
    _ = try b.addVertex(.{ .point = try b.geometry.addPoint(testing.allocator, .{ 5, 5, 5 }) });
    try testing.expectEqual(@as(usize, 3), copy.vertices.items.len);
    try testing.expectEqual(@as(usize, 4), b.vertices.items.len);

    var cp = try b.checkpoint();
    _ = try b.addFace(.{ .surface = geometry.SurfaceRef.of(.plane, 0), .shell = types.ShellIndex.of(0) });
    b.vertex(types.VertexIndex.of(0)).gap = 7;
    try testing.expectEqual(@as(usize, 2), b.faces.items.len);
    cp.restore(&b);
    try testing.expectEqual(@as(usize, 1), b.faces.items.len);
    try testing.expectEqual(@as(f64, 0), b.vertex(types.VertexIndex.of(0)).gap);

    // Tombstone the extra vertex and an unused edge, then compact: indices shift
    b.vertex(types.VertexIndex.of(3)).tombstone = true;
    const dead_edge = try b.addEdge(.{ .curve = geometry.CurveRef.of(.line, 0), .t0 = 0, .t1 = 1, .start = types.VertexIndex.of(0), .end = types.VertexIndex.of(1) });
    b.edge(dead_edge).flags.tombstone = true;
    // A tombstoned first coedge, so the live ones move down one
    const dead = try b.addCoedge(.{ .edge = dead_edge, .same_sense = true, .loop = types.LoopIndex.of(0) });
    b.coedge(dead).tombstone = true;
    b.coedge(types.CoedgeIndex.of(0)).tombstone = true;
    // Relink the loop as 1 → 2 → 1 (a two-coedge loop, just to see the remap applied)
    b.coedge(types.CoedgeIndex.of(1)).next = types.CoedgeIndex.of(2);
    b.coedge(types.CoedgeIndex.of(2)).next = types.CoedgeIndex.of(1);
    b.coedge(types.CoedgeIndex.of(1)).prev = types.CoedgeIndex.of(2);
    b.coedge(types.CoedgeIndex.of(2)).prev = types.CoedgeIndex.of(1);
    b.loop(types.LoopIndex.of(0)).first = types.CoedgeIndex.of(1);
    b.vertex(types.VertexIndex.of(0)).coedge = .none;
    b.edge(types.EdgeIndex.of(0)).coedge = .none;
    var remap = try b.compact();
    defer remap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), b.vertices.items.len);
    try testing.expectEqual(@as(usize, 3), b.edges.items.len);
    try testing.expectEqual(@as(usize, 2), b.coedges.items.len);
    try testing.expectEqual(Body.Remap.NONE, remap.coedges[0]);
    try testing.expectEqual(@as(u32, 0), remap.coedges[1]);
    try testing.expectEqual(@as(u32, 1), remap.coedges[2]);
    try testing.expectEqual(Body.Remap.NONE, remap.vertices[3]);
    try testing.expectEqual(types.CoedgeIndex.of(0), b.loop(types.LoopIndex.of(0)).first);
    try testing.expectEqual(types.CoedgeIndex.of(1), b.coedge(types.CoedgeIndex.of(0)).next);
    try testing.expectEqual(types.CoedgeIndex.of(0), b.coedge(types.CoedgeIndex.of(1)).next);
    try testing.expectEqual(types.CoedgeIndex.of(0), b.vertex(types.VertexIndex.of(1)).coedge);
    try testing.expectEqual(@as(usize, 2), try traverse.loopLength(&b, types.LoopIndex.of(0)));
}

test "Tags: splits copy, merges unite, names are found at the root, and the log keeps named entities" {
    var table: tags.Table = .empty;
    defer table.deinit(testing.allocator);
    const a = try table.named(testing.allocator, 1, 100);
    const b = try table.named(testing.allocator, 1, 200);
    const a1 = try table.split(testing.allocator, 2, a);
    const a2 = try table.split(testing.allocator, 2, a1);
    try testing.expect(table.descendsFrom(a2, a));
    try testing.expect(!table.descendsFrom(a2, b));
    try testing.expectEqual(@as(?u32, 100), table.nameOf(a2));
    const ab = try table.merged(testing.allocator, 3, a2, b);
    try testing.expect(table.descendsFrom(ab, a) and table.descendsFrom(ab, b));
    try testing.expectEqual(@as(?u32, null), table.nameOf(ab));
    // An untagged parent gives nothing; merging with untagged keeps the tagged one
    try testing.expectEqual(types.Tag.untagged, try table.split(testing.allocator, 2, .untagged));
    try testing.expectEqual(a, try table.merged(testing.allocator, 3, a, .untagged));
    try testing.expectEqual(a, try table.merged(testing.allocator, 3, a, a));
    const p = try table.pair(testing.allocator, 4, a, b);
    try testing.expect(table.descendsFrom(p, b));
    try testing.expectEqual(@as(?tags.Row, null), table.row(.untagged));

    var log: tags.ChangeLog = .empty;
    defer log.deinit(testing.allocator);
    try log.record(testing.allocator, .{ .kind = .face, .what = .split, .tag = a1 });
    try log.record(testing.allocator, .{ .kind = .face, .what = .added, .tag = .untagged });
    try testing.expectEqual(@as(usize, 1), log.changes.items.len);
    var copy = try table.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expectEqual(table.rows.items.len, copy.rows.items.len);
}
