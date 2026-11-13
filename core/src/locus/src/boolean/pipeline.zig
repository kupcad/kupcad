//! The boolean of two solids with planar faces (docs/architecture.md §7.4, D10, D16, D17):
//! the general imprint–classify–assemble pipeline, its phases separate modules with
//! tables between them, each testable alone, in this order (the layering test holds it):
//!
//! 1. `pave.zig`: every place the operands touch, in order of dimension, as merged
//!    vertices, each edge's paves, each face's section segments, the coplanar face pairs;
//! 2. `imprint.zig`: each face split by its paves and section segments in the overlay,
//!    into fragments;
//! 3. `classify.zig`: each fragment inside, outside, or on a face of the other operand
//!    facing the same or the other way;
//! 4. `select.zig`: Mäntylä's table, the fragments kept, `b`'s turned inward in a
//!    difference;
//! 5. here, the assembly: the kept fragments sewn into shells (`construct/sew.zig`), one
//!    vertex per merged vertex, the coplanar ones on one plane record; an edge more than two
//!    fragments use (two solids touching along it) is one edge per solid, its uses paired
//!    by the wedges of material about it; a shell enclosing negative volume a void;
//! 6. `simplify.zig`: faces on one plane merged across edges, edges joined across vertices
//!    on a line;
//! 7. the checker: the result passes it or the operation fails with its finding.
//!
//! Typed findings name the entity: failures `TooSmallEdge` (an operand's edge, `pave`),
//! `imprint_unmatched` and `unclassified` (an operand's face), `pinched` (a result's shell
//! touching itself along a line or at a point inside one solid, refused by design), the
//! checker's on the result; warnings `nearly_coplanar` (a face of `a` parallel to one of `b` a hair from its
//! plane, the result's faces that thin) and `solids_touch` (a result's edge where two of
//! its solids touch along a line).
//!
//! An empty operand answers without geometry (the union is the other, a difference
//! without `b` is `a`, the rest are empty). Operands with a curved face are M5's: refused,
//! naming the face. The result's tolerance is the larger of the operands' (§6) unless the
//! options give one.

