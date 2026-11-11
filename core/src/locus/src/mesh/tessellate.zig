//! The mesh of a body (docs/architecture.md §7.7, D13): its edges discretized once
//! (`edges.zig`), its faces triangulated between them. Each face's loops become a polygon
//! in the face's UV (a plane's by projection, a curved surface's by the coedges' pcurves
//! at the edge points' parameters), the triangulator cuts it (`triangulate.zig`), and the
//! triangles are turned to the face's outward normal. A curved face (cylinder, cone,
//! sphere, torus) is first scaled to be near-isometric (`u` is radians, `v` millimetres)
//! and gets interior points: the tensor grid of its boundary's distinct `u` and `v` values
//! and of the resolution's own parameter lines around each circular direction (the grid
//! a full circle of that direction's largest radius gets, from angle 0: the very grid the
//! edges are cut on, so a boundary along a circle adds no line), inserted into the
//! constrained Delaunay triangulation and mapped through the surface (a structured grid
//! zipped to the edge points, research/solidcraft.md §3; a cylinder's side gets no
//! interior point and keeps the mesh engine's vertices, a hemisphere a latitude-longitude
//! grid); a triangle along a pole (two corners at one vertex) is dropped. A free-form
//! face (an extrusion or a revolution of a free-form curve, a NURBS patch) gets the
//! generator's certified chords (`chords.zig`) and the patch's knots as its lines, and is
//! then refined where a link's or a triangle's midpoint on the surface stands off the
//! mesh by more than a chord of that length may bow. Vertices are welded by
//! construction: a body vertex is one mesh vertex, an edge's interior point one, so a
//! closed body gives a mesh in which every edge appears once each way
//! (`CHECK_EDGE_PAIRS`). A face the triangulator refuses is `.failed` with why, a warning
//! names it, and it is filled leniently (a fan of its outer loop) so that the rest of the
//! body is still delivered with no hole in the picture (a viewer wants the part it can
//! draw).

