//! `Body`: the entity tables of topology/types.zig, the geometry arena they refer to, the
//! tag table, and the body's tolerance (docs/architecture.md §5.2, D3). A body is a value:
//! an operation takes bodies by `const` reference and returns a new one; a body with no
//! shells is the empty body, valid, with zero measures. `Checkpoint` is a copy to go back
//! to while building; `compact` drops tombstoned entities and renumbers, giving the remap
//! tables (SolveSpace's `newH`), and tags stay what they were.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const Geometry = @import("../geometry/arena.zig").Geometry;
const Tolerance = @import("../tolerance.zig").Tolerance;
const types = @import("types.zig");
const tags = @import("tags.zig");
const Vec3 = vec.Vec3;
pub const VertexIndex = types.VertexIndex;
pub const EdgeIndex = types.EdgeIndex;
pub const CoedgeIndex = types.CoedgeIndex;
pub const LoopIndex = types.LoopIndex;
pub const FaceIndex = types.FaceIndex;
pub const ShellIndex = types.ShellIndex;

pub const Error = error{ OutOfMemory, TooMany };

/// Whether the body bounds a volume or is an open sheet (a sketch: planar faces on `z = 0`).
pub const Kind = enum(u8) { solid, sheet };

pub const Body = struct {
    allocator: std.mem.Allocator,
    tol: Tolerance,
    kind: Kind = .solid,
    first_shell: ShellIndex = .none,

    vertices: std.ArrayList(types.Vertex) = .empty,
    edges: std.ArrayList(types.Edge) = .empty,
    coedges: std.ArrayList(types.Coedge) = .empty,
    loops: std.ArrayList(types.Loop) = .empty,
    faces: std.ArrayList(types.Face) = .empty,
    shells: std.ArrayList(types.Shell) = .empty,

    geometry: Geometry = .empty,
    tags: tags.Table = .empty,

    /// The most entities of one table a body may hold (`Limits.entities_per_arena` bounds
    /// it lower).
    pub const MAX_ENTITIES: usize = std.math.maxInt(u32);

    pub fn init(allocator: std.mem.Allocator, tol: Tolerance) Body {
        return .{ .allocator = allocator, .tol = tol };
    }

    /// The empty body: no shells, zero measures.
    pub fn empty(allocator: std.mem.Allocator, tol: Tolerance) Body {
        return init(allocator, tol);
    }

    pub fn deinit(self: *Body) void {
        self.vertices.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.coedges.deinit(self.allocator);
        self.loops.deinit(self.allocator);
        self.faces.deinit(self.allocator);
        self.shells.deinit(self.allocator);
        self.geometry.deinit(self.allocator);
        self.tags.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn isEmpty(self: *const Body) bool {
        return self.first_shell == .none;
    }

    /// A deep copy, in `allocator`'s memory (the same body, index for index).
    pub fn clone(self: *const Body, allocator: std.mem.Allocator) Error!Body {
        var out = Body.init(allocator, self.tol);
        errdefer out.deinit();
        out.kind = self.kind;
        out.first_shell = self.first_shell;
        try out.vertices.appendSlice(allocator, self.vertices.items);
        try out.edges.appendSlice(allocator, self.edges.items);
        try out.coedges.appendSlice(allocator, self.coedges.items);
        try out.loops.appendSlice(allocator, self.loops.items);
        try out.faces.appendSlice(allocator, self.faces.items);
        try out.shells.appendSlice(allocator, self.shells.items);
        out.geometry = try self.geometry.clone(allocator);
        out.tags = try self.tags.clone(allocator);
        return out;
    }

    // --- accessors (by typed index; none is a bug, caught in Debug by the bounds check) ---

    pub fn vertex(self: *const Body, i: VertexIndex) *types.Vertex {
        return &self.vertices.items[@backingInt(i)];
    }
    pub fn edge(self: *const Body, i: EdgeIndex) *types.Edge {
        return &self.edges.items[@backingInt(i)];
    }
    pub fn coedge(self: *const Body, i: CoedgeIndex) *types.Coedge {
        return &self.coedges.items[@backingInt(i)];
    }
    pub fn loop(self: *const Body, i: LoopIndex) *types.Loop {
        return &self.loops.items[@backingInt(i)];
    }
    pub fn face(self: *const Body, i: FaceIndex) *types.Face {
        return &self.faces.items[@backingInt(i)];
    }
    pub fn shell(self: *const Body, i: ShellIndex) *types.Shell {
        return &self.shells.items[@backingInt(i)];
    }

    /// The vertex a coedge starts at: its edge's start when traversed forward.
    pub fn coedgeStart(self: *const Body, c: CoedgeIndex) VertexIndex {
        const ce = self.coedge(c);
        const e = self.edge(ce.edge);
        return if (ce.same_sense) e.start else e.end;
    }

    pub fn coedgeEnd(self: *const Body, c: CoedgeIndex) VertexIndex {
        const ce = self.coedge(c);
        const e = self.edge(ce.edge);
        return if (ce.same_sense) e.end else e.start;
    }

    pub fn point(self: *const Body, v: VertexIndex) Vec3 {
        return self.geometry.point(self.vertex(v).point);
    }

    // --- adding entities ---

    pub fn addVertex(self: *Body, v: types.Vertex) Error!VertexIndex {
        if (self.vertices.items.len >= MAX_ENTITIES) return error.TooMany;
        try self.vertices.append(self.allocator, v);
        return VertexIndex.of(self.vertices.items.len - 1);
    }

    pub fn addEdge(self: *Body, e: types.Edge) Error!EdgeIndex {
        if (self.edges.items.len >= MAX_ENTITIES) return error.TooMany;
        try self.edges.append(self.allocator, e);
        return EdgeIndex.of(self.edges.items.len - 1);
    }

    pub fn addCoedge(self: *Body, c: types.Coedge) Error!CoedgeIndex {
        if (self.coedges.items.len >= MAX_ENTITIES) return error.TooMany;
        try self.coedges.append(self.allocator, c);
        return CoedgeIndex.of(self.coedges.items.len - 1);
    }

    pub fn addLoop(self: *Body, l: types.Loop) Error!LoopIndex {
        if (self.loops.items.len >= MAX_ENTITIES) return error.TooMany;
        try self.loops.append(self.allocator, l);
        return LoopIndex.of(self.loops.items.len - 1);
    }

    pub fn addFace(self: *Body, f: types.Face) Error!FaceIndex {
        if (self.faces.items.len >= MAX_ENTITIES) return error.TooMany;
        try self.faces.append(self.allocator, f);
        return FaceIndex.of(self.faces.items.len - 1);
    }

    pub fn addShell(self: *Body, s: types.Shell) Error!ShellIndex {
        if (self.shells.items.len >= MAX_ENTITIES) return error.TooMany;
        try self.shells.append(self.allocator, s);
        return ShellIndex.of(self.shells.items.len - 1);
    }

    /// Reserves room for `n` more of each entity, so a construction that counted its
    /// entities cannot fail for memory midway.
    pub fn reserve(self: *Body, n: usize) Error!void {
        try self.vertices.ensureUnusedCapacity(self.allocator, n);
        try self.edges.ensureUnusedCapacity(self.allocator, n);
        try self.coedges.ensureUnusedCapacity(self.allocator, 2 * n);
        try self.loops.ensureUnusedCapacity(self.allocator, n);
        try self.faces.ensureUnusedCapacity(self.allocator, n);
        try self.shells.ensureUnusedCapacity(self.allocator, n);
    }

    // --- intrusive lists ---

    /// Links `l` as the last loop of its face (the first loop stays the outer one).
    pub fn appendLoop(self: *Body, f: FaceIndex, l: LoopIndex) void {
        const fc = self.face(f);
        self.loop(l).next_in_face = .none;
        if (fc.first_loop == .none) {
            fc.first_loop = l;
            return;
        }
        var last = fc.first_loop;
        var steps: usize = 0;
        while (self.loop(last).next_in_face != .none) : (last = self.loop(last).next_in_face) {
            steps += 1;
            std.debug.assert(steps <= self.loops.items.len);
        }
        self.loop(last).next_in_face = l;
    }

    /// Unlinks `l` from its face's loops.
    pub fn removeLoop(self: *Body, f: FaceIndex, l: LoopIndex) void {
        const fc = self.face(f);
        if (fc.first_loop == l) {
            fc.first_loop = self.loop(l).next_in_face;
        } else {
            var prev = fc.first_loop;
            var steps: usize = 0;
            while (self.loop(prev).next_in_face != l) : (prev = self.loop(prev).next_in_face) {
                steps += 1;
                std.debug.assert(steps <= self.loops.items.len);
            }
            self.loop(prev).next_in_face = self.loop(l).next_in_face;
        }
        self.loop(l).next_in_face = .none;
    }

    /// Links `f` as the first face of shell `s` (order among faces means nothing).
    pub fn appendFace(self: *Body, s: ShellIndex, f: FaceIndex) void {
        const sh = self.shell(s);
        self.face(f).shell = s;
        self.face(f).next_in_shell = sh.first_face;
        sh.first_face = f;
    }

    pub fn removeFace(self: *Body, s: ShellIndex, f: FaceIndex) void {
        const sh = self.shell(s);
        if (sh.first_face == f) {
            sh.first_face = self.face(f).next_in_shell;
        } else {
            var prev = sh.first_face;
            var steps: usize = 0;
            while (self.face(prev).next_in_shell != f) : (prev = self.face(prev).next_in_shell) {
                steps += 1;
                std.debug.assert(steps <= self.faces.items.len);
            }
            self.face(prev).next_in_shell = self.face(f).next_in_shell;
        }
        self.face(f).next_in_shell = .none;
    }

    pub fn appendShell(self: *Body, s: ShellIndex) void {
        self.shell(s).next_in_body = self.first_shell;
        self.first_shell = s;
    }

    pub fn removeShell(self: *Body, s: ShellIndex) void {
        if (self.first_shell == s) {
            self.first_shell = self.shell(s).next_in_body;
        } else {
            var prev = self.first_shell;
            var steps: usize = 0;
            while (self.shell(prev).next_in_body != s) : (prev = self.shell(prev).next_in_body) {
                steps += 1;
                std.debug.assert(steps <= self.shells.items.len);
            }
            self.shell(prev).next_in_body = self.shell(s).next_in_body;
        }
        self.shell(s).next_in_body = .none;
    }

    // --- counts of live entities ---

    pub const Counts = struct { vertices: usize = 0, edges: usize = 0, coedges: usize = 0, loops: usize = 0, faces: usize = 0, shells: usize = 0 };

    pub fn counts(self: *const Body) Counts {
        var c: Counts = .{};
        for (self.vertices.items) |v| c.vertices += @intFromBool(!v.tombstone);
        for (self.edges.items) |e| c.edges += @intFromBool(!e.flags.tombstone);
        for (self.coedges.items) |ce| c.coedges += @intFromBool(!ce.tombstone);
        for (self.loops.items) |l| c.loops += @intFromBool(!l.tombstone);
        for (self.faces.items) |f| c.faces += @intFromBool(!f.flags.tombstone);
        for (self.shells.items) |s| c.shells += @intFromBool(!s.tombstone);
        return c;
    }

    // --- compaction ---

    /// Old index → new index for one table; `NONE` for a dropped entity.
    pub const Remap = struct {
        vertices: []u32,
        edges: []u32,
        coedges: []u32,
        loops: []u32,
        faces: []u32,
        shells: []u32,

        pub const NONE: u32 = std.math.maxInt(u32);

        pub fn deinit(self: *Remap, allocator: std.mem.Allocator) void {
            allocator.free(self.vertices);
            allocator.free(self.edges);
            allocator.free(self.coedges);
            allocator.free(self.loops);
            allocator.free(self.faces);
            allocator.free(self.shells);
            self.* = undefined;
        }
    };

    /// Drops the tombstoned entities and renumbers the rest in order, rewriting every
    /// index; the geometry arena is left as it is (unused geometry costs only memory).
    /// Returns the remap tables, the caller's to free.
    pub fn compact(self: *Body) Error!Remap {
        var remap = Remap{
            .vertices = try renumber(self.allocator, types.Vertex, self.vertices.items, "tombstone"),
            .edges = undefined,
            .coedges = undefined,
            .loops = undefined,
            .faces = undefined,
            .shells = undefined,
        };
        errdefer self.allocator.free(remap.vertices);
        remap.edges = try renumberFlags(self.allocator, types.Edge, self.edges.items);
        errdefer self.allocator.free(remap.edges);
        remap.coedges = try renumber(self.allocator, types.Coedge, self.coedges.items, "tombstone");
        errdefer self.allocator.free(remap.coedges);
        remap.loops = try renumber(self.allocator, types.Loop, self.loops.items, "tombstone");
        errdefer self.allocator.free(remap.loops);
        remap.faces = try renumberFlags(self.allocator, types.Face, self.faces.items);
        errdefer self.allocator.free(remap.faces);
        remap.shells = try renumber(self.allocator, types.Shell, self.shells.items, "tombstone");
        errdefer self.allocator.free(remap.shells);

        // Rewrite the indices, then squeeze each table in place
        for (self.vertices.items) |*v| v.coedge = mapIndex(CoedgeIndex, v.coedge, remap.coedges);
        for (self.edges.items) |*e| {
            e.start = mapIndex(VertexIndex, e.start, remap.vertices);
            e.end = mapIndex(VertexIndex, e.end, remap.vertices);
            e.coedge = mapIndex(CoedgeIndex, e.coedge, remap.coedges);
        }
        for (self.coedges.items) |*c| {
            c.edge = mapIndex(EdgeIndex, c.edge, remap.edges);
            c.partner = mapIndex(CoedgeIndex, c.partner, remap.coedges);
            c.next = mapIndex(CoedgeIndex, c.next, remap.coedges);
            c.prev = mapIndex(CoedgeIndex, c.prev, remap.coedges);
            c.loop = mapIndex(LoopIndex, c.loop, remap.loops);
        }
        for (self.loops.items) |*l| {
            l.face = mapIndex(FaceIndex, l.face, remap.faces);
            l.first = mapIndex(CoedgeIndex, l.first, remap.coedges);
            l.vertex = mapIndex(VertexIndex, l.vertex, remap.vertices);
            l.next_in_face = mapIndex(LoopIndex, l.next_in_face, remap.loops);
        }
        for (self.faces.items) |*f| {
            f.first_loop = mapIndex(LoopIndex, f.first_loop, remap.loops);
            f.shell = mapIndex(ShellIndex, f.shell, remap.shells);
            f.next_in_shell = mapIndex(FaceIndex, f.next_in_shell, remap.faces);
        }
        for (self.shells.items) |*s| {
            s.first_face = mapIndex(FaceIndex, s.first_face, remap.faces);
            s.next_in_body = mapIndex(ShellIndex, s.next_in_body, remap.shells);
        }
        self.first_shell = mapIndex(ShellIndex, self.first_shell, remap.shells);

        squeeze(types.Vertex, &self.vertices, remap.vertices);
        squeeze(types.Edge, &self.edges, remap.edges);
        squeeze(types.Coedge, &self.coedges, remap.coedges);
        squeeze(types.Loop, &self.loops, remap.loops);
        squeeze(types.Face, &self.faces, remap.faces);
        squeeze(types.Shell, &self.shells, remap.shells);
        return remap;
    }

    // --- checkpoints ---

    /// A copy of the body to go back to: `restore` puts it back, whatever happened since.
    pub const Checkpoint = struct {
        copy: Body,

        pub fn deinit(self: *Checkpoint) void {
            self.copy.deinit();
        }

        /// `body` becomes the copy again; the checkpoint is spent.
        pub fn restore(self: *Checkpoint, body: *Body) void {
            body.deinit();
            body.* = self.copy;
            self.* = undefined;
        }
    };

    pub fn checkpoint(self: *const Body) Error!Checkpoint {
        return .{ .copy = try self.clone(self.allocator) };
    }
};

fn renumber(allocator: std.mem.Allocator, comptime T: type, items: []const T, comptime flag: []const u8) Error![]u32 {
    const map = try allocator.alloc(u32, items.len);
    var next: u32 = 0;
    for (items, map) |item, *m| {
        if (@field(item, flag)) {
            m.* = Body.Remap.NONE;
        } else {
            m.* = next;
            next += 1;
        }
    }
    return map;
}

fn renumberFlags(allocator: std.mem.Allocator, comptime T: type, items: []const T) Error![]u32 {
    const map = try allocator.alloc(u32, items.len);
    var next: u32 = 0;
    for (items, map) |item, *m| {
        if (item.flags.tombstone) {
            m.* = Body.Remap.NONE;
        } else {
            m.* = next;
            next += 1;
        }
    }
    return map;
}

fn mapIndex(comptime Index: type, i: Index, map: []const u32) Index {
    if (i == .none) return .none;
    const m = map[@backingInt(i)];
    return if (m == Body.Remap.NONE) .none else @fromBackingInt(@intCast(m));
}

fn squeeze(comptime T: type, list: *std.ArrayList(T), map: []const u32) void {
    var kept: usize = 0;
    for (list.items, map) |item, m| {
        if (m == Body.Remap.NONE) continue;
        list.items[kept] = item;
        kept += 1;
    }
    list.shrinkRetainingCapacity(kept);
}
