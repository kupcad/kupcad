//! The checker (docs/architecture.md §9.1): `run(body, level)` is a pure function giving
//! the findings, in the order of the rules, stopping at the first structural failure so no
//! geometric rule reads a corrupt graph. Level 0: structural; 1: and orientation and
//! geometric; 2 (later): and the global rules. Every test ends with it; every operation's
//! result passes it or the operation fails with the finding.

const std = @import("std");
const builtin = @import("builtin");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("types.zig");
const body_mod = @import("body.zig");
const traverse = @import("traverse.zig");
const Body = body_mod.Body;
const Finding = diagnostics.Finding;
const EntityRef = diagnostics.EntityRef;
const VertexIndex = types.VertexIndex;
const EdgeIndex = types.EdgeIndex;
const CoedgeIndex = types.CoedgeIndex;
const LoopIndex = types.LoopIndex;
const FaceIndex = types.FaceIndex;
const ShellIndex = types.ShellIndex;

pub const Error = error{OutOfMemory};

/// The rules, as diagnostics codes.
pub const Rule = diagnostics.Code;

pub const Level = enum(u8) { structural = 0, geometric = 1, global = 2 };

/// The findings of a run; empty for a valid body.
pub const Report = struct {
    findings: std.ArrayList(Finding) = .empty,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        self.findings.deinit(allocator);
        self.* = undefined;
    }

    pub fn ok(self: *const Report) bool {
        return self.findings.items.len == 0;
    }

    pub fn first(self: *const Report) ?Finding {
        return if (self.findings.items.len == 0) null else self.findings.items[0];
    }
};

/// Checks `body` up to `level`. `samples`: points per edge for the geometric rules.
pub fn run(allocator: std.mem.Allocator, body: *const Body, level: Level) Error!Report {
    var report: Report = .{};
    errdefer report.deinit(allocator);
    var checker = Checker{ .allocator = allocator, .body = body, .report = &report };
    try checker.structural();
    if (!report.ok() or level == .structural) return report;
    try checker.orientation();
    try checker.geometric();
    return report;
}

/// Panics on a structural finding: what the Euler operators call in Debug and tests.
pub fn assertStructural(body: *const Body) void {
    var report = run(body.allocator, body, .structural) catch return;
    defer report.deinit(body.allocator);
    if (report.first()) |f| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        f.format(&w) catch {};
        @panic(w.buffered());
    }
}

/// Samples along an edge for the geometric rules (OCCT uses 23).
const EDGE_SAMPLES = 7;

