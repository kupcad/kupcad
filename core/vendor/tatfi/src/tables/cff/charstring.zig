const std = @import("std");
const cff = @import("../cff.zig");
const parser = @import("../../parser.zig");

const Self = @This();

stack: std.ArrayList(f32),
builder: *cff.Builder,
x: f32,
y: f32,
has_move_to: bool,
is_first_move_to: bool,
width_only: bool, // Exit right after the glyph width is parsed.

pub fn parse_move_to(
    self: *Self,
    offset: usize,
) cff.Error!void {
    // dx1 dy1

    if (self.stack.items.len != offset + 2) return error.InvalidArgumentsStackLength;

    if (self.is_first_move_to)
        self.is_first_move_to = false
    else
        self.builder.close();

    self.has_move_to = true;

    self.x += self.stack.items[offset + 0];
    self.y += self.stack.items[offset + 1];
    self.builder.move_to(self.x, self.y);

    self.stack.clearRetainingCapacity();
}

pub fn parse_horizontal_move_to(
    self: *Self,
    offset: usize,
) cff.Error!void {
    // dx1

    if (self.stack.items.len != offset + 1) return error.InvalidArgumentsStackLength;

    if (self.is_first_move_to)
        self.is_first_move_to = false
    else
        self.builder.close();

    self.has_move_to = true;

    self.x += self.stack.items[offset];
    self.builder.move_to(self.x, self.y);

    self.stack.clearRetainingCapacity();
}

pub fn parse_vertical_move_to(
    self: *Self,
    offset: usize,
) cff.Error!void {
    // dy1

    if (self.stack.items.len != offset + 1) return error.InvalidArgumentsStackLength;

    if (self.is_first_move_to)
        self.is_first_move_to = false
    else
        self.builder.close();

    self.has_move_to = true;

    self.y += self.stack.items[offset];
    self.builder.move_to(self.x, self.y);

    self.stack.clearRetainingCapacity();
}

pub fn parse_line_to(
    self: *Self,
) cff.Error!void {
    // {dxa dya}+

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len & 1 != 0) return error.InvalidArgumentsStackLength;

    var i: usize = 0;
    while (i < self.stack.items.len) {
        self.x += self.stack.items[i + 0];
        self.y += self.stack.items[i + 1];
        self.builder.line_to(self.x, self.y);
        i += 2;
    }

    self.stack.clearRetainingCapacity();
}

pub fn parse_horizontal_line_to(
    self: *Self,
) cff.Error!void {
    // dx1 {dya dxb}*
    //     {dxa dyb}+

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len == 0) return error.InvalidArgumentsStackLength;

    var i: usize = 0;
    while (i < self.stack.items.len) {
        self.x += self.stack.items[i];
        i += 1;
        self.builder.line_to(self.x, self.y);

        if (i == self.stack.items.len) break;

        self.y += self.stack.items[i];
        i += 1;
        self.builder.line_to(self.x, self.y);
    }

    self.stack.clearRetainingCapacity();
}

pub fn parse_vertical_line_to(
    self: *Self,
) cff.Error!void {
    // dy1 {dxa dyb}*
    //     {dya dxb}+

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len == 0) return error.InvalidArgumentsStackLength;

    var i: usize = 0;
    while (i < self.stack.items.len) {
        self.y += self.stack.items[i];
        i += 1;
        self.builder.line_to(self.x, self.y);

        if (i == self.stack.items.len) break;

        self.x += self.stack.items[i];
        i += 1;
        self.builder.line_to(self.x, self.y);
    }

    self.stack.clearRetainingCapacity();
}

pub fn parse_curve_to(
    self: *Self,
) cff.Error!void {
    // {dxa dya dxb dyb dxc dyc}+

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len % 6 != 0) return error.InvalidArgumentsStackLength;

    var i: usize = 0;
    while (i < self.stack.items.len) {
        const x1 = self.x + self.stack.items[i + 0];
        const y1 = self.y + self.stack.items[i + 1];
        const x2 = x1 + self.stack.items[i + 2];
        const y2 = y1 + self.stack.items[i + 3];
        self.x = x2 + self.stack.items[i + 4];
        self.y = y2 + self.stack.items[i + 5];

        self.builder.curve_to(x1, y1, x2, y2, self.x, self.y);
        i += 6;
    }

    self.stack.clearRetainingCapacity();
}

