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

/// What a built-in gives back, for tools that read a script before it runs: the editor's
/// type hints and the lint's shape tracking (tools/lint/shapes.zig) both read it here.
pub const Result = enum {
    /// The receiver's kind: a Solid's `translate` is a Solid, a Sketch's a Sketch.
    receiver,
    solid,
    sketch,
    number,
    boolean,
    bounding_box,
    array,
    workplane,
    assembly,
    /// nil
    nothing,
    /// Whatever its block or arguments give (`inspect`, `benchmark { }`, `param`).
    varies,

    /// The class a script sees (`.class`), when it is always the same one.
    pub fn className(self: Result) ?[]const u8 {
        return switch (self) {
            .solid => "Geometry",
            .sketch => "CrossSection",
            .number => "Number",
            .boolean => "Boolean",
            .bounding_box => "BoundingBox",
            .array => "Array",
            .workplane => "Workplane",
            .assembly => "Assembly",
            .nothing => "NilClass",
            .receiver, .varies => null,
        };
    }
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
    result: Result,
    /// A primitive's parameters, for tools that read calls before they run.
    signature: ?*const Signature = null,
};

pub const MeshMethod = struct {
    name: []const u8,
    category: Category,
    func: value.NativeFn,
    /// What it takes (stdlib/method_signatures.zig), for its parameter hints and lint.
    signature: *const Signature,
    result: Result,
};

pub const core_namespaces = [_][]const u8{
    "Object",   "Array",        "String", "Map",      "Number",      "Range",  "Symbol",   "Boolean",
    "Geometry", "CrossSection", "Solid",  "Sketch2D", "BoundingBox", "Math",   "GC",       "Kernel",
    "CAD",      "NilClass",     "Proc",   "Method",   "Class",       "Module", "Assembly",
    // "Workplane": hidden with on_face (see the method table)
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
    .{ .name = "puts", .func = common.wrapGlobal(io_mod.nativePuts), .category = .io, .result = .nothing },
    .{ .name = "print", .func = common.wrapGlobal(io_mod.nativePrint), .category = .io, .result = .nothing },
    .{ .name = "inspect", .func = common.wrapGlobal(io_mod.nativeInspect), .category = .io, .result = .varies },
    .{ .name = "debugger", .func = common.wrapGlobal(debug_mod.nativeDebugger), .category = .io, .result = .nothing },
    .{ .name = "param", .func = common.wrapGlobal(params_mod.nativeParam), .category = .io, .result = .varies },
    .{ .name = "assert", .func = common.wrapGlobal(diagnostics_mod.nativeAssert), .category = .io, .result = .nothing },
    .{ .name = "warn", .func = common.wrapGlobal(diagnostics_mod.nativeWarn), .category = .io, .result = .nothing },
    .{ .name = "benchmark", .func = common.wrapGlobal(diagnostics_mod.nativeBenchmark), .category = .io, .result = .varies },
    .{ .name = "assemble", .func = common.wrapGlobal(assembly_mod.nativeAssemble), .category = .brep_op, .result = .assembly },
    .{ .name = "union", .func = common.wrapGlobal(assembly_mod.nativeUnion), .category = .csg_operator, .result = .solid },
    .{ .name = "batch_hull", .func = common.wrapGlobal(assembly_mod.nativeBatchHull), .category = .csg_operator, .result = .solid },
    .{ .name = "highlight", .func = common.wrapGlobal(methods.globalHighlight), .category = .transform, .result = .solid },
    .{ .name = "ghost", .func = common.wrapGlobal(methods.globalGhost), .category = .transform, .result = .nothing },
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
    .{ .name = "import_stl", .func = common.wrapGlobal(stl.nativeImportStl), .category = .file_io, .result = .solid },
    .{ .name = "import_step", .func = common.wrapGlobal(step.nativeImportStep), .category = .file_io, .result = .solid },
};

