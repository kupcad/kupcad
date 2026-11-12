//! The boolean of two solids with planar faces (docs/architecture.md §7.4, D10, D16, D17):
//! the general imprint–classify–assemble pipeline, its phases separate modules with
//! tables between them, each testable alone, in this order (the layering test holds it):
//!
//! 1. `pave.zig`: every place the operands touch, in order of dimension, as merged
//!    vertices, each edge's paves, each face's section segments, the coplanar face pairs;
//! 2. `imprint.zig`: each face split by its paves and section segments in the overlay,
//!    into fragments;
//! 3. `classify.zig`: each fragment inside, outside, or on a face of the other operand
//!    facing the same or the other way;
//! 4. `select.zig`: Mäntylä's table, the fragments kept, `b`'s turned inward in a
//!    difference;
//! 5. here, the assembly: the kept fragments sewn into shells (`construct/sew.zig`), one
//!    vertex per merged vertex, the coplanar ones on one plane record; an edge more than two
//!    fragments use (two solids touching along it) is one edge per solid, its uses paired
//!    by the wedges of material about it; a shell enclosing negative volume a void;
//! 6. `simplify.zig`: faces on one plane merged across edges, edges joined across vertices
//!    on a line;
//! 7. the checker: the result passes it or the operation fails with its finding.
//!
//! An empty operand answers without geometry (the union is the other, a difference
//! without `b` is `a`, the rest are empty). Operands with a curved face are M5's: refused,
//! naming the face. The result's tolerance is the larger of the operands' (§6) unless the
//! options give one.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const check = @import("../topology/check.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const trace = @import("../io/trace.zig");
const primitives = @import("../construct/primitives.zig");
const sew = @import("../construct/sew.zig");
const in_face = @import("../query/in_face.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const pave = @import("pave.zig");
const imprint = @import("imprint.zig");
const classify = @import("classify.zig");
const select = @import("select.zig");
const simplify = @import("simplify.zig");
const Body = body_mod.Body;
const Frame = geometry.Frame;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const Op = select.Op;

/// The milestone of booleans on curved operands.
const CURVED_MILESTONE = 5;

/// `a op b`, a new solid; the operands untouched.
pub fn boolean(allocator: std.mem.Allocator, a: *const Body, b: *const Body, op: Op, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    try options.checkCancel();
    try trace.arguments(allocator, &options, "boolean", .{ .op = op });
    for ([2]*const Body{ a, b }) |operand| {
        if (operand.kind != .solid) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "an operand: a solid" });
        try planarOnly(operand, diag);
    }
    const tol = options.tolerance orelse Tolerance.merge(a.tol, b.tol);
    try diagnostics.input.tolerance(diag, tol);
    if (a.isEmpty() or b.isEmpty()) return emptyOperand(allocator, a, b, op, tol, diag);

    var paves = try pave.run(allocator, a, b, tol, options, diag);
    defer paves.deinit();
    try options.checkCancel();
    var fragments = try imprint.run(allocator, &paves, options, diag);
    defer fragments.deinit();
    const classes = try classify.run(allocator, &paves, &fragments, options, diag);
    defer allocator.free(classes);
    const keeps = try select.run(allocator, op, &fragments, classes);
    defer allocator.free(keeps);
    try options.checkCancel();

    var result = try assemble(allocator, &paves, &fragments, keeps, tol, diag);
    errdefer result.deinit();
    try trace.phase(allocator, &options, &result, "boolean", "assembled");
    try simplify.run(&result, diag);
    try trace.phase(allocator, &options, &result, "boolean", "simplified");
    var report = try check.run(allocator, &result, .geometric);
    defer report.deinit(allocator);
    if (report.first()) |f| return diag.fail(error.NotValid, f);
    return result;
}

/// `NotImplemented` naming the first face of `body` that is not planar or has an edge that
/// is not a line.
fn planarOnly(body: *const Body, diag: *Diagnostics) Error!void {
    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(body, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            var straight = body.face(f).surface.kind == .plane;
            var loops = traverse.Loops.init(body, f);
            while (straight) {
                const l = (loops.next() catch return corrupt(diag)) orelse break;
                var it = traverse.Coedges.init(body, l);
                while (it.next() catch return corrupt(diag)) |c| straight = straight and body.edge(body.coedge(c).edge).curve.kind == .line;
            }
            if (!straight) return diag.fail(error.NotImplemented, .{ .code = .not_implemented, .entity = .of(.face, @backingInt(f)), .label = "a boolean of an operand with a curved face or edge", .threshold = CURVED_MILESTONE });
        }
    }
}

fn emptyOperand(allocator: std.mem.Allocator, a: *const Body, b: *const Body, op: Op, tol: Tolerance, diag: *Diagnostics) Error!Body {
    const keep: ?*const Body = switch (op) {
        .@"union" => if (a.isEmpty()) b else a,
        .difference => a,
        .intersection => null,
    };
    if (keep) |body| if (!body.isEmpty()) return body.clone(allocator) catch |e| return tooMany(diag, e);
    var empty = Body.empty(allocator, tol);
    empty.kind = .solid;
    return empty;
}

