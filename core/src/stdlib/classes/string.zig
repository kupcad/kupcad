//! The String class's methods (`methods`): `length`, case changes, `split`, `chars`,
//! `replace`, `reverse`, padding (`rjust`, `ljust`), conversions such as `to_f` and
//! `to_sym`, `trim` (`strip`) and substring, prefix and suffix tests. Each returns a new
//! String, as Strings are immutable values.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const HandleScope = @import("../../vm/scope.zig").HandleScope;
const common = @import("common.zig");
const limits = @import("../../core/limits.zig");

/// String.new(text = "") -> the text (Strings are immutable values)
pub fn stringNew(vm: *VM, class: value.Value, text: ?*value.ObjString) !value.Value {
    _ = class;
    if (text) |t| return value.Value.initObj(&t.obj);
    return vm.allocateString("");
}

/// String#length / String#size
pub fn stringLength(vm: *VM, str: *value.ObjString) !value.Value {
    _ = vm;
    const len = std.unicode.utf8CountCodepoints(str.chars) catch str.chars.len;
    return value.Value.initNumber(@floatFromInt(len));
}

/// String#upcase
pub fn stringUpcase(vm: *VM, str: *value.ObjString) !value.Value {
    const new_str = try vm.gc.trackingAllocator().alloc(u8, str.chars.len);
    for (str.chars, 0..) |c, i| new_str[i] = std.ascii.toUpper(c);

    return try vm.allocateStringTakeOwnership(new_str);
}

/// String#downcase
pub fn stringDowncase(vm: *VM, str: *value.ObjString) !value.Value {
    const new_str = try vm.gc.trackingAllocator().alloc(u8, str.chars.len);
    for (str.chars, 0..) |c, i| new_str[i] = std.ascii.toLower(c);

    return try vm.allocateStringTakeOwnership(new_str);
}

/// String#split(delim)
pub fn stringSplit(vm: *VM, str: *value.ObjString, delim_obj: *value.ObjString) !value.Value {
    const delim_str = delim_obj.chars;

    var scope = HandleScope.init(vm);
    defer scope.deinit();

    const arr_obj = try scope.array();

    // Into its characters, as in Ruby (an empty delimiter tripped an assertion).
    if (delim_str.len == 0) return charsInto(vm, str, arr_obj, "split");

    var iter = std.mem.splitSequence(u8, str.chars, delim_str);
    while (iter.next()) |part| {
        const part_val = try vm.allocateString(part);
        try arr_obj.items.append(vm.gc.trackingAllocator(), part_val);
    }
    return value.Value.initObj(&arr_obj.obj);
}

/// String#chars: its characters, each a String (`split("")`).
pub fn stringChars(vm: *VM, str: *value.ObjString) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    return charsInto(vm, str, try scope.array(), "chars");
}

/// `str`'s characters appended to `arr` (rooted by the caller), which is the result; a
/// String that isn't UTF-8 is a ValueError naming `method`.
fn charsInto(vm: *VM, str: *value.ObjString, arr: *value.ObjArray, comptime method: []const u8) !value.Value {
    var chars = (try utf8View(vm, str, method)).iterator();
    while (chars.nextCodepointSlice()) |ch| {
        const ch_val = try vm.allocateString(ch);
        try arr.items.append(vm.gc.trackingAllocator(), ch_val);
    }
    return value.Value.initObj(&arr.obj);
}

fn utf8View(vm: *VM, str: *const value.ObjString, comptime method: []const u8) !std.unicode.Utf8View {
    return std.unicode.Utf8View.init(str.chars) catch vm.fail(.ValueError, method ++ ": the String isn't valid UTF-8", .{});
}

/// String#include?(other): whether `other` occurs in it.
pub fn stringInclude(vm: *VM, str: *value.ObjString, other: *value.ObjString) !value.Value {
    _ = vm;
    return value.Value.initBool(std.mem.find(u8, str.chars, other.chars) != null);
}

/// String#reverse: its characters in the opposite order.
pub fn stringReverse(vm: *VM, str: *value.ObjString) !value.Value {
    var chars = (try utf8View(vm, str, "reverse")).iterator();
    const out = try vm.gc.trackingAllocator().alloc(u8, str.chars.len);
    errdefer vm.gc.trackingAllocator().free(out);
    var end = out.len;
    while (chars.nextCodepointSlice()) |ch| {
        end -= ch.len;
        @memcpy(out[end..][0..ch.len], ch);
    }
    return vm.allocateStringTakeOwnership(out);
}

/// String#rjust(width, pad = " "): the String `width` characters long, `pad` repeated
/// before it (cut to fit); the String itself when it is that long already.
pub fn stringRjust(vm: *VM, str: *value.ObjString, width: f64, pad: ?*value.ObjString) !value.Value {
    return justify(vm, str, width, pad, .right, "rjust");
}

