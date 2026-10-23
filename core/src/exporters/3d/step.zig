//! STEP: `buildStepBuffer` writes B-Rep solids through the kernel; a part that isn't one
//! (a mesh) is refused by name before (export.zig's `requireExactParts`). The script's
//! `export_step` and `import_step` are in stdlib/files.zig.

const std = @import("std");
const geom = @import("../../core/geometry_handle.zig");
const kernel = @import("../../kernel/kernel.zig");

pub fn buildStepBuffer(allocator: std.mem.Allocator, handles: []const geom.GeometryHandle) ![]const u8 {
    return kernel.exportStep(allocator, handles);
}
