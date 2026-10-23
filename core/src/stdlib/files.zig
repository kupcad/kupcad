//! The script's file methods: `export_stl`, `export_gltf`, `export_step`, `export_3mf` and
//! `export_obj` on a Solid or an Assembly, `export_svg` and `export_dxf` on any shape (a
//! drawing, through exporters/export.zig), and `import_stl` / `import_step` / `import_font`
//! (`import_json` is in json.zig). The formats themselves are in exporters/3d and
//! exporters/2d, which know nothing of scripts.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const geom = @import("../kernel/geometry_handle.zig");
const kernel = @import("../kernel/kernel.zig");
const util = @import("methods/util.zig");
const stl = @import("../exporters/3d/stl.zig");
const threemf = @import("../exporters/3d/threemf.zig");
const obj = @import("../exporters/3d/obj.zig");
const export_mod = @import("../exporters/export.zig");
const ExportFormat = @import("../exporters/format.zig").ExportFormat;
const step = @import("../exporters/3d/step.zig");
const gltf = @import("../exporters/3d/gltf.zig");
const text = @import("../core/text.zig");
const limits = @import("../core/limits.zig");
const HandleScope = @import("../vm/scope.zig").HandleScope;

/// Appends the evaluated parts of `receiver`, a Solid (itself) or an Assembly (its Solids),
/// to `out`; `method` names the export in the error for anything else. Handles are
/// borrowed from the VM.
pub fn receiverParts(vm: *VM, receiver: value.Value, comptime method: []const u8, out: *std.ArrayList(geom.GeometryHandle)) !void {
    if (receiver.isGeometry()) return out.append(vm.allocator, try vm.ensureConcrete(receiver));
    if (!receiver.isAssembly()) return util.notDefinedFor(vm, method, receiver);
    for (receiver.asAssembly().parts.items.items) |part| try out.append(vm.allocator, try vm.ensureConcrete(part));
}

/// The Solids of `receiver`, a Solid (itself) or an Assembly (its parts), appended to
/// `out`, and the Assembly's name; `method` names the export in the error for anything
/// else. For the exporters that take the parts list's view of a model (3MF, OBJ).
fn receiverSolids(vm: *VM, receiver: value.Value, comptime method: []const u8, out: *std.ArrayList(value.Value)) !?[]const u8 {
    if (receiver.isGeometry()) {
        try out.append(vm.allocator, receiver);
        return null;
    }
    if (!receiver.isAssembly()) return util.notDefinedFor(vm, method, receiver);
    const assembly = receiver.asAssembly();
    try out.appendSlice(vm.allocator, assembly.parts.items.items);
    return assembly.name.chars;
}

/// `solid.export_3mf(path)` and `assembly.export_3mf(path)`: each part once, placed once
/// per copy, with its name and colours, as `kupcad build -o part.3mf` writes it.
pub fn meshExport3mf(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    var solids: std.ArrayList(value.Value) = .empty;
    defer solids.deinit(vm.allocator);
    const title = try receiverSolids(vm, receiver, "export_3mf", &solids);
    const bytes = threemf.build(vm.allocator, vm, solids.items, title) catch |err| switch (err) {
        error.NoGeometry => return vm.fail(.GeometryError, "export_3mf: the model is empty, there is nothing to write to '{s}'", .{filepath}),
        else => return err,
    };
    defer vm.allocator.free(bytes);
    try vm.vfs.writeFile(filepath, bytes);
    return receiver;
}

