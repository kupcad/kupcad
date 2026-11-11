//! A segment cast at a solid (docs/architecture.md §7.6): where it crosses the boundary,
//! nearest first, each crossing's point, outward normal and sign (+1 into the solid, −1
//! out of it), so that summed along the segment the signs say how much deeper inside its
//! end is than its origin (KupCAD's `ray_cast`).
//!
//! The candidates: for every face whose box the segment meets (`index.zig`'s BVH), the
//! segment's meetings with the face's surface, in closed form for a plane, a cylinder, a
//! cone, a sphere and a torus (the roots of a polynomial of degree 1, 2 or 4 in the
//! parameter along the segment, `math/poly.zig`, measured from the segment's point nearest
//! the surface's centre or axis so the coefficients don't cancel; a critical point where
//! the segment comes within the zone of the surface is a tangency), by Newton on
//! `S(u, v) = O + t·d` from a grid of seeds over the face's UV box for a swept or NURBS
//! surface (every root found is verified, a grazing pair between two seeds may be
//! missed: the free-form kinds are sampled, the analytic ones are not); each meeting kept
//! when it lies in the face or on its boundary (`in_face.zig`).
//!
//! The crossings: candidates within the zone of one another are one place. A place that
//! is one candidate strictly inside its face, the segment not tangent there, crosses by
//! the sign of its normal against the segment. Any other (an edge, a vertex, a tangency)
//! is decided by what is on either side: the points halfway to the neighbouring places
//! are classified (`point_in_body.zig`), and the difference is the crossing; no
//! difference is a touch, reported as an entry and an exit at the same distance, which
//! cancel (as the mesh engine reports a grazed corner).

