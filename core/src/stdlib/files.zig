//! The script's file methods: `export_stl`, `export_gltf`, `export_step`, `export_3mf` and
//! `export_obj` on a Solid or an Assembly, `export_svg` and `export_dxf` on any shape (a
//! drawing, through exporters/export.zig), and `import_stl` / `import_step` / `import_font`
//! (`import_json` is in json.zig). The formats themselves are in exporters/3d and
//! exporters/2d, which know nothing of scripts.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const arguments = @import("arguments.zig");
const stl = @import("../exporters/3d/stl.zig");
const export_mod = @import("../exporters/export.zig");
const format_mod = @import("../exporters/format.zig");
const ExportFormat = format_mod.ExportFormat;
const ExportOptions = format_mod.ExportOptions;
const gltf = @import("../exporters/3d/gltf.zig");
const text = @import("../core/text.zig");
const limits = @import("../core/limits.zig");
const HandleScope = @import("../vm/scope.zig").HandleScope;

/// The shapes of `receiver` an export writes: a Solid, an Assembly's parts with its name,
/// and for a drawing a Sketch or a Path too, kept in `held`; `method` names the export in
/// the error for anything else.
fn shapesOf(vm: *VM, receiver: value.Value, comptime method: []const u8, format: ExportFormat, held: *std.ArrayList(value.Value)) !export_mod.Shapes {
    if (format.dimension() == .@"2d" and (receiver.isCrossSection() or receiver.isPath())) {
        try held.append(vm.allocator, receiver);
        return if (receiver.isPath()) .{ .paths = held.items } else .{ .sketches = held.items };
    }
    if (receiver.isGeometry()) {
        try held.append(vm.allocator, receiver);
        return .{ .solids = held.items };
    }
    if (!receiver.isAssembly()) return arguments.notDefinedFor(vm, method, receiver);
    const assembly = receiver.asAssembly();
    try held.appendSlice(vm.allocator, assembly.parts.items.items);
    return .{ .solids = held.items, .title = assembly.name.chars };
}

/// Writes `receiver` to `filepath` in `format` as `options` say, as `kupcad build` writes
/// the model: the script's `method`. An empty model is an error naming the file.
fn exportTo(vm: *VM, receiver: value.Value, filepath: []const u8, format: ExportFormat, options: ExportOptions, comptime method: []const u8) !void {
    var held: std.ArrayList(value.Value) = .empty;
    defer held.deinit(vm.allocator);
    const shapes = try shapesOf(vm, receiver, method, format, &held);
    const bytes = export_mod.exportShapes(vm.allocator, vm, format, options, shapes) catch |err| switch (err) {
        error.NoGeometry => return vm.fail(.GeometryError, method ++ ": the model is empty, there is nothing to write to '{s}'", .{filepath}),
        else => return err,
    };
    defer vm.allocator.free(bytes);
    try vm.vfs.writeFile(filepath, bytes);
}

/// `solid.export_stl(path)` and `assembly.export_stl(path)` (its parts united).
pub fn meshExportStl(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    try exportTo(vm, receiver, filepath, .stl, .{}, "export_stl");
    return receiver;
}

/// `solid.export_3mf(path)` and `assembly.export_3mf(path)`: each part once, placed once
/// per copy, with its name and colours.
pub fn meshExport3mf(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    try exportTo(vm, receiver, filepath, .@"3mf", .{}, "export_3mf");
    return receiver;
}

/// `solid.export_obj(path, mtl)` and `assembly.export_obj(path, mtl)`: Wavefront OBJ, an
/// object per Solid; with `mtl` true, the materials go in a library beside it (part.mtl),
/// as `--mtl` writes them.
pub fn meshExportObj(vm: *VM, receiver: value.Value, filepath: []const u8, mtl_opt: ?bool) !value.Value {
    const mtl_path: ?[]u8 = if (mtl_opt orelse false) try export_mod.materialLibraryPath(vm.allocator, filepath) else null;
    defer if (mtl_path) |p| vm.allocator.free(p);
    try exportTo(vm, receiver, filepath, .obj, .{ .mtl_name = if (mtl_path) |p| std.fs.path.basename(p) else null }, "export_obj");
    if (mtl_path) |p| {
        const library = try export_mod.exportMaterialLibrary(vm.allocator, vm);
        defer vm.allocator.free(library);
        try vm.vfs.writeFile(p, library);
    }
    return receiver;
}

/// `solid.export_gltf(path, draco)` and `assembly.export_gltf(path, draco)`: the parts kept
/// apart, each a node named after it; glTF JSON for a `.gltf` path, binary glTF otherwise.
pub fn meshExportGltf(vm: *VM, receiver: value.Value, filepath: []const u8, draco_opt: ?bool) !value.Value {
    const format: ExportFormat = if (gltf.Container.forPath(filepath) == .gltf) .gltf else .glb;
    try exportTo(vm, receiver, filepath, format, .{ .draco = draco_opt orelse false }, "export_gltf");
    return receiver;
}

/// `solid.export_step(path)` and `assembly.export_step(path)`: exact B-Rep parts only.
pub fn meshExportStep(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    try exportTo(vm, receiver, filepath, .step, .{}, "export_step");
    return receiver;
}

/// `shape.export_svg(path)` and `shape.export_dxf(path)`: a Sketch as its drawing, a Path
/// as it is, a Solid as its projection onto XY, an Assembly as its parts'.
pub fn meshExportSvg(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    try exportTo(vm, receiver, filepath, .svg, .{}, "export_svg");
    return receiver;
}

pub fn meshExportDxf(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    try exportTo(vm, receiver, filepath, .dxf, .{}, "export_dxf");
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

pub fn nativeImportStep(vm: *VM, path_str: []const u8) !value.Value {
    _ = path_str;
    return vm.fail(.NotImplementedError, "import_step is not supported yet", .{});
}