/// One use of an edge by a kept fragment, for pairing the uses of an edge more than two
/// fragments share.
const Use = struct {
    spec: u32,
    face: u32,
};

/// The kept fragments as a body: see the file's comment, step 5.
fn assemble(allocator: std.mem.Allocator, paves: *const pave.Paves, fragments: *const imprint.Fragments, keeps: []const select.Keep, tol: Tolerance, diag: *Diagnostics) Error!Body {
    var b = try primitives.Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const vertex_of = try allocator.alloc(types.VertexIndex, paves.points.items.len);
    defer allocator.free(vertex_of);
    @memset(vertex_of, .none);

    var edge_specs: std.ArrayList(sew.EdgeSpec) = .empty;
    defer edge_specs.deinit(allocator);
    var uses: std.ArrayList(Use) = .empty;
    defer uses.deinit(allocator);
    // Per face: its loops as ranges of `edge_specs`, and per loop its range
    var loop_ranges: std.ArrayList([2]u32) = .empty;
    defer loop_ranges.deinit(allocator);
    var faces: std.ArrayList(sew.FaceSpec) = .empty;
    defer faces.deinit(allocator);
    var face_loops: std.ArrayList([2]u32) = .empty;
    defer face_loops.deinit(allocator);
    var normals: std.ArrayList(Vec3) = .empty;
    defer normals.deinit(allocator);

    for (fragments.items.items, keeps, 0..) |fragment, keep, i| {
        if (keep == .drop) continue;
        const flip = keep == .flip;
        const body = paves.operands[fragment.operand];
        const f = types.FaceIndex.of(fragment.face);
        const frame = planar_faces.frameOf(body, f).?;
        var normal = in_face.outwardNormal(body, f, .{ 0, 0 });
        if (flip) normal = vec.neg(normal);
        const facing = try b.facingPlane(Frame.init(frame.origin, frame.x, normal));
        const face_index: u32 = @intCast(faces.items.len);
        const first_loop: u32 = @intCast(loop_ranges.items.len);
        for (fragments.loopsOf(i)) |loop| {
            const vertices = fragments.loopVertices(loop);
            const start: u32 = @intCast(edge_specs.items.len);
            for (0..vertices.len) |j| {
                // A flipped fragment's loops run the other way
                const from = if (flip) vertices[vertices.len - 1 - j] else vertices[j];
                const to = if (flip) vertices[(2 * vertices.len - 2 - j) % vertices.len] else vertices[(j + 1) % vertices.len];
                const u = try builderVertex(&b, paves, vertex_of, from);
                const w = try builderVertex(&b, paves, vertex_of, to);
                if (u == w) return diag.fail(error.Degenerate, .{ .code = .edge_too_short, .entity = .of(.face, fragment.face), .label = "a piece of a face" });
                try edge_specs.append(allocator, try b.straight(u, w));
                try uses.append(allocator, .{ .spec = @intCast(edge_specs.items.len - 1), .face = face_index });
            }
            try loop_ranges.append(allocator, .{ start, @intCast(edge_specs.items.len - start) });
        }
        try face_loops.append(allocator, .{ first_loop, @intCast(loop_ranges.items.len - first_loop) });
        try normals.append(allocator, normal);
        try faces.append(allocator, .{ .surface = facing.surface, .same_sense = facing.same_sense, .loops = &.{}, .attribute = body.face(f).attribute });
    }
    try pairTouching(allocator, &b.body, edge_specs.items, uses.items, normals.items, diag);

    // The loops, now that the edges no longer move; each face's box in its plane record's frame
    const loop_specs = try allocator.alloc(sew.LoopSpec, loop_ranges.items.len);
    defer allocator.free(loop_specs);
    for (loop_ranges.items, loop_specs) |range, *spec| spec.* = .{ .edges = edge_specs.items[range[0]..][0..range[1]] };
    for (faces.items, face_loops.items) |*spec, range| {
        spec.loops = loop_specs[range[0]..][0..range[1]];
        const plane_frame = b.body.geometry.planes.items[spec.surface.index].frame;
        var uv = geometry.Box2.empty;
        for (spec.loops) |l| for (l.edges) |e| {
            const p = plane_frame.toLocal(b.body.point(e.start));
            uv.grow(.{ p[0], p[1] });
        };
        spec.uv_box = uv;
    }
    if (faces.items.len == 0) return b.body;
    _ = sew.sew(&b.body, faces.items, .outer) catch |e| return b.fail(e);
    // A shell enclosing negative volume bounds a void
    var shells = traverse.Shells.init(&b.body);
    while (shells.next() catch return corrupt(diag)) |s| {
        if (try shellVolume(&b.body, s, diag) < 0) b.body.shell(s).kind = .void;
    }
    return b.body;
}

/// The builder's vertex for merged vertex `m`, made on its first use with the merged
/// vertex's gap.
fn builderVertex(b: *primitives.Builder, paves: *const pave.Paves, vertex_of: []types.VertexIndex, m: u32) Error!types.VertexIndex {
    if (vertex_of[m] == .none) {
        vertex_of[m] = try b.vertex(paves.point(m));
        b.body.vertex(vertex_of[m]).gap = paves.gaps.items[m];
    }
    return vertex_of[m];
}