pub fn parse_curve_line(
    self: *Self,
) cff.Error!void {
    // {dxa dya dxb dyb dxc dyc}+ dxd dyd

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len < 8 or
        (self.stack.items.len - 2) % 6 != 0) return error.InvalidArgumentsStackLength;

    var i: usize = 0;
    while (i < self.stack.items.len - 2) {
        const x1 = self.x + self.stack.items[i + 0];
        const y1 = self.y + self.stack.items[i + 1];
        const x2 = x1 + self.stack.items[i + 2];
        const y2 = y1 + self.stack.items[i + 3];
        self.x = x2 + self.stack.items[i + 4];
        self.y = y2 + self.stack.items[i + 5];

        self.builder.curve_to(x1, y1, x2, y2, self.x, self.y);
        i += 6;
    }

    self.x += self.stack.items[i + 0];
    self.y += self.stack.items[i + 1];
    self.builder.line_to(self.x, self.y);

    self.stack.clearRetainingCapacity();
}

pub fn parse_line_curve(
    self: *Self,
) cff.Error!void {
    // {dxa dya}+ dxb dyb dxc dyc dxd dyd

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len < 8 or
        self.stack.items.len & 1 != 0) return error.InvalidArgumentsStackLength;

    var i: usize = 0;
    while (i < self.stack.items.len - 6) {
        self.x += self.stack.items[i + 0];
        self.y += self.stack.items[i + 1];

        self.builder.line_to(self.x, self.y);
        i += 2;
    }

    const x1 = self.x + self.stack.items[i + 0];
    const y1 = self.y + self.stack.items[i + 1];
    const x2 = x1 + self.stack.items[i + 2];
    const y2 = y1 + self.stack.items[i + 3];
    self.x = x2 + self.stack.items[i + 4];
    self.y = y2 + self.stack.items[i + 5];
    self.builder.curve_to(x1, y1, x2, y2, self.x, self.y);

    self.stack.clearRetainingCapacity();
}

pub fn parse_hh_curve_to(
    self: *Self,
) cff.Error!void {
    // dy1? {dxa dxb dyb dxc}+

    if (!self.has_move_to) return error.MissingMoveTo;

    var i: usize = 0;

    // The odd argument count indicates an Y position.
    if (self.stack.items.len & 1 != 0) {
        self.y += self.stack.items[0];
        i += 1;
    }

    if ((self.stack.items.len - i) % 4 != 0) return error.InvalidArgumentsStackLength;

    while (i < self.stack.items.len) {
        const x1 = self.x + self.stack.items[i + 0];
        const y1 = self.y;
        const y2 = y1 + self.stack.items[i + 2];
        const x2 = x1 + self.stack.items[i + 1];
        self.x = x2 + self.stack.items[i + 3];
        self.y = y2;

        self.builder.curve_to(x1, y1, x2, y2, self.x, self.y);
        i += 4;
    }

    self.stack.clearRetainingCapacity();
}

pub fn parse_vv_curve_to(
    self: *Self,
) cff.Error!void {
    // dx1? {dya dxb dyb dyc}+

    if (!self.has_move_to) return error.MissingMoveTo;

    var i: usize = 0;

    // The odd argument count indicates an X position.
    if (self.stack.items.len & 1 != 0) {
        self.x += self.stack.items[0];
        i += 1;
    }

    if ((self.stack.items.len - i) % 4 != 0) return error.InvalidArgumentsStackLength;

    while (i < self.stack.items.len) {
        const x1 = self.x;
        const y1 = self.y + self.stack.items[i + 0];
        const x2 = x1 + self.stack.items[i + 1];
        const y2 = y1 + self.stack.items[i + 2];
        self.x = x2;
        self.y = y2 + self.stack.items[i + 3];

        self.builder.curve_to(x1, y1, x2, y2, self.x, self.y);
        i += 4;
    }

    self.stack.clearRetainingCapacity();
}

