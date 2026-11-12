//! Sweeps (docs/architecture.md §7.1): a planar sheet (a sketch) swept along a vector
//! (`extrude`) or about an axis in its plane (`revolve`) into a solid, by the generator ×
//! director table: a generator vertex along the director makes an edge, a generator edge
//! a face, the generator face the caps. The surface of each swept edge follows its kind:
//! along a vector, a line gives a plane, an arc swept along its own normal a cylinder, any
//! other curve (or an arc swept askew) a linear-extrusion surface; about an axis, a line
//! along it a cylinder, across it a plane, oblique a cone, an arc centred on the axis a
//! sphere, off it a torus, any other curve a surface of revolution; a vertex on the axis
//! sweeps a degenerate edge and an edge on the axis no face. The faces are sewn, as the
//! primitives are, with every loop counter-clockwise about its face's outward normal,
//! which is the traversal's tangent turned about the sheet's normal; a hole of the sheet
//! is a hole through the solid. A full turn is split at 0 and π (D7), a turn past π at
//! its middle; a partial turn gets the sheet as its two end caps. Every record is
//! addressed by index; the arrays the face specifications point into are sized first and
//! never grow.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Affine = @import("../math/mat.zig").Affine;
const diagnostics = @import("../diagnostics.zig");
const trace = @import("../io/trace.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const sew = @import("sew.zig");
const primitives = @import("primitives.zig");
const Body = body_mod.Body;
const Builder = primitives.Builder;
const Vec3 = vec.Vec3;
const Frame = geometry.Frame;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// The sheet swept along `direction` (its length the height): a solid whose bottom cap is
/// the sheet and whose top cap is the sheet moved by `direction`. The sheet must be flat
/// (every face on a plane) and `direction` must leave its plane. The input is untouched.
pub fn extrude(allocator: std.mem.Allocator, sheet: *const Body, direction: Vec3, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    for (direction) |c| try diagnostics.input.finite(diag, "the direction", c);
    try options.checkCancel();
    try trace.arguments(allocator, &options, "extrude", .{ .direction = direction });
    if (sheet.kind != .sheet or sheet.isEmpty()) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "the profile: a sheet" });
    const tol = options.tolerance orelse sheet.tol;
    const height = vec.length(direction);
    if (!(height > tol.zone)) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the height", .measured = height });
    const d_hat = vec.scale(direction, 1.0 / height);

    // Sized first: the sheet's loops and coedges, each a cap loop pair and a side face
    const counts = try countSheet(sheet, diag);
    if (counts.coedges > options.limits.faces_per_body) return diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "the profile's edges", .measured = @floatFromInt(counts.coedges), .threshold = @floatFromInt(options.limits.faces_per_body) });

    var b = try Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();

    // The sheet's vertices at the bottom and the top of the solid
    const bottom = try allocator.alloc(types.VertexIndex, sheet.vertices.items.len);
    defer allocator.free(bottom);
    const top = try allocator.alloc(types.VertexIndex, sheet.vertices.items.len);
    defer allocator.free(top);
    for (sheet.vertices.items, 0..) |v, i| {
        if (v.tombstone) continue;
        const p = sheet.geometry.point(v.point);
        bottom[i] = try b.vertex(p);
        top[i] = try b.vertex(vec.add(p, direction));
    }

    // What the face specifications point into: the caps' edges (bottom, then top, in
    // coedge order), the caps' loops (bottom, then top, in loop order), each side's four
    // edges and its one loop
    const cap_edges = try allocator.alloc(sew.EdgeSpec, 2 * counts.coedges);
    defer allocator.free(cap_edges);
    const cap_loops = try allocator.alloc(sew.LoopSpec, 2 * counts.loops);
    defer allocator.free(cap_loops);
    const side_edges = try allocator.alloc([4]sew.EdgeSpec, counts.coedges);
    defer allocator.free(side_edges);
    const side_loops = try allocator.alloc([1]sew.LoopSpec, counts.coedges);
    defer allocator.free(side_loops);
    const specs = try allocator.alloc(sew.FaceSpec, counts.coedges + 2 * counts.faces);
    defer allocator.free(specs);

    var ci: usize = 0;
    var li: usize = 0;
    var fi: usize = 0;
    var shells = traverse.Shells.init(sheet);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(sheet, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            try options.checkCancel();
            const face = sheet.face(f);
            const plane = sheet.geometry.planes.items[face.surface.index];
            // The sheet's outward normal: its loops run counter-clockwise about it
            const n_sheet = vec.scale(plane.frame.z, plane.frame.sign() * (if (face.same_sense) @as(f64, 1) else -1));
            const along = vec.dot(d_hat, n_sheet);
            if (@abs(along) <= tol.angle) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the direction's rise from the profile's plane", .measured = along });
            // The cap facing the sheet's way keeps its loops' direction; the other one
            // reverses them
            const n_bottom = if (along > 0) vec.neg(n_sheet) else n_sheet;
            const bottom_plane = try b.plane(Frame.init(plane.frame.origin, plane.frame.x, n_bottom));
            const top_plane = try b.plane(Frame.init(vec.add(plane.frame.origin, direction), plane.frame.x, vec.neg(n_bottom)));
            var bottom_box = geometry.Box2.empty;
            var top_box = geometry.Box2.empty;
            const first_loop = li;

            var face_loops = traverse.Loops.init(sheet, f);
            while (face_loops.next() catch return corrupt(diag)) |l| : (li += 1) {
                const first = ci;
                var it = traverse.Coedges.init(sheet, l);
                while (it.next() catch return corrupt(diag)) |c| : (ci += 1) {
                    const coedge = sheet.coedge(c);
                    const edge = sheet.edge(coedge.edge);
                    const va = sheet.coedgeStart(c);
                    const vb = sheet.coedgeEnd(c);
                    const pa = sheet.geometry.point(sheet.vertex(va).point);
                    const pb = sheet.geometry.point(sheet.vertex(vb).point);
                    const curve = sheet.geometry.curve(edge.curve);
                    const low = try copyCurve(&b, curve, &Affine.identity, pa, pb, coedge.same_sense);
                    const high = try copyCurve(&b, curve, &Affine.translate(direction), vec.add(pa, direction), vec.add(pb, direction), coedge.same_sense);
                    const ends = Ends{ .bottom_a = bottom[@backingInt(va)], .bottom_b = bottom[@backingInt(vb)], .top_a = top[@backingInt(va)], .top_b = top[@backingInt(vb)] };
                    cap_edges[ci] = .{ .start = ends.bottom_a, .end = ends.bottom_b, .curve = low.curve, .t0 = low.t0, .t1 = low.t1, .forward = low.forward };
                    cap_edges[counts.coedges + ci] = .{ .start = ends.top_a, .end = ends.top_b, .curve = high.curve, .t0 = high.t0, .t1 = high.t1, .forward = high.forward };
                    growByCurve(&bottom_box, b.body.geometry.surface(bottom_plane).plane, b.body.geometry.curve(low.curve), low.t0, low.t1);
                    growByCurve(&top_box, b.body.geometry.surface(top_plane).plane, b.body.geometry.curve(high.curve), high.t0, high.t1);
                    // The side: its outward normal is the traversal's tangent turned about
                    // the sheet's normal
                    const t_mid = (edge.t0 + edge.t1) / 2.0;
                    const tangent = vec.scale(curve.d1(t_mid), if (coedge.same_sense) @as(f64, 1) else -1);
                    const outward = vec.normalized(vec.cross(tangent, n_sheet)) orelse return diag.fail(error.Degenerate, .{ .code = .edge_too_short, .entity = .of(.edge, @backingInt(coedge.edge)) });
                    specs[fi] = try sideFace(&b, curve, low, high, ends, pa, pb, direction, d_hat, outward, &side_edges[ci]);
                    side_loops[ci] = .{.{ .edges = &side_edges[ci] }};
                    specs[fi].loops = &side_loops[ci];
                    specs[fi].attribute = face.attribute;
                    fi += 1;
                }
                const bottom_edges = cap_edges[first..ci];
                const top_edges = cap_edges[counts.coedges + first .. counts.coedges + ci];
                if (along > 0) reverseLoop(bottom_edges) else reverseLoop(top_edges);
                cap_loops[li] = .{ .edges = bottom_edges };
                cap_loops[counts.loops + li] = .{ .edges = top_edges };
            }
            specs[fi] = .{ .surface = bottom_plane, .loops = cap_loops[first_loop..li], .uv_box = bottom_box, .tag = face.tag, .attribute = face.attribute };
            specs[fi + 1] = .{ .surface = top_plane, .loops = cap_loops[counts.loops + first_loop .. counts.loops + li], .uv_box = top_box, .tag = face.tag, .attribute = face.attribute };
            fi += 2;
        }
    }
    return b.finish(specs, .outer);
}