const std = @import("std");
const vec = @import("../math/vec.zig");
const predicates = @import("../math/predicates.zig");
const trig = @import("../math/trig.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const check = @import("../topology/check.zig");
const condition = @import("../topology/condition.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const trace = @import("../io/trace.zig");
const primitives = @import("../construct/primitives.zig");
const sew = @import("../construct/sew.zig");
const in_face = @import("../query/in_face.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const pave = @import("pave.zig");
const imprint = @import("imprint.zig");
const classify = @import("classify.zig");
const select = @import("select.zig");
const simplify = @import("simplify.zig");
const Body = body_mod.Body;
const Frame = geometry.Frame;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

pub const Op = select.Op;
pub const Stage = pave.Stage;

/// The milestone of booleans on curved operands.
const CURVED_MILESTONE = 5;

pub const Options = struct {
    common: diagnostics.Options = .{},
    /// The host's number for this operation, in the tag rows the result's faces get (D14,
    /// `topology/tags.zig`: a face split from an operand's, two coincident faces merged).
    tag_op: u32 = 0,
    /// The fast paths in front of the general one (the containment table); false runs the
    /// general path alone, which they must agree with (D17), for tests and for tracing it.
    fast_paths: bool = true,
};

/// How a result face came from an input face, the weaker first: through a chain's steps
/// the stronger stands.
pub const Role = enum {
    /// The whole face, alone: not split, nothing merged into it.
    preserved,
    /// A part of it, or it with other parts of its own operand.
    split,
    /// Made one with a face of the other operand: lying on it (the operands coincident
    /// there) or beside it in one plane.
    merged,
};

/// An input face and a result face made from it.
pub const FaceMap = struct {
    /// The operand's place: 0 for the first, 1 for the second (in a chain, its index).
    operand: u32,
    /// The face's index in its operand and in the result.
    input: u32,
    result: u32,
    role: Role,
    /// Facing the other way: the second operand's inside of a difference.
    reversed: bool,
};

/// What a boolean did, for the host (research/opengeometry.md §4; the typed warnings made
/// concrete): the operation, its quality (exact, or approximate with the largest gap: how
/// far a vertex of the result was moved to meet the other operand), whether the operands
/// had coincident faces, their contacts when they touch without overlapping, each input
/// face's result faces, and for a refusal the stage it came from (an interference class
/// or a later phase). Filled even when the operation fails; sent to the trace as the
/// phase "report".
pub const Report = struct {
    allocator: std.mem.Allocator,
    op: Op = .@"union",
    max_gap: f64 = 0,
    coincident: bool = false,
    /// The points where the operands touch, when no part of either lies inside the other.
    contacts: std.ArrayList(Vec3) = .empty,
    /// Sorted by operand, input face, result face.
    faces: std.ArrayList(FaceMap) = .empty,
    failed_in: ?Stage = null,
    /// In a chain, the operand whose step failed.
    failed_step: ?u32 = null,
    /// Answered by the containment table: the operands met nowhere.
    by_containment: bool = false,

    pub fn init(allocator: std.mem.Allocator) Report {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Report) void {
        self.contacts.deinit(self.allocator);
        self.faces.deinit(self.allocator);
        self.* = undefined;
    }

    pub const Quality = union(enum) { exact, approximate: f64 };

    pub fn quality(self: *const Report) Quality {
        return if (self.max_gap == 0) .exact else .{ .approximate = self.max_gap };
    }

    /// The result faces made from face `input` of `operand`, in order.
    pub fn resultsOf(self: *const Report, operand: u32, input: u32, out: *std.ArrayList(u32)) error{OutOfMemory}!void {
        out.clearRetainingCapacity();
        for (self.faces.items) |m| if (m.operand == operand and m.input == input) try out.append(self.allocator, m.result);
    }

    /// The report as the trace takes it (plain data for std.json).
    fn view(self: *const Report) View {
        return .{ .op = self.op, .quality = if (self.max_gap == 0) "exact" else "approximate", .max_gap = self.max_gap, .coincident = self.coincident, .contacts = self.contacts.items, .faces = self.faces.items, .failed_in = self.failed_in, .failed_step = self.failed_step, .by_containment = self.by_containment };
    }

    const View = struct { op: Op, quality: []const u8, max_gap: f64, coincident: bool, contacts: []const Vec3, faces: []const FaceMap, failed_in: ?Stage, failed_step: ?u32, by_containment: bool };
};

/// `a op b`, a new solid; the operands untouched. What it did goes into `report` when
/// given (and to the trace either way), a refusal's stage among it.
pub fn boolean(allocator: std.mem.Allocator, a: *const Body, b: *const Body, op: Op, options: Options, diag: *Diagnostics, report: ?*Report) Error!Body {
    var own = Report.init(allocator);
    defer own.deinit();
    const r = report orelse &own;
    r.op = op;
    r.failed_in = null;
    var stage: Stage = .operands;
    errdefer {
        r.failed_in = stage;
        trace.data(allocator, &options.common, "boolean", "report", r.view()) catch {};
    }
    const common = options.common;
    try common.checkCancel();
    try trace.arguments(allocator, &common, "boolean", .{ .op = op });
    for ([2]*const Body{ a, b }) |operand| {
        if (operand.kind != .solid) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "an operand: a solid" });
        try planarOnly(operand, diag);
    }
    const tol = common.tolerance orelse Tolerance.merge(a.tol, b.tol);
    try diagnostics.input.tolerance(diag, tol);
    if (a.isEmpty() or b.isEmpty()) {
        const result = try emptyOperand(allocator, a, b, op, tol, diag, r);
        try trace.data(allocator, &common, "boolean", "report", r.view());
        return result;
    }

    var paves = try pave.run(allocator, a, b, tol, common, diag, &stage);
    defer paves.deinit();
    try common.checkCancel();
    // Operands that met nowhere: the containment table, each shell whole and classified
    // once (the general path's answer, without the overlay and a ray per face)
    const table = options.fast_paths and paves.apart();
    r.by_containment = table;
    stage = .imprint;
    var fragments = if (table) try imprint.wholeFaces(allocator, &paves, diag) else try imprint.run(allocator, &paves, common, diag);
    defer fragments.deinit();
    stage = .classify;
    const classes = if (table) try classify.byShell(allocator, &paves, &fragments, common, diag) else try classify.run(allocator, &paves, &fragments, common, diag);
    defer allocator.free(classes);
    const keeps = try select.run(allocator, op, &fragments, classes);
    defer allocator.free(keeps);
    try contacts(&paves, classes, r);
    try common.checkCancel();

    stage = .assemble;
    var made = try assemble(allocator, &paves, &fragments, classes, keeps, tol, options.tag_op, diag);
    defer made.deinit(allocator);
    var result = made.body;
    errdefer result.deinit();
    try trace.phase(allocator, &common, &result, "boolean", "assembled");
    // The Euler operators simplification runs take a structurally valid body: the assembly
    // is checked to that level first, a pinch refused there (the solids fuzzer, 2026-11-13:
    // a pinched difference reached `kef`, whose check in Debug stopped the process)
    try refuseInvalid(allocator, &result, .structural, diag);
    stage = .simplify;
    var log: simplify.Log = .{};
    defer log.deinit(allocator);
    try simplify.run(&result, diag, &log);
    try trace.phase(allocator, &common, &result, "boolean", "simplified");
    stage = .check;
    try refuseInvalid(allocator, &result, .geometric, diag);
    try faceMap(allocator, &result, &made, &log, options.tag_op, r, diag);
    for (result.vertices.items) |v| if (!v.tombstone) {
        r.max_gap = @max(r.max_gap, v.gap);
    };
    try warnTouching(allocator, &result, diag);
    try trace.data(allocator, &common, "boolean", "report", r.view());
    return result;
}

/// `operands[0] op operands[1] op …`, folded from the left as KupCAD's chains and the mesh
/// engine's batch are (the union of all, the first less the rest, the intersection of
/// all), each step a boolean of the running result and the next operand (§7.4: batches
/// run as a sequence until General Fuse, D17). The report composes the steps': each
/// operand's faces followed to the final result's (`FaceMap.operand` the operand's index),
/// the largest gap, any coincidence, every step's contacts; a refusal's stage and step.
/// One operand gives its copy.
pub fn chain(allocator: std.mem.Allocator, operands: []const *const Body, op: Op, options: Options, diag: *Diagnostics, report: ?*Report) Error!Body {
    if (operands.len == 0) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "a chain's operands" });
    var own = Report.init(allocator);
    defer own.deinit();
    const r = report orelse &own;
    r.op = op;
    // The first operand's faces, each its own so far
    var map: std.ArrayList(FaceMap) = .empty;
    defer map.deinit(allocator);
    for (operands[0].faces.items, 0..) |f, i| {
        if (!f.flags.tombstone) try map.append(allocator, .{ .operand = 0, .input = @intCast(i), .result = @intCast(i), .role = .preserved, .reversed = false });
    }
    var held: ?Body = null;
    errdefer if (held) |*h| h.deinit();
    for (operands[1..], 1..) |next, k| {
        var step = Report.init(allocator);
        defer step.deinit();
        const current = if (held) |*h| h else operands[0];
        var made = boolean(allocator, current, next, op, options, diag, &step) catch |e| {
            r.failed_in = step.failed_in;
            r.failed_step = @intCast(k);
            trace.data(allocator, &options.common, "chain", "report", r.view()) catch {};
            return e;
        };
        errdefer made.deinit();
        try compose(allocator, &map, &step, @intCast(k));
        r.max_gap = @max(r.max_gap, step.max_gap);
        r.coincident = r.coincident or step.coincident;
        try r.contacts.appendSlice(allocator, step.contacts.items);
        if (held) |*h| h.deinit();
        held = made;
    }
    try r.faces.appendSlice(allocator, map.items);
    try trace.data(allocator, &options.common, "chain", "report", r.view());
    if (held) |h| return h;
    return operands[0].clone(allocator) catch |e| return tooMany(diag, e);
}

