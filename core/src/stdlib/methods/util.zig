const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const limits = @import("../../core/limits.zig");

/// Converts a script number to integer type `I`, truncating toward zero (the
/// historical @intFromFloat semantics). @intFromFloat on NaN/inf/out-of-range
/// input panics in Debug and is UB in ReleaseFast, so every user-supplied
/// count must go through this instead.
pub fn checkedInt(comptime I: type, vm: *VM, val: f64, name: []const u8) !I {
    const t = @trunc(val);
    const lo: f64 = @floatFromInt(std.math.minInt(I));
    const hi: f64 = @floatFromInt(std.math.maxInt(I));
    if (!std.math.isFinite(val) or t < lo or t > hi) {
        vm.reportError("ValueError: '{s}' must be a finite integer in [{d}, {d}], got {d}.\n", .{ name, std.math.minInt(I), std.math.maxInt(I), val });
        return error.RuntimeError;
    }
    return @intFromFloat(t);
}

/// Validates a tessellation count (segments/sides/slices). 0 means "auto" for
/// callers that resolve it from the engine config afterwards.
pub fn requireSegmentCount(vm: *VM, segs: i32, name: []const u8) !void {
    if (segs < 0 or segs > limits.MAX_SEGMENTS) {
        vm.reportError("ValueError: '{s}' must be between 0 and {d}, got {d}.\n", .{ name, limits.MAX_SEGMENTS, segs });
        return error.RuntimeError;
    }
}

/// Clamps an auto-computed segment count (from ManifoldConfig.getSegments) to
/// MAX_SEGMENTS; auto counts are not the user's fault, so we clamp rather than error.
pub fn clampSegments(segs: u32) i32 {
    return @intCast(@min(segs, @as(u32, @intCast(limits.MAX_SEGMENTS))));
}

/// Parses positional arguments and/or kwargs map into a [x, y, z] struct.
pub fn parseVec3(args: []const value.Value, default_val: f64) !struct { f64, f64, f64 } {
    var pos_count = args.len;
    var kwargs: ?*value.ObjMap = null;

    if (args.len > 0 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        kwargs = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
        pos_count -= 1;
    }

    if (pos_count > 0 and !args[0].isNumber()) return error.RuntimeError;
    if (pos_count > 1 and !args[1].isNumber()) return error.RuntimeError;
    if (pos_count > 2 and !args[2].isNumber()) return error.RuntimeError;

    var x = if (pos_count > 0) args[0].asNumber() else default_val;
    var y = if (pos_count > 1) args[1].asNumber() else default_val;
    var z = if (pos_count > 2) args[2].asNumber() else default_val;

    if (kwargs) |map| {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                const k_str = if (k.asObj().obj_type == .string)
                    @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                else
                    @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

                const v = entry.value_ptr.*;
                if (v.isNumber()) {
                    if (std.mem.eql(u8, k_str, "x")) x = v.asNumber();
                    if (std.mem.eql(u8, k_str, "y")) y = v.asNumber();
                    if (std.mem.eql(u8, k_str, "z")) z = v.asNumber();
                }
            }
        }
    }
    return .{ x, y, z };
}

/// Universal Comptime Kwarg Parser to Eliminate Boilerplate
/// Integer fields are range-checked via checkedInt (reports the kwarg name).
pub fn parseKwargs(comptime T: type, vm: *VM, map: *value.ObjMap) !T {
    var result: T = .{};
    var it = map.map.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
            const k_str = if (k.asObj().obj_type == .string)
                @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
            else
                @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

            const v = entry.value_ptr.*;

            // Unroll loop at compile-time
            inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, i| {
                const field_type = @typeInfo(T).@"struct".field_types[i];
                if (std.mem.eql(u8, k_str, field_name)) {
                    if (field_type == f64 or field_type == ?f64) {
                        if (v.isNumber()) @field(result, field_name) = v.asNumber();
                    } else if (field_type == i32 or field_type == ?i32) {
                        if (v.isNumber()) @field(result, field_name) = try checkedInt(i32, vm, v.asNumber(), field_name);
                    } else if (field_type == bool or field_type == ?bool) {
                        if (v.isBool()) @field(result, field_name) = v.asBool();
                    } else if (field_type == []const u8 or field_type == ?[]const u8) {
                        if (v.isString()) @field(result, field_name) = v.asString().chars else if (v.isSymbol()) @field(result, field_name) = v.asSymbol().chars;
                    }
                }
            }
        }
    }
    return result;
}

/// Helper for retrieving isolated aliases
pub fn getKey(map: *value.ObjMap, target: []const u8) ?value.Value {
    var it = map.map.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
            const k_str = if (k.asObj().obj_type == .string)
                @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
            else
                @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;
            if (std.mem.eql(u8, k_str, target)) return entry.value_ptr.*;
        }
    }
    return null;
}
