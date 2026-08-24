const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;

// A Half-Edge data structure optimized purely for Quickhull generation
const HalfEdge = struct {
    end_vertex: u32,
    opp_edge: u32,
    face: u32,
    next_edge: u32,
    disabled: bool = false,
};

const HullFace = struct {
    plane_normal: Vec3,
    plane_distance: f64,
    first_half_edge: u32,
    farthest_point: u32 = 0,
    farthest_dist: f64 = 0.0,
    visible: bool = false,
    disabled: bool = false,
    // Indices of points outside this face
    points_outside: std.ArrayListUnmanaged(u32) = .empty,
};

pub const QuickhullBuilder = struct {
    allocator: std.mem.Allocator,
    vertices: []const Vec3,

    half_edges: std.ArrayListUnmanaged(HalfEdge) = .empty,
    faces: std.ArrayListUnmanaged(HullFace) = .empty,

    pub fn init(allocator: std.mem.Allocator, points: []const Vec3) QuickhullBuilder {
        return .{
            .allocator = allocator,
            .vertices = points,
        };
    }

    pub fn deinit(self: *QuickhullBuilder) void {
        for (self.faces.items) |*f| {
            f.points_outside.deinit(self.allocator);
        }
        self.half_edges.deinit(self.allocator);
        self.faces.deinit(self.allocator);
    }

    /// Finds the indices of the 6 extrema points: MinX, MaxX, MinY, MaxY, MinZ, MaxZ.
    pub fn computeExtrema(self: *const QuickhullBuilder) [6]u32 {
        var extrema = [_]u32{0} ** 6;
        var vals = [_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64) };

        for (self.vertices, 0..) |v, i| {
            if (v[0] < vals[0]) {
                vals[0] = v[0];
                extrema[0] = @intCast(i);
            }
            if (v[0] > vals[1]) {
                vals[1] = v[0];
                extrema[1] = @intCast(i);
            }
            if (v[1] < vals[2]) {
                vals[2] = v[1];
                extrema[2] = @intCast(i);
            }
            if (v[1] > vals[3]) {
                vals[3] = v[1];
                extrema[3] = @intCast(i);
            }
            if (v[2] < vals[4]) {
                vals[4] = v[2];
                extrema[4] = @intCast(i);
            }
            if (v[2] > vals[5]) {
                vals[5] = v[2];
                extrema[5] = @intCast(i);
            }
        }
        return extrema;
    }

    // Step 2: Build the Initial Tetrahedron & Horizon Expansion Logic
    // [Implementation logic porting `quickhull.lisp` will continue here]
};