/// The running face map through one more step of a chain: each entry's face of the running
/// result followed to the step's result faces, the roles composed (merged over split over
/// preserved), and the step's second operand (the chain's operand `k`) added.
fn compose(allocator: std.mem.Allocator, map: *std.ArrayList(FaceMap), step: *const Report, k: u32) Error!void {
    var next: std.ArrayList(FaceMap) = .empty;
    defer next.deinit(allocator);
    for (map.items) |e| {
        for (step.faces.items) |s| {
            if (s.operand != 0 or s.input != e.result) continue;
            try next.append(allocator, .{ .operand = e.operand, .input = e.input, .result = s.result, .role = stronger(e.role, s.role), .reversed = e.reversed or s.reversed });
        }
    }
    for (step.faces.items) |s| {
        if (s.operand == 1) try next.append(allocator, .{ .operand = k, .input = s.input, .result = s.result, .role = s.role, .reversed = s.reversed });
    }
    const Order = struct {
        fn lessThan(_: void, x: FaceMap, y: FaceMap) bool {
            if (x.operand != y.operand) return x.operand < y.operand;
            if (x.input != y.input) return x.input < y.input;
            return x.result < y.result;
        }
    };
    std.mem.sort(FaceMap, next.items, {}, Order.lessThan);
    // A face reaching one result face by two ways was in two pieces: split at least
    map.clearRetainingCapacity();
    for (next.items) |e| {
        if (map.items.len > 0) {
            const last = &map.items[map.items.len - 1];
            if (last.operand == e.operand and last.input == e.input and last.result == e.result) {
                last.role = stronger(stronger(last.role, e.role), .split);
                last.reversed = last.reversed or e.reversed;
                continue;
            }
        }
        try map.append(allocator, e);
    }
}

fn stronger(x: Role, y: Role) Role {
    return @enumFromInt(@max(@intFromEnum(x), @intFromEnum(y)));
}

/// Whether the operands had coincident faces, and where they touch when no part of
/// either lies inside the other: the merged vertices on faces of both.
fn contacts(paves: *const pave.Paves, classes: []const classify.Classified, r: *Report) Error!void {
    var overlap = false;
    for (classes) |c| {
        overlap = overlap or c.class == .inside;
        r.coincident = r.coincident or c.class == .on_same or c.class == .on_opposite;
    }
    if (overlap) return;
    // Each merged vertex's operands, from the faces it lies on
    const on = try r.allocator.alloc(u2, paves.points.items.len);
    defer r.allocator.free(on);
    @memset(on, 0);
    for (paves.incidences.items) |inc| on[inc.vertex] |= @as(u2, 1) << inc.face.operand;
    for (on, 0..) |operands, v| if (operands == 3) try r.contacts.append(r.allocator, paves.point(@intCast(v)));
}

