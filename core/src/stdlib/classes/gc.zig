const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

pub fn gcCollect(vm: *VM, receiver: value.Value) !value.Value {
    _ = receiver;
    vm.gc.collectGarbage(vm, false);
    return value.Value.initNil();
}

pub fn gcBytesAllocated(vm: *VM, receiver: value.Value) !value.Value {
    _ = receiver;
    return value.Value.initNumber(@floatFromInt(vm.gc.bytes_allocated));
}

pub const methods = [_]common.MethodDef{
    .{ .name = "collect", .func = common.wrapMethod(gcCollect) },
    .{ .name = "bytes_allocated", .func = common.wrapMethod(gcBytesAllocated) },
};
