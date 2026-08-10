const std = @import("std");
const value = @import("../core/value.zig");
const primitives = @import("primitives.zig");
const step = @import("step.zig");
const stl = @import("stl.zig");

pub const Category = enum {
    primitive_3d,
    primitive_2d,
    transform,
    csg_operator,
    workplane_method,
    inspection_method,
    file_io,
    brep_op,
};

pub const GlobalFunction = struct {
    name: []const u8,
    func: value.NativeFn,
    category: Category,
};

// Single Source of Truth for Global Functions
pub const global_functions = [_]GlobalFunction{
    .{ .name = "cube", .func = primitives.nativeCube, .category = .primitive_3d },

    // STL I/O
    .{ .name = "import_stl", .func = stl.nativeImportStl, .category = .file_io },
    .{ .name = "export_stl", .func = stl.nativeExportStl, .category = .file_io },

    // STEP I/O
    .{ .name = "import_step", .func = step.nativeImportStep, .category = .file_io },
    .{ .name = "export_step", .func = step.nativeExportStep, .category = .file_io },
};

pub const MeshMethod = struct {
    name: []const u8,
    category: Category,
};

// Single Source of Truth for Mesh Object Methods
pub const mesh_methods = [_]MeshMethod{
    .{ .name = "translate", .category = .transform },
    .{ .name = "rotate", .category = .transform },
    .{ .name = "chamfer", .category = .transform },
};
