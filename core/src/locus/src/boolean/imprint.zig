//! The boolean's second phase (docs/architecture.md §7.4 step 3, §7.3; OCCT's
//! `BOPAlgo_BuilderFace`): each face of both operands split by what the other operand
//! left on it, through the overlay (D9, the one face-splitting engine). In the face's
//! plane the overlay takes the face's loops, each edge cut at its paves (input 0), and the
//! face's section segments run both ways, splitting but bounding nothing (input 1); each
//! region input 0 winds about is a fragment, its cycles the loops of a face of the result
//! should it be kept, outer first, run as the face's own loops run about its outward
//! normal.
//!
//! The paves made every point the face's pieces meet at, so the overlay's vertices are the
//! merged vertices: each one is read back by its coordinates. A vertex the overlay made
//! itself (a crossing the interferences did not find) would split this face where its
//! neighbour across an edge is not split, so it is refused (`imprint_unmatched`), never
//! sewn into a result with a gap.

const std = @import("std");
const vec = @import("../math/vec.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const overlay_mod = @import("../sketch/overlay.zig");
const pave = @import("pave.zig");
const Body = body_mod.Body;
const Overlay = overlay_mod.Overlay;
const Paves = pave.Paves;
const Vec2 = vec.Vec2;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// A piece of a face of an operand: its loops (`Fragments.loops[first_loop..]`, the outer
/// first), each a cycle of merged vertices.
pub const Fragment = struct {
    operand: u1,
    face: u32,
    first_loop: u32,
    loop_count: u32,
};

pub const Fragments = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Fragment) = .empty,
    /// Each loop as `vertices[start..][0..count]`.
    loops: std.ArrayList([2]u32) = .empty,
    vertices: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Fragments) void {
        self.items.deinit(self.allocator);
        self.loops.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn loopsOf(self: *const Fragments, i: usize) []const [2]u32 {
        const f = self.items.items[i];
        return self.loops.items[f.first_loop..][0..f.loop_count];
    }

    pub fn loopVertices(self: *const Fragments, loop: [2]u32) []const u32 {
        return self.vertices.items[loop[0]..][0..loop[1]];
    }
};

/// The fragments of every face of both operands.
pub fn run(allocator: std.mem.Allocator, paves: *const Paves, options: diagnostics.Options, diag: *Diagnostics) Error!Fragments {
    var out: Fragments = .{ .allocator = allocator };
    errdefer out.deinit();
    for (0..2) |k| {
        const body = paves.operands[k];
        var shells = traverse.Shells.init(body);
        while (shells.next() catch return corrupt(diag)) |s| {
            var faces = traverse.Faces.init(body, s);
            while (faces.next() catch return corrupt(diag)) |f| {
                try options.checkCancel();
                try face(allocator, paves, @intCast(k), f, &out, diag);
            }
        }
    }
    return out;
}

/// Every face of both operands whole, one fragment each (the containment table's, when the
/// paves found the operands apart): its loops as its coedges' starts, merged. A loop of one
/// vertex bounds nothing and is left out, as the general path's overlay leaves it out.
pub fn wholeFaces(allocator: std.mem.Allocator, paves: *const Paves, diag: *Diagnostics) Error!Fragments {
    var out: Fragments = .{ .allocator = allocator };
    errdefer out.deinit();
    for (0..2) |k| {
        const body = paves.operands[k];
        var shells = traverse.Shells.init(body);
        while (shells.next() catch return corrupt(diag)) |s| {
            var faces = traverse.Faces.init(body, s);
            while (faces.next() catch return corrupt(diag)) |f| {
                const first_loop: u32 = @intCast(out.loops.items.len);
                var loops = traverse.Loops.init(body, f);
                while (loops.next() catch return corrupt(diag)) |l| {
                    if (body.loop(l).first == .none) continue;
                    const start: u32 = @intCast(out.vertices.items.len);
                    var it = traverse.Coedges.init(body, l);
                    while (it.next() catch return corrupt(diag)) |c| try out.vertices.append(allocator, paves.vertex_of[k][@backingInt(body.coedgeStart(c))]);
                    try out.loops.append(allocator, .{ start, @intCast(out.vertices.items.len - start) });
                }
                try out.items.append(allocator, .{ .operand = @intCast(k), .face = @backingInt(f), .first_loop = first_loop, .loop_count = @intCast(out.loops.items.len - first_loop) });
            }
        }
    }
    return out;
}

/// The point's coordinates, the key the overlay's vertices are read back by.
const Key = [2]u64;

fn keyOf(p: Vec2) Key {
    return .{ @bitCast(p[0]), @bitCast(p[1]) };
}

