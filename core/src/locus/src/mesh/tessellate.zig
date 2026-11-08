//! The mesh of a body (docs/architecture.md §7.7, D13): its edges discretized once
//! (`edges.zig`), its faces triangulated between them. In M2 the planar faces: each face's
//! loops become a polygon in the plane's (u, v) through the shared edge points, the
//! triangulator cuts it (`triangulate.zig`), and the triangles are turned to the face's
//! outward normal. Vertices are welded by construction: a body vertex is one mesh vertex,
//! an edge's interior point one, so a closed body of planar faces gives a mesh in which
//! every edge appears once each way (`CHECK_EDGE_PAIRS`). A curved face is reported as
//! `.curved_later` with no triangles until M3 adds interior points and the mapping through
//! its surface; a planar face the triangulator refuses is `.failed`, a warning names it,
//! and the rest of the body is still delivered (a viewer wants the part it can draw).

const std = @import("std");
const vec = @import("../math/vec.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const edges_mod = @import("edges.zig");
const triangulate = @import("triangulate.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

const NONE: u32 = std.math.maxInt(u32);

/// What became of a face.
pub const Status = enum(u8) {
    ok,
    /// A curved face: tessellated from M3 on.
    curved_later,
    /// The triangulator refused the face's polygon: a defect upstream, in the loops.
    failed,
};

/// A face's triangles: `triangles[first..first + count]`.
pub const FaceRange = struct {
    face: types.FaceIndex,
    first: u32,
    count: u32,
    status: Status,
};

pub const Mesh = struct {
    positions: []Vec3,
    /// Counter-clockwise about the face's outward normal, as indices into `positions`.
    triangles: [][3]u32,
    faces: []FaceRange,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
        allocator.free(self.triangles);
        allocator.free(self.faces);
        self.* = undefined;
    }

    pub fn of(self: Mesh, range: FaceRange) []const [3]u32 {
        return self.triangles[range.first .. range.first + range.count];
    }
};

/// The mesh of `body` at `resolution`; owned by `allocator`. `error.NotImplemented` for a
/// body with a free-form edge (M3); a curved face is left out with its status. A planar
/// face whose chorded outline crosses itself at the resolution (a chord of an arc cutting
/// across a hole or a neighbouring edge that the arc itself clears) has its arcs' grids
/// doubled, the mesh built again, up to `edges.MAX_DOUBLINGS` times; what still fails is
/// reported `.failed` with a warning.
pub fn tessellate(allocator: std.mem.Allocator, body: *const Body, resolution: tolerance.Resolution, options: diagnostics.Options, diag: *Diagnostics) Error!Mesh {
    try options.checkCancel();
    const doublings = try allocator.alloc(u8, body.edges.items.len);
    defer allocator.free(doublings);
    @memset(doublings, 0);
    var round: u8 = 0;
    while (true) : (round += 1) {
        var attempt = Diagnostics.init(allocator);
        defer attempt.deinit();
        var mesh = try build(allocator, body, resolution, doublings, options, &attempt);
        errdefer mesh.deinit(allocator);
        var refined = false;
        if (round < edges_mod.MAX_DOUBLINGS) {
            for (mesh.faces) |range| {
                if (range.status == .failed and try doubleArcs(body, range.face, doublings, diag)) refined = true;
            }
        }
        if (!refined) {
            for (attempt.findings.items) |finding| try diag.add(finding);
            return mesh;
        }
        mesh.deinit(allocator);
    }
}

/// Doubles the grid of every arc edge of face `f`; whether it had any.
fn doubleArcs(body: *const Body, f: types.FaceIndex, doublings: []u8, diag: *Diagnostics) Error!bool {
    var any = false;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var coedges = traverse.Coedges.init(body, l);
        while (coedges.next() catch return corrupt(diag)) |c| {
            const e = body.coedge(c).edge;
            if (body.geometry.curve(body.edge(e).curve) != .circle) continue;
            doublings[@backingInt(e)] += 1;
            any = true;
        }
    }
    return any;
}

