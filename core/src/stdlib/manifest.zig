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
    primitive("cube", .primitive_3d, primitives.nativeCube, &primitives.CUBE),
    primitive("cylinder", .primitive_3d, primitives.nativeCylinder, &primitives.CYLINDER),
    primitive("sphere", .primitive_3d, primitives.nativeSphere, &primitives.SPHERE),
    primitive("square", .primitive_2d, primitives.nativeSquare, &primitives.SQUARE),
    primitive("circle", .primitive_2d, primitives.nativeCircle, &primitives.CIRCLE),
    primitive("polygon", .primitive_2d, primitives.nativePolygon, &primitives.POLYGON),
    primitive("regular_polygon", .primitive_2d, primitives.nativeRegularPolygon, &primitives.REGULAR_POLYGON),
    primitive("torus", .primitive_3d, primitives.nativeTorus, &primitives.TORUS),
    primitive("polyhedron", .primitive_3d, primitives.nativePolyhedron, &primitives.POLYHEDRON),
    primitive("text", .primitive_2d, primitives.nativeText, &primitives.TEXT),
    .{ .name = "import_stl", .func = common.wrapGlobal(stl.nativeImportStl), .category = .file_io },
    .{ .name = "import_step", .func = common.wrapGlobal(step.nativeImportStep), .category = .file_io },
};

pub const mesh_methods = [_]MeshMethod{
    method("union", .csg_operator, methods.meshUnion, &sig.SHAPES),
    method("difference", .csg_operator, methods.meshDifference, &sig.SHAPES),
    method("intersection", .csg_operator, methods.meshIntersection, &sig.SHAPES),
    method("translate", .transform, methods.meshTranslate, &sig.TRANSLATE),
    method("rotate", .transform, methods.meshRotate, &sig.ROTATE),
    method("scale", .transform, methods.meshScale, &sig.SCALE),
    method("resize", .transform, methods.meshResize, &sig.RESIZE),
    method("project", .transform, methods.meshProject, &sig.PROJECT),
    method("slice", .transform, methods.meshSlice, &sig.SLICE),
    method("center", .transform, methods.meshCenter, &sig.CENTER),
    method("align", .transform, methods.meshAlign, &sig.ALIGN),
    method("mirror", .transform, methods.meshMirror, &sig.MIRROR),
    method("on_face", .workplane_method, methods.meshOnFace, &sig.ON_FACE),
    method("split_by_plane", .transform, methods.meshSplitByPlane, &sig.SPLIT_BY_PLANE),
    method("decompose", .transform, methods.meshDecompose, &sig.NONE),
    method("genus", .inspection_method, methods.meshGenus, &sig.NONE),
    method("simplify", .transform, methods.meshSimplify, &sig.SIMPLIFY),
    method("bbox", .inspection_method, methods.meshBBox, &sig.NONE),
    method("volume", .inspection_method, methods.meshVolume, &sig.NONE),
    method("surface_area", .inspection_method, methods.meshSurfaceArea, &sig.NONE),
    method("extrude", .transform, methods.meshExtrude, &sig.EXTRUDE),
    method("revolve", .transform, methods.meshRevolve, &sig.REVOLVE),
    method("hull", .transform, methods.meshHull, &sig.SHAPES),
    method("helix", .transform, methods.meshHelix, &sig.HELIX),
    method("loft", .transform, methods.meshLoft, &sig.LOFT),
    method("fillet_edges", .transform, methods.meshFilletEdges, &sig.FILLET_EDGES),
    method("trim_by_plane", .transform, methods.meshTrimByPlane, &sig.TRIM_BY_PLANE),
    method("minkowski", .transform, methods.meshMinkowski, &sig.MINKOWSKI),
    method("offset", .transform, methods.meshOffset, &sig.OFFSET),
    method("transform", .transform, methods.meshTransform, &sig.TRANSFORM),
    method("min_gap", .inspection_method, methods.meshMinGap, &sig.MIN_GAP),
    method("contains?", .inspection_method, methods.meshContains, &sig.CONTAINS),
    method("ray_cast", .inspection_method, methods.meshRayCast, &sig.RAY_CAST),
    method("repeat_linear", .transform, methods.meshRepeatLinear, &sig.REPEAT_LINEAR),
    method("repeat_polar", .transform, methods.meshRepeatPolar, &sig.REPEAT_POLAR),
    method("material", .transform, methods.meshMaterial, &sig.MATERIAL),
    method("highlight", .transform, methods.meshHighlight, &sig.NONE),
    method("ghost", .transform, methods.meshGhost, &sig.NONE),
    method("export_stl", .file_io, stl.meshExportStl, &sig.EXPORT),
    method("export_step", .file_io, step.meshExportStep, &sig.EXPORT),
    method("export_gltf", .file_io, gltf.meshExportGltf, &sig.EXPORT_GLTF),
};

/// A primitive whose calls are checked against `signature` (common.checkArguments).
fn primitive(comptime name: []const u8, comptime category: Category, comptime func: anytype, comptime signature: *const Signature) GlobalFunction {
    return .{ .name = name, .func = common.wrapGlobalWith(func, signature.*), .category = category, .signature = signature };
}

/// A method whose calls are checked against `signature` (common.checkArguments).
fn method(comptime name: []const u8, comptime category: Category, comptime func: anytype, comptime signature: *const Signature) MeshMethod {
    return .{ .name = name, .category = category, .func = common.wrapMethodWith(func, signature.*), .signature = signature };
}

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
