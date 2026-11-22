//! A body under an affine map (docs/architecture.md §5.1, the transforms item of M0): a new
//! body with the same topology and the geometry mapped by geometry/transform.zig. A rigid
//! move, a uniform scale or a mirror maps every kind exactly; a mirror leaves the surface
//! frames left-handed, so every parameter and pcurve stays as it was, and flips each
//! face's `same_sense` and reverses each loop, so the outward normals and the "face to the
//! left" rule hold on the mirror image. Edge ranges and pcurves scale where a line's or an
//! extrusion's length parameter does. Under a general map (a non-uniform scale) a body
//! whose faces are all planes maps exactly; a curved face is `error.NotRepresentable`.
//!
//! A map is a similarity as given when its matrix is one to rounding, and is taken for the
//! similarity nearest it when that moves no point of the body by more than the zone (a
//! matrix typed to a few digits; `geo_transform.nearSimilarity`): the body's frames are
//! then orthonormal, where a matrix 9e-6 off once passed as it was and left a cylinder's
//! frame that far from square (audit of 2026-11-22). Past that the map is a general one.
//!
//! A similarity scales the body's tolerance with it (`Tolerance.scaled`, as OCCT's
//! BRepTools_TrsfModification does), so every relation the body held, a gap, a vertex on
//! an edge or a face within the intersection tolerance, holds at the scale: a union
//! holding a box's bottom outline 1.5e-5 off another's top with no gap, scaled by 2, had it
//! 3e-5 off against an unscaled 2e-5 (audit of 2026-11-22). A general map keeps the
//! tolerance and changes distances unevenly, so its result is a made solid like any other
//! (`overlap.refuseMade`: faces brought within the tolerance of each other, refused below
//! the feature size), or a sheet the overlay could not have made (edges within the zone
//! of each other, refused alike; `sketch/overlap.check`).

