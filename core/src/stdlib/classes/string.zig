const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

pub fn stringLength(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 0, args);
    // Safely count actual Unicode characters, fallback to raw byte length if invalid UTF-8
    const len = std.unicode.utf8CountCodepoints(ctx.str.chars) catch ctx.str.chars.len;
    return value.Value.initNumber(@floatFromInt(len));
}

pub fn stringUpcase(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 0, args);
    const new_str = try ctx.vm.allocator.alloc(u8, ctx.str.chars.len);
    errdefer ctx.vm.allocator.free(new_str); // Free ONLY if GC allocation fails

    for (ctx.str.chars, 0..) |c, i| new_str[i] = std.ascii.toUpper(c);

    return try ctx.vm.allocateStringTakeOwnership(new_str);
}

pub fn stringDowncase(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 0, args);
    const new_str = try ctx.vm.allocator.alloc(u8, ctx.str.chars.len);
    errdefer ctx.vm.allocator.free(new_str);

    for (ctx.str.chars, 0..) |c, i| new_str[i] = std.ascii.toLower(c);

    return try ctx.vm.allocateStringTakeOwnership(new_str);
}

pub fn stringSplit(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 1, args);
    const delim_val = args[0];
    if (!delim_val.isObject() or delim_val.asObj().obj_type != .string) return error.RuntimeError;
    const delim_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", delim_val.asObj()))).chars;

    const arr_obj = try ctx.vm.gc.allocateArray(ctx.vm);
    ctx.vm.push(value.Value.initObj(&arr_obj.obj));
    defer _ = ctx.vm.pop();

    var iter = std.mem.splitSequence(u8, ctx.str.chars, delim_str);
    while (iter.next()) |part| {
        const part_val = try ctx.vm.allocateString(part);
        ctx.vm.retainValue(part_val);
        try arr_obj.items.append(ctx.vm.allocator, part_val);
    }
    return value.Value.initObj(&arr_obj.obj);
}

pub fn stringReplace(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 2, args);
    const target_val = args[0];
    const replace_val = args[1];

    if (!target_val.isObject() or target_val.asObj().obj_type != .string) return error.RuntimeError;
    if (!replace_val.isObject() or replace_val.asObj().obj_type != .string) return error.RuntimeError;

    const t_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", target_val.asObj()))).chars;
    const r_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", replace_val.asObj()))).chars;

    const replaced = try std.mem.replaceOwned(u8, ctx.vm.allocator, ctx.str.chars, t_str, r_str);
    errdefer ctx.vm.allocator.free(replaced);

    return try ctx.vm.allocateStringTakeOwnership(replaced);
}

pub fn stringToF(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 0, args);
    const float_val = std.fmt.parseFloat(f64, ctx.str.chars) catch return value.Value.initNil();
    return value.Value.initNumber(float_val);
}

pub fn stringToI(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 0, args);
    const int_val = std.fmt.parseInt(i64, ctx.str.chars, 10) catch return value.Value.initNil();
    return value.Value.initNumber(@floatFromInt(int_val));
}

pub fn stringTrim(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 0, args);
    const trimmed = std.mem.trim(u8, ctx.str.chars, " \t\r\n");
    return try ctx.vm.allocateString(trimmed);
}

pub fn stringStartsWith(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 1, args);
    if (!args[0].isObject() or args[0].asObj().obj_type != .string) return error.RuntimeError;
    const prefix = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", args[0].asObj()))).chars;
    return value.Value.initBool(std.mem.startsWith(u8, ctx.str.chars, prefix));
}

pub fn stringEndsWith(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 1, args);
    if (!args[0].isObject() or args[0].asObj().obj_type != .string) return error.RuntimeError;
    const suffix = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", args[0].asObj()))).chars;
    return value.Value.initBool(std.mem.endsWith(u8, ctx.str.chars, suffix));
}

// String to Symbol
pub fn stringToSym(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 0, args);
    return try ctx.vm.allocateSymbol(ctx.str.chars);
}

// String to String (Identity)
pub fn stringToS(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapString(vm_opaque, arg_count, 0, args);
    return ctx.receiver;
}

pub const methods = [_]common.MethodDef{
    .{ .name = "upcase", .func = stringUpcase },
    .{ .name = "downcase", .func = stringDowncase },
    .{ .name = "split", .func = stringSplit },
    .{ .name = "replace", .func = stringReplace },
    .{ .name = "to_f", .func = stringToF },
    .{ .name = "to_i", .func = stringToI },
    .{ .name = "trim", .func = stringTrim },
    .{ .name = "starts_with?", .func = stringStartsWith },
    .{ .name = "ends_with?", .func = stringEndsWith },
    .{ .name = "to_sym", .func = stringToSym },
    .{ .name = "to_s", .func = stringToS },
};
