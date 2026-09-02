const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const common = @import("common.zig");

/// String#length / String#size
pub fn stringLength(vm: *VM, str: *value.ObjString) !value.Value {
    _ = vm;
    const len = std.unicode.utf8CountCodepoints(str.chars) catch str.chars.len;
    return value.Value.initNumber(@floatFromInt(len));
}

/// String#upcase
pub fn stringUpcase(vm: *VM, str: *value.ObjString) !value.Value {
    const new_str = try vm.allocator.alloc(u8, str.chars.len);
    errdefer vm.allocator.free(new_str);

    for (str.chars, 0..) |c, i| new_str[i] = std.ascii.toUpper(c);

    return try vm.allocateStringTakeOwnership(new_str);
}

/// String#downcase
pub fn stringDowncase(vm: *VM, str: *value.ObjString) !value.Value {
    const new_str = try vm.allocator.alloc(u8, str.chars.len);
    errdefer vm.allocator.free(new_str);

    for (str.chars, 0..) |c, i| new_str[i] = std.ascii.toLower(c);

    return try vm.allocateStringTakeOwnership(new_str);
}

/// String#split(delim)
pub fn stringSplit(vm: *VM, str: *value.ObjString, delim_obj: *value.ObjString) !value.Value {
    const delim_str = delim_obj.chars;

    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const arr_obj = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&arr_obj.obj));

    var iter = std.mem.splitSequence(u8, str.chars, delim_str);
    while (iter.next()) |part| {
        const part_val = try vm.allocateString(part);
        try arr_obj.items.append(vm.allocator, part_val);
    }
    return value.Value.initObj(&arr_obj.obj);
}

/// String#replace(target, replacement)
pub fn stringReplace(vm: *VM, str: *value.ObjString, target_obj: *value.ObjString, replace_obj: *value.ObjString) !value.Value {
    const t_str = target_obj.chars;
    const r_str = replace_obj.chars;

    const replaced = try std.mem.replaceOwned(u8, vm.allocator, str.chars, t_str, r_str);
    errdefer vm.allocator.free(replaced);

    return try vm.allocateStringTakeOwnership(replaced);
}

/// String#to_f
pub fn stringToF(vm: *VM, str: *value.ObjString) !value.Value {
    _ = vm;
    const float_val = std.fmt.parseFloat(f64, str.chars) catch return value.Value.initNil();
    return value.Value.initNumber(float_val);
}

/// String#to_i
pub fn stringToI(vm: *VM, str: *value.ObjString) !value.Value {
    _ = vm;
    const int_val = std.fmt.parseInt(i64, str.chars, 10) catch return value.Value.initNil();
    return value.Value.initNumber(@floatFromInt(int_val));
}

/// String#trim
pub fn stringTrim(vm: *VM, str: *value.ObjString) !value.Value {
    const trimmed = std.mem.trim(u8, str.chars, " \t\r\n");
    return try vm.allocateString(trimmed);
}

/// String#starts_with?(prefix)
pub fn stringStartsWith(vm: *VM, str: *value.ObjString, prefix_obj: *value.ObjString) !value.Value {
    _ = vm;
    return value.Value.initBool(std.mem.startsWith(u8, str.chars, prefix_obj.chars));
}

/// String#ends_with?(suffix)
pub fn stringEndsWith(vm: *VM, str: *value.ObjString, suffix_obj: *value.ObjString) !value.Value {
    _ = vm;
    return value.Value.initBool(std.mem.endsWith(u8, str.chars, suffix_obj.chars));
}

/// String#to_sym
pub fn stringToSym(vm: *VM, str: *value.ObjString) !value.Value {
    return try vm.allocateSymbol(str.chars);
}

/// String#to_s (Identity)
pub fn stringToS(vm: *VM, str: *value.ObjString) !value.Value {
    _ = vm;
    return value.Value.initObj(&str.obj);
}

/// String class method dispatch table
pub const methods = [_]common.MethodDef{
    .{ .name = "length", .func = common.wrapMethod(stringLength) },
    .{ .name = "size", .func = common.wrapMethod(stringLength) },
    .{ .name = "upcase", .func = common.wrapMethod(stringUpcase) },
    .{ .name = "downcase", .func = common.wrapMethod(stringDowncase) },
    .{ .name = "split", .func = common.wrapMethod(stringSplit) },
    .{ .name = "replace", .func = common.wrapMethod(stringReplace) },
    .{ .name = "to_f", .func = common.wrapMethod(stringToF) },
    .{ .name = "to_i", .func = common.wrapMethod(stringToI) },
    .{ .name = "trim", .func = common.wrapMethod(stringTrim) },
    .{ .name = "starts_with?", .func = common.wrapMethod(stringStartsWith) },
    .{ .name = "ends_with?", .func = common.wrapMethod(stringEndsWith) },
    .{ .name = "to_sym", .func = common.wrapMethod(stringToSym) },
    .{ .name = "to_s", .func = common.wrapMethod(stringToS) },
};