/// Each edge more than two fragments use, where two solids of the result touch along it,
/// made one edge per solid (`EdgeSpec.copy`): its uses sorted by the angle of their faces
/// about it, and each pair of neighbours with material between them one edge (the face
/// side away from a face's outward normal is its material).
fn pairTouching(allocator: std.mem.Allocator, body: *const Body, specs: []sew.EdgeSpec, uses: []const Use, normals: []const Vec3, diag: *Diagnostics) Error!void {
    const Key = struct { lo: u32, hi: u32 };
    var groups: std.AutoArrayHashMapUnmanaged(Key, std.ArrayList(u32)) = .empty;
    defer {
        for (groups.values()) |*list| list.deinit(allocator);
        groups.deinit(allocator);
    }
    for (uses, 0..) |use, i| {
        const spec = specs[use.spec];
        const key: Key = .{ .lo = @min(@backingInt(spec.start), @backingInt(spec.end)), .hi = @max(@backingInt(spec.start), @backingInt(spec.end)) };
        const entry = try groups.getOrPut(allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, @intCast(i));
    }
    for (groups.keys(), groups.values()) |key, *list| {
        if (list.items.len <= 2) continue;
        if (list.items.len % 2 != 0) return diag.fail(error.NotValid, .{ .code = .edge_coedge_count, .label = "an edge of a boolean's result", .measured = @floatFromInt(list.items.len) });
        const origin = body.point(types.VertexIndex.of(key.lo));
        const axis = vec.normalized(vec.sub(body.point(types.VertexIndex.of(key.hi)), origin)) orelse return diag.fail(error.Degenerate, .{ .code = .edge_too_short, .label = "an edge of a boolean's result" });
        const r0 = vec.perpendicular(axis);
        const r1 = vec.cross(axis, r0);
        // Each use's face, as the direction into it from the edge, by its angle about the axis
        const Sorted = struct {
            angles: []const f64,
            fn lessThan(ctx: @This(), x: u32, y: u32) bool {
                return ctx.angles[x] < ctx.angles[y];
            }
        };
        const angle_of = try allocator.alloc(f64, uses.len);
        defer allocator.free(angle_of);
        for (list.items) |u| {
            const spec = specs[uses[u].spec];
            const along = if (@backingInt(spec.start) == key.lo) axis else vec.neg(axis);
            const into = vec.cross(normals[uses[u].face], along);
            angle_of[u] = trig.atan2(vec.dot(into, r1), vec.dot(into, r0));
        }
        std.mem.sort(u32, list.items, Sorted{ .angles = angle_of }, Sorted.lessThan);
        // Pair each use with its neighbour on its material side, turning about the axis
        const n = list.items.len;
        var copy: u32 = 0;
        var paired = try allocator.alloc(bool, n);
        defer allocator.free(paired);
        @memset(paired, false);
        for (0..n) |k| {
            const u = list.items[k];
            const spec = specs[uses[u].spec];
            const along = if (@backingInt(spec.start) == key.lo) axis else vec.neg(axis);
            const into = vec.cross(normals[uses[u].face], along);
            // Turning on about the axis from this face leaves it on its material side
            if (vec.dot(vec.cross(axis, into), normals[uses[u].face]) >= 0) continue;
            const next = (k + 1) % n;
            if (paired[k] or paired[next]) return diag.fail(error.NotValid, .{ .code = .edge_coedge_count, .label = "an edge of a boolean's result (its faces do not pair)", .measured = @floatFromInt(n) });
            paired[k] = true;
            paired[next] = true;
            specs[uses[u].spec].copy = copy;
            specs[uses[list.items[next]].spec].copy = copy;
            copy += 1;
        }
        for (paired) |p| if (!p) return diag.fail(error.NotValid, .{ .code = .edge_coedge_count, .label = "an edge of a boolean's result (its faces do not pair)", .measured = @floatFromInt(n) });
    }
}

/// The volume shell `s` encloses, by the fan of each face about its first vertex:
/// negative for a void's. Planar faces with straight edges.
fn shellVolume(body: *const Body, s: types.ShellIndex, diag: *Diagnostics) Error!f64 {
    var volume: f64 = 0;
    var faces = traverse.Faces.init(body, s);
    while (faces.next() catch return corrupt(diag)) |f| {
        const apex = body.point(body.coedgeStart(body.loop(body.face(f).first_loop).first));
        var loops = traverse.Loops.init(body, f);
        while (loops.next() catch return corrupt(diag)) |l| {
            var it = traverse.Coedges.init(body, l);
            while (it.next() catch return corrupt(diag)) |c| volume += vec.dot(apex, vec.cross(body.point(body.coedgeStart(c)), body.point(body.coedgeEnd(c)))) / 6.0;
        }
    }
    return volume;
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "a boolean's operand or result" });
}

/// A body's tables' errors as the operation's.
pub fn tooMany(diag: *Diagnostics, err: error{ OutOfMemory, TooMany }) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooMany => diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "entities" }),
    };
}
