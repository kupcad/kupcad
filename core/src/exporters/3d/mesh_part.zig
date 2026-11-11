//! `MeshPart`: a part as the 3D writers that keep parts apart take it (glTF, OBJ): the
//! kernel's handle of its shape, borrowed, and the name a viewer shows it by. And
//! `floatMesh`, the mesh each writer of 32-bit floats (STL, 3MF, OBJ, glTF) writes.

const std = @import("std");
const geom = @import("../../core/geometry_handle.zig");
const kernel = @import("../../kernel/kernel.zig");

/// The largest coordinate a 32-bit float holds, in millimetres: past it a file says `inf`.
pub const MAX_FLOAT_COORDINATE: f64 = std.math.floatMax(f32);

pub const MeshPart = struct {
    handle: geom.GeometryHandle,
    /// Null for a ghost, which the viewer shows unnamed.
    name: ?[]const u8 = null,
    /// The part's preview mesh may stand in for its mesh (a viewer's picture, not a file).
    preview: bool = false,
};

/// The kernel's mesh of `handle`, owned by `allocator`, its positions the 32-bit floats a
/// file writes: error.BeyondFloatRange for one that reaches past MAX_FLOAT_COORDINATE, which
/// they can't hold (`cube(1e39)` was written as `inf`, a file no reader takes back, KupCAD's
/// own import_3mf neither).
pub fn floatMesh(allocator: std.mem.Allocator, handle: geom.GeometryHandle, preview: bool) error{ MeshExtractionFailed, BeyondFloatRange }!geom.Mesh {
    const mesh = (if (preview) kernel.getPreviewMesh(allocator, handle) else kernel.getMesh(allocator, handle)) orelse return error.MeshExtractionFailed;
    var v: usize = 0;
    while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
        for (mesh.vert_props[v..][0..3]) |c| if (!std.math.isFinite(c)) {
            allocator.free(mesh.vert_props);
            allocator.free(mesh.tri_verts);
            return error.BeyondFloatRange;
        };
    }
    return mesh;
}
