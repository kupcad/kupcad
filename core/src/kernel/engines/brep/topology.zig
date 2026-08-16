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
    vertices: []const Vertex,
    edges: []const Edge,
    wires: []const Wire,
    faces: []const Face,
    shells: []const Shell,
    solids: []const Solid,

    // Flattened Relationship Arrays
    wire_edges: []const u32,
    face_inner_wires: []const u32,
    shell_faces: []const u32,

    pub fn initEmpty(allocator: std.mem.Allocator) Brep {
        return .{
            .allocator = allocator,
            .vertices = &[_]Vertex{},
            .edges = &[_]Edge{},
            .wires = &[_]Wire{},
            .faces = &[_]Face{},
            .shells = &[_]Shell{},
            .solids = &[_]Solid{},
            .wire_edges = &[_]u32{},
            .face_inner_wires = &[_]u32{},
            .shell_faces = &[_]u32{},
        };
    }

    pub fn deinit(self: *Brep) void {
        _ = self;
    }
};