/// The checker's first failure on `body` up to `level` as the operation's, a pinch as
/// `pinched` (refused by design), any other as `NotValid` with the finding.
fn refuseInvalid(allocator: std.mem.Allocator, body: *const Body, level: check.Level, diag: *Diagnostics) Error!void {
    var checked = try check.run(allocator, body, level);
    defer checked.deinit(allocator);
    const f = checked.first() orelse return;
    if (f.code == .euler_poincare) if (try pinchedShell(allocator, body, f)) |s| {
        return diag.fail(error.Degenerate, .{ .code = .pinched, .entity = .of(.shell, s), .label = "the result" });
    };
    return diag.fail(error.NotValid, f);
}

/// The shell an Euler–Poincaré finding names when it is pinched: one shell touching itself
/// along a line or at a point, so a vertex of it is singular (its faces about it two fans
/// or more, `topology/condition.zig`), which no count of one shell admits. Null for any
/// other failure of the count.
fn pinchedShell(allocator: std.mem.Allocator, body: *const Body, finding: diagnostics.Finding) Error!?u32 {
    var grades: std.ArrayList(condition.ShellGrade) = .empty;
    defer grades.deinit(allocator);
    condition.ofBody(allocator, body, &grades) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt => return null,
    };
    for (grades.items) |g| {
        if (@backingInt(g.shell) == finding.entity.index and g.grade.singular_vertices > 0) return finding.entity.index;
    }
    return null;
}

/// A warning (`solids_touch`) for each place the result's solids touch along a line: two
/// edges between one pair of vertices, one for each solid, the first of them named.
fn warnTouching(allocator: std.mem.Allocator, body: *const Body, diag: *Diagnostics) Error!void {
    var seen: std.AutoHashMapUnmanaged([2]u32, struct { edge: u32, warned: bool }) = .empty;
    defer seen.deinit(allocator);
    for (body.edges.items, 0..) |e, i| {
        if (e.flags.tombstone or e.flags.degenerate) continue;
        const key: [2]u32 = .{ @min(@backingInt(e.start), @backingInt(e.end)), @max(@backingInt(e.start), @backingInt(e.end)) };
        const entry = try seen.getOrPut(allocator, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .edge = @intCast(i), .warned = false };
            continue;
        }
        if (entry.value_ptr.warned) continue;
        entry.value_ptr.warned = true;
        try diag.warn(.{ .code = .solids_touch, .entity = .of(.edge, entry.value_ptr.edge) });
    }
}

/// `NotImplemented` naming the first face of `body` that is not planar or has an edge that
/// is not a line.
fn planarOnly(body: *const Body, diag: *Diagnostics) Error!void {
    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(body, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            var straight = body.face(f).surface.kind == .plane;
            var loops = traverse.Loops.init(body, f);
            while (straight) {
                const l = (loops.next() catch return corrupt(diag)) orelse break;
                var it = traverse.Coedges.init(body, l);
                while (it.next() catch return corrupt(diag)) |c| straight = straight and body.edge(body.coedge(c).edge).curve.kind == .line;
            }
            if (!straight) return diag.fail(error.NotImplemented, .{ .code = .not_implemented, .entity = .of(.face, @backingInt(f)), .label = "a boolean of an operand with a curved face or edge", .threshold = CURVED_MILESTONE });
        }
    }
}

/// An empty operand's answer: the other operand's copy, each of its faces preserved, or the
/// empty solid.
fn emptyOperand(allocator: std.mem.Allocator, a: *const Body, b: *const Body, op: Op, tol: Tolerance, diag: *Diagnostics, r: *Report) Error!Body {
    const keep: ?*const Body = switch (op) {
        .@"union" => if (a.isEmpty()) b else a,
        .difference => a,
        .intersection => null,
    };
    if (keep) |body| if (!body.isEmpty()) {
        const operand: u1 = if (body == a) 0 else 1;
        for (body.faces.items, 0..) |f, i| {
            if (f.flags.tombstone) continue;
            try r.faces.append(allocator, .{ .operand = operand, .input = @intCast(i), .result = @intCast(i), .role = .preserved, .reversed = false });
        }
        return body.clone(allocator) catch |e| return tooMany(diag, e);
    };
    var empty = Body.empty(allocator, tol);
    empty.kind = .solid;
    return empty;
}

/// One use of an edge by a kept fragment, for pairing the uses of an edge more than two
/// fragments share.
const Use = struct {
    spec: u32,
    face: u32,
};

