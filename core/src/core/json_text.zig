//! JSON as KupCAD writes it for a host or a front end (a build's report, a preview frame,
//! `--errors json`) and text as the C API hands it over: std.json's, except that a string
//! that isn't UTF-8 is written as text, each byte that doesn't start a UTF-8 sequence
//! U+FFFD. std.json writes such a []const u8 as an array of numbers, so a DXF layer named in
//! a codepage (byte 0xD8) made an error's message `[73, 109, ...]`, which no host reads as
//! the message. Script text can hold any bytes (`"\xD8"`, a file it read).

const std = @import("std");
const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;

/// What a byte that isn't UTF-8 is written as.
const REPLACEMENT = std.unicode.replacement_character_utf8;

/// `v` as JSON on `writer`, as std.json.Stringify.value writes it, its strings as text.
pub fn value(v: anytype, options: Stringify.Options, writer: *Writer) Writer.Error!void {
    var jws: Stringify = .{ .writer = writer, .options = options };
    try write(&jws, v);
}

/// `v` as JSON, owned by `gpa`.
pub fn valueAlloc(gpa: std.mem.Allocator, v: anytype, options: Stringify.Options) error{OutOfMemory}![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    value(v, options, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `v` as JSON for `{f}`, as std.json.fmt formats it.
pub fn fmt(v: anytype, options: Stringify.Options) Formatter(@TypeOf(v)) {
    return .{ .value = v, .options = options };
}

pub fn Formatter(comptime T: type) type {
    return struct {
        value: T,
        options: Stringify.Options,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            try value(self.value, self.options, writer);
        }
    };
}

/// `bytes` as UTF-8 text, NUL-terminated for C, owned by `gpa`: each byte that doesn't
/// start a UTF-8 sequence U+FFFD (a NUL it holds stays, its length saying where it ends).
pub fn textZ(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![:0]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var rest = bytes;
    while (rest.len > 0) {
        const valid = validPrefix(rest);
        out.writer.writeAll(rest[0..valid]) catch return error.OutOfMemory;
        rest = rest[valid..];
        if (rest.len == 0) break;
        out.writer.writeAll(&REPLACEMENT) catch return error.OutOfMemory;
        rest = rest[1..];
    }
    return out.toOwnedSliceSentinel(0);
}

/// How many bytes `bytes` starts with that are UTF-8: whole sequences, none overlong, of no
/// surrogate, up to U+10FFFF.
fn validPrefix(bytes: []const u8) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch break;
        if (len > bytes.len - i) break;
        if (len > 1) _ = std.unicode.utf8Decode(bytes[i..][0..len]) catch break;
        i += len;
    }
    return i;
}

/// `bytes` as a JSON string, each byte that isn't UTF-8 U+FFFD.
fn writeString(jws: *Stringify, bytes: []const u8) Writer.Error!void {
    try jws.beginWriteRaw();
    try jws.writer.writeByte('"');
    var rest = bytes;
    while (rest.len > 0) {
        const valid = validPrefix(rest);
        try Stringify.encodeJsonStringChars(rest[0..valid], jws.options, jws.writer);
        rest = rest[valid..];
        if (rest.len == 0) break;
        try Stringify.encodeJsonStringChars(&REPLACEMENT, jws.options, jws.writer);
        rest = rest[1..];
    }
    try jws.writer.writeByte('"');
    jws.endWriteRaw();
}

/// `v` as Stringify.write writes it, down through its structs, slices and optionals, its
/// strings by writeString. A type with its own jsonStringify writes itself.
fn write(jws: *Stringify, v: anytype) Writer.Error!void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (ptr.child == u8) return writeString(jws, v);
                try jws.beginArray();
                for (v) |item| try write(jws, item);
                return jws.endArray();
            },
            .one => switch (@typeInfo(ptr.child)) {
                .array => |array| return write(jws, @as([]const array.child, v)),
                else => return write(jws, v.*),
            },
            else => return jws.write(v),
        },
        .array => return write(jws, &v),
        .optional => return if (v) |inner| write(jws, inner) else jws.write(null),
        .@"struct" => |info| {
            if (comptime std.meta.hasFn(T, "jsonStringify") or info.is_tuple) return jws.write(v);
            try jws.beginObject();
            inline for (info.field_names, info.field_types) |name, field_type| {
                const field_value = @field(v, name);
                const skipped = field_type == void or (@typeInfo(field_type) == .optional and !jws.options.emit_null_optional_fields and field_value == null);
                if (!skipped) {
                    try jws.objectField(name);
                    try write(jws, field_value);
                }
            }
            return jws.endObject();
        },
        else => return jws.write(v),
    }
}