const std = @import("std");
const vec = @import("../math/vec.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const geometry = @import("../geometry/types.zig");
const surfaces = @import("../geometry/surfaces.zig");
const edges_mod = @import("edges.zig");
const triangulate = @import("triangulate.zig");
const chords = @import("chords.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

const NONE: u32 = std.math.maxInt(u32);
const TWO_PI: f64 = 2 * std.math.pi;
/// Two parameter values closer than this share of the face's UV box are one grid line
/// (an edge's grid point within `edges.END_SLACK` of its end is left to the vertex).
const GRID_MERGE: f64 = 1e-9;
/// How often a free-form face is triangulated again with the midpoints that stood off.
const MAX_REFINE_ROUNDS: usize = 8;
/// The most points a face's triangulation takes before refinement stops.
const MAX_FACE_POINTS: usize = 1 << 18;

/// What became of a face.
pub const Status = enum(u8) {
    ok,
    /// The triangulator refused the face's polygon (`FaceRange.reason` says why): a
    /// defect upstream, in the loops; the face is filled leniently.
    failed,
};

/// A face's triangles: `triangles[first..first + count]`.
pub const FaceRange = struct {
    face: types.FaceIndex,
    first: u32,
    count: u32,
    status: Status,
    /// Why the face `.failed`; null otherwise.
    reason: ?diagnostics.Code = null,
};

/// An edge's polyline as mesh vertices: `edge_vertices[first..first + count]`, from its
/// `t0` end; a tombstoned edge has none, a degenerate one its vertex.
pub const EdgeRange = struct {
    edge: types.EdgeIndex,
    first: u32,
    count: u32,
    /// `c0` is a crease the viewer draws; `g1` and `g2` (a seam, a fillet's boundary) it
    /// leaves out.
    regularity: types.Regularity,
};

pub const Mesh = struct {
    positions: []Vec3,
    /// Counter-clockwise about the face's outward normal, as indices into `positions`.
    triangles: [][3]u32,
    faces: []FaceRange,
    edges: []EdgeRange,
    edge_vertices: []u32,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
        allocator.free(self.triangles);
        allocator.free(self.faces);
        allocator.free(self.edges);
        allocator.free(self.edge_vertices);
        self.* = undefined;
    }

    pub fn of(self: Mesh, range: FaceRange) []const [3]u32 {
        return self.triangles[range.first .. range.first + range.count];
    }

    pub fn verticesOf(self: Mesh, range: EdgeRange) []const u32 {
        return self.edge_vertices[range.first .. range.first + range.count];
    }
};

/// The mesh of `body` at `resolution`; owned by `allocator`. `error.LimitExceeded` for a
/// free-form edge no chord certifies. A face whose chorded outline crosses itself at the resolution (a
/// chord of an arc cutting across a hole or a neighbouring edge that the arc itself
/// clears) has its arcs' grids doubled, the mesh built again, up to
/// `edges.MAX_DOUBLINGS` times; what still fails is reported `.failed` with a warning.
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

/// How a face is meshed, by its surface: projected flat; gridded between its edges on the
/// circle grids; gridded and refined where the surface stands off the mesh.
const Kind = enum { planar, curved, free_form };

fn kindOf(surface: surfaces.Surface) Kind {
    return switch (surface) {
        .plane => .planar,
        .cylinder, .cone, .sphere, .torus => .curved,
        .extrusion, .revolution, .nurbs => .free_form,
    };
}

/// The mesh under construction: the vertices so far and one face's rings.
const Builder = struct {
    allocator: std.mem.Allocator,
    body: *const Body,
    edge_points: *const edges_mod.EdgePoints,
    positions: std.ArrayList(Vec3) = .empty,
    /// Each body vertex's mesh vertex (`NONE` when tombstoned).
    vertex_id: []u32,
    /// Where each edge's interior points start among the mesh vertices.
    interior_start: []u32,
    triangles: std.ArrayList([3]u32) = .empty,
    faces: std.ArrayList(FaceRange) = .empty,
    /// The current face's loops in UV, their mesh vertices, and where each ring starts.
    ring_uv: std.ArrayList(Vec2) = .empty,
    ring_id: std.ArrayList(u32) = .empty,
    starts: std.ArrayList(u32) = .empty,
    /// Scratch: the rings scaled near-isometric, the interior points, their mesh vertices.
    scaled: std.ArrayList(Vec2) = .empty,
    extra: std.ArrayList(Vec2) = .empty,
    extra_scaled: std.ArrayList(Vec2) = .empty,
    extra_id: std.ArrayList(u32) = .empty,
    grid_u: std.ArrayList(f64) = .empty,
    grid_v: std.ArrayList(f64) = .empty,

    fn deinit(self: *Builder) void {
        self.positions.deinit(self.allocator);
        self.triangles.deinit(self.allocator);
        self.faces.deinit(self.allocator);
        self.ring_uv.deinit(self.allocator);
        self.ring_id.deinit(self.allocator);
        self.starts.deinit(self.allocator);
        self.scaled.deinit(self.allocator);
        self.extra.deinit(self.allocator);
        self.extra_scaled.deinit(self.allocator);
        self.extra_id.deinit(self.allocator);
        self.grid_u.deinit(self.allocator);
        self.grid_v.deinit(self.allocator);
    }

    /// The face's loops as rings in UV (`ring_uv`, `ring_id`, `starts`): each coedge's
    /// points the coedge's way, its last left to the next coedge, through the pcurve at
    /// the points' parameters, or projected onto a plane; a degenerate edge (a pole, an
    /// apex) its pcurve's start, so the ring runs along the pole line. Spikes pruned,
    /// rings of fewer than three points left out, every ring counter-clockwise about the
    /// face's outward normal.
    fn collectRings(self: *Builder, f: types.FaceIndex, surface: surfaces.Surface, diag: *Diagnostics) Error!void {
        const body = self.body;
        const face = body.face(f);
        self.ring_uv.clearRetainingCapacity();
        self.ring_id.clearRetainingCapacity();
        self.starts.clearRetainingCapacity();
        try self.starts.append(self.allocator, 0);
        var loops = traverse.Loops.init(body, f);
        while (loops.next() catch return corrupt(diag)) |l| {
            const ring_start = self.ring_uv.items.len;
            var coedges = traverse.Coedges.init(body, l);
            while (coedges.next() catch return corrupt(diag)) |c| {
                const coedge = body.coedge(c);
                const e = body.edge(coedge.edge);
                if (e.flags.degenerate) {
                    if (coedge.pcurve.isNone()) continue;
                    const t = if (coedge.same_sense) e.t0 else e.t1;
                    try self.ring_uv.append(self.allocator, body.geometry.pcurve(coedge.pcurve).eval(t));
                    try self.ring_id.append(self.allocator, self.vertex_id[@backingInt(e.start)]);
                    continue;
                }
                const pts = self.edge_points.of(coedge.edge);
                const params = self.edge_points.paramsOf(coedge.edge);
                for (0..pts.len - 1) |step| {
                    const k = if (coedge.same_sense) step else pts.len - 1 - step;
                    const id = if (k == 0) self.vertex_id[@backingInt(e.start)] else if (k == pts.len - 1) self.vertex_id[@backingInt(e.end)] else self.interior_start[@backingInt(coedge.edge)] + @as(u32, @intCast(k - 1));
                    const uv = if (coedge.pcurve.isNone()) surface.project(pts[k], body.tol.approx, 50) else body.geometry.pcurve(coedge.pcurve).eval(params[k]);
                    try self.ring_uv.append(self.allocator, uv);
                    try self.ring_id.append(self.allocator, id);
                }
            }
            // A lens thinner than its chords (a line and a slight arc between two
            // vertices, the arc's polyline fallen onto the line) is a spike of no area in
            // the polygon: pruned, its area within the chords' error. A loop that is all
            // spike at this resolution is left out
            pruneSpikes(&self.ring_uv, &self.ring_id, ring_start);
            if (self.ring_uv.items.len - ring_start < 3) {
                self.ring_uv.shrinkRetainingCapacity(ring_start);
                self.ring_id.shrinkRetainingCapacity(ring_start);
                continue;
            }
            // Loops run counter-clockwise in UV about the surface's normal (`du × dv`)
            // when the outward normal is the surface's; the triangulator wants them so
            if (!face.same_sense) {
                std.mem.reverse(Vec2, self.ring_uv.items[ring_start..]);
                std.mem.reverse(u32, self.ring_id.items[ring_start..]);
            }
            try self.starts.append(self.allocator, @intCast(self.ring_uv.items.len));
        }
    }

    /// The interior points of a curved face: the tensor grid of the rings' distinct `u`
    /// and `v` values and the resolution's parameter lines (`naturalGrid`), those inside
    /// the polygon and no nearer a ring's edge than the merge tolerance (`extra`,
    /// unscaled): the grid's own lines hold the boundary's points, and two edges' ends
    /// agree only to rounding (a seam's end parameter against a circle's pcurve height),
    /// so a candidate a few ulps inside an edge is the boundary's, not a sliver's.
    fn collectInterior(self: *Builder, surface: surfaces.Surface, box: geometry.Box2, resolution: tolerance.Resolution, scale: Vec2, diag: *Diagnostics) Error!void {
        self.extra.clearRetainingCapacity();
        self.grid_u.clearRetainingCapacity();
        self.grid_v.clearRetainingCapacity();
        for (self.ring_uv.items) |uv| {
            try self.grid_u.append(self.allocator, uv[0]);
            try self.grid_v.append(self.allocator, uv[1]);
        }
        try naturalGrid(self.allocator, surface, box, resolution, &self.grid_u, &self.grid_v, diag);
        distinct(&self.grid_u);
        distinct(&self.grid_v);
        const polygon: triangulate.Polygon = .{ .points = self.scaled.items, .starts = self.starts.items };
        var extent = geometry.Box2.empty;
        for (self.scaled.items) |p| extent.grow(p);
        const near = GRID_MERGE * vec.distance2(extent.min, extent.max);
        for (self.grid_u.items) |u| {
            for (self.grid_v.items) |v| {
                if (!inside(polygon, .{ u * scale[0], v * scale[1] }, near)) continue;
                try self.extra.append(self.allocator, .{ u, v });
            }
        }
    }

    /// The mesh vertex of triangle corner `index` of the current face: a ring's point, or
    /// an interior point of `surface`, evaluated and added on first use.
    fn vertexOf(self: *Builder, index: u32, surface: surfaces.Surface) Error!u32 {
        const n_ring: u32 = @intCast(self.ring_id.items.len);
        if (index < n_ring) return self.ring_id.items[index];
        const k = index - n_ring;
        if (self.extra_id.items[k] == NONE) {
            self.extra_id.items[k] = @intCast(self.positions.items.len);
            const uv = self.extra.items[k];
            try self.positions.append(self.allocator, surface.eval(uv[0], uv[1]));
        }
        return self.extra_id.items[k];
    }

    /// Triangulates the current face's rings (with `extra` interior points when curved)
    /// and appends its triangles, turned to the face's outward normal; a triangle with two
    /// corners at one mesh vertex (along a pole) is dropped. A free-form face (an
    /// extrusion, a revolution, a NURBS patch, whose grid is the knots' and the generator's
    /// chords) is refined where a link's or a triangle's midpoint on the surface stands off
    /// the mesh by more than a chord of that length may bow: the midpoint joins the
    /// interior points and the face is triangulated again, `MAX_REFINE_ROUNDS` times at
    /// most and `MAX_FACE_POINTS` points at most. The face's range.
    fn meshFace(self: *Builder, f: types.FaceIndex, kind: Kind, surface: surfaces.Surface, scale: Vec2, resolution: tolerance.Resolution, diag: *Diagnostics) Error!FaceRange {
        const face = self.body.face(f);
        const first: u32 = @intCast(self.triangles.items.len);
        if (self.starts.items.len < 2) return .{ .face = f, .first = first, .count = 0, .status = .ok };
        const points = if (kind == .planar) self.ring_uv.items else self.scaled.items;
        const polygon: triangulate.Polygon = .{ .points = points, .starts = self.starts.items };
        var round: usize = 0;
        while (true) : (round += 1) {
            self.extra_scaled.clearRetainingCapacity();
            for (self.extra.items) |uv| try self.extra_scaled.append(self.allocator, .{ uv[0] * scale[0], uv[1] * scale[1] });
            try self.extra_id.resize(self.allocator, self.extra.items.len);
            @memset(self.extra_id.items, NONE);
            var face_diag = Diagnostics.init(self.allocator);
            defer face_diag.deinit();
            const local = triangulate.triangulateWith(self.allocator, polygon, self.extra_scaled.items, &face_diag) catch |err| switch (err) {
                error.InvalidInput, error.LimitExceeded => {
                    const code = if (face_diag.first()) |finding| finding.code else .not_simple;
                    try diag.warn(.{ .code = code, .entity = .of(.face, @backingInt(f)), .label = "a face's polygon" });
                    try self.fanFill(face.same_sense);
                    return .{ .face = f, .first = first, .count = @intCast(self.triangles.items.len - first), .status = .failed, .reason = code };
                },
                else => return err,
            };
            defer self.allocator.free(local);
            if (kind == .free_form and round < MAX_REFINE_ROUNDS and self.extra.items.len + self.ring_uv.items.len < MAX_FACE_POINTS) {
                if (try self.refineWhereOff(local, surface, resolution, scale)) continue;
            }
            for (local) |t| {
                const a = try self.vertexOf(t[0], surface);
                const b = try self.vertexOf(t[1], surface);
                const c = try self.vertexOf(t[2], surface);
                if (a == b or b == c or a == c) continue;
                // Counter-clockwise in UV is about the surface's normal: turned over when
                // the face's outward normal is its opposite
                try self.triangles.append(self.allocator, if (face.same_sense) .{ a, b, c } else .{ a, c, b });
            }
            return .{ .face = f, .first = first, .count = @intCast(self.triangles.items.len - first), .status = .ok };
        }
    }

    /// The UV of triangle corner `index` of the current face, unscaled.
    fn uvOf(self: *const Builder, index: u32) Vec2 {
        const n_ring: u32 = @intCast(self.ring_uv.items.len);
        return if (index < n_ring) self.ring_uv.items[index] else self.extra.items[index - n_ring];
    }

    /// Adds to `extra` the UV midpoint of every link, and the centroid of every triangle,
    /// whose point on the surface stands off the mesh by more than a chord of its length
    /// may bow (`Resolution.chordBow`); whether any was added. A midpoint on or near a
    /// ring's edge is the boundary's (its edge was cut by its own certified chords).
    fn refineWhereOff(self: *Builder, local: []const [3]u32, surface: surfaces.Surface, resolution: tolerance.Resolution, scale: Vec2) Error!bool {
        const before = self.extra.items.len;
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(self.allocator);
        const polygon: triangulate.Polygon = .{ .points = self.scaled.items, .starts = self.starts.items };
        var extent = geometry.Box2.empty;
        for (self.scaled.items) |p| extent.grow(p);
        const near = GRID_MERGE * vec.distance2(extent.min, extent.max);
        for (local) |t| {
            var corners: [3]Vec3 = undefined;
            var uvs: [3]Vec2 = undefined;
            for (0..3) |k| {
                uvs[k] = self.uvOf(t[k]);
                corners[k] = surface.eval(uvs[k][0], uvs[k][1]);
            }
            for (0..3) |k| {
                const i = t[k];
                const j = t[(k + 1) % 3];
                const key = (@as(u64, @min(i, j)) << 32) | @max(i, j);
                if ((try seen.getOrPut(self.allocator, key)).found_existing) continue;
                const mid_uv = vec.lerp2(uvs[k], uvs[(k + 1) % 3], 0.5);
                const chord = vec.distance(corners[k], corners[(k + 1) % 3]);
                const off = vec.distance(surface.eval(mid_uv[0], mid_uv[1]), vec.lerp(corners[k], corners[(k + 1) % 3], 0.5));
                if (off > resolution.chordBow(chord) and inside(polygon, .{ mid_uv[0] * scale[0], mid_uv[1] * scale[1] }, near)) try self.extra.append(self.allocator, mid_uv);
            }
            const centre_uv = vec.scale2(vec.add2(vec.add2(uvs[0], uvs[1]), uvs[2]), 1.0 / 3.0);
            const centre = vec.scale(vec.add(vec.add(corners[0], corners[1]), corners[2]), 1.0 / 3.0);
            const longest = @max(vec.distance(corners[0], corners[1]), @max(vec.distance(corners[1], corners[2]), vec.distance(corners[2], corners[0])));
            const off = vec.distance(surface.eval(centre_uv[0], centre_uv[1]), centre);
            if (off > resolution.chordBow(longest) and inside(polygon, .{ centre_uv[0] * scale[0], centre_uv[1] * scale[1] }, near)) try self.extra.append(self.allocator, centre_uv);
        }
        return self.extra.items.len > before;
    }

    /// The lenient fill of a face the triangulator refused: a fan of its outer ring from
    /// its first point (the holes left out; the triangles may overlap where the ring
    /// bends in), so the picture has no hole where the defect is.
    fn fanFill(self: *Builder, same_sense: bool) Error!void {
        const ids = self.ring_id.items[self.starts.items[0]..self.starts.items[1]];
        for (1..ids.len - 1) |i| {
            const a = ids[0];
            const b = ids[i];
            const c = ids[i + 1];
            if (a == b or b == c or a == c) continue;
            try self.triangles.append(self.allocator, if (same_sense) .{ a, b, c } else .{ a, c, b });
        }
    }
};

fn build(allocator: std.mem.Allocator, body: *const Body, resolution: tolerance.Resolution, doublings: []const u8, options: diagnostics.Options, diag: *Diagnostics) Error!Mesh {
    var edge_points = try edges_mod.discretizeRefined(allocator, body, resolution, doublings, diag);
    defer edge_points.deinit(allocator);

    const vertex_id = try allocator.alloc(u32, body.vertices.items.len);
    defer allocator.free(vertex_id);
    const interior_start = try allocator.alloc(u32, body.edges.items.len);
    defer allocator.free(interior_start);
    var b: Builder = .{ .allocator = allocator, .body = body, .edge_points = &edge_points, .vertex_id = vertex_id, .interior_start = interior_start };
    defer b.deinit();

    // Mesh vertices: the body's vertices first, then each edge's interior points
    for (body.vertices.items, vertex_id) |v, *id| {
        id.* = if (v.tombstone) NONE else @intCast(b.positions.items.len);
        if (!v.tombstone) try b.positions.append(allocator, body.geometry.point(v.point));
    }
    for (body.edges.items, 0..) |e, i| {
        interior_start[i] = @intCast(b.positions.items.len);
        if (e.flags.tombstone or e.flags.degenerate) continue;
        const pts = edge_points.of(types.EdgeIndex.of(i));
        try b.positions.appendSlice(allocator, pts[1 .. pts.len - 1]);
    }
    // The edges' polylines, as those vertices
    var edge_ranges: std.ArrayList(EdgeRange) = .empty;
    errdefer edge_ranges.deinit(allocator);
    var edge_vertices: std.ArrayList(u32) = .empty;
    errdefer edge_vertices.deinit(allocator);
    for (body.edges.items, 0..) |e, i| {
        const first: u32 = @intCast(edge_vertices.items.len);
        if (!e.flags.tombstone) {
            try edge_vertices.append(allocator, vertex_id[@backingInt(e.start)]);
            if (!e.flags.degenerate) {
                const n_inside = edge_points.of(types.EdgeIndex.of(i)).len - 2;
                for (0..n_inside) |k| try edge_vertices.append(allocator, interior_start[i] + @as(u32, @intCast(k)));
                try edge_vertices.append(allocator, vertex_id[@backingInt(e.end)]);
            }
        }
        try edge_ranges.append(allocator, .{ .edge = types.EdgeIndex.of(i), .first = first, .count = @intCast(edge_vertices.items.len - first), .regularity = e.regularity });
    }

    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        var it = traverse.Faces.init(body, s);
        while (it.next() catch return corrupt(diag)) |f| {
            try options.checkCancel();
            const face = body.face(f);
            const surface = body.geometry.surface(face.surface);
            const kind = kindOf(surface);
            try b.collectRings(f, surface, diag);
            var scale = Vec2{ 1, 1 };
            b.extra.clearRetainingCapacity();
            if (kind != .planar) {
                scale = isometricScale(surface, face.uv_box);
                b.scaled.clearRetainingCapacity();
                for (b.ring_uv.items) |uv| try b.scaled.append(allocator, .{ uv[0] * scale[0], uv[1] * scale[1] });
                if (b.starts.items.len >= 2) try b.collectInterior(surface, face.uv_box, resolution, scale, diag);
            }
            const range = try b.meshFace(f, kind, surface, scale, resolution, diag);
            try b.faces.append(allocator, range);
        }
    }
    const owned_positions = try b.positions.toOwnedSlice(allocator);
    errdefer allocator.free(owned_positions);
    const owned_triangles = try b.triangles.toOwnedSlice(allocator);
    errdefer allocator.free(owned_triangles);
    const owned_faces = try b.faces.toOwnedSlice(allocator);
    errdefer allocator.free(owned_faces);
    const owned_edges = try edge_ranges.toOwnedSlice(allocator);
    errdefer allocator.free(owned_edges);
    return .{ .positions = owned_positions, .triangles = owned_triangles, .faces = owned_faces, .edges = owned_edges, .edge_vertices = try edge_vertices.toOwnedSlice(allocator) };
}

