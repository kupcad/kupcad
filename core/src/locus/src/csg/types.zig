const math = @import("../math.zig");
const topo = @import("../topology.zig");

// --- Mathematical Curve Definitions for Exact SSI ---

pub const MathLine = struct {
    origin: math.Vec3,
    direction: math.Vec3,
};

pub const MathCircle = struct {
    center: math.Vec3,
    radius: f64,
    normal: math.Vec3,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
};

pub const IntersectionResult = union(enum) {
    empty,
    point: math.Vec3,
    line: MathLine,
    two_lines: [2]MathLine,
    circle: MathCircle,
    sampled: []math.Vec3,
    two_sampled: [2][]math.Vec3,
};

pub const Segment3D = struct {
    start: math.Vec3,
    end: math.Vec3,
};

pub const BooleanOp = enum {
    union_op,
    difference,
    intersection,
};
pub const FaceClassification = enum {
    inside,
    outside,
    same,
    opposite,
};

pub const BooleanError = error{
    OutOfMemory,
    DidNotConverge,
    SurfaceKindMismatch,
    TopologyCorrupted,
};

pub const IntersectionEvent = struct {
    he_id: topo.HalfEdgeId,
    edge_solid: topo.SolidId,
    face_id: topo.FaceId,
    pt: math.Vec3,
    t: f64,
    dynamic_tol: f64,
};

pub const FaceTracker = struct {
    face: topo.FaceId,
    source_solid: topo.SolidId,
};

pub const FaceAABB = struct {
    face_id: topo.FaceId,
    min: math.Vec3,
    max: math.Vec3,
};

pub const CurveSurfaceHit = struct {
    point: math.Vec3,
    sin_theta: f64,
};