const std = @import("std");
const vec = @import("../math/vec.zig");
const poly = @import("../math/poly.zig");
const solve = @import("../math/solve.zig");
const geometry = @import("../geometry/types.zig");
const surfaces = @import("../geometry/surfaces.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const bvh_mod = @import("../spatial/bvh.zig");
const index_mod = @import("index.zig");
const in_face = @import("in_face.zig");
const point_in_body = @import("point_in_body.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Box3 = geometry.Box3;
const FaceIndex = index_mod.FaceIndex;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// A crossing is clean when the segment meets the surface no closer to tangent than this
/// (the cosine between the segment and the normal).
pub const CLEAN_COSINE: f64 = 1e-6;
/// Seeds per side of a free-form face's UV box.
const FREE_FORM_GRID: usize = 16;
/// How far beyond its corners' box a free-form cell may bulge, as a share of its size.
const CELL_BULGE: f64 = 0.5;
/// How far from a place a sample point stands when there is no neighbouring place on
/// that side, in zones.
const SIDE_STEP_ZONES: f64 = 16;
/// Newton steps polishing a free-form root to the last bits after Levenberg–Marquardt.
const POLISH_STEPS: usize = 4;

pub const Hit = struct {
    /// Along the segment from its origin, in its units.
    t: f64,
    point: Vec3,
    /// The face's outward normal there.
    normal: Vec3,
    /// +1 into the solid, −1 out of it.
    crossing: i32,
    face: types.FaceIndex,
};

/// A meeting of the segment with a face (its surface, in the face or on its boundary).
pub const Candidate = struct {
    t: f64,
    face: types.FaceIndex,
    place: in_face.Place,
    normal: Vec3,
    /// The normal against the segment's direction.
    cosine: f64,

    fn lessThan(_: void, a: Candidate, b: Candidate) bool {
        return a.t < b.t;
    }

    fn isClean(self: Candidate) bool {
        return self.place == .inside and @abs(self.cosine) > CLEAN_COSINE;
    }
};

/// The crossings of the segment from `origin` to `end` with `body`'s boundary, nearest
/// first. Owned by `allocator`.
pub fn cast(allocator: std.mem.Allocator, body: *const Body, index: *const FaceIndex, origin: Vec3, end: Vec3, options: diagnostics.Options, diag: *Diagnostics) Error![]Hit {
    try options.checkCancel();
    const length = vec.distance(origin, end);
    const dir = vec.normalized(vec.sub(end, origin)) orelse return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the segment's length" });
    const zone = body.tol.zone;
    var found: std.ArrayList(Candidate) = .empty;
    defer found.deinit(allocator);
    try candidates(allocator, body, index, origin, dir, -zone, length + zone, &found, diag);
    std.mem.sort(Candidate, found.items, {}, Candidate.lessThan);

    // The places: runs of candidates within the zone of one another
    var places: std.ArrayList([]const Candidate) = .empty;
    defer places.deinit(allocator);
    var start: usize = 0;
    for (found.items, 0..) |c, i| {
        if (i > start and c.t - found.items[i - 1].t > zone) {
            try places.append(allocator, found.items[start..i]);
            start = i;
        }
    }
    if (start < found.items.len) try places.append(allocator, found.items[start..]);

    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(allocator);
    for (places.items, 0..) |place, k| {
        const t = std.math.clamp(place[0].t, 0, length);
        const point = vec.addScaled(origin, dir, t);
        if (place.len == 1 and place[0].isClean()) {
            try hits.append(allocator, .{ .t = t, .point = point, .normal = place[0].normal, .crossing = if (place[0].cosine < 0) 1 else -1, .face = place[0].face });
            continue;
        }
        // Decided by the sides: halfway to the neighbouring places, or a step out
        const before_t = if (k > 0) (places.items[k - 1][0].t + place[0].t) / 2 else place[0].t - SIDE_STEP_ZONES * zone;
        const after_t = if (k + 1 < places.items.len) (place[0].t + places.items[k + 1][0].t) / 2 else place[0].t + SIDE_STEP_ZONES * zone;
        const before = try side(allocator, body, index, vec.addScaled(origin, dir, before_t), options, diag);
        const after = try side(allocator, body, index, vec.addScaled(origin, dir, after_t), options, diag);
        const change = after - before;
        // The normal of the candidate the segment meets most squarely the right way
        var entering = place[0];
        var leaving = place[0];
        for (place) |c| {
            if (c.cosine < entering.cosine) entering = c;
            if (c.cosine > leaving.cosine) leaving = c;
        }
        if (change > 0) {
            try hits.append(allocator, .{ .t = t, .point = point, .normal = entering.normal, .crossing = 1, .face = entering.face });
        } else if (change < 0) {
            try hits.append(allocator, .{ .t = t, .point = point, .normal = leaving.normal, .crossing = -1, .face = leaving.face });
        } else {
            // A touch: in and out at once
            try hits.append(allocator, .{ .t = t, .point = point, .normal = entering.normal, .crossing = 1, .face = entering.face });
            try hits.append(allocator, .{ .t = t, .point = point, .normal = leaving.normal, .crossing = -1, .face = leaving.face });
        }
    }
    return hits.toOwnedSlice(allocator);
}

/// 1 inside the solid (or on its boundary, within the zone), 0 outside.
fn side(allocator: std.mem.Allocator, body: *const Body, index: *const FaceIndex, p: Vec3, options: diagnostics.Options, diag: *Diagnostics) Error!i32 {
    return if (try point_in_body.classify(allocator, body, index, p, options, diag) == .outside) 0 else 1;
}

/// Appends to `out` every meeting of the line `origin + t·dir` (`dir` unit), `t` in
/// `[lo, hi]`, with a face of `body` (in the face or on its boundary), in no order.
pub fn candidates(allocator: std.mem.Allocator, body: *const Body, index: *const FaceIndex, origin: Vec3, dir: Vec3, lo: f64, hi: f64, out: *std.ArrayList(Candidate), diag: *Diagnostics) Error!void {
    var items: std.ArrayList(u32) = .empty;
    defer items.deinit(allocator);
    const Collect = struct {
        allocator: std.mem.Allocator,
        items: *std.ArrayList(u32),
        failed: bool = false,
        fn visit(self: *@This(), item: u32) bool {
            self.items.append(self.allocator, item) catch {
                self.failed = true;
                return false;
            };
            return true;
        }
    };
    var collect: Collect = .{ .allocator = allocator, .items = &items };
    index.bvh.querySegment(origin, dir, lo, hi, &collect, Collect.visit);
    if (collect.failed) return error.OutOfMemory;
    std.mem.sort(u32, items.items, {}, std.sort.asc(u32));

    var ts: std.ArrayList(f64) = .empty;
    defer ts.deinit(allocator);
    for (items.items) |item| {
        const f = index.faces[item];
        const face = body.face(f);
        const surface = body.geometry.surface(face.surface);
        ts.clearRetainingCapacity();
        try surfaceRoots(allocator, body, surface, face.uv_box, origin, dir, lo, hi, &ts);
        for (ts.items) |t| {
            const p = vec.addScaled(origin, dir, t);
            const uv = in_face.uvOf(body, f, p);
            const place = try in_face.classify(body, f, p, uv, body.tol.zone, diag);
            if (place == .outside) continue;
            const normal = in_face.outwardNormal(body, f, uv);
            try out.append(allocator, .{ .t = t, .face = f, .place = place, .normal = normal, .cosine = vec.dot(normal, dir) });
        }
    }
}

/// Appends to `out` the parameters in `[lo, hi]` at which the line `origin + t·dir`
/// (`dir` unit) meets `surface`: crossings and tangencies within the zone.
fn surfaceRoots(allocator: std.mem.Allocator, body: *const Body, surface: surfaces.Surface, uv_box: geometry.Box2, origin: Vec3, dir: Vec3, lo: f64, hi: f64, out: *std.ArrayList(f64)) Error!void {
    const form = analytic(surface, origin, dir) orelse return freeFormRoots(allocator, body, surface, uv_box, origin, dir, lo, hi, out);
    const s_lo = lo - form.t_c;
    const s_hi = hi - form.t_c;
    const roots = poly.roots(form.f, s_lo, s_hi);
    for (roots.slice()) |s| try keep(body, surface, origin, dir, form.t_c + s, out, allocator);
    // A tangency: the segment's nearest approach to the surface, within the zone of it
    const crit = poly.criticalPoints(form.f, s_lo, s_hi);
    for (crit.slice()) |s| {
        const t = form.t_c + s;
        const p = vec.addScaled(origin, dir, t);
        const uv = surface.project(p, body.tol.approx, in_face.NEWTON_STEPS);
        if (vec.distance(surface.eval(uv[0], uv[1]), p) > body.tol.zone) continue;
        var near = false;
        for (out.items) |known| near = near or @abs(known - t) <= body.tol.zone;
        if (!near) try keep(body, surface, origin, dir, t, out, allocator);
    }
}

/// Newton on `S(u, v) − (O + t·d) = 0` with the surface's own derivatives (the Jacobian's
/// columns `S_u`, `S_v`, `−d`, solved by Cramer's rule), from a root Levenberg–Marquardt
/// found within its tolerance, to the last bits; a step that would not shrink the
/// residual is not taken.
fn polish(surface: surfaces.Surface, origin: Vec3, dir: Vec3, x: *[3]f64) void {
    var r = vec.sub(surface.eval(x[0], x[1]), vec.addScaled(origin, dir, x[2]));
    for (0..POLISH_STEPS) |_| {
        const s = surface.sample(x[0], x[1]);
        const c = vec.neg(dir);
        const det = vec.dot(s.du, vec.cross(s.dv, c));
        if (!(det != 0) or !std.math.isFinite(det)) return;
        const minus_r = vec.neg(r);
        const next: [3]f64 = .{
            x[0] + vec.dot(minus_r, vec.cross(s.dv, c)) / det,
            x[1] + vec.dot(s.du, vec.cross(minus_r, c)) / det,
            x[2] + vec.dot(s.du, vec.cross(s.dv, minus_r)) / det,
        };
        const next_r = vec.sub(surface.eval(next[0], next[1]), vec.addScaled(origin, dir, next[2]));
        if (!(vec.length(next_r) < vec.length(r))) return;
        x.* = next;
        r = next_r;
    }
}

/// Appends `t` unless the surface's form rules the point out (a cone's other nappe).
fn keep(body: *const Body, surface: surfaces.Surface, origin: Vec3, dir: Vec3, t: f64, out: *std.ArrayList(f64), allocator: std.mem.Allocator) Error!void {
    if (surface == .cone) {
        const cone = surface.cone;
        const local = cone.frame.toLocal(vec.addScaled(origin, dir, t));
        if (cone.r + local[2] * @tan(cone.half_angle) < -body.tol.zone) return;
    }
    try out.append(allocator, t);
}

/// An analytic surface's implicit equation along the line, as a polynomial in the
/// parameter less `t_c` (the line's point nearest the surface's centre, axis or apex).
const Form = struct { f: poly.Poly, t_c: f64 };

fn analytic(surface: surfaces.Surface, origin: Vec3, dir: Vec3) ?Form {
    switch (surface) {
        .plane => |s| {
            const o = s.frame.toLocal(origin);
            const d = s.frame.toLocalDir(dir);
            return .{ .f = poly.Poly.of(&.{ o[2], d[2] }), .t_c = 0 };
        },
        .cylinder => |s| {
            const o0 = s.frame.toLocal(origin);
            const d = s.frame.toLocalDir(dir);
            const a = d[0] * d[0] + d[1] * d[1];
            const t_c = if (a > 0) -(o0[0] * d[0] + o0[1] * d[1]) / a else 0;
            const o = vec.addScaled(o0, d, t_c);
            return .{ .f = poly.Poly.of(&.{ o[0] * o[0] + o[1] * o[1] - s.r * s.r, 2 * (o[0] * d[0] + o[1] * d[1]), a }), .t_c = t_c };
        },
        .sphere => |s| {
            const o0 = s.frame.toLocal(origin);
            const d = s.frame.toLocalDir(dir);
            const t_c = -vec.dot(o0, d) / vec.dot(d, d);
            const o = vec.addScaled(o0, d, t_c);
            return .{ .f = poly.Poly.of(&.{ vec.dot(o, o) - s.r * s.r, 2 * vec.dot(o, d), vec.dot(d, d) }), .t_c = t_c };
        },
        .cone => |s| {
            const k = @tan(s.half_angle);
            const o0 = s.frame.toLocal(origin);
            const d = s.frame.toLocalDir(dir);
            const apex: Vec3 = .{ 0, 0, -s.r / k };
            const t_c = vec.dot(vec.sub(apex, o0), d) / vec.dot(d, d);
            const o = vec.addScaled(o0, d, t_c);
            const rho = s.r + k * o[2];
            return .{ .f = poly.Poly.of(&.{
                o[0] * o[0] + o[1] * o[1] - rho * rho,
                2 * (o[0] * d[0] + o[1] * d[1]) - 2 * k * d[2] * rho,
                d[0] * d[0] + d[1] * d[1] - k * k * d[2] * d[2],
            }), .t_c = t_c };
        },
        .torus => |s| {
            const o0 = s.frame.toLocal(origin);
            const d = s.frame.toLocalDir(dir);
            const t_c = -vec.dot(o0, d) / vec.dot(d, d);
            const o = vec.addScaled(o0, d, t_c);
            const g = poly.Poly.of(&.{ vec.dot(o, o) + s.major * s.major - s.minor * s.minor, 2 * vec.dot(o, d), vec.dot(d, d) });
            const h = poly.Poly.of(&.{ o[0] * o[0] + o[1] * o[1], 2 * (o[0] * d[0] + o[1] * d[1]), d[0] * d[0] + d[1] * d[1] });
            return .{ .f = g.mul(g).add(h.scale(-4 * s.major * s.major)), .t_c = t_c };
        },
        .extrusion, .revolution, .nurbs => return null,
    }
}

/// The line's meetings with a free-form surface over the face's UV box: from the centre of
/// every cell of a `FREE_FORM_GRID` square grid whose box (its corners' and centre's,
/// grown by `CELL_BULGE`) the segment meets, Newton (Levenberg–Marquardt) on
/// `S(u, v) − (O + t·d) = 0`; a root is kept when its residual is within `approx`, its
/// parameters in the box and `t` in range, once (within the zone).
fn freeFormRoots(allocator: std.mem.Allocator, body: *const Body, surface: surfaces.Surface, box: geometry.Box2, origin: Vec3, dir: Vec3, lo: f64, hi: f64, out: *std.ArrayList(f64)) Error!void {
    if (box.isEmpty()) return;
    const tol = body.tol;
    const n: f64 = @floatFromInt(FREE_FORM_GRID);
    const du = (box.max[0] - box.min[0]) / n;
    const dv = (box.max[1] - box.min[1]) / n;
    const Ctx = struct {
        surface: surfaces.Surface,
        origin: Vec3,
        dir: Vec3,
        fn residuals(self: @This(), x: *const [3]f64, r: *[3]f64) void {
            const s = self.surface.eval(x[0], x[1]);
            const l = vec.addScaled(self.origin, self.dir, x[2]);
            r.* = vec.sub(s, l);
        }
    };
    const ctx: Ctx = .{ .surface = surface, .origin = origin, .dir = dir };
    for (0..FREE_FORM_GRID) |i| {
        for (0..FREE_FORM_GRID) |j| {
            const cell_u = box.min[0] + du * @as(f64, @floatFromInt(i));
            const cell_v = box.min[1] + dv * @as(f64, @floatFromInt(j));
            const centre = surface.eval(cell_u + du / 2, cell_v + dv / 2);
            var cell = Box3.ofPoint(centre);
            for ([_]f64{ 0, 1 }) |a| for ([_]f64{ 0, 1 }) |b| cell.grow(surface.eval(cell_u + a * du, cell_v + b * dv));
            if (!bvh_mod.segmentMeetsBox(cell.inflated(CELL_BULGE * cell.extent() + tol.zone), origin, dir, lo, hi)) continue;
            var x: [3]f64 = .{ cell_u + du / 2, cell_v + dv / 2, vec.dot(vec.sub(centre, origin), dir) };
            const result = solve.levenbergMarquardt(3, 3, ctx, Ctx.residuals, &x, tol.approx / 4, 0, in_face.NEWTON_STEPS);
            if (!(result.max_residual <= tol.approx)) continue;
            polish(surface, origin, dir, &x);
            const slack_u = (box.max[0] - box.min[0]) * 1e-9;
            const slack_v = (box.max[1] - box.min[1]) * 1e-9;
            if (x[0] < box.min[0] - slack_u or x[0] > box.max[0] + slack_u or x[1] < box.min[1] - slack_v or x[1] > box.max[1] + slack_v) continue;
            if (x[2] < lo or x[2] > hi) continue;
            var known = false;
            for (out.items) |t| known = known or @abs(t - x[2]) <= tol.zone;
            if (!known) try out.append(allocator, x[2]);
        }
    }
}