/// The sheet turned about the axis through `origin` along `axis`, which must lie in the
/// sheet's plane, by `angle` radians (counter-clockwise seen from the axis's tip; negative
/// the other way; a full turn at ±2π): a solid. The sheet must lie on one side of the
/// axis; a point on it is allowed (an apex, a pole), an edge along it too (it sweeps
/// nothing). The input is untouched.
pub fn revolve(allocator: std.mem.Allocator, input: *const Body, origin: Vec3, axis: Vec3, angle: f64, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    for (origin) |c| try diagnostics.input.finite(diag, "the axis origin", c);
    for (axis) |c| try diagnostics.input.finite(diag, "the axis", c);
    try diagnostics.input.finite(diag, "the angle", angle);
    try options.checkCancel();
    try trace.arguments(allocator, &options, "revolve", .{ .origin = origin, .axis = axis, .angle = angle });
    if (input.kind != .sheet or input.isEmpty()) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "the profile: a sheet" });
    const tol = options.tolerance orelse input.tol;
    const z = vec.normalized(axis) orelse return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the axis's length" });
    if (!(@abs(angle) > tol.param)) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the angle", .measured = @abs(angle) });
    const turn = Turn.of(angle, tol);
    const frame = try profileFrame(input, origin, z, tol, diag);

    // The profile with every arc across its torus's seam split there (D7)
    var profile = try splitAtTorusSeams(allocator, input, frame, tol, diag);
    defer profile.deinit();
    const sheet = &profile;
    const counts = try countSheet(sheet, diag);
    const sides = counts.coedges * turn.spans();
    if (sides > options.limits.faces_per_body) return diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "the profile's edges", .measured = @floatFromInt(sides), .threshold = @floatFromInt(options.limits.faces_per_body) });

    var b = try Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const g = &b.body.geometry;

    // The sheet's vertices at each split angle, with their place about the axis; a
    // vertex on the axis is one record at every angle
    const n_vertices = sheet.vertices.items.len;
    const verts = try allocator.alloc(types.VertexIndex, turn.splits * n_vertices);
    defer allocator.free(verts);
    const places = try allocator.alloc(Place, n_vertices);
    defer allocator.free(places);
    for (sheet.vertices.items, 0..) |v, i| {
        if (v.tombstone) continue;
        const p = sheet.geometry.point(v.point);
        places[i] = frame.place(p);
        if (places[i].radius <= tol.zone) {
            verts[i] = try b.vertex(frame.onAxis(places[i].axial));
            for (1..turn.splits) |k| verts[k * n_vertices + i] = verts[i];
        } else {
            for (0..turn.splits) |k| verts[k * n_vertices + i] = try b.vertex(Affine.rotateAbout(origin, z, turn.placeOf(k)).point(p));
        }
    }

    // What the face specifications point into: the generator copies at each split angle
    // per coedge, each side's edges (four, or three on a plane) and loop, the caps' edges
    // (start, then end, in coedge order) and loops (start, then end, in loop order)
    const gens = try allocator.alloc(Copied, turn.splits * counts.coedges);
    defer allocator.free(gens);
    const side_edges = try allocator.alloc(sew.EdgeSpec, SIDE_EDGES * sides);
    defer allocator.free(side_edges);
    const side_loops = try allocator.alloc([1]sew.LoopSpec, sides);
    defer allocator.free(side_loops);
    const cap_edges = try allocator.alloc(sew.EdgeSpec, 2 * counts.coedges);
    defer allocator.free(cap_edges);
    const cap_loops = try allocator.alloc(sew.LoopSpec, 2 * counts.loops);
    defer allocator.free(cap_loops);
    const specs = try allocator.alloc(sew.FaceSpec, sides + 2 * counts.faces);
    defer allocator.free(specs);

    var ci: usize = 0;
    var li: usize = 0;
    var fi: usize = 0;
    var si: usize = 0;
    var shells = traverse.Shells.init(sheet);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(sheet, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            try options.checkCancel();
            const face = sheet.face(f);
            const first_loop = li;
            // The caps of a partial turn: the sheet's own plane turned to the start, facing
            // against the turn, and to the end, facing with it
            var caps: ?Caps = null;
            if (!turn.full) {
                const start = Affine.rotate(z, turn.start);
                const end = Affine.rotate(z, turn.end);
                caps = .{
                    .start = try b.plane(Frame.init(origin, start.vector(frame.r_dir), start.vector(frame.normal))),
                    .end = try b.plane(Frame.init(origin, end.vector(frame.r_dir), vec.neg(end.vector(frame.normal)))),
                };
            }
            var face_loops = traverse.Loops.init(sheet, f);
            while (face_loops.next() catch return corrupt(diag)) |l| : (li += 1) {
                const first = ci;
                var it = traverse.Coedges.init(sheet, l);
                while (it.next() catch return corrupt(diag)) |c| : (ci += 1) {
                    const coedge = sheet.coedge(c);
                    const edge = sheet.edge(coedge.edge);
                    const ia = @backingInt(sheet.coedgeStart(c));
                    const ib = @backingInt(sheet.coedgeEnd(c));
                    const curve = sheet.geometry.curve(edge.curve);
                    const on_axis = places[ia].radius <= tol.zone and places[ib].radius <= tol.zone;
                    // The generator at each split angle: the curve turned there, between
                    // the vertices there; an edge on the axis is itself at every angle
                    for (0..turn.splits) |k| {
                        const at: f64 = if (on_axis) 0 else turn.placeOf(k);
                        const qa = b.body.point(verts[k * n_vertices + ia]);
                        const qb = b.body.point(verts[k * n_vertices + ib]);
                        gens[k * counts.coedges + ci] = try copyCurve(&b, curve, &Affine.rotateAbout(origin, z, at), qa, qb, coedge.same_sense);
                    }
                    if (caps) |*cap| {
                        const last = turn.splits - 1;
                        const g_start = gens[ci];
                        const g_end = gens[last * counts.coedges + ci];
                        cap_edges[ci] = specOf(g_start, verts[ia], verts[ib]);
                        cap_edges[counts.coedges + ci] = specOf(g_end, verts[last * n_vertices + ia], verts[last * n_vertices + ib]);
                        growByCurve(&cap.start_box, g.surface(cap.start).plane, g.curve(g_start.curve), g_start.t0, g_start.t1);
                        growByCurve(&cap.end_box, g.surface(cap.end).plane, g.curve(g_end.curve), g_end.t0, g_end.t1);
                    }
                    if (on_axis) continue;
                    // A side per span: the outward normal is the traversal's tangent turned
                    // about the sheet's normal, as for an extrusion
                    const t_mid = (edge.t0 + edge.t1) / 2.0;
                    const tangent = vec.scale(curve.d1(t_mid), if (coedge.same_sense) @as(f64, 1) else -1);
                    const outward = vec.normalized(vec.cross(tangent, frame.normal)) orelse return diag.fail(error.Degenerate, .{ .code = .edge_too_short, .entity = .of(.edge, @backingInt(coedge.edge)) });
                    for (0..turn.spans()) |k| {
                        const k_end = turn.endSplit(k);
                        const side = try revolvedFace(&b, curve, .{
                            .frame = frame,
                            .u0 = turn.at(k),
                            .u1 = turn.spanEnd(k),
                            .seam = turn.isSeam(k),
                            .low = gens[k * counts.coedges + ci],
                            .high = gens[k_end * counts.coedges + ci],
                            .base = gens[turn.zeroSplit() * counts.coedges + ci],
                            .ends = .{ .bottom_a = verts[k * n_vertices + ia], .bottom_b = verts[k * n_vertices + ib], .top_a = verts[k_end * n_vertices + ia], .top_b = verts[k_end * n_vertices + ib] },
                            .place_a = places[ia],
                            .place_b = places[ib],
                        }, outward, side_edges[SIDE_EDGES * si ..][0..SIDE_EDGES]);
                        side_loops[si] = .{.{ .edges = side_edges[SIDE_EDGES * si ..][0..side.edge_count] }};
                        specs[fi] = side.spec;
                        specs[fi].loops = &side_loops[si];
                        specs[fi].attribute = face.attribute;
                        si += 1;
                        fi += 1;
                    }
                }
                if (caps != null) {
                    const start_edges = cap_edges[first..ci];
                    const end_edges = cap_edges[counts.coedges + first .. counts.coedges + ci];
                    reverseLoop(end_edges);
                    cap_loops[li] = .{ .edges = start_edges };
                    cap_loops[counts.loops + li] = .{ .edges = end_edges };
                }
            }
            if (caps) |cap| {
                specs[fi] = .{ .surface = cap.start, .loops = cap_loops[first_loop..li], .uv_box = cap.start_box, .tag = face.tag, .attribute = face.attribute };
                specs[fi + 1] = .{ .surface = cap.end, .loops = cap_loops[counts.loops + first_loop .. counts.loops + li], .uv_box = cap.end_box, .tag = face.tag, .attribute = face.attribute };
                fi += 2;
            }
        }
    }
    return b.finish(specs[0..fi], .outer);
}

