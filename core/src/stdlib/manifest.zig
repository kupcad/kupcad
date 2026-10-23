//! The table of built-ins: the global functions (`global_functions`) and the Solid, Sketch,
//! Path and assembly methods (`mesh_methods`, `path_methods`, `assembly_methods`), each with
//! its category, signature, result kind and the shapes it is bound for, from which the
//! compiler's intrinsics, the LSP's completions and the lint's lookups are derived
//! (`methodAllows`); why a Path lacks a method (`missingMethodHint`, core/path.zig's OPEN_PATH_HINT);
//! and `cadBinaryHandler`, which turns `+ - &` into booleans, `+` of two Paths into a
//! join and a String's `%` into a format.

const std = @import("std");
const common = @import("classes/common.zig");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const primitives = @import("primitives.zig");
const paths = @import("paths.zig");
const Signature = @import("signature.zig").Signature;
const sig = @import("method_signatures.zig");
const files = @import("files.zig");
const json = @import("json.zig");
const dag = @import("../vm/dag.zig");
const io_mod = @import("io.zig");
const chunk = @import("../vm/chunk.zig");
const methods = @import("methods.zig");
const assembly_mod = @import("assembly.zig");
const bom = @import("bom.zig");
const path_mod = @import("../core/path.zig");
const diagnostics_mod = @import("diagnostics.zig");
const params_mod = @import("params.zig");
const format = @import("format.zig");

