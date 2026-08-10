const std = @import("std");

/// Exact 3D Coordinate
pub const Point3D = struct { x: f64, y: f64, z: f64 };

/// Topological Entities (Data-Oriented Design via Indices)
pub const Vertex = struct { point: Point3D };
pub const Edge = struct { start_vertex: u32, end_vertex: u32 };
pub const Wire = struct { edges: []const u32 }; // A closed loop of edges
pub const Face = struct { outer_wire: u32, inner_wires: []const u32 };
pub const Shell = struct { faces: []const u32 }; // A connected set of faces
pub const Solid = struct { outer_shell: u32 };

/// The master B-Rep object holding all data in contiguous SoA/AoA arrays
pub const Brep = struct {
    allocator: std.mem.Allocator,

    vertices: []const Vertex,
    edges: []const Edge,
    wires: []const Wire,
    faces: []const Face,
    shells: []const Shell,
    solids: []const Solid,

    pub fn initEmpty(allocator: std.mem.Allocator) Brep {
        return .{
            .allocator = allocator,
            .vertices = &[_]Vertex{},
            .edges = &[_]Edge{},
            .wires = &[_]Wire{},
            .faces = &[_]Face{},
            .shells = &[_]Shell{},
            .solids = &[_]Solid{},
        };
    }

    pub fn deinit(self: *Brep) void {
        // In the future, this will free the slices
        _ = self;
    }
};