/// Edges per side face at most (three on a plane whose inner arc is a point).
const SIDE_EDGES = 4;

/// The angular spans of a turn: a full turn is [0, π] and [π, 2π]; a partial one from 0
/// to the angle, or the other way from 2π + angle to 2π (the same places, inside the
/// periodic domain), split at its middle past a half turn. The split angles are where the
/// generators are copied.
const Turn = struct {
    start: f64,
    end: f64,
    full: bool,
    /// The split angles: 2 or 3; a full turn's third, 2π, is its first again.
    splits: usize,
    middle: ?f64,

    fn of(angle: f64, tol: Tolerance) Turn {
        const full = @abs(angle) >= geometry.TWO_PI - tol.param;
        if (full) return .{ .start = 0, .end = geometry.TWO_PI, .full = true, .splits = 2, .middle = std.math.pi };
        const start: f64 = if (angle > 0) 0 else geometry.TWO_PI + angle;
        const end: f64 = if (angle > 0) angle else geometry.TWO_PI;
        const halved = end - start > std.math.pi + tol.param;
        return .{ .start = start, .end = end, .full = false, .splits = if (halved) 3 else 2, .middle = if (halved) start + std.math.pi else null };
    }

    fn spans(self: Turn) usize {
        return if (self.full) 2 else self.splits - 1;
    }

    /// The angle of split `k`.
    fn at(self: Turn, k: usize) f64 {
        return switch (k) {
            0 => self.start,
            1 => self.middle orelse self.end,
            else => self.end,
        };
    }

    /// The split at the profile's own place, angle 0: the first, or for a turn the other
    /// way the last (at 2π).
    fn zeroSplit(self: Turn) usize {
        return if (self.start == 0) 0 else self.splits - 1;
    }

    /// The angle the generators and vertices of split `k` are turned by: exactly 0 at the
    /// profile's own place, where a turn by 2π would land a rounding away.
    fn placeOf(self: Turn, k: usize) f64 {
        return if (k == self.zeroSplit()) 0 else self.at(k);
    }

    /// The split that ends span `k`: a full turn's last span ends at its first split.
    fn endSplit(self: Turn, k: usize) usize {
        return if (self.full and k == 1) 0 else k + 1;
    }

    fn spanEnd(self: Turn, k: usize) f64 {
        return if (self.full and k == 1) geometry.TWO_PI else self.at(k + 1);
    }

    /// Whether span `k`'s generators are seams: the splits of a periodic surface, never a
    /// cap's edge (each span's edges are flagged where they are not an end of the turn).
    fn isSeam(self: Turn, k: usize) bool {
        _ = k;
        return self.full or self.middle != null;
    }
};

