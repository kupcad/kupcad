//! A [Glyph Variations Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/gvar) implementation.

// https://docs.microsoft.com/en-us/typography/opentype/spec/otvarcommonformats#tuple-variation-store

const std = @import("std");
const cfg = @import("config");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const glyfTable = @import("glyf.zig");

const log = std.log.scoped(.gvar);

const StackFallback = struct {
    fba: std.heap.FixedBufferAllocator,
    gpa: std.mem.Allocator,

    pub fn init(buffer: []u8, gpa: std.mem.Allocator) StackFallback {
        return .{ .fba = std.heap.FixedBufferAllocator.init(buffer), .gpa = gpa };
    }

    pub fn allocator(self: *StackFallback) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *StackFallback = @ptrCast(@alignCast(ctx));
        if (self.fba.allocator().rawAlloc(len, ptr_align, ret_addr)) |p| return p;
        return self.gpa.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, ptr_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *StackFallback = @ptrCast(@alignCast(ctx));
        if (self.fba.allocator().rawResize(buf, ptr_align, new_len, ret_addr)) return true;
        return self.gpa.rawResize(buf, ptr_align, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, ptr_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *StackFallback = @ptrCast(@alignCast(ctx));
        if (self.fba.allocator().rawRemap(buf, ptr_align, new_len, ret_addr)) |p| return p;
        return self.gpa.rawRemap(buf, ptr_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, ptr_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *StackFallback = @ptrCast(@alignCast(ctx));
        const buf_start = @intFromPtr(self.fba.buffer.ptr);
        const buf_end = buf_start + self.fba.buffer.len;
        const ptr_val = @intFromPtr(buf.ptr);

        if (ptr_val >= buf_start and ptr_val < buf_end) {
            self.fba.allocator().rawFree(buf, ptr_align, ret_addr);
        } else {
            self.gpa.rawFree(buf, ptr_align, ret_addr);
        }
    }
};

/// 'The TrueType rasterizer dynamically generates 'phantom' points for each glyph
/// that represent horizontal and vertical advance widths and side bearings,
/// and the variation data within the `gvar` table includes data for these phantom points.'
///
/// We don't actually use them, but they are required during deltas parsing.
const PHANTOM_POINTS_LEN: usize = 4;

const Table = @This();

axis_count: u16, // nonzero
shared_tuple_records: parser.LazyArray16(parser.F2DOT14),
offsets: GlyphVariationDataOffsets,
glyphs_variation_data: []const u8,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    const version = try s.read(u32);
    if (version != 0x00010000) return error.ParseFail;

    const axis_count = try s.read(u16);

    // The axis count cannot be zero.
    if (axis_count == 0) return error.ParseFail;

    const shared_tuple_count = try s.read(u16);
    const shared_tuples_offset = try s.read(parser.Offset32);
    const glyph_count = try s.read(u16);
    const flags = try s.read(u16);

    const glyph_variation_data_array_offset = try s.read(parser.Offset32);

    const shared_tuple_records = str: {
        var sub_s = try parser.Stream.new_at(data, shared_tuples_offset[0]);
        const count = try std.math.mul(u16, shared_tuple_count, axis_count);
        break :str try sub_s.read_array(parser.F2DOT14, count);
    };

    const glyphs_variation_data = try utils.slice(data, glyph_variation_data_array_offset[0]);

    const offsets: GlyphVariationDataOffsets = o: {
        const offsets_count = try std.math.add(u16, glyph_count, 1);
        const is_long_format = flags & 1 == 1; // The first bit indicates a long format.
        break :o if (is_long_format)
            .{ .long = try s.read_array(parser.Offset32, offsets_count) }
        else
            .{ .short = try s.read_array(parser.Offset16, offsets_count) };
    };

    return .{
        .axis_count = axis_count,
        .shared_tuple_records = shared_tuple_records,
        .offsets = offsets,
        .glyphs_variation_data = glyphs_variation_data,
    };
}

pub fn phantom_points(
    self: *const Table,
    gpa: std.mem.Allocator,
    glyf_table: glyfTable,
    coordinates: []const lib.NormalizedCoordinate,
    glyph_id: lib.GlyphId,
) ?lib.PhantomPoints {
    const outline_points = glyf_table.outline_points(glyph_id);

    var stack_buf: [VariationTuples.STACK_ALLOCATION_SIZE]u8 = undefined;
    var fba_state = StackFallback.init(&stack_buf, gpa);
    const fba = fba_state.allocator();

    var tuples = VariationTuples.init(fba) catch return null;
    defer tuples.deinit();

    self.parse_variation_data(
        glyph_id,
        coordinates,
        outline_points,
        &tuples,
    ) catch
        return null;

    // Skip all outline deltas.
    for (0..outline_points) |_| _ = tuples.apply_null() orelse return null;

    return .{
        .left = tuples.apply_null() orelse return null,
        .right = tuples.apply_null() orelse return null,
        .top = tuples.apply_null() orelse return null,
        .bottom = tuples.apply_null() orelse return null,
    };
}

fn parse_variation_data(
    self: *const Table,
    glyph_id: lib.GlyphId,
    coordinates: []const lib.NormalizedCoordinate,
    points_len: u16,
    tuples: *VariationTuples,
) GvarError!void {
    tuples.clear();

    if (coordinates.len != self.axis_count) return error.ParseFail;

    const next_glyph_id = try std.math.add(u16, glyph_id[0], 1);

    const start: usize, const end: usize = se: switch (self.offsets) {
        .short => |array| {
            // 'If the short format (parser.Offset16) is used for offsets,
            // the value stored is the offset divided by 2.'
            const start: usize = (array.get(glyph_id[0]) orelse return error.ParseFail)[0];
            const end: usize = (array.get(next_glyph_id) orelse return error.ParseFail)[0];

            break :se .{ start * 2, end * 2 };
        },
        .long => |array| {
            const start = array.get(glyph_id[0]) orelse return error.ParseFail;
            const end = array.get(next_glyph_id) orelse return error.ParseFail;

            break :se .{ start[0], end[0] };
        },
    };

    if (start == end) return;
    const data = try utils.slice(self.glyphs_variation_data, .{ .start = start, .end = end });

    return try parse_variation_data_inner(
        coordinates,
        self.shared_tuple_records,
        points_len,
        data,
        tuples,
    );
}