const std = @import("std");
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const geometry = @import("../geometry/types.zig");
const geo_transform = @import("../geometry/transform.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const check = @import("../topology/check.zig");
const overlap = @import("../query/overlap.zig");
const sketch_overlap = @import("../sketch/overlap.zig");
const trace = @import("../io/trace.zig");
const Body = body_mod.Body;
const Affine = mat.Affine;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// `body` under `affine`, in `allocator`'s memory; the input is untouched.
pub fn transform(allocator: std.mem.Allocator, body: *const Body, input: *const Affine, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    for (input.linear) |v| try diagnostics.input.finite(diag, "the matrix", v);
    for (input.translation) |v| try diagnostics.input.finite(diag, "the matrix", v);
    try options.checkCancel();
    try trace.arguments(allocator, &options, "transform", .{ .linear = input.linear, .translation = input.translation });
    const tol = options.tolerance orelse body.tol;
    // A similarity to rounding as given; one within the tolerance over the body's reach
    // (a matrix typed to a few digits) as the similarity nearest it, which moves no point
    // of the body by more than the zone; anything further off the stretch or shear it is
    const given = geo_transform.classify(input);
    if (given == .singular) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .label = "the matrix's determinant", .measured = input.determinant() });
    const snapped: ?Affine = if (given == .general) geo_transform.nearSimilarity(input, tol, reachOf(body)) else null;
    const affine: *const Affine = if (snapped) |*near| near else input;
    const shape = if (snapped != null) geo_transform.classify(affine) else given;

    var out = body.clone(allocator) catch |e| return mapError(diag, e);
    errdefer out.deinit();
    const g = &out.geometry;
    if (shape == .similarity) out.tol = body.tol.scaled(shape.similarity.scale);

    // Points, with the gaps scaled by a similarity's factor
    const factor: f64 = switch (shape) {
        .similarity => |s| s.scale,
        else => 1.0,
    };
    for (g.points.items) |*p| p.* = affine.point(p.*);
    for (out.vertices.items) |*v| v.gap *= factor;
    for (out.edges.items) |*e| e.gap *= factor;

    // Curves: each record once, the lines' parameter factors kept for their edges
    const line_scale = try allocator.alloc(f64, g.lines.items.len);
    defer allocator.free(line_scale);
    for (g.lines.items, line_scale) |*l, *ls| {
        var t = geo_transform.curve(allocator, .{ .line = l.* }, 0, 1, affine, shape) catch |e| return mapError(diag, e);
        defer t.deinit(allocator);
        l.* = t.curve.line;
        ls.* = t.t_scale;
    }
    for (g.circles.items, 0..) |*c, i| {
        if (shape != .similarity) return notRepresentable(diag, .curve, i);
        var t = geo_transform.curve(allocator, .{ .circle = c.* }, 0, 1, affine, shape) catch |e| return mapError(diag, e);
        defer t.deinit(allocator);
        c.* = t.curve.circle;
    }
    for (g.ellipses.items, 0..) |*c, i| {
        if (shape != .similarity) return notRepresentable(diag, .curve, i);
        var t = geo_transform.curve(allocator, .{ .ellipse = c.* }, 0, 1, affine, shape) catch |e| return mapError(diag, e);
        defer t.deinit(allocator);
        c.* = t.curve.ellipse;
    }
    for (g.nurbs_curves.items) |rec| {
        for (g.point4_pool.items[rec.points.start .. rec.points.start + rec.points.len]) |*q| q.* = vec.weighted(affine.point(vec.project4(q.*)), q[3]);
    }
    for (g.nurbs_surfaces.items) |rec| {
        for (g.point4_pool.items[rec.points.start .. rec.points.start + rec.points.len]) |*q| q.* = vec.weighted(affine.point(vec.project4(q.*)), q[3]);
    }
    // Surfaces: each record once; the parameter factors per record, applied to the pcurves
    // of the faces on them
    for (g.planes.items) |*p| {
        var t = geo_transform.surface(allocator, .{ .plane = p.* }, geometry.Box2.empty, affine, shape) catch |e| return mapError(diag, e);
        defer t.deinit(allocator);
        p.* = t.surface.plane;
    }
    for (g.cylinders.items, 0..) |*c, i| {
        const k = similarityOr(shape, diag, .surface, i) catch |e| return e;
        c.* = .{ .frame = geo_transform.frame(c.frame, affine, k), .r = c.r * k };
    }
    for (g.cones.items, 0..) |*c, i| {
        const k = similarityOr(shape, diag, .surface, i) catch |e| return e;
        c.* = .{ .frame = geo_transform.frame(c.frame, affine, k), .r = c.r * k, .half_angle = c.half_angle };
    }
    for (g.spheres.items, 0..) |*s, i| {
        const k = similarityOr(shape, diag, .surface, i) catch |e| return e;
        s.* = .{ .frame = geo_transform.frame(s.frame, affine, k), .r = s.r * k };
    }
    for (g.tori.items, 0..) |*t, i| {
        const k = similarityOr(shape, diag, .surface, i) catch |e| return e;
        t.* = .{ .frame = geo_transform.frame(t.frame, affine, k), .major = t.major * k, .minor = t.minor * k };
    }
    for (g.revolutions.items, 0..) |*r, i| {
        const k = similarityOr(shape, diag, .surface, i) catch |e| return e;
        r.frame = geo_transform.frame(r.frame, affine, k);
    }
    for (g.extrusions.items, 0..) |*e, i| {
        // The generator was mapped with the curves; an arc generator under a stretch is
        // refused there
        const d = affine.vector(e.d);
        const len = vec.length(d);
        if (!(len > 0.0)) return notRepresentable(diag, .surface, i);
        e.d = vec.scale(d, 1.0 / len);
    }

    // Edge ranges on lines scale with the line's parameter
    for (out.edges.items) |*e| {
        if (e.flags.tombstone or e.curve.kind != .line) continue;
        const ls = line_scale[e.curve.index];
        e.t0 *= ls;
        e.t1 *= ls;
    }
    // Pcurves: v scales on cylinders, cones and extrusions (their v is a length), u on
    // nothing stored (planes compute theirs); a pcurve record serves one scaling
    const pcurve_scaled = try allocator.alloc(bool, g.lines2.items.len);
    defer allocator.free(pcurve_scaled);
    @memset(pcurve_scaled, false);
    for (out.coedges.items) |c| {
        if (c.tombstone or c.pcurve.isNone()) continue;
        const face = out.face(out.loop(c.loop).face);
        const v_scale: f64 = switch (face.surface.kind) {
            .cylinder, .cone => factor,
            .extrusion => vec.length(affine.vector(body.geometry.extrusions.items[face.surface.index].d)),
            else => 1.0,
        };
        const edge_scale: f64 = if (out.edge(c.edge).curve.kind == .line) line_scale[out.edge(c.edge).curve.index] else 1.0;
        if (v_scale == 1.0 and edge_scale == 1.0) continue;
        switch (c.pcurve.kind) {
            .line2 => {
                if (pcurve_scaled[c.pcurve.index]) continue;
                pcurve_scaled[c.pcurve.index] = true;
                const l = &g.lines2.items[c.pcurve.index];
                // pcurve'(t') = S · pcurve(t' / edge_scale)
                l.o = .{ l.o[0], l.o[1] * v_scale };
                l.d = .{ l.d[0] / edge_scale, l.d[1] * v_scale / edge_scale };
            },
            .circle2, .nurbs2 => return notRepresentable(diag, .coedge, 0),
        }
    }
    // UV boxes: v scales the same way
    for (out.faces.items, 0..) |*f, fi| {
        if (f.flags.tombstone or f.uv_box.isEmpty()) continue;
        switch (f.surface.kind) {
            .cylinder, .cone => {
                f.uv_box.min[1] *= factor;
                f.uv_box.max[1] *= factor;
            },
            .extrusion => {
                const k = vec.length(affine.vector(body.geometry.extrusions.items[f.surface.index].d));
                f.uv_box.min[1] *= k;
                f.uv_box.max[1] *= k;
            },
            .plane => {
                if (shape == .similarity) {
                    f.uv_box.min = .{ f.uv_box.min[0] * factor, f.uv_box.min[1] * factor };
                    f.uv_box.max = .{ f.uv_box.max[0] * factor, f.uv_box.max[1] * factor };
                } else {
                    f.uv_box = try planeBox(&out, types.FaceIndex.of(fi));
                }
            },
            else => {},
        }
    }

    // A mirror: outward normals flip with the handedness, so the senses do, and the loops
    // run the other way to keep the face on the left
    if (affine.determinant() < 0) try mirrorTopology(&out);
    try trace.phase(allocator, &options, &out, "transform", "mapped");

    var report = check.run(allocator, &out, if (out.kind == .sheet) .global else .geometric) catch return error.OutOfMemory;
    defer report.deinit(allocator);
    if (report.first()) |f| return diag.fail(if (report.onlySizes()) error.Degenerate else error.NotValid, f);
    if (shape == .general) try refuseStretched(allocator, &out, options, diag);
    try trace.phase(allocator, &options, &out, "transform", "checked");
    return out;
}