/// Where a point of the profile is about the axis: its distance from it along the radial
/// direction and its coordinate along the axis.
const Place = struct { radius: f64, axial: f64 };

/// The profile's plane about the axis: the axis's direction, the radial direction in the
/// plane (the side the profile lies on) and the plane's outward normal.
const ProfileFrame = struct {
    origin: Vec3,
    z: Vec3,
    r_dir: Vec3,
    normal: Vec3,

    fn place(self: ProfileFrame, p: Vec3) Place {
        const d = vec.sub(p, self.origin);
        return .{ .radius = vec.dot(d, self.r_dir), .axial = vec.dot(d, self.z) };
    }

    fn onAxis(self: ProfileFrame, axial: f64) Vec3 {
        return vec.addScaled(self.origin, self.z, axial);
    }
};

/// A copy of the profile in which every arc that crosses the seam of the torus it will
/// sweep (the point of its circle farthest from the axis, where the torus's `v` is 0) is
/// split at that point, so no swept face's UV box wraps or leaves the domain (D7); an arc
/// about a centre on the axis sweeps a sphere, whose `v` runs from pole to pole with no
/// seam in reach.
fn splitAtTorusSeams(allocator: std.mem.Allocator, input: *const Body, frame: ProfileFrame, tol: Tolerance, diag: *Diagnostics) Error!Body {
    const euler = @import("../topology/euler.zig");
    var profile = input.clone(allocator) catch return diag.fail(error.OutOfMemory, .{ .code = .limit_exceeded, .label = "the profile's copy" });
    errdefer profile.deinit();
    const n_edges = profile.edges.items.len;
    for (0..n_edges) |i| {
        const e = profile.edge(types.EdgeIndex.of(i));
        if (e.flags.tombstone or e.flags.degenerate) continue;
        const circle = switch (profile.geometry.curve(e.curve)) {
            .circle => |c| c,
            else => continue,
        };
        if (frame.place(circle.c).radius <= tol.zone) continue;
        const seam_point = vec.addScaled(circle.c, frame.r_dir, circle.r);
        const t = circle.project(seam_point);
        if (!(t > e.t0 + tol.param and t < e.t1 - tol.param)) continue;
        const point = profile.geometry.addPoint(allocator, circle.eval(t)) catch return diag.fail(error.OutOfMemory, .{ .code = .limit_exceeded, .label = "the profile's copy" });
        _ = euler.mevSplitEdge(&profile, e.coedge, t, point) catch return corrupt(diag);
    }
    return profile;
}