/// Outlines a glyph.
pub fn outline(
    self: *const Table,
    gpa: std.mem.Allocator,
    glyf_table: *const glyfTable,
    coordinates: []const lib.NormalizedCoordinate,
    glyph_id: lib.GlyphId,
    builder: lib.OutlineBuilder,
) ?lib.Rect {
    var b = glyfTable.Builder.new(.{}, .{}, builder);
    const glyph_data = glyf_table.get(glyph_id) orelse
        return null;
    outline_var_impl(gpa, glyf_table, self, glyph_id, glyph_data, coordinates, 0, &b) catch |e|
        log.err("Hit error outlining a glyph: {t}", .{e});

    return b.bbox.to_rect();
}

const GlyphVariationDataOffsets = union(enum) {
    short: parser.LazyArray16(parser.Offset16),
    long: parser.LazyArray16(parser.Offset32),
};

/// A list of variation tuples, possibly stored on the heap.
///
/// This is the only part of the `gvar` algorithm that actually allocates a data.
/// This is probably unavoidable due to `gvar` structure,
/// since we have to iterate all tuples in parallel.
const VariationTuples = struct {
    /// this is the allocator used. it must be a stack fallback allocator that
    /// falls back to either an arena or a failing allocator.
    allocator: std.mem.Allocator,
    /// the ArrayList where the items are
    list: std.ArrayList(VariationTuple),

    const STACK_ALLOCATION_SIZE = cfg.gvar_max_stack_tuples_len * @sizeOf(VariationTuple);

    /// input allocator be a stack fallback allocator with size at least
    /// `cfg.gvar_max_stack_tuples_len * @sizeOf(VariationTuple)`
    fn init(
        fba: std.mem.Allocator,
    ) std.mem.Allocator.Error!VariationTuples {
        return .{
            .allocator = fba,
            .list = try .initCapacity(
                fba,
                cfg.gvar_max_stack_tuples_len,
            ),
        };
    }

    fn deinit(
        self: *VariationTuples,
    ) void {
        self.list.deinit(self.allocator);
    }

    /// Remove all tuples from the structure.
    fn clear(
        self: *VariationTuples,
    ) void {
        self.list.clearRetainingCapacity();
    }

    /// Attempt to reserve up to `capacity` total slots for variation tuples.
    fn reserve(
        self: *VariationTuples,
        capacity: u16,
    ) std.mem.Allocator.Error!void {
        try self.list.ensureTotalCapacityPrecise(self.allocator, capacity);
    }

    /// Append a new tuple header to the list.
    /// This may panic if the list can't hold a new header.
    // [ARS] maybe better to use `appendBounded`?
    fn push(
        self: *VariationTuples,
        header: VariationTuple,
    ) void {
        self.list.appendAssumeCapacity(header);
    }

    fn apply(
        self: *VariationTuples,
        all_points: glyfTable.GlyphPointsIter,
        points: glyfTable.GlyphPointsIter,
        point: glyfTable.GlyphPointsIter.GlyphPoint,
    ) ?lib.PhantomPoints.PointF {
        var x: f32 = @floatFromInt(point.x);
        var y: f32 = @floatFromInt(point.y);

        // [ARS] I tunred this into something completely unreadable!
        for (self.list.items) |*tuple| {
            const x_delta, const y_delta = d: {
                var set_points = &(tuple.set_points orelse
                    break :d tuple.deltas.next() orelse continue);

                defer if (point.last_point) {
                    tuple.prev_point = null;
                };

                if (!set_points.next())
                    // Point is not referenced, so we have to resolve it.
                    break :d infer_deltas(tuple, set_points.*, points, all_points, point);

                const deltas = tuple.deltas.next() orelse
                    // If there are no more deltas, we have to resolve them manually.
                    break :d infer_deltas(tuple, set_points.*, points, all_points, point);

                const x_delta, const y_delta = deltas;

                // Remember the last set point and delta.
                tuple.prev_point = .{
                    .x = point.x,
                    .y = point.y,
                    .x_delta = x_delta,
                    .y_delta = y_delta,
                };

                break :d deltas;
            };

            x += x_delta;
            y += y_delta;
        }

        return .{ .x = x, .y = y };
    }

    // This is just like `apply()`, but without `infer_deltas`,
    // since we use it only for component points and not a contour.
    // And since there are no contour and no points, `infer_deltas()` will do nothing.
    fn apply_null(
        self: *VariationTuples,
    ) ?lib.PhantomPoints.PointF {
        var x: f32 = 0.0;
        var y: f32 = 0.0;

        for (self.list.items) |*tuple| {
            const x_delta, const y_delta =
                if (tuple.set_points) |*set_points| d: {
                    if (!set_points.next()) continue;
                    break :d tuple.deltas.next() orelse continue;
                } else tuple.deltas.next() orelse continue;

            x += x_delta;
            y += y_delta;
        }

        return .{ .x = x, .y = y };
    }
};

// This structure will be used by the `VariationTuples` stack buffer,
// so it has to be as small as possible.
const VariationTuple = struct {
    set_points: ?PackedPointsIter.SetPointsIter,
    deltas: PackedDeltasIter,
    /// The last parsed point with delta in the contour.
    /// Used during delta resolving.
    prev_point: ?PointAndDelta,
};