pub fn parse_hv_curve_to(
    self: *Self,
) cff.Error!void {
    // dx1 dx2 dy2 dy3 {dya dxb dyb dxc dxd dxe dye dyf}* dxf?
    //                 {dxa dxb dyb dyc dyd dxe dye dxf}+ dyf?

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len < 4) return error.InvalidArgumentsStackLength;

    std.mem.reverse(f32, self.stack.items);

    while (self.stack.items.len != 0) {
        if (self.stack.items.len < 4) return error.InvalidArgumentsStackLength;
        {
            const x1 = self.x + (self.stack.pop() orelse unreachable);
            const y1 = self.y;
            const x2 = x1 + (self.stack.pop() orelse unreachable);
            const y2 = y1 + (self.stack.pop() orelse unreachable);
            self.y = y2 + (self.stack.pop() orelse unreachable);
            self.x = x2;
            if (self.stack.items.len == 1)
                self.x += (self.stack.pop() orelse unreachable);

            self.builder.curve_to(x1, y1, x2, y2, self.x, self.y);
        }

        if (self.stack.items.len == 0) break;
        if (self.stack.items.len < 4) return error.InvalidArgumentsStackLength;

        {
            const x1 = self.x;
            const y1 = self.y + (self.stack.pop() orelse unreachable);
            const x2 = x1 + (self.stack.pop() orelse unreachable);
            const y2 = y1 + (self.stack.pop() orelse unreachable);
            self.x = x2 + (self.stack.pop() orelse unreachable);
            self.y = y2;
            if (self.stack.items.len == 1)
                self.y += (self.stack.pop() orelse unreachable);

            self.builder.curve_to(x1, y1, x2, y2, self.x, self.y);
        }
    }

    std.debug.assert((self.stack.items.len == 0));
}

pub fn parse_vh_curve_to(
    self: *Self,
) cff.Error!void {
    // dy1 dx2 dy2 dx3 {dxa dxb dyb dyc dyd dxe dye dxf}* dyf?
    //                 {dya dxb dyb dxc dxd dxe dye dyf}+ dxf?

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len < 4) return error.InvalidArgumentsStackLength;

    std.mem.reverse(f32, self.stack.items);
    while (self.stack.items.len != 0) {
        if (self.stack.items.len < 4) return error.InvalidArgumentsStackLength;

        {
            const x1 = self.x;
            const y1 = self.y + (self.stack.pop() orelse unreachable);
            const x2 = x1 + (self.stack.pop() orelse unreachable);
            const y2 = y1 + (self.stack.pop() orelse unreachable);
            self.x = x2 + (self.stack.pop() orelse unreachable);
            self.y = y2;
            if (self.stack.items.len == 1) {
                self.y += (self.stack.pop() orelse unreachable);
            }
            self.builder.curve_to(x1, y1, x2, y2, self.x, self.y);
        }

        if (self.stack.items.len == 0) break;
        if (self.stack.items.len < 4) return error.InvalidArgumentsStackLength;

        {
            const x1 = self.x + (self.stack.pop() orelse unreachable);
            const y1 = self.y;
            const x2 = x1 + (self.stack.pop() orelse unreachable);
            const y2 = y1 + (self.stack.pop() orelse unreachable);
            self.y = y2 + (self.stack.pop() orelse unreachable);
            self.x = x2;
            if (self.stack.items.len == 1) {
                self.x += (self.stack.pop() orelse unreachable);
            }
            self.builder.curve_to(x1, y1, x2, y2, self.x, self.y);
        }
    }

    std.debug.assert((self.stack.items.len == 0));
}

pub fn parse_flex(
    self: *Self,
) cff.Error!void {
    // dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 dx6 dy6 fd

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len != 13) return error.InvalidArgumentsStackLength;

    const dx1 = self.x + self.stack.items[0];
    const dy1 = self.y + self.stack.items[1];
    const dx2 = dx1 + self.stack.items[2];
    const dy2 = dy1 + self.stack.items[3];
    const dx3 = dx2 + self.stack.items[4];
    const dy3 = dy2 + self.stack.items[5];
    const dx4 = dx3 + self.stack.items[6];
    const dy4 = dy3 + self.stack.items[7];
    const dx5 = dx4 + self.stack.items[8];
    const dy5 = dy4 + self.stack.items[9];
    self.x = dx5 + self.stack.items[10];
    self.y = dy5 + self.stack.items[11];
    self.builder.curve_to(dx1, dy1, dx2, dy2, dx3, dy3);
    self.builder.curve_to(dx4, dy4, dx5, dy5, self.x, self.y);

    self.stack.clearRetainingCapacity();
}

