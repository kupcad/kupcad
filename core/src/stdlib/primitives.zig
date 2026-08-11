const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn nativeCube(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    // Fast $O(1)$ Arena append. No C++ kernel invoked
    const dag_idx = try vm.dag_builder.addCube(1.0, 1.0, 1.0, true);

    // Create the geometry wrapper
    const ptr = try vm.allocator.create(value.ObjGeometry);
    ptr.* = .{
        .obj = .{
            .obj_type = .geometry,
            .is_marked = false,
            .next = null, // Leaves this out of the GC tracking loop
        },
        .ref_count = 1,
        .dag_idx = dag_idx,
        .cached_handle = null,
        .cached_bbox = null,
    };

    return value.Value.initGeometry(ptr);
}
