//! The gaps of edges and vertices grown to cover where their curves and points lie (OCCT's
//! `UpdateVertex`, `CorrectCurveOnSurface` and `SameParameter`): one rule for whatever sets
//! or edits an edge's geometry, the boolean's provenance and simplify's edits, and the
//! builders of what an operation makes of its input (the sweeps, a hull, a polyhedron).
//! The margin is on the set side, with D27's band, and the checker stays strict.

const std = @import("std");
const vec = @import("../math/vec.zig");
const diagnostics = @import("../diagnostics.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const canonical = @import("../geometry/canonical.zig");
const types = @import("types.zig");
const body_mod = @import("body.zig");
const traverse = @import("traverse.zig");
const check = @import("check.zig");
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// Vertex `v`'s gap grown to cover its distance from `line` beyond the intersection
/// tolerance, as the checker holds an edge's ends to its curve (`vertex_off_curve`) and OCCT
/// grows a vertex's tolerance to the edges it ends (`UpdateVertex`): the one rule for
/// whatever puts a vertex at the end of an edge off its line, the boolean's builder (a
/// pave on an edge by the segment between its merged ends, `Provenance.piece`, through
/// `carryLine`, whose edge carries what passes the zone) and the
/// short-edge collapse (an edge moved from the vertex gone to the one kept; the 10K session
/// on 6007ab01: a hull's edge moved to a box's corner 2.0138e-5 off its line, at a
/// tolerance of 2e-5, with no gap). The gap covers the distance's rounding too (D27's
/// band): the checker measures from the line at the vertex's projection, a rounding from
/// `lineOffset` at the coordinates' size, and the offset's excess alone fell 9e-17 short
/// of it in the same find. Past the zone, refused (`gap_too_large`), naming `entity` with
/// `label`.
pub fn coverLine(body: *Body, v: types.VertexIndex, line: curves.Line, entity: diagnostics.EntityRef, label: []const u8, diag: *Diagnostics) Error!void {
    const p = body.point(v);
    const offset = canonical.lineOffset(line, p);
    const gap = offset - body.tol.xsect + canonical.Comparison.distance(offset, body.tol.xsect, canonical.magnitude(&.{ p, line.o })).band;
    if (gap <= body.vertex(v).gap) return;
    if (gap > body.tol.zone) return diag.fail(error.Degenerate, .{ .code = .gap_too_large, .entity = entity, .label = label, .measured = gap, .threshold = body.tol.zone });
    body.vertex(v).gap = gap;
}

/// The gaps of a new edge on `line` from vertex `ends[0]` to `ends[1]`, each of which the
/// paves put on an edge of that line within the tolerance, its gap and the edge's
/// (`incidence.Decider.onEdge`, from the segment between the edge's merged ends): each
/// vertex's gap grown to cover its distance from the line beyond the intersection
/// tolerance up to the zone, as `coverLine` grows it, and the rest carried by the edge;
/// returns the edge's gap. The checker holds an edge's end within the tolerance and both
/// gaps (`vertex_off_curve`), and the paves accepted the vertex on the edge by both: a
/// vertex with a gap on an edge with one may lie past the tolerance and the zone from the
/// line, and held by its own gap alone it was refused (audit B's B23; Leo 2026-11-28: a
/// gap the paves accepted is carried, not measured again; `coverLine`'s other callers,
/// the short-edge collapse and a map, put no vertex on an edge the paves accepted and keep
/// the vertex's gap alone). Taken over both ends at once, so neither end's order decides
/// the other's gap; `coverEdge` then raises the ends to the edge's gap (`gap_order`). Each
/// needed gap covers the distance's rounding (D27's band, as `coverLine`). Past what the
/// two gaps hold, the tolerance and twice the zone, refused (`gap_too_large`), naming the
/// farther end's entry of `entities` with `label`: the paves measure from the segment
/// between the edge's merged ends, the result keeps the line (D28), and an end gapped off
/// the line moves the segment off it by up to its own reach.
pub fn carryLine(body: *Body, ends: [2]types.VertexIndex, line: curves.Line, entities: [2]diagnostics.EntityRef, label: []const u8, diag: *Diagnostics) Error!f64 {
    const zone = body.tol.zone;
    var needed: [2]f64 = undefined;
    var gap: f64 = 0;
    for (ends, &needed) |v, *n| {
        const p = body.point(v);
        const offset = canonical.lineOffset(line, p);
        n.* = offset - body.tol.xsect + canonical.Comparison.distance(offset, body.tol.xsect, canonical.magnitude(&.{ p, line.o })).band;
        gap = @max(gap, n.* - zone);
    }
    const farther: usize = if (needed[1] > needed[0]) 1 else 0;
    if (gap > zone) return diag.fail(error.Degenerate, .{ .code = .gap_too_large, .entity = entities[farther], .label = label, .measured = needed[farther], .threshold = 2 * zone });
    for (ends, needed) |v, n| body.vertex(v).gap = @max(body.vertex(v).gap, @min(n, zone));
    return gap;
}

/// Edge `e`'s gap grown to cover its line's height over each of its faces' planes past the
/// intersection tolerance, measured at its two ends (a line's height over a plane is
/// linear, so its ends bound it), with the height's rounding (D27's band, at the size of
/// the line's origin, the end and the plane's: the checker measures the same distance
/// another way, projecting points along the edge onto the face, and a gap of the height as
/// the plane gave it left an edge 5.5e-16 off its face, find bx), and its end vertices'
/// gaps grown to the edge's, as the checker orders them (`gap_order`; OCCT's
/// `UpdateVertex`). The one rule for an edge's gap wherever its line, range or ends are
/// set: the builder's provenance (`pipeline.coverFaces`, OCCT's `CorrectCurveOnSurface`),
/// and every later edit of an edge, a run joined into one edge (`joinRun`) and the edges
/// moved to the vertex a short edge collapsed into (`collapseShortEdges`): measured where
/// the edge ends up, not carried over from the pieces it came from or the ends it had, as
/// OCCT re-validates tolerances after `UnifySameDomain` or ShapeFix (the audit of
/// 2026-11-22: a joined edge took its largest piece's gap while the run's other end kept
/// its own, smaller, and the boolean's result failed its check). Past the zone, refused
/// (`gap_too_large`). On a curved face, an edge of any curve is covered for its pcurve's
/// lift beyond the approximation tolerance, measured at the samples the checker holds it
/// at (`check.pcurveLift`, `pcurve_off_edge`), as OCCT's `SameParameter` grows an edge's
/// tolerance to its pcurves: a sheet's vertex off its arc's circle within the zone, swept,
/// made an edge through the vertex (a line extruded, a circle revolved) whose pcurve at
/// the arc's end lifted onto the arc's surface, the vertex's offset away, and a valid
/// sheet's sweep failed its check (batch E's probe, cr, 2026-11-22).
pub fn coverEdge(body: *Body, e: types.EdgeIndex, diag: *Diagnostics) Error!void {
    const tol = body.tol;
    const edge = body.edge(e);
    const curve = body.geometry.curve(edge.curve);
    var gap = edge.gap;
    for (traverse.coedgesOfEdge(body, e)) |c| {
        if (c == .none) continue;
        const coedge = body.coedge(c);
        const face = body.face(body.loop(coedge.loop).face);
        switch (face.surface.kind) {
            .plane => if (curve == .line) {
                const line = curve.line;
                const plane = body.geometry.planes.items[face.surface.index];
                for ([_]f64{ edge.t0, edge.t1 }) |t| {
                    const end = line.eval(t);
                    const height = @abs(plane.height(end));
                    const rounding = canonical.Comparison.distance(height, tol.xsect, canonical.magnitude(&.{ line.o, end, plane.frame.origin })).band;
                    gap = @max(gap, height + rounding - tol.xsect);
                }
            },
            else => if (!coedge.pcurve.isNone()) {
                const apart = check.pcurveLift(body, c);
                const rounding = canonical.Comparison.distance(apart, tol.approx, canonical.magnitude(&.{ curve.eval(edge.t0), curve.eval(edge.t1) })).band;
                gap = @max(gap, apart + rounding - tol.approx);
            },
        }
    }
    if (gap > tol.zone) return diag.fail(error.Degenerate, .{ .code = .gap_too_large, .entity = .of(.edge, @backingInt(e)), .label = "an edge whose line leaves its faces' planes past the intersection tolerance by", .measured = gap, .threshold = tol.zone });
    edge.gap = gap;
    for ([_]types.VertexIndex{ edge.start, edge.end }) |v| body.vertex(v).gap = @max(body.vertex(v).gap, gap);
}

/// Every live edge of `body` and its ends re-measured where they now lie: each end of an
/// edge on a line by `coverLine`, each edge by `coverEdge`. The rule for a body whose
/// coordinates all changed at once (`construct/transform`): a rigid move far out rounds
/// every point, line and plane at the new size, and the gaps set with D27's band at the
/// old size do not cover it (audit 2's item 4: a union whose edge lay within the
/// intersection tolerance of a sloped face, 2e-4 to rounding at coordinates of 200, moved
/// 3e5 out had it 1e-11 past). OCCT moves a shape by a `TopLoc_Location`, never rounding
/// its geometry, and re-validates its tolerances where an edit changes geometry (ShapeFix);
/// a map here rewrites the coordinates, so it re-measures, with the band at the size it
/// left them. Gaps only grow; past the zone, refused (`gap_too_large`).
pub fn coverBody(body: *Body, diag: *Diagnostics) Error!void {
    for (body.edges.items, 0..) |edge, i| {
        if (edge.flags.tombstone) continue;
        const e = types.EdgeIndex.of(i);
        if (edge.curve.kind == .line) {
            const line = body.geometry.lines.items[edge.curve.index];
            for ([_]types.VertexIndex{ edge.start, edge.end }) |v| try coverLine(body, v, line, .of(.vertex, @backingInt(v)), "a vertex the map left off its edge's line past the intersection tolerance by", diag);
        }
        try coverEdge(body, e, diag);
    }
}
