const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const primitives = @import("primitives.zig");
const step = @import("../exporters/3d/step.zig");
const stl = @import("../exporters/3d/stl.zig");
const dag = @import("../vm/dag.zig");
const io_mod = @import("io.zig");
const chunk = @import("../vm/chunk.zig");
const methods = @import("methods.zig");
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
    .{ .name = "puts", .func = io_mod.nativePuts, .category = .io },
    .{ .name = "print", .func = io_mod.nativePrint, .category = .io },
    .{ .name = "p", .func = io_mod.nativeP, .category = .io },
    .{ .name = "debugger", .func = debug_mod.nativeDebugger, .category = .io },
    .{ .name = "cube", .func = primitives.nativeCube, .category = .primitive_3d },
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
    func: MeshMethodFn,
};

pub const mesh_methods = [_]MeshMethod{
    .{ .name = "translate", .category = .transform, .func = methods.meshTranslate },
    .{ .name = "rotate", .category = .transform, .func = methods.meshMockTransform },
    .{ .name = "chamfer", .category = .transform, .func = methods.meshMockTransform },
    .{ .name = "on_face", .category = .workplane_method, .func = methods.meshOnFace },
    .{ .name = "bbox", .category = .inspection_method, .func = methods.meshBBox },
    .{ .name = "volume", .category = .inspection_method, .func = methods.meshBBox },
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

// The O(1) Dynamic Dispatcher
pub fn cadInvokeHandler(vm: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (!receiver.isGeometry()) {
        vm.reportError("Runtime Error: Methods can only be called on Geometry objects.\n", .{});
        return error.RuntimeError;
    }

    if (method_map.get(method_name)) |method_func| {
        return method_func(vm, receiver, arg_count, args);
    }

    vm.reportError("Runtime Error: Unknown method '{s}' on Geometry object.\n", .{method_name});
    return error.RuntimeError;
}

pub fn cadBinaryHandler(vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value {
    if (!a.isGeometry() or !b.isGeometry()) {
        vm.reportError("Runtime Error: Invalid operands for CSG operation\n", .{});
        return error.RuntimeError;
    }

    const geom_a = a.asGeometry();
    const geom_b = b.asGeometry();

    const dag_tag: dag.DAGTag = switch (op) {
        .op_add => .union_op,
        .op_subtract => .difference_op,
        // .op_bitwise_and => .intersection_op,
        else => return error.RuntimeError,
    };

    const result_idx = try vm.dag_builder.addBinary(dag_tag, geom_a.dag_idx, geom_b.dag_idx);

    // Defer to VM ARC allocator
    return try vm.allocateGeometry(.{ .symbolic = result_idx });
}
