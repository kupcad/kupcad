//! The model written as a file: `exportModelFromVm` in any format, a drawing of shapes
//! (`exportDrawing`, built by `drawingOf` from the kernel's outlines and the curves the
//! sketches define), the Solids in a 3D format (glTF's and OBJ's parts named as the parts
//! list names them, `namedParts`), each part on its own (`exportPartsFromVm`, `kupcad build
//! --split`) and an OBJ's material library. The writers take what this evaluates (kernel
//! handles, names, materials); the script's errors are raised here.

const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const geom = @import("../core/geometry_handle.zig");
const kernel = @import("../kernel/kernel.zig");
const HandleScope = @import("../vm/scope.zig").HandleScope;
const error_kind = @import("../vm/error_kind.zig");
const MaterialDef = @import("../core/material.zig").MaterialDef;
const sketch_curves = @import("2d/sketch_curves.zig");
const format_mod = @import("format.zig");
const ExportFormat = format_mod.ExportFormat;
const ExportOptions = format_mod.ExportOptions;
const model_mod = @import("model.zig");
const parts_mod = @import("parts.zig");
const stl_exporter = @import("3d/stl.zig");
const gltf_exporter = @import("3d/gltf.zig");
const step_exporter = @import("3d/step.zig");
const threemf_exporter = @import("3d/threemf.zig");
const obj_exporter = @import("3d/obj.zig");
const MeshPart = @import("3d/mesh_part.zig").MeshPart;
const svg_exporter = @import("2d/svg.zig");
const dxf_exporter = @import("2d/dxf.zig");
const drawing_mod = @import("2d/drawing.zig");
const curves_mod = @import("2d/curves.zig");
const log = std.log.scoped(.@"export");

/// The material library (`.mtl`) of the model: the script's materials, as an OBJ written
/// with `ExportOptions.mtl_name` refers to them.
pub fn exportMaterialLibrary(allocator: std.mem.Allocator, vm: *const VM) ![]u8 {
    return obj_exporter.buildMaterialLibrary(allocator, vm.materials.items);
}

/// Where an OBJ's material library goes: beside it, named after it (part.obj's is
/// part.mtl). Caller owns the result.
pub fn materialLibraryPath(allocator: std.mem.Allocator, obj_path: []const u8) ![]u8 {
    return allocator.print("{s}.mtl", .{obj_path[0 .. obj_path.len - std.fs.path.extension(obj_path).len]});
}

/// The model the script left (collectModel) in `format`, its ghosts (the display list)
/// beside it where the format shows them. A failure the script can read about (a model the
/// format can't hold, an engine that can't mesh, a failed union) is raised in the VM first,
/// so `vm.last_error` says what went wrong.
pub fn exportModelFromVm(
    allocator: std.mem.Allocator,
    vm: *VM,
    format: ExportFormat,
    options: ExportOptions,
) ![]const u8 {
    var model = try model_mod.collectModel(allocator, vm);
    defer model.deinit(allocator);
    try model_mod.requireExportable(vm, &model, format);
    return exportShapes(allocator, vm, format, options, .{
        .solids = model.solids.items,
        .sketches = model.sketches.items,
        .paths = model.paths.items,
        .ghosts = model.ghosts,
        .title = model.title,
    });
}

/// What an export writes: Solids (rooted by the caller) and the ghosts shown beside them,
/// which only glb and gltf hold, in a 3D format, `title` naming a 3MF model; Sketches,
/// Paths and the Solids projected onto XY in a 2D one.
pub const Shapes = struct {
    solids: []const value.Value = &.{},
    sketches: []const value.Value = &.{},
    paths: []const value.Value = &.{},
    ghosts: []const geom.GeometryHandle = &.{},
    title: ?[]const u8 = null,
};

/// `shapes` in `format`, as `options` say. error.NoGeometry when there is nothing to write
/// (no triangle, or no point), for the caller to say where it was going; what the format
/// can't hold (a Sketch in STL, a mesh in STEP) is raised in the VM.
pub fn exportShapes(allocator: std.mem.Allocator, vm: *VM, format: ExportFormat, options: ExportOptions, shapes: Shapes) ![]const u8 {
    return switch (format.dimension()) {
        .@"3d" => exportSolids(allocator, vm, format, options, shapes.solids, shapes.ghosts, shapes.title),
        .@"2d" => exportDrawing(allocator, vm, format, options, shapes.sketches, shapes.solids, shapes.paths),
    };
}

