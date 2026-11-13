//! The checker (docs/architecture.md §9.1): `run(body, level)` is a pure function giving
//! the findings, in the order of the rules, stopping at the first structural failure so no
//! geometric rule reads a corrupt graph. Level 0: structural; 1: and orientation and
//! geometric; 2: and the global rules (holes inside their outer loops, the pcurve rules
//! at nine samples, redundant topology and singular vertices as warnings). From level 1
//! the report grades every shell in the vocabulary the mesh validator uses too
//! (`condition.zig`: irregular < regular < oriented < closed, and singular vertices).
//! Every test ends with it; every operation's result passes it or the operation fails
//! with the finding.

const std = @import("std");
const builtin = @import("builtin");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("types.zig");
const body_mod = @import("body.zig");
const traverse = @import("traverse.zig");
const condition = @import("condition.zig");
const Body = body_mod.Body;
const Finding = diagnostics.Finding;
const EntityRef = diagnostics.EntityRef;
const VertexIndex = types.VertexIndex;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const EdgeIndex = types.EdgeIndex;
const CoedgeIndex = types.CoedgeIndex;
const LoopIndex = types.LoopIndex;
const FaceIndex = types.FaceIndex;
const ShellIndex = types.ShellIndex;

pub const Error = error{OutOfMemory};

/// The rules, as diagnostics codes.
pub const Rule = diagnostics.Code;

pub const Level = enum(u8) { structural = 0, geometric = 1, global = 2 };

pub const ShellGrade = condition.ShellGrade;

