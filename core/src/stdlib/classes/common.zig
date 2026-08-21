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

    std.debug.assert(receiver.isObject() and receiver.asObj().obj_type == .array);

    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .arr = arr };
}

pub fn unwrapMap(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, map: *value.ObjMap } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];

    std.debug.assert(receiver.isObject() and receiver.asObj().obj_type == .map);

    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .map = map };
}

pub fn unwrapString(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, str: *value.ObjString } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];

    std.debug.assert(receiver.isObject() and receiver.asObj().obj_type == .string);

    const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .str = str };
}

pub fn unwrapSymbol(vm_opaque: *anyopaque, arg_count: u8, expected_args: u8, args: [*]value.Value) !struct { vm: *VM, receiver: value.Value, sym: *value.ObjSymbol } {
    if (arg_count != expected_args) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const receiver = (args - 1)[0];

    std.debug.assert(receiver.isObject() and receiver.asObj().obj_type == .symbol);

    const sym = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", receiver.asObj())));
    return .{ .vm = vm, .receiver = receiver, .sym = sym };
}

/// Wraps a strongly typed Zig function into a raw KupCAD `NativeFn`
pub fn wrapNative(comptime func: anytype) value.NativeFn {
    const fn_info = @typeInfo(@TypeOf(func)).Fn;
    const params = fn_info.params;

    // Expected arguments = Total function parameters - 2 (subtracting `vm: *VM` and `receiver`)
    const expected_args: u8 = @intCast(params.len - 2);

    return struct {
        fn nativeWrapper(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
            if (arg_count != expected_args) return error.RuntimeError;
            const vm: *VM = @ptrCast(@alignCast(vm_opaque));

            // Extract receiver from slot (args - 1)
            const raw_receiver = (args - 1)[0];

            // Comptime type-checking and unboxing for Receiver
            const ReceiverType = params[1].type.?;
            const receiver = switch (ReceiverType) {
                *value.ObjArray => if (raw_receiver.isObject() and raw_receiver.asObj().obj_type == .array)
                    @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", raw_receiver.asObj())))
                else
                    return error.RuntimeError,
                *value.ObjMap => if (raw_receiver.isObject() and raw_receiver.asObj().obj_type == .map)
                    @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", raw_receiver.asObj())))
                else
                    return error.RuntimeError,
                *value.ObjString => if (raw_receiver.isObject() and raw_receiver.asObj().obj_type == .string)
                    @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", raw_receiver.asObj())))
                else
                    return error.RuntimeError,
                value.Value => raw_receiver,
                else => @compileError("Unsupported receiver type in wrapNative"),
            };

            // Invoke the strongly typed function dynamically
            var call_args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            call_args[0] = vm;
            call_args[1] = receiver;

            inline for (params[2..], 0..) |param, idx| {
                const ArgType = param.type.?;
                const raw_arg = args[idx];
                call_args[idx + 2] = if (ArgType == value.Value)
                    raw_arg
                else if (ArgType == f64)
                    if (raw_arg.isNumber()) raw_arg.asNumber() else return error.RuntimeError
                else if (ArgType == bool)
                    if (raw_arg.isBool()) raw_arg.asBool() else return error.RuntimeError
                else
                    @compileError("Unsupported argument type in wrapNative");
            }

            return @call(.auto, func, call_args);
        }
    }.nativeWrapper;
}