/// `sketches`, `solids` and `paths` (rooted by the caller) as a drawing in `format`
/// (drawingOf), written as `options` say.
fn exportDrawing(allocator: std.mem.Allocator, vm: *VM, format: ExportFormat, options: ExportOptions, sketches: []const value.Value, solids: []const value.Value, paths: []const value.Value) ![]const u8 {
    var drawing = try drawingOf(allocator, vm, sketches, solids, paths);
    defer drawing.deinit(allocator);
    if (drawing.bounds == null) return vm.fail(.GeometryError, "the model's shapes have no outline (empty sketches): nothing to draw as {s}", .{@tagName(format)});
    return switch (format) {
        .svg => svg_exporter.build(allocator, &drawing, options.stroke_width),
        .dxf => dxf_exporter.build(allocator, &drawing),
        .stl, .glb, .gltf, .step, .@"3mf", .obj => unreachable, // 3D: exportSolids
    };
}

/// The drawing of `sketches`, each with its name and colour (parts_mod.sketchLabel), of
/// `paths`, as they are (open, their arcs exact), and of `solids` projected onto the XY
/// plane (their silhouettes, as `project` gives them), each with its part's name and
/// colour. The outlines come from the kernel (feature `sketch_contours`), so a B-Rep sketch
/// raises what it can't do.
pub fn drawingOf(allocator: std.mem.Allocator, vm: *VM, sketches: []const value.Value, solids: []const value.Value, paths: []const value.Value) !drawing_mod.Drawing {
    var shapes: std.ArrayList(drawing_mod.Shape) = .empty;
    errdefer {
        for (shapes.items) |shape| shape.deinit(allocator);
        shapes.deinit(allocator);
    }
    try shapes.ensureTotalCapacity(allocator, sketches.len + solids.len + paths.len);
    for (sketches) |sketch| {
        const label = parts_mod.sketchLabel(vm, sketch);
        const name: ?[]u8 = if (label.name) |n| try allocator.dupe(u8, n) else null;
        shapes.appendAssumeCapacity(try shapeOf(allocator, vm, sketch, name, label.material));
    }
    for (paths) |path_val| shapes.appendAssumeCapacity(try pathShapeOf(allocator, vm, path_val));
    if (solids.len > 0) {
        const grouping = try parts_mod.group(vm, allocator, solids);
        defer grouping.deinit(allocator);
        var names = try parts_mod.CopyNames.init(allocator, &grouping);
        defer names.deinit(allocator);
        for (solids, grouping.copies) |solid, copy| {
            // The projection, rooted while its outlines are read; a scope, as an error
            // raised in it unwinds the stack
            var scope = HandleScope.init(vm);
            defer scope.deinit();
            const projected = try vm.allocateCrossSection(try vm.dag_builder.addProjectAsMade(solid.asGeometry().dag_idx));
            vm.push(projected);
            shapes.appendAssumeCapacity(try shapeOf(allocator, vm, projected, try names.next(allocator, copy), grouping.parts[copy.part].material));
        }
        log.info("projected {d} Solid{s} onto the XY plane for the drawing", .{ solids.len, if (solids.len == 1) "" else "s" });
    }
    const bounds = drawing_mod.Drawing.boundsOf(shapes.items);
    return .{ .shapes = try shapes.toOwnedSlice(allocator), .projected = solids.len, .bounds = bounds };
}

/// A Path as a shape of the drawing: one open outline of its segments, as they are.
fn pathShapeOf(allocator: std.mem.Allocator, vm: *const VM, path_val: value.Value) !drawing_mod.Shape {
    const p = path_val.asPath();
    const name: ?[]u8 = if (p.name) |n| try allocator.dupe(u8, n.chars) else null;
    errdefer if (name) |n| allocator.free(n);
    const outlines = try allocator.alloc(drawing_mod.Outline, 1);
    errdefer allocator.free(outlines);
    outlines[0] = .{ .start = p.start, .edges = try allocator.dupe(drawing_mod.Edge, p.segments), .closed = false };
    const material: ?MaterialDef = if (p.material_id) |id| (if (id < vm.materials.items.len) vm.materials.items[id] else null) else null;
    return .{ .name = name, .rgb = if (material) |m| m.rgb else null, .alpha = if (material) |m| m.alpha else 1.0, .tolerance = vm.config().tolerance, .outlines = outlines };
}

/// `sketch`'s outlines as a shape of the drawing, labelled `name` (owned by `allocator`;
/// the shape's from here on, freed on failure) and `material`: the kernel's contours, with
/// the chords of the curves the sketch's graph defines turned back into them.
fn shapeOf(allocator: std.mem.Allocator, vm: *VM, sketch: value.Value, name: ?[]const u8, material: ?MaterialDef) !drawing_mod.Shape {
    errdefer if (name) |n| allocator.free(n);
    const handle = try vm.ensureConcreteCrossSection(sketch);
    try vm.requireFeature(handle.engine, .sketch_contours);
    const contours = kernel.crossSectionContours(allocator, handle) orelse return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"the sketch's outlines"});
    defer contours.deinit(allocator);
    const node = sketch.asCrossSection().dag_idx;
    var curves = try sketch_curves.collect(allocator, &vm.dag_builder, node);
    defer curves.deinit(allocator);
    const tolerance = vm.settingsOf(sketch).tolerance;
    const outlines = try curves_mod.outlinesOf(allocator, contours, &curves, tolerance);
    return .{ .name = name, .rgb = if (material) |m| m.rgb else null, .alpha = if (material) |m| m.alpha else 1.0, .tolerance = tolerance, .outlines = outlines };
}

