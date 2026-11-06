//! Walks over a body's entities, each bounded by the count of what it walks over (README
//! rule 4): a cycle longer than that is a corrupt body, which `error.Corrupt` reports
//! rather than looping. `next()` returns null at the end.

const std = @import("std");
const Body = @import("body.zig").Body;
const types = @import("types.zig");
const CoedgeIndex = types.CoedgeIndex;
const LoopIndex = types.LoopIndex;
const FaceIndex = types.FaceIndex;
const ShellIndex = types.ShellIndex;
const VertexIndex = types.VertexIndex;

pub const Error = error{Corrupt};

/// The coedges of a loop, from its first, around.
pub const Coedges = struct {
    body: *const Body,
    first: CoedgeIndex,
    current: CoedgeIndex,
    steps: usize = 0,

    pub fn init(body: *const Body, l: LoopIndex) Coedges {
        const first = body.loop(l).first;
        return .{ .body = body, .first = first, .current = first };
    }

    pub fn next(self: *Coedges) Error!?CoedgeIndex {
        if (self.current == .none) return null;
        if (self.steps >= self.body.coedges.items.len) return error.Corrupt;
        const out = self.current;
        self.steps += 1;
        const following = self.body.coedge(out).next;
        self.current = if (following == self.first) .none else following;
        return out;
    }
};

/// The loops of a face, the outer one first.
pub const Loops = struct {
    body: *const Body,
    current: LoopIndex,
    steps: usize = 0,

    pub fn init(body: *const Body, f: FaceIndex) Loops {
        return .{ .body = body, .current = body.face(f).first_loop };
    }

    pub fn next(self: *Loops) Error!?LoopIndex {
        if (self.current == .none) return null;
        if (self.steps >= self.body.loops.items.len) return error.Corrupt;
        const out = self.current;
        self.steps += 1;
        self.current = self.body.loop(out).next_in_face;
        return out;
    }
};

/// The faces of a shell.
pub const Faces = struct {
    body: *const Body,
    current: FaceIndex,
    steps: usize = 0,

    pub fn init(body: *const Body, s: ShellIndex) Faces {
        return .{ .body = body, .current = body.shell(s).first_face };
    }

    pub fn next(self: *Faces) Error!?FaceIndex {
        if (self.current == .none) return null;
        if (self.steps >= self.body.faces.items.len) return error.Corrupt;
        const out = self.current;
        self.steps += 1;
        self.current = self.body.face(out).next_in_shell;
        return out;
    }
};

/// The shells of a body.
pub const Shells = struct {
    body: *const Body,
    current: ShellIndex,
    steps: usize = 0,

    pub fn init(body: *const Body) Shells {
        return .{ .body = body, .current = body.first_shell };
    }

    pub fn next(self: *Shells) Error!?ShellIndex {
        if (self.current == .none) return null;
        if (self.steps >= self.body.shells.items.len) return error.Corrupt;
        const out = self.current;
        self.steps += 1;
        self.current = self.body.shell(out).next_in_body;
        return out;
    }
};

/// The coedges leaving a vertex, around it: from `vertex.coedge`, each next one is the
/// partner of the previous coedge in the loop (which ends at the vertex). On a sheet's
/// boundary the walk stops where there is no partner; the caller may restart from the
/// other side with `initFrom`.
pub const Umbrella = struct {
    body: *const Body,
    first: CoedgeIndex,
    current: CoedgeIndex,
    steps: usize = 0,

    pub fn init(body: *const Body, v: VertexIndex) Umbrella {
        return initFrom(body, body.vertex(v).coedge);
    }

    pub fn initFrom(body: *const Body, leaving: CoedgeIndex) Umbrella {
        return .{ .body = body, .first = leaving, .current = leaving };
    }

    pub fn next(self: *Umbrella) Error!?CoedgeIndex {
        if (self.current == .none) return null;
        if (self.steps >= self.body.coedges.items.len) return error.Corrupt;
        const out = self.current;
        self.steps += 1;
        const prev = self.body.coedge(out).prev;
        const around = if (prev == .none) .none else self.body.coedge(prev).partner;
        self.current = if (around == self.first) .none else around;
        return out;
    }
};

/// The two coedges of an edge: the first and its partner (which may be `none` on a sheet).
pub fn coedgesOfEdge(body: *const Body, e: types.EdgeIndex) [2]CoedgeIndex {
    const first = body.edge(e).coedge;
    return .{ first, if (first == .none) .none else body.coedge(first).partner };
}

/// How many coedges a loop has, bounded.
pub fn loopLength(body: *const Body, l: LoopIndex) Error!usize {
    var it = Coedges.init(body, l);
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}
