//! The entities of a body (docs/architecture.md §5.2): a manifold B-Rep in the half-edge
//! form with explicit edge records. Entities live in arrays of the body, addressed by
//! typed indices (`none` is the null index); one-to-many relations (face → loops, shell →
//! faces, body → shells) are intrusive index lists, so an insertion is O(1) anywhere.
//! Deletion is a tombstone bit; `Body.compact` renumbers.

const std = @import("std");
const geometry = @import("../geometry/types.zig");

pub const VertexIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn of(i: usize) VertexIndex {
        return @fromBackingInt(@intCast(i));
    }
};
pub const EdgeIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn of(i: usize) EdgeIndex {
        return @fromBackingInt(@intCast(i));
    }
};
pub const CoedgeIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn of(i: usize) CoedgeIndex {
        return @fromBackingInt(@intCast(i));
    }
};
pub const LoopIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn of(i: usize) LoopIndex {
        return @fromBackingInt(@intCast(i));
    }
};
pub const FaceIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn of(i: usize) FaceIndex {
        return @fromBackingInt(@intCast(i));
    }
};
pub const ShellIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn of(i: usize) ShellIndex {
        return @fromBackingInt(@intCast(i));
    }
};

/// A row of the tag table (tags.zig): where an entity came from. 0 is "untagged".
pub const Tag = enum(u32) {
    untagged = 0,
    _,
    pub fn of(i: usize) Tag {
        return @fromBackingInt(@intCast(i));
    }
};

/// How an edge's two faces meet across it.
pub const Regularity = enum(u8) {
    /// A real crease: the viewer draws it, `simplify` never merges across it.
    c0,
    /// Tangent planes agree: a seam split, a fillet's boundary.
    g1,
    g2,
};

pub const ShellKind = enum(u8) { outer, void, sheet };

pub const EdgeFlags = packed struct(u8) {
    /// The 3D curve is a point (`start == end`): a sphere's pole, a cone's apex.
    degenerate: bool = false,
    /// On the split of a periodic surface (D7): both faces lie on one surface.
    seam: bool = false,
    /// The curve is an approximation within `approx` (a marched intersection).
    approx: bool = false,
    tombstone: bool = false,
    _pad: u4 = 0,
};

pub const FaceFlags = packed struct(u8) {
    /// Some pcurve of the face is an approximation.
    approx: bool = false,
    tombstone: bool = false,
    _pad: u6 = 0,
};

pub const Vertex = struct {
    point: geometry.PointIndex,
    /// How far the construction missed, at most the body's `zone`.
    gap: f64 = 0,
    /// One coedge leaving it; `none` for a vertex no edge uses yet.
    coedge: CoedgeIndex = .none,
    tag: Tag = .untagged,
    tombstone: bool = false,
};

pub const Edge = struct {
    curve: geometry.CurveRef,
    t0: f64,
    t1: f64,
    start: VertexIndex,
    end: VertexIndex,
    gap: f64 = 0,
    /// The first of its coedges (the other is its partner); `none` only mid-construction.
    coedge: CoedgeIndex = .none,
    flags: EdgeFlags = .{},
    regularity: Regularity = .c0,
    tag: Tag = .untagged,
};

pub const Coedge = struct {
    edge: EdgeIndex,
    /// Traverses the edge from `t0` to `t1`.
    same_sense: bool,
    /// The coedge on the other face of the edge, opposite in sense; `none` on a sheet's
    /// boundary.
    partner: CoedgeIndex = .none,
    next: CoedgeIndex = .none,
    prev: CoedgeIndex = .none,
    loop: LoopIndex,
    /// The edge's image in the face's UV box; `none` on a plane, where it is computed.
    pcurve: geometry.PCurveRef = geometry.PCurveRef.none,
    tombstone: bool = false,
};

pub const Loop = struct {
    face: FaceIndex,
    /// Its first coedge; `none` for a loop of one vertex (`vertex` then).
    first: CoedgeIndex = .none,
    /// The vertex of a loop without coedges (a face just made, an isolated vertex).
    vertex: VertexIndex = .none,
    next_in_face: LoopIndex = .none,
    tombstone: bool = false,
};

pub const Face = struct {
    surface: geometry.SurfaceRef,
    /// The outward normal is the surface's when true, its opposite when false.
    same_sense: bool = true,
    /// The first loop is the outer one.
    first_loop: LoopIndex = .none,
    shell: ShellIndex,
    next_in_shell: FaceIndex = .none,
    /// The face's UV range, a plain box without wrap (D7).
    uv_box: geometry.Box2 = geometry.Box2.empty,
    flags: FaceFlags = .{},
    tag: Tag = .untagged,
    /// The host's value for the face, 0 for none (KupCAD's material slot; architecture §8):
    /// passive data, copied wherever the face goes or is split (a move, a split of its
    /// loop, a sweep's faces of a sheet's face), never read by Locus.
    attribute: u32 = 0,
};

pub const Shell = struct {
    first_face: FaceIndex = .none,
    next_in_body: ShellIndex = .none,
    kind: ShellKind = .outer,
    tombstone: bool = false,
};

/// Which table an index names, for findings and the change log.
pub const EntityKind = enum(u8) { vertex, edge, coedge, loop, face, shell };