/// The findings of a run; empty for a valid body. From level 1, every shell's grade.
pub const Report = struct {
    findings: std.ArrayList(Finding) = .empty,
    shells: std.ArrayList(ShellGrade) = .empty,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        self.findings.deinit(allocator);
        self.shells.deinit(allocator);
        self.* = undefined;
    }

    /// No failures; warnings (level 2's "could be merged") are in `findings` still.
    pub fn ok(self: *const Report) bool {
        return self.first() == null;
    }

    /// The first failure.
    pub fn first(self: *const Report) ?Finding {
        for (self.findings.items) |f| if (f.severity == .failure) return f;
        return null;
    }

    pub fn warnings(self: *const Report) usize {
        var n: usize = 0;
        for (self.findings.items) |f| n += @intFromBool(f.severity == .warning);
        return n;
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
    if (!report.ok() or level == .geometric) return report;
    try checker.global();
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

    fn warn(self: *Checker, rule: Rule, entity: EntityRef) Error!void {
        try self.report.findings.append(self.allocator, .{ .code = rule, .severity = .warning, .entity = entity });
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
        // Every shell graded: what the edge rules below and the structural ones say in one
        // word, and the singular vertices no edge rule sees
        condition.ofBody(self.allocator, b, &self.report.shells) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Corrupt => return,
        };
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
        // The scale guard (architecture §12): the zone must stay above the spacing of the
        // coordinates, measured by the largest one of the vertices (the surfaces pass
        // through them)
        var magnitude: f64 = 0;
        for (b.vertices.items) |v| {
            if (v.tombstone) continue;
            for (b.geometry.point(v.point)) |x| magnitude = @max(magnitude, @abs(x));
        }
        if (!(tol.zone >= magnitude * diagnostics.SCALE_GUARD)) try self.add(.too_large_for_tolerance, .{ .kind = .body }, magnitude, tol.zone / diagnostics.SCALE_GUARD);
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
        try self.windings();
        try self.verticesApart();
    }

    /// Every loop runs counter-clockwise in UV about its face's outward normal when it is
    /// the outer one, clockwise when a hole (what `same_sense` and the surface's own
    /// orientation make of "the face to the left"); and the loops of a closed shell are
    /// wound outward: the signed volume they enclose is positive for an outer shell,
    /// negative for a void.
    fn windings(self: *Checker) Error!void {
        const b = self.body;
        var uv = std.ArrayList(Vec2).empty;
        defer uv.deinit(self.allocator);
        var xyz = std.ArrayList(Vec3).empty;
        defer xyz.deinit(self.allocator);
        var shells = traverse.Shells.init(b);
        while (shells.next() catch return) |s| {
            var volume: f64 = 0;
            // The point the fans' volumes are taken from: the shell's first, so far from the
            // origin they are the shell's size, not its distance (§9.2)
            var from: ?Vec3 = null;
            var faces = traverse.Faces.init(b, s);
            while (faces.next() catch return) |f| {
                const face = b.face(f);
                // The fans' apex: a point of the surface inside the face's UV box, so a
                // curved face's bulge counts (a hemisphere's loop polygon is flat)
                const surface = b.geometry.surface(face.surface);
                const apex: ?Vec3 = if (face.uv_box.isEmpty()) null else surface.eval((face.uv_box.min[0] + face.uv_box.max[0]) / 2.0, (face.uv_box.min[1] + face.uv_box.max[1]) / 2.0);
                var loops = traverse.Loops.init(b, f);
                var outer = true;
                while (loops.next() catch return) |l| : (outer = false) {
                    if (b.loop(l).first == .none) continue;
                    const sampled = try self.sampleLoop(l, &uv, &xyz);
                    if (from == null) from = xyz.items[0];
                    volume += fanVolume(from.?, apex orelse xyz.items[0], xyz.items);
                    if (!sampled) continue;
                    const area = shoelace(uv.items);
                    const want_ccw = outer == face.same_sense;
                    // A loop of no area (a spur, a lamina mid-construction) runs neither way
                    if (@abs(area) > b.tol.param * b.tol.param and (area > 0) != want_ccw) try self.add(.loop_winding, .of(.loop, @backingInt(l)), area, 0);
                }
            }
            // A shell of no volume (a lamina mid-construction) is neither way round
            switch (b.shell(s).kind) {
                .outer => if (volume < 0) try self.add(.shell_inside_out, .of(.shell, @backingInt(s)), volume, 0),
                .void => if (volume > 0) try self.add(.shell_inside_out, .of(.shell, @backingInt(s)), volume, 0),
                .sheet => {},
            }
        }
    }

    /// The loop as a polygon of `LOOP_SAMPLES` points per coedge, in space and in the
    /// face's UV (by the pcurve, else by projection). False when a coedge on a periodic
    /// surface has no pcurve: its UV would jump at the seam, so the UV polygon is not
    /// trusted (the points in space are).
    fn sampleLoop(self: *Checker, l: LoopIndex, uv: *std.ArrayList(Vec2), xyz: *std.ArrayList(Vec3)) Error!bool {
        const b = self.body;
        const tol = b.tol;
        const face = b.face(b.loop(l).face);
        const surface = b.geometry.surface(face.surface);
        const periodic = surface.domainU().periodic or surface.domainV().periodic;
        uv.clearRetainingCapacity();
        xyz.clearRetainingCapacity();
        var trusted = true;
        var it = traverse.Coedges.init(b, l);
        while (it.next() catch return false) |c| {
            const coedge = b.coedge(c);
            const e = b.edge(coedge.edge);
            const curve = b.geometry.curve(e.curve);
            const from: f64 = if (coedge.same_sense) e.t0 else e.t1;
            const to: f64 = if (coedge.same_sense) e.t1 else e.t0;
            var k: usize = 0;
            while (k < LOOP_SAMPLES) : (k += 1) {
                const t = from + (to - from) * @as(f64, @floatFromInt(k)) / LOOP_SAMPLES;
                const p = curve.eval(t);
                try xyz.append(self.allocator, p);
                if (!coedge.pcurve.isNone()) {
                    try uv.append(self.allocator, b.geometry.pcurve(coedge.pcurve).eval(t));
                } else if (periodic) {
                    trusted = false;
                } else {
                    try uv.append(self.allocator, surface.project(p, tol.approx, 50));
                }
            }
        }
        return trusted;
    }

    /// OpenGeometry's two pcurve rules (research/opengeometry.md §6): every coedge's
    /// pcurve, at `PCURVE_SAMPLES` parameters from the edge's start to its end, lifts onto
    /// the edge's curve within `approx` (plus the edge's gap) and lies in its face's UV box
    /// within the zone over the surface's metric there; and consecutive coedges of a loop
    /// join in UV within that slack, a period apart counting as joined. A coedge without
    /// a pcurve (on a plane) takes no part.
    fn pcurveRules(self: *Checker) Error!void {
        const b = self.body;
        const tol = b.tol;
        for (b.faces.items, 0..) |face, fi| {
            if (face.flags.tombstone) continue;
            const surface = b.geometry.surface(face.surface);
            const periods: [2]?f64 = .{ if (surface.domainU().periodic) surface.domainU().span() else null, if (surface.domainV().periodic) surface.domainV().span() else null };
            var loops = traverse.Loops.init(b, FaceIndex.of(fi));
            while (loops.next() catch return) |l| {
                var previous_end: ?Vec2 = null;
                var first: ?struct { coedge: CoedgeIndex, uv: Vec2 } = null;
                var it = traverse.Coedges.init(b, l);
                while (it.next() catch return) |c| {
                    const coedge = b.coedge(c);
                    if (coedge.pcurve.isNone()) {
                        previous_end = null;
                        continue;
                    }
                    const e = b.edge(coedge.edge);
                    const curve = b.geometry.curve(e.curve);
                    const pc = b.geometry.pcurve(coedge.pcurve);
                    const from = if (coedge.same_sense) e.t0 else e.t1;
                    const to = if (coedge.same_sense) e.t1 else e.t0;
                    var start_uv: Vec2 = undefined;
                    var end_uv: Vec2 = undefined;
                    var k: usize = 0;
                    while (k < PCURVE_SAMPLES) : (k += 1) {
                        const t = from + (to - from) * @as(f64, @floatFromInt(k)) / (PCURVE_SAMPLES - 1);
                        const uv = pc.eval(t);
                        if (k == 0) start_uv = uv;
                        if (k == PCURVE_SAMPLES - 1) end_uv = uv;
                        const p = curve.eval(t);
                        const dl = vec.distance(surface.eval(uv[0], uv[1]), p);
                        if (dl > tol.approx + e.gap) {
                            try self.add(.pcurve_off_edge, .of(.coedge, @backingInt(c)), dl, tol.approx + e.gap);
                            break;
                        }
                        const out = outsideBox(face.uv_box, uv, uvSlack(surface, uv, tol.zone));
                        if (out > 1) {
                            try self.add(.pcurve_outside_box, .of(.coedge, @backingInt(c)), out * tol.zone, tol.zone);
                            break;
                        }
                    }
                    if (previous_end) |prev| {
                        const gap = uvGap(prev, start_uv, uvSlack(surface, start_uv, tol.zone), periods);
                        if (gap > 1) try self.add(.pcurves_disjoint, .of(.coedge, @backingInt(c)), gap * tol.zone, tol.zone);
                    }
                    if (first == null) first = .{ .coedge = c, .uv = start_uv };
                    previous_end = end_uv;
                }
                // Round the loop: the last pcurve's end to the first's start
                if (previous_end) |prev| if (first) |f| {
                    const gap = uvGap(prev, f.uv, uvSlack(surface, f.uv, tol.zone), periods);
                    if (gap > 1) try self.add(.pcurves_disjoint, .of(.coedge, @backingInt(f.coedge)), gap * tol.zone, tol.zone);
                };
            }
        }
    }

    /// No two vertices within the zone of each other: sorted along x, each against the
    /// ones that follow within the zone.
    fn verticesApart(self: *Checker) Error!void {
        const b = self.body;
        var order = std.ArrayList(u32).empty;
        defer order.deinit(self.allocator);
        for (b.vertices.items, 0..) |v, i| if (!v.tombstone) try order.append(self.allocator, @intCast(i));
        const Ctx = struct {
            body: *const Body,
            fn lessThan(ctx: @This(), i: u32, j: u32) bool {
                return ctx.body.point(VertexIndex.of(i))[0] < ctx.body.point(VertexIndex.of(j))[0];
            }
        };
        std.mem.sort(u32, order.items, Ctx{ .body = b }, Ctx.lessThan);
        for (order.items, 0..) |i, k| {
            const p = b.point(VertexIndex.of(i));
            for (order.items[k + 1 ..]) |j| {
                const q = b.point(VertexIndex.of(j));
                if (q[0] - p[0] > b.tol.zone) break;
                const d = vec.distance(p, q);
                if (d <= b.tol.zone) try self.add(.vertices_too_close, .of(.vertex, j), d, b.tol.zone);
            }
        }
    }

    // --- global (level 2) ---

    /// What needs the whole face or shell: a hole loop lies inside its face's outer loop
    /// and in no other hole (by a point of it against the sampled UV polygons, even-odd);
    /// the pcurve rules (`pcurveRules`); and, as warnings, topology that a simplification
    /// could remove: an edge whose two faces are one face, or lie on one surface the same
    /// way (never across a seam, which D7 keeps). The rules that need an intersector
    /// (faces of a shell meeting only along shared edges, voids inside the outer shell)
    /// wait for it.
    fn global(self: *Checker) Error!void {
        const b = self.body;
        try self.pcurveRules();
        // A solid touching itself at a point: valid topology, worth a word (a sheet's
        // regions touching at a corner are its own business)
        for (self.report.shells.items) |sg| {
            if (b.shell(sg.shell).kind == .sheet) continue;
            if (sg.grade.first_singular) |v| try self.warn(.singular_vertex, .of(.vertex, v));
        }
        var uv = std.ArrayList(Vec2).empty;
        defer uv.deinit(self.allocator);
        var xyz = std.ArrayList(Vec3).empty;
        defer xyz.deinit(self.allocator);
        var outer_uv = std.ArrayList(Vec2).empty;
        defer outer_uv.deinit(self.allocator);
        var hole_points = std.ArrayList(Vec2).empty;
        defer hole_points.deinit(self.allocator);
        var hole_polygons = std.ArrayList([]Vec2).empty;
        defer {
            for (hole_polygons.items) |poly| self.allocator.free(poly);
            hole_polygons.deinit(self.allocator);
        }
        for (b.faces.items, 0..) |face, fi| {
            if (face.flags.tombstone) continue;
            if (face.first_loop == .none or b.loop(face.first_loop).next_in_face == .none) continue;
            if (!try self.sampleLoop(face.first_loop, &uv, &xyz)) continue;
            outer_uv.clearRetainingCapacity();
            try outer_uv.appendSlice(self.allocator, uv.items);
            hole_points.clearRetainingCapacity();
            for (hole_polygons.items) |poly| self.allocator.free(poly);
            hole_polygons.clearRetainingCapacity();
            var loops = traverse.Loops.init(b, types.FaceIndex.of(fi));
            _ = loops.next() catch return;
            while (loops.next() catch return) |l| {
                if (!try self.sampleLoop(l, &uv, &xyz)) continue;
                if (uv.items.len == 0) continue;
                if (!insidePolygon(outer_uv.items, uv.items[0])) try self.add(.hole_outside_outer, .of(.loop, @backingInt(l)), 0, 0);
                for (hole_polygons.items, hole_points.items) |poly, point| {
                    if (insidePolygon(poly, uv.items[0]) or insidePolygon(uv.items, point)) try self.add(.hole_outside_outer, .of(.loop, @backingInt(l)), 0, 0);
                }
                try hole_points.append(self.allocator, uv.items[0]);
                try hole_polygons.ensureUnusedCapacity(self.allocator, 1);
                hole_polygons.appendAssumeCapacity(try self.allocator.dupe(Vec2, uv.items));
            }
        }
        for (b.edges.items, 0..) |e, i| {
            if (e.flags.tombstone or e.flags.seam or e.flags.degenerate or e.coedge == .none) continue;
            const partner = b.coedge(e.coedge).partner;
            if (partner == .none) continue;
            const fa = b.face(b.loop(b.coedge(e.coedge).loop).face);
            const fb = b.face(b.loop(b.coedge(partner).loop).face);
            const one_face = b.loop(b.coedge(e.coedge).loop).face == b.loop(b.coedge(partner).loop).face;
            if (one_face or (fa.surface == fb.surface and fa.same_sense == fb.same_sense)) try self.warn(.redundant_topology, .of(.edge, i));
        }
    }
};