/// The profile's frame, every face checked on one plane through the axis, and every edge
/// checked on the radial side of it.
fn profileFrame(sheet: *const Body, origin: Vec3, z: Vec3, tol: Tolerance, diag: *Diagnostics) Error!ProfileFrame {
    var frame: ?ProfileFrame = null;
    for (sheet.faces.items, 0..) |face, fi| {
        if (face.flags.tombstone) continue;
        const n = outwardNormal(sheet, types.FaceIndex.of(fi));
        if (frame) |fr| {
            if (vec.dot(n, fr.normal) < 1.0 - tol.angle) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .of(.face, fi), .label = "a profile face's agreement with the first's plane" });
            continue;
        }
        if (@abs(vec.dot(n, z)) > tol.angle) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the axis's lie in the profile's plane", .measured = vec.dot(n, z) });
        const plane = sheet.geometry.planes.items[face.surface.index];
        const off = vec.dot(vec.sub(origin, plane.frame.origin), plane.frame.z);
        if (@abs(off) > tol.zone) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the axis's distance from the profile's plane", .measured = off });
        frame = .{ .origin = origin, .z = z, .r_dir = vec.normalized(vec.cross(z, n)).?, .normal = n };
    }
    const fr = frame orelse return corrupt(diag);
    for (sheet.edges.items, 0..) |e, i| {
        if (e.flags.tombstone) continue;
        const box = sheet.geometry.curve(e.curve).bounds(e.t0, e.t1);
        var lowest = std.math.inf(f64);
        for ([_]f64{ box.min[0], box.max[0] }) |x| for ([_]f64{ box.min[1], box.max[1] }) |y| for ([_]f64{ box.min[2], box.max[2] }) |zc| {
            lowest = @min(lowest, fr.place(.{ x, y, zc }).radius);
        };
        if (lowest < -tol.zone) return diag.fail(error.NotRepresentable, .{ .code = .not_implemented, .entity = .of(.edge, i), .label = "a profile crossing the axis", .measured = lowest });
    }
    return fr;
}

/// A face's outward normal: its plane's normal by its sense (the sheet's loops run
/// counter-clockwise about it).
fn outwardNormal(sheet: *const Body, f: types.FaceIndex) Vec3 {
    const face = sheet.face(f);
    const plane = sheet.geometry.planes.items[face.surface.index];
    return vec.scale(plane.frame.z, plane.frame.sign() * (if (face.same_sense) @as(f64, 1) else -1));
}

/// The two caps of a partial turn with their UV boxes, grown as the loops are laid.
const Caps = struct {
    start: geometry.SurfaceRef,
    end: geometry.SurfaceRef,
    start_box: geometry.Box2 = geometry.Box2.empty,
    end_box: geometry.Box2 = geometry.Box2.empty,
};

/// The edge specification of a copied generator between two vertices.
fn specOf(copied: Copied, start: types.VertexIndex, end: types.VertexIndex) sew.EdgeSpec {
    return .{ .start = start, .end = end, .curve = copied.curve, .t0 = copied.t0, .t1 = copied.t1, .forward = copied.forward };
}

/// One swept edge over one angular span: what `revolvedFace` needs.
const RevolvedEdge = struct {
    frame: ProfileFrame,
    u0: f64,
    u1: f64,
    seam: bool,
    /// The generator at `u0`, at `u1`, and at the profile's own place (angle 0), which a
    /// surface of revolution measures its angle from.
    low: Copied,
    high: Copied,
    base: Copied,
    ends: Ends,
    place_a: Place,
    place_b: Place,
};

const SideFace = struct { spec: sew.FaceSpec, edge_count: usize };