fn build(allocator: std.mem.Allocator, body: *const Body, resolution: tolerance.Resolution, doublings: []const u8, options: diagnostics.Options, diag: *Diagnostics) Error!Mesh {
    var edge_points = try edges_mod.discretizeRefined(allocator, body, resolution, doublings, diag);
    defer edge_points.deinit(allocator);

    // Mesh vertices: the body's vertices first, then each edge's interior points
    var positions: std.ArrayList(Vec3) = .empty;
    errdefer positions.deinit(allocator);
    const vertex_id = try allocator.alloc(u32, body.vertices.items.len);
    defer allocator.free(vertex_id);
    for (body.vertices.items, vertex_id) |v, *id| {
        id.* = if (v.tombstone) NONE else @intCast(positions.items.len);
        if (!v.tombstone) try positions.append(allocator, body.geometry.point(v.point));
    }
    const interior_start = try allocator.alloc(u32, body.edges.items.len);
    defer allocator.free(interior_start);
    for (body.edges.items, 0..) |e, i| {
        interior_start[i] = @intCast(positions.items.len);
        if (e.flags.tombstone or e.flags.degenerate) continue;
        const pts = edge_points.of(types.EdgeIndex.of(i));
        try positions.appendSlice(allocator, pts[1 .. pts.len - 1]);
    }

    var triangles: std.ArrayList([3]u32) = .empty;
    errdefer triangles.deinit(allocator);
    var faces: std.ArrayList(FaceRange) = .empty;
    errdefer faces.deinit(allocator);
    var ring_uv: std.ArrayList(Vec2) = .empty;
    defer ring_uv.deinit(allocator);
    var ring_id: std.ArrayList(u32) = .empty;
    defer ring_id.deinit(allocator);
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(allocator);

    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        var it = traverse.Faces.init(body, s);
        while (it.next() catch return corrupt(diag)) |f| {
            try options.checkCancel();
            const face = body.face(f);
            const first: u32 = @intCast(triangles.items.len);
            if (face.surface.kind != .plane) {
                try faces.append(allocator, .{ .face = f, .first = first, .count = 0, .status = .curved_later });
                continue;
            }
            const plane = body.geometry.planes.items[face.surface.index];
            ring_uv.clearRetainingCapacity();
            ring_id.clearRetainingCapacity();
            starts.clearRetainingCapacity();
            try starts.append(allocator, 0);
            var loops = traverse.Loops.init(body, f);
            while (loops.next() catch return corrupt(diag)) |l| {
                const ring_start = ring_uv.items.len;
                var coedges = traverse.Coedges.init(body, l);
                while (coedges.next() catch return corrupt(diag)) |c| {
                    const coedge = body.coedge(c);
                    const e = body.edge(coedge.edge);
                    const pts = edge_points.of(coedge.edge);
                    // The edge's points the coedge's way, its last point left to the next
                    // coedge, which starts there
                    for (0..pts.len - 1) |step| {
                        const k = if (coedge.same_sense) step else pts.len - 1 - step;
                        const id = if (k == 0) vertex_id[@backingInt(e.start)] else if (k == pts.len - 1) vertex_id[@backingInt(e.end)] else interior_start[@backingInt(coedge.edge)] + @as(u32, @intCast(k - 1));
                        try ring_uv.append(allocator, plane.project(pts[k]));
                        try ring_id.append(allocator, id);
                    }
                }
                // Loops run counter-clockwise in UV when the outward normal is the
                // surface's; the triangulator wants them so
                if (!face.same_sense) {
                    std.mem.reverse(Vec2, ring_uv.items[ring_start..]);
                    std.mem.reverse(u32, ring_id.items[ring_start..]);
                }
                try starts.append(allocator, @intCast(ring_uv.items.len));
            }
            const polygon: triangulate.Polygon = .{ .points = ring_uv.items, .starts = starts.items };
            var face_diag = Diagnostics.init(allocator);
            defer face_diag.deinit();
            const local = triangulate.triangulate(allocator, polygon, &face_diag) catch |err| switch (err) {
                error.InvalidInput, error.LimitExceeded => {
                    try diag.warn(.{ .code = if (face_diag.first()) |finding| finding.code else .not_simple, .entity = .of(.face, @backingInt(f)), .label = "a face's polygon" });
                    try faces.append(allocator, .{ .face = f, .first = first, .count = 0, .status = .failed });
                    continue;
                },
                else => return err,
            };
            defer allocator.free(local);
            for (local) |t| {
                // Counter-clockwise in UV is about the surface's normal: turned over when
                // the face's outward normal is its opposite
                const a = ring_id.items[t[0]];
                const b = ring_id.items[t[1]];
                const c = ring_id.items[t[2]];
                try triangles.append(allocator, if (face.same_sense) .{ a, b, c } else .{ a, c, b });
            }
            try faces.append(allocator, .{ .face = f, .first = first, .count = @intCast(local.len), .status = .ok });
        }
    }
    const owned_positions = try positions.toOwnedSlice(allocator);
    errdefer allocator.free(owned_positions);
    const owned_triangles = try triangles.toOwnedSlice(allocator);
    errdefer allocator.free(owned_triangles);
    return .{ .positions = owned_positions, .triangles = owned_triangles, .faces = try faces.toOwnedSlice(allocator) };
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