/// `solid.export_obj(path, mtl)` and `assembly.export_obj(path, mtl)`: Wavefront OBJ, an
/// object per Solid, as `kupcad build -o part.obj` writes it; with `mtl` true, the
/// materials go in a library beside it (part.mtl), as `--mtl` writes them.
pub fn meshExportObj(vm: *VM, receiver: value.Value, filepath: []const u8, mtl_opt: ?bool) !value.Value {
    var solids: std.ArrayList(value.Value) = .empty;
    defer solids.deinit(vm.allocator);
    const title = try receiverSolids(vm, receiver, "export_obj", &solids);
    const mtl_path: ?[]u8 = if (mtl_opt orelse false) try export_mod.materialLibraryPath(vm.allocator, filepath) else null;
    defer if (mtl_path) |p| vm.allocator.free(p);

    const bytes = obj.build(vm.allocator, vm, solids.items, title, if (mtl_path) |p| std.fs.path.basename(p) else null) catch |err| switch (err) {
        error.NoGeometry => return vm.fail(.GeometryError, "export_obj: the model is empty, there is nothing to write to '{s}'", .{filepath}),
        else => return err,
    };
    defer vm.allocator.free(bytes);
    try vm.vfs.writeFile(filepath, bytes);
    if (mtl_path) |p| {
        const library = try export_mod.exportMaterialLibrary(vm.allocator, vm);
        defer vm.allocator.free(library);
        try vm.vfs.writeFile(p, library);
    }
    return receiver;
}

/// `shape.export_svg(path)` and `shape.export_dxf(path)`: a Sketch as its drawing, a Solid
/// as its projection onto XY, an Assembly as its parts', as `kupcad build -o part.svg`
/// writes them.
pub fn meshExportSvg(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    return exportDrawingTo(vm, receiver, filepath, .svg, "export_svg");
}

pub fn meshExportDxf(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    return exportDrawingTo(vm, receiver, filepath, .dxf, "export_dxf");
}

fn exportDrawingTo(vm: *VM, receiver: value.Value, filepath: []const u8, format: ExportFormat, comptime method: []const u8) !value.Value {
    var solids: std.ArrayList(value.Value) = .empty;
    defer solids.deinit(vm.allocator);
    const sketches: []const value.Value = if (receiver.isCrossSection()) &.{receiver} else &.{};
    const paths: []const value.Value = if (receiver.isPath()) &.{receiver} else &.{};
    if (!receiver.isCrossSection() and !receiver.isPath()) _ = try receiverSolids(vm, receiver, method, &solids);
    const bytes = try export_mod.exportDrawing(vm.allocator, vm, format, .{}, sketches, solids.items, paths);
    defer vm.allocator.free(bytes);
    try vm.vfs.writeFile(filepath, bytes);
    return receiver;
}

/// `solid.export_stl(path)` and `assembly.export_stl(path)` (its parts united).
pub fn meshExportStl(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    var parts: std.ArrayList(geom.GeometryHandle) = .empty;
    defer parts.deinit(vm.allocator);
    try receiverParts(vm, receiver, "export_stl", &parts);

    const stl_bytes = stl.buildStlOfParts(vm.allocator, vm, parts.items) catch |err| switch (err) {
        error.NoGeometry => {
            return vm.fail(.GeometryError, "export_stl: the model is empty, there is nothing to write to '{s}'", .{filepath});
        },
        else => return err,
    };
    defer vm.allocator.free(stl_bytes);

    try vm.vfs.writeFile(filepath, stl_bytes);

    return receiver;
}