const Checker = struct {
    allocator: std.mem.Allocator,
    body: *const Body,
    report: *Report,

    fn add(self: *Checker, rule: Rule, entity: EntityRef, measured: f64, threshold: f64) Error!void {
        try self.report.findings.append(self.allocator, .{ .code = rule, .entity = entity, .measured = measured, .threshold = threshold });
    }

    fn live(comptime T: type, item: T) bool {
        return if (@hasField(T, "flags")) !item.flags.tombstone else !item.tombstone;
    }

    // --- structural ---

    fn structural(self: *Checker) Error!void {
        const b = self.body;
        // Every index in range, and pointing at a live entity
        for (b.vertices.items, 0..) |v, i| {
            if (!live(types.Vertex, v)) continue;
            if (@backingInt(v.point) >= b.geometry.points.items.len) try self.add(.index_out_of_range, .of(.vertex, i), @floatFromInt(@backingInt(v.point)), 0);
            if (!self.liveCoedge(v.coedge, true)) try self.add(.index_out_of_range, .of(.vertex, i), 0, 0);
        }
        for (b.edges.items, 0..) |e, i| {
            if (!live(types.Edge, e)) continue;
            if (!self.liveVertex(e.start) or !self.liveVertex(e.end)) try self.add(.index_out_of_range, .of(.edge, i), 0, 0);
            if (!self.liveCoedge(e.coedge, false)) try self.add(.index_out_of_range, .of(.edge, i), 0, 0);
            if (!self.liveCurve(e.curve)) try self.add(.index_out_of_range, .of(.edge, i), 0, 0);
        }
        for (b.coedges.items, 0..) |c, i| {
            if (!live(types.Coedge, c)) continue;
            if (!self.liveEdge(c.edge) or !self.liveLoop(c.loop) or !self.liveCoedge(c.next, false) or !self.liveCoedge(c.prev, false) or !self.liveCoedge(c.partner, true)) try self.add(.index_out_of_range, .of(.coedge, i), 0, 0);
        }
        for (b.loops.items, 0..) |l, i| {
            if (!live(types.Loop, l)) continue;
            if (!self.liveFace(l.face) or !self.liveCoedge(l.first, true) or !self.liveVertex(l.vertex) and l.vertex != .none or !self.liveLoop(l.next_in_face) and l.next_in_face != .none) try self.add(.index_out_of_range, .of(.loop, i), 0, 0);
        }
        for (b.faces.items, 0..) |f, i| {
            if (!live(types.Face, f)) continue;
            if (!self.liveShell(f.shell) or !self.liveSurface(f.surface) or (f.next_in_shell != .none and !self.liveFace(f.next_in_shell)) or (f.first_loop != .none and !self.liveLoop(f.first_loop))) try self.add(.index_out_of_range, .of(.face, i), 0, 0);
        }
        for (b.shells.items, 0..) |s, i| {
            if (!live(types.Shell, s)) continue;
            if ((s.first_face != .none and !self.liveFace(s.first_face)) or (s.next_in_body != .none and !self.liveShell(s.next_in_body))) try self.add(.index_out_of_range, .of(.shell, i), 0, 0);
        }
        if (!self.report.ok()) return;

        // Every loop closes within the coedge count and its coedges name it
        var coedges_in_loops: usize = 0;
        for (b.loops.items, 0..) |l, i| {
            if (!live(types.Loop, l)) continue;
            if (l.first == .none) {
                if (l.vertex == .none) try self.add(.loop_empty, .of(.loop, i), 0, 0);
                continue;
            }
            var it = traverse.Coedges.init(b, LoopIndex.of(i));
            var n: usize = 0;
            while (it.next() catch {
                try self.add(.loop_not_closed, .of(.loop, i), 0, 0);
                break;
            }) |c| {
                n += 1;
                if (b.coedge(c).loop != LoopIndex.of(i)) try self.add(.coedge_loop_disagrees, .of(.coedge, @backingInt(c)), 0, 0);
            }
            coedges_in_loops += n;
        }
        // next/prev reciprocal; coedge.loop agrees with the loop it is reached from
        for (b.coedges.items, 0..) |c, i| {
            if (!live(types.Coedge, c)) continue;
            if (b.coedge(c.next).prev != CoedgeIndex.of(i)) try self.add(.next_prev_not_reciprocal, .of(.coedge, i), 0, 0);
            // partner reciprocal and opposite
            if (c.partner != .none) {
                const p = b.coedge(c.partner);
                if (p.partner != CoedgeIndex.of(i)) try self.add(.partner_not_reciprocal, .of(.coedge, i), 0, 0);
                if (p.edge != c.edge) try self.add(.partner_not_reciprocal, .of(.coedge, i), 0, 0);
                if (p.same_sense == c.same_sense) try self.add(.partner_same_sense, .of(.coedge, i), 0, 0);
            }
            // The next coedge starts where this one ends: the same vertex record
            if (b.coedgeEnd(CoedgeIndex.of(i)) != b.coedgeStart(c.next)) try self.add(.loop_not_connected, .of(.coedge, i), 0, 0);
        }
        // An edge has one or two coedges, both naming it
        var coedge_uses = std.ArrayList(u8).empty;
        defer coedge_uses.deinit(self.allocator);
        try coedge_uses.appendNTimes(self.allocator, 0, b.edges.items.len);
        for (b.coedges.items) |c| {
            if (!live(types.Coedge, c)) continue;
            coedge_uses.items[@backingInt(c.edge)] +|= 1;
        }
        for (b.edges.items, 0..) |e, i| {
            if (!live(types.Edge, e)) continue;
            const uses = coedge_uses.items[i];
            if (uses == 0 or uses > 2) try self.add(.edge_coedge_count, .of(.edge, i), @floatFromInt(uses), 2);
            if (b.coedge(e.coedge).edge != EdgeIndex.of(i)) try self.add(.edge_coedge_count, .of(.edge, i), 0, 0);
            // Degenerate edges have start == end, no other edge does; and a degenerate edge
            // (a pole, an apex) belongs to one face
            if (e.flags.degenerate != (e.start == e.end)) try self.add(.degenerate_edge_vertices, .of(.edge, i), 0, 0);
            if (e.flags.degenerate and uses == 2) try self.add(.edge_coedge_count, .of(.edge, i), 2, 1);
            if (!(e.t0 < e.t1)) try self.add(.edge_range_reversed, .of(.edge, i), e.t0, e.t1);
        }
        // A vertex's coedge leaves it
        for (b.vertices.items, 0..) |v, i| {
            if (!live(types.Vertex, v) or v.coedge == .none) continue;
            if (b.coedgeStart(v.coedge) != VertexIndex.of(i)) try self.add(.vertex_coedge_not_leaving, .of(.vertex, i), 0, 0);
        }
        // Each face's loops name it and the face is in exactly one shell's list
        var face_seen = std.ArrayList(u8).empty;
        defer face_seen.deinit(self.allocator);
        try face_seen.appendNTimes(self.allocator, 0, b.faces.items.len);
        var shells = traverse.Shells.init(b);
        while (shells.next() catch {
            try self.add(.shell_list_not_closed, .of(.body, 0), 0, 0);
            return;
        }) |s| {
            var faces = traverse.Faces.init(b, s);
            while (faces.next() catch {
                try self.add(.shell_list_not_closed, .of(.shell, @backingInt(s)), 0, 0);
                return;
            }) |f| {
                face_seen.items[@backingInt(f)] +|= 1;
                if (b.face(f).shell != s) try self.add(.face_shell_disagrees, .of(.face, @backingInt(f)), 0, 0);
                var loops = traverse.Loops.init(b, f);
                var n: usize = 0;
                while (loops.next() catch {
                    try self.add(.loop_not_closed, .of(.face, @backingInt(f)), 0, 0);
                    break;
                }) |l| {
                    n += 1;
                    if (b.loop(l).face != f) try self.add(.loop_face_disagrees, .of(.loop, @backingInt(l)), 0, 0);
                }
                if (n == 0) try self.add(.face_without_loop, .of(.face, @backingInt(f)), 0, 0);
            }
        }
        for (b.faces.items, 0..) |f, i| {
            if (!live(types.Face, f)) continue;
            if (face_seen.items[i] != 1) try self.add(.face_shell_count, .of(.face, i), @floatFromInt(face_seen.items[i]), 1);
        }
        if (!self.report.ok()) return;
        // Euler–Poincaré per shell: V − E + F − (L − F) = 2(S − G), G a whole number ≥ 0
        try self.eulerPoincare();
    }

    fn eulerPoincare(self: *Checker) Error!void {
        const b = self.body;
        // One mark per vertex and edge, cleared per shell: the counts of a shell's
        // entities through its faces
        const vertex_seen = try self.allocator.alloc(bool, b.vertices.items.len);
        defer self.allocator.free(vertex_seen);
        const edge_seen = try self.allocator.alloc(bool, b.edges.items.len);
        defer self.allocator.free(edge_seen);
        var shells = traverse.Shells.init(b);
        while (shells.next() catch return) |s| {
            if (b.shell(s).kind == .sheet) continue;
            @memset(vertex_seen, false);
            @memset(edge_seen, false);
            var faces_n: i64 = 0;
            var loops_n: i64 = 0;
            var faces = traverse.Faces.init(b, s);
            while (faces.next() catch return) |f| {
                faces_n += 1;
                var loops = traverse.Loops.init(b, f);
                while (loops.next() catch return) |l| {
                    loops_n += 1;
                    if (b.loop(l).vertex != .none) vertex_seen[@backingInt(b.loop(l).vertex)] = true;
                    var it = traverse.Coedges.init(b, l);
                    while (it.next() catch return) |c| {
                        // A degenerate edge is a point of the surface, not an edge of the
                        // graph the formula counts
                        if (!b.edge(b.coedge(c).edge).flags.degenerate) edge_seen[@backingInt(b.coedge(c).edge)] = true;
                        vertex_seen[@backingInt(b.coedgeStart(c))] = true;
                    }
                }
            }
            const v: i64 = @intCast(std.mem.count(bool, vertex_seen, &.{true}));
            const e: i64 = @intCast(std.mem.count(bool, edge_seen, &.{true}));
            const chi = v - e + faces_n - (loops_n - faces_n);
            // chi = 2(1 − G) for one shell
            const twice_one_minus_g = chi;
            if (@mod(twice_one_minus_g, 2) != 0 or twice_one_minus_g > 2) try self.add(.euler_poincare, .of(.shell, @backingInt(s)), @floatFromInt(chi), 2);
        }
    }

    fn liveVertex(self: *const Checker, i: VertexIndex) bool {
        return i != .none and @backingInt(i) < self.body.vertices.items.len and !self.body.vertex(i).tombstone;
    }
    fn liveEdge(self: *const Checker, i: EdgeIndex) bool {
        return i != .none and @backingInt(i) < self.body.edges.items.len and !self.body.edge(i).flags.tombstone;
    }
    fn liveCoedge(self: *const Checker, i: CoedgeIndex, none_ok: bool) bool {
        if (i == .none) return none_ok;
        return @backingInt(i) < self.body.coedges.items.len and !self.body.coedge(i).tombstone;
    }
    fn liveLoop(self: *const Checker, i: LoopIndex) bool {
        return i != .none and @backingInt(i) < self.body.loops.items.len and !self.body.loop(i).tombstone;
    }
    fn liveFace(self: *const Checker, i: FaceIndex) bool {
        return i != .none and @backingInt(i) < self.body.faces.items.len and !self.body.face(i).flags.tombstone;
    }
    fn liveShell(self: *const Checker, i: ShellIndex) bool {
        return i != .none and @backingInt(i) < self.body.shells.items.len and !self.body.shell(i).tombstone;
    }
    fn liveCurve(self: *const Checker, r: geometry.CurveRef) bool {
        const g = &self.body.geometry;
        const n: usize = switch (r.kind) {
            .line => g.lines.items.len,
            .circle => g.circles.items.len,
            .ellipse => g.ellipses.items.len,
            .nurbs => g.nurbs_curves.items.len,
        };
        return r.index < n;
    }
    fn liveSurface(self: *const Checker, r: geometry.SurfaceRef) bool {
        const g = &self.body.geometry;
        const n: usize = switch (r.kind) {
            .plane => g.planes.items.len,
            .cylinder => g.cylinders.items.len,
            .cone => g.cones.items.len,
            .sphere => g.spheres.items.len,
            .torus => g.tori.items.len,
            .extrusion => g.extrusions.items.len,
            .revolution => g.revolutions.items.len,
            .nurbs => g.nurbs_surfaces.items.len,
        };
        return r.index < n;
    }

    // --- orientation ---

    fn orientation(self: *Checker) Error!void {
        const b = self.body;
        // In a closed shell every edge has two coedges (the manifold condition); on a sheet
        // boundary edges have one
        var shells = traverse.Shells.init(b);
        while (shells.next() catch return) |s| {
            if (b.shell(s).kind == .sheet) continue;
            var faces = traverse.Faces.init(b, s);
            while (faces.next() catch return) |f| {
                var loops = traverse.Loops.init(b, f);
                while (loops.next() catch return) |l| {
                    var it = traverse.Coedges.init(b, l);
                    while (it.next() catch return) |c| {
                        if (b.coedge(c).partner == .none and !b.edge(b.coedge(c).edge).flags.degenerate) try self.add(.open_edge_in_closed_shell, .of(.edge, @backingInt(b.coedge(c).edge)), 0, 0);
                    }
                }
            }
        }
    }

    // --- geometric ---

    fn geometric(self: *Checker) Error!void {
        const b = self.body;
        const tol = b.tol;
        for (b.edges.items, 0..) |e, i| {
            if (e.flags.tombstone) continue;
            const curve = b.geometry.curve(e.curve);
            // Vertex points on the curve's ends within the gaps and xsect
            const p0 = curve.eval(e.t0);
            const p1 = curve.eval(e.t1);
            const d0 = vec.distance(p0, b.point(e.start));
            const d1 = vec.distance(p1, b.point(e.end));
            const allowed0 = tol.xsect + e.gap + b.vertex(e.start).gap;
            const allowed1 = tol.xsect + e.gap + b.vertex(e.end).gap;
            if (d0 > allowed0) try self.add(.vertex_off_curve, .of(.edge, i), d0, allowed0);
            if (d1 > allowed1) try self.add(.vertex_off_curve, .of(.edge, i), d1, allowed1);
            // A degenerate edge is a point; any other is longer than the minimum feature
            if (e.flags.degenerate) {
                const d = vec.distance(p0, p1);
                if (d > tol.xsect) try self.add(.degenerate_edge_not_point, .of(.edge, i), d, tol.xsect);
            } else {
                const len = chordLength(curve, e.t0, e.t1);
                if (len <= 2.0 * tol.zone) try self.add(.edge_too_short, .of(.edge, i), len, 2.0 * tol.zone);
            }
            // The gaps are ordered: vertex ≥ edge
            if (b.vertex(e.start).gap + tol.zone * 0 < e.gap and b.vertex(e.start).gap < e.gap) try self.add(.gap_order, .of(.edge, i), e.gap, b.vertex(e.start).gap);
            if (e.gap > tol.zone) try self.add(.gap_too_large, .of(.edge, i), e.gap, tol.zone);
            // The curve lies on both faces' surfaces, at samples
            const pair = traverse.coedgesOfEdge(b, EdgeIndex.of(i));
            for (pair) |c| {
                if (c == .none) continue;
                const f = b.loop(b.coedge(c).loop).face;
                const surface = b.geometry.surface(b.face(f).surface);
                var k: usize = 0;
                while (k < EDGE_SAMPLES) : (k += 1) {
                    const t = e.t0 + (e.t1 - e.t0) * (@as(f64, @floatFromInt(k)) + 0.5) / EDGE_SAMPLES;
                    const p = curve.eval(t);
                    const uv = surface.project(p, tol.approx, 50);
                    const d = vec.distance(surface.eval(uv[0], uv[1]), p);
                    if (d > tol.xsect + e.gap) {
                        try self.add(.edge_off_surface, .of(.edge, i), d, tol.xsect + e.gap);
                        break;
                    }
                    // The stored pcurve lifts onto the edge
                    const pc = b.coedge(c).pcurve;
                    if (!pc.isNone()) {
                        const lifted = surface.eval(b.geometry.pcurve(pc).eval(t)[0], b.geometry.pcurve(pc).eval(t)[1]);
                        const dl = vec.distance(lifted, p);
                        if (dl > tol.approx + e.gap) {
                            try self.add(.pcurve_off_edge, .of(.coedge, @backingInt(c)), dl, tol.approx + e.gap);
                            break;
                        }
                    }
                }
            }
        }
        for (b.vertices.items, 0..) |v, i| {
            if (v.tombstone) continue;
            if (v.gap > tol.zone) try self.add(.gap_too_large, .of(.vertex, i), v.gap, tol.zone);
        }
        // UV boxes inside the surface's domain, without wrap
        for (b.faces.items, 0..) |f, i| {
            if (f.flags.tombstone) continue;
            const surface = b.geometry.surface(f.surface);
            const du = surface.domainU();
            const dv = surface.domainV();
            const box = f.uv_box;
            if (box.isEmpty()) continue;
            if (box.min[0] < du.t0 - tol.param or box.max[0] > du.t1 + tol.param or box.min[1] < dv.t0 - tol.param or box.max[1] > dv.t1 + tol.param) {
                try self.add(.uv_box_outside_domain, .of(.face, i), box.max[0] - box.min[0], du.t1 - du.t0);
            }
            if ((du.periodic and box.max[0] - box.min[0] > du.span() + tol.param) or (dv.periodic and box.max[1] - box.min[1] > dv.span() + tol.param)) {
                try self.add(.uv_box_wraps, .of(.face, i), 0, 0);
            }
        }
    }
};

/// The length of the polyline through `EDGE_SAMPLES + 1` points of the curve over the
/// range: a lower bound on the edge's length, enough to tell a short edge.
fn chordLength(curve: anytype, t0: f64, t1: f64) f64 {
    var len: f64 = 0;
    var prev = curve.eval(t0);
    var k: usize = 1;
    while (k <= EDGE_SAMPLES) : (k += 1) {
        const p = curve.eval(t0 + (t1 - t0) * @as(f64, @floatFromInt(k)) / EDGE_SAMPLES);
        len += vec.distance(prev, p);
        prev = p;
    }
    return len;
}
