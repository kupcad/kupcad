//! A [Glyph Data Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/glyf) implementation.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const loca = @import("loca.zig");

const Table = @This();

data: []const u8,
loca_table: loca.Table,

/// Parses a table from raw data.
pub fn parse(
    loca_table: loca.Table,
    data: []const u8,
) Table {
    return .{
        .data = data,
        .loca_table = loca_table,
    };
}

pub fn get(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?[]const u8 {
    const start, const end = self.loca_table.glyph_range(glyph_id) orelse return null;
    return utils.slice(self.data, .{ .start = start, .end = end }) catch null;
}

/// Returns the number of points in this outline.
pub fn outline_points(
    self: *const Table,
    glyph_id: lib.GlyphId,
) u16 {
    return self.outline_points_impl(glyph_id) catch 0;
}

fn outline_points_impl(
    self: *const Table,
    glyph_id: lib.GlyphId,
) parser.Error!u16 {
    const data = self.get(glyph_id) orelse return error.ParseFail;
    var s = parser.Stream.new(data);
    const number_of_contours = try s.read(i16);

    s.advance(8); //  bbox.

    if (number_of_contours > 0) {
        // Simple glyph.
        const glyph_points = try parse_simple_outline(
            try s.tail(),
            @bitCast(number_of_contours),
        );
        return glyph_points.points_left;
    } else if (number_of_contours < 0) {
        // Composite glyph.
        var components = CompositeGlyphIter.new(try s.tail());
        var count: u16 = 0;
        while (components.next()) |_| count += 1;

        return count;
    } else {
        // An empty glyph.
        return error.ParseFail;
    }
}

/// Outlines a glyph.
pub fn outline(
    self: *const Table,
    glyph_id: lib.GlyphId,
    builder: lib.OutlineBuilder,
) ?lib.Rect {
    var b = Builder.new(.{}, .{}, builder);
    const glyph_data = self.get(glyph_id) orelse return null;
    return outline_impl(self.loca_table, self.data, glyph_data, 0, &b) catch return null;
}

/// The bounding box of the glyph. Unlike the `outline` method, this method does not
/// calculate the bounding box manually by outlining the glyph, but instead uses the
/// bounding box in the `glyf` program. As a result, this method will be much faster,
/// but the bounding box could be more inaccurate.
pub fn bbox(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?lib.Rect {
    const glyph_data = self.get(glyph_id) orelse return null;

    var s = parser.Stream.new(glyph_data);
    s.skip(i16); // number of contours
    return .{
        .x_min = s.read(i16) catch return null,
        .y_min = s.read(i16) catch return null,
        .x_max = s.read(i16) catch return null,
        .y_max = s.read(i16) catch return null,
    };
}

pub fn parse_simple_outline(
    glyph_data: []const u8,
    number_of_contours: u16, // nonzero,
) parser.Error!GlyphPointsIter {
    var s = parser.Stream.new(glyph_data);
    const endpoints = try s.read_array(u16, number_of_contours);

    const points_total = pt: {
        const last = endpoints.last() orelse return error.ParseFail;
        break :pt try std.math.add(u16, last, 1);
    };

    // Contours with a single point should be ignored.
    // But this is not an error, so we should return an "empty" iterator.
    if (points_total == 1) return .empty;

    // Skip instructions byte code.
    const instructions_len = try s.read(u16);
    s.advance(instructions_len);

    const flags_offset = s.offset;
    const x_coords_len, const y_coords_len = try resolve_coords_len(&s, points_total);
    const x_coords_offset = s.offset;
    const y_coords_offset = x_coords_offset + x_coords_len;

    return .{
        .endpoints = EndpointsIter.new(endpoints) orelse return error.ParseFail,
        .flags = .new(try utils.slice(glyph_data, .{ .start = flags_offset, .end = x_coords_offset })),
        .x_coords = .new(try utils.slice(glyph_data, .{ x_coords_offset, x_coords_len })),
        .y_coords = .new(try utils.slice(glyph_data, .{ y_coords_offset, y_coords_len })),
        .points_left = points_total,
    };
}

pub const GlyphPointsIter = struct {
    endpoints: EndpointsIter,
    flags: FlagsIter,
    x_coords: CoordsIter,
    y_coords: CoordsIter,
    points_left: u16, // Number of points left in the glyph.

    const empty: GlyphPointsIter = .{
        .endpoints = .{},
        .flags = .{},
        .x_coords = .{},
        .y_coords = .{},
        .points_left = 0,
    };

    // [RazrFalcom]
    // Due to some optimization magic, using f32 instead of i16
    // makes the code ~10% slower. At least on my machine.
    // I guess it's due to the fact that with i16 the struct
    // fits into the machine word.
    pub const GlyphPoint = struct {
        x: i16,
        y: i16,
        /// Indicates that a point is a point on curve
        /// and not a control point.
        on_curve_point: bool,
        last_point: bool,
    };

    pub fn next(
        self: *GlyphPointsIter,
    ) ?GlyphPoint {
        if (self.points_left == 0) return null;
        self.points_left -= 1;

        // TODO: skip empty contours

        const last_point = self.endpoints.next();
        const flags = self.flags.next();

        return .{
            .x = self.x_coords.next(flags.x_short, flags.x_is_same_or_positive_short),
            .y = self.y_coords.next(flags.y_short, flags.y_is_same_or_positive_short),
            .on_curve_point = flags.on_curve_point,
            .last_point = last_point,
        };
    }

    pub fn current_contour(
        self: GlyphPointsIter,
    ) u16 {
        return self.endpoints.index - 1;
    }
};

/// A simple flattening iterator for glyph's endpoints.
///
/// Translates endpoints like: 2 4 7
/// into flags: 0 0 1 0 1 0 0 1
const EndpointsIter = struct {
    endpoints: parser.LazyArray16(u16) = .{}, // Each endpoint indicates a contour end.
    index: u16 = 0,
    left: u16 = 0,

    fn new(
        endpoints: parser.LazyArray16(u16),
    ) ?EndpointsIter {
        return .{
            .endpoints = endpoints,
            .index = 1,
            .left = endpoints.get(0) orelse return null,
        };
    }

    fn next(self: *EndpointsIter) bool {
        if (self.left == 0) {
            if (self.endpoints.get(self.index)) |end| {
                const prev = self.endpoints.get(self.index - 1) orelse 0;

                // Malformed font can have endpoints not in increasing order,
                // so we have to use checked_sub.
                self.left = end -| prev;
                self.left -|= 1;
            }

            // Always advance the index, so we can check the current contour number.
            self.index +|= 1;

            return true;
        } else {
            self.left -= 1;
            return false;
        }
    }
};

const FlagsIter = struct {
    stream: parser.Stream = .empty,
    // Number of times the `flags` should be used
    // before reading the next one from `stream`.
    repeats: u8 = 0,
    flags: SimpleGlyphFlags = .{},

    fn new(
        data: []const u8,
    ) FlagsIter {
        return .{
            .stream = .new(data),
            .repeats = 0,
            .flags = .{},
        };
    }

    fn next(self: *FlagsIter) SimpleGlyphFlags {
        if (self.repeats == 0) {
            self.flags = self.stream.read(SimpleGlyphFlags) catch .{};
            if (self.flags.repeat_flag)
                self.repeats = self.stream.read(u8) catch 0;
        } else {
            self.repeats -= 1;
        }

        return self.flags;
    }
};

// https://docs.microsoft.com/en-us/typography/opentype/spec/glyf#simple-glyph-description
const SimpleGlyphFlags = packed struct(u8) {
    on_curve_point: bool = false,
    x_short: bool = false,
    y_short: bool = false,
    repeat_flag: bool = false,
    x_is_same_or_positive_short: bool = false,
    y_is_same_or_positive_short: bool = false,
    _0: u2 = 0,
};

const CoordsIter = struct {
    stream: parser.Stream = .empty,
    prev: i16 = 0, // Points are stored as deltas, so we have to keep the previous one.

    fn new(
        data: []const u8,
    ) CoordsIter {
        return .{
            .stream = .new(data),
            .prev = 0,
        };
    }

    fn next(
        self: *CoordsIter,
        is_short: bool,
        is_same_or_short: bool,
    ) i16 {
        // See https://docs.microsoft.com/en-us/typography/opentype/spec/glyf#simple-glyph-description
        // for details about Simple Glyph Flags processing.

        // We've already checked the coords data, so it's safe to fallback to 0.

        var n: i16 = 0;
        if (is_short) {
            n = self.stream.read(u8) catch 0;
            if (!is_same_or_short)
                n = -n;
        } else if (!is_same_or_short)
            n = self.stream.read(i16) catch 0;

        self.prev +%= n;
        return self.prev;
    }
};

pub const CompositeGlyphIter = struct {
    stream: parser.Stream = .empty,

    pub fn new(
        data: []const u8,
    ) CompositeGlyphIter {
        return .{
            .stream = .new(data),
        };
    }

    pub fn next(
        self: *CompositeGlyphIter,
    ) ?CompositeGlyphInfo {
        const flags = self.stream.read(CompositeGlyphFlags) catch return null;
        const glyph_id = self.stream.read(lib.GlyphId) catch return null;

        var ts: lib.Transform = .{};

        if (flags.args_are_xy_values) {
            if (flags.arg_1_and_2_are_words) {
                ts.e = @floatFromInt(self.stream.read(i16) catch return null);
                ts.f = @floatFromInt(self.stream.read(i16) catch return null);
            } else {
                ts.e = @floatFromInt(self.stream.read(i8) catch return null);
                ts.f = @floatFromInt(self.stream.read(i8) catch return null);
            }
        }

        if (flags.we_have_a_two_by_two) {
            ts.a = (self.stream.read(parser.F2DOT14) catch return null).to_f32();
            ts.b = (self.stream.read(parser.F2DOT14) catch return null).to_f32();
            ts.c = (self.stream.read(parser.F2DOT14) catch return null).to_f32();
            ts.d = (self.stream.read(parser.F2DOT14) catch return null).to_f32();
        } else if (flags.we_have_an_x_and_y_scale) {
            ts.a = (self.stream.read(parser.F2DOT14) catch return null).to_f32();
            ts.d = (self.stream.read(parser.F2DOT14) catch return null).to_f32();
        } else if (flags.we_have_a_scale) {
            ts.a = (self.stream.read(parser.F2DOT14) catch return null).to_f32();
            ts.d = ts.a;
        }

        if (!flags.more_components)
            // Finish the iterator even if stream still has some data.
            self.stream.jump_to_end();

        return .{
            .glyph_id = glyph_id,
            .transform = ts,
            .flags = flags,
        };
    }
};

pub const CompositeGlyphInfo = struct {
    glyph_id: lib.GlyphId,
    transform: lib.Transform,
    flags: CompositeGlyphFlags,
};

// https://docs.microsoft.com/en-us/typography/opentype/spec/glyf#composite-glyph-description
const CompositeGlyphFlags = packed struct(u16) {
    arg_1_and_2_are_words: bool = false,
    args_are_xy_values: bool = false,
    _0: u1 = 0,
    we_have_a_scale: bool = false,
    _1: u1 = 0,
    more_components: bool = false,
    we_have_an_x_and_y_scale: bool = false,
    we_have_a_two_by_two: bool = false,
    _2: u8 = 0,
};

/// Resolves coordinate arrays length.
///
/// The length depends on *Simple Glyph Flags*, so we have to process them all to find it.
fn resolve_coords_len(
    s: *parser.Stream,
    points_total: u16,
) parser.Error!struct { u32, u32 } {
    var flags_left: u32 = points_total;
    var repeats: u32 = undefined;
    var x_coords_len: u32 = 0;
    var y_coords_len: u32 = 0;

    while (flags_left > 0) {
        const flags = try s.read(SimpleGlyphFlags);
        repeats = if (flags.repeat_flag)
            (try s.read(u8)) + 1
        else
            1;

        if (repeats > flags_left) return error.ParseFail;

        // No need to check for `*_coords_len` overflow since u32 is more than enough.

        if (flags.x_short) {
            // Coordinate is 1 byte long.
            x_coords_len += repeats;
        } else if (!flags.x_is_same_or_positive_short) {
            // Coordinate is 2 bytes long.
            x_coords_len += repeats * 2;
        }

        if (flags.y_short) {
            // Coordinate is 1 byte long.
            y_coords_len += repeats;
        } else if (!flags.y_is_same_or_positive_short) {
            // Coordinate is 2 bytes long.
            y_coords_len += repeats * 2;
        }

        // [ARS] Branchless version in Rust OG. Might be faster
        // x_coords_len += (flags.0 & 0x02 != 0) as u32 * repeats;
        // x_coords_len += (flags.0 & (0x02 | 0x10) == 0) as u32 * (repeats * 2);
        //
        // y_coords_len += (flags.0 & 0x04 != 0) as u32 * repeats;
        // y_coords_len += (flags.0 & (0x04 | 0x20) == 0) as u32 * (repeats * 2);

        flags_left -= repeats;
    }

    return .{ x_coords_len, y_coords_len };
}

pub const Builder = struct {
    builder: lib.OutlineBuilder,
    transform: lib.Transform,
    is_default_ts: bool, // `bool` is faster than `Option` or `is_default`.
    // We have to always calculate the bbox, because `gvar` doesn't store one
    // and in case of a malformed bbox in `glyf`.
    bbox: lib.RectF,
    first_on_curve: ?Point,
    first_off_curve: ?Point,
    last_off_curve: ?Point,

    const Point = struct {
        x: f32,
        y: f32,

        fn lerp(
            self: Point,
            other: Point,
            t: f32,
        ) Point {
            return .{
                .x = self.x + t * (other.x - self.x),
                .y = self.y + t * (other.y - self.y),
            };
        }
    };

    pub fn new(
        transform: lib.Transform,
        b_box: lib.RectF,
        builder: lib.OutlineBuilder,
    ) Builder {
        return .{
            .builder = builder,
            .transform = transform,
            .is_default_ts = transform.is_default(),
            .bbox = b_box,
            .first_on_curve = null,
            .first_off_curve = null,
            .last_off_curve = null,
        };
    }

    // Useful links:
    //
    // - https://developer.apple.com/fonts/TrueType-Reference-Manual/RM01/Chap1.html
    // - https://stackoverflow.com/a/20772557
    pub fn push_point(
        self: *Builder,
        x: f32,
        y: f32,
        on_curve_point: bool,
        last_point: bool,
    ) void {
        const p: Point = .{ .x = x, .y = y };

        if (self.first_on_curve) |_| if (self.last_off_curve) |offcurve| if (on_curve_point) {
            self.last_off_curve = null;
            self.quad_to(offcurve.x, offcurve.y, p.x, p.y);
        } else {
            self.last_off_curve = p;
            const mid = offcurve.lerp(p, 0.5);
            self.quad_to(offcurve.x, offcurve.y, mid.x, mid.y);
        } else if (on_curve_point) {
            self.line_to(p.x, p.y);
        } else {
            self.last_off_curve = p;
        } else if (on_curve_point) {
            self.first_on_curve = p;
            self.move_to(p.x, p.y);
        } else if (self.first_off_curve) |offcurve| {
            const mid = offcurve.lerp(p, 0.5);
            self.first_on_curve = mid;
            self.last_off_curve = p;
            self.move_to(mid.x, mid.y);
        } else {
            self.first_off_curve = p;
        }

        if (last_point)
            self.finish_contour();
    }

    fn move_to(
        self: *Builder,
        x_: f32,
        y_: f32,
    ) void {
        var x, var y = .{ x_, y_ };
        if (!self.is_default_ts) {
            self.transform.apply_to(&x, &y);
        }

        self.bbox.extend_by(x, y);
        self.builder.move_to(x, y);
    }

    fn line_to(
        self: *Builder,
        x_: f32,
        y_: f32,
    ) void {
        var x, var y = .{ x_, y_ };
        if (!self.is_default_ts) {
            self.transform.apply_to(&x, &y);
        }

        self.bbox.extend_by(x, y);
        self.builder.line_to(x, y);
    }

    fn quad_to(
        self: *Builder,
        x1_: f32,
        y1_: f32,
        x_: f32,
        y_: f32,
    ) void {
        var x1, var y1, var x, var y = .{ x1_, y1_, x_, y_ };
        if (!self.is_default_ts) {
            self.transform.apply_to(&x1, &y1);
            self.transform.apply_to(&x, &y);
        }

        self.bbox.extend_by(x1, y1);
        self.bbox.extend_by(x, y);

        self.builder.quad_to(x1, y1, x, y);
    }

    fn finish_contour(
        self: *Builder,
    ) void {
        if (self.first_off_curve) |offcurve1| if (self.last_off_curve) |offcurve2| {
            self.last_off_curve = null;
            const mid = offcurve2.lerp(offcurve1, 0.5);
            self.quad_to(offcurve2.x, offcurve2.y, mid.x, mid.y);
        };

        if (self.first_on_curve) |p|
            if (self.first_off_curve) |offcurve1|
                self.quad_to(offcurve1.x, offcurve1.y, p.x, p.y)
            else if (self.last_off_curve) |offcurve2|
                self.quad_to(offcurve2.x, offcurve2.y, p.x, p.y)
            else
                self.line_to(p.x, p.y);

        self.first_on_curve = null;
        self.first_off_curve = null;
        self.last_off_curve = null;

        self.builder.close();
    }
};

// It's not defined in the spec, so we are using our own value.
pub const MAX_COMPONENTS: u8 = 32;

fn outline_impl(
    loca_table: loca.Table,
    glyf_table: []const u8,
    data: []const u8,
    depth: u8,
    builder: *Builder,
) parser.Error!?lib.Rect {
    if (depth >= MAX_COMPONENTS) return error.ParseFail;

    var s = parser.Stream.new(data);
    const number_of_contours = try s.read(i16);
    s.advance(8); // Skip bbox. We use calculated one.

    if (number_of_contours > 0) {
        // Simple glyph.

        // u16 casting is safe, since we already checked that the value is positive.
        var iter = try parse_simple_outline(try s.tail(), @bitCast(number_of_contours));
        while (iter.next()) |point| builder.push_point(
            @floatFromInt(point.x),
            @floatFromInt(point.y),
            point.on_curve_point,
            point.last_point,
        );
    } else if (number_of_contours < 0) {
        // Composite glyph.

        var iter = CompositeGlyphIter.new(try s.tail());
        while (iter.next()) |comp| {
            const start, const end = loca_table.glyph_range(comp.glyph_id) orelse continue;
            const glyph_data = utils.slice(glyf_table, .{ .start = start, .end = end }) catch continue;

            const transform = builder.transform.combine(comp.transform);
            var b = Builder.new(transform, builder.bbox, builder.builder);
            _ = try outline_impl(
                loca_table,
                glyf_table,
                glyph_data,
                depth + 1,
                &b,
            );

            // Take updated bbox.
            builder.bbox = b.bbox;
        }
    }

    if (builder.bbox.is_default()) return null;
    return builder.bbox.to_rect();
}
