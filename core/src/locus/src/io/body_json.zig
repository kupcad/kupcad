//! The body as JSON (docs/architecture.md §7.9, §12): a straight dump of every table in
//! usd-brep's flat layout, each entity a row of plain numbers, indices into the other
//! tables, `null` for none, the first loop of a face its outer one. `dump` renumbers the
//! live entities in order and skips the tombstoned, so the same body gives the same bytes
//! whatever was deleted before: it is the canonical serialization that `hash` hashes, the
//! fixture and trace format, and the debugging snapshot. `load` reads it back; a file is
//! hostile input: every index is checked before the body is used.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const pcurves = @import("../geometry/pcurves.zig");
const arena = @import("../geometry/arena.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const topo = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const tags = @import("../topology/tags.zig");
const Body = body_mod.Body;
const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;

pub const Error = error{
    OutOfMemory,
    /// A table in the text is larger than a body may hold.
    TooMany,
    /// The text is not a body: wrong version, a malformed document, an index past its
    /// table, a reference kind without a table.
    Malformed,
};

/// The format's version: a change to the schema bumps it, and a fixture of another
/// version is refused rather than misread.
pub const VERSION: u32 = 1;

/// The schema, as plain data std.json can write and read.
pub const Schema = struct {
    version: u32,
    kind: []const u8,
    tolerance: struct { zone: f64, xsect: f64, approx: f64, angle: f64, param: f64 },
    first_shell: ?u32,
    vertices: []const Vertex,
    edges: []const Edge,
    coedges: []const Coedge,
    loops: []const Loop,
    faces: []const Face,
    shells: []const Shell,
    geometry: Geometry,
    tags: []const Tag,

    pub const Ref = struct { kind: []const u8, index: u32 };
    pub const Vertex = struct { point: u32, gap: f64, coedge: ?u32, tag: u32 };
    pub const Edge = struct { curve: Ref, t0: f64, t1: f64, start: u32, end: u32, gap: f64, coedge: ?u32, degenerate: bool, seam: bool, approx: bool, regularity: []const u8, tag: u32 };
    pub const Coedge = struct { edge: u32, same_sense: bool, partner: ?u32, next: ?u32, prev: ?u32, loop: u32, pcurve: ?Ref };
    pub const Loop = struct { face: u32, first: ?u32, vertex: ?u32, next_in_face: ?u32 };
    pub const Face = struct { surface: Ref, same_sense: bool, first_loop: ?u32, shell: u32, next_in_shell: ?u32, uv_box: ?[4]f64, approx: bool, tag: u32 };
    pub const Shell = struct { first_face: ?u32, next_in_body: ?u32, kind: []const u8 };
    pub const Frame = struct { origin: Vec3, x: Vec3, y: Vec3, z: Vec3 };
    pub const Geometry = struct {
        points: []const Vec3,
        lines: []const struct { o: Vec3, d: Vec3 },
        circles: []const struct { c: Vec3, x: Vec3, y: Vec3, r: f64 },
        ellipses: []const struct { c: Vec3, x: Vec3, y: Vec3, a: f64, b: f64 },
        nurbs_curves: []const struct { degree: u8, knots: []const f64, points: []const Vec4 },
        planes: []const struct { frame: Frame },
        cylinders: []const struct { frame: Frame, r: f64 },
        cones: []const struct { frame: Frame, r: f64, half_angle: f64 },
        spheres: []const struct { frame: Frame, r: f64 },
        tori: []const struct { frame: Frame, major: f64, minor: f64 },
        extrusions: []const struct { curve: Ref, d: Vec3 },
        revolutions: []const struct { curve: Ref, frame: Frame },
        nurbs_surfaces: []const struct { degree_u: u8, degree_v: u8, knots_u: []const f64, knots_v: []const f64, count_u: u32, count_v: u32, points: []const Vec4 },
        lines2: []const struct { o: [2]f64, d: [2]f64 },
        circles2: []const struct { c: [2]f64, r: f64 },
        nurbs_pcurves: []const struct { degree: u8, knots: []const f64, points: []const Vec3 },
    };
    pub const Tag = struct { op: u32, source: []const u8, a: u32, b: u32 };
};

// ---------------------------------------------------------------------------------------
// dump

/// The body as canonical JSON text, the caller's to free.
pub fn dump(allocator: std.mem.Allocator, body: *const Body) Error![]u8 {
    var a = std.heap.ArenaAllocator.init(allocator);
    defer a.deinit();
    const schema = try toSchema(a.allocator(), body);
    return std.json.Stringify.valueAlloc(allocator, schema, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
}

/// A 64-bit hash of the canonical serialization: the same for the same body wherever it
/// was built (§12).
pub fn hash(allocator: std.mem.Allocator, body: *const Body) Error!u64 {
    const text = try dump(allocator, body);
    defer allocator.free(text);
    return std.hash.Wyhash.hash(0, text);
}

/// Old index → new index of the live entities, in order.
const Renumber = struct {
    map: []u32,

    const NONE: u32 = std.math.maxInt(u32);

    fn of(allocator: std.mem.Allocator, comptime T: type, items: []const T) Error!Renumber {
        const map = try allocator.alloc(u32, items.len);
        var next: u32 = 0;
        for (items, map) |item, *m| {
            const dead = if (@hasField(T, "flags")) item.flags.tombstone else item.tombstone;
            if (dead) {
                m.* = NONE;
            } else {
                m.* = next;
                next += 1;
            }
        }
        return .{ .map = map };
    }

    fn get(self: Renumber, i: anytype) ?u32 {
        if (i == .none) return null;
        const m = self.map[@backingInt(i)];
        return if (m == NONE) null else m;
    }

    fn must(self: Renumber, i: anytype) u32 {
        return self.get(i) orelse NONE;
    }
};

fn refOf(r: anytype) Schema.Ref {
    return .{ .kind = @tagName(r.kind), .index = r.index };
}

fn frameOf(f: geometry.Frame) Schema.Frame {
    return .{ .origin = f.origin, .x = f.x, .y = f.y, .z = f.z };
}

fn toSchema(allocator: std.mem.Allocator, body: *const Body) Error!Schema {
    const rv = try Renumber.of(allocator, topo.Vertex, body.vertices.items);
    const re = try Renumber.of(allocator, topo.Edge, body.edges.items);
    const rc = try Renumber.of(allocator, topo.Coedge, body.coedges.items);
    const rl = try Renumber.of(allocator, topo.Loop, body.loops.items);
    const rf = try Renumber.of(allocator, topo.Face, body.faces.items);
    const rs = try Renumber.of(allocator, topo.Shell, body.shells.items);

    var vertices: std.ArrayList(Schema.Vertex) = .empty;
    for (body.vertices.items) |v| {
        if (v.tombstone) continue;
        try vertices.append(allocator, .{ .point = @backingInt(v.point), .gap = v.gap, .coedge = rc.get(v.coedge), .tag = @backingInt(v.tag) });
    }
    var edges: std.ArrayList(Schema.Edge) = .empty;
    for (body.edges.items) |e| {
        if (e.flags.tombstone) continue;
        try edges.append(allocator, .{ .curve = refOf(e.curve), .t0 = e.t0, .t1 = e.t1, .start = rv.must(e.start), .end = rv.must(e.end), .gap = e.gap, .coedge = rc.get(e.coedge), .degenerate = e.flags.degenerate, .seam = e.flags.seam, .approx = e.flags.approx, .regularity = @tagName(e.regularity), .tag = @backingInt(e.tag) });
    }
    var coedges: std.ArrayList(Schema.Coedge) = .empty;
    for (body.coedges.items) |c| {
        if (c.tombstone) continue;
        try coedges.append(allocator, .{ .edge = re.must(c.edge), .same_sense = c.same_sense, .partner = rc.get(c.partner), .next = rc.get(c.next), .prev = rc.get(c.prev), .loop = rl.must(c.loop), .pcurve = if (c.pcurve.isNone()) null else refOf(c.pcurve) });
    }
    var loops: std.ArrayList(Schema.Loop) = .empty;
    for (body.loops.items) |l| {
        if (l.tombstone) continue;
        try loops.append(allocator, .{ .face = rf.must(l.face), .first = rc.get(l.first), .vertex = rv.get(l.vertex), .next_in_face = rl.get(l.next_in_face) });
    }
    var faces: std.ArrayList(Schema.Face) = .empty;
    for (body.faces.items) |f| {
        if (f.flags.tombstone) continue;
        try faces.append(allocator, .{ .surface = refOf(f.surface), .same_sense = f.same_sense, .first_loop = rl.get(f.first_loop), .shell = rs.must(f.shell), .next_in_shell = rf.get(f.next_in_shell), .uv_box = if (f.uv_box.isEmpty()) null else .{ f.uv_box.min[0], f.uv_box.min[1], f.uv_box.max[0], f.uv_box.max[1] }, .approx = f.flags.approx, .tag = @backingInt(f.tag) });
    }
    var shells: std.ArrayList(Schema.Shell) = .empty;
    for (body.shells.items) |s| {
        if (s.tombstone) continue;
        try shells.append(allocator, .{ .first_face = rf.get(s.first_face), .next_in_body = rs.get(s.next_in_body), .kind = @tagName(s.kind) });
    }
    var tag_rows: std.ArrayList(Schema.Tag) = .empty;
    for (body.tags.rows.items) |row| {
        try tag_rows.append(allocator, switch (row.source) {
            .named => |n| .{ .op = row.op, .source = "named", .a = n, .b = 0 },
            .split => |p| .{ .op = row.op, .source = "split", .a = @backingInt(p), .b = 0 },
            .merged => |p| .{ .op = row.op, .source = "merged", .a = @backingInt(p[0]), .b = @backingInt(p[1]) },
            .pair => |p| .{ .op = row.op, .source = "pair", .a = @backingInt(p[0]), .b = @backingInt(p[1]) },
        });
    }
    const g = &body.geometry;
    const G = Schema.Geometry;
    var lines = try allocator.alloc(std.meta.Child(@FieldType(G, "lines")), g.lines.items.len);
    for (g.lines.items, 0..) |l, i| lines[i] = .{ .o = l.o, .d = l.d };
    var circles = try allocator.alloc(std.meta.Child(@FieldType(G, "circles")), g.circles.items.len);
    for (g.circles.items, 0..) |c, i| circles[i] = .{ .c = c.c, .x = c.x, .y = c.y, .r = c.r };
    var ellipses = try allocator.alloc(std.meta.Child(@FieldType(G, "ellipses")), g.ellipses.items.len);
    for (g.ellipses.items, 0..) |e, i| ellipses[i] = .{ .c = e.c, .x = e.x, .y = e.y, .a = e.a, .b = e.b };
    var nurbs_curves = try allocator.alloc(std.meta.Child(@FieldType(G, "nurbs_curves")), g.nurbs_curves.items.len);
    for (g.nurbs_curves.items, 0..) |n, i| nurbs_curves[i] = .{ .degree = n.degree, .knots = g.knot_pool.items[n.knots.start .. n.knots.start + n.knots.len], .points = g.point4_pool.items[n.points.start .. n.points.start + n.points.len] };
    var planes = try allocator.alloc(std.meta.Child(@FieldType(G, "planes")), g.planes.items.len);
    for (g.planes.items, 0..) |p, i| planes[i] = .{ .frame = frameOf(p.frame) };
    var cylinders = try allocator.alloc(std.meta.Child(@FieldType(G, "cylinders")), g.cylinders.items.len);
    for (g.cylinders.items, 0..) |c, i| cylinders[i] = .{ .frame = frameOf(c.frame), .r = c.r };
    var cones = try allocator.alloc(std.meta.Child(@FieldType(G, "cones")), g.cones.items.len);
    for (g.cones.items, 0..) |c, i| cones[i] = .{ .frame = frameOf(c.frame), .r = c.r, .half_angle = c.half_angle };
    var spheres = try allocator.alloc(std.meta.Child(@FieldType(G, "spheres")), g.spheres.items.len);
    for (g.spheres.items, 0..) |s, i| spheres[i] = .{ .frame = frameOf(s.frame), .r = s.r };
    var tori = try allocator.alloc(std.meta.Child(@FieldType(G, "tori")), g.tori.items.len);
    for (g.tori.items, 0..) |t, i| tori[i] = .{ .frame = frameOf(t.frame), .major = t.major, .minor = t.minor };
    var extrusions = try allocator.alloc(std.meta.Child(@FieldType(G, "extrusions")), g.extrusions.items.len);
    for (g.extrusions.items, 0..) |e, i| extrusions[i] = .{ .curve = refOf(e.curve), .d = e.d };
    var revolutions = try allocator.alloc(std.meta.Child(@FieldType(G, "revolutions")), g.revolutions.items.len);
    for (g.revolutions.items, 0..) |r, i| revolutions[i] = .{ .curve = refOf(r.curve), .frame = frameOf(r.frame) };
    var nurbs_surfaces = try allocator.alloc(std.meta.Child(@FieldType(G, "nurbs_surfaces")), g.nurbs_surfaces.items.len);
    for (g.nurbs_surfaces.items, 0..) |n, i| nurbs_surfaces[i] = .{ .degree_u = n.degree_u, .degree_v = n.degree_v, .knots_u = g.knot_pool.items[n.knots_u.start .. n.knots_u.start + n.knots_u.len], .knots_v = g.knot_pool.items[n.knots_v.start .. n.knots_v.start + n.knots_v.len], .count_u = n.count_u, .count_v = n.count_v, .points = g.point4_pool.items[n.points.start .. n.points.start + n.points.len] };
    var lines2 = try allocator.alloc(std.meta.Child(@FieldType(G, "lines2")), g.lines2.items.len);
    for (g.lines2.items, 0..) |l, i| lines2[i] = .{ .o = l.o, .d = l.d };
    var circles2 = try allocator.alloc(std.meta.Child(@FieldType(G, "circles2")), g.circles2.items.len);
    for (g.circles2.items, 0..) |c, i| circles2[i] = .{ .c = c.c, .r = c.r };
    var nurbs_pcurves = try allocator.alloc(std.meta.Child(@FieldType(G, "nurbs_pcurves")), g.nurbs_pcurves.items.len);
    for (g.nurbs_pcurves.items, 0..) |n, i| nurbs_pcurves[i] = .{ .degree = n.degree, .knots = g.knot_pool.items[n.knots.start .. n.knots.start + n.knots.len], .points = g.point3_pool.items[n.points.start .. n.points.start + n.points.len] };

    return .{
        .version = VERSION,
        .kind = @tagName(body.kind),
        .tolerance = .{ .zone = body.tol.zone, .xsect = body.tol.xsect, .approx = body.tol.approx, .angle = body.tol.angle, .param = body.tol.param },
        .first_shell = rs.get(body.first_shell),
        .vertices = vertices.items,
        .edges = edges.items,
        .coedges = coedges.items,
        .loops = loops.items,
        .faces = faces.items,
        .shells = shells.items,
        .geometry = .{
            .points = g.points.items,
            .lines = lines,
            .circles = circles,
            .ellipses = ellipses,
            .nurbs_curves = nurbs_curves,
            .planes = planes,
            .cylinders = cylinders,
            .cones = cones,
            .spheres = spheres,
            .tori = tori,
            .extrusions = extrusions,
            .revolutions = revolutions,
            .nurbs_surfaces = nurbs_surfaces,
            .lines2 = lines2,
            .circles2 = circles2,
            .nurbs_pcurves = nurbs_pcurves,
        },
        .tags = tag_rows.items,
    };
}

// ---------------------------------------------------------------------------------------
// load

/// The body the text describes, in `allocator`'s memory. Every index and reference is
/// checked against its table; the structural rules are the caller's to run.
pub fn load(allocator: std.mem.Allocator, text: []const u8) Error!Body {
    var parsed = std.json.parseFromSlice(Schema, allocator, text, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    defer parsed.deinit();
    const s = parsed.value;
    if (s.version != VERSION) return error.Malformed;
    var body = Body.init(allocator, .{ .zone = s.tolerance.zone, .xsect = s.tolerance.xsect, .approx = s.tolerance.approx, .angle = s.tolerance.angle, .param = s.tolerance.param });
    errdefer body.deinit();
    if (!body.tol.isValid()) return error.Malformed;
    body.kind = std.meta.stringToEnum(body_mod.Kind, s.kind) orelse return error.Malformed;

    // Geometry first: the entities refer to it
    const g = &body.geometry;
    for (s.geometry.points) |p| _ = try g.addPoint(allocator, p);
    for (s.geometry.lines) |l| _ = try g.addLine(allocator, .{ .o = l.o, .d = l.d });
    for (s.geometry.circles) |c| _ = try g.addCircle(allocator, .{ .c = c.c, .x = c.x, .y = c.y, .r = c.r });
    for (s.geometry.ellipses) |e| _ = try g.addEllipse(allocator, .{ .c = e.c, .x = e.x, .y = e.y, .a = e.a, .b = e.b });
    for (s.geometry.nurbs_curves) |n| {
        const view = @import("../geometry/nurbs.zig").Curve{ .degree = n.degree, .knots = n.knots, .points = n.points };
        if (!view.isValid()) return error.Malformed;
        _ = try g.addNurbsCurve(allocator, view);
    }
    for (s.geometry.planes) |p| _ = try g.addPlane(allocator, .{ .frame = try frameFrom(p.frame) });
    for (s.geometry.cylinders) |c| _ = try g.addCylinder(allocator, .{ .frame = try frameFrom(c.frame), .r = c.r });
    for (s.geometry.cones) |c| _ = try g.addCone(allocator, .{ .frame = try frameFrom(c.frame), .r = c.r, .half_angle = c.half_angle });
    for (s.geometry.spheres) |sp| _ = try g.addSphere(allocator, .{ .frame = try frameFrom(sp.frame), .r = sp.r });
    for (s.geometry.tori) |t| _ = try g.addTorus(allocator, .{ .frame = try frameFrom(t.frame), .major = t.major, .minor = t.minor });
    for (s.geometry.extrusions) |e| _ = try g.addExtrusion(allocator, try curveRef(g, e.curve), e.d);
    for (s.geometry.revolutions) |r| {
        const f = try frameFrom(r.frame);
        const ref = try g.addRevolution(allocator, try curveRef(g, r.curve), f.origin, f.z);
        g.revolutions.items[ref.index].frame = f;
    }
    for (s.geometry.nurbs_surfaces) |n| {
        const view = @import("../geometry/nurbs.zig").Surface{ .degree_u = n.degree_u, .degree_v = n.degree_v, .knots_u = n.knots_u, .knots_v = n.knots_v, .count_u = n.count_u, .count_v = n.count_v, .points = n.points };
        if (!view.isValid()) return error.Malformed;
        _ = try g.addNurbsSurface(allocator, view);
    }
    for (s.geometry.lines2) |l| _ = try g.addLine2(allocator, .{ .o = l.o, .d = l.d });
    for (s.geometry.circles2) |c| _ = try g.addCircle2(allocator, .{ .c = c.c, .r = c.r });
    for (s.geometry.nurbs_pcurves) |n| {
        const view = @import("../geometry/nurbs.zig").Curve2{ .degree = n.degree, .knots = n.knots, .points = n.points };
        if (!view.isValid()) return error.Malformed;
        _ = try g.addNurbs2(allocator, view);
    }

    // Tags
    for (s.tags) |t| {
        const source: tags.Row.Source = if (std.mem.eql(u8, t.source, "named"))
            .{ .named = t.a }
        else if (std.mem.eql(u8, t.source, "split"))
            .{ .split = @fromBackingInt(@intCast(t.a)) }
        else if (std.mem.eql(u8, t.source, "merged"))
            .{ .merged = .{ @fromBackingInt(@intCast(t.a)), @fromBackingInt(@intCast(t.b)) } }
        else if (std.mem.eql(u8, t.source, "pair"))
            .{ .pair = .{ @fromBackingInt(@intCast(t.a)), @fromBackingInt(@intCast(t.b)) } }
        else
            return error.Malformed;
        _ = try body.tags.add(allocator, .{ .op = t.op, .source = source });
    }
    const tag_count = body.tags.rows.items.len;

    // Entities, each index checked against its table's length
    const nv = s.vertices.len;
    const ne = s.edges.len;
    const nc = s.coedges.len;
    const nl = s.loops.len;
    const nf = s.faces.len;
    const ns = s.shells.len;
    for (s.vertices) |v| {
        if (v.point >= g.points.items.len or v.tag > tag_count) return error.Malformed;
        _ = try body.addVertex(.{ .point = @fromBackingInt(@intCast(v.point)), .gap = v.gap, .coedge = try opt(topo.CoedgeIndex, v.coedge, nc), .tag = @fromBackingInt(@intCast(v.tag)) });
    }
    for (s.edges) |e| {
        if (e.tag > tag_count) return error.Malformed;
        _ = try body.addEdge(.{
            .curve = try curveRef(g, e.curve),
            .t0 = e.t0,
            .t1 = e.t1,
            .start = try idx(topo.VertexIndex, e.start, nv),
            .end = try idx(topo.VertexIndex, e.end, nv),
            .gap = e.gap,
            .coedge = try opt(topo.CoedgeIndex, e.coedge, nc),
            .flags = .{ .degenerate = e.degenerate, .seam = e.seam, .approx = e.approx },
            .regularity = std.meta.stringToEnum(topo.Regularity, e.regularity) orelse return error.Malformed,
            .tag = @fromBackingInt(@intCast(e.tag)),
        });
    }
    for (s.coedges) |c| {
        _ = try body.addCoedge(.{
            .edge = try idx(topo.EdgeIndex, c.edge, ne),
            .same_sense = c.same_sense,
            .partner = try opt(topo.CoedgeIndex, c.partner, nc),
            .next = try opt(topo.CoedgeIndex, c.next, nc),
            .prev = try opt(topo.CoedgeIndex, c.prev, nc),
            .loop = try idx(topo.LoopIndex, c.loop, nl),
            .pcurve = if (c.pcurve) |r| try pcurveRef(g, r) else geometry.PCurveRef.none,
        });
    }
    for (s.loops) |l| {
        _ = try body.addLoop(.{ .face = try idx(topo.FaceIndex, l.face, nf), .first = try opt(topo.CoedgeIndex, l.first, nc), .vertex = try opt(topo.VertexIndex, l.vertex, nv), .next_in_face = try opt(topo.LoopIndex, l.next_in_face, nl) });
    }
    for (s.faces) |f| {
        if (f.tag > tag_count) return error.Malformed;
        _ = try body.addFace(.{
            .surface = try surfaceRef(g, f.surface),
            .same_sense = f.same_sense,
            .first_loop = try opt(topo.LoopIndex, f.first_loop, nl),
            .shell = try idx(topo.ShellIndex, f.shell, ns),
            .next_in_shell = try opt(topo.FaceIndex, f.next_in_shell, nf),
            .uv_box = if (f.uv_box) |b| .{ .min = .{ b[0], b[1] }, .max = .{ b[2], b[3] } } else geometry.Box2.empty,
            .flags = .{ .approx = f.approx },
            .tag = @fromBackingInt(@intCast(f.tag)),
        });
    }
    for (s.shells) |sh| {
        _ = try body.addShell(.{ .first_face = try opt(topo.FaceIndex, sh.first_face, nf), .next_in_body = try opt(topo.ShellIndex, sh.next_in_body, ns), .kind = std.meta.stringToEnum(topo.ShellKind, sh.kind) orelse return error.Malformed });
    }
    body.first_shell = try opt(topo.ShellIndex, s.first_shell, ns);
    return body;
}

fn idx(comptime Index: type, i: u32, len: usize) Error!Index {
    if (i >= len) return error.Malformed;
    return @fromBackingInt(@intCast(i));
}

fn opt(comptime Index: type, i: ?u32, len: usize) Error!Index {
    return if (i) |v| idx(Index, v, len) else .none;
}

fn frameFrom(f: Schema.Frame) Error!geometry.Frame {
    const frame = geometry.Frame{ .origin = f.origin, .x = f.x, .y = f.y, .z = f.z };
    inline for (.{ f.origin, f.x, f.y, f.z }) |v| if (!vec.isFinite(v)) return error.Malformed;
    return frame;
}

fn curveRef(g: *const arena.Geometry, r: Schema.Ref) Error!geometry.CurveRef {
    const kind = std.meta.stringToEnum(geometry.CurveKind, r.kind) orelse return error.Malformed;
    const len: usize = switch (kind) {
        .line => g.lines.items.len,
        .circle => g.circles.items.len,
        .ellipse => g.ellipses.items.len,
        .nurbs => g.nurbs_curves.items.len,
    };
    if (r.index >= len) return error.Malformed;
    return geometry.CurveRef.of(kind, r.index);
}

fn surfaceRef(g: *const arena.Geometry, r: Schema.Ref) Error!geometry.SurfaceRef {
    const kind = std.meta.stringToEnum(geometry.SurfaceKind, r.kind) orelse return error.Malformed;
    const len: usize = switch (kind) {
        .plane => g.planes.items.len,
        .cylinder => g.cylinders.items.len,
        .cone => g.cones.items.len,
        .sphere => g.spheres.items.len,
        .torus => g.tori.items.len,
        .extrusion => g.extrusions.items.len,
        .revolution => g.revolutions.items.len,
        .nurbs => g.nurbs_surfaces.items.len,
    };
    if (r.index >= len) return error.Malformed;
    return geometry.SurfaceRef.of(kind, r.index);
}

fn pcurveRef(g: *const arena.Geometry, r: Schema.Ref) Error!geometry.PCurveRef {
    const kind = std.meta.stringToEnum(geometry.PCurveKind, r.kind) orelse return error.Malformed;
    const len: usize = switch (kind) {
        .line2 => g.lines2.items.len,
        .circle2 => g.circles2.items.len,
        .nurbs2 => g.nurbs_pcurves.items.len,
    };
    if (r.index >= len) return error.Malformed;
    return geometry.PCurveRef.of(kind, r.index);
}