/// The assembled body and where its faces came from, for the face map.
const Made = struct {
    body: Body,
    /// Each face of the body as built (before simplification): its fragment and its tag.
    face_fragment: []u32,
    face_tag: []types.Tag,
    operands: [2]*const Body,
    /// How many fragments each operand's face split into, by face index.
    pieces: [2][]u32,
    /// Where the second operand's tags start in the body's tag table.
    tag_offset: u32,
    fragments: *const imprint.Fragments,
    classes: []const classify.Classified,
    keeps: []const select.Keep,

    fn deinit(self: *Made, allocator: std.mem.Allocator) void {
        allocator.free(self.face_fragment);
        allocator.free(self.face_tag);
        allocator.free(self.pieces[0]);
        allocator.free(self.pieces[1]);
    }

    /// Operand `operand`'s tag `tag` in the body's table.
    fn tagIn(self: *const Made, operand: u1, tag: types.Tag) types.Tag {
        if (tag == .untagged or operand == 0) return tag;
        return types.Tag.of(@backingInt(tag) + self.tag_offset);
    }
};

/// The kept fragments as a body: see the file's comment, step 5. The body's tag table
/// holds both operands' rows (the second's after the first's), and each face the tag of
/// its operand's face, a `split` row of it when that face became several fragments.
fn assemble(allocator: std.mem.Allocator, paves: *const pave.Paves, fragments: *const imprint.Fragments, classes: []const classify.Classified, keeps: []const select.Keep, tol: Tolerance, tag_op: u32, diag: *Diagnostics) Error!Made {
    var b = try primitives.Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    var made: Made = .{ .body = undefined, .face_fragment = &.{}, .face_tag = &.{}, .operands = paves.operands, .pieces = .{ &.{}, &.{} }, .tag_offset = 0, .fragments = fragments, .classes = classes, .keeps = keeps };
    errdefer made.deinit(allocator);
    for (0..2) |k| {
        made.pieces[k] = try allocator.alloc(u32, paves.operands[k].faces.items.len);
        @memset(made.pieces[k], 0);
    }
    for (fragments.items.items) |f| made.pieces[f.operand][f.face] += 1;
    try adoptTags(allocator, &b.body, paves.operands, &made);
    var face_fragment: std.ArrayList(u32) = .empty;
    defer face_fragment.deinit(allocator);
    var face_tag: std.ArrayList(types.Tag) = .empty;
    defer face_tag.deinit(allocator);
    const vertex_of = try allocator.alloc(types.VertexIndex, paves.points.items.len);
    defer allocator.free(vertex_of);
    @memset(vertex_of, .none);

    var edge_specs: std.ArrayList(sew.EdgeSpec) = .empty;
    defer edge_specs.deinit(allocator);
    var uses: std.ArrayList(Use) = .empty;
    defer uses.deinit(allocator);
    // Per face: its loops as ranges of `edge_specs`, and per loop its range
    var loop_ranges: std.ArrayList([2]u32) = .empty;
    defer loop_ranges.deinit(allocator);
    var faces: std.ArrayList(sew.FaceSpec) = .empty;
    defer faces.deinit(allocator);
    var face_loops: std.ArrayList([2]u32) = .empty;
    defer face_loops.deinit(allocator);
    var normals: std.ArrayList(Vec3) = .empty;
    defer normals.deinit(allocator);

    for (fragments.items.items, keeps, 0..) |fragment, keep, i| {
        if (keep == .drop) continue;
        const flip = keep == .flip;
        const body = paves.operands[fragment.operand];
        const f = types.FaceIndex.of(fragment.face);
        const frame = planar_faces.frameOf(body, f).?;
        var normal = in_face.outwardNormal(body, f, .{ 0, 0 });
        if (flip) normal = vec.neg(normal);
        const facing = try b.facingPlane(Frame.init(frame.origin, frame.x, normal));
        const face_index: u32 = @intCast(faces.items.len);
        const first_loop: u32 = @intCast(loop_ranges.items.len);
        for (fragments.loopsOf(i)) |loop| {
            const vertices = fragments.loopVertices(loop);
            const start: u32 = @intCast(edge_specs.items.len);
            for (0..vertices.len) |j| {
                // A flipped fragment's loops run the other way
                const from = if (flip) vertices[vertices.len - 1 - j] else vertices[j];
                const to = if (flip) vertices[(2 * vertices.len - 2 - j) % vertices.len] else vertices[(j + 1) % vertices.len];
                const u = try builderVertex(&b, paves, vertex_of, from);
                const w = try builderVertex(&b, paves, vertex_of, to);
                if (u == w) return diag.fail(error.Degenerate, .{ .code = .edge_too_short, .entity = .of(.face, fragment.face), .label = "a piece of a face" });
                try edge_specs.append(allocator, try b.straight(u, w));
                try uses.append(allocator, .{ .spec = @intCast(edge_specs.items.len - 1), .face = face_index });
            }
            try loop_ranges.append(allocator, .{ start, @intCast(edge_specs.items.len - start) });
        }
        try face_loops.append(allocator, .{ first_loop, @intCast(loop_ranges.items.len - first_loop) });
        try normals.append(allocator, normal);
        const own = made.tagIn(fragment.operand, body.face(f).tag);
        const tag = if (made.pieces[fragment.operand][fragment.face] > 1) b.body.tags.split(allocator, tag_op, own) catch |e| return tooMany(diag, e) else own;
        try faces.append(allocator, .{ .surface = facing.surface, .same_sense = facing.same_sense, .loops = &.{}, .attribute = body.face(f).attribute, .tag = tag });
        try face_fragment.append(allocator, @intCast(i));
        try face_tag.append(allocator, tag);
    }
    try pairTouching(allocator, &b.body, edge_specs.items, uses.items, normals.items, diag);

    // The loops, now that the edges no longer move; each face's box in its plane record's frame
    const loop_specs = try allocator.alloc(sew.LoopSpec, loop_ranges.items.len);
    defer allocator.free(loop_specs);
    for (loop_ranges.items, loop_specs) |range, *spec| spec.* = .{ .edges = edge_specs.items[range[0]..][0..range[1]] };
    for (faces.items, face_loops.items) |*spec, range| {
        spec.loops = loop_specs[range[0]..][0..range[1]];
        const plane_frame = b.body.geometry.planes.items[spec.surface.index].frame;
        var uv = geometry.Box2.empty;
        for (spec.loops) |l| for (l.edges) |e| {
            const p = plane_frame.toLocal(b.body.point(e.start));
            uv.grow(.{ p[0], p[1] });
        };
        spec.uv_box = uv;
    }
    made.face_fragment = try face_fragment.toOwnedSlice(allocator);
    made.face_tag = try face_tag.toOwnedSlice(allocator);
    if (faces.items.len > 0) {
        _ = sew.sew(&b.body, faces.items, .outer) catch |e| return b.fail(e);
        // A shell enclosing negative volume bounds a void
        var shells = traverse.Shells.init(&b.body);
        while (shells.next() catch return corrupt(diag)) |s| {
            if (try shellVolume(&b.body, s, diag) < 0) b.body.shell(s).kind = .void;
        }
        try pinchedAtPoint(paves, fragments, made.face_fragment, vertex_of, &b.body, diag);
    }
    made.body = b.body;
    return made;
}

