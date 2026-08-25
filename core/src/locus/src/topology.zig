const std = @import("std");
const geom = @import("geometry.zig");

// --- Strongly Typed Handles ---
pub const VertexId = u32;
pub const EdgeId = u32;
pub const WireId = u32;
pub const FaceId = u32;
pub const ShellId = u32;
pub const SolidId = u32;

// --- Topological Elements ---

/// A 3D point in space.
pub const Vertex = struct {
    point: [3]f64,
};

/// An edge bounded by two vertices, attached to a 3D curve[cite: 15].
pub const Edge = struct {
    front: VertexId,
    back: VertexId,
    curve: geom.CurveId, // Now uses the strict DOD packed struct[cite: 15]
};

/// Used in Wires to track traversal direction of an edge[cite: 15].
pub const DirectedEdge = struct {
    edge: EdgeId,
    forward: bool,
};

/// A sequence of connected edges forming a boundary loop[cite: 15].
pub const Wire = struct {
    edges_start: u32,
    edges_len: u32,
};

/// A topological face bounded by wires, attached to a surface[cite: 15].
pub const Face = struct {
    surface: geom.SurfaceId, // Now uses the strict DOD packed struct[cite: 15]
    forward: bool,
    wires_start: u32,
    wires_len: u32,
};

/// A connected set of faces[cite: 15].
pub const Shell = struct {
    faces_start: u32,
    faces_len: u32,
};

/// A 3D volume bounded by closed shells[cite: 15].
pub const Solid = struct {
    shells_start: u32,
    shells_len: u32,
};

// --- The Memory Arena ---

pub const TopologyArena = struct {
    allocator: std.mem.Allocator,

    // Core Elements
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
