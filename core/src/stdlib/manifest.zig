const std = @import("std");
const common = @import("classes/common.zig");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const primitives = @import("primitives.zig");
const step = @import("../exporters/3d/step.zig");
const stl = @import("../exporters/3d/stl.zig");
const gltf = @import("../exporters/3d/gltf.zig");
const dag = @import("../vm/dag.zig");
const io_mod = @import("io.zig");
const chunk = @import("../vm/chunk.zig");
const methods = @import("methods.zig");
const assembly_mod = @import("assembly.zig");
const diagnostics_mod = @import("diagnostics.zig");
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

pub const Intrinsic = enum {
    raise_err,
    block_given_chk,
    yield_call,
    defined_chk,
    protected_symbol,
};

pub const GlobalFunction = struct {
    name: []const u8,
    func: value.NativeFn,
    category: Category,
};

// Strongly typed function pointer for Mesh methods
pub const MeshMethodFn = *const fn (vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value;

pub const MeshMethod = struct {
    name: []const u8,
    category: Category,
    func: value.NativeFn,
};

pub const core_namespaces = [_][]const u8{
    "Object",   "Array",        "String", "Map",      "Number",      "Symbol", "Boolean",
    "Geometry", "CrossSection", "Solid",  "Sketch2D", "BoundingBox", "Math",   "GC",
    "Kernel",   "CAD",
};

// Core language keywords and intrinsic system states
pub const language_intrinsics = [_]struct { []const u8, Intrinsic }{
    .{ "raise", .raise_err },
    .{ "block_given?", .block_given_chk },
    .{ "yield", .yield_call },
    .{ "defined?", .defined_chk },
    .{ "params", .protected_symbol }, // CLI injection map
};

pub const global_functions = [_]GlobalFunction{
    // debug methods
    .{ .name = "puts", .func = common.wrapGlobal(io_mod.nativePuts), .category = .io },
    .{ .name = "print", .func = common.wrapGlobal(io_mod.nativePrint), .category = .io },
    .{ .name = "inspect", .func = common.wrapGlobal(io_mod.nativeInspect), .category = .io },
    .{ .name = "debugger", .func = common.wrapGlobal(debug_mod.nativeDebugger), .category = .io },
    .{ .name = "param", .func = common.wrapGlobal(params_mod.nativeParam), .category = .io },
    .{ .name = "assert", .func = common.wrapGlobal(diagnostics_mod.nativeAssert), .category = .io },
    .{ .name = "warn", .func = common.wrapGlobal(diagnostics_mod.nativeWarn), .category = .io },
    .{ .name = "benchmark", .func = common.wrapGlobal(diagnostics_mod.nativeBenchmark), .category = .io },
    .{ .name = "assemble", .func = assembly_mod.nativeAssemble, .category = .brep_op },
    .{ .name = "union", .func = assembly_mod.nativeUnion, .category = .csg_operator },
    .{ .name = "batch_hull", .func = assembly_mod.nativeBatchHull, .category = .csg_operator },
    .{ .name = "highlight", .func = methods.globalHighlight, .category = .transform },
    .{ .name = "ghost", .func = methods.globalGhost, .category = .transform },
    .{ .name = "cube", .func = common.wrapGlobal(primitives.nativeCube), .category = .primitive_3d },
    .{ .name = "cylinder", .func = common.wrapGlobal(primitives.nativeCylinder), .category = .primitive_3d },
    .{ .name = "sphere", .func = common.wrapGlobal(primitives.nativeSphere), .category = .primitive_3d },
    .{ .name = "square", .func = common.wrapGlobal(primitives.nativeSquare), .category = .primitive_2d },
    .{ .name = "circle", .func = common.wrapGlobal(primitives.nativeCircle), .category = .primitive_2d },
    .{ .name = "polygon", .func = common.wrapGlobal(primitives.nativePolygon), .category = .primitive_2d },
    .{ .name = "regular_polygon", .func = common.wrapGlobal(primitives.nativeRegularPolygon), .category = .primitive_2d },
    .{ .name = "torus", .func = common.wrapGlobal(primitives.nativeTorus), .category = .primitive_3d },
    .{ .name = "polyhedron", .func = common.wrapGlobal(primitives.nativePolyhedron), .category = .primitive_3d },
    .{ .name = "text", .func = common.wrapGlobal(primitives.nativeText), .category = .primitive_2d },
    .{ .name = "import_stl", .func = common.wrapGlobal(stl.nativeImportStl), .category = .file_io },
    .{ .name = "import_step", .func = common.wrapGlobal(step.nativeImportStep), .category = .file_io },
};

pub const mesh_methods = [_]MeshMethod{
    .{ .name = "union", .category = .csg_operator, .func = common.wrapMethod(methods.meshUnion) },
    .{ .name = "difference", .category = .csg_operator, .func = common.wrapMethod(methods.meshDifference) },
    .{ .name = "intersection", .category = .csg_operator, .func = common.wrapMethod(methods.meshIntersection) },
    .{ .name = "translate", .category = .transform, .func = common.wrapMethod(methods.meshTranslate) },
    .{ .name = "rotate", .category = .transform, .func = common.wrapMethod(methods.meshRotate) },
    .{ .name = "scale", .category = .transform, .func = common.wrapMethod(methods.meshScale) },
    .{ .name = "resize", .category = .transform, .func = common.wrapMethod(methods.meshResize) },
    .{ .name = "project", .category = .transform, .func = common.wrapMethod(methods.meshProject) },
    .{ .name = "slice", .category = .transform, .func = common.wrapMethod(methods.meshSlice) },
    .{ .name = "center", .category = .transform, .func = common.wrapMethod(methods.meshCenter) },
    .{ .name = "align", .category = .transform, .func = common.wrapMethod(methods.meshAlign) },
    .{ .name = "mirror", .category = .transform, .func = common.wrapMethod(methods.meshMirror) },
    .{ .name = "on_face", .category = .workplane_method, .func = common.wrapMethod(methods.meshOnFace) },
    .{ .name = "split_by_plane", .category = .transform, .func = common.wrapMethod(methods.meshSplitByPlane) },
    .{ .name = "decompose", .category = .transform, .func = common.wrapMethod(methods.meshDecompose) },
    .{ .name = "genus", .category = .inspection_method, .func = common.wrapMethod(methods.meshGenus) },
    .{ .name = "simplify", .category = .transform, .func = common.wrapMethod(methods.meshSimplify) },
    .{ .name = "bbox", .category = .inspection_method, .func = common.wrapMethod(methods.meshBBox) },
    .{ .name = "volume", .category = .inspection_method, .func = common.wrapMethod(methods.meshVolume) },
    .{ .name = "surface_area", .category = .inspection_method, .func = common.wrapMethod(methods.meshSurfaceArea) },
    .{ .name = "extrude", .category = .transform, .func = common.wrapMethod(methods.meshExtrude) },
    .{ .name = "revolve", .category = .transform, .func = common.wrapMethod(methods.meshRevolve) },
    .{ .name = "hull", .category = .transform, .func = common.wrapMethod(methods.meshHull) },
    .{ .name = "helix", .category = .transform, .func = common.wrapMethod(methods.meshHelix) },
    .{ .name = "loft", .category = .transform, .func = common.wrapMethod(methods.meshLoft) },
    .{ .name = "fillet_edges", .category = .transform, .func = common.wrapMethod(methods.meshFilletEdges) },
    .{ .name = "trim_by_plane", .category = .transform, .func = common.wrapMethod(methods.meshTrimByPlane) },
    .{ .name = "minkowski", .category = .transform, .func = common.wrapMethod(methods.meshMinkowski) },
    .{ .name = "offset", .category = .transform, .func = common.wrapMethod(methods.meshOffset) },
    .{ .name = "transform", .category = .transform, .func = common.wrapMethod(methods.meshTransform) },
    .{ .name = "min_gap", .category = .inspection_method, .func = common.wrapMethod(methods.meshMinGap) },
    .{ .name = "contains?", .category = .inspection_method, .func = common.wrapMethod(methods.meshContains) },
    .{ .name = "ray_cast", .category = .inspection_method, .func = common.wrapMethod(methods.meshRayCast) },
    .{ .name = "repeat_linear", .category = .transform, .func = common.wrapMethod(methods.meshRepeatLinear) },
    .{ .name = "repeat_polar", .category = .transform, .func = common.wrapMethod(methods.meshRepeatPolar) },
    .{ .name = "material", .category = .transform, .func = common.wrapMethod(methods.meshMaterial) },
    .{ .name = "highlight", .category = .transform, .func = common.wrapMethod(methods.meshHighlight) },
    .{ .name = "ghost", .category = .transform, .func = common.wrapMethod(methods.meshGhost) },
    .{ .name = "export_stl", .category = .file_io, .func = common.wrapMethod(stl.meshExportStl) },
    .{ .name = "export_step", .category = .file_io, .func = common.wrapMethod(step.meshExportStep) },
    .{ .name = "export_gltf", .category = .file_io, .func = common.wrapMethod(gltf.meshExportGltf) },
};

// --- 2. Comptime Map for Compiler Protection ---
fn buildCompilerIntrinsics() std.StaticStringMap(Intrinsic) {
    const total_len = language_intrinsics.len + core_namespaces.len + global_functions.len;
    var combined: [total_len]struct { []const u8, Intrinsic } = undefined;
    var idx = 0;

    for (language_intrinsics) |item| {
        combined[idx] = item;
        idx += 1;
    }
    for (core_namespaces) |ns| {
        combined[idx] = .{ ns, .protected_symbol };
        idx += 1;
    }
    for (global_functions) |gf| {
        combined[idx] = .{ gf.name, .protected_symbol };
        idx += 1;
    }

    return std.StaticStringMap(Intrinsic).initComptime(combined);
}

/// Prevents users from overriding core classes and CAD globals.
pub const compiler_intrinsics = buildCompilerIntrinsics();

/// A flat array of all valid standard library names, methods, and classes for LSP.
/// Automatically deduplicates overlapping names by leveraging the compiler_intrinsics map in O(N) time.
fn buildLspCompletions() [core_namespaces.len + global_functions.len + mesh_methods.len][]const u8 {
    var arr: [core_namespaces.len + global_functions.len + mesh_methods.len][]const u8 = undefined;
    var idx: usize = 0;

    for (core_namespaces) |ns| {
        arr[idx] = ns;
        idx += 1;
    }
    for (global_functions) |gf| {
        arr[idx] = gf.name;
        idx += 1;
    }
    for (mesh_methods) |mm| {
        arr[idx] = mm.name;
        idx += 1;
    }

    return arr;
}

pub const lsp_completions = buildLspCompletions();

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

    const dag_tag: dag.DAGTag = switch (op) {
        .op_add => if (is_3d) .union_op else .cs_union_op,
        .op_subtract => if (is_3d) .difference_op else .cs_difference_op,
        .op_bitwise_and => if (is_3d) .intersection_op else .cs_intersection_op,
        else => return error.RuntimeError,
    };

    const idx_a = if (is_3d) a.asGeometry().dag_idx else a.asCrossSection().dag_idx;
    const idx_b = if (is_3d) b.asGeometry().dag_idx else b.asCrossSection().dag_idx;

    const result_idx = try vm.dag_builder.addBinary(dag_tag, idx_a, idx_b);

    if (is_3d) {
        return try vm.allocateGeometry(.{ .symbolic = result_idx });
    } else {
        return try vm.allocateCrossSection(result_idx);
    }
}

// Build the Static Map at compile time
fn buildMeshMethodMap() std.StaticStringMap(value.NativeFn) {
    var kvs: [mesh_methods.len]struct { []const u8, value.NativeFn } = undefined;
    for (mesh_methods, 0..) |m, i| {
        kvs[i] = .{ m.name, m.func };
    }
    return std.StaticStringMap(value.NativeFn).initComptime(kvs);
}

pub const mesh_method_map = buildMeshMethodMap();

/// Get mesh method
pub fn getMeshMethod(name: []const u8) ?value.NativeFn {
    return mesh_method_map.get(name);
}
