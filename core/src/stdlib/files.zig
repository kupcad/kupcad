//! The script's file methods: `export_stl`, `export_gltf` and `export_step` on a Solid or an
//! Assembly, and `import_stl` / `import_step` / `import_font` (`import_json` is in json.zig). The formats themselves are in exporters/3d
//! (stl.zig, gltf.zig, step.zig), which knew nothing of scripts until these lived there.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const geom = @import("../kernel/geometry_handle.zig");
const kernel = @import("../kernel/kernel.zig");
const util = @import("methods/util.zig");
const stl = @import("../exporters/3d/stl.zig");
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

pub fn meshExportGltf(vm: *VM, receiver: value.Value, filepath: []const u8, draco_opt: ?bool) !value.Value {
    var handles = std.ArrayList(geom.GeometryHandle).empty;
    defer handles.deinit(vm.allocator);

    const use_draco = draco_opt orelse false;

    try receiverParts(vm, receiver, "export_gltf", &handles);

    for (handles.items) |h| try vm.requireFeature(h.engine, .mesh);
    const bytes = try gltf.buildGltfBuffer(vm.allocator, vm, handles.items, use_draco, gltf.Container.forPath(filepath));
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
