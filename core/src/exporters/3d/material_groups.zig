//! A mesh's triangles grouped by material: the slot of each (kernel.materialSlot, a vertex's
//! fourth property; DEFAULT_MATERIAL_SLOT for a mesh without one), for the exporters that
//! write one group per material (glTF's primitives, OBJ's `usemtl` runs). Each kept its own
//! grouping.

const std = @import("std");
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");

/// The material slot of the triangle starting at `tri` in `mesh.tri_verts`: its first
/// vertex's.
pub fn slotOf(mesh: geom.Mesh, tri: usize) u32 {
    if (mesh.num_prop < 4) return kernel.DEFAULT_MATERIAL_SLOT;
    return @intFromFloat(mesh.vert_props[mesh.tri_verts[tri] * mesh.num_prop + 3]);
}

/// Each material slot of a mesh with the starts of its triangles, slots in the order they
/// first appear and triangles in the mesh's, so the output is the same every time.
pub const Groups = struct {
    by_slot: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,

    pub fn collect(allocator: std.mem.Allocator, mesh: geom.Mesh) !Groups {
        var groups: Groups = .{};
        errdefer groups.deinit(allocator);
        var tri: usize = 0;
        while (tri < mesh.tri_verts.len) : (tri += 3) {
            const gop = try groups.by_slot.getOrPut(allocator, slotOf(mesh, tri));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, @intCast(tri));
        }
        return groups;
    }

    pub fn deinit(self: *Groups, allocator: std.mem.Allocator) void {
        for (self.by_slot.values()) |*tris| tris.deinit(allocator);
        self.by_slot.deinit(allocator);
    }

    /// How many groups there are.
    pub fn count(self: *const Groups) usize {
        return self.by_slot.count();
    }

    pub const Group = struct { slot: u32, tri_starts: []const u32 };

    /// The `i`th group.
    pub fn at(self: *const Groups, i: usize) Group {
        return .{ .slot = self.by_slot.keys()[i], .tri_starts = self.by_slot.values()[i].items };
    }
};