/// `solids` (rooted by the caller), with the meshes of `ghosts`, in `format`; `title` names
/// a 3MF model. error.NoGeometry when what is written has no triangle.
fn exportSolids(
    allocator: std.mem.Allocator,
    vm: *VM,
    format: ExportFormat,
    options: ExportOptions,
    solids: []const value.Value,
    ghosts: []const geom.GeometryHandle,
    title: ?[]const u8,
) ![]const u8 {
    switch (format) {
        // The parts once each, placed per copy: the Solids themselves, not their meshes. The
        // ghosts are the viewer's, as in an STL.
        .@"3mf" => return threemfOf(allocator, vm, solids, title),
        .obj => {
            var parts = try namedParts(allocator, vm, solids, &.{});
            defer parts.deinit();
            for (parts.items) |part| try vm.requireFeature(part.handle.engine, .mesh);
            return obj_exporter.build(allocator, parts.items, title, options.mtl_name);
        },
        .svg, .dxf => unreachable, // 2D: exportDrawing
        .step => {
            var handles = try model_mod.handlesOf(allocator, vm, solids, ghosts);
            defer handles.deinit(allocator);
            try requireExactParts(vm, handles.items);
            return step_exporter.buildStepBuffer(allocator, handles.items);
        },
        // STL holds one mesh: the model's parts are united, the ghosts left out.
        .stl => {
            var handles = try model_mod.handlesOf(allocator, vm, solids, &.{});
            defer handles.deinit(allocator);
            // Refuse parts the engine can't tessellate, or unite, before any work on them.
            for (handles.items) |h| try vm.requireFeature(h.engine, .mesh);
            if (handles.items.len > 1) try vm.requireFeature(handles.items[0].engine, .boolean);
            return stl_exporter.buildStlOfParts(allocator, handles.items) catch |err| switch (err) {
                error.UnionFailed => return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"union"}),
                else => return err,
            };
        },
        .glb, .gltf => {
            var parts = try namedParts(allocator, vm, solids, ghosts);
            defer parts.deinit();
            for (parts.items) |part| try vm.requireFeature(part.handle.engine, .mesh);
            const container: gltf_exporter.Container = if (format == .gltf) .gltf else .glb;
            return gltf_exporter.buildGltfBuffer(allocator, vm.materials.items, parts.items, if (options.draco) options.draco_bits else null, container);
        },
    }
}

/// Raises unless every part is exact (B-Rep) geometry, which is all STEP can hold. The
/// writer skipped mesh parts: a model with a Manifold part was written without it, and an
/// all-Manifold model failed with a bare NoGeometry.
fn requireExactParts(vm: *VM, handles: []const geom.GeometryHandle) error{RuntimeError}!void {
    for (handles, 1..) |h, n| {
        if (h.engine == .brep_native) continue;
        const fmt = "STEP export needs exact geometry, and {s} was built by the {s} engine (a mesh); build it with engine: :brep";
        if (handles.len == 1) {
            _ = vm.raiseError(.NotImplementedError, fmt, .{ "the model", h.engine.scriptName() });
        } else {
            var buf: [48]u8 = undefined;
            const which = std.mem.print(&buf, "part {d} of {d}", .{ n, handles.len }) catch "a part";
            _ = vm.raiseError(.NotImplementedError, fmt, .{ which, h.engine.scriptName() });
        }
        return error.RuntimeError;
    }
}

/// `solids` (rooted by the caller) as a 3MF package: each part of the parts list once, as
/// made (with its material, so its mesh has the colour the viewport shows), and a build
/// item per copy.
fn threemfOf(allocator: std.mem.Allocator, vm: *VM, solids: []const value.Value, title: ?[]const u8) ![]u8 {
    const grouping = try parts_mod.group(vm, allocator, solids);
    defer grouping.deinit(allocator);
    // The parts as made are new Solids: rooted, in one Array, until the package is written,
    // so their nodes (and the kernel's shapes the writer reads) outlive any collection
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const made = try scope.array();
    try made.items.ensureTotalCapacity(vm.gc.trackingAllocator(), grouping.parts.len);
    const parts = try allocator.alloc(MeshPart, grouping.parts.len);
    defer allocator.free(parts);
    for (grouping.parts, parts) |part, *mesh_part| {
        const shape = try parts_mod.madeOf(vm, part);
        made.items.appendAssumeCapacity(shape);
        const handle = try vm.ensureConcrete(shape);
        try vm.requireFeature(handle.engine, .mesh);
        mesh_part.* = .{ .handle = handle, .name = part.name };
    }
    const items = try allocator.alloc(threemf_exporter.Item, grouping.copies.len);
    defer allocator.free(items);
    for (grouping.copies, items) |copy, *item| item.* = .{ .part = copy.part, .placement = copy.placement };
    return threemf_exporter.build(allocator, parts, items, vm.materials.items, title);
}

