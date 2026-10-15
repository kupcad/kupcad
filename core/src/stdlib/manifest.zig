const std = @import("std");
const common = @import("classes/common.zig");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const util = @import("methods/util.zig");
const primitives = @import("primitives.zig");
const Signature = @import("signature.zig").Signature;
const sig = @import("method_signatures.zig");
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
    /// A primitive's parameters, for tools that read calls before they run.
    signature: ?*const Signature = null,
};

pub const MeshMethod = struct {
    name: []const u8,
    category: Category,
    func: value.NativeFn,
    /// What it takes (stdlib/method_signatures.zig), for its parameter hints and lint.
    signature: *const Signature,
};

pub const core_namespaces = [_][]const u8{
    "Object",   "Array",        "String", "Map",      "Number",      "Range",  "Symbol",   "Boolean",
    "Geometry", "CrossSection", "Solid",  "Sketch2D", "BoundingBox", "Math",   "GC",       "Kernel",
    "CAD",      "NilClass",     "Proc",   "Method",   "Class",       "Module", "Assembly", "Workplane",
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
    .{ .name = "assemble", .func = common.wrapGlobal(assembly_mod.nativeAssemble), .category = .brep_op },
    .{ .name = "union", .func = common.wrapGlobal(assembly_mod.nativeUnion), .category = .csg_operator },
    .{ .name = "batch_hull", .func = common.wrapGlobal(assembly_mod.nativeBatchHull), .category = .csg_operator },
    .{ .name = "highlight", .func = common.wrapGlobal(methods.globalHighlight), .category = .transform },
    .{ .name = "ghost", .func = common.wrapGlobal(methods.globalGhost), .category = .transform },
    .{ .name = "cube", .func = common.wrapGlobal(primitives.nativeCube), .category = .primitive_3d, .signature = &primitives.CUBE },
    .{ .name = "cylinder", .func = common.wrapGlobal(primitives.nativeCylinder), .category = .primitive_3d, .signature = &primitives.CYLINDER },
    .{ .name = "sphere", .func = common.wrapGlobal(primitives.nativeSphere), .category = .primitive_3d, .signature = &primitives.SPHERE },
    .{ .name = "square", .func = common.wrapGlobal(primitives.nativeSquare), .category = .primitive_2d, .signature = &primitives.SQUARE },
    .{ .name = "circle", .func = common.wrapGlobal(primitives.nativeCircle), .category = .primitive_2d, .signature = &primitives.CIRCLE },
    .{ .name = "polygon", .func = common.wrapGlobal(primitives.nativePolygon), .category = .primitive_2d },
    .{ .name = "regular_polygon", .func = common.wrapGlobal(primitives.nativeRegularPolygon), .category = .primitive_2d, .signature = &primitives.REGULAR_POLYGON },
    .{ .name = "torus", .func = common.wrapGlobal(primitives.nativeTorus), .category = .primitive_3d, .signature = &primitives.TORUS },
    .{ .name = "polyhedron", .func = common.wrapGlobal(primitives.nativePolyhedron), .category = .primitive_3d },
    .{ .name = "text", .func = common.wrapGlobal(primitives.nativeText), .category = .primitive_2d, .signature = &primitives.TEXT },
    .{ .name = "import_stl", .func = common.wrapGlobal(stl.nativeImportStl), .category = .file_io },
    .{ .name = "import_step", .func = common.wrapGlobal(step.nativeImportStep), .category = .file_io },
};