/// Face `f` of operand `k` split into its fragments, appended to `out`.
fn face(allocator: std.mem.Allocator, paves: *const Paves, k: u1, f: types.FaceIndex, out: *Fragments, diag: *Diagnostics) Error!void {
    const body = paves.operands[k];
    const frame = planar_faces.frameOf(body, f).?;
    var o = Overlay.init(allocator, paves.tol);
    defer o.deinit();
    var lookup: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    defer lookup.deinit(allocator);
    const Add = struct {
        o: *Overlay,
        lookup: *std.AutoHashMapUnmanaged(Key, u32),
        allocator: std.mem.Allocator,
        paves: *const Paves,
        frame: @import("../geometry/types.zig").Frame,
        diag: *Diagnostics,
        fn edge(self: *const @This(), u: u32, w: u32) Error!void {
            const a = planar_faces.flat(self.frame, self.paves.point(u));
            const b = planar_faces.flat(self.frame, self.paves.point(w));
            try self.lookup.put(self.allocator, keyOf(a), u);
            try self.lookup.put(self.allocator, keyOf(b), w);
            self.o.addEdge(.{ .a = a, .b = b }) catch |e| return planar_faces.overlayError(self.diag, e);
        }
    };
    const add: Add = .{ .o = &o, .lookup = &lookup, .allocator = allocator, .paves = paves, .frame = frame, .diag = diag };

    // The face's loops, each edge cut at its paves, in the coedge's direction
    _ = o.addInput() catch |e| return planar_faces.overlayError(diag, e);
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const coedge = body.coedge(c);
            const list = paves.edge_paves[k][@backingInt(coedge.edge)].items;
            for (0..list.len - 1) |i| {
                if (coedge.same_sense) {
                    try add.edge(list[i].vertex, list[i + 1].vertex);
                } else {
                    try add.edge(list[list.len - 1 - i].vertex, list[list.len - 2 - i].vertex);
                }
            }
        }
    }
    // Its section segments, there and back
    _ = o.addInput() catch |e| return planar_faces.overlayError(diag, e);
    for (paves.sections[k][@backingInt(f)].items) |segment| {
        try add.edge(segment[0], segment[1]);
        try add.edge(segment[1], segment[0]);
    }
    o.run() catch |e| return planar_faces.overlayError(diag, e);

    // A valid face winds once about each of its regions: an operand's face that covers
    // part of its plane twice is named so before any of its regions is read back (its
    // loop's own crossings are no merged vertices, which reading a region would report)
    for (0..o.faces.items.len) |r| {
        const winding = o.windingOf(@intCast(r), 0);
        if (winding != 0 and winding != 1 and winding != -1) return diag.fail(error.InvalidInput, .{ .code = .faces_overlap, .entity = .of(.face, @backingInt(f)), .label = "a face of an operand", .measured = @floatFromInt(winding), .threshold = 1 });
    }
    for (0..o.faces.items.len) |r| {
        const winding = o.windingOf(@intCast(r), 0);
        if (winding == 0) continue;
        const first_loop: u32 = @intCast(out.loops.items.len);
        const region = o.faces.items[r];
        try cycle(&o, &lookup, region.outer, winding < 0, out, k, f, diag);
        for (o.holesOf(@intCast(r))) |hole| try cycle(&o, &lookup, hole, winding < 0, out, k, f, diag);
        try out.items.append(out.allocator, .{ .operand = k, .face = @backingInt(f), .first_loop = first_loop, .loop_count = @intCast(out.loops.items.len - first_loop) });
    }
}

/// Overlay cycle `c` as a loop of merged vertices, reversed when the face's loops run
/// clockwise in its plane's coordinates (its outward normal against the plane's).
fn cycle(o: *const Overlay, lookup: *const std.AutoHashMapUnmanaged(Key, u32), c: u32, reverse: bool, out: *Fragments, k: u1, f: types.FaceIndex, diag: *Diagnostics) Error!void {
    const start: u32 = @intCast(out.vertices.items.len);
    for (o.halvesOf(c)) |half| {
        const v = lookup.get(keyOf(o.point(o.origin(half)))) orelse return diag.fail(error.IntersectionFailed, .{ .code = .imprint_unmatched, .entity = .of(.face, @backingInt(f)), .label = if (k == 0) "a face of the first operand, imprinted with what the second leaves on it (face–face)" else "a face of the second operand, imprinted with what the first leaves on it (face–face)" });
        try out.vertices.append(out.allocator, v);
    }
    const count: u32 = @intCast(out.vertices.items.len - start);
    if (reverse) std.mem.reverse(u32, out.vertices.items[start..]);
    try out.loops.append(out.allocator, .{ start, count });
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "an operand" });
}