/// The face swept by one edge over one angular span: a cylinder, plane, cone, sphere,
/// torus or surface of revolution by the edge's kind and place, its loop counter-clockwise
/// about `outward`. The edges go to `edges` in the natural order (the generator at `u0`,
/// the director arc at `b`, the generator at `u1` back, the director arc at `a` back),
/// reversed when the surface's own orientation asks; a director arc of a point on the
/// axis is a degenerate edge, left out on a plane (which has no singularity there).
fn revolvedFace(b: *Builder, curve: curves.Curve, r: RevolvedEdge, outward: Vec3, edges: []sew.EdgeSpec) Error!SideFace {
    const g = &b.body.geometry;
    const tol = b.body.tol;
    const frame = r.frame;
    const seam_flags: types.EdgeFlags = if (r.seam) primitives.SEAM else .{};
    const seam_regularity: types.Regularity = if (r.seam) .g1 else .c0;
    edges[0] = specOf(r.low, r.ends.bottom_a, r.ends.bottom_b);
    edges[1] = .{ .start = r.ends.bottom_b, .end = r.ends.top_b, .curve = try directorArc(b, frame, r.place_b), .t0 = r.u0, .t1 = r.u1, .flags = if (r.place_b.radius <= tol.zone) primitives.DEGENERATE else .{} };
    edges[2] = specOf(r.high, r.ends.top_b, r.ends.top_a);
    edges[2].forward = !r.high.forward;
    edges[3] = .{ .start = r.ends.top_a, .end = r.ends.bottom_a, .curve = try directorArc(b, frame, r.place_a), .t0 = r.u0, .t1 = r.u1, .forward = false, .flags = if (r.place_a.radius <= tol.zone) primitives.DEGENERATE else .{} };
    edges[0].flags = seam_flags;
    edges[2].flags = seam_flags;
    edges[0].regularity = seam_regularity;
    edges[2].regularity = seam_regularity;

    const d_axial = r.place_b.axial - r.place_a.axial;
    const d_radial = r.place_b.radius - r.place_a.radius;
    if (curve == .line and @abs(d_axial) <= tol.zone) return planeSector(b, r, outward, edges);

    // The parametric surfaces: u the angle, v along the generator as each kind has it,
    // read at both ends, and the generator's parameter mapped to v linearly
    var surface: geometry.SurfaceRef = undefined;
    var v_a: f64 = undefined;
    var v_b: f64 = undefined;
    switch (curve) {
        .line => if (@abs(d_radial) <= tol.zone) {
            // Along the axis: a cylinder, v the axial coordinate
            surface = b.interner.cylinder(b.allocator, g, .{ .frame = Frame.init(frame.origin, frame.r_dir, frame.z), .r = r.place_a.radius }) catch |e| return b.fail(e);
            v_a = r.place_a.axial;
            v_b = r.place_b.axial;
        } else {
            // Oblique: a cone from the lower end, v the distance along the generator
            const low_is_a = r.place_a.axial < r.place_b.axial;
            const low_place = if (low_is_a) r.place_a else r.place_b;
            const half_angle = trig.atan2(if (low_is_a) d_radial else -d_radial, @abs(d_axial));
            surface = b.interner.cone(b.allocator, g, .{ .frame = Frame.init(frame.onAxis(low_place.axial), frame.r_dir, frame.z), .r = low_place.radius, .half_angle = half_angle }) catch |e| return b.fail(e);
            const length = @sqrt(d_axial * d_axial + d_radial * d_radial);
            v_a = if (low_is_a) 0 else length;
            v_b = if (low_is_a) length else 0;
        },
        .circle => |c| {
            // Centred on the axis a sphere, off it a torus; v is the angle about the
            // circle's centre from the radial direction toward the axis, at `a` by its
            // place, at `b` by the arc's extent the way the edge runs it
            const centre = frame.place(c.c);
            const base = Frame.init(frame.onAxis(centre.axial), frame.r_dir, frame.z);
            if (centre.radius <= tol.zone) {
                surface = b.interner.sphere(b.allocator, g, .{ .frame = base, .r = c.r }) catch |e| return b.fail(e);
            } else {
                surface = b.interner.torus(b.allocator, g, .{ .frame = base, .major = centre.radius, .minor = c.r }) catch |e| return b.fail(e);
            }
            v_a = trig.atan2(r.place_a.axial - centre.axial, r.place_a.radius - centre.radius);
            // Which way v runs along the arc, from the generator at the profile's own
            // place (angle 0), where the direction of growing v lies in the profile's
            // frame; a copy at another angle has its tangent turned out of it, and the
            // sign of the dot with it depended on the span (the two spans of one arc then
            // disagreed and the sewing refused the edge they share)
            const t_a = if (r.base.forward) r.base.t0 else r.base.t1;
            const along_v = vec.add(vec.scale(frame.r_dir, -@sin(v_a)), vec.scale(frame.z, @cos(v_a)));
            const base_curve = g.curve(r.base.curve);
            const direction: f64 = if (vec.dot(base_curve.d1(t_a), along_v) > 0) 1 else -1;
            const extent = r.base.t1 - r.base.t0;
            v_b = v_a + direction * (if (r.base.forward) extent else -extent);
            // A torus's v runs from 0 at the seam: an arc ending there from below is a
            // turn further on (its seam crossings were split, so it is all on one side)
            if (centre.radius > tol.zone and @min(v_a, v_b) < -tol.param) {
                v_a += geometry.TWO_PI;
                v_b += geometry.TWO_PI;
            }
        },
        else => {
            // From the generator at angle 0, so the surface's u is the absolute angle
            surface = g.addRevolution(b.allocator, r.base.curve, frame.origin, frame.z) catch |e| return b.fail(e);
            v_a = if (r.base.forward) r.base.t0 else r.base.t1;
            v_b = if (r.base.forward) r.base.t1 else r.base.t0;
        },
    }
    edges[0].pcurve = try generatorPcurve(b, r.low, r.u0, v_a, v_b);
    edges[2].pcurve = try generatorPcurve(b, r.high, r.u1, v_a, v_b);
    edges[1].pcurve = try b.pcurveLine(.{ 0, v_b }, .{ 1, 0 });
    edges[3].pcurve = try b.pcurveLine(.{ 0, v_a }, .{ 1, 0 });
    const box = geometry.Box2{ .min = .{ r.u0, @min(v_a, v_b) }, .max = .{ r.u1, @max(v_a, v_b) } };
    // The surface's normal against the outward one at the middle of the span; the natural
    // order climbs v first at u0, so it is counter-clockwise in UV when v falls from a to b
    const u_mid = (r.u0 + r.u1) / 2.0;
    const same_sense = vec.dot(g.surface(surface).normal(u_mid, (v_a + v_b) / 2.0), Affine.rotate(frame.z, u_mid).vector(outward)) > 0;
    if ((v_b < v_a) != same_sense) reverseLoop(edges[0..SIDE_EDGES]);
    return .{ .spec = .{ .surface = surface, .same_sense = same_sense, .loops = &.{}, .uv_box = box }, .edge_count = SIDE_EDGES };
}

/// The pcurve of a generator at angle `u` whose parameter maps to v linearly: v_a at its
/// start and v_b at its end, the way the edge runs it.
fn generatorPcurve(b: *Builder, gen: Copied, u: f64, v_a: f64, v_b: f64) Error!geometry.PCurveRef {
    const t_a = if (gen.forward) gen.t0 else gen.t1;
    const t_b = if (gen.forward) gen.t1 else gen.t0;
    const k = (v_b - v_a) / (t_b - t_a);
    return b.pcurveLine(.{ u, v_a - k * t_a }, .{ 0, k });
}

/// A line across the axis sweeps an annulus sector (a disc sector when one end is on the
/// axis): a planar face facing `outward`, no pcurves, its loop laid by its winding in the
/// plane, a degenerate inner arc left out.
fn planeSector(b: *Builder, r: RevolvedEdge, outward: Vec3, edges: []sew.EdgeSpec) Error!SideFace {
    const g = &b.body.geometry;
    const frame = r.frame;
    const normal = if (vec.dot(outward, frame.z) > 0) frame.z else vec.neg(frame.z);
    const surface = try b.plane(Frame.init(frame.onAxis(r.place_a.axial), frame.r_dir, normal));
    const plane = g.surface(surface).plane;
    var kept: usize = 0;
    for (0..SIDE_EDGES) |i| {
        if (edges[i].flags.degenerate) continue;
        edges[kept] = edges[i];
        kept += 1;
    }
    const loop = edges[0..kept];
    var box = geometry.Box2.empty;
    var winding: f64 = 0;
    for (loop) |e| {
        const c = g.curve(e.curve);
        const start = plane.project(b.body.point(e.start));
        const mid = plane.project(c.eval((e.t0 + e.t1) / 2.0));
        const end = plane.project(b.body.point(e.end));
        winding += start[0] * mid[1] - mid[0] * start[1] + mid[0] * end[1] - end[0] * mid[1];
        growByCurve(&box, plane, c, e.t0, e.t1);
    }
    if (winding < 0) reverseLoop(loop);
    return .{ .spec = .{ .surface = surface, .loops = &.{}, .uv_box = box }, .edge_count = kept };
}

