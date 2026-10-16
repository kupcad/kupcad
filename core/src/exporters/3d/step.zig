//! STEP export for scripts: `export_step` (`meshExportStep`) writes the parts of a solid or
//! assembly through the kernel, refusing any part that isn't B-Rep geometry; `import_step`
//! is not implemented yet and raises.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const util = @import("../../stdlib/methods/util.zig");
const geom = @import("../../kernel/geometry_handle.zig");
const kernel = @import("../../kernel/kernel.zig");

pub fn buildStepBuffer(allocator: std.mem.Allocator, handles: []const geom.GeometryHandle) ![]const u8 {
    return kernel.exportStep(allocator, handles);
}

/// Raises unless every part is exact (B-Rep) geometry, which is all STEP can hold. The
/// writer skipped mesh parts: a model with a Manifold part was written without it, and an
/// all-Manifold model failed with a bare NoGeometry.
pub fn requireExactParts(vm: *VM, handles: []const geom.GeometryHandle) error{RuntimeError}!void {
    for (handles, 1..) |h, n| {
        if (h.engine == .brep_native) continue;
        const fmt = "STEP export needs exact geometry, and {s} was built by the {s} engine (a mesh); build it with engine: :brep";
        if (handles.len == 1) {
            _ = vm.raiseError(.NotImplementedError, fmt, .{ "the model", h.engine.scriptName() });
        } else {
            var buf: [48]u8 = undefined;
            const which = std.fmt.bufPrint(&buf, "part {d} of {d}", .{ n, handles.len }) catch "a part";
            _ = vm.raiseError(.NotImplementedError, fmt, .{ which, h.engine.scriptName() });
        }
        return error.RuntimeError;
    }
}

pub fn meshExportStep(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    var export_handles = std.ArrayListUnmanaged(geom.GeometryHandle).empty;
    defer export_handles.deinit(vm.allocator);

    if (receiver.isAssembly()) {
        for (receiver.asAssembly().parts.items.items) |part_val| {
            if (part_val.isGeometry()) {
                const h = try vm.ensureConcrete(part_val);
                try export_handles.append(vm.allocator, h);
            }
        }
    } else if (receiver.isGeometry()) {
        try export_handles.append(vm.allocator, try vm.ensureConcrete(receiver));
    } else {
        return util.notDefinedFor(vm, "export_step", receiver);
    }
    try requireExactParts(vm, export_handles.items);

    const step_bytes = buildStepBuffer(vm.allocator, export_handles.items) catch |err| {
        _ = vm.raiseError(.GeometryError, "export_step could not write the STEP file ({s})", .{@errorName(err)});
        return error.RuntimeError;
    };
    defer vm.allocator.free(step_bytes);

    try vm.vfs.writeFile(filepath, step_bytes);

    return receiver;
}

pub fn nativeImportStep(vm: *VM, path_str: []const u8) !value.Value {
    _ = path_str;
    _ = vm.raiseError(.NotImplementedError, "import_step is not supported yet", .{});
    return error.RuntimeError;
}
