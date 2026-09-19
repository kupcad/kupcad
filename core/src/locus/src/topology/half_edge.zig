const types = @import("types.zig");
const geom_types = @import("../geometry/types.zig");

pub const Vertex = struct {
    point: geom_types.PointIndex,
};

pub const HalfEdge = struct {
    twin: types.HalfEdgeIndex,
    next: types.HalfEdgeIndex,
    prev: types.HalfEdgeIndex,
    start_vertex: types.VertexIndex,
    loop_id: types.LoopIndex,

    curve: geom_types.CurveHandle,
    p_curve: ?geom_types.PCurveHandle = null,

    forward: bool,
};

pub const Loop = struct {
    face_id: types.FaceIndex,
    first_half_edge: types.HalfEdgeIndex,
};

pub const Face = struct {
    surface: geom_types.SurfaceHandle,
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