/// How far from the origin the body's points reach: what a change of the matrix moves them
/// in proportion to.
fn reachOf(body: *const Body) f64 {
    var reach: f64 = 0;
    for (body.vertices.items) |v| {
        if (v.tombstone) continue;
        reach = @max(reach, vec.length(body.geometry.point(v.point)));
    }
    return reach;
}

/// A body under a general map, which kept its tolerance and changed its distances unevenly:
/// a solid through the rules of a made solid, a sheet through the overlay's own rule (its
/// edges past the zone of each other), each refused below the feature size where the map
/// brought features too near (a tetrahedron 5e-5 high squashed to 1.5e-5, its sides in its
/// base's plane; a slit 3e-5 across squashed to 7.5e-6).
fn refuseStretched(allocator: std.mem.Allocator, out: *const Body, options: diagnostics.Options, diag: *Diagnostics) Error!void {
    var held = options;
    held.tolerance = out.tol;
    if (out.kind == .solid) {
        _ = try overlap.refuseMade(allocator, out, "faces of the stretched solid, within its features nearer than the minimum feature size,", held, diag);
        return;
    }
    var scratch = Diagnostics.init(allocator);
    defer scratch.deinit();
    sketch_overlap.check(allocator, out, &scratch) catch |e| switch (e) {
        error.NotValid => return diag.fail(error.Degenerate, .{ .code = .below_feature_size, .entity = scratch.first().?.entity, .label = "edges of the stretched sheet, within the zone of each other,", .measured = scratch.first().?.measured, .threshold = out.tol.zone }),
        else => {
            for (scratch.findings.items) |f| try diag.add(f);
            return e;
        },
    };
}

/// The UV box of a planar face from its loops' points, after the plane got new axes.
fn planeBox(body: *const Body, f: types.FaceIndex) Error!geometry.Box2 {
    const plane = body.geometry.planes.items[body.face(f).surface.index];
    var box = geometry.Box2.empty;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return error.NotValid) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return error.NotValid) |c| box.grow(plane.project(body.point(body.coedgeStart(c))));
    }
    return box;
}

fn mirrorTopology(out: *Body) Error!void {
    for (out.faces.items) |*f| {
        if (!f.flags.tombstone) f.same_sense = !f.same_sense;
    }
    for (out.coedges.items) |*c| {
        if (c.tombstone) continue;
        std.mem.swap(types.CoedgeIndex, &c.next, &c.prev);
        c.same_sense = !c.same_sense;
    }
    // A vertex's coedge left it; reversed, its partner does
    for (out.vertices.items, 0..) |*v, i| {
        if (v.tombstone or v.coedge == .none) continue;
        const partner = out.coedge(v.coedge).partner;
        if (partner != .none) {
            v.coedge = partner;
        } else {
            // A sheet's boundary: the coedge that now leaves the vertex is the one that
            // followed the old one in its loop, which ended... search the loop
            var it = traverse.Coedges.init(out, out.coedge(v.coedge).loop);
            while (it.next() catch return error.NotValid) |c| {
                if (out.coedgeStart(c) == types.VertexIndex.of(i)) {
                    v.coedge = c;
                    break;
                }
            }
        }
    }
}

fn similarityOr(shape: geo_transform.Shape, diag: *Diagnostics, kind: diagnostics.EntityKind, index: usize) Error!f64 {
    return switch (shape) {
        .similarity => |s| s.scale,
        else => notRepresentable(diag, kind, index),
    };
}

fn notRepresentable(diag: *Diagnostics, kind: diagnostics.EntityKind, index: usize) Error {
    return diag.fail(error.NotRepresentable, .{ .code = .not_implemented, .entity = .of(kind, index), .label = "a curved kind under a non-uniform scale", .threshold = 0 });
}

fn mapError(diag: *Diagnostics, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooMany => diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "entities" }),
        error.NotRepresentable => diag.fail(error.NotRepresentable, .{ .code = .not_implemented, .label = "a curved kind under a non-uniform scale" }),
        else => unreachable,
    };
}