pub const mesh_methods = [_]MeshMethod{
    .{ .name = "union", .category = .csg_operator, .func = common.wrapMethod(methods.meshUnion), .signature = &sig.SHAPES },
    .{ .name = "difference", .category = .csg_operator, .func = common.wrapMethod(methods.meshDifference), .signature = &sig.SHAPES },
    .{ .name = "intersection", .category = .csg_operator, .func = common.wrapMethod(methods.meshIntersection), .signature = &sig.SHAPES },
    .{ .name = "translate", .category = .transform, .func = common.wrapMethod(methods.meshTranslate), .signature = &sig.TRANSLATE },
    .{ .name = "rotate", .category = .transform, .func = common.wrapMethod(methods.meshRotate), .signature = &sig.ROTATE },
    .{ .name = "scale", .category = .transform, .func = common.wrapMethod(methods.meshScale), .signature = &sig.SCALE },
    .{ .name = "resize", .category = .transform, .func = common.wrapMethod(methods.meshResize), .signature = &sig.RESIZE },
    .{ .name = "project", .category = .transform, .func = common.wrapMethod(methods.meshProject), .signature = &sig.PROJECT },
    .{ .name = "slice", .category = .transform, .func = common.wrapMethod(methods.meshSlice), .signature = &sig.SLICE },
    .{ .name = "center", .category = .transform, .func = common.wrapMethod(methods.meshCenter), .signature = &sig.CENTER },
    .{ .name = "align", .category = .transform, .func = common.wrapMethod(methods.meshAlign), .signature = &sig.ALIGN },
    .{ .name = "mirror", .category = .transform, .func = common.wrapMethod(methods.meshMirror), .signature = &sig.MIRROR },
    .{ .name = "on_face", .category = .workplane_method, .func = common.wrapMethod(methods.meshOnFace), .signature = &sig.ON_FACE },
    .{ .name = "split_by_plane", .category = .transform, .func = common.wrapMethod(methods.meshSplitByPlane), .signature = &sig.SPLIT_BY_PLANE },
    .{ .name = "decompose", .category = .transform, .func = common.wrapMethod(methods.meshDecompose), .signature = &sig.NONE },
    .{ .name = "genus", .category = .inspection_method, .func = common.wrapMethod(methods.meshGenus), .signature = &sig.NONE },
    .{ .name = "simplify", .category = .transform, .func = common.wrapMethod(methods.meshSimplify), .signature = &sig.SIMPLIFY },
    .{ .name = "bbox", .category = .inspection_method, .func = common.wrapMethod(methods.meshBBox), .signature = &sig.NONE },
    .{ .name = "volume", .category = .inspection_method, .func = common.wrapMethod(methods.meshVolume), .signature = &sig.NONE },
    .{ .name = "surface_area", .category = .inspection_method, .func = common.wrapMethod(methods.meshSurfaceArea), .signature = &sig.NONE },
    .{ .name = "extrude", .category = .transform, .func = common.wrapMethod(methods.meshExtrude), .signature = &sig.EXTRUDE },
    .{ .name = "revolve", .category = .transform, .func = common.wrapMethod(methods.meshRevolve), .signature = &sig.REVOLVE },
    .{ .name = "hull", .category = .transform, .func = common.wrapMethod(methods.meshHull), .signature = &sig.SHAPES },
    .{ .name = "helix", .category = .transform, .func = common.wrapMethod(methods.meshHelix), .signature = &sig.HELIX },
    .{ .name = "loft", .category = .transform, .func = common.wrapMethod(methods.meshLoft), .signature = &sig.LOFT },
    .{ .name = "fillet_edges", .category = .transform, .func = common.wrapMethod(methods.meshFilletEdges), .signature = &sig.FILLET_EDGES },
    .{ .name = "trim_by_plane", .category = .transform, .func = common.wrapMethod(methods.meshTrimByPlane), .signature = &sig.TRIM_BY_PLANE },
    .{ .name = "minkowski", .category = .transform, .func = common.wrapMethod(methods.meshMinkowski), .signature = &sig.MINKOWSKI },
    .{ .name = "offset", .category = .transform, .func = common.wrapMethod(methods.meshOffset), .signature = &sig.OFFSET },
    .{ .name = "transform", .category = .transform, .func = common.wrapMethod(methods.meshTransform), .signature = &sig.TRANSFORM },
    .{ .name = "min_gap", .category = .inspection_method, .func = common.wrapMethod(methods.meshMinGap), .signature = &sig.MIN_GAP },
    .{ .name = "contains?", .category = .inspection_method, .func = common.wrapMethod(methods.meshContains), .signature = &sig.CONTAINS },
    .{ .name = "ray_cast", .category = .inspection_method, .func = common.wrapMethod(methods.meshRayCast), .signature = &sig.RAY_CAST },
    .{ .name = "repeat_linear", .category = .transform, .func = common.wrapMethod(methods.meshRepeatLinear), .signature = &sig.REPEAT_LINEAR },
    .{ .name = "repeat_polar", .category = .transform, .func = common.wrapMethod(methods.meshRepeatPolar), .signature = &sig.REPEAT_POLAR },
    .{ .name = "material", .category = .transform, .func = common.wrapMethod(methods.meshMaterial), .signature = &sig.MATERIAL },
    .{ .name = "highlight", .category = .transform, .func = common.wrapMethod(methods.meshHighlight), .signature = &sig.NONE },
    .{ .name = "ghost", .category = .transform, .func = common.wrapMethod(methods.meshGhost), .signature = &sig.NONE },
    .{ .name = "export_stl", .category = .file_io, .func = common.wrapMethod(stl.meshExportStl), .signature = &sig.EXPORT },
    .{ .name = "export_step", .category = .file_io, .func = common.wrapMethod(step.meshExportStep), .signature = &sig.EXPORT },
    .{ .name = "export_gltf", .category = .file_io, .func = common.wrapMethod(gltf.meshExportGltf), .signature = &sig.EXPORT_GLTF },
};

/// The category of the global function `name` (whether it makes a solid or a sketch, for
/// tools that read a script before it runs).
pub fn categoryOf(name: []const u8) ?Category {
    for (global_functions) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.category;
    }
    return null;
}

/// The signature of the global function `name`, if it is a primitive that declares one.
pub fn signatureOf(name: []const u8) ?*const Signature {
    for (global_functions) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.signature;
    }
    return null;
}

/// The signature of the method `name` of a solid or a sketch.
pub fn methodSignatureOf(name: []const u8) ?*const Signature {
    for (mesh_methods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.signature;
    }
    return null;
}

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

/// The host fallback for a method no class defines: every built-in method is bound on a
/// class, so this only reports it.
pub fn cadInvokeHandler(vm: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    return util.notDefinedFor(vm, method_name, receiver);
}

pub fn cadBinaryHandler(vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value {
    const is_3d = a.isGeometry() and b.isGeometry();
    const is_2d = a.isCrossSection() and b.isCrossSection();

    // The VM reports these as "'+' can't combine Array and nil".
    if (!is_3d and !is_2d) return error.UnsupportedOperands;

    const dag_tag: dag.DAGTag = switch (op) {
        .op_add => if (is_3d) .union_op else .cs_union_op,
        .op_subtract => if (is_3d) .difference_op else .cs_difference_op,
        .op_bitwise_and => if (is_3d) .intersection_op else .cs_intersection_op,
        else => return error.UnsupportedOperands,
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
