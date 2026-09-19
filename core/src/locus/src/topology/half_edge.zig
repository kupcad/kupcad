const types = @import("types.zig");
const arena = @import("arena.zig");
const geom_types = @import("../geometry/types.zig");

pub const Vertex = struct {
    point: geom_types.PointIndex, // Explicit link to coordinates in GeometryArena
    tolerance: f64 = 1e-5, // Needed for dynamic local welding logic
};

pub const HalfEdge = struct {
    start_vertex: types.VertexIndex,
    twin: types.HalfEdgeIndex,
    next: types.HalfEdgeIndex,
    prev: types.HalfEdgeIndex,
    loop_id: types.LoopIndex,

    // Links to explicit mathematical boundaries
    curve: geom_types.CurveId,
    p_curve: ?geom_types.PCurveId = null,

    start_uv: ?[2]f64 = null, // Cached parameter space projection for boundary stitching
    forward: bool,
};

pub const Loop = struct {
    face_id: types.FaceIndex,
    first_half_edge: types.HalfEdgeIndex,
};

pub const Face = struct {
    surface: geom_types.SurfaceId,
    forward: bool,
    loops_start: u32,
    loops_len: u32,
};

pub const Shell = struct {
    faces_start: u32,
    faces_len: u32,
};

pub const Solid = struct {
    shells_start: u32,
    shells_len: u32,
};

pub const VertexUmbrellaIterator = struct {
    t_arena: *const arena.TopologyArena,
    start_he: types.HalfEdgeIndex,
    current_he: types.HalfEdgeIndex,
    first_pass: bool = true,

    pub fn init(t_arena: *const arena.TopologyArena, vertex: types.VertexIndex) ?VertexUmbrellaIterator {
        // Find the first outgoing half-edge starting at this vertex
        for (t_arena.half_edges.items, 0..) |he, idx| {
            if (he.start_vertex == vertex) {
                const he_idx: types.HalfEdgeIndex = @enumFromInt(@as(u32, @intCast(idx)));
                return .{
                    .t_arena = t_arena,
                    .start_he = he_idx,
                    .current_he = he_idx,
                };
            }
        }
        return null;
    }

    pub fn next(self: *VertexUmbrellaIterator) ?types.HalfEdgeIndex {
        if (!self.first_pass and self.current_he == self.start_he) return null;
        if (self.current_he == types.NULL_HALF_EDGE) return null;

        self.first_pass = false;
        const yield_he = self.current_he;

        // Radial pivot: next outgoing half-edge is twin(prev(current_he))
        const he = self.t_arena.half_edges.items[@intFromEnum(self.current_he)];
        if (he.prev != types.NULL_HALF_EDGE) {
            const prev_he = self.t_arena.half_edges.items[@intFromEnum(he.prev)];
            self.current_he = prev_he.twin;
        } else {
            self.current_he = types.NULL_HALF_EDGE;
        }

        return yield_he;
    }
};
