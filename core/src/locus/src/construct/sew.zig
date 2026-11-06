//! Sewing (docs/architecture.md §7.1): a closed (or open) set of faces, each given as loops
//! of edge specifications, becomes the shells of a body, the shared edges matched by their
//! curve and vertex pair. The caller makes the vertices and the geometry first; `sew` makes
//! the edges once each, the coedges with their partners, the loops and the faces, sets
//! every back reference, and gives each connected set of faces a shell of its own (two
//! pieces are two shells: a sketch difference that leaves two regions, the extrusion of
//! it). A set in which an edge would be used more than twice, or twice the same way round,
//! is refused.

const std = @import("std");
const geometry = @import("../geometry/types.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const Body = body_mod.Body;
const VertexIndex = types.VertexIndex;
const EdgeIndex = types.EdgeIndex;
const CoedgeIndex = types.CoedgeIndex;

pub const Error = error{
    OutOfMemory,
    TooMany,
    /// An edge used three times, or twice in the same direction, or a loop of no edges.
    NotManifold,
};

/// One edge of a loop, in the loop's direction: from `start` to `end` along `curve`, whose
/// parameter at `start` is `t0` and at `end` is `t1` when `forward`, the reverse otherwise.
/// Two specifications with the same curve and vertices are one edge.
pub const EdgeSpec = struct {
    start: VertexIndex,
    end: VertexIndex,
    curve: geometry.CurveRef,
    /// The edge's range along the curve, from its own start vertex to its end.
    t0: f64,
    t1: f64,
    /// Whether the loop runs the edge from `t0` to `t1`.
    forward: bool = true,
    flags: types.EdgeFlags = .{},
    regularity: types.Regularity = .c0,
    /// The coedge's image in the face's UV box; `none` on a plane.
    pcurve: geometry.PCurveRef = geometry.PCurveRef.none,
};

pub const LoopSpec = struct {
    edges: []const EdgeSpec,
};

pub const FaceSpec = struct {
    surface: geometry.SurfaceRef,
    same_sense: bool = true,
    /// The outer loop first.
    loops: []const LoopSpec,
    uv_box: geometry.Box2 = geometry.Box2.empty,
    tag: types.Tag = .untagged,
};

/// What identifies an edge: its curve, its vertices, and its range (two halves of a circle
/// share the curve and the vertices).
const EdgeKey = struct { curve: u32, a: u32, b: u32, t0: u64, t1: u64 };

/// Sews `faces` into new shells of `kind` in `body`, one per connected set of faces;
/// returns the first.
pub fn sew(body: *Body, faces: []const FaceSpec, kind: types.ShellKind) Error!types.ShellIndex {
    const allocator = body.allocator;
    var edges = std.AutoHashMapUnmanaged(EdgeKey, EdgeIndex).empty;
    defer edges.deinit(allocator);
    // Count to reserve, so nothing fails for memory midway
    var count: usize = 0;
    for (faces) |f| for (f.loops) |l| {
        count += l.edges.len;
    };
    try body.reserve(count + faces.len + 1);
    try edges.ensureTotalCapacity(allocator, @intCast(count));

    const shell = try body.addShell(.{ .kind = kind });
    body.appendShell(shell);
    for (faces) |spec| {
        const face = try body.addFace(.{ .surface = spec.surface, .same_sense = spec.same_sense, .shell = shell, .uv_box = spec.uv_box, .tag = spec.tag });
        body.appendFace(shell, face);
        for (spec.loops) |loop_spec| {
            if (loop_spec.edges.len == 0) return error.NotManifold;
            const loop = try body.addLoop(.{ .face = face });
            body.appendLoop(face, loop);
            var first: CoedgeIndex = .none;
            var prev: CoedgeIndex = .none;
            for (loop_spec.edges) |e| {
                // The edge, made the first time its curve and vertices are seen
                const key = EdgeKey{ .curve = @bitCast(e.curve), .a = @min(@backingInt(e.start), @backingInt(e.end)), .b = @max(@backingInt(e.start), @backingInt(e.end)), .t0 = @bitCast(e.t0), .t1 = @bitCast(e.t1) };
                const entry = edges.getOrPutAssumeCapacity(key);
                var edge: EdgeIndex = undefined;
                var same_sense: bool = undefined;
                if (!entry.found_existing) {
                    const start = if (e.forward) e.start else e.end;
                    const end = if (e.forward) e.end else e.start;
                    edge = try body.addEdge(.{ .curve = e.curve, .t0 = e.t0, .t1 = e.t1, .start = start, .end = end, .flags = e.flags, .regularity = e.regularity });
                    entry.value_ptr.* = edge;
                } else {
                    edge = entry.value_ptr.*;
                    const rec = body.edge(edge);
                    if (rec.coedge == .none or body.coedge(rec.coedge).partner != .none) return error.NotManifold;
                }
                // Whether this use runs the edge from its start to its end: told by the
                // vertices, or by `forward` when they are one (a closed edge)
                const rec = body.edge(edge);
                same_sense = if (rec.start != rec.end) e.start == rec.start else e.forward;
                // The second use runs the other way
                if (entry.found_existing and same_sense == body.coedge(rec.coedge).same_sense) return error.NotManifold;
                const coedge = try body.addCoedge(.{ .edge = edge, .same_sense = same_sense, .loop = loop, .pcurve = e.pcurve });
                if (rec.coedge == .none) {
                    rec.coedge = coedge;
                } else {
                    body.coedge(rec.coedge).partner = coedge;
                    body.coedge(coedge).partner = rec.coedge;
                }
                if (body.vertex(e.start).coedge == .none) body.vertex(e.start).coedge = coedge;
                if (prev != .none) {
                    body.coedge(prev).next = coedge;
                    body.coedge(coedge).prev = prev;
                } else {
                    first = coedge;
                }
                prev = coedge;
            }
            body.coedge(prev).next = first;
            body.coedge(first).prev = prev;
            body.loop(loop).first = first;
        }
    }
    if (kind != .sheet) {
        // Every edge of a closed shell has both coedges, but a degenerate one (a pole, an
        // apex), which belongs to one face
        var it = edges.valueIterator();
        while (it.next()) |edge| {
            const rec = body.edge(edge.*);
            if (rec.coedge == .none) return error.NotManifold;
            if (body.coedge(rec.coedge).partner == .none and !rec.flags.degenerate) return error.NotManifold;
        }
    }
    try splitComponents(body, shell, kind);
    return shell;
}

/// Gives every connected set of the shell's faces (faces joined through shared edges) a
/// shell of its own: the first set keeps `shell`, the others get new ones.
fn splitComponents(body: *Body, shell: types.ShellIndex, kind: types.ShellKind) Error!void {
    const allocator = body.allocator;
    const n = body.faces.items.len;
    // Union–find over the faces, joined across each edge with two coedges
    const parent = try allocator.alloc(u32, n);
    defer allocator.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    for (body.edges.items) |e| {
        if (e.flags.tombstone or e.coedge == .none) continue;
        const partner = body.coedge(e.coedge).partner;
        if (partner == .none) continue;
        const a = find(parent, @backingInt(body.loop(body.coedge(e.coedge).loop).face));
        const b = find(parent, @backingInt(body.loop(body.coedge(partner).loop).face));
        parent[a] = b;
    }
    // The faces of this shell, grouped by root; the first root keeps the shell
    const shell_of_root = try allocator.alloc(types.ShellIndex, n);
    defer allocator.free(shell_of_root);
    @memset(shell_of_root, .none);
    var first_root: ?u32 = null;
    var f = body.shell(shell).first_face;
    body.shell(shell).first_face = .none;
    while (f != .none) {
        const next = body.face(f).next_in_shell;
        const root = find(parent, @backingInt(f));
        if (first_root == null) {
            first_root = root;
            shell_of_root[root] = shell;
        } else if (shell_of_root[root] == .none) {
            const added = try body.addShell(.{ .kind = kind });
            body.appendShell(added);
            shell_of_root[root] = added;
        }
        body.appendFace(shell_of_root[root], f);
        f = next;
    }
}

fn find(parent: []u32, i: u32) u32 {
    var root = i;
    while (parent[root] != root) root = parent[root];
    var at = i;
    while (parent[at] != root) {
        const next = parent[at];
        parent[at] = root;
        at = next;
    }
    return root;
}