// https://docs.microsoft.com/en-us/typography/opentype/spec/otvarcommonformats#tuple-variation-store-header
fn parse_variation_data_inner(
    coordinates: []const lib.NormalizedCoordinate,
    shared_tuple_records: parser.LazyArray16(parser.F2DOT14),
    points_len: u16,
    data: []const u8,
    tuples: *VariationTuples,
) GvarError!void {
    const SHARED_POINT_NUMBERS_FLAG: u16 = 0x8000;
    const COUNT_MASK: u16 = 0x0FFF;

    var main_stream = parser.Stream.new(data);
    const tuple_variation_count_raw = try main_stream.read(u16);
    const data_offset = try main_stream.read(parser.Offset16);

    // 'The high 4 bits are flags, and the low 12 bits
    // are the number of tuple variation tables for this glyph.'
    const has_shared_point_numbers = tuple_variation_count_raw & SHARED_POINT_NUMBERS_FLAG != 0;
    const tuple_variation_count = tuple_variation_count_raw & COUNT_MASK;

    // 'The number of tuple variation tables can be any number between 1 and 4095.'
    // No need to check for 4095, because this is 0x0FFF that we masked before.
    if (tuple_variation_count == 0) return error.ParseFail;

    // Attempt to reserve space for the tuples we're about to parse.
    // If it fails, bail out.
    tuples.reserve(tuple_variation_count) catch |e| {
        // https://github.com/harfbuzz/ttf-parser/issues/194#issuecomment-3073862296
        log.debug(
            \\Given font has {d} vairation tuples. Maximum amount allocatable is {d}.
            \\To get this font's data pass in a working allocator.
        , .{ tuple_variation_count, cfg.gvar_max_stack_tuples_len });
        return e;
    };

    // A glyph variation data consists of three parts: header + variation tuples + serialized data.
    // Each tuple has it's own chunk in the serialized data.
    // Because of that, we are using two parsing streams: one for tuples and one for serialized data.
    // So we can parse them in parallel and avoid needless allocations.
    var serialized_stream = try parser.Stream.new_at(data, data_offset[0]);

    // All tuples in the variation data can reference the same point numbers,
    // which are defined at the start of the serialized data.

    const shared_point_numbers = if (has_shared_point_numbers)
        try PackedPointsIter.new(&serialized_stream)
    else
        null;

    return try parse_variation_tuples(
        tuple_variation_count,
        coordinates,
        shared_tuple_records,
        shared_point_numbers,
        try std.math.add(u16, points_len, PHANTOM_POINTS_LEN),
        &main_stream,
        &serialized_stream,
        tuples,
    );
}

// https://docs.microsoft.com/en-us/typography/opentype/spec/otvarcommonformats#tuplevariationheader
fn parse_variation_tuples(
    count: u16,
    coordinates: []const lib.NormalizedCoordinate,
    shared_tuple_records: parser.LazyArray16(parser.F2DOT14),
    shared_point_numbers: ?PackedPointsIter,
    points_len: u16,
    main_s: *parser.Stream,
    serialized_s: *parser.Stream,
    tuples: *VariationTuples,
) parser.Error!void {
    // [ARS] would be 80 if Zig did niche optimization properly
    comptime std.debug.assert(@sizeOf(VariationTuple) <= 88);

    // `TupleVariationHeader` has a variable size, so we cannot use a `LazyArray`.
    for (0..count) |_| {
        const header = try parse_tuple_variation_header(
            coordinates,
            shared_tuple_records,
            main_s,
        );

        if (!(header.scalar > 0.0)) {
            // Serialized data for headers with non-positive scalar should be skipped.
            serialized_s.advance(header.serialized_data_len);
            continue;
        }

        const serialized_data_start = serialized_s.offset;

        // Resolve point numbers source.
        const point_numbers = if (header.has_private_point_numbers)
            try PackedPointsIter.new(serialized_s)
        else
            shared_point_numbers;

        // TODO: this
        // Since the packed representation can include zero values,
        // it is possible for a given point number to be repeated in the derived point number list.
        // In that case, there will be multiple delta values in the deltas data
        // associated with that point number. All of these deltas must be applied
        // cumulatively to the given point.

        const deltas_count = if (point_numbers) |pn| dc: {
            var iter = pn;
            var pn_count: u16 = 0;
            while (iter.next()) |_| pn_count += 1;
            break :dc pn_count;
        } else points_len;

        const deltas = d: {
            // Use `checked_sub` in case we went over the `serialized_data_len`.
            const left = try std.math.sub(
                usize,
                header.serialized_data_len,
                serialized_s.offset - serialized_data_start,
            );

            const deltas_data = try serialized_s.read_bytes(left);
            break :d PackedDeltasIter.new(header.scalar, deltas_count, deltas_data);
        };

        const set_points: ?PackedPointsIter.SetPointsIter = if (point_numbers) |pn| .new(pn) else null;

        const tuple = VariationTuple{
            .set_points = set_points,
            .deltas = deltas,
            .prev_point = null,
        };

        tuples.push(tuple);
    }
}

const TupleVariationHeaderData = struct {
    scalar: f32,
    has_private_point_numbers: bool,
    serialized_data_len: u16,
};

