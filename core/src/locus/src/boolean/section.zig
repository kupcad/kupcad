//! The plane section of a solid (docs/architecture.md §7.3; Stroud p.187–192): KupCAD's
//! `slice`, the solid cut by the plane `z = height`, returned as a sketch (a sheet on
//! `z = 0`). The plane's trace on each face (`intersect/surface_surface.zig`) is imprinted
//! on the face: the trace is split where the face's edges cross the plane
//! (`intersect/curve_surface.zig`, each edge's crossings computed once, so the faces on
//! either side of an edge split at the same points), and each piece is kept when its middle
//! lies inside the face (`query/in_face.zig`). Each kept piece bounds the section with the
//! material on its left, running along `n_plane × n_face`. The pieces are one input of the
//! overlay (§7.3), and the faces it winds about once are the section's faces.
//!
//! On the plane itself the section is the solid just above it, as the mesh engine slices
//! (a triangle counts when its lowest corner is at or below the height and its highest
//! above): a face lying in the plane gives nothing, and an edge lying in it bounds the
//! section from each face that rises from it, so a cube cut at its bottom is its bottom
//! square and at its top is nothing, and the two faces of a groove's floor cancel. A face
//! only touching the plane (a sphere's pole, a lying cylinder's side, a torus's crown)
//! gives nothing either: just above, it is a sliver of no area.
//!
//! A trace that is neither a line nor a circle (a tilted cylinder's ellipse) has no edge
//! in a sketch yet, and the cases `planeSurface` refuses wait for M5: both are
//! `NotImplemented` naming the face.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trace = @import("../io/trace.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const bbox = @import("../measure/bbox.zig");
const in_face = @import("../query/in_face.zig");
const curve_surface = @import("../intersect/curve_surface.zig");
const surface_surface = @import("../intersect/surface_surface.zig");
const overlay_mod = @import("../sketch/overlay.zig");
const sketch_boolean = @import("../sketch/boolean.zig");
const Body = body_mod.Body;
const Overlay = overlay_mod.Overlay;
const InputEdge = overlay_mod.InputEdge;
const Plane = curve_surface.Plane;
const Curve = curves.Curve;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;
const TWO_PI = geometry.TWO_PI;

/// The milestone of sketches whose edges are other curves than lines and arcs: none is
/// planned yet, so a refusal names no milestone.
const NO_MILESTONE = 0;

/// The section of `body` (a solid) by the plane `z = height`, as a sheet on `z = 0`: the
/// solid just above the plane (see the file's comment). A plane that misses the solid gives
/// the empty sheet.
pub fn slice(allocator: std.mem.Allocator, body: *const Body, height: f64, options: diagnostics.Options, diag: *Diagnostics) Error!Body {
    try diagnostics.input.finite(diag, "height", height);
    try options.checkCancel();
    try trace.arguments(allocator, &options, "slice", .{ .height = height });
    if (body.kind != .solid) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "the body: a solid" });
    const tol = options.tolerance orelse body.tol;
    var o = Overlay.init(allocator, tol);
    defer o.deinit();
    _ = o.addInput() catch |e| return sketch_boolean.mapError(diag, e);
    var section: Section = .{ .allocator = allocator, .body = body, .tol = tol, .plane = Plane.level(height), .o = &o, .diag = diag };
    defer section.deinit();
    section.cuts = try allocator.alloc(?Cut, body.edges.items.len);
    @memset(section.cuts, null);
    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(body, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            try options.checkCancel();
            try section.face(f);
        }
    }
    o.run() catch |e| return sketch_boolean.mapError(diag, e);
    const keep = try allocator.alloc(bool, o.faces.items.len);
    defer allocator.free(keep);
    for (keep, 0..) |*k, f| k.* = o.windingOf(@intCast(f), 0) > 0;
    var sheet = try sketch_boolean.build(allocator, tol, &o, keep, diag);
    errdefer sheet.deinit();
    try trace.phase(allocator, &options, &sheet, "slice", "section");
    return sheet;
}

/// Where an edge meets the plane: the whole edge, or its crossing points (a crossing
/// within the zone of an end is that end's vertex, exactly).
const Cut = struct {
    lies_in: bool = false,
    count: u8 = 0,
    points: [curve_surface.MAX_CROSSINGS]Vec3 = undefined,
};

/// A point where a face's boundary meets the plane, at parameter `t` of the trace curve it
/// lies on.
const Mark = struct {
    t: f64,
    p: Vec3,

    fn before(_: void, a: Mark, b: Mark) bool {
        return a.t < b.t;
    }
};