/// Points per coedge of a loop's sampled polygon.
const LOOP_SAMPLES: usize = 4;
/// Samples per pcurve of the level-2 pcurve rules, the ends among them (OpenGeometry's
/// nine, research/opengeometry.md §6): a fixed count keeps the check linear.
const PCURVE_SAMPLES: usize = 9;

/// The parameter a move of `distance` is worth in each direction of `surface` at `uv`:
/// the distance over the surface's metric there (the derivative's length); unbounded
/// where the metric vanishes (at a pole any `u` is the same point).
fn uvSlack(surface: anytype, uv: Vec2, distance: f64) Vec2 {
    const s = surface.sample(uv[0], uv[1]);
    const du = vec.length(s.du);
    const dv = vec.length(s.dv);
    return .{ if (du > 0) distance / du else std.math.inf(f64), if (dv > 0) distance / dv else std.math.inf(f64) };
}

/// How far `uv` lies outside `box`, as a share of `slack` in the worse direction (at
/// most 1 inside).
fn outsideBox(box: geometry.Box2, uv: Vec2, slack: Vec2) f64 {
    var worst: f64 = 0;
    for (0..2) |k| {
        const out = @max(box.min[k] - uv[k], uv[k] - box.max[k]);
        if (out > 0) worst = @max(worst, out / slack[k]);
    }
    return worst;
}

