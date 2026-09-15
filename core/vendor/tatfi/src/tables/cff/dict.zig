const std = @import("std");
const parser = @import("../../parser.zig");

// Limits according to the Adobe Technical Note #5176, chapter 4 DICT Data.
const TWO_BYTE_OPERATOR_MARK: u8 = 12;
const FLOAT_STACK_LEN: usize = 64;
const END_OF_FLOAT_FLAG: u4 = 0xF;

const DictionaryParser = @This();

data: []const u8,
// The current offset.
offset: usize,
// Offset to the last operands start.
operands_offset: usize,
// Actual operands.
//
// While CFF can contain only i32 and f32 values, we have to store operands as f64
// since f32 cannot represent the whole i32 range.
// Meaning we have a choice of storing operands as f64 or as enum of i32/f32.
// In both cases the type size would be 8 bytes, so it's easier to simply use f64.
operands: []f64,
// An amount of operands in the `operands` array.
operands_len: u16,

pub fn new(
    data: []const u8,
    operands_buffer: []f64,
) DictionaryParser {
    return .{
        .data = data,
        .offset = 0,
        .operands_offset = 0,
        .operands = operands_buffer,
        .operands_len = 0,
    };
}

pub const Operator = struct { u16 };

pub fn parse_next(
    self: *DictionaryParser,
    T: type,
) ?T {
    std.debug.assert(@typeInfo(T).@"enum".mode == .nonexhaustive);
    var s = parser.Stream.new_at(self.data, self.offset) catch return null;
    self.operands_offset = self.offset;

    while (!s.at_end()) {
        const b = s.read(u8) catch return null;
        // 0...21 bytes are operators.
        if (is_dict_one_byte_op(b)) {
            var operator: u16 = b;

            // Check that operator is two byte long.
            if (b == TWO_BYTE_OPERATOR_MARK) {
                // Use a 1200 'prefix' to make two byte operators more readable.
                // 12 3 => 1203
                operator = @as(u16, 1200) + (s.read(u8) catch return null);
            }

            self.offset = s.offset;
            return @enumFromInt(operator);
        } else skip_number(b, &s) catch return null;
    }

    return null;
}

/// Parses operands of the current operator.
///
/// In the DICT structure, operands are defined before an operator.
/// So we are trying to find an operator first and the we can actually parse the operands.
///
/// Since this methods is pretty expensive and we do not care about most of the operators,
/// we can speed up parsing by parsing operands only for required operators.
///
/// We still have to "skip" operands during operators search (see `skip_number()`),
/// but it's still faster that a naive method.
pub fn parse_operands(
    self: *DictionaryParser,
) parser.Error!void {
    var s = try parser.Stream.new_at(self.data, self.operands_offset);
    self.operands_len = 0;
    while (!s.at_end()) {
        const b = try s.read(u8);
        // 0...21 bytes are operators.
        if (is_dict_one_byte_op(b)) {
            break;
        } else {
            const op = try parse_number(b, &s);
            self.operands[self.operands_len] = op;
            self.operands_len += 1;

            if (self.operands_len >= self.operands.len) break;
        }
    }
}

pub fn parse_number_method(
    self: *DictionaryParser,
    F: type,
) parser.Error!F {
    try self.parse_operands();
    if (self.operands_slice().len == 0) return error.ParseFail;

    return @floatCast(self.operands[0]);
}

pub fn parse_offset(
    self: *DictionaryParser,
) parser.Error!usize {
    try self.parse_operands();

    const operands = self.operands_slice();
    if (operands.len != 1) return error.ParseFail;

    return std.math.cast(usize, std.math.lossyCast(i32, operands[0])) orelse
        return error.ParseFail;
}

pub fn parse_range(
    self: *DictionaryParser,
) parser.Error!struct { usize, usize } {
    try self.parse_operands();
    const operands = self.operands_slice();
    if (operands.len != 2) return error.ParseFail;

    const len = std.math.cast(usize, std.math.lossyCast(i32, operands[0])) orelse
        return error.ParseFail;
    const start = std.math.cast(usize, std.math.lossyCast(i32, operands[1])) orelse
        return error.ParseFail;

    return .{ start, len };
}

pub fn operands_slice(
    self: DictionaryParser,
) []f64 {
    return self.operands[0..self.operands_len];
}

