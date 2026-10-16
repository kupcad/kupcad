//! The script's file methods: `export_stl`, `export_gltf` and `export_step` on a Solid or an
//! Assembly, and `import_stl` / `import_step`. The formats themselves are in exporters/3d
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

/// Appends the evaluated parts of `receiver`, a Solid (itself) or an Assembly (its Solids),
/// to `out`; `method` names the export in the error for anything else. Handles are
/// borrowed from the VM.
pub fn receiverParts(vm: *VM, receiver: value.Value, comptime method: []const u8, out: *std.ArrayListUnmanaged(geom.GeometryHandle)) !void {
    if (receiver.isGeometry()) return out.append(vm.allocator, try vm.ensureConcrete(receiver));
    if (!receiver.isAssembly()) return util.notDefinedFor(vm, method, receiver);
    for (receiver.asAssembly().parts.items.items) |part| try out.append(vm.allocator, try vm.ensureConcrete(part));
}

/// `solid.export_stl(path)` and `assembly.export_stl(path)` (its parts united).
pub fn meshExportStl(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    var parts: std.ArrayListUnmanaged(geom.GeometryHandle) = .empty;
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
    const file_buf = vm.vfs.readFile(vm.allocator, path_str) catch |err| {
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

pub fn meshExportGltf(vm: *VM, receiver: value.Value, filepath: []const u8, draco_opt: ?bool) !value.Value {
    var handles = std.ArrayListUnmanaged(geom.GeometryHandle).empty;
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
    var export_handles = std.ArrayListUnmanaged(geom.GeometryHandle).empty;
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
