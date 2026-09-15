const std = @import("std");
const log = std.log.scoped(.parser_module);

/// A slice-like container that converts internal binary data only on access.
///
/// Array values are stored in a continuous data chunk.
pub fn LazyArray16(T: type) type {
    return LazyArray(u16, T);
}
/// A slice-like container that converts internal binary data only on access.
///
/// Array values are stored in a continuous data chunk.
pub fn LazyArray32(T: type) type {
    return LazyArray(u32, T);
}

/// A slice-like container that converts internal binary data only on access.
///
/// This is a low-level, internal structure that should not be used directly.
pub fn LazyArray(I: type, T: type) type {
    // [ARS] T implements trait FromData

    std.debug.assert(I == u8 or I == u16 or I == u32);
    return struct {
        data: []const u8 = &.{},

        const Self = @This();

        pub fn new(
            data: []const u8,
        ) Self {
            return .{ .data = data };
        }

        /// Returns a value at `index`.
        pub fn get(
            self: Self,
            index: I,
        ) ?T {
            if (@typeInfo(T) == .optional) @compileError("use get_optional");
            const size = size_of(T);

            if (index >= self.len()) return null;
            const start: usize = index * size;
            if (start > self.data.len) return null;
            if (start + size > self.data.len) return null;

            const bytes: *const [size]u8 = self.data[start..][0..size];
            return switch (has_trait(T, "FromData")) {
                .int => std.mem.readInt(T, bytes, .big),
                .impl => T.FromData.parse(bytes) catch return null,
                inline else => |F, tag| {
                    const i = std.mem.readInt(F, bytes, .big);
                    return switch (tag) {
                        .@"enum" => @enumFromInt(i),
                        .wrapper => .{i},
                        .fancy_wrapper => .{ .inner = i },
                        .flags => @bitCast(i),
                        else => unreachable,
                    };
                },
            };
        }

        // [ARS] To work LazyArray16(?Offset32) and co
        pub fn get_optional(
            self: Self,
            index: I,
        ) T {
            if (@typeInfo(T) != .optional) @compileError("use get for non-optionals");
            const F = switch (has_trait(@typeInfo(T).optional.child, "FromData")) {
                .wrapper => |F| F,
                else => @compileError("get_optional only to be used for wrappers"),
            };

            const size: usize = @typeInfo(F).int.bits / 8;
            if (index >= self.len()) return null;
            const start = index * size;
            if (start > self.data.len or
                start + size > self.data.len) return null;

            const bytes = self.data[start..][0..size];
            const ret = std.mem.readInt(F, bytes, .big);
            if (ret == 0) return null;
            return .{ret};
        }

        /// Returns array's length.
        pub fn len(
            self: Self,
        ) I {
            const size = size_of(T);
            return @truncate(self.data.len / size);
        }

        /// Returns the last value.
        pub fn last(
            self: Self,
        ) ?T {
            return if (self.len() > 0)
                self.get(self.len() - 1)
            else
                null;
        }

        pub fn iterator(
            data: *const Self,
        ) Self.Iterator {
            return .{ .data = data };
        }

        pub const Iterator = struct {
            data: *const Self,
            index: I = 0,

            pub fn next(
                self: *Iterator,
            ) ?T {
                defer self.index += 1;
                return self.data.get(self.index);
            }
        };

        /// Performs a binary search using specified closure.
        pub fn binary_search_by(
            self: Self,
            ctx: anytype,
            F: fn (T, @TypeOf(ctx)) std.math.Order,
        ) SearchError!struct { I, T } {
            // Based on Rust std implementation.

            var size = self.len();
            if (size == 0) return error.NotFound;

            var base: I = 0;
            while (size > 1) {
                const half = size / 2;
                const mid = base + half;
                // mid is always in [0, size), that means mid is >= 0 and < size.
                // mid >= 0: by definition
                // mid < size: mid = size / 2 + size / 4 + size / 8 ...
                const cmp = F(
                    self.get(mid) orelse return error.DataError,
                    ctx,
                );
                if (cmp != .gt) base = mid;
                size -= half;
            }

            const value = self.get(base) orelse return error.DataError;
            if (F(value, ctx) == .eq) {
                return .{ base, value };
            } else return error.NotFound;
        }

        /// Returns sub-array.
        pub fn slice(
            self: Self,
            start: I,
            end: I,
        ) Self {
            const size = size_of(T);

            const start_t = start * size;
            const end_t = end * size;
            return .{ .data = self.data[start_t..end_t] };
        }

        pub fn format(
            self: Self,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            if (self.len() == 0) {
                try writer.writeAll("[]");
                return;
            }

            try writer.writeByte('[');
            var iter = self.iterator();
            var idx: I = 0;
            while (iter.next()) |item| : (idx += 1) {
                if (idx > 0) try writer.writeByte(',');
                try writer.print(" {any}", .{item});
            }
            try writer.writeAll(" ]");
        }
    };
}