/// Refuses (`pinched`) a result that keeps a point contact inside one solid: a vertex of
/// one operand strictly inside a face of the other (`Paves.touches`), on no edge of the
/// face's pieces, whose face piece and whose faces about the vertex are in one shell (a
/// pocket meeting the face it was cut from at a corner). Two solids touching so are two
/// shells, and pass.
fn pinchedAtPoint(paves: *const pave.Paves, fragments: *const imprint.Fragments, face_fragment: []const u32, vertex_of: []const types.VertexIndex, body: *const Body, diag: *Diagnostics) Error!void {
    for (paves.touches.items) |touch| {
        const v = vertex_of[touch.vertex];
        if (v == .none) continue;
        const frame = planar_faces.frameOf(paves.operands[touch.operand], types.FaceIndex.of(touch.face)).?;
        const at = planar_faces.flat(frame, paves.point(touch.vertex));
        // The built face of the touched face's piece around the point
        const holder: ?u32 = for (face_fragment, 0..) |i, j| {
            const fragment = fragments.items.items[i];
            if (fragment.operand != touch.operand or fragment.face != touch.face) continue;
            if (aroundPoint(paves, fragments, i, frame, at, touch.vertex)) break @intCast(j);
        } else null;
        const j = holder orelse continue;
        const shell = body.faces.items[j].shell;
        for (body.coedges.items, 0..) |c, ci| {
            if (c.tombstone or body.coedgeStart(types.CoedgeIndex.of(ci)) != v) continue;
            if (body.face(body.loop(c.loop).face).shell == shell) return diag.fail(error.Degenerate, .{ .code = .pinched, .entity = .of(.shell, @backingInt(shell)), .label = "the result (a corner of one operand on a face of the other, inside one solid)" });
        }
    }
}

/// Whether fragment `i` holds the point `at` (merged vertex `m`) strictly inside, by the
/// exact crossing count of its loops in its face's plane; a fragment with `m` on a loop
/// holds it on its boundary, an edge's end, which no pinch is.
fn aroundPoint(paves: *const pave.Paves, fragments: *const imprint.Fragments, i: usize, frame: Frame, at: [2]f64, m: u32) bool {
    var inside = false;
    for (fragments.loopsOf(i)) |loop| {
        const ring = fragments.loopVertices(loop);
        for (ring, 0..) |u, k| {
            if (u == m) return false;
            const a = planar_faces.flat(frame, paves.point(u));
            const b = planar_faces.flat(frame, paves.point(ring[(k + 1) % ring.len]));
            if ((a[1] > at[1]) == (b[1] > at[1])) continue;
            if ((predicates.orient2d(a, b, at) > 0) == (b[1] > a[1])) inside = !inside;
        }
    }
    return inside;
}

