//! A mesh's triangles grouped by material: the slot of each (kernel.materialSlot, a vertex's
//! fourth property; DEFAULT_MATERIAL_SLOT for a mesh without one), for the exporters that
//! write one group per material (glTF's primitives, OBJ's `usemtl` runs; 3MF reads the slot
//! of each triangle). Each kept its own grouping.

const std = @import("std");
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../core/geometry_handle.zig");

/// The material slot of the triangle starting at `tri` in `mesh.tri_verts` (its first
/// vertex's), of the default and `material_count` materials after it: the default for a slot
/// past them, a material no export knows (an id an earlier run of a session made). Written
/// as it was, a glTF named a material past its table, which validators refuse and three.js
/// throws on.
pub fn slotOf(mesh: geom.Mesh, tri: usize, material_count: usize) u32 {
    if (mesh.num_prop < 4) return kernel.DEFAULT_MATERIAL_SLOT;
    const slot: u32 = @intFromFloat(mesh.vert_props[mesh.tri_verts[tri] * mesh.num_prop + 3]);
    return if (slot <= material_count) slot else kernel.DEFAULT_MATERIAL_SLOT;
}

/// Each material slot of a mesh with the starts of its triangles, slots in the order they
/// first appear and triangles in the mesh's, so the output is the same every time.
pub const Groups = struct {
    by_slot: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,

    pub fn collect(allocator: std.mem.Allocator, mesh: geom.Mesh, material_count: usize) !Groups {
        var groups: Groups = .{};
        errdefer groups.deinit(allocator);
        var tri: usize = 0;
        while (tri < mesh.tri_verts.len) : (tri += 3) {
            const gop = try groups.by_slot.getOrPut(allocator, slotOf(mesh, tri, material_count));
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