/// The factors that make the face's UV near-isometric: the lengths of the surface's
/// derivatives at the middle of its UV box (on a cylinder `u` is radians, so `r`; on a
/// sphere `u` shrinks towards the poles, so the parallel's radius at mid-latitude), or
/// at a corner of the box where the middle is a pole; one where neither helps.
fn isometricScale(surface: surfaces.Surface, box: geometry.Box2) Vec2 {
    if (box.isEmpty()) return .{ 1, 1 };
    const mid = Vec2{ (box.min[0] + box.max[0]) / 2.0, (box.min[1] + box.max[1]) / 2.0 };
    var scale = derivativeLengths(surface, mid);
    const corners = [4]Vec2{ box.min, .{ box.max[0], box.min[1] }, box.max, .{ box.min[0], box.max[1] } };
    for (corners) |corner| {
        if (scale[0] > 0 and scale[1] > 0) break;
        const at = derivativeLengths(surface, corner);
        if (scale[0] == 0) scale[0] = at[0];
        if (scale[1] == 0) scale[1] = at[1];
    }
    return .{ if (scale[0] > 0) scale[0] else 1, if (scale[1] > 0) scale[1] else 1 };
}

/// The resolution's own parameter lines across `box`, appended to `grid_u` and `grid_v`:
/// in a direction that runs around a circle (`u` on every analytic curved kind and on a
/// revolution; `v` on a sphere, a meridian, and on a torus, the tube) the grid a full
/// circle of that direction's largest radius gets, `segmentsFor(r)` equal steps from
/// angle 0 (`edges.zig` cuts the edges on it, so a boundary along such a circle lies on
/// these lines), strictly inside the box; along a generator curve (an extrusion's `u`, a
/// revolution's `v`) the curve's certified chords (`chords.zig`, as its edges are cut);
/// on a NURBS patch the knots; none along a straight direction (a cylinder's or a cone's
/// `v`, an extrusion's `v`).
fn naturalGrid(allocator: std.mem.Allocator, surface: surfaces.Surface, box: geometry.Box2, resolution: tolerance.Resolution, grid_u: *std.ArrayList(f64), grid_v: *std.ArrayList(f64), diag: *Diagnostics) Error!void {
    if (box.isEmpty()) return;
    switch (surface) {
        .extrusion => |s| if (box.max[0] > box.min[0]) try chords.sampleParams(allocator, s.curve, box.min[0], box.max[0], resolution, grid_u, diag, .none),
        .revolution => |s| if (box.max[1] > box.min[1]) try chords.sampleParams(allocator, s.curve, box.min[1], box.max[1], resolution, grid_v, diag, .none),
        .nurbs => |s| {
            for (s.knots_u) |k| if (k > box.min[0] and k < box.max[0]) try grid_u.append(allocator, k);
            for (s.knots_v) |k| if (k > box.min[1] and k < box.max[1]) try grid_v.append(allocator, k);
        },
        else => {},
    }
    const radii: [2]f64 = switch (surface) {
        .cylinder => |s| .{ s.r, 0 },
        .cone => |s| .{ @max(@abs(s.radiusAt(box.min[1])), @abs(s.radiusAt(box.max[1]))), 0 },
        .sphere => |s| .{ s.r, s.r },
        .torus => |s| .{ s.major + s.minor, s.minor },
        .revolution => |s| .{ farthestFromAxis(s, box), 0 },
        .plane, .extrusion, .nurbs => .{ 0, 0 },
    };
    for (radii, [2]*std.ArrayList(f64){ grid_u, grid_v }, 0..) |r, grid, axis| {
        if (!(r > 0)) continue;
        const step = TWO_PI / @as(f64, @floatFromInt(resolution.segmentsFor(r)));
        const lo = box.min[axis];
        const hi = box.max[axis];
        const first: i64 = @intFromFloat(@floor(lo / step));
        const last: i64 = @intFromFloat(@ceil(hi / step));
        var k = first;
        while (k <= last) : (k += 1) {
            const angle = @as(f64, @floatFromInt(k)) * step;
            if (angle > lo and angle < hi) try grid.append(allocator, angle);
        }
    }
}