pub fn nativeImportStl(vm: *VM, path_str: []const u8) !value.Value {
    const file_buf = vm.readScriptFile(path_str) catch |err| {
        return vm.fail(.ImportError, "could not read STL file '{s}': {s}", .{ path_str, @errorName(err) });
    };
    defer vm.allocator.free(file_buf);

    var stl_mesh = stl.parseStlBuffer(vm.allocator, file_buf) catch |err| {
        return vm.fail(.ImportError, "could not parse STL file '{s}': {s}", .{ path_str, @errorName(err) });
    };
    defer stl_mesh.deinit(vm.allocator);

    const dag_idx = try vm.dag_builder.addPolyhedron(stl_mesh.points, stl_mesh.faces);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

/// import_font(path) -> the font file at `path` as a Font, for `text(font:)`: what
/// `import label from "./Inter-Bold.ttf"` calls. A file that can't be read, is larger than
/// limits.MAX_FONT_BYTES or isn't a font text can draw with (text.importedFace) is an
/// ImportError naming it. The Font is named as the font names itself, or after its file.
pub fn nativeImportFont(vm: *VM, path: []const u8) !value.Value {
    const file = vm.readScriptFile(path) catch |err| {
        return vm.fail(.ImportError, "could not read font file '{s}': {s}", .{ path, @errorName(err) });
    };
    defer vm.allocator.free(file);
    if (file.len > limits.MAX_FONT_BYTES) {
        return vm.fail(.ImportError, "font file '{s}' is {d} bytes; a script reads at most {d}", .{ path, file.len, limits.MAX_FONT_BYTES });
    }
    const face = text.importedFace(file) catch |err| {
        return vm.fail(.ImportError, "'{s}' isn't a font text can draw with: {s}", .{ path, describeFontError(err) });
    };
    const own_name = try text.fontName(vm.allocator, &face);
    defer if (own_name) |n| vm.allocator.free(n);

    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const name = try vm.gc.allocateString(vm, own_name orelse std.fs.path.basename(path));
    vm.push(value.Value.initObj(&name.obj));
    const bytes = try vm.gc.trackingAllocator().dupe(u8, file);
    errdefer vm.gc.trackingAllocator().free(bytes);
    const font = try vm.gc.allocateFont(vm, bytes, name);
    return value.Value.initObj(&font.obj);
}

fn describeFontError(err: text.ImportedFontError) []const u8 {
    return switch (err) {
        error.InvalidFont => "it isn't a TrueType or OpenType font",
        error.NoOutlines => "it has no outlines (TrueType or CFF ones; a variable CFF2 font's and a bitmap font's aren't read)",
        error.NoCharacterMap => "it maps no characters to glyphs (it has no cmap table)",
    };
}

/// `solid.export_gltf(path, draco)` and `assembly.export_gltf(path, draco)`: the parts kept
/// apart, each a node named after it.
pub fn meshExportGltf(vm: *VM, receiver: value.Value, filepath: []const u8, draco_opt: ?bool) !value.Value {
    var solids: std.ArrayList(value.Value) = .empty;
    defer solids.deinit(vm.allocator);
    _ = try receiverSolids(vm, receiver, "export_gltf", &solids);
    var parts = try export_mod.gltfParts(vm.allocator, vm, solids.items, &.{});
    defer parts.deinit();
    for (parts.items) |part| try vm.requireFeature(part.handle.engine, .mesh);
    const draco_bits: ?u8 = if (draco_opt orelse false) gltf.DEFAULT_DRACO_POSITION_BITS else null;
    const bytes = try gltf.buildGltfBuffer(vm.allocator, vm, parts.items, draco_bits, gltf.Container.forPath(filepath));
    defer vm.allocator.free(bytes);

    try vm.vfs.writeFile(filepath, bytes);

    return receiver;
}

pub fn meshExportStep(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    var export_handles = std.ArrayList(geom.GeometryHandle).empty;
    defer export_handles.deinit(vm.allocator);

    try receiverParts(vm, receiver, "export_step", &export_handles);
    try step.requireExactParts(vm, export_handles.items);

    const step_bytes = step.buildStepBuffer(vm.allocator, export_handles.items) catch |err| {
        return vm.fail(.GeometryError, "export_step could not write the STEP file ({s})", .{@errorName(err)});
    };
    defer vm.allocator.free(step_bytes);

    try vm.vfs.writeFile(filepath, step_bytes);

    return receiver;
}

pub fn nativeImportStep(vm: *VM, path_str: []const u8) !value.Value {
    _ = path_str;
    return vm.fail(.NotImplementedError, "import_step is not supported yet", .{});
}