pub fn parse_flex1(
    self: *Self,
) cff.Error!void {
    // dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 d6

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len != 11) return error.InvalidArgumentsStackLength;

    const dx1 = self.x + self.stack.items[0];
    const dy1 = self.y + self.stack.items[1];
    const dx2 = dx1 + self.stack.items[2];
    const dy2 = dy1 + self.stack.items[3];
    const dx3 = dx2 + self.stack.items[4];
    const dy3 = dy2 + self.stack.items[5];
    const dx4 = dx3 + self.stack.items[6];
    const dy4 = dy3 + self.stack.items[7];
    const dx5 = dx4 + self.stack.items[8];
    const dy5 = dy4 + self.stack.items[9];

    if (@abs(dx5 - self.x) > @abs(dy5 - self.y))
        self.x = dx5 + self.stack.items[10]
    else
        self.y = dy5 + self.stack.items[10];

    self.builder.curve_to(dx1, dy1, dx2, dy2, dx3, dy3);
    self.builder.curve_to(dx4, dy4, dx5, dy5, self.x, self.y);

    self.stack.clearRetainingCapacity();
}

pub fn parse_hflex(
    self: *Self,
) cff.Error!void {
    // dx1 dx2 dy2 dx3 dx4 dx5 dx6

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len != 7) return error.InvalidArgumentsStackLength;

    const dx1 = self.x + self.stack.items[0];
    const dy1 = self.y;
    const dx2 = dx1 + self.stack.items[1];
    const dy2 = dy1 + self.stack.items[2];
    const dx3 = dx2 + self.stack.items[3];
    const dy3 = dy2;
    const dx4 = dx3 + self.stack.items[4];
    const dy4 = dy2;
    const dx5 = dx4 + self.stack.items[5];
    const dy5 = self.y;
    self.x = dx5 + self.stack.items[6];
    self.builder.curve_to(dx1, dy1, dx2, dy2, dx3, dy3);
    self.builder.curve_to(dx4, dy4, dx5, dy5, self.x, self.y);

    self.stack.clearRetainingCapacity();
}

pub fn parse_hflex1(
    self: *Self,
) cff.Error!void {
    // dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6

    if (!self.has_move_to) return error.MissingMoveTo;
    if (self.stack.items.len != 9) return error.InvalidArgumentsStackLength;

    const dx1 = self.x + self.stack.items[0];
    const dy1 = self.y + self.stack.items[1];
    const dx2 = dx1 + self.stack.items[2];
    const dy2 = dy1 + self.stack.items[3];
    const dx3 = dx2 + self.stack.items[4];
    const dy3 = dy2;
    const dx4 = dx3 + self.stack.items[5];
    const dy4 = dy2;
    const dx5 = dx4 + self.stack.items[6];
    const dy5 = dy4 + self.stack.items[7];
    self.x = dx5 + self.stack.items[8];
    self.builder.curve_to(dx1, dy1, dx2, dy2, dx3, dy3);
    self.builder.curve_to(dx4, dy4, dx5, dy5, self.x, self.y);

    self.stack.clearRetainingCapacity();
}

pub fn parse_int1(
    self: *Self,
    op: u8,
) cff.Error!void {
    const n = @as(i16, op) - 139;
    self.stack.appendBounded(@floatFromInt(n)) catch return error.ArgumentsStackLimitReached;
}

pub fn parse_int2(
    self: *Self,
    op: u8,
    s: *parser.Stream,
) cff.Error!void {
    const b1 = s.read(u8) catch return error.ReadOutOfBounds;
    const n = (@as(i16, op) - 247) * 256 + @as(i16, b1) + 108;
    std.debug.assert(n >= 108 and n <= 1131);
    self.stack.appendBounded(@floatFromInt(n)) catch return error.ArgumentsStackLimitReached;
}

pub fn parse_int3(
    self: *Self,
    op: u8,
    s: *parser.Stream,
) cff.Error!void {
    const b1 = s.read(u8) catch return error.ReadOutOfBounds;
    const n = -(@as(i16, op) - 251) * 256 - @as(i16, b1) - 108;
    std.debug.assert(n >= -1131 and n <= -108);
    self.stack.appendBounded(@floatFromInt(n)) catch return error.ArgumentsStackLimitReached;
}

pub fn parse_fixed(
    self: *Self,
    s: *parser.Stream,
) cff.Error!void {
    const n = s.read(parser.Fixed) catch return error.ReadOutOfBounds;
    self.stack.appendBounded(n.value) catch return error.ArgumentsStackLimitReached;
}
