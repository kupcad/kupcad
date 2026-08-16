const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;

pub const MethodDef = struct {
    name: []const u8,
    func: value.NativeFn,
};

// --- Unboxing Helpers ---
pub fn unwrapArray(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, arr: *value.ObjArray } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .arr = arr };
}

pub fn unwrapMap(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, map: *value.ObjMap } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .map = map };
}

pub fn unwrapString(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, str: *value.ObjString } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .str = str };
}

pub fn unwrapSymbol(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, sym: *value.ObjSymbol } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];
    const sym = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .sym = sym };
}