pub const Category = enum {
    primitive_3d,
    primitive_2d,
    /// `line`, `polyline`, `arc`: makes a Path.
    primitive_path,
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
    path,
    number,
    boolean,
    string,
    bounding_box,
    array,
    workplane,
    assembly,
    font,
    /// nil
    nothing,
    /// Whatever its block or arguments give (`inspect`, `benchmark { }`, `param`).
    varies,

    /// The class a script sees (`.class`), when it is always the same one.
    pub fn className(self: Result) ?[]const u8 {
        return switch (self) {
            .solid => "Geometry",
            .sketch => "CrossSection",
            .path => "Path",
            .number => "Number",
            .boolean => "Boolean",
            .string => "String",
            .bounding_box => "BoundingBox",
            .array => "Array",
            .workplane => "Workplane",
            .assembly => "Assembly",
            .font => "Font",
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

/// Which shapes a method is defined on: `respond_to?` and a call on the other kind answer
/// as for any missing method (every method used to be bound to both, so a sketch said it
/// responded to `hull` and then raised a TypeError).
pub const On = enum { solids, sketches, both, paths };

pub const MeshMethod = struct {
    name: []const u8,
    category: Category,
    func: value.NativeFn,
    /// What it takes (stdlib/method_signatures.zig), for its parameter hints and lint.
    signature: *const Signature,
    result: Result,
    on: On,

    pub fn isOn(self: MeshMethod, on: On) bool {
        return self.on == on or (self.on == .both and on != .paths);
    }
};

pub const core_namespaces = [_][]const u8{
    "Object",   "Array",        "String", "Map",      "Number",      "Range",  "Symbol",   "Boolean",
    "Geometry", "CrossSection", "Solid",  "Sketch2D", "BoundingBox", "Math",   "GC",       "Kernel",
    "CAD",      "NilClass",     "Proc",   "Method",   "Class",       "Module", "Assembly", "JsonObject",
    "Font",     "Path",
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
    .{ .name = "debugger", .func = common.wrapGlobal(diagnostics_mod.nativeDebugger), .category = .io, .result = .nothing },
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
    primitive("line", .primitive_path, paths.nativeLine, &paths.LINE),
    primitive("polyline", .primitive_path, paths.nativePolyline, &paths.POLYLINE),
    primitive("arc", .primitive_path, paths.nativeArc, &paths.ARC),
    primitive("regular_polygon", .primitive_2d, primitives.nativeRegularPolygon, &primitives.REGULAR_POLYGON),
    primitive("torus", .primitive_3d, primitives.nativeTorus, &primitives.TORUS),
    primitive("polyhedron", .primitive_3d, primitives.nativePolyhedron, &primitives.POLYHEDRON),
    primitive("text", .primitive_2d, primitives.nativeText, &primitives.TEXT),
    .{ .name = "import_stl", .func = common.wrapGlobal(files.nativeImportStl), .category = .file_io, .result = .solid },
    .{ .name = "import_step", .func = common.wrapGlobal(files.nativeImportStep), .category = .file_io, .result = .solid },
    .{ .name = "import_json", .func = common.wrapGlobal(json.nativeImportJson), .category = .file_io, .result = .varies },
    .{ .name = "import_font", .func = common.wrapGlobal(files.nativeImportFont), .category = .file_io, .result = .font },
};

pub const mesh_methods = [_]MeshMethod{
    method("union", .csg_operator, methods.meshUnion, &sig.SHAPES, .receiver, .both),
    method("difference", .csg_operator, methods.meshDifference, &sig.SHAPES, .receiver, .both),
    method("intersection", .csg_operator, methods.meshIntersection, &sig.SHAPES, .receiver, .both),
    method("translate", .transform, methods.meshTranslate, &sig.TRANSLATE, .receiver, .both),
    method("rotate", .transform, methods.meshRotate, &sig.ROTATE, .receiver, .both),
    method("scale", .transform, methods.meshScale, &sig.SCALE, .receiver, .both),
    method("resize", .transform, methods.meshResize, &sig.RESIZE, .receiver, .solids),
    method("project", .transform, methods.meshProject, &sig.PROJECT, .sketch, .solids),
    method("slice", .transform, methods.meshSlice, &sig.SLICE, .sketch, .solids),
    method("center", .transform, methods.meshCenter, &sig.CENTER, .receiver, .both),
    method("align", .transform, methods.meshAlign, &sig.ALIGN, .receiver, .both),
    method("mirror", .transform, methods.meshMirror, &sig.MIRROR, .receiver, .both),
    // `on_face` returns a Workplane, a value with no methods yet: hidden until the fluent
    // sketching API it belongs to exists (CadQuery's Workplane does the local-coordinate
    // sketching and extrusion; a bare one misleads). The implementation stays.
    // method("on_face", .workplane_method, methods.meshOnFace, &sig.ON_FACE, .workplane, .solids),
    method("split_by_plane", .transform, methods.meshSplitByPlane, &sig.SPLIT_BY_PLANE, .array, .solids),
    method("decompose", .transform, methods.meshDecompose, &sig.NONE, .array, .solids),
    method("genus", .inspection_method, methods.meshGenus, &sig.NONE, .number, .solids),
    method("simplify", .transform, methods.meshSimplify, &sig.SIMPLIFY, .receiver, .solids),
    method("bbox", .inspection_method, methods.meshBBox, &sig.NONE, .bounding_box, .both),
    method("volume", .inspection_method, methods.meshVolume, &sig.NONE, .number, .solids),
    method("surface_area", .inspection_method, methods.meshSurfaceArea, &sig.NONE, .number, .solids),
    method("extrude", .transform, methods.meshExtrude, &sig.EXTRUDE, .solid, .sketches),
    method("revolve", .transform, methods.meshRevolve, &sig.REVOLVE, .solid, .sketches),
    method("hull", .transform, methods.meshHull, &sig.SHAPES, .solid, .solids),
    method("helix", .transform, methods.meshHelix, &sig.HELIX, .solid, .sketches),
    method("loft", .transform, methods.meshLoft, &sig.LOFT, .solid, .sketches),
    method("trim_by_plane", .transform, methods.meshTrimByPlane, &sig.TRIM_BY_PLANE, .receiver, .solids),
    method("minkowski", .transform, methods.meshMinkowski, &sig.MINKOWSKI, .receiver, .solids),
    method("offset", .transform, methods.meshOffset, &sig.OFFSET, .receiver, .both),
    method("transform", .transform, methods.meshTransform, &sig.TRANSFORM, .receiver, .both),
    method("min_gap", .inspection_method, methods.meshMinGap, &sig.MIN_GAP, .number, .solids),
    method("contains?", .inspection_method, methods.meshContains, &sig.CONTAINS, .boolean, .both),
    method("ray_cast", .inspection_method, methods.meshRayCast, &sig.RAY_CAST, .array, .solids),
    method("repeat_linear", .transform, methods.meshRepeatLinear, &sig.REPEAT_LINEAR, .receiver, .solids),
    method("repeat_polar", .transform, methods.meshRepeatPolar, &sig.REPEAT_POLAR, .receiver, .solids),
    method("material", .transform, methods.meshMaterial, &sig.MATERIAL, .receiver, .both),
    method("named", .transform, bom.meshNamed, &sig.NAMED, .receiver, .both),
    method("bom", .inspection_method, bom.meshBom, &sig.NONE, .array, .solids),
    method("highlight", .transform, methods.meshHighlight, &sig.NONE, .receiver, .solids),
    method("ghost", .transform, methods.meshGhost, &sig.NONE, .receiver, .solids),
    method("export_stl", .file_io, files.meshExportStl, &sig.EXPORT, .receiver, .solids),
    method("export_step", .file_io, files.meshExportStep, &sig.EXPORT, .receiver, .solids),
    method("export_gltf", .file_io, files.meshExportGltf, &sig.EXPORT_GLTF, .receiver, .solids),
    method("export_3mf", .file_io, files.meshExport3mf, &sig.EXPORT, .receiver, .solids),
    method("export_obj", .file_io, files.meshExportObj, &sig.EXPORT_OBJ, .receiver, .solids),
    method("export_svg", .file_io, files.meshExportSvg, &sig.EXPORT, .receiver, .both),
    method("export_dxf", .file_io, files.meshExportDxf, &sig.EXPORT, .receiver, .both),
};

/// The methods of a Path (line, polyline, arc): open 2D geometry, moved as a Sketch is,
/// closed or stroked into one, labelled for a drawing, and drawn.
pub const path_methods = [_]MeshMethod{
    method("translate", .transform, paths.pathTranslate, &sig.TRANSLATE, .receiver, .paths),
    method("rotate", .transform, paths.pathRotate, &sig.ROTATE, .receiver, .paths),
    method("scale", .transform, paths.pathScale, &sig.SCALE, .receiver, .paths),
    method("mirror", .transform, paths.pathMirror, &sig.MIRROR, .receiver, .paths),
    method("close", .transform, paths.pathClose, &sig.NONE, .sketch, .paths),
    method("stroke", .transform, paths.pathStroke, &paths.STROKE, .sketch, .paths),
    method("named", .transform, paths.pathNamed, &sig.NAMED, .receiver, .paths),
    method("material", .transform, methods.meshMaterial, &sig.MATERIAL, .receiver, .paths),
    method("start", .inspection_method, paths.pathStart, &sig.NONE, .array, .paths),
    method("end", .inspection_method, paths.pathEnd, &sig.NONE, .array, .paths),
    method("length", .inspection_method, paths.pathLength, &sig.NONE, .number, .paths),
    method("export_svg", .file_io, files.meshExportSvg, &sig.EXPORT, .receiver, .paths),
    method("export_dxf", .file_io, files.meshExportDxf, &sig.EXPORT, .receiver, .paths),
};

/// The methods of an Assembly (assemble(name:, parts:)): it is a named group of Solids
/// for export, so it answers what it holds and writes its parts as one file. It had no
/// methods at all: `assemble(...).export_step(...)` was a NoMethodError.
pub const assembly_methods = [_]MeshMethod{
    method("name", .inspection_method, assembly_mod.assemblyName, &sig.NONE, .string, .solids),
    method("parts", .inspection_method, assembly_mod.assemblyParts, &sig.NONE, .array, .solids),
    method("bom", .inspection_method, bom.meshBom, &sig.NONE, .array, .solids),
    // Placing a whole subassembly: its bounds, and every part moved alike.
    method("bbox", .inspection_method, methods.meshBBox, &sig.NONE, .bounding_box, .both),
    method("center", .transform, methods.meshCenter, &sig.CENTER, .receiver, .both),
    method("translate", .transform, methods.meshTranslate, &sig.TRANSLATE, .receiver, .both),
    method("export_stl", .file_io, files.meshExportStl, &sig.EXPORT, .receiver, .solids),
    method("export_step", .file_io, files.meshExportStep, &sig.EXPORT, .receiver, .solids),
    method("export_gltf", .file_io, files.meshExportGltf, &sig.EXPORT_GLTF, .receiver, .solids),
    method("export_3mf", .file_io, files.meshExport3mf, &sig.EXPORT, .receiver, .solids),
    method("export_obj", .file_io, files.meshExportObj, &sig.EXPORT_OBJ, .receiver, .solids),
    method("export_svg", .file_io, files.meshExportSvg, &sig.EXPORT, .receiver, .both),
    method("export_dxf", .file_io, files.meshExportDxf, &sig.EXPORT, .receiver, .both),
};

/// A primitive whose calls are checked against `signature` (common.checkArguments).
fn primitive(comptime name: []const u8, comptime category: Category, comptime func: anytype, comptime signature: *const Signature) GlobalFunction {
    const result: Result = switch (category) {
        .primitive_3d => .solid,
        .primitive_2d => .sketch,
        .primitive_path => .path,
        else => @compileError("primitive " ++ name ++ " makes neither a solid, a sketch nor a path"),
    };
    return .{ .name = name, .func = common.wrapGlobalWith(func, signature.*), .category = category, .result = result, .signature = signature };
}

/// A method whose calls are checked against `signature` (common.checkArguments), defined
/// on the shapes `on` (an assembly's methods are bound to Assembly whatever it says).
fn method(comptime name: []const u8, comptime category: Category, comptime func: anytype, comptime signature: *const Signature, comptime result: Result, comptime on: On) MeshMethod {
    return .{ .name = name, .category = category, .func = common.wrapMethodWith(func, signature.*), .signature = signature, .result = result, .on = on };
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

/// What the method `name` of a solid, a sketch or an assembly gives back.
pub fn methodResultOf(name: []const u8) ?Result {
    return if (methodNamed(name)) |m| m.result else null;
}

/// The signature of the method `name` of a solid, a sketch or an assembly.
pub fn methodSignatureOf(name: []const u8) ?*const Signature {
    return if (methodNamed(name)) |m| m.signature else null;
}

/// What to do about a shape that lacks a method it is often asked for: a Path for
/// `extrude` or `revolve`, which need a closed shape.
/// Whether the shape method `name` is one of the shapes `on`'s (a Solid's `hull`, a
/// Sketch's `extrude`, a Path's `close`); null when no shape has a method of that name.
pub fn methodAllows(name: []const u8, on: On) ?bool {
    var known = false;
    for (&mesh_methods) |*m| {
        if (!std.mem.eql(u8, m.name, name)) continue;
        known = true;
        if (m.isOn(on)) return true;
    }
    for (&path_methods) |*m| {
        if (!std.mem.eql(u8, m.name, name)) continue;
        known = true;
        if (m.isOn(on)) return true;
    }
    return if (known) false else null;
}

/// Why `class` has no method `name`, when there is something to say: the VM adds it to
/// the NoMethodError and the lint to its finding.
pub fn missingMethodHint(class: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, class, "Path")) return null;
    for ([_][]const u8{ "extrude", "revolve", "helix", "loft", "hull", "offset" }) |needs_region| {
        if (std.mem.eql(u8, name, needs_region)) return path_mod.OPEN_PATH_HINT;
    }
    return null;
}

/// A shape method named `name`: a solid's or a sketch's, else an assembly's (the exports
/// they share are declared alike).
fn methodNamed(name: []const u8) ?*const MeshMethod {
    for (&mesh_methods) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    for (&assembly_methods) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    for (&path_methods) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
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
/// What the editor completes outside a call chain: the namespaces and the global functions.
/// A solid's methods are completed after a dot; offered here, each was a NameError.
fn buildLspCompletions() [core_namespaces.len + global_functions.len][]const u8 {
    var arr: [core_namespaces.len + global_functions.len][]const u8 = undefined;
    var idx: usize = 0;

    for (core_namespaces) |ns| {
        arr[idx] = ns;
        idx += 1;
    }
    for (global_functions) |gf| {
        arr[idx] = gf.name;
        idx += 1;
    }

    return arr;
}

pub const lsp_completions = buildLspCompletions();

/// The host's operators on what the VM doesn't combine itself: `+ - &` of two Solids or two
/// Sketches as their boolean, `+` of two Paths as their join, and a String `%` arguments as
/// a format (stdlib/format.zig); error.UnsupportedOperands for anything else.
pub fn cadBinaryHandler(vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value {
    // Two paths join where one ends and the next starts
    if (op == .op_add and a.isPath() and b.isPath()) return paths.join(vm, a, b);
    if (op == .op_modulo and a.isString()) return format.format(vm, a, b);
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
