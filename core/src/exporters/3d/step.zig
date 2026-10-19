//! STEP: `buildStepBuffer` writes B-Rep solids through the kernel, and `requireExactParts`
//! refuses, by name, any part that isn't B-Rep geometry, which STEP can't hold. The script's
//! `export_step` and `import_step` are in stdlib/files.zig.

const std = @import("std");
const VM = @import("../../vm/vm.zig").VM;
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
            const which = std.mem.print(&buf, "part {d} of {d}", .{ n, handles.len }) catch "a part";
            _ = vm.raiseError(.NotImplementedError, fmt, .{ which, h.engine.scriptName() });
        }
        return error.RuntimeError;
    }
}