/// How far the revolution's generator reaches from its axis over the box's `v` range: the
/// farthest corner of the generator's bounding box.
fn farthestFromAxis(s: surfaces.Revolution, box: geometry.Box2) f64 {
    const gen = s.curve.bounds(box.min[1], box.max[1]);
    if (gen.isEmpty()) return 0;
    var rho: f64 = 0;
    for ([_]f64{ gen.min[0], gen.max[0] }) |x| {
        for ([_]f64{ gen.min[1], gen.max[1] }) |y| {
            for ([_]f64{ gen.min[2], gen.max[2] }) |z| {
                const l = s.frame.toLocal(.{ x, y, z });
                rho = @max(rho, @sqrt(l[0] * l[0] + l[1] * l[1]));
            }
        }
    }
    return rho;
}

fn derivativeLengths(surface: surfaces.Surface, uv: Vec2) Vec2 {
    const s = surface.sample(uv[0], uv[1]);
    const du = vec.length(s.du);
    const dv = vec.length(s.dv);
    return .{ if (std.math.isFinite(du)) du else 0, if (std.math.isFinite(dv)) dv else 0 };
}

/// Sorts `values` and keeps one of each run of values within `GRID_MERGE` of their span.
fn distinct(values: *std.ArrayList(f64)) void {
    const items = values.items;
    if (items.len == 0) return;
    std.mem.sort(f64, items, {}, std.sort.asc(f64));
    const merge = GRID_MERGE * @max(items[items.len - 1] - items[0], 0);
    var kept: usize = 1;
    for (items[1..]) |x| {
        if (x - items[kept - 1] <= merge) continue;
        items[kept] = x;
        kept += 1;
    }
    values.shrinkRetainingCapacity(kept);
}

