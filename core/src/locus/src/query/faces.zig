//! A solid's faces by the way they face (docs/architecture.md §7.6; KupCAD's `on_face`):
//! the planar faces whose outward normal is the direction's within the body's angle
//! tolerance, the farthest along it first, each with its exact area and area centroid
//! (Green's theorem over its loops in the plane's coordinates, each edge by Gauss–Legendre
//! quadrature: exact for lines, to rounding for arcs and ellipses, to the rule for NURBS)
//! and its tag. A curved face has no one normal and is never matched.

const std = @import("std");
const vec = @import("../math/vec.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const mass = @import("../measure/mass.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const Match = struct {
    face: types.FaceIndex,
    /// The face's outward normal.
    normal: Vec3,
    /// The centroid of its area.
    centroid: Vec3,
    area: f64,
    /// How far along the direction its plane lies (the centroid's dot with it).
    depth: f64,
    tag: types.Tag,

    fn farther(_: void, a: Match, b: Match) bool {
        return a.depth > b.depth or (a.depth == b.depth and @backingInt(a.face) < @backingInt(b.face));
    }
};

/// The planar faces of `body` facing `direction` (any length), farthest first, ties by
/// face index. Owned by `allocator`.
pub fn byDirection(allocator: std.mem.Allocator, body: *const Body, direction: Vec3, diag: *Diagnostics) Error![]Match {
    const d = vec.normalized(direction) orelse return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the direction's length" });
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(allocator);
    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        var it = traverse.Faces.init(body, s);
        while (it.next() catch return corrupt(diag)) |f| {
            const face = body.face(f);
            if (face.surface.kind != .plane) continue;
            const plane = body.geometry.surface(face.surface).plane;
            const n0 = plane.normal(0, 0);
            const normal = if (face.same_sense) n0 else vec.neg(n0);
            if (1 - vec.dot(normal, d) > body.tol.angle) continue;
            const moments = try planarMoments(body, f, diag);
            if (moments.area == 0) continue;
            const uv: Vec2 = .{ moments.u / moments.area, moments.v / moments.area };
            const centroid = plane.eval(uv[0], uv[1]);
            try out.append(allocator, .{ .face = f, .normal = normal, .centroid = centroid, .area = @abs(moments.area), .depth = vec.dot(centroid, d), .tag = face.tag });
        }
    }
    std.mem.sort(Match, out.items, {}, Match.farther);
    return out.toOwnedSlice(allocator);
}

/// A planar face's signed area and first moments in its plane's coordinates: `A = ½∮(u dv −
/// v du)`, `∬u = ∮ u²/2 dv`, `∬v = −∮ v²/2 du` (Green), over every loop the way it runs, so
/// holes subtract; the signs cancel in the centroid whichever way the plane faces.
const Moments = struct { area: f64, u: f64, v: f64 };

fn planarMoments(body: *const Body, f: types.FaceIndex, diag: *Diagnostics) Error!Moments {
    const plane = body.geometry.surface(body.face(f).surface).plane;
    var m: Moments = .{ .area = 0, .u = 0, .v = 0 };
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const coedge = body.coedge(c);
            const edge = body.edge(coedge.edge);
            if (edge.flags.degenerate) continue;
            const curve = body.geometry.curve(edge.curve);
            const from = if (coedge.same_sense) edge.t0 else edge.t1;
            const to = if (coedge.same_sense) edge.t1 else edge.t0;
            const step = (to - from) / @as(f64, @floatFromInt(mass.EDGE_SPANS));
            for (0..mass.EDGE_SPANS) |k| {
                const a = from + step * @as(f64, @floatFromInt(k));
                for (mass.GAUSS_10.nodes, mass.GAUSS_10.weights) |x, w| {
                    const t = a + step * (x + 1) / 2;
                    const s = curve.sample(t);
                    const p = plane.project(s.p);
                    // The tangent in the plane's coordinates: the frame's axes' components
                    const dp: Vec2 = .{ vec.dot(s.d1, plane.frame.x), vec.dot(s.d1, plane.frame.y) };
                    const weight = w * step / 2;
                    m.area += weight * 0.5 * (p[0] * dp[1] - p[1] * dp[0]);
                    m.u += weight * 0.5 * p[0] * p[0] * dp[1];
                    m.v -= weight * 0.5 * p[1] * p[1] * dp[0];
                }
            }
        }
    }
    return m;
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
