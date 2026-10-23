//! What the native classes share: `MethodDef`, an entry of a class's method table, and
//! `wrapMethod`/`wrapGlobal`, which turn a typed Zig function into a `value.NativeFn` that
//! checks and unboxes the call's arguments.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const geom = @import("../../core/geometry_handle.zig");
const arguments = @import("../arguments.zig");
const Signature = @import("../signature.zig").Signature;

/// Defines a native class method mapping
pub const MethodDef = struct {
    name: []const u8,
    func: value.NativeFn,
};

/// Comptime helper to unbox a `Value` into a strongly typed Zig parameter; error.WrongType
/// when it is not of that type.
pub inline fn unboxValue(comptime T: type, val: value.Value, vm: *VM) !T {
    if (T == value.Value) return val;
    if (T == f64) return if (val.isNumber()) val.asNumber() else error.WrongType;
    if (T == bool) return if (val.isBool()) val.asBool() else error.WrongType;
    if (T == []const u8) return if (val.isString()) val.asString().chars else error.WrongType;
    if (T == *value.ObjString) return if (val.isString()) val.asString() else error.WrongType;
    if (T == *value.ObjSymbol) return if (val.isSymbol()) val.asSymbol() else error.WrongType;
    if (T == *value.ObjArray) return if (val.isArray()) val.asArray() else error.WrongType;
    if (T == *value.ObjMap) return if (val.isMap()) val.asMap() else error.WrongType;
    if (T == *value.ObjJsonObject) return if (val.isJsonObject()) val.asJsonObject() else error.WrongType;
    if (T == *value.ObjRange) return if (val.isRange()) val.asRange() else error.WrongType;
    if (T == *value.ObjClosure) return if (val.isClosure()) val.asClosure() else error.WrongType;
    if (T == *value.ObjInstance) return if (val.isInstance()) val.asInstance() else error.WrongType;
    if (T == *value.ObjClass) return if (val.isClass()) val.asClass() else error.WrongType;
    if (T == *value.ObjBBox) return if (val.isBBox()) val.asBBox() else error.WrongType;
    if (T == *value.ObjFont) return if (val.isFont()) val.asFont() else error.WrongType;

    // --- Strongly Typed Geometry Pointers for DAG Continuity ---
    if (T == *value.ObjGeometry) return if (val.isGeometry()) val.asGeometry() else error.WrongType;
    if (T == *value.ObjCrossSection) return if (val.isCrossSection()) val.asCrossSection() else error.WrongType;

    // Auto-Evaluate DAG for raw CAD kernel functions
    if (T == geom.GeometryHandle) {
        if (!val.isGeometry()) return error.WrongType;
        return try vm.ensureConcrete(val);
    }
    if (T == geom.CrossSectionHandle) {
        if (!val.isCrossSection()) return error.WrongType;
        return try vm.ensureConcreteCrossSection(val);
    }

    switch (@typeInfo(T)) {
        .optional => |opt_info| {
            if (val.isNil()) return null;
            return try unboxValue(opt_info.child, val, vm);
        },
        else => @compileError("Unsupported parameter type in a wrapped native: " ++ @typeName(T)),
    }
}

/// How a TypeError describes parameter type `T` ("expects a number for argument 1").
fn expectedName(comptime T: type) []const u8 {
    if (@typeInfo(T) == .optional) return expectedName(@typeInfo(T).optional.child);
    return switch (T) {
        f64 => "a number",
        bool => "true or false",
        []const u8, *value.ObjString => "a String",
        *value.ObjSymbol => "a Symbol",
        *value.ObjArray => "an Array",
        *value.ObjMap => "a Map",
        *value.ObjJsonObject => "a JsonObject",
        *value.ObjRange => "a Range",
        *value.ObjClosure => "a block or lambda",
        *value.ObjInstance => "an object",
        *value.ObjClass => "a Class",
        *value.ObjBBox => "a BoundingBox",
        *value.ObjFont => "a Font",
        *value.ObjGeometry, geom.GeometryHandle => "a Solid",
        *value.ObjCrossSection, geom.CrossSectionHandle => "a Sketch",
        else => @compileError("No expectedName for " ++ @typeName(T)),
    };
}