/// Whether `p` is inside the polygon by the even-odd rule along a ray to +x, and farther
/// than `near` from every ring's edge.
fn inside(polygon: triangulate.Polygon, p: Vec2, near: f64) bool {
    var crossings: usize = 0;
    for (0..polygon.rings()) |r| {
        const ring = polygon.ring(r);
        for (ring, 0..) |a, i| {
            const b = ring[(i + 1) % ring.len];
            if (segmentDistanceSq(a, b, p) <= near * near) return false;
            if ((a[1] > p[1]) == (b[1] > p[1])) continue;
            const x = a[0] + (p[1] - a[1]) / (b[1] - a[1]) * (b[0] - a[0]);
            if (x > p[0]) crossings += 1;
        }
    }
    return crossings % 2 == 1;
}

/// The squared distance from `p` to the segment `a b`.
fn segmentDistanceSq(a: Vec2, b: Vec2, p: Vec2) f64 {
    const ab = vec.sub2(b, a);
    const len_sq = vec.lengthSq2(ab);
    const t = if (len_sq > 0) std.math.clamp(vec.dot2(vec.sub2(p, a), ab) / len_sq, 0, 1) else 0;
    return vec.distanceSq2(p, vec.addScaled2(a, ab, t));
}

/// Removes every spike from the ring at `start`: a point whose neighbours are one mesh
/// vertex goes with the step back, again until none is left (a spike of several steps
/// shrinks from its tip).
fn pruneSpikes(ring_uv: *std.ArrayList(Vec2), ring_id: *std.ArrayList(u32), start: usize) void {
    var pruned = true;
    while (pruned) {
        pruned = false;
        const ids = ring_id.items[start..];
        const n = ids.len;
        if (n < 3) return;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const before = ids[(i + n - 1) % n];
            const after = ids[(i + 1) % n];
            if (before != after) continue;
            // Drop the tip `i` and the step back to `before`: the later index first
            const tip = start + i;
            const back = start + (i + 1) % n;
            const hi = @max(tip, back);
            const lo = @min(tip, back);
            _ = ring_uv.orderedRemove(hi);
            _ = ring_id.orderedRemove(hi);
            _ = ring_uv.orderedRemove(lo);
            _ = ring_id.orderedRemove(lo);
            pruned = true;
            break;
        }
    }
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