// https://docs.microsoft.com/en-us/typography/opentype/spec/otvarcommonformats#tuplevariationheader
fn parse_tuple_variation_header(
    coordinates: []const lib.NormalizedCoordinate,
    shared_tuple_records: parser.LazyArray16(parser.F2DOT14),
    s: *parser.Stream,
) parser.Error!TupleVariationHeaderData {
    const EMBEDDED_PEAK_TUPLE_FLAG: u16 = 0x8000;
    const INTERMEDIATE_REGION_FLAG: u16 = 0x4000;
    const PRIVATE_POINT_NUMBERS_FLAG: u16 = 0x2000;
    const TUPLE_INDEX_MASK: u16 = 0x0FFF;

    const serialized_data_size = try s.read(u16);
    const tuple_index_raw = try s.read(u16);

    const has_embedded_peak_tuple = tuple_index_raw & EMBEDDED_PEAK_TUPLE_FLAG != 0;
    const has_intermediate_region = tuple_index_raw & INTERMEDIATE_REGION_FLAG != 0;
    const has_private_point_numbers = tuple_index_raw & PRIVATE_POINT_NUMBERS_FLAG != 0;
    const tuple_index = tuple_index_raw & TUPLE_INDEX_MASK;

    const axis_count: u16 = @truncate(coordinates.len);

    const peak_tuple = if (has_embedded_peak_tuple)
        try s.read_array(parser.F2DOT14, axis_count)
    else pt: {
        // Use shared tuples.
        const start = try std.math.mul(u16, tuple_index, axis_count);
        const end = try std.math.add(u16, start, axis_count);

        break :pt shared_tuple_records.slice(start, end);
    };

    const start_tuple: parser.LazyArray16(parser.F2DOT14), const end_tuple: parser.LazyArray16(parser.F2DOT14) =
        if (has_intermediate_region) .{
            try s.read_array(parser.F2DOT14, axis_count),
            try s.read_array(parser.F2DOT14, axis_count),
        } else .{ .{}, .{} };

    var header: TupleVariationHeaderData = .{
        .scalar = 0.0,
        .has_private_point_numbers = has_private_point_numbers,
        .serialized_data_len = serialized_data_size,
    };

    // Calculate the scalar value according to the pseudo-code described at:
    // https://docs.microsoft.com/en-us/typography/opentype/spec/otvaroverview#algorithm-for-interpolation-of-instance-values
    var scalar: f32 = 1.0;
    for (0..axis_count) |i_usize| {
        const i: u16 = @truncate(i_usize);
        const v = coordinates[i].inner;
        const peak = (peak_tuple.get(i) orelse return error.ParseFail).inner;

        if (peak == 0 or v == peak) continue;

        if (has_intermediate_region) {
            const start = (start_tuple.get(i) orelse return error.ParseFail).inner;
            const end = (end_tuple.get(i) orelse return error.ParseFail).inner;

            if (start > peak or
                peak > end or
                (start < 0 and end > 0 and peak != 0)) continue;

            if (v < start or v > end) return header;

            if (v < peak) {
                if (peak != start) {
                    const top: f32 = @floatFromInt(v - start);
                    const bot: f32 = @floatFromInt(peak - start);
                    scalar *= top / bot;
                }
            } else {
                if (peak != end) {
                    const top: f32 = @floatFromInt(end - v);
                    const bot: f32 = @floatFromInt(end - peak);
                    scalar *= top / bot;
                }
            }
        } else if (v == 0 or v < @min(0, peak) or v > @max(0, peak)) {
            // 'If the instance coordinate is out of range for some axis, then the
            // region and its associated deltas are not applicable.'
            return header;
        } else {
            const top: f32 = @floatFromInt(v);
            const bot: f32 = @floatFromInt(peak);
            scalar *= top / bot;
        }
    }

    header.scalar = scalar;
    return header;
}

