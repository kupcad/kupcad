//! A face's edges in trees, for the questions a boolean asks of one face many times
//! (`boolean/pave.zig`'s `placeIn`): the distance from a point to the face's boundary, when
//! within a reach, and where a point of a planar face with straight edges lies by the exact
//! crossing count of `in_face`. The same answers as `in_face`'s scans of every edge, from the
//! edges a tree finds near the point or across the point's ray: an edge farther than the
//! reach has a box, grown by it, that does not hold the point; an edge the ray from the
//! point to +x crosses spans the point's height and reaches east of it. Each query is then
//! logarithmic in the face's edges (two 1000-sided prisms whose ends lie in one plane asked
//! a scan of every edge for each of thousands of points, most of the union's second,
//! 2026-11-14).

const std = @import("std");
const vec = @import("../math/vec.zig");
const ray_crossing = @import("../math/ray_crossing.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const bvh_mod = @import("../spatial/bvh.zig");
const in_face = @import("in_face.zig");
const Body = body_mod.Body;
const Box3 = geometry.Box3;
const Bvh = bvh_mod.Bvh;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// The edges past which a face is worth its trees: below, a scan of its edges is as quick.
pub const INDEXED_AT_LEAST = 32;

/// How far east a crossing ray's box reaches: past any coordinate a face holds (the scale
/// guard keeps them far below it).
const EAST: f64 = std.math.floatMax(f64) / 4;

pub const FaceEdges = struct {
    face: types.FaceIndex,
    /// The face's coedges' edges, in its loops' order, and its loops' lone vertices.
    edges: []types.EdgeIndex,
    lone: []types.VertexIndex,
    /// Each edge's box grown by `reach`, the farthest a distance query may ask.
    near: Bvh,
    reach: f64,
    /// A planar face with straight edges: its plane's frame, and each coedge's segment in
    /// it (start to end, the coedge's way), in a tree by their boxes in the plane.
    flat: ?Flat,

    const Flat = struct {
        frame: geometry.Frame,
        segments: [][2]Vec2,
        tree: Bvh,
    };

    /// Face `f` of `body`'s edges in trees, distances asked within `reach` at most.
    pub fn build(allocator: std.mem.Allocator, body: *const Body, f: types.FaceIndex, reach: f64, diag: *Diagnostics) Error!FaceEdges {
        var edges: std.ArrayList(types.EdgeIndex) = .empty;
        defer edges.deinit(allocator);
        var lone: std.ArrayList(types.VertexIndex) = .empty;
        defer lone.deinit(allocator);
        var boxes: std.ArrayList(Box3) = .empty;
        defer boxes.deinit(allocator);
        var segments: std.ArrayList([2]Vec2) = .empty;
        defer segments.deinit(allocator);
        var flat_boxes: std.ArrayList(Box3) = .empty;
        defer flat_boxes.deinit(allocator);
        const face = body.face(f);
        var planar = face.surface.kind == .plane;
        const frame = if (planar) body.geometry.planes.items[face.surface.index].frame else undefined;
        var loops = traverse.Loops.init(body, f);
        while (loops.next() catch return corrupt(diag)) |l| {
            if (body.loop(l).vertex != .none) try lone.append(allocator, body.loop(l).vertex);
            var it = traverse.Coedges.init(body, l);
            while (it.next() catch return corrupt(diag)) |c| {
                const e = body.coedge(c).edge;
                try edges.append(allocator, e);
                try boxes.append(allocator, edgeBox(body, e).inflated(reach));
                if (!planar) continue;
                if (body.edge(e).curve.kind != .line) {
                    planar = false;
                    continue;
                }
                const a3 = frame.toLocal(body.point(body.coedgeStart(c)));
                const b3 = frame.toLocal(body.point(body.coedgeEnd(c)));
                const a: Vec2 = .{ a3[0], a3[1] };
                const b: Vec2 = .{ b3[0], b3[1] };
                try segments.append(allocator, .{ a, b });
                var box = Box3.ofPoint(.{ a[0], a[1], 0 });
                box.grow(.{ b[0], b[1], 0 });
                try flat_boxes.append(allocator, box);
            }
        }
        var near = try Bvh.build(allocator, boxes.items);
        errdefer near.deinit(allocator);
        var flat: ?Flat = null;
        if (planar) {
            var tree = try Bvh.build(allocator, flat_boxes.items);
            errdefer tree.deinit(allocator);
            flat = .{ .frame = frame, .segments = try segments.toOwnedSlice(allocator), .tree = tree };
        }
        errdefer if (flat) |*fl| {
            allocator.free(fl.segments);
            fl.tree.deinit(allocator);
        };
        const owned_edges = try edges.toOwnedSlice(allocator);
        errdefer allocator.free(owned_edges);
        return .{ .face = f, .edges = owned_edges, .lone = try lone.toOwnedSlice(allocator), .near = near, .reach = reach, .flat = flat };
    }

    pub fn deinit(self: *FaceEdges, allocator: std.mem.Allocator) void {
        allocator.free(self.edges);
        allocator.free(self.lone);
        self.near.deinit(allocator);
        if (self.flat) |*fl| {
            allocator.free(fl.segments);
            fl.tree.deinit(allocator);
        }
        self.* = undefined;
    }

    /// The distance from `p` to the face's boundary when within `within` (at most the
    /// trees' reach), else infinity: `in_face.boundaryDistance`'s answer wherever that is
    /// within `within`.
    pub fn boundaryDistance(self: *const FaceEdges, body: *const Body, p: Vec3, within: f64) f64 {
        std.debug.assert(within <= self.reach);
        var nearest = std.math.inf(f64);
        for (self.lone) |v| nearest = @min(nearest, vec.distance(body.point(v), p));
        var search: Search = .{ .self = self, .body = body, .p = p };
        self.near.query(Box3.ofPoint(p), &search, Search.visit);
        nearest = @min(nearest, search.nearest);
        return if (nearest <= within) nearest else std.math.inf(f64);
    }

    const Search = struct {
        self: *const FaceEdges,
        body: *const Body,
        p: Vec3,
        nearest: f64 = std.math.inf(f64),
        fn visit(s: *@This(), item: u32) bool {
            s.nearest = @min(s.nearest, in_face.edgeDistance(s.body, s.self.edges[item], s.p));
            return true;
        }
    };

    /// Where `p` (on the face's surface, at `uv`) lies: `in_face.classify(.., 0)`'s answer,
    /// on the boundary only exactly on an edge, else by the crossing count over the edges
    /// the ray from `uv` to +x may cross; a face not planar with straight edges by
    /// `in_face`'s own scan.
    pub fn classify(self: *const FaceEdges, body: *const Body, p: Vec3, uv: Vec2, diag: *Diagnostics) Error!in_face.Place {
        const fl = self.flat orelse return in_face.classify(body, self.face, p, uv, 0, diag);
        if (self.boundaryDistance(body, p, 0) == 0) return .boundary;
        var ray: Ray = .{ .segments = fl.segments, .uv = uv };
        var box = Box3.ofPoint(.{ uv[0], uv[1], 0 });
        box.grow(.{ EAST, uv[1], 0 });
        fl.tree.query(box, &ray, Ray.visit);
        return if (ray.inside and !ray.on) .inside else .outside;
    }

    /// `in_face`'s exact crossing count, over the segments the tree gives (each segment
    /// through `uv` among them), and whether `uv` lies on one (outside, as `in_face` has it).
    const Ray = struct {
        segments: [][2]Vec2,
        uv: Vec2,
        inside: bool = false,
        on: bool = false,
        fn visit(r: *@This(), item: u32) bool {
            const s = r.segments[item];
            if (ray_crossing.onSegment(s[0], s[1], r.uv)) {
                r.on = true;
                return false;
            }
            if (ray_crossing.line(s[0], s[1], r.uv)) r.inside = !r.inside;
            return true;
        }
    };
};

/// Edge `e`'s box: its curve's bounds over its range, with its ends (a degenerate edge's
/// range is a point).
fn edgeBox(body: *const Body, e: types.EdgeIndex) Box3 {
    const edge = body.edge(e);
    var box = body.geometry.curve(edge.curve).bounds(edge.t0, edge.t1);
    box.grow(body.point(edge.start));
    box.grow(body.point(edge.end));
    return box;
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