/// Turns a typed Zig function into a `value.NativeFn`. After `vm` (and, for a method, the
/// receiver) its parameters take the call's arguments in order: an optional one may be
/// omitted, and a `[]const value.Value` takes all the rest. A last parameter of type
/// `?*value.ObjClosure` takes the call's block, or `*value.ObjClosure` a block it requires;
/// a native without one ignores a block, like Ruby.
/// A wrong number of arguments is an ArgumentError and a wrong type a TypeError, each
/// naming the native and the argument: they used to be a generic "Native Execution Error",
/// and extra arguments were dropped silently.
fn wrap(comptime func: anytype, comptime has_receiver: bool, comptime sig: ?Signature) value.NativeFn {
    const param_types = @typeInfo(@TypeOf(func)).@"fn".param_types;
    const first_arg: usize = 1 + @as(usize, @intFromBool(has_receiver));
    if (param_types.len < first_arg) @compileError("A wrapped native takes (vm: *VM" ++ (if (has_receiver) ", receiver" else "") ++ ", ...)");

    const last_type = param_types[param_types.len - 1].?;
    const has_block_param = param_types.len > first_arg and (last_type == ?*value.ObjClosure or last_type == *value.ObjClosure);
    const arg_types = param_types[first_arg .. param_types.len - @intFromBool(has_block_param)];
    const arity = comptime blk: {
        var required: usize = 0;
        var max: ?usize = arg_types.len;
        for (arg_types) |T| {
            if (T.? == []const value.Value) {
                max = null;
            } else if (@typeInfo(T.?) != .optional) {
                required += 1;
            }
        }
        break :blk .{ .required = required, .max = max };
    };

    return struct {
        fn nativeWrapper(vm_opaque: *anyopaque, args: value.NativeArgs) anyerror!value.Value {
            const vm: *VM = @ptrCast(@alignCast(vm_opaque));
            // SAFETY: call_args is populated element by element below.
            var call_args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            call_args[0] = vm;
            if (has_receiver) {
                const receiver = args.receiver();
                call_args[1] = unboxValue(param_types[1].?, receiver, vm) catch |err| {
                    if (err == error.WrongType) return vm.fail(.TypeError, "{s} can't be called on {s}", .{ args.name, arguments.typeName(vm, receiver) });
                    return err;
                };
            }

            const given = args.positional();
            if (sig) |s| try checkArguments(vm, args.name, s, given);
            if (given.len < arity.required or (arity.max != null and given.len > arity.max.?)) {
                return arityError(vm, args.name, arity.required, arity.max, given.len);
            }

            var next: usize = 0;
            inline for (arg_types, first_arg..) |T, slot| {
                if (T.? == []const value.Value) {
                    call_args[slot] = given[next..];
                    next = given.len;
                } else if (@typeInfo(T.?) == .optional and next >= given.len) {
                    call_args[slot] = null;
                } else {
                    call_args[slot] = unboxValue(T.?, given[next], vm) catch |err| {
                        if (err == error.WrongType) return vm.fail(.TypeError, "{s} expects {s} for argument {d}, got {s}", .{ args.name, expectedName(T.?), next + 1, arguments.typeName(vm, given[next]) });
                        return err;
                    };
                    next += 1;
                }
            }
            if (has_block_param) {
                if (last_type == *value.ObjClosure) {
                    call_args[param_types.len - 1] = try arguments.requireBlock(vm, args.block(), args.name);
                } else {
                    call_args[param_types.len - 1] = args.block();
                }
            }

            return @call(.auto, func, call_args);
        }
    }.nativeWrapper;
}

/// Wraps `fn(vm: *VM, receiver: ReceiverType, args...) !value.Value` (see `wrap`).
pub fn wrapMethod(comptime func: anytype) value.NativeFn {
    return wrap(func, true, null);
}

/// Wraps `fn(vm: *VM, args...) !value.Value` (see `wrap`).
pub fn wrapGlobal(comptime func: anytype) value.NativeFn {
    return wrap(func, false, null);
}

/// wrapMethod for a method `sig` describes: see `checkArguments`.
pub fn wrapMethodWith(comptime func: anytype, comptime sig: Signature) value.NativeFn {
    return wrap(func, true, sig);
}

/// wrapGlobal for a function `sig` describes: see `checkArguments`.
pub fn wrapGlobalWith(comptime func: anytype, comptime sig: Signature) value.NativeFn {
    return wrap(func, false, sig);
}

/// A call with more positional arguments than `sig` names, or with keywords when it takes
/// none, is an ArgumentError before the native runs: natives that read their arguments
/// by hand used to drop the rest (`extrude(10, 5)` was `extrude(10)`). The keywords
/// themselves are checked by the native, which parses `sig.keywords`.
fn checkArguments(vm: *VM, name: []const u8, comptime sig: Signature, given: []const value.Value) error{RuntimeError}!void {
    const has_keywords = arguments.trailingKwargs(given) != null;
    const positional = given.len - @intFromBool(has_keywords);
    if (sig.rest == null and positional > sig.positional.len) {
        if (sig.positional.len == 0) return vm.fail(.ArgumentError, "{s} takes no positional arguments, got {d}", .{ name, positional });
        const names = comptime blk: {
            var list: []const u8 = "";
            for (sig.positional, 0..) |p, i| list = list ++ (if (i == 0) "" else ", ") ++ p;
            break :blk list;
        };
        const noun = if (sig.positional.len == 1) "argument" else "arguments";
        return vm.fail(.ArgumentError, "{s} takes at most {d} positional {s} ({s}), got {d}", .{ name, sig.positional.len, noun, names, positional });
    }
    if (has_keywords and sig.keywords.len == 0) return vm.fail(.ArgumentError, "{s} takes no keywords", .{name});
}

fn arityError(vm: *VM, name: []const u8, required: usize, max: ?usize, given: usize) error{RuntimeError} {
    const noun = if (required == 1) "argument" else "arguments";
    if (max == null) return vm.fail(.ArgumentError, "{s} expects at least {d} {s}, got {d}", .{ name, required, noun, given });
    if (max.? == required) return vm.fail(.ArgumentError, "{s} expects {d} {s}, got {d}", .{ name, required, noun, given });
    return vm.fail(.ArgumentError, "{s} expects {d} to {d} arguments, got {d}", .{ name, required, max.?, given });
}
