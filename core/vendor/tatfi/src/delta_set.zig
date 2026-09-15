// DeltaSetIndexMap

const Self = @This();

const std = @import("std");
const parser = @import("parser.zig");

data: []const u8,

pub fn new(data: []const u8) Self {
    return .{ .data = data };
}

pub fn map(
    self: Self,
    index: u32,
) ?struct { u16, u16 } {
    return self.map_inner(index) catch null;
}

fn map_inner(
    self: Self,
    index: u32,
) parser.Error!struct { u16, u16 } {
    var s = parser.Stream.new(self.data);
    const format = try s.read(u8);
    const entry_format = try s.read(u8);

    const map_count: u32 = if (format == 0) try s.read(u16) else try s.read(u32);

    if (map_count == 0) return error.ParseFail;

    // 'If a given glyph ID is greater than mapCount-1, then the last entry is used.'
    //
    const idx = std.math.clamp(index, 0, map_count - 1);

    const entry_size = ((entry_format >> 4) & 3) + 1;
    const inner_index_bit_count: u5 = @truncate((entry_format & 0xF) + 1);

    s.advance(entry_size * idx);

    var n: u32 = 0;
    for (try s.read_bytes(entry_size)) |b| n = (n << 8) + b;

    const outer_index_32 = n >> inner_index_bit_count;
    const outer_index = std.math.cast(u16, outer_index_32) orelse return error.ParseFail;

    const inner_index_32 = n & ((@as(u32, 1) << inner_index_bit_count) - 1);
    const inner_index = std.math.cast(u16, inner_index_32) orelse return error.ParseFail;

    return .{ outer_index, inner_index };
}
