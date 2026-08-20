const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

/// GC.collect -> Triggers an immediate Mark-and-Sweep garbage collection cycle
pub fn gcCollect(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    // Run full mark-and-sweep (passing false preserves reachable roots)
    vm.gc.collectGarbage(vm, false);

    return value.Value.initNil();
}

/// GC.bytes_allocated -> Returns total heap memory currently tracked by GC (in bytes)
pub fn gcBytesAllocated(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    return value.Value.initNumber(@floatFromInt(vm.gc.bytes_allocated));
}

pub const methods = [_]common.MethodDef{
    .{ .name = "collect", .func = gcCollect },
    .{ .name = "bytes_allocated", .func = gcBytesAllocated },
};
