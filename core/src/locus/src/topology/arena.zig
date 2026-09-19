const std = @import("std");
const types = @import("types.zig");
const he = @import("half_edge.zig");

pub const Vertex = he.Vertex;
pub const HalfEdge = he.HalfEdge;
pub const Loop = he.Loop;
pub const Face = he.Face;
pub const Shell = he.Shell;
pub const Solid = he.Solid;

pub const TopologyArena = struct {
    vertices: std.ArrayListUnmanaged(he.Vertex) = .empty,
    half_edges: std.ArrayListUnmanaged(he.HalfEdge) = .empty,
    loops: std.ArrayListUnmanaged(he.Loop) = .empty,
    faces: std.ArrayListUnmanaged(he.Face) = .empty,
    shells: std.ArrayListUnmanaged(he.Shell) = .empty,
    solids: std.ArrayListUnmanaged(he.Solid) = .empty,

    face_loops: std.ArrayListUnmanaged(types.LoopIndex) = .empty,
    shell_faces: std.ArrayListUnmanaged(types.FaceIndex) = .empty,
    solid_shells: std.ArrayListUnmanaged(types.ShellIndex) = .empty,

    pub fn init() TopologyArena {
        return .{};
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
};