/// The circle a point of the profile sweeps about the axis, the angle its parameter; a
/// point of the axis sweeps a zero-radius circle, a degenerate edge's curve.
fn directorArc(b: *Builder, frame: ProfileFrame, place: Place) Error!geometry.CurveRef {
    const centre = frame.onAxis(place.axial);
    if (place.radius <= b.body.tol.zone) return b.pointCurve(centre);
    return b.interner.circle(b.allocator, &b.body.geometry, .{ .c = centre, .x = frame.r_dir, .y = vec.cross(frame.z, frame.r_dir), .r = place.radius }) catch |e| return b.fail(e);
}

const Counts = struct { faces: usize, loops: usize, coedges: usize };

/// The sheet's faces (each on a plane, or `NotRepresentable`), loops and coedges.
fn countSheet(sheet: *const Body, diag: *Diagnostics) Error!Counts {
    var counts = Counts{ .faces = 0, .loops = 0, .coedges = 0 };
    var shells = traverse.Shells.init(sheet);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(sheet, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            if (sheet.face(f).surface.kind != .plane) return diag.fail(error.NotRepresentable, .{ .code = .not_implemented, .entity = .of(.face, @backingInt(f)), .label = "a curved profile face" });
            counts.faces += 1;
            var loops = traverse.Loops.init(sheet, f);
            while (loops.next() catch return corrupt(diag)) |l| {
                counts.loops += 1;
                var it = traverse.Coedges.init(sheet, l);
                var n: usize = 0;
                while (it.next() catch return corrupt(diag)) |_| n += 1;
                if (n == 0) return corrupt(diag);
                counts.coedges += n;
            }
        }
    }
    return counts;
}

/// The vertices of one swept edge: its ends at the bottom and at the top.
const Ends = struct { bottom_a: types.VertexIndex, bottom_b: types.VertexIndex, top_a: types.VertexIndex, top_b: types.VertexIndex };

/// A curve of the sheet in the new body under `map` (a move, a turn), as the edge from
/// `pa` to `pb` (already mapped) runs it: `t0 < t1` its range, `forward` whether the edge
/// runs from `t0` to `t1` (`pa` at `t0`). A line is the one through the mapped ends; a
/// circle, an ellipse and a free-form curve are the records mapped.
const Copied = struct { curve: geometry.CurveRef, t0: f64, t1: f64, forward: bool };

fn copyCurve(b: *Builder, curve: curves.Curve, map: *const Affine, pa: Vec3, pb: Vec3, same_sense: bool) Error!Copied {
    const g = &b.body.geometry;
    switch (curve) {
        .line => {
            const ref = try b.line(pa, pb);
            const l = g.curve(ref).line;
            const ta = l.project(pa);
            const tb = l.project(pb);
            return .{ .curve = ref, .t0 = @min(ta, tb), .t1 = @max(ta, tb), .forward = ta < tb };
        },
        .circle => |c| {
            const ref = b.interner.circle(b.allocator, g, .{ .c = map.point(c.c), .x = map.vector(c.x), .y = map.vector(c.y), .r = c.r }) catch |e| return b.fail(e);
            return arcOn(ref, g.curve(ref), pa, pb, same_sense, b.body.tol);
        },
        .ellipse => |e| {
            const ref = g.addEllipse(b.allocator, .{ .c = map.point(e.c), .x = map.vector(e.x), .y = map.vector(e.y), .a = e.a, .b = e.b }) catch |err| return b.fail(err);
            return arcOn(ref, g.curve(ref), pa, pb, same_sense, b.body.tol);
        },
        .nurbs => |n| {
            // The control points under the map, the knots as they are
            const points = try b.allocator.alloc(vec.Vec4, n.points.len);
            defer b.allocator.free(points);
            for (n.points, points) |q, *mapped| mapped.* = vec.weighted(map.point(vec.project4(q)), q[3]);
            const ref = g.addNurbsCurve(b.allocator, .{ .degree = n.degree, .knots = n.knots, .points = points }) catch |e| return b.fail(e);
            const copy = g.curve(ref);
            const ta = copy.project(pa, b.body.tol.approx, 50);
            const tb = copy.project(pb, b.body.tol.approx, 50);
            return .{ .curve = ref, .t0 = @min(ta, tb), .t1 = @max(ta, tb), .forward = ta < tb };
        },
    }
}

/// The arc of a closed curve the edge from `pa` to `pb` covers: counter-clockwise from
/// `pa` when the edge runs the curve forward, from `pb` otherwise; the same point twice
/// is the full turn (a circle of one edge).
fn arcOn(ref: geometry.CurveRef, curve: curves.Curve, pa: Vec3, pb: Vec3, same_sense: bool, tol: Tolerance) Copied {
    const ta = curve.project(pa, tol.approx, 50);
    const tb = curve.project(pb, tol.approx, 50);
    const period = curve.domain().span();
    if (same_sense) {
        const end = if (tb <= ta + tol.param) tb + period else tb;
        return .{ .curve = ref, .t0 = ta, .t1 = end, .forward = true };
    }
    const end = if (ta <= tb + tol.param) ta + period else ta;
    return .{ .curve = ref, .t0 = tb, .t1 = end, .forward = false };
}