/// Both operands' tag rows into `body`'s table, the second's parents moved past the
/// first's rows.
fn adoptTags(allocator: std.mem.Allocator, body: *Body, operands: [2]*const Body, made: *Made) Error!void {
    const table = &body.tags;
    table.rows.appendSlice(allocator, operands[0].tags.rows.items) catch return error.OutOfMemory;
    made.tag_offset = @intCast(operands[0].tags.rows.items.len);
    for (operands[1].tags.rows.items) |row| {
        var moved = row;
        switch (moved.source) {
            .named => {},
            .split => |*parent| parent.* = made.tagIn(1, parent.*),
            .merged, .pair => |*parents| for (parents) |*t| {
                t.* = made.tagIn(1, t.*);
            },
        }
        table.rows.append(allocator, moved) catch return error.OutOfMemory;
    }
}

/// The report's face map, and each result face's tag the union of its sources': each face
/// as built followed through the merges of simplification to its face in the result; its
/// sources its fragment's face and, for a fragment kept for two coincident faces (`on_same`),
/// the other operand's face it lies on.
fn faceMap(allocator: std.mem.Allocator, result: *Body, made: *const Made, log: *const simplify.Log, tag_op: u32, r: *Report, diag: *Diagnostics) Error!void {
    const n = made.face_fragment.len;
    if (n == 0) return;
    // Each built face's survivor: the face it was merged into, followed
    const into = try allocator.alloc(u32, n);
    defer allocator.free(into);
    for (into, 0..) |*t, i| t.* = @intCast(i);
    for (log.merged.items) |m| into[m[0]] = m[1];
    const survivor = struct {
        fn of(merged_into: []const u32, i: u32) u32 {
            var at = i;
            var steps: usize = 0;
            while (merged_into[at] != at and steps < merged_into.len) : (steps += 1) at = merged_into[at];
            return at;
        }
    }.of;
    // The sources of every result face, and its tag
    const Source = struct { operand: u1, input: u32, reversed: bool, result: u32 };
    var sources: std.ArrayList(Source) = .empty;
    defer sources.deinit(allocator);
    // Each result face's tag, folded over its sources' by `merged` (an untagged one adds
    // nothing, one tag alone stays itself)
    const tags = try allocator.alloc(types.Tag, result.faces.items.len);
    defer allocator.free(tags);
    @memset(tags, .untagged);
    for (0..n) |j| {
        const res = log.faces[survivor(into, @intCast(j))];
        if (res == body_mod.Body.Remap.NONE) continue;
        const i = made.face_fragment[j];
        const fragment = made.fragments.items.items[i];
        try sources.append(allocator, .{ .operand = fragment.operand, .input = fragment.face, .reversed = made.keeps[i] == .flip, .result = res });
        tags[res] = result.tags.merged(result.allocator, tag_op, tags[res], made.face_tag[j]) catch |e| return tooMany(diag, e);
        const c = made.classes[i];
        if (c.class == .on_same and c.partner != classify.NONE) {
            const other: u1 = 1 - fragment.operand;
            try sources.append(allocator, .{ .operand = other, .input = c.partner, .reversed = false, .result = res });
            const partner_tag = made.tagIn(other, made.operands[other].face(types.FaceIndex.of(c.partner)).tag);
            tags[res] = result.tags.merged(result.allocator, tag_op, tags[res], partner_tag) catch |e| return tooMany(diag, e);
        }
    }
    for (tags, 0..) |tag, f| {
        if (!result.faces.items[f].flags.tombstone) result.faces.items[f].tag = tag;
    }
    // Each source once per result face, in order
    const Order = struct {
        fn lessThan(_: void, x: Source, y: Source) bool {
            if (x.operand != y.operand) return x.operand < y.operand;
            if (x.input != y.input) return x.input < y.input;
            return x.result < y.result;
        }
    };
    std.mem.sort(Source, sources.items, {}, Order.lessThan);
    for (sources.items, 0..) |src, k| {
        if (k > 0) {
            const prev = sources.items[k - 1];
            if (prev.operand == src.operand and prev.input == src.input and prev.result == src.result) continue;
        }
        // Merged when the result face has a source of each operand; preserved when its
        // only source is this face, whole
        var both = false;
        var alone = true;
        for (sources.items) |other| if (other.result == src.result) {
            both = both or other.operand != src.operand;
            alone = alone and other.operand == src.operand and other.input == src.input;
        };
        const whole = made.pieces[src.operand][src.input] == 1;
        const role: Role = if (both) .merged else if (alone and whole) .preserved else .split;
        try r.faces.append(r.allocator, .{ .operand = src.operand, .input = src.input, .result = src.result, .role = role, .reversed = src.reversed });
    }
}

/// The builder's vertex for merged vertex `m`, made on its first use with the merged
/// vertex's gap.
fn builderVertex(b: *primitives.Builder, paves: *const pave.Paves, vertex_of: []types.VertexIndex, m: u32) Error!types.VertexIndex {
    if (vertex_of[m] == .none) {
        vertex_of[m] = try b.vertex(paves.point(m));
        b.body.vertex(vertex_of[m]).gap = paves.gaps.items[m];
    }
    return vertex_of[m];
}

