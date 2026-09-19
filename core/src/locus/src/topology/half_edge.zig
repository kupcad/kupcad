const types = @import("types.zig");
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
