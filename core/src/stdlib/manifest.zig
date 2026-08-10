const std = @import("std");
const value = @import("../core/value.zig");
const primitives = @import("primitives.zig");
const step = @import("step.zig");
const export_ops = @import("export.zig");

pub const Category = enum {
    primitive_3d,
    primitive_2d,
    transform,
    csg_operator,
    workplane_method,
    inspection_method,
    export_op,
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
    .{ .name = "export_stl", .func = export_ops.nativeExportStl, .category = .export_op },
    .{ .name = "import_step", .func = step.nativeImportStep, .category = .brep_op },
    .{ .name = "export_step", .func = step.nativeExportStep, .category = .brep_op },
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
