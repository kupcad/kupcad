const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");

// --- ID Types ---
pub const VertexId = u32;
pub const HalfEdgeId = u32;
pub const LoopId = u32;
pub const FaceId = u32;
pub const ShellId = u32;
pub const SolidId = u32;

pub const NULL_ID: u32 = std.math.maxInt(u32);

// --- Topological Primitives ---

pub const Vertex = struct {
    point: math.Vec3,
    tolerance: f64 = 1e-7, // Localized precision boundary
};

pub const HalfEdge = struct {
    start_vertex: VertexId,
    twin: HalfEdgeId,
    next: HalfEdgeId,
    prev: HalfEdgeId,
    loop_id: LoopId,
    curve: geom.CurveId, // 3D World Curve
    p_curve: ?geom.PCurveId = null, // 2D Parametric Surface UV Curve
    forward: bool,
    tolerance: f64 = 1e-7, // Curve deviation tolerance
};

pub const Loop = struct {
    face_id: FaceId,
    first_half_edge: HalfEdgeId,
};

pub const Face = struct {
    surface: geom.SurfaceId,
    forward: bool,
    loops_start: u32,
    loops_len: u32,
    tolerance: f64 = 1e-7, // Surface sag/deviation tolerance
};

pub const Shell = struct {
    faces_start: u32,
    faces_len: u32,
};

pub const Solid = struct {
    shells_start: u32,
    shells_len: u32,
};

// --- The Global Graph Arena ---

pub const TopologyArena = struct {
    vertices: std.ArrayListUnmanaged(Vertex),
    half_edges: std.ArrayListUnmanaged(HalfEdge),
    loops: std.ArrayListUnmanaged(Loop),
    faces: std.ArrayListUnmanaged(Face),
    shells: std.ArrayListUnmanaged(Shell),
    solids: std.ArrayListUnmanaged(Solid),

    face_loops: std.ArrayListUnmanaged(LoopId),
    shell_faces: std.ArrayListUnmanaged(FaceId),
    solid_shells: std.ArrayListUnmanaged(ShellId),

    pub fn init(allocator: std.mem.Allocator) TopologyArena {
        _ = allocator; // Silences the unused parameter error
        return .{
            .vertices = .empty,
            .half_edges = .empty,
            .loops = .empty,
            .faces = .empty,
            .shells = .empty,
            .solids = .empty,
            .face_loops = .empty,
            .shell_faces = .empty,
            .solid_shells = .empty,
        };
    }

    pub fn deinit(self: *TopologyArena, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.half_edges.deinit(allocator);
        self.loops.deinit(allocator);
        self.faces.deinit(allocator);
        self.shells.deinit(allocator);
        self.solids.deinit(allocator);
        self.face_loops.deinit(allocator);
        self.shell_faces.deinit(allocator);
        self.solid_shells.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *TopologyArena) void {
        self.vertices.clearRetainingCapacity();
        self.half_edges.clearRetainingCapacity();
        self.loops.clearRetainingCapacity();
        self.faces.clearRetainingCapacity();
        self.shells.clearRetainingCapacity();
        self.solids.clearRetainingCapacity();
        self.face_loops.clearRetainingCapacity();
        self.shell_faces.clearRetainingCapacity();
        self.solid_shells.clearRetainingCapacity();
    }

    /// Computes the 2D UV parametric point for a half-edge's start vertex on its parent face.
    pub fn getHalfEdgeStartUV(self: TopologyArena, g_arena: *const geom.GeometryArena, he_id: HalfEdgeId) math.Vec2 {
        const he = self.half_edges.items[he_id];
        const loop = self.loops.items[he.loop_id];
        const face = self.faces.items[loop.face_id];
        const pt = self.vertices.items[he.start_vertex].point;
        return g_arena.surfaceProject(face.surface, pt);
    }

    /// Computes the 2D UV parametric point for a half-edge's end vertex on its parent face.
    pub fn getHalfEdgeEndUV(self: TopologyArena, g_arena: *const geom.GeometryArena, he_id: HalfEdgeId) math.Vec2 {
        const he = self.half_edges.items[he_id];
        const next_he = self.half_edges.items[he.next];
        const loop = self.loops.items[he.loop_id];
        const face = self.faces.items[loop.face_id];
        const pt = self.vertices.items[next_he.start_vertex].point;
        return g_arena.surfaceProject(face.surface, pt);
    }
};