/// The face swept by one edge: a plane for a line, a cylinder for an arc swept along its
/// normal, a linear-extrusion surface for any other curve; its loop counter-clockwise
/// about `outward`. The four edges go to `edges`.
fn sideFace(b: *Builder, curve: curves.Curve, low: Copied, high: Copied, ends: Ends, pa: Vec3, pb: Vec3, direction: Vec3, d_hat: Vec3, outward: Vec3, edges: *[4]sew.EdgeSpec) Error!sew.FaceSpec {
    const g = &b.body.geometry;
    const up_a = try b.line(pa, vec.add(pa, direction));
    const up_b = try b.line(pb, vec.add(pb, direction));
    const la = g.curve(up_a).line;
    const lb = g.curve(up_b).line;
    const ta0 = la.project(pa);
    const ta1 = la.project(vec.add(pa, direction));
    const tb0 = lb.project(pb);
    const tb1 = lb.project(vec.add(pb, direction));
    // The natural order: along the bottom, up at b, back along the top, down at a
    edges.* = .{
        .{ .start = ends.bottom_a, .end = ends.bottom_b, .curve = low.curve, .t0 = low.t0, .t1 = low.t1, .forward = low.forward },
        .{ .start = ends.bottom_b, .end = ends.top_b, .curve = up_b, .t0 = @min(tb0, tb1), .t1 = @max(tb0, tb1), .forward = tb0 < tb1 },
        .{ .start = ends.top_b, .end = ends.top_a, .curve = high.curve, .t0 = high.t0, .t1 = high.t1, .forward = !high.forward },
        .{ .start = ends.top_a, .end = ends.bottom_a, .curve = up_a, .t0 = @min(ta0, ta1), .t1 = @max(ta0, ta1), .forward = ta1 < ta0 },
    };
    switch (curve) {
        .line => {
            // The plane through the edge with the outward normal: v runs along the
            // sheet's normal, so the loop is counter-clockwise when the sweep rises
            const tangent = vec.normalized(vec.sub(pb, pa)).?;
            const frame = Frame.init(pa, tangent, outward);
            const surface = try b.plane(frame);
            const plane = g.surface(surface).plane;
            var box = geometry.Box2.empty;
            for ([_]Vec3{ pa, pb, vec.add(pa, direction), vec.add(pb, direction) }) |p| box.grow(plane.project(p));
            if (vec.dot(direction, frame.y) < 0) reverseLoop(edges);
            return .{ .surface = surface, .loops = &.{}, .uv_box = box };
        },
        else => {},
    }
    // A cylinder when an arc is swept along its own normal; the extrusion surface else.
    // Both have u the curve's parameter and v a distance along `z`
    var surface: geometry.SurfaceRef = undefined;
    var z: Vec3 = undefined;
    if (curve == .circle and vec.length(vec.cross(d_hat, curve.circle.normal())) <= b.body.tol.angle) {
        const c = curve.circle;
        z = c.normal();
        surface = b.interner.cylinder(b.allocator, g, .{ .frame = Frame.init(c.c, c.x, z), .r = c.r }) catch |e| return b.fail(e);
    } else {
        z = d_hat;
        surface = g.addExtrusion(b.allocator, low.curve, d_hat) catch |e| return b.fail(e);
    }
    const v_top = vec.dot(direction, z);
    const u_a = if (low.forward) low.t0 else low.t1;
    const u_b = if (low.forward) low.t1 else low.t0;
    edges[0].pcurve = try b.pcurveLine(.{ 0, 0 }, .{ 1, 0 });
    edges[1].pcurve = try verticalPcurve(b, lb, pb, u_b, z);
    edges[2].pcurve = try b.pcurveLine(.{ 0, v_top }, .{ 1, 0 });
    edges[3].pcurve = try verticalPcurve(b, la, pa, u_a, z);
    const box = geometry.Box2{ .min = .{ low.t0, @min(0, v_top) }, .max = .{ low.t1, @max(0, v_top) } };
    // The surface's normal against the outward one, at the middle; the loop is
    // counter-clockwise in UV when it goes the surface's way
    const s = g.surface(surface);
    const same_sense = vec.dot(s.normal((low.t0 + low.t1) / 2.0, v_top / 2.0), outward) > 0;
    const ccw_in_uv = (u_b > u_a) == (v_top > 0);
    if (ccw_in_uv != same_sense) reverseLoop(edges);
    return .{ .surface = surface, .same_sense = same_sense, .loops = &.{}, .uv_box = box };
}

/// The pcurve of a vertical edge on a surface whose v is the distance along `z` from the
/// sheet: `v(t) = (t − t_p)·(d · z)` for the line's parameter t, `t_p` at `p`.
fn verticalPcurve(b: *Builder, line: curves.Line, p: Vec3, u: f64, z: Vec3) Error!geometry.PCurveRef {
    const k = vec.dot(line.d, z);
    const tp = line.project(p);
    return b.pcurveLine(.{ u, -k * tp }, .{ 0, k });
}

/// Grows a plane's UV box by the box of a curve over a range.
fn growByCurve(box: *geometry.Box2, plane: surfaces.Plane, curve: curves.Curve, t0: f64, t1: f64) void {
    const b3 = curve.bounds(t0, t1);
    for ([_]f64{ b3.min[0], b3.max[0] }) |x| for ([_]f64{ b3.min[1], b3.max[1] }) |y| for ([_]f64{ b3.min[2], b3.max[2] }) |z| box.grow(plane.project(.{ x, y, z }));
}

/// Reverses a loop: the edges in the other order, each the other way.
fn reverseLoop(edges: []sew.EdgeSpec) void {
    std.mem.reverse(sew.EdgeSpec, edges);
    for (edges) |*e| {
        std.mem.swap(types.VertexIndex, &e.start, &e.end);
        e.forward = !e.forward;
    }
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the profile" });
}
