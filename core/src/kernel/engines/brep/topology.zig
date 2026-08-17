const std = @import("std");

/// Exact 3D Coordinate
pub const Point3D = struct { x: f64, y: f64, z: f64 };

/// Topological Entities (Pure Data-Oriented Design via Flat Indices)
pub const Vertex = struct { point: Point3D };
pub const Edge = struct { start_vertex: u32, end_vertex: u32 };

// Flattened from `edges: []const u32`
pub const Wire = struct { first_edge: u32, num_edges: u32 };

// Flattened from `inner_wires: []const u32`
pub const Face = struct { outer_wire: u32, first_inner_wire: u32, num_inner_wires: u32 };

// Flattened from `faces: []const u32`
pub const Shell = struct { first_face: u32, num_faces: u32 };

pub const Solid = struct { outer_shell: u32 };

/// The master B-Rep object holding ALL data in contiguous arrays (100% Cache Local)
pub const Brep = struct {
    allocator: std.mem.Allocator,

    // Entity Arrays
    vertices: std.ArrayListUnmanaged(Vertex),
    edges: std.ArrayListUnmanaged(Edge),
    wires: std.ArrayListUnmanaged(Wire),
    faces: std.ArrayListUnmanaged(Face),
    shells: std.ArrayListUnmanaged(Shell),
    solids: std.ArrayListUnmanaged(Solid),

    // Flattened Relationship Arrays
    wire_edges: []const u32,
    face_inner_wires: []const u32,
    shell_faces: []const u32,

    pub fn initEmpty(allocator: std.mem.Allocator) Brep {
        return .{
            .allocator = allocator,
            .vertices = .empty,
            .edges = .empty,
            .wires = .empty,
            .faces = .empty,
            .shells = .empty,
            .solids = .empty,
            .wire_edges = &[_]u32{},
            .face_inner_wires = &[_]u32{},
            .shell_faces = &[_]u32{},
        };
    }

    pub fn deinit(self: *Brep) void {
        self.vertices.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.wires.deinit(self.allocator);
        self.faces.deinit(self.allocator);
        self.shells.deinit(self.allocator);
        self.solids.deinit(self.allocator);

        if (self.wire_edges.len > 0) self.allocator.free(self.wire_edges);
        if (self.face_inner_wires.len > 0) self.allocator.free(self.face_inner_wires);
        if (self.shell_faces.len > 0) self.allocator.free(self.shell_faces);
    }
};