/// A `LazyArray16`-like container, but data is accessed by offsets.
///
/// Unlike `LazyArray16`, internal storage is not continuous.
///
/// Multiple offsets can point to the same data.
pub fn LazyOffsetArray16(T: type) type {
    // [ARS] T implements trait FromSlice
    return struct {
        data: []const u8,
        // Zero offsets must be ignored, therefore we're using optionals
        offsets: LazyArray16(?Offset16),

        const Self = @This();

        pub fn new(
            data: []const u8,
            offsets: LazyArray16(?Offset16),
        ) Self {
            return .{
                .data = data,
                .offsets = offsets,
            };
        }

        pub fn parse(
            data: []const u8,
        ) Error!Self {
            var s = Stream.new(data);
            const count = try s.read(u16);
            const offsets = try s.read_array_optional(Offset16, count);

            return .{
                .data = data,
                .offsets = offsets,
            };
        }

        /// Returns a value at `index`.
        pub fn get(
            self: Self,
            index: u16,
        ) ?T {
            const offset = self.offsets.get_optional(index) orelse return null;
            if (offset[0] > self.data.len) return null;
            return T.parse(self.data[offset[0]..]) catch null;
        }

        /// Returns array's length.
        pub fn len(
            self: Self,
        ) u16 {
            return self.offsets.len();
        }

        /// Get an iterator. Note that `null` values do not terminate it as data is not contiguous
        pub fn iterator(self: *const Self) Iterator {
            return .{ .array = self };
        }

        pub const Iterator = struct {
            array: *const Self,
            index: u16 = 0,

            pub fn next(self: *Iterator) ?T {
                while (self.index < self.array.len()) {
                    defer self.index += 1;
                    return self.array.get(self.index) orelse continue;
                } else return null;
            }
        };
    };
}

/// A type-safe u32 offset.
pub const Offset32 = struct { u32 };

/// A type-safe u24 offset.
pub const Offset24 = struct { u24 };

/// A type-safe u16 offset.
pub const Offset16 = struct { u16 };

/// A 16-bit signed fixed number with the low 14 bits of fraction (2.14).
pub const F2DOT14 = struct {
    inner: i16,

    pub fn to_f32(i: F2DOT14) f32 {
        const f: f32 = @floatFromInt(i.inner);
        return f / (1 << 14);
    }

    pub fn apply_float_delta(
        self: F2DOT14,
        delta: f32,
    ) f32 {
        return self.to_f32() + @as(
            f32,
            @floatCast(
                @as(f64, @floatCast(delta)) * (@as(f64, 1.0) / @as(f64, 1 << 14)),
            ),
        );
    }
};

/// A 32-bit signed fixed-point number (16.16).
pub const Fixed = struct {
    value: f32,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 4;

        pub fn parse(
            data: *const [SIZE]u8,
        ) Error!Self {
            const i = std.mem.readInt(i32, data, .big);
            const f: f32 = @floatFromInt(i);
            return .{ .value = f / (1 << 16) };
        }
    };

    pub fn apply_float_delta(
        self: Fixed,
        delta: f32,
    ) f32 {
        return self.value + @as(
            f32,
            @floatCast(
                @as(f64, @floatCast(delta)) * (@as(f64, 1.0) / @as(f64, 1 << 16)),
            ),
        );
    }
};

