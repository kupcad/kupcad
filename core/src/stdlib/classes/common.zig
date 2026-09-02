const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const geom = @import("../../kernel/geometry_handle.zig");

/// Defines a native class method mapping
pub const MethodDef = struct {
    name: []const u8,
    func: value.NativeFn,
};

/// Comptime helper to unbox a `Value` into a strongly typed Zig parameter.
/// Throws `error.RuntimeError` if the type check fails at runtime.
pub inline fn unboxValue(comptime T: type, val: value.Value, vm: *VM) !T {
    if (T == value.Value) return val;
    if (T == f64) return if (val.isNumber()) val.asNumber() else error.RuntimeError;
    if (T == bool) return if (val.isBool()) val.asBool() else error.RuntimeError;
    if (T == []const u8) return if (val.isString()) val.asString().chars else error.RuntimeError;

    if (T == *value.ObjString) return if (val.isObject() and val.asObj().obj_type == .string)
        @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", val.asObj())))
    else
        error.RuntimeError;

    if (T == *value.ObjSymbol) return if (val.isObject() and val.asObj().obj_type == .symbol)
        @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", val.asObj())))
    else
        error.RuntimeError;

    if (T == *value.ObjArray) return if (val.isObject() and val.asObj().obj_type == .array)
        @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", val.asObj())))
    else
        error.RuntimeError;

    if (T == *value.ObjMap) return if (val.isObject() and val.asObj().obj_type == .map)
        @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", val.asObj())))
    else
        error.RuntimeError;

    if (T == *value.ObjClosure) return if (val.isClosure())
        val.asClosure()
    else
        error.RuntimeError;

    if (T == *value.ObjInstance) return if (val.isInstance())
        val.asInstance()
    else
        error.RuntimeError;

    // --- Strongly Typed Geometry Pointers for DAG Continuity ---
    if (T == *value.ObjGeometry) {
        if (!val.isGeometry()) return error.RuntimeError;
        return val.asGeometry();
    }
    if (T == *value.ObjCrossSection) {
        if (!val.isCrossSection()) return error.RuntimeError;
        return val.asCrossSection();
    }

    // Auto-Evaluate DAG for raw CAD kernel functions
    if (T == geom.GeometryHandle) {
        if (!val.isGeometry()) return error.RuntimeError;
        return try vm.ensureConcrete(val);
    }
    if (T == geom.CrossSectionHandle) {
        if (!val.isCrossSection()) return error.RuntimeError;
        return try vm.ensureConcreteCrossSection(val);
    }

    switch (@typeInfo(T)) {
        .optional => |opt_info| {
            if (val.isNil()) return null;
            return try unboxValue(opt_info.child, val, vm);
        },
        else => @compileError("Unsupported parameter type in wrapNative: " ++ @typeName(T)),
    }
}

/// Wraps a strongly typed Zig method signature `fn(vm: *VM, receiver: ReceiverType, arg1: Arg1Type, ...) !value.Value`
/// into KupCAD's raw `NativeFn` function pointer signature (`fn(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) ...`).
pub fn wrapMethod(comptime func: anytype) value.NativeFn {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const params = fn_info.params;

    if (params.len < 2) {
        @compileError("Native method function must take at least (vm: *VM, receiver: ReceiverType)");
    }

    const has_block_param = params.len > 2 and params[params.len - 1].type.? == ?*value.ObjClosure;

    return struct {
        fn nativeWrapper(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
            const vm: *VM = @ptrCast(@alignCast(vm_opaque));
            var call_args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;

            call_args[0] = vm;
            call_args[1] = try unboxValue(params[1].type.?, vm.getReceiver(args), vm);

            var effective_arg_count: usize = arg_count;
            var block_val: ?*value.ObjClosure = null;

            // Intercept the implicit trailing block so optional positionals don't consume it
            if (has_block_param and arg_count > 0) {
                const last_arg = args[arg_count - 1];
                if (last_arg.isClosure()) {
                    block_val = last_arg.asClosure();
                    effective_arg_count -= 1;
                }
            }

            var arg_idx: usize = 0;
            inline for (params[2..], 2..) |param, i| {
                const ParamType = param.type.?;
                if (has_block_param and i == params.len - 1) {
                    call_args[i] = block_val;
                } else if (ParamType == []const value.Value) {
                    call_args[i] = args[arg_idx..effective_arg_count];
                    arg_idx = effective_arg_count;
                } else if (@typeInfo(ParamType) == .optional) {
                    if (arg_idx < effective_arg_count) {
                        call_args[i] = try unboxValue(ParamType, args[arg_idx], vm);
                        arg_idx += 1;
                    } else {
                        call_args[i] = null;
                    }
                } else {
                    if (arg_idx >= effective_arg_count) {
                        vm.runtimeError("Runtime Error: Not enough arguments.\n", .{});
                        return error.RuntimeError;
                    }
                    call_args[i] = try unboxValue(ParamType, args[arg_idx], vm);
                    arg_idx += 1;
                }
            }

            return @call(.auto, func, call_args);
        }
    }.nativeWrapper;
}

pub fn wrapGlobal(comptime func: anytype) value.NativeFn {
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const params = fn_info.params;

    if (params.len < 1) {
        @compileError("Native global function must take at least (vm: *VM)");
    }

    const has_block_param = params.len > 1 and params[params.len - 1].type.? == ?*value.ObjClosure;

    return struct {
        fn nativeWrapper(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
            const vm: *VM = @ptrCast(@alignCast(vm_opaque));
            var call_args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            call_args[0] = vm;

            var effective_arg_count: usize = arg_count;
            var block_val: ?*value.ObjClosure = null;

            if (has_block_param and arg_count > 0) {
                const last_arg = args[arg_count - 1];
                if (last_arg.isClosure()) {
                    block_val = last_arg.asClosure();
                    effective_arg_count -= 1;
                }
            }

            var arg_idx: usize = 0;
            inline for (params[1..], 1..) |param, i| {
                const ParamType = param.type.?;
                if (has_block_param and i == params.len - 1) {
                    call_args[i] = block_val;
                } else if (ParamType == []const value.Value) {
                    call_args[i] = args[arg_idx..effective_arg_count];
                    arg_idx = effective_arg_count;
                } else if (@typeInfo(ParamType) == .optional) {
                    if (arg_idx < effective_arg_count) {
                        call_args[i] = try unboxValue(ParamType, args[arg_idx], vm);
                        arg_idx += 1;
                    } else {
                        call_args[i] = null;
                    }
                } else {
                    if (arg_idx >= effective_arg_count) {
                        vm.runtimeError("Runtime Error: Not enough arguments.\n", .{});
                        return error.RuntimeError;
                    }
                    call_args[i] = try unboxValue(ParamType, args[arg_idx], vm);
                    arg_idx += 1;
                }
            }
            return @call(.auto, func, call_args);
        }
    }.nativeWrapper;
}
