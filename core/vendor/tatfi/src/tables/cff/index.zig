const std = @import("std");
const parser = @import("../../parser.zig");
const utils = @import("../../utils.zig");

const Index = @This();

data: []const u8,
offsets: VarOffsets,

pub const default: Index = .{
    .data = &.{},
    .offsets = .{
        .data = &.{},
        .offset_size = .size1,
    },
};

pub fn len(
    self: Index,
) u32 {
    // Last offset points to the byte after the `Object data`. We should skip it.
    return self.offsets.len() -| 1;
}

pub fn get(
    self: Index,
    index: u32,
) ?[]const u8 {
    const next_index = std.math.add(u32, index, 1) catch return null; // make sure we do not overflow
    const start: usize = self.offsets.get(index) orelse return null;
    const end: usize = self.offsets.get(next_index) orelse return null;

    return utils.slice(self.data, .{ .start = start, .end = end }) catch null;
}

pub fn iterator(
    data: *const Index,
) Iterator {
    return .{ .data = data };
}

pub const Iterator = struct {
    data: *const Index,
    offset_index: u32 = 0,

    pub fn next(
        self: *Iterator,
    ) ?[]const u8 {
        if (self.offset_index == self.data.len()) return null;

        defer self.offset_index += 1;
        return self.data.get(self.offset_index);
    }
};

pub const VarOffsets = struct {
    data: []const u8,
    offset_size: OffsetSize,

    pub fn get(
        self: VarOffsets,
        index: u32,
    ) ?u32 {
        if (index >= self.len()) return null;
        const offset_size = @intFromEnum(self.offset_size);

        const start = @as(usize, index) * offset_size;
        var s = parser.Stream.new_at(self.data, start) catch return null;
        const n: u32 = switch (self.offset_size) {
            .size1 => s.read(u8) catch return null,
            .size2 => s.read(u16) catch return null,
            .size3 => s.read(u24) catch return null,
            .size4 => s.read(u32) catch return null,
        };

        // Offsets are offset by one byte in the font,
        // so we have to shift them back.
        return std.math.sub(u32, n, 1) catch null;
    }

    pub fn last(
        self: VarOffsets,
    ) ?u32 {
        if (self.len() == 0) return null;
        return self.get(self.len() - 1);
    }

    pub fn len(
        self: VarOffsets,
    ) u32 {
        return @as(u32, @truncate(self.data.len)) /
            @intFromEnum(self.offset_size);
    }
};

pub const OffsetSize = enum(u3) {
    size1 = 1,
    size2 = 2,
    size3 = 3,
    size4 = 4,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 1;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return switch (data[0]) {
                1 => .size1,
                2 => .size2,
                3 => .size3,
                4 => .size4,
                else => error.ParseFail,
            };
        }
    };
};

pub fn skip(
    T: type,
    s: *parser.Stream,
) parser.Error!void {
    const count: u32 = try s.read(T);
    if (count == 0 or count == std.math.maxInt(u32))
        return;

    const offset_size = try s.read(OffsetSize);
    const offsets_len = try std.math.mul(
        u32,
        count + 1,
        @intFromEnum(offset_size),
    );

    const offsets: VarOffsets = .{
        .data = try s.read_bytes(offsets_len),
        .offset_size = offset_size,
    };

    if (offsets.last()) |last_offset|
        s.advance(last_offset);
}

pub fn parse(
    T: type,
    s: *parser.Stream,
) parser.Error!Index {
    const count: u32 = try s.read(T);
    if (count == 0 or count == std.math.maxInt(u32))
        return .default;

    const offset_size = try s.read(OffsetSize);
    const offsets_len = try std.math.mul(
        u32,
        count + 1,
        @intFromEnum(offset_size),
    );

    const offsets: VarOffsets = .{
        .data = try s.read_bytes(offsets_len),
        .offset_size = offset_size,
    };

    // Last offset indicates a Data Index size.
    if (offsets.last()) |last_offset| {
        const data = try s.read_bytes(last_offset);
        return .{ .data = data, .offsets = offsets };
    } else return .default;
}

test "parse offset size" {
    const t = std.testing;
    {
        var s = parser.Stream.new(&.{0x00});
        try t.expectError(error.ParseFail, s.read(OffsetSize));
    }
    {
        var s = parser.Stream.new(&.{0x01});
        try t.expectEqual(OffsetSize.size1, s.read(OffsetSize));
    }
    {
        var s = parser.Stream.new(&.{0x05});
        try t.expectError(error.ParseFail, s.read(OffsetSize));
    }
}