/// A streaming binary parser.
pub const Stream = struct {
    data: []const u8,
    offset: usize,

    pub const empty: Stream = .{ .data = &.{}, .offset = 0 };

    /// Creates a new `Stream` parser.
    pub fn new(
        data: []const u8,
    ) Stream {
        return .{ .data = data, .offset = 0 };
    }

    /// Creates a new `Stream` parser at offset.
    ///
    /// Returns an error when `offset` is out of bounds.
    pub fn new_at(
        data: []const u8,
        offset: usize,
    ) Error!Stream {
        return if (offset <= data.len)
            .{ .data = data, .offset = offset }
        else
            error.ParseFail;
    }

    /// Parses the type from the steam.
    ///
    /// Returns an error when there is not enough data left in the stream
    /// or the type parsing failed.
    pub fn read(
        self: *Stream,
        T: type,
    ) Error!T {
        const size = size_of(T);

        const bytes = try self.read_bytes(size);
        return switch (has_trait(T, "FromData")) {
            .int => std.mem.readInt(T, bytes[0..size], .big),
            .impl => try T.FromData.parse(bytes[0..size]),
            inline else => |F, tag| {
                const i = std.mem.readInt(F, bytes[0..size], .big);
                return switch (tag) {
                    .@"enum" => @enumFromInt(i),
                    .wrapper => .{i},
                    .fancy_wrapper => .{ .inner = i },
                    .flags => @bitCast(i),
                    else => unreachable,
                };
            },
        };
    }

    /// [ARS] Parses the type from the steam.
    ///
    /// [ARS] Only to be used for Optional Offsets (nonzero)
    pub fn read_optional(
        self: *Stream,
        T: type,
    ) Error!?T {
        const F = switch (has_trait(T, "FromData")) {
            .wrapper => |F| F,
            else => @compileError("read_optional only to be used for wrappers"),
        };

        const size: usize = @typeInfo(F).int.bits / 8;
        const bytes = try self.read_bytes(size);
        const ret = std.mem.readInt(F, bytes[0..size], .big);
        if (ret == 0) return null;
        return .{ret};
    }

    /// Parses the type from the steam at offset.
    pub fn read_at(
        self: *Stream,
        T: type,
        offset: usize,
    ) Error!T {
        // [ARS] different impl from Rust's
        self.offset = offset;
        return try self.read(T);
    }

    /// Reads N bytes from the stream.
    pub fn read_bytes(
        self: *Stream,
        len: usize,
    ) Error![]const u8 {
        // [ARS] simulate Rust behaviour
        const end = if (@import("builtin").mode == .debug) e: {
            const end = self.offset + len;

            // [RazrFalcon]
            // An integer overflow here on 32bit systems is almost guarantee to be caused
            // by an incorrect parsing logic from the caller side.
            // Simply using `checked_add` here would silently swallow errors, which is not what we want.
            std.debug.assert(end <= std.math.maxInt(u32));
            break :e end;
        } else try std.math.add(usize, self.offset, len);

        if (self.offset > self.data.len) return error.ParseFail;
        if (end > self.data.len) return error.ParseFail;

        defer self.advance(len);
        return self.data[self.offset..][0..len];
    }

    /// Reads the next `count` types as a slice.
    pub fn read_array(
        self: *Stream,
        T: type,
        // u16 or u32
        count: anytype,
    ) Error!LazyArray(@TypeOf(count), T) {
        const size = size_of(T);
        const len = count * size;
        const bytes = try self.read_bytes(len);
        return LazyArray(@TypeOf(count), T).new(bytes);
    }

    /// Reads the next `count` types as a slice.
    pub fn read_array_optional(
        self: *Stream,
        T: type,
        // u16 or u32
        count: anytype,
    ) Error!LazyArray(@TypeOf(count), ?T) {
        const F = switch (has_trait(T, "FromData")) {
            .wrapper => |F| F,
            else => @compileError("read_array_optional only to be used for wrappers"),
        };

        const size: usize = @typeInfo(F).int.bits / 8;
        const len = count * size;
        const bytes = try self.read_bytes(len);
        return LazyArray(@TypeOf(count), ?T).new(bytes);
    }

    /// Parses the `count` types as a slice from the steam at offset.
    pub fn read_array_at(
        self: *Stream,
        T: type,
        count: anytype,
        offset: usize,
    ) Error!LazyArray(@TypeOf(count), T) {
        self.offset = offset;
        return try self.read_array(T, count);
    }

    /// Advances by `FromData.SIZE`.
    ///
    /// Doesn't check bounds.
    pub fn skip(
        self: *Stream,
        T: type,
    ) void {
        const size = size_of(T);
        self.advance(size);
    }

    /// Advances by the specified `len`.
    ///
    /// Doesn't check bounds.
    pub fn advance(
        self: *Stream,
        len: usize,
    ) void {
        self.offset += len;
    }

    /// Advances by the specified `len` and checks for bounds.
    /// return `true` if it advances
    pub fn advance_checked(
        self: *Stream,
        len: usize,
    ) Error!void {
        if (self.offset + len > self.data.len) return error.ParseFail;
        self.advance(len);
    }

    /// Returns the trailing data.
    ///
    /// Returns an error when `Stream` is reached the end.
    pub fn tail(
        self: *Stream,
    ) Error![]const u8 {
        if (self.offset > self.data.len) return error.ParseFail;
        return self.data[self.offset..];
    }

    /// Checks that stream reached the end of the data.
    pub fn at_end(
        self: Stream,
    ) bool {
        return self.offset >= self.data.len;
    }

    /// Jumps to the end of the stream.
    ///
    /// Useful to indicate that we parsed all the data.
    pub fn jump_to_end(
        self: *Stream,
    ) void {
        self.offset = self.data.len;
    }
};