/// Each edge more than two fragments use, where two solids of the result touch along it,
/// made one edge per solid (`EdgeSpec.copy`): its uses sorted by the angle of their faces
/// about it, and each pair of neighbours with material between them one edge (the face
/// side away from a face's outward normal is its material).
fn pairTouching(allocator: std.mem.Allocator, body: *const Body, specs: []sew.EdgeSpec, uses: []const Use, normals: []const Vec3, diag: *Diagnostics) Error!void {
    const Key = struct { lo: u32, hi: u32 };
    var groups: std.AutoArrayHashMapUnmanaged(Key, std.ArrayList(u32)) = .empty;
    defer {
        for (groups.values()) |*list| list.deinit(allocator);
        groups.deinit(allocator);
    }
    for (uses, 0..) |use, i| {
        const spec = specs[use.spec];
        const key: Key = .{ .lo = @min(@backingInt(spec.start), @backingInt(spec.end)), .hi = @max(@backingInt(spec.start), @backingInt(spec.end)) };
        const entry = try groups.getOrPut(allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, @intCast(i));
    }
    for (groups.keys(), groups.values()) |key, *list| {
        if (list.items.len <= 2) continue;
        if (list.items.len % 2 != 0) return diag.fail(error.NotValid, .{ .code = .edge_coedge_count, .label = "an edge of a boolean's result", .measured = @floatFromInt(list.items.len) });
        const origin = body.point(types.VertexIndex.of(key.lo));
        const axis = vec.normalized(vec.sub(body.point(types.VertexIndex.of(key.hi)), origin)) orelse return diag.fail(error.Degenerate, .{ .code = .edge_too_short, .label = "an edge of a boolean's result" });
        const r0 = vec.perpendicular(axis);
        const r1 = vec.cross(axis, r0);
        // Each use's face, as the direction into it from the edge, by its angle about the axis
        const Sorted = struct {
            angles: []const f64,
            fn lessThan(ctx: @This(), x: u32, y: u32) bool {
                return ctx.angles[x] < ctx.angles[y];
            }
        };
        const angle_of = try allocator.alloc(f64, uses.len);
        defer allocator.free(angle_of);
        for (list.items) |u| {
            const spec = specs[uses[u].spec];
            const along = if (@backingInt(spec.start) == key.lo) axis else vec.neg(axis);
            const into = vec.cross(normals[uses[u].face], along);
            angle_of[u] = trig.atan2(vec.dot(into, r1), vec.dot(into, r0));
        }
        std.mem.sort(u32, list.items, Sorted{ .angles = angle_of }, Sorted.lessThan);
        // Pair each use with its neighbour on its material side, turning about the axis
        const n = list.items.len;
        var copy: u32 = 0;
        var paired = try allocator.alloc(bool, n);
        defer allocator.free(paired);
        @memset(paired, false);
        for (0..n) |k| {
            const u = list.items[k];
            const spec = specs[uses[u].spec];
            const along = if (@backingInt(spec.start) == key.lo) axis else vec.neg(axis);
            const into = vec.cross(normals[uses[u].face], along);
            // Turning on about the axis from this face leaves it on its material side
            if (vec.dot(vec.cross(axis, into), normals[uses[u].face]) >= 0) continue;
            const next = (k + 1) % n;
            if (paired[k] or paired[next]) return diag.fail(error.NotValid, .{ .code = .edge_coedge_count, .label = "an edge of a boolean's result (its faces do not pair)", .measured = @floatFromInt(n) });
            paired[k] = true;
            paired[next] = true;
            specs[uses[u].spec].copy = copy;
            specs[uses[list.items[next]].spec].copy = copy;
            copy += 1;
        }
        for (paired) |p| if (!p) return diag.fail(error.NotValid, .{ .code = .edge_coedge_count, .label = "an edge of a boolean's result (its faces do not pair)", .measured = @floatFromInt(n) });
    }
}

/// The volume shell `s` encloses, by the fan of each face about its first vertex:
/// negative for a void's. Planar faces with straight edges.
fn shellVolume(body: *const Body, s: types.ShellIndex, diag: *Diagnostics) Error!f64 {
    var volume: f64 = 0;
    var faces = traverse.Faces.init(body, s);
    while (faces.next() catch return corrupt(diag)) |f| {
        const apex = body.point(body.coedgeStart(body.loop(body.face(f).first_loop).first));
        var loops = traverse.Loops.init(body, f);
        while (loops.next() catch return corrupt(diag)) |l| {
            var it = traverse.Coedges.init(body, l);
            while (it.next() catch return corrupt(diag)) |c| volume += vec.dot(apex, vec.cross(body.point(body.coedgeStart(c)), body.point(body.coedgeEnd(c)))) / 6.0;
        }
    }
    return volume;
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "a boolean's operand or result" });
}

/// A body's tables' errors as the operation's.
pub fn tooMany(diag: *Diagnostics, err: error{ OutOfMemory, TooMany }) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooMany => diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "entities" }),
    };
}