// One-byte CFF DICT Operators according to the
// Adobe Technical Note #5176, Appendix H CFF DICT Encoding.
pub fn is_dict_one_byte_op(
    b: u8,
) bool {
    return switch (b) {
        0...27 => true,
        28...30 => false, // numbers
        31 => true, // Reserved
        32...254 => false, // numbers
        255 => true, // Reserved
    };
}

// Just like `parse_number`, but doesn't actually parse the data.
pub fn skip_number(
    b0: u8,
    s: *parser.Stream,
) parser.Error!void {
    switch (b0) {
        28 => s.skip(u16),
        29 => s.skip(u32),
        30 => while (!s.at_end()) {
            const f = try s.read(FloatNibble);
            if (f.nibble1 == END_OF_FLOAT_FLAG or
                f.nibble2 == END_OF_FLOAT_FLAG) break;
        },
        32...246 => {},
        247...250 => s.skip(u8),
        251...254 => s.skip(u8),
        else => return error.ParseFail,
    }
}

// Adobe Technical Note #5177, Table 3 Operand Encoding
pub fn parse_number(
    b0: u8,
    s: *parser.Stream,
) parser.Error!f64 {
    switch (b0) {
        28 => {
            const n: i32 = try s.read(i16);
            return @floatFromInt(n);
        },
        29 => {
            const n = try s.read(i32);
            return @floatFromInt(n);
        },
        30 => return parse_float(s) catch return error.ParseFail,
        32...246 => {
            const n: i32 = @as(i32, b0) - 139;
            return @floatFromInt(n);
        },
        247...250 => {
            const b1: i32 = try s.read(u8);
            const n: i32 = (@as(i32, b0) - 247) * 256 + b1 + 108;
            return @floatFromInt(n);
        },
        251...254 => {
            const b1: i32 = try s.read(u8);
            const n: i32 = -(@as(i32, b0) - 251) * 256 - b1 - 108;
            return @floatFromInt(n);
        },
        else => return error.ParseFail,
    }
}

const FloatNibble = packed struct(u8) {
    nibble2: u4,
    nibble1: u4,
};

fn parse_float(
    s: *parser.Stream,
) !f64 {
    var buffer: [FLOAT_STACK_LEN]u8 = undefined;
    var data: std.ArrayList(u8) = .initBuffer(&buffer);

    while (s.read(FloatNibble)) |f| {
        try parse_float_nibble(f.nibble1, &data) orelse break;
        try parse_float_nibble(f.nibble2, &data) orelse break;
    } else |e| return e;

    return try std.fmt.parseFloat(f64, data.items);
}

// Adobe Technical Note #5176, Table 5 Nibble Definitions
fn parse_float_nibble(
    nibble: u4,
    data: *std.ArrayList(u8),
) !?void {
    switch (nibble) {
        0...9 => try data.appendBounded('0' + @as(u8, nibble)),
        10 => try data.appendBounded('.'),
        11 => try data.appendBounded('E'),
        12 => {
            try data.appendBounded('E');
            try data.appendBounded('-');
        },
        13 => return error.OutOfMemory,
        14 => try data.appendBounded('-'),
        END_OF_FLOAT_FLAG => return null,
    }
}

const t = std.testing;

test "parse float" {
    {
        var s = parser.Stream.new(&.{ 0xE2, 0xA2, 0x5F });
        try t.expectEqual(try parse_float(&s), -2.25);
    }
    {
        var s = parser.Stream.new(&.{ 0x0A, 0x14, 0x05, 0x41, 0xC3, 0xFF });
        try t.expectEqual(try parse_float(&s), 0.140541E-3);
    }
}

test "parse dict number" {
    {
        var s = parser.Stream.new(&.{0x7C});
        try t.expectEqual(try parse_number(0xFA, &s), 1000);
    }
    {
        var s = parser.Stream.new(&.{0x7C});
        try t.expectEqual(try parse_number(0xFE, &s), -1000);
    }
    {
        var s = parser.Stream.new(&.{ 0x27, 0x10 });
        try t.expectEqual(try parse_number(0x1C, &s), 10000);
    }
    {
        var s = parser.Stream.new(&.{ 0xD8, 0xF0 });
        try t.expectEqual(try parse_number(0x1C, &s), -10000);
    }
    {
        var s = parser.Stream.new(&.{ 0x00, 0x01, 0x86, 0xA0 });
        try t.expectEqual(try parse_number(0x1D, &s), 100000);
    }
    {
        var s = parser.Stream.new(&.{ 0xFF, 0xFE, 0x79, 0x60 });
        try t.expectEqual(try parse_number(0x1D, &s), -100000);
    }
}
