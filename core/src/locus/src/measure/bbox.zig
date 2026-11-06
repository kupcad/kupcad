//! Bounding boxes (docs/architecture.md §7.6): a face's from its edges' curve bounds over
//! their ranges and its surface's bounds over its UV box, a body's from its faces'. Exact
//! for the analytic kinds (circle and ellipse extremes, a sphere's and torus's interior
//! extremes), conservative (control points) for NURBS.

const std = @import("std");
const geometry = @import("../geometry/types.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Body = body_mod.Body;
const Box3 = geometry.Box3;

pub const Error = traverse.Error;

/// The box of a face: its edges' bounds, and its surface's over its UV box when it has one.
pub fn faceBounds(body: *const Body, f: types.FaceIndex) Error!Box3 {
    var box = Box3.empty;
    var loops = traverse.Loops.init(body, f);
    while (try loops.next()) |l| {
        var coedges = traverse.Coedges.init(body, l);
        while (try coedges.next()) |c| {
            const e = body.edge(body.coedge(c).edge);
            box = Box3.merge(box, body.geometry.curve(e.curve).bounds(e.t0, e.t1));
        }
        if (body.loop(l).vertex != .none) box.grow(body.point(body.loop(l).vertex));
    }
    const face = body.face(f);
    if (!face.uv_box.isEmpty()) box = Box3.merge(box, body.geometry.surface(face.surface).bounds(face.uv_box));
    return box;
}

/// The box of every face of the body; empty for the empty body.
pub fn bodyBounds(body: *const Body) Error!Box3 {
    var box = Box3.empty;
    var shells = traverse.Shells.init(body);
    while (try shells.next()) |s| {
        var faces = traverse.Faces.init(body, s);
        while (try faces.next()) |f| box = Box3.merge(box, try faceBounds(body, f));
    }
    return box;
}
