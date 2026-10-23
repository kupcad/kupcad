//! A mesh a file gives (an STL's, an OBJ's, a 3MF's), for the kernel: its points and its
//! triangles (`Mesh`), built by `Builder`, which merges the points the file repeats (by
//! their bits, as the file wrote them) and refuses one that isn't finite, which the kernel
//! can't place (a mesh with one crashed a build; the importer fuzz test found it).

const std = @import("std");

pub const Mesh = struct {
    points: [][3]f64,
    faces: [][3]u32,

    pub fn deinit(self: Mesh, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.faces);
    }
};

pub const Builder = struct {
    points: std.ArrayList([3]f64) = .empty,
    faces: std.ArrayList([3]u32) = .empty,
    /// Each point's index, by its coordinates' bits
    index: std.AutoHashMapUnmanaged([3]u64, u32) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        self.faces.deinit(allocator);
        self.index.deinit(allocator);
    }

    /// The index of the point at `p`, added unless the mesh has it already.
    /// error.NonFiniteVertex for a coordinate that is NaN or infinite.
    pub fn point(self: *Builder, allocator: std.mem.Allocator, p: [3]f64) error{ NonFiniteVertex, OutOfMemory }!u32 {
        for (p) |c| if (!std.math.isFinite(c)) return error.NonFiniteVertex;
        const entry = try self.index.getOrPut(allocator, .{ @bitCast(p[0]), @bitCast(p[1]), @bitCast(p[2]) });
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(self.points.items.len);
            try self.points.append(allocator, p);
        }
        return entry.value_ptr.*;
    }

    pub fn triangle(self: *Builder, allocator: std.mem.Allocator, corners: [3]u32) !void {
        try self.faces.append(allocator, corners);
    }

    /// The mesh built, owned by `allocator`; the builder is spent.
    pub fn finish(self: *Builder, allocator: std.mem.Allocator) !Mesh {
        defer self.deinit(allocator);
        const points = try self.points.toOwnedSlice(allocator);
        errdefer allocator.free(points);
        return .{ .points = points, .faces = try self.faces.toOwnedSlice(allocator) };
    }
};