pub const mesh_methods = [_]MeshMethod{
    method("union", .csg_operator, methods.meshUnion, &sig.SHAPES, .receiver),
    method("difference", .csg_operator, methods.meshDifference, &sig.SHAPES, .receiver),
    method("intersection", .csg_operator, methods.meshIntersection, &sig.SHAPES, .receiver),
    method("translate", .transform, methods.meshTranslate, &sig.TRANSLATE, .receiver),
    method("rotate", .transform, methods.meshRotate, &sig.ROTATE, .receiver),
    method("scale", .transform, methods.meshScale, &sig.SCALE, .receiver),
    method("resize", .transform, methods.meshResize, &sig.RESIZE, .receiver),
    method("project", .transform, methods.meshProject, &sig.PROJECT, .sketch),
    method("slice", .transform, methods.meshSlice, &sig.SLICE, .sketch),
    method("center", .transform, methods.meshCenter, &sig.CENTER, .receiver),
    method("align", .transform, methods.meshAlign, &sig.ALIGN, .receiver),
    method("mirror", .transform, methods.meshMirror, &sig.MIRROR, .receiver),
    // `on_face` returns a Workplane, a value with no methods yet: hidden until the fluent
    // sketching API it belongs to exists (CadQuery's Workplane does the local-coordinate
    // sketching and extrusion; a bare one misleads). The implementation stays.
    // method("on_face", .workplane_method, methods.meshOnFace, &sig.ON_FACE, .workplane),
    method("split_by_plane", .transform, methods.meshSplitByPlane, &sig.SPLIT_BY_PLANE, .array),
    method("decompose", .transform, methods.meshDecompose, &sig.NONE, .array),
    method("genus", .inspection_method, methods.meshGenus, &sig.NONE, .number),
    method("simplify", .transform, methods.meshSimplify, &sig.SIMPLIFY, .receiver),
    method("bbox", .inspection_method, methods.meshBBox, &sig.NONE, .bounding_box),
    method("volume", .inspection_method, methods.meshVolume, &sig.NONE, .number),
    method("surface_area", .inspection_method, methods.meshSurfaceArea, &sig.NONE, .number),
    method("extrude", .transform, methods.meshExtrude, &sig.EXTRUDE, .solid),
    method("revolve", .transform, methods.meshRevolve, &sig.REVOLVE, .solid),
    method("hull", .transform, methods.meshHull, &sig.SHAPES, .solid),
    method("helix", .transform, methods.meshHelix, &sig.HELIX, .solid),
    method("loft", .transform, methods.meshLoft, &sig.LOFT, .solid),
    method("fillet_edges", .transform, methods.meshFilletEdges, &sig.FILLET_EDGES, .receiver),
    method("trim_by_plane", .transform, methods.meshTrimByPlane, &sig.TRIM_BY_PLANE, .receiver),
    method("minkowski", .transform, methods.meshMinkowski, &sig.MINKOWSKI, .receiver),
    method("offset", .transform, methods.meshOffset, &sig.OFFSET, .sketch),
    method("transform", .transform, methods.meshTransform, &sig.TRANSFORM, .receiver),
    method("min_gap", .inspection_method, methods.meshMinGap, &sig.MIN_GAP, .number),
    method("contains?", .inspection_method, methods.meshContains, &sig.CONTAINS, .boolean),
    method("ray_cast", .inspection_method, methods.meshRayCast, &sig.RAY_CAST, .array),
    method("repeat_linear", .transform, methods.meshRepeatLinear, &sig.REPEAT_LINEAR, .receiver),
    method("repeat_polar", .transform, methods.meshRepeatPolar, &sig.REPEAT_POLAR, .receiver),
    method("material", .transform, methods.meshMaterial, &sig.MATERIAL, .receiver),
    method("highlight", .transform, methods.meshHighlight, &sig.NONE, .receiver),
    method("ghost", .transform, methods.meshGhost, &sig.NONE, .nothing),
    method("export_stl", .file_io, stl.meshExportStl, &sig.EXPORT, .receiver),
    method("export_step", .file_io, step.meshExportStep, &sig.EXPORT, .receiver),
    method("export_gltf", .file_io, gltf.meshExportGltf, &sig.EXPORT_GLTF, .receiver),
};

/// A primitive whose calls are checked against `signature` (common.checkArguments).
fn primitive(comptime name: []const u8, comptime category: Category, comptime func: anytype, comptime signature: *const Signature) GlobalFunction {
    const result: Result = switch (category) {
        .primitive_3d => .solid,
        .primitive_2d => .sketch,
        else => @compileError("primitive " ++ name ++ " makes neither a solid nor a sketch"),
    };
    return .{ .name = name, .func = common.wrapGlobalWith(func, signature.*), .category = category, .result = result, .signature = signature };
}

/// A method whose calls are checked against `signature` (common.checkArguments).
fn method(comptime name: []const u8, comptime category: Category, comptime func: anytype, comptime signature: *const Signature, comptime result: Result) MeshMethod {
    return .{ .name = name, .category = category, .func = common.wrapMethodWith(func, signature.*), .signature = signature, .result = result };
}

/// The signature of the global function `name`, if it is a primitive that declares one.
pub fn signatureOf(name: []const u8) ?*const Signature {
    for (global_functions) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.signature;
    }
    return null;
}

/// What the global function `name` gives back, if it is a built-in.
pub fn resultOf(name: []const u8) ?Result {
    for (global_functions) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.result;
    }
    return null;
}

/// What the method `name` of a solid or a sketch gives back.
pub fn methodResultOf(name: []const u8) ?Result {
    for (mesh_methods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.result;
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