/// The parts of a glTF or an OBJ: `ghosts`, unnamed, then `solids`, evaluated and named as
/// the parts list names their copies (parts_mod.CopyNames). Owned by `allocator`, the names
/// included; the handles are borrowed (see VM.ensureConcrete).
const NamedParts = struct {
    arena: std.heap.ArenaAllocator,
    items: []MeshPart,

    fn deinit(self: *NamedParts) void {
        self.arena.deinit();
    }
};

fn namedParts(allocator: std.mem.Allocator, vm: *VM, solids: []const value.Value, ghosts: []const geom.GeometryHandle) !NamedParts {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const items = try arena.allocator().alloc(MeshPart, ghosts.len + solids.len);
    for (ghosts, items[0..ghosts.len]) |ghost, *item| item.* = .{ .handle = ghost };
    const grouping = try parts_mod.group(vm, allocator, solids);
    defer grouping.deinit(allocator);
    var names = try parts_mod.CopyNames.init(allocator, &grouping);
    defer names.deinit(allocator);
    for (solids, grouping.copies, items[ghosts.len..]) |solid, copy, *item| {
        item.* = .{ .handle = try vm.ensureConcrete(solid), .name = try names.next(arena.allocator(), copy) };
    }
    return .{ .arena = arena, .items = items };
}

/// One file `kupcad build --split` writes: a part of the model, as made (no placement).
pub const PartFile = struct {
    /// The part's name (the geometry graph's), or null when it has none.
    name: ?[]const u8,
    /// What it is, for the name an unnamed one gets (parts_mod.fallbackName).
    kind: parts_mod.ShapeKind,
    /// How many copies of it the model holds.
    count: u32,
    /// Owned by the allocator `exportPartsFromVm` was given.
    bytes: []const u8,
};

/// Each part of the model's parts list (stdlib/parts.zig) in `format`, without its placement:
/// a file to print each from; in a 2D format, each Sketch of the model too, as a drawing of
/// its own (it was left out, and a 2D format crashed the split). Raises in the VM when the
/// format can't hold the model (requireExportable; a split has no ghosts to show).
pub fn exportPartsFromVm(allocator: std.mem.Allocator, vm: *VM, format: ExportFormat, options: ExportOptions) ![]PartFile {
    var model = try model_mod.collectModel(allocator, vm);
    defer model.deinit(allocator);
    model.ghosts = &.{};
    try model_mod.requireExportable(vm, &model, format);
    const grouping = try parts_mod.group(vm, allocator, model.solids.items);
    defer grouping.deinit(allocator);

    var files: std.ArrayList(PartFile) = .empty;
    errdefer freePartFiles(allocator, files.items);
    defer files.deinit(allocator);
    for (grouping.parts) |part| {
        // Rooted while it is evaluated and written; a scope, as an error raised in it
        // unwinds the stack
        var scope = HandleScope.init(vm);
        defer scope.deinit();
        const made = try parts_mod.madeOf(vm, part);
        vm.push(made);
        const bytes = try exportShapes(allocator, vm, format, options, .{ .solids = &.{made}, .title = part.name });
        errdefer allocator.free(bytes);
        try files.append(allocator, .{ .name = part.name, .kind = .part, .count = part.count, .bytes = bytes });
    }
    if (format.dimension() == .@"2d") {
        for (model.sketches.items) |sketch| {
            const bytes = try exportShapes(allocator, vm, format, options, .{ .sketches = &.{sketch} });
            errdefer allocator.free(bytes);
            try files.append(allocator, .{ .name = parts_mod.sketchLabel(vm, sketch).name, .kind = .part, .count = 1, .bytes = bytes });
        }
        for (model.paths.items) |path_val| {
            const bytes = try exportShapes(allocator, vm, format, options, .{ .paths = &.{path_val} });
            errdefer allocator.free(bytes);
            const name: ?[]const u8 = if (path_val.asPath().name) |n| n.chars else null;
            try files.append(allocator, .{ .name = name, .kind = .path, .count = 1, .bytes = bytes });
        }
    }
    return files.toOwnedSlice(allocator);
}

pub fn freePartFiles(allocator: std.mem.Allocator, files: []const PartFile) void {
    for (files) |file| allocator.free(file.bytes);
}
