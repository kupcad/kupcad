//! `MeshPart`: a part as the 3D writers that keep parts apart take it (glTF, OBJ): the
//! kernel's handle of its shape, borrowed, and the name a viewer shows it by.

const geom = @import("../../core/geometry_handle.zig");

pub const MeshPart = struct {
    handle: geom.GeometryHandle,
    /// Null for a ghost, which the viewer shows unnamed.
    name: ?[]const u8 = null,
};