const Section = struct {
    allocator: std.mem.Allocator,
    body: *const Body,
    tol: Tolerance,
    plane: Plane,
    o: *Overlay,
    diag: *Diagnostics,
    /// Each edge's cut, once computed.
    cuts: []?Cut = &.{},
    /// The current face's boundary points on the plane, and those of one trace curve.
    points: std.ArrayList(Vec3) = .empty,
    marks: std.ArrayList(Mark) = .empty,

    fn deinit(self: *Section) void {
        self.allocator.free(self.cuts);
        self.points.deinit(self.allocator);
        self.marks.deinit(self.allocator);
    }

    /// Face `f`'s share of the section: its trace's pieces inside it, and its edges lying
    /// in the plane when it rises from them.
    fn face(self: *Section, f: types.FaceIndex) Error!void {
        const body = self.body;
        const box = bbox.faceBounds(body, f) catch return corrupt(self.diag);
        if (box.isEmpty()) return;
        const h = self.plane.d;
        if (box.max[2] < h - self.tol.zone or box.min[2] > h + self.tol.zone) return;
        // A face lying in a level plane: its edges are the section's from the faces rising
        // from them, when it is on the plane
        if (box.max[2] - box.min[2] <= self.tol.zone) return;
        self.points.clearRetainingCapacity();
        var loops = traverse.Loops.init(body, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            const lone = body.loop(l).vertex;
            if (lone != .none and @abs(self.plane.height(body.point(lone))) <= self.tol.zone) try self.addPoint(body.point(lone));
            var it = traverse.Coedges.init(body, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const e = body.coedge(c).edge;
                const cut = try self.cutOf(e);
                if (cut.lies_in) {
                    try self.addPoint(body.point(body.edge(e).start));
                    try self.addPoint(body.point(body.edge(e).end));
                    try self.edgeInPlane(f, c);
                } else for (cut.points[0..cut.count]) |p| try self.addPoint(p);
            }
        }
        const near = vec.scale(vec.add(box.min, box.max), 0.5);
        const extent = vec.distance(box.min, box.max);
        const surface = body.geometry.surface(body.face(f).surface);
        const traced = surface_surface.planeSurface(self.plane, surface, near, extent, self.tol, self.diag) catch |e| return self.refused(e, f);
        if (traced.kind != .curves) return;
        for (traced.slice()) |curve| try self.tracePieces(f, curve);
    }

    /// A refusal of `planeSurface`'s, its finding naming face `f`.
    fn refused(self: *Section, err: Error, f: types.FaceIndex) Error {
        if (self.diag.findings.items.len > 0) self.diag.findings.items[self.diag.findings.items.len - 1].entity = .of(.face, @backingInt(f));
        return err;
    }

    fn addPoint(self: *Section, p: Vec3) Error!void {
        for (self.points.items) |q| if (self.tol.samePoint(p, q)) return;
        try self.points.append(self.allocator, p);
    }

    /// Edge `e`'s cut, computed on the first ask.
    fn cutOf(self: *Section, e: types.EdgeIndex) Error!Cut {
        const i = @backingInt(e);
        if (self.cuts[i]) |cut| return cut;
        const body = self.body;
        const edge = body.edge(e);
        var cut: Cut = .{};
        if (!edge.flags.degenerate) {
            const curve = body.geometry.curve(edge.curve);
            const crossings = try curve_surface.curvePlane(curve, edge.t0, edge.t1, self.plane, self.tol.zone, self.diag);
            cut.lies_in = crossings.lies_in;
            const ends = [2]Vec3{ body.point(edge.start), body.point(edge.end) };
            for (crossings.params()) |t| {
                var p = curve.eval(t);
                for (ends) |end| if (self.tol.samePoint(p, end)) {
                    p = end;
                };
                var seen = false;
                for (cut.points[0..cut.count]) |q| seen = seen or self.tol.samePoint(p, q);
                if (seen) continue;
                cut.points[cut.count] = p;
                cut.count += 1;
            }
        }
        self.cuts[i] = cut;
        return cut;
    }

    /// The pieces of `curve` (the plane's trace on face `f`'s surface) inside the face,
    /// between the face's boundary points on it.
    fn tracePieces(self: *Section, f: types.FaceIndex, curve: Curve) Error!void {
        const periodic = switch (curve) {
            .line => false,
            .circle => true,
            else => return self.diag.fail(error.NotImplemented, .{ .code = .not_implemented, .entity = .of(.face, @backingInt(f)), .label = "a section whose trace on a face is an ellipse (a sketch's edges are lines and arcs)", .threshold = NO_MILESTONE }),
        };
        self.marks.clearRetainingCapacity();
        for (self.points.items) |p| {
            const t = switch (curve) {
                .line => |line| line.project(p),
                .circle => |circle| circle.project(p),
                else => unreachable,
            };
            if (vec.distance(curve.eval(t), p) <= self.tol.xsect) try self.marks.append(self.allocator, .{ .t = t, .p = p });
        }
        std.mem.sort(Mark, self.marks.items, {}, Mark.before);
        const marks = self.marks.items;
        if (!periodic) {
            if (marks.len < 2) return;
            for (marks[0 .. marks.len - 1], marks[1..]) |a, b| try self.piece(f, curve, a, b);
            return;
        }
        if (marks.len == 0) {
            // A whole circle, inside the face or not
            const start: Mark = .{ .t = 0, .p = curve.eval(0) };
            return self.piece(f, curve, start, .{ .t = TWO_PI, .p = start.p });
        }
        for (marks, 0..) |a, k| {
            const b: Mark = if (k + 1 < marks.len) marks[k + 1] else .{ .t = marks[0].t + TWO_PI, .p = marks[0].p };
            try self.piece(f, curve, a, b);
        }
    }

    /// The piece of `curve` from `a` to `b`, kept when its middle is inside face `f`.
    fn piece(self: *Section, f: types.FaceIndex, curve: Curve, a: Mark, b: Mark) Error!void {
        if (self.tol.samePoint(a.p, b.p) and b.t - a.t < std.math.pi) return;
        const mid = curve.eval((a.t + b.t) / 2);
        const uv = in_face.uvOf(self.body, f, mid);
        const place = try in_face.classify(self.body, f, mid, uv, self.tol.zone, self.diag);
        if (place != .inside) return;
        const dir = vec.cross(self.plane.n, in_face.outwardNormal(self.body, f, uv));
        try self.add(curve, a, b, dir);
    }

    /// Edge `e` of face `f` (by coedge `c`), lying in the plane: a bound of the section
    /// when the face rises from it, running with the material of the face's side on its
    /// left.
    fn edgeInPlane(self: *Section, f: types.FaceIndex, c: types.CoedgeIndex) Error!void {
        const body = self.body;
        const coedge = body.coedge(c);
        const edge = body.edge(coedge.edge);
        if (edge.flags.degenerate) return;
        const curve = body.geometry.curve(edge.curve);
        const tm = (edge.t0 + edge.t1) / 2;
        const sample = curve.sample(tm);
        const along = vec.normalized(if (coedge.same_sense) sample.d1 else vec.neg(sample.d1)) orelse return;
        const uv = in_face.uvOf(body, f, sample.p);
        const n = in_face.outwardNormal(body, f, uv);
        // A curved face tangent to the plane along the edge (a lying cylinder split at its
        // side) leaves a sliver of no area above it
        if (body.face(f).surface.kind != .plane and self.tol.parallel(n, self.plane.n)) return;
        // Into the face, across the edge: the face lies left of its coedge seen from outside
        if (vec.dot(vec.cross(n, along), self.plane.n) <= 0) return;
        const dir = vec.cross(self.plane.n, n);
        const start: Mark = .{ .t = edge.t0, .p = body.point(edge.start) };
        const end: Mark = .{ .t = edge.t1, .p = body.point(edge.end) };
        switch (curve) {
            .line, .circle => try self.add(curve, start, end, dir),
            else => return self.diag.fail(error.NotImplemented, .{ .code = .not_implemented, .entity = .of(.edge, @backingInt(coedge.edge)), .label = "a section along an edge that is neither a line nor an arc", .threshold = NO_MILESTONE }),
        }
    }

    /// The piece of `curve` from `a` to `b` (increasing parameter) as an overlay edge on
    /// `z = 0` running along `dir` (any length): a line's ends swapped when it runs against
    /// it, an arc run clockwise from `b` when the circle's turn is against it, and an arc
    /// of more than half a turn in two halves (an arc from a point to itself has no
    /// direction).
    fn add(self: *Section, curve: Curve, a: Mark, b: Mark, dir: Vec3) Error!void {
        switch (curve) {
            .line => {
                const forward = vec.dot(dir, vec.sub(b.p, a.p)) >= 0;
                try self.emit(if (forward) .{ .a = flat(a.p), .b = flat(b.p) } else .{ .a = flat(b.p), .b = flat(a.p) });
            },
            .circle => |circle| {
                if (b.t - a.t > std.math.pi) {
                    const mid: Mark = .{ .t = (a.t + b.t) / 2, .p = circle.eval((a.t + b.t) / 2) };
                    try self.add(curve, a, mid, dir);
                    return self.add(curve, mid, b, dir);
                }
                // The circle's turn seen from above: counter-clockwise when its normal is up
                const up = vec.dot(circle.normal(), self.plane.n) > 0;
                const forward = vec.dot(dir, circle.sample((a.t + b.t) / 2).d1) >= 0;
                const arc: overlay_mod.Arc = .{ .c = flat(circle.c), .r = circle.r, .ccw = up == forward };
                try self.emit(if (forward) .{ .a = flat(a.p), .b = flat(b.p), .arc = arc } else .{ .a = flat(b.p), .b = flat(a.p), .arc = arc });
            },
            else => unreachable,
        }
    }

    fn emit(self: *Section, e: InputEdge) Error!void {
        self.o.addEdge(e) catch |err| return sketch_boolean.mapError(self.diag, err);
    }
};

fn flat(p: Vec3) Vec2 {
    return .{ p[0], p[1] };
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