// This structure will be used by the `VariationTuples` stack buffer,
// so it has to be as small as possible.
// Therefore we cannot use `Stream` and other abstractions.
const PackedPointsIter = struct {
    data: []const u8,
    // u16 is enough, since the maximum number of points is 32767.
    offset: u16,
    state: State,
    points_left: u8,

    const State = enum {
        control,
        short_point,
        long_point,
    };

    const Control = packed struct(u8) {
        run_count_mask: u7,
        points_are_words: bool,

        // 'Mask for the low 7 bits to provide the number of point values in the run, minus one.'
        // So we have to add 1.
        // It will never overflow because of a mask.
        fn run_count(
            self: Control,
        ) u8 {
            return @as(u8, self.run_count_mask) + 1;
        }
    };

    // The `PackedPointsIter` will return referenced point numbers as deltas.
    // i.e. 1 2 4 is actually 1 3 7
    // But this is not very useful in our current algorithm,
    // so we will convert it once again into:
    // false true false true false false false true
    // This way we can iterate glyph points and point numbers in parallel.
    const SetPointsIter = struct {
        iter: PackedPointsIter,
        unref_count: u16,

        fn new(
            iter: PackedPointsIter,
        ) SetPointsIter {
            var iterator = iter;
            const unref_count = iterator.next() orelse 0;
            return .{
                .iter = iterator,
                .unref_count = unref_count,
            };
        }

        fn next(
            self: *SetPointsIter,
        ) bool {
            if (self.unref_count != 0) {
                self.unref_count -= 1;
                return false;
            }

            if (self.iter.next()) |unref_count| {
                self.unref_count = unref_count;
                self.unref_count -|= 1;
            }

            // Iterator will be returning `true` after "finished".
            // This is because this iterator will be zipped with the `glyf.GlyphPointsIter`
            // and the number of glyph points can be larger than the amount of set points.
            // Anyway, this is a non-issue in a well-formed font.
            return true;
        }

        fn restart(
            self: SetPointsIter,
        ) SetPointsIter {
            var iter = self.iter;
            iter.offset = 0;
            iter.state = .control;
            iter.points_left = 0;

            const unref_count = iter.next() orelse 0;
            return .{
                .iter = iter,
                .unref_count = unref_count,
            };
        }
    };

    fn new(
        s: *parser.Stream,
    ) parser.Error!?PackedPointsIter {
        // The total amount of points can be set as one or two bytes
        // depending on the first bit.
        const b1 = try s.read(u8);
        const count: u16 = if (b1 & 0x80 != 0) b: {
            const b2 = try s.read(u8);
            break :b (@as(u16, b1 & 0x7F) << 8) | @as(u16, b2);
        } else b1;

        // No points is not an error.
        if (count == 0) return null;

        const start = s.offset;
        const tail = try s.tail();

        // The actual packed points data size is not stored,
        // so we have to parse the points first to advance the provided stream.
        // Since deltas will be right after points.
        var i: u16 = 0;
        while (i < count) {
            const control = try s.read(Control);
            const run_count: u16 = control.run_count();
            // Do not actually parse the number, simply advance.
            try s.advance_checked(
                if (control.points_are_words) 2 * run_count else run_count,
            );
            i += run_count;
        }

        // No points is not an error.
        if (i == 0) return null;

        // Malformed font.
        if (i > count) return error.ParseFail;

        // Check that points data size is smaller than the storage type
        // used by the iterator.
        const data_len = s.offset - start;
        if (data_len > std.math.maxInt(u16)) return error.ParseFail;

        return .{
            .data = tail[0..data_len],
            .offset = 0,
            .state = .control,
            .points_left = 0,
        };
    }

    fn next(
        self: *PackedPointsIter,
    ) ?u16 {
        if (self.offset >= self.data.len) return null;

        if (self.state == .control) {
            const control: Control = @bitCast(self.data[self.offset]);
            self.offset += 1;

            self.points_left = control.run_count();
            self.state = if (control.points_are_words)
                .long_point
            else
                .short_point;

            return self.next();
        } else {
            var s = parser.Stream.new_at(self.data, self.offset) catch return null;
            const point: u16 = if (self.state == .long_point) l: {
                self.offset += 2;
                break :l s.read(u16) catch return null;
            } else s: {
                self.offset += 1;
                break :s s.read(u8) catch return null;
            };

            self.points_left -= 1;
            if (self.points_left == 0) self.state = .control;

            return point;
        }
    }

    // Trsts
    const t = std.testing;
    fn gen_control(control: struct {
        points_are_words: bool,
        run_count: u7,
    }) !u8 {
        if (!@import("builtin").is_test) unreachable;
        try t.expect(control.run_count > 0); // run count cannot be zero

        const c: Control = .{
            .points_are_words = control.points_are_words,
            .run_count_mask = control.run_count - 1,
        };

        return @bitCast(c);
    }

    test "empty" {
        var s = parser.Stream.new(&.{});
        try t.expectError(error.ParseFail, PackedPointsIter.new(&s));
    }

    test "single zero control" {
        var s = parser.Stream.new(&.{0});
        try t.expectEqual(null, try PackedPointsIter.new(&s));
    }

    test "single point" {
        var s = parser.Stream.new(&.{
            1, // total count
            try gen_control(.{ .points_are_words = false, .run_count = 1 }),
            1,
        });

        const points_iter = try PackedPointsIter.new(&s);
        var iter = SetPointsIter.new(points_iter.?);
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(true, iter.next()); // endlessly true
    }

    test "set 0 and 2" {
        var s = parser.Stream.new(&.{
            2, // total count
            try gen_control(.{ .points_are_words = false, .run_count = 2 }),
            0,
            2,
        });

        const points_iter = try PackedPointsIter.new(&s);
        var iter = SetPointsIter.new(points_iter.?);
        try t.expectEqual(true, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(true, iter.next()); // Endlessly true.
    }

    test "set 1 and 2" {
        var s = parser.Stream.new(&.{
            2, // total count
            try gen_control(.{ .points_are_words = false, .run_count = 2 }),
            1,
            1,
        });

        const points_iter = try PackedPointsIter.new(&s);
        var iter = SetPointsIter.new(points_iter.?);
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(true, iter.next()); // Endlessly true.
    }

    test "set 1 and 3" {
        var s = parser.Stream.new(&.{
            2, // total count
            try gen_control(.{ .points_are_words = false, .run_count = 2 }),
            1,
            2,
        });

        const points_iter = try PackedPointsIter.new(&s);
        var iter = SetPointsIter.new(points_iter.?);
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(true, iter.next()); // Endlessly true.
    }

    test "set 2 5 7" {
        var s = parser.Stream.new(&.{
            3, // total count
            try gen_control(.{ .points_are_words = false, .run_count = 3 }),
            2,
            3,
            2,
        });

        const points_iter = try PackedPointsIter.new(&s);
        var iter = SetPointsIter.new(points_iter.?);
        try t.expectEqual(false, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(true, iter.next()); // Endlessly true.
    }

    test "more than 127 points" {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(t.allocator);

        // total count
        try data.append(t.allocator, 0x80); // Control.POINTS_ARE_WORDS_FLAG
        try data.append(t.allocator, 150);

        try data.append(t.allocator, try gen_control(.{
            .points_are_words = false,
            .run_count = 100,
        }));
        for (0..100) |_| try data.append(t.allocator, 2);

        try data.append(t.allocator, try gen_control(.{
            .points_are_words = false,
            .run_count = 50,
        }));
        for (0..50) |_| try data.append(t.allocator, 2);

        var s = parser.Stream.new(data.items);
        const points_iter = try PackedPointsIter.new(&s);
        var iter = SetPointsIter.new(points_iter.?);
        try t.expectEqual(false, iter.next());
        for (0..150) |_| {
            try t.expectEqual(false, iter.next());
            try t.expectEqual(true, iter.next());
        }
        try t.expectEqual(true, iter.next());
        try t.expectEqual(true, iter.next()); // Endlessly true.
    }

    test "long points" {
        var s = parser.Stream.new(&.{
            2, // total count
            try gen_control(.{ .points_are_words = true, .run_count = 2 }),
            0,
            2,
            0,
            3,
        });

        const points_iter = try PackedPointsIter.new(&s);
        var iter = SetPointsIter.new(points_iter.?);
        try t.expectEqual(false, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(true, iter.next()); // Endlessly true.
    }

    test "multiple runs" {
        var s = parser.Stream.new(&.{
            5, // total count
            try gen_control(.{ .points_are_words = true, .run_count = 2 }),
            0,
            2,
            0,
            3,
            try gen_control(.{ .points_are_words = false, .run_count = 3 }),
            2,
            3,
            2,
        });

        const points_iter = try PackedPointsIter.new(&s);
        var iter = SetPointsIter.new(points_iter.?);
        try t.expectEqual(false, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(false, iter.next());
        try t.expectEqual(true, iter.next());
        try t.expectEqual(true, iter.next()); // Endlessly true.
    }

    test "runs overflow" {
        // TrueType allows up to 32767 points.
        const data: [0xFFFF * 2]u8 = @splat(0xFF);
        var s = parser.Stream.new(&data);

        try t.expectError(error.ParseFail, PackedPointsIter.new(&s));
    }
};

// This structure will be used by the `VariationTuples` stack buffer,
// so it has to be as small as possible.
// Therefore we cannot use `Stream` and other abstractions.
const PackedDeltasIter = struct {
    data: []const u8 = &.{},
    x_run: RunState = .{},
    y_run: RunState = .{},

    /// A total number of deltas per axis.
    ///
    /// Required only by restart()
    total_count: u16 = 0,

    scalar: f32 = 0.0,

    const RunState = struct {
        data_offset: u16 = 0,
        state: State = .control,
        run_deltas_left: u8 = 0,

        fn next(
            self: *RunState,
            data: []const u8,
            scalar: f32,
        ) ?f32 {
            if (self.state == .control) {
                if (self.data_offset == data.len) return null;

                var s = parser.Stream.new_at(data, self.data_offset) catch return null;
                const control = s.read(Control) catch return null;

                self.data_offset += 1;
                self.run_deltas_left = control.run_count();
                self.state = if (control.deltas_are_zero_flag)
                    .zero_delta
                else if (control.delta_are_words_flag)
                    .long_delta
                else
                    .short_delta;

                return self.next(data, scalar);
            } else {
                var s = parser.Stream.new_at(data, self.data_offset) catch return null;
                const delta: f32 = switch (self.state) {
                    .zero_delta => 0.0,
                    .long_delta => l: {
                        self.data_offset += 2;
                        break :l @as(f32, @floatFromInt(s.read(i16) catch return null)) * scalar;
                    },
                    .short_delta => s: {
                        self.data_offset += 1;
                        break :s @as(f32, @floatFromInt(s.read(i8) catch return null)) * scalar;
                    },
                    else => unreachable,
                };
                self.run_deltas_left -= 1;
                if (self.run_deltas_left == 0) self.state = .control;

                return delta;
            }
        }
    };

    const State = enum {
        control,
        zero_delta,
        short_delta,
        long_delta,
    };

    const Control = packed struct(u8) {
        delta_run_count_mask: u6 = 0,
        delta_are_words_flag: bool = false,
        deltas_are_zero_flag: bool = false,

        // 'Mask for the low 6 bits to provide the number of delta values in the run, minus one.'
        // So we have to add 1.
        // It will never overflow because of a mask.
        fn run_count(
            self: Control,
        ) u8 {
            return @as(u8, self.delta_run_count_mask) + 1;
        }
    };

    /// `count` indicates a number of delta pairs.
    fn new(
        scalar: f32,
        count: u16,
        data: []const u8,
    ) PackedDeltasIter {
        comptime std.debug.assert(@sizeOf(PackedDeltasIter) <= 32);

        var iter = PackedDeltasIter{
            .data = data,
            .total_count = count,
            .scalar = scalar,
        };

        // 'The packed deltas are arranged with all of the deltas for X coordinates first,
        // followed by the deltas for Y coordinates.'
        // So we have to skip X deltas in the Y deltas iterator.
        //
        // Note that Y deltas doesn't necessarily start with a Control byte
        // and can actually start in the middle of the X run.
        // So we can't simply split the input data in half
        // and process those chunks separately.
        for (0..count) |_| _ = iter.y_run.next(data, scalar);

        return iter;
    }

    fn next(
        self: *PackedDeltasIter,
    ) ?struct { f32, f32 } {
        const x = self.x_run.next(self.data, self.scalar) orelse return null;
        const y = self.y_run.next(self.data, self.scalar) orelse return null;
        return .{ x, y };
    }

    fn restart(
        self: PackedDeltasIter,
    ) PackedDeltasIter {
        return .new(self.scalar, self.total_count, self.data);
    }

    // Tests
    const t = std.testing;

    fn gen_control(control: struct {
        deltas_are_zero: bool,
        deltas_are_words: bool,
        run_count: u6,
    }) !u8 {
        if (!@import("builtin").is_test) unreachable;
        try t.expect(control.run_count > 0); // run count cannot be zero

        const c: Control = .{
            .delta_are_words_flag = control.deltas_are_words,
            .deltas_are_zero_flag = control.deltas_are_zero,
            .delta_run_count_mask = control.run_count - 1,
        };

        return @bitCast(c);
    }

    test "empty" {
        var iter = PackedDeltasIter.new(1.0, 1, &.{});
        try t.expectEqual(null, iter.next());
    }

    test "single delta" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = false,
                .run_count = 2,
            }),
            2,
            3,
        };

        var iter = PackedDeltasIter.new(1.0, 1, data);
        try t.expectEqual(.{ 2.0, 3.0 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "two deltas" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = false,
                .run_count = 4,
            }),
            2,
            3,
            4,
            5,
        };

        var iter = PackedDeltasIter.new(1.0, 2, data);
        // Remember that X deltas are defined first.
        try t.expectEqual(.{ 2.0, 4.0 }, iter.next().?);
        try t.expectEqual(.{ 3.0, 5.0 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "single long delta" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = true,
                .run_count = 2,
            }),
            0,
            2,
            0,
            3,
        };

        var iter = PackedDeltasIter.new(1.0, 1, data);
        try t.expectEqual(.{ 2.0, 3.0 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "zeros" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = true,
                .deltas_are_words = false,
                .run_count = 4,
            }),
        };

        var iter = PackedDeltasIter.new(1.0, 2, data);
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "zero words" {
        // When `deltas_are_zero` is set, `deltas_are_words` should be ignored.

        const data: []const u8 = &.{try gen_control(.{
            .deltas_are_zero = true,
            .deltas_are_words = true,
            .run_count = 4,
        })};

        var iter = PackedDeltasIter.new(1.0, 2, data);
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "zero runs" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = true,
                .deltas_are_words = false,
                .run_count = 2,
            }),
            try gen_control(.{
                .deltas_are_zero = true,
                .deltas_are_words = false,
                .run_count = 4,
            }),
            try gen_control(.{
                .deltas_are_zero = true,
                .deltas_are_words = false,
                .run_count = 6,
            }),
        };

        var iter = PackedDeltasIter.new(1.0, 6, data);
        // First run.
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        // Second run.
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        // Third run.
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "delta after zeros" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = true,
                .deltas_are_words = false,
                .run_count = 2,
            }),
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = false,
                .run_count = 2,
            }),
            2,
            3,
        };

        var iter = PackedDeltasIter.new(1.0, 2, data);
        try t.expectEqual(.{ 0.0, 2.0 }, iter.next().?);
        try t.expectEqual(.{ 0.0, 3.0 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "unexpected end of data 1" {
        const data: []const u8 = &.{try gen_control(.{
            .deltas_are_zero = false,
            .deltas_are_words = false,
            .run_count = 2,
        })};

        var iter = PackedDeltasIter.new(1.0, 1, data);
        try t.expectEqual(null, iter.next());
    }

    test "unexpected end of data 2" {
        // Only X is set.

        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = false,
                .run_count = 2,
            }),
            1,
        };

        var iter = PackedDeltasIter.new(1.0, 1, data);
        try t.expectEqual(null, iter.next());
    }

    test "unexpected end of data 3" {
        const data: []const u8 = &.{try gen_control(.{
            .deltas_are_zero = false,
            .deltas_are_words = true,
            .run_count = 2,
        })};

        var iter = PackedDeltasIter.new(1.0, 1, data);
        try t.expectEqual(null, iter.next());
    }

    test "unexpected end of data 4" {
        // X data is too short.

        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = true,
                .run_count = 2,
            }),
            1,
        };

        var iter = PackedDeltasIter.new(1.0, 1, data);
        try t.expectEqual(null, iter.next());
    }

    test "unexpected end of data 6" {
        // Only X is set.

        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = true,
                .run_count = 2,
            }),
            0,
            1,
        };

        var iter = PackedDeltasIter.new(1.0, 1, data);
        try t.expectEqual(null, iter.next());
    }

    test "unexpected end of data 7" {
        // Y data is too short.

        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = true,
                .run_count = 2,
            }),
            0,
            1,
            0,
        };

        var iter = PackedDeltasIter.new(1.0, 1, data);
        try t.expectEqual(null, iter.next());
    }

    test "single run" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = false,
                .run_count = 1,
            }),
            2,
            3,
        };

        var iter = PackedDeltasIter.new(1.0, 1, data);
        try t.expectEqual(null, iter.next());
    }

    test "too many pairs" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = false,
                .run_count = 2,
            }),
            2,
            3,
        };

        // We have only one pair, not 10.
        var iter = PackedDeltasIter.new(1.0, 10, data);
        try t.expectEqual(null, iter.next());
    }

    test "invalid number of pairs" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = false,
                .run_count = 2,
            }),
            2,
            3,
            4,
            5,
            6,
            7,
        };

        // We have 3 pairs, not 4.
        // We don't actually check this, since it will be very expensive.
        // And it should not happen in a well-formed font anyway.
        // So as long as it doesn't panic - we are fine.
        var iter = PackedDeltasIter.new(1.0, 4, data);
        try t.expectEqual(.{ 2.0, 7.0 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "mixed runs" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = false,
                .run_count = 3,
            }),
            2,
            3,
            4,
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = true,
                .run_count = 2,
            }),
            0,
            5,
            0,
            6,
            try gen_control(.{
                .deltas_are_zero = true,
                .deltas_are_words = false,
                .run_count = 1,
            }),
        };

        var iter = PackedDeltasIter.new(1.0, 3, data);
        try t.expectEqual(.{ 2.0, 5.0 }, iter.next().?);
        try t.expectEqual(.{ 3.0, 6.0 }, iter.next().?);
        try t.expectEqual(.{ 4.0, 0.0 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "non default scalar" {
        const data: []const u8 = &.{
            try gen_control(.{
                .deltas_are_zero = false,
                .deltas_are_words = false,
                .run_count = 2,
            }),
            2,
            3,
        };

        var iter = PackedDeltasIter.new(0.5, 1, data);
        try t.expectEqual(.{ 1.0, 1.5 }, iter.next().?);
        try t.expectEqual(null, iter.next());
    }

    test "runs overflow" {
        const data: [0xFFFF]u8 = @splat(0xFF);
        var iter = PackedDeltasIter.new(1.0, 0xFFFF, &data);
        // As long as it doesn't panic - we are fine.
        try t.expectEqual(.{ 0.0, 0.0 }, iter.next().?);
    }
};

const PointAndDelta = struct {
    x: i16,
    y: i16,
    x_delta: f32,
    y_delta: f32,
};

fn outline_var_impl(
    gpa: std.mem.Allocator,
    glyf_table: *const glyfTable,
    gvar_table: *const Table,
    glyph_id: lib.GlyphId,
    data: []const u8,
    coordinates: []const lib.NormalizedCoordinate,
    depth: u8,
    builder: *glyfTable.Builder,
) GvarError!void {
    if (depth >= glyfTable.MAX_COMPONENTS) return error.ParseFail;

    var s = parser.Stream.new(data);
    const number_of_contours = try s.read(i16);

    // Skip bbox.
    //
    // In case of a variable font, a bounding box defined in the `glyf` data
    // refers to the default variation values. Which is not what we want.
    // Instead, we have to manually calculate outline's bbox.
    s.advance(8);

    var stack_buf: [VariationTuples.STACK_ALLOCATION_SIZE]u8 = undefined;
    var fba_state = StackFallback.init(&stack_buf, gpa);
    const fba = fba_state.allocator();

    var tuples = VariationTuples.init(fba) catch return error.ParseFail;
    defer tuples.deinit();

    if (number_of_contours > 0) {
        // Simple glyph.

        var glyph_points = try glyfTable.parse_simple_outline(try s.tail(), @bitCast(number_of_contours));
        const all_glyph_points = glyph_points; // [ARS} ].clone()
        const points_len = glyph_points.points_left;
        try gvar_table.parse_variation_data(glyph_id, coordinates, points_len, &tuples);

        while (glyph_points.next()) |point| {
            const p = tuples.apply(
                all_glyph_points,
                glyph_points,
                point,
            ) orelse return error.ParseFail;

            builder.push_point(p.x, p.y, point.on_curve_point, point.last_point);
        }
    } else if (number_of_contours < 0) {
        // Composite glyph.

        // In case of a composite glyph, `gvar` data contains position adjustments
        // for each component.
        // Basically, an additional translation used during transformation.
        // So we have to push zero points manually, instead of parsing the `glyf` data.
        //
        // Details:
        // https://docs.microsoft.com/en-us/typography/opentype/spec/gvar#point-numbers-and-processing-for-composite-glyphs
        var components = glyfTable.CompositeGlyphIter.new(try s.tail());
        const components_count = cc: {
            var components_iter = components;
            var count: u16 = 0;
            while (components_iter.next()) |_| count += 1;
            break :cc count;
        };

        try gvar_table.parse_variation_data(
            glyph_id,
            coordinates,
            components_count,
            &tuples,
        );

        while (components.next()) |component| {
            const t = tuples.apply_null() orelse return error.ParseFail;
            var transform = builder.transform;
            // Variation component offset should be applied only when
            // the ARGS_ARE_XY_VALUES flag is set.
            if (component.flags.args_are_xy_values)
                transform = transform.combine(
                    .new_translate(t.x, t.y),
                );

            transform = transform.combine(component.transform);

            var b = glyfTable.Builder.new(transform, builder.bbox, builder.builder);
            if (glyf_table.get(component.glyph_id)) |glyph_data| {
                try outline_var_impl(
                    gpa,
                    glyf_table,
                    gvar_table,
                    component.glyph_id,
                    glyph_data,
                    coordinates,
                    depth + 1,
                    &b,
                );

                // Take updated bbox.
                builder.bbox = b.bbox;
            }
        }
    } else
    // An empty glyph.
    return error.ParseFail;
}

/// Infer unreferenced deltas.
///
/// A font can define deltas only for specific points, to reduce the file size.
/// In this case, we have to infer undefined/unreferenced deltas manually,
/// depending on the context.
///
/// This is already a pretty complex task, since deltas should be resolved
/// only inside the current contour (do not confuse with component).
/// And during resolving we can actually wrap around the contour.
/// So if there is no deltas after the current one, we have to use
/// the first delta of the current contour instead.
/// Same goes for the previous delta. If there are no deltas
/// before the current one, we have to use the last one in the current contour.
///
/// And in case of `ttf-parser` (`tatfi`'s dad) everything is becoming even more complex,
/// since we don't actually have a list of points and deltas, only iterators.
/// Because of `ttf-parser`'s allocation free policy.
/// Which makes the code even more complicated.
///
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gvar#inferred-deltas-for-un-referenced-point-numbers
fn infer_deltas(
    tuple: *const VariationTuple,
    points_set: PackedPointsIter.SetPointsIter,
    // A points iterator that starts after the current point.
    points: glyfTable.GlyphPointsIter,
    // A points iterator that starts from the first point in the glyph.
    all_points: glyfTable.GlyphPointsIter,
    curr_point: glyfTable.GlyphPointsIter.GlyphPoint,
) struct { f32, f32 } {
    const current_contour = if (curr_point.last_point)
        // When we parsed the last point of a contour,
        // an iterator had switched to the next contour.
        // So we have to move to the previous one.
        points.current_contour() -| 1
    else
        points.current_contour();

    const prev_point = if (tuple.prev_point) |prev_point|
        // If a contour already had a delta - just use it.
        prev_point
    else pp: {
        // If not, find the last point with delta in the current contour.
        var last_point: ?PointAndDelta = null;
        var deltas = tuple.deltas;

        var points_clone = points;
        var points_set_clone = points_set;
        while (true) {
            const point = points_clone.next() orelse break;
            const is_set = points_set_clone.next();

            if (is_set) if (deltas.next()) |d| {
                last_point = .{
                    .x = point.x,
                    .y = point.y,
                    .x_delta = d[0],
                    .y_delta = d[1],
                };
            };

            if (point.last_point) break;
        }

        // If there is no last point, there are no deltas.
        if (last_point) |p| break :pp p else return .{ 0.0, 0.0 };
    };

    var next_point_maybe: ?PointAndDelta = null;
    if (!curr_point.last_point) {
        // If the current point is not the last one in the contour,
        // find the first set delta in the current contour.
        var deltas = tuple.deltas;

        var points_clone = points;
        var points_set_clone = points_set;
        while (true) {
            const point = points_clone.next() orelse break;
            const is_set = points_set_clone.next();
            if (is_set) {
                const x_delta, const y_delta = deltas.next() orelse break;

                next_point_maybe = .{
                    .x = point.x,
                    .y = point.y,
                    .x_delta = x_delta,
                    .y_delta = y_delta,
                };

                break;
            }

            if (point.last_point)
                break;
        }
    }

    if (next_point_maybe == null) {
        // If there were no deltas after the current point,
        // restart from the start of the contour.
        //
        // This is probably the most expensive branch,
        // but nothing we can do about it since `glyf`/`gvar` data structure
        // doesn't allow implementing a reverse iterator.
        // So we have to parse everything once again.

        var all_points_clone = all_points;
        var deltas = tuple.deltas.restart();
        var points_set_clone = points_set.restart();

        var contour: u16 = 0;
        while (true) {
            const point = all_points_clone.next() orelse break;
            const is_set = points_set_clone.next();

            // First, we have to skip already processed contours.
            if (contour != current_contour) {
                if (is_set) _ = deltas.next();

                contour = all_points_clone.current_contour();
                continue;
            }

            if (is_set) {
                const x_delta, const y_delta = deltas.next() orelse .{ 0.0, 0.0 };
                next_point_maybe = .{
                    .x = point.x,
                    .y = point.y,
                    .x_delta = x_delta,
                    .y_delta = y_delta,
                };

                break;
            }

            if (point.last_point) break;
        }
    }

    // If there is no next point, there are no deltas.
    const next_point = next_point_maybe orelse return .{ 0.0, 0.0 };

    const dx = infer_delta(
        prev_point.x,
        curr_point.x,
        next_point.x,
        prev_point.x_delta,
        next_point.x_delta,
    );

    const dy = infer_delta(
        prev_point.y,
        curr_point.y,
        next_point.y,
        prev_point.y_delta,
        next_point.y_delta,
    );

    return .{ dx, dy };
}

fn infer_delta(
    prev_point: i16,
    target_point: i16,
    next_point: i16,
    prev_delta: f32,
    next_delta: f32,
) f32 {
    return if (prev_point == next_point)
        if (prev_delta == next_delta) prev_delta else 0.0
    else if (target_point <= @min(prev_point, next_point))
        if (prev_point < next_point) prev_delta else next_delta
    else if (target_point >= @max(prev_point, next_point))
        if (prev_point > next_point) prev_delta else next_delta
    else {
        // 'Target point coordinate is between adjacent point coordinates.'
        //
        // 'Target point delta is derived from the adjacent point deltas
        // using linear interpolation.'
        const target_sub: f32 = @floatFromInt(
            std.math.sub(i16, target_point, prev_point) catch return 0.0,
        );
        const next_sub: f32 = @floatFromInt(
            std.math.sub(i16, next_point, prev_point) catch return 0.0,
        );
        const d = target_sub / next_sub;
        return (1.0 - d) * prev_delta + d * next_delta;
    };
}

const GvarError = parser.Error || std.mem.Allocator.Error;
