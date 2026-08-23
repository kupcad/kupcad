const std = @import("std");
const common = @import("classes/common.zig");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const primitives = @import("primitives.zig");
const step = @import("../exporters/3d/step.zig");
const stl = @import("../exporters/3d/stl.zig");
const dag = @import("../vm/dag.zig");
const io_mod = @import("io.zig");
const chunk = @import("../vm/chunk.zig");
const methods = @import("methods.zig");
const params_mod = @import("params.zig");
const debug_mod = @import("debug.zig");

pub const Category = enum {
    primitive_3d,
    primitive_2d,
    transform,
    csg_operator,
    workplane_method,
    inspection_method,
    file_io,
    io,
    brep_op,
};

pub const GlobalFunction = struct {
    name: []const u8,
    func: value.NativeFn,
    category: Category,
};

pub const global_functions = [_]GlobalFunction{
    // debug methods
    .{ .name = "puts", .func = common.wrapGlobal(io_mod.nativePuts), .category = .io },
    .{ .name = "print", .func = common.wrapGlobal(io_mod.nativePrint), .category = .io },
    .{ .name = "inspect", .func = common.wrapGlobal(io_mod.nativeInspect), .category = .io },
    .{ .name = "debugger", .func = common.wrapGlobal(debug_mod.nativeDebugger), .category = .io },
    .{ .name = "param", .func = params_mod.nativeParam, .category = .io },
    .{ .name = "cube", .func = common.wrapGlobal(primitives.nativeCube), .category = .primitive_3d },
    .{ .name = "cylinder", .func = common.wrapGlobal(primitives.nativeCylinder), .category = .primitive_3d },
    .{ .name = "sphere", .func = common.wrapGlobal(primitives.nativeSphere), .category = .primitive_3d },
    .{ .name = "square", .func = common.wrapGlobal(primitives.nativeSquare), .category = .primitive_2d },
    .{ .name = "circle", .func = common.wrapGlobal(primitives.nativeCircle), .category = .primitive_2d },
    .{ .name = "polygon", .func = common.wrapGlobal(primitives.nativePolygon), .category = .primitive_2d },
    .{ .name = "polyhedron", .func = common.wrapGlobal(primitives.nativePolyhedron), .category = .primitive_3d },
    .{ .name = "text", .func = common.wrapGlobal(primitives.nativeText), .category = .primitive_2d },
    .{ .name = "import_stl", .func = stl.nativeImportStl, .category = .file_io },
    .{ .name = "export_stl", .func = stl.nativeExportStl, .category = .file_io },
    .{ .name = "import_step", .func = step.nativeImportStep, .category = .file_io },
    .{ .name = "export_step", .func = step.nativeExportStep, .category = .file_io },
};

// Strongly typed function pointer for Mesh methods
pub const MeshMethodFn = *const fn (vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value;

pub const MeshMethod = struct {
    name: []const u8,
    category: Category,
    func: value.NativeFn,
};

pub const mesh_methods = [_]MeshMethod{
    .{ .name = "union", .category = .csg_operator, .func = common.wrapMethod(methods.meshUnion) },
    .{ .name = "difference", .category = .csg_operator, .func = common.wrapMethod(methods.meshDifference) },
    .{ .name = "intersection", .category = .csg_operator, .func = common.wrapMethod(methods.meshIntersection) },
    .{ .name = "translate", .category = .transform, .func = common.wrapMethod(methods.meshTranslate) },
    .{ .name = "rotate", .category = .transform, .func = common.wrapMethod(methods.meshRotate) },
    .{ .name = "scale", .category = .transform, .func = common.wrapMethod(methods.meshScale) },
    .{ .name = "on_face", .category = .workplane_method, .func = common.wrapMethod(methods.meshOnFace) },
    .{ .name = "bbox", .category = .inspection_method, .func = common.wrapMethod(methods.meshBBox) },
    .{ .name = "volume", .category = .inspection_method, .func = common.wrapMethod(methods.meshVolume) },
    .{ .name = "surface_area", .category = .inspection_method, .func = common.wrapMethod(methods.meshSurfaceArea) },
    .{ .name = "extrude", .category = .transform, .func = common.wrapMethod(methods.meshExtrude) },
    .{ .name = "revolve", .category = .transform, .func = common.wrapMethod(methods.meshRevolve) },
    .{ .name = "hull", .category = .transform, .func = common.wrapMethod(methods.meshHull) },
    .{ .name = "trim_by_plane", .category = .transform, .func = common.wrapMethod(methods.meshTrimByPlane) },
    .{ .name = "minkowski", .category = .transform, .func = common.wrapMethod(methods.meshMinkowski) },
    .{ .name = "offset", .category = .transform, .func = common.wrapMethod(methods.meshOffset) },
    .{ .name = "transform", .category = .transform, .func = common.wrapMethod(methods.meshTransform) },
    .{ .name = "min_gap", .category = .inspection_method, .func = common.wrapMethod(methods.meshMinGap) },
    .{ .name = "contains?", .category = .inspection_method, .func = common.wrapMethod(methods.meshContains) },
    .{ .name = "ray_cast", .category = .inspection_method, .func = common.wrapMethod(methods.meshRayCast) },
};

// Compile-time generated O(1) jump table
pub const method_map = std.StaticStringMap(MeshMethodFn).initComptime(blk: {
    const num_methods = mesh_methods.len;
    var kvs: [num_methods]struct { []const u8, MeshMethodFn } = undefined;
    for (mesh_methods, 0..) |m, i| {
        kvs[i] = .{ m.name, m.func };
    }
    break :blk kvs;
});

// The O(1) Dynamic Dispatcher (Now acts only as a pure Host Fallback)
pub fn cadInvokeHandler(vm: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    _ = receiver;
    vm.reportError("Runtime Error: Unknown method '{s}'.\n", .{method_name});
    return error.RuntimeError;
}

pub fn cadBinaryHandler(vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value {
    const is_3d = a.isGeometry() and b.isGeometry();
    const is_2d = a.isCrossSection() and b.isCrossSection();

    if (!is_3d and !is_2d) {
        vm.reportError("Runtime Error: Invalid operands for CSG operation. Both must be 3D Geometries or 2D Profiles.\n", .{});
        return error.RuntimeError;
    }

    // Unified tag resolution
    const dag_tag: dag.DAGTag = switch (op) {
        .op_add => if (is_3d) .union_op else .cs_union_op,
        .op_subtract => if (is_3d) .difference_op else .cs_difference_op,
        .op_bitwise_and => if (is_3d) .intersection_op else .cs_intersection_op,
        else => return error.RuntimeError,
    };

    // Unified index extraction
    const idx_a = if (is_3d) a.asGeometry().dag_idx else a.asCrossSection().dag_idx;
    const idx_b = if (is_3d) b.asGeometry().dag_idx else b.asCrossSection().dag_idx;

    // Execute insertion once
    const result_idx = try vm.dag_builder.addBinary(dag_tag, idx_a, idx_b);

    if (is_3d) {
        return try vm.allocateGeometry(.{ .symbolic = result_idx });
    } else {
        return try vm.allocateCrossSection(result_idx);
    }
}
