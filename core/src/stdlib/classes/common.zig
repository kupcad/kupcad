const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;

/// Defines a native class method mapping
pub const MethodDef = struct {
    name: []const u8,
    func: value.NativeFn,
};

/// Comptime helper to unbox a `Value` into a strongly typed Zig parameter.
/// Throws `error.RuntimeError` if the type check fails at runtime.
pub inline fn unboxValue(comptime T: type, val: value.Value) !T {
    return switch (T) {
        value.Value => val,
        f64 => if (val.isNumber()) val.asNumber() else error.RuntimeError,
        bool => if (val.isBool()) val.asBool() else error.RuntimeError,
        *value.ObjString => if (val.isObject() and val.asObj().obj_type == .string)
            @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", val.asObj())))
        else
            error.RuntimeError,
        *value.ObjSymbol => if (val.isObject() and val.asObj().obj_type == .symbol)
            @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", val.asObj())))
        else
            error.RuntimeError,
        *value.ObjArray => if (val.isObject() and val.asObj().obj_type == .array)
            @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", val.asObj())))
        else
            error.RuntimeError,
        *value.ObjMap => if (val.isObject() and val.asObj().obj_type == .map)
            @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", val.asObj())))
        else
            error.RuntimeError,
        *value.ObjClosure => if (val.isClosure())
            val.asClosure()
        else
            error.RuntimeError,
        else => @compileError("Unsupported parameter type in wrapNative: " ++ @typeName(T)),
    };
}

/// Wraps a strongly typed Zig method signature `fn(vm: *VM, receiver: ReceiverType, arg1: Arg1Type, ...) !value.Value`
/// into KupCAD's raw `NativeFn` function pointer signature (`fn(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) ...`).
pub fn wrapNative(comptime func: anytype) value.NativeFn {
    // Escape `fn` using @"fn" syntax
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const params = fn_info.params;

    if (params.len < 2) {
        @compileError("Native method function must take at least (vm: *VM, receiver: ReceiverType)");
    }

    const expected_args: u8 = @intCast(params.len - 2);

    return struct {
        fn nativeWrapper(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
            if (arg_count != expected_args) return error.RuntimeError;
            const vm: *VM = @ptrCast(@alignCast(vm_opaque));

            // Extract receiver securely using the FFI Bounds Checker
            const raw_receiver = vm.getReceiver(args);

            // Build parameter tuple dynamically at compile-time
            var call_args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            call_args[0] = vm;
            call_args[1] = try unboxValue(params[1].type.?, raw_receiver);

            inline for (params[2..], 0..) |param, idx| {
                const ArgType = param.type.?;
                const raw_arg = args[idx];
                call_args[idx + 2] = try unboxValue(ArgType, raw_arg);
            }
            return @call(.auto, func, call_args);
        }
    }.nativeWrapper;
}
