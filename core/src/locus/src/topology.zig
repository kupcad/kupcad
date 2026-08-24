const std = @import("std");

// --- Strongly Typed Handles ---
pub const VertexId = u32;
pub const EdgeId = u32;
pub const WireId = u32;
pub const FaceId = u32;
pub const ShellId = u32;
pub const SolidId = u32;

// --- Geometric Handles ---
pub const CurveId = u32;
pub const SurfaceId = u32;

// --- Topological Elements ---

pub const Vertex = struct {
    point: [3]f64,
};

pub const Edge = struct {
    front: VertexId,
    back: VertexId,
    curve: CurveId,
};

pub const DirectedEdge = struct {
    edge: EdgeId,
    forward: bool,
};

pub const Wire = struct {
    edges_start: u32,
    edges_len: u32,
};

pub const Face = struct {
    surface: SurfaceId,
    forward: bool,
    wires_start: u32,
    wires_len: u32,
};

pub const Shell = struct {
    faces_start: u32,
    faces_len: u32,
};

pub const Solid = struct {
    shells_start: u32,
    shells_len: u32,
};

// --- The Memory Arena ---

pub const TopologyArena = struct {
    allocator: std.mem.Allocator,

    // Primary Elements
    vertices: std.ArrayListUnmanaged(Vertex) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    wires: std.ArrayListUnmanaged(Wire) = .empty,
    faces: std.ArrayListUnmanaged(Face) = .empty,
    shells: std.ArrayListUnmanaged(Shell) = .empty,
    solids: std.ArrayListUnmanaged(Solid) = .empty,

    // Relational Flattened Arrays (100% Cache Local)
    wire_edges: std.ArrayListUnmanaged(DirectedEdge) = .empty,
    face_wires: std.ArrayListUnmanaged(WireId) = .empty,
    shell_faces: std.ArrayListUnmanaged(FaceId) = .empty,
    solid_shells: std.ArrayListUnmanaged(ShellId) = .empty,

    pub fn init(allocator: std.mem.Allocator) TopologyArena {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TopologyArena) void {
        self.vertices.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.wires.deinit(self.allocator);
        self.faces.deinit(self.allocator);
        self.shells.deinit(self.allocator);
        self.solids.deinit(self.allocator);

        self.wire_edges.deinit(self.allocator);
        self.face_wires.deinit(self.allocator);
        self.shell_faces.deinit(self.allocator);
        self.solid_shells.deinit(self.allocator);
    }
};
