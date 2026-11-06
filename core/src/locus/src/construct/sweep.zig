//! Sweeps (docs/architecture.md §7.1): a planar sheet (a sketch) swept along a vector
//! (`extrude`) into a solid, by the generator × director table: a generator vertex along
//! the director makes an edge, a generator edge a face, the generator face the two caps.
//! The surface of each swept edge follows its kind: a line gives a plane, an arc swept
//! along its own normal a cylinder, any other curve (or an arc swept askew) a
//! linear-extrusion surface. The faces are sewn, as the primitives are, with every loop
//! counter-clockwise about its face's outward normal; a hole of the sheet is a hole
//! through the solid. Every record is addressed by index; the arrays the face
//! specifications point into are sized first and never grow.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
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
                    const low = try copyCurve(&b, curve, vec.ZERO3, pa, pb, coedge.same_sense);
                    const high = try copyCurve(&b, curve, direction, vec.add(pa, direction), vec.add(pb, direction), coedge.same_sense);
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
                    fi += 1;
                }
                const bottom_edges = cap_edges[first..ci];
                const top_edges = cap_edges[counts.coedges + first .. counts.coedges + ci];
                if (along > 0) reverseLoop(bottom_edges) else reverseLoop(top_edges);
                cap_loops[li] = .{ .edges = bottom_edges };
                cap_loops[counts.loops + li] = .{ .edges = top_edges };
            }
            specs[fi] = .{ .surface = bottom_plane, .loops = cap_loops[first_loop..li], .uv_box = bottom_box, .tag = face.tag };
            specs[fi + 1] = .{ .surface = top_plane, .loops = cap_loops[counts.loops + first_loop .. counts.loops + li], .uv_box = top_box, .tag = face.tag };
            fi += 2;
        }
    }
    return b.finish(specs, .outer);
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

/// A curve of the sheet in the new body, moved by `offset`, as the edge from `pa` to
/// `pb` runs it: `t0 < t1` its range, `forward` whether the edge runs from `t0` to `t1`
/// (`pa` at `t0`).
const Copied = struct { curve: geometry.CurveRef, t0: f64, t1: f64, forward: bool };

fn copyCurve(b: *Builder, curve: curves.Curve, offset: Vec3, pa: Vec3, pb: Vec3, same_sense: bool) Error!Copied {
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
            const ref = b.interner.circle(b.allocator, g, .{ .c = vec.add(c.c, offset), .x = c.x, .y = c.y, .r = c.r }) catch |e| return b.fail(e);
            return arcOn(ref, g.curve(ref), pa, pb, same_sense, b.body.tol);
        },
        .ellipse => |e| {
            const ref = g.addEllipse(b.allocator, .{ .c = vec.add(e.c, offset), .x = e.x, .y = e.y, .a = e.a, .b = e.b }) catch |err| return b.fail(err);
            return arcOn(ref, g.curve(ref), pa, pb, same_sense, b.body.tol);
        },
        .nurbs => return b.diag.fail(error.NotRepresentable, .{ .code = .not_implemented, .label = "a free-form profile edge" }),
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
