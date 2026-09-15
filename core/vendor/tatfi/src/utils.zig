const std = @import("std");

// [ARS] NUMERICAL STUFF
pub inline fn f32_to_i32(v: f32) ?i32 {
    // [ARS] this method is a bastardization of the of source
    const MIN: f32 = @floatFromInt(std.math.minInt(i32));

    // [ARs] https://ziggit.dev/t/determining-lower-upper-bound-for-safe-conversion-from-f32-to-i32/3764/3?u=asibahi
    const MAX_P1: f32 = @floatFromInt(2147483520);

    if (v >= MIN and v <= MAX_P1)
        return @intFromFloat(v)
    else
        return null;
}

pub inline fn f32_to_i16(v: f32) ?i16 {
    const i = f32_to_i32(v) orelse return null;
    return std.math.cast(i16, i);
}

pub inline fn f32_to_u16(v: f32) ?u16 {
    const i = f32_to_i32(v) orelse return null;
    return std.math.cast(u16, i);
}

pub inline fn f32_to_u8(v: f32) ?u8 {
    const i = f32_to_i32(v) orelse return null;
    return std.math.cast(u8, i);
}

pub fn f64_to_usize(f: f64) ?usize {
    const i = std.math.lossyCast(i64, f);
    return std.math.cast(usize, i);
}

/// Internal usage.
///
/// `range` either an int or .{ start, length }
pub fn slice(
    data: []const u8,
    range: anytype,
) error{DataError}![]const u8 {
    const T = @TypeOf(range);
    const start, const length, const end = switch (@typeInfo(T)) {
        .int => .{ range, null, null },
        .@"struct" => |s| if (s.is_tuple)
            .{ range[0], range[1], null }
        else
            .{ range.start, null, range.end },
        else => unreachable,
    };

    if (start > data.len) return error.DataError;

    if (@TypeOf(length) != @TypeOf(null)) { // weirdness
        const e = std.math.add(usize, start, length) catch return error.DataError;
        if (e > data.len) return error.DataError;

        return data[start..e];
    } else if (@TypeOf(end) != @TypeOf(null)) {
        if (end > data.len or end < start) return error.DataError;
        return data[start..end];
    } else return data[start..];
}