pub inline fn size_of(T: type) usize {
    if (T == void) return 0;
    if (@typeInfo(T) == .optional) // [ARS] for LazyArray16(?Offset16) to work
        return size_of(@typeInfo(T).optional.child);

    return switch (has_trait(T, "FromData")) {
        .int => @typeInfo(T).int.bits / 8,
        .impl => T.FromData.SIZE,
        inline else => |F| @typeInfo(F).int.bits / 8,
    };
}

pub fn parse_struct_from_data(
    T: type,
    data: *const [T.FromData.SIZE]u8,
) Error!T {
    comptime {
        // Check whether T.FromData.SIZE is correct
        var sum = 0;
        for (@typeInfo(T).@"struct".field_types) |FieldType| sum += size_of(FieldType);
        std.debug.assert(T.FromData.SIZE == sum);
    }

    var s = Stream.new(data);
    var ret: T = undefined;

    // hope it is order of declaration
    inline for (@typeInfo(T).@"struct".field_names, 0..) |f_name, i| {
        const FType = @typeInfo(T).@"struct".field_types[i];
        switch (@typeInfo(FType)) {
            .void => {},
            .optional => |o| @field(ret, f_name) = try s.read_optional(o.child),
            else => @field(ret, f_name) = try s.read(FType),
        }
    }

    return ret;
}

pub const Error = error{
    ParseFail,
    Overflow,
    DataError,
};

pub const SearchError = error{
    NotFound,
    DataError,
};

inline fn has_trait(
    T: type,
    comptime trait: []const u8,
) union(enum) {
    int,
    wrapper: type,
    fancy_wrapper: type,
    flags: type,
    @"enum": type,
    impl,
} {
    switch (@typeInfo(T)) {
        .int => {
            assert_divisible_by_8(T, T);
            return .int;
        },
        .@"struct" => |s| {
            if (@hasDecl(T, trait)) return .impl;

            if (s.backing_integer) |F| {
                assert_divisible_by_8(F, T);
                return .{ .flags = F };
            }

            if (s.field_names.len == 1) {
                const F = s.field_types[0];
                assert_divisible_by_8(F, T);

                if (s.is_tuple)
                    return .{ .wrapper = F };

                if (@hasField(T, "inner"))
                    return .{ .fancy_wrapper = F };
            }
        },
        .@"enum" => |e| {
            if (@hasDecl(T, trait)) return .impl;

            if (e.mode == .nonexhaustive) {
                assert_divisible_by_8(e.tag_type, T);
                return .{ .@"enum" = e.tag_type };
            }
        },
        else => if (@hasDecl(T, trait)) return .impl,
    }

    @compileError(@typeName(T) ++ " does not implement trait " ++ trait);
}

fn assert_divisible_by_8(
    F: type,
    T: type,
) void {
    if (@typeInfo(F).int.bits % 8 != 0)
        @compileError(@typeName(T) ++ " must have bitcount divisble by 8");
}