/// String#ljust(width, pad = " "): the String `width` characters long, `pad` repeated
/// after it (cut to fit); the String itself when it is that long already.
pub fn stringLjust(vm: *VM, str: *value.ObjString, width: f64, pad: ?*value.ObjString) !value.Value {
    return justify(vm, str, width, pad, .left, "ljust");
}

fn justify(vm: *VM, str: *value.ObjString, width_num: f64, pad_obj: ?*value.ObjString, comptime side: enum { left, right }, comptime method: []const u8) !value.Value {
    if (!std.math.isFinite(width_num)) return vm.fail(.ArgumentError, method ++ ": the width is a finite number, got {f}", .{value.fmtNumber(width_num)});
    const pad = if (pad_obj) |p| p.chars else " ";
    if (pad.len == 0) return vm.fail(.ArgumentError, method ++ ": the padding is empty", .{});
    const pad_view = std.unicode.Utf8View.init(pad) catch return vm.fail(.ValueError, method ++ ": the padding isn't valid UTF-8", .{});
    const len = std.unicode.utf8CountCodepoints(str.chars) catch str.chars.len;
    const width = @trunc(width_num);
    if (width <= @as(f64, @floatFromInt(len))) return value.Value.initObj(&str.obj);
    if (width - @as(f64, @floatFromInt(len)) > @as(f64, @floatFromInt(limits.MAX_STRING_PAD))) {
        return vm.fail(.RangeError, method ++ ": a width of {f} would add more than {d} characters", .{ value.fmtNumber(width_num), limits.MAX_STRING_PAD });
    }
    const missing: usize = @intFromFloat(width - @as(f64, @floatFromInt(len)));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(vm.gc.trackingAllocator());
    if (side == .left) try out.appendSlice(vm.gc.trackingAllocator(), str.chars);
    var pad_chars = pad_view.iterator();
    for (0..missing) |_| {
        const ch = pad_chars.nextCodepointSlice() orelse blk: {
            pad_chars = pad_view.iterator();
            break :blk pad_chars.nextCodepointSlice().?;
        };
        try out.appendSlice(vm.gc.trackingAllocator(), ch);
    }
    if (side == .right) try out.appendSlice(vm.gc.trackingAllocator(), str.chars);
    return vm.allocateStringTakeOwnership(try out.toOwnedSlice(vm.gc.trackingAllocator()));
}

/// String#replace(target, replacement): every `target` replaced. An empty one is found before
/// each character and at the end, as in Ruby (`"abc".replace("", "-")` is "-a-b-c-"): it
/// tripped std.mem's assertion that a needle isn't empty.
pub fn stringReplace(vm: *VM, str: *value.ObjString, target_obj: *value.ObjString, replace_obj: *value.ObjString) !value.Value {
    const t_str = target_obj.chars;
    const r_str = replace_obj.chars;
    if (t_str.len == 0) return replaceEmpty(vm, str, r_str);

    const replaced = try std.mem.replaceOwned(u8, vm.gc.trackingAllocator(), str.chars, t_str, r_str);
    return try vm.allocateStringTakeOwnership(replaced);
}

/// `str` with `replacement` before each of its characters and after the last.
fn replaceEmpty(vm: *VM, str: *value.ObjString, replacement: []const u8) !value.Value {
    const allocator = vm.gc.trackingAllocator();
    var chars = (try utf8View(vm, str, "replace")).iterator();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, replacement);
    while (chars.nextCodepointSlice()) |ch| {
        try out.appendSlice(allocator, ch);
        try out.appendSlice(allocator, replacement);
    }
    return vm.allocateStringTakeOwnership(try out.toOwnedSlice(allocator));
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
    .{ .name = "chars", .func = common.wrapMethod(stringChars) },
    .{ .name = "reverse", .func = common.wrapMethod(stringReverse) },
    .{ .name = "include?", .func = common.wrapMethod(stringInclude) },
    .{ .name = "rjust", .func = common.wrapMethod(stringRjust) },
    .{ .name = "ljust", .func = common.wrapMethod(stringLjust) },
    .{ .name = "replace", .func = common.wrapMethod(stringReplace) },
    .{ .name = "to_f", .func = common.wrapMethod(stringToF) },
    .{ .name = "to_i", .func = common.wrapMethod(stringToI) },
    .{ .name = "trim", .func = common.wrapMethod(stringTrim) },
    .{ .name = "strip", .func = common.wrapMethod(stringTrim) },
    .{ .name = "starts_with?", .func = common.wrapMethod(stringStartsWith) },
    .{ .name = "start_with?", .func = common.wrapMethod(stringStartsWith) },
    .{ .name = "ends_with?", .func = common.wrapMethod(stringEndsWith) },
    .{ .name = "end_with?", .func = common.wrapMethod(stringEndsWith) },
    .{ .name = "to_sym", .func = common.wrapMethod(stringToSym) },
    .{ .name = "to_s", .func = common.wrapMethod(stringToS) },
};