/// The gap between two UV points as a share of `slack` in the worse direction, a period
/// apart counting as together in a periodic direction.
fn uvGap(a: Vec2, b: Vec2, slack: Vec2, periods: [2]?f64) f64 {
    var worst: f64 = 0;
    for (0..2) |k| {
        var d = @abs(a[k] - b[k]);
        if (periods[k]) |period| {
            d = @mod(d, period);
            d = @min(d, period - d);
        }
        worst = @max(worst, d / slack[k]);
    }
    return worst;
}

/// Twice the signed area of a polygon in UV: positive counter-clockwise.
fn shoelace(points: []const Vec2) f64 {
    var area: f64 = 0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        area += p[0] * q[1] - q[0] * p[1];
    }
    return area;
}

/// The signed volume between `from` and the fan of a polygon about `apex`: summed over a
/// closed surface's loops it is the volume they enclose, whatever `from` is, positive when
/// wound outward (the fans of one face share their apex, so a hole's fan takes its share
/// away). From the world's origin, a shell 3.7e5 out summed terms of 5e16 to a volume of
/// 0.1, and the sign was the rounding's (the solids fuzzer's moved chains, CI run
/// 43509321095): `from` is a point of the shell.
fn fanVolume(from: Vec3, apex: Vec3, points: []const Vec3) f64 {
    const a = vec.sub(apex, from);
    var volume: f64 = 0;
    for (points, 0..) |p, i| volume += vec.dot(a, vec.cross(vec.sub(p, from), vec.sub(points[(i + 1) % points.len], from))) / 6.0;
    return volume;
}

/// Whether `p` is inside the polygon by the even-odd rule.
fn insidePolygon(polygon: []const Vec2, p: Vec2) bool {
    var inside = false;
    for (polygon, 0..) |a, i| {
        const b = polygon[(i + 1) % polygon.len];
        if ((a[1] > p[1]) != (b[1] > p[1])) {
            const x = a[0] + (p[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
            if (p[0] < x) inside = !inside;
        }
    }
    return inside;
}

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
