//! Files packed into one buffer: how a host gives the core many files in one call (the wasm
//! build's `files`, a map of paths to contents in JavaScript). Each file is its path, then its
//! content, each with its length first (u32, little-endian), one file after another to the
//! end: `[path_len][path][content_len][content]...`. `unpack` writes them into a Vfs, trusting
//! nothing of the buffer; `pack` writes the buffer, for a host in Zig and the tests.

const std = @import("std");
const Vfs = @import("vfs.zig").Vfs;

/// A length, as written before a path and before a content.
const LEN_BYTES = 4;

pub const File = struct {
    path: []const u8,
    content: []const u8,
};

/// `files` packed; the caller owns the bytes. A path or a content longer than a u32 counts
/// is error.FieldTooLong.
pub fn pack(allocator: std.mem.Allocator, files: []const File) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (files) |file| {
        try writeField(&out.writer, file.path);
        try writeField(&out.writer, file.content);
    }
    return try out.toOwnedSlice();
}

fn writeField(writer: *std.Io.Writer, bytes: []const u8) !void {
    const len = std.math.cast(u32, bytes.len) orelse return error.FieldTooLong;
    try writer.writeInt(u32, len, .little);
    try writer.writeAll(bytes);
}

/// Writes the files packed in `bytes` into `vfs`, a later file over an earlier one at the
/// same path. error.MalformedFiles when a length runs past the end of the buffer, or a file
/// is cut short: nothing of the buffer is trusted.
pub fn unpack(vfs: Vfs, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const path = try takeField(&rest);
        const content = try takeField(&rest);
        try vfs.writeFile(path, content);
    }
}

/// The field at the start of `rest`, which then starts after it.
fn takeField(rest: *[]const u8) ![]const u8 {
    if (rest.len < LEN_BYTES) return error.MalformedFiles;
    const len = std.mem.readInt(u32, rest.*[0..LEN_BYTES], .little);
    const after = rest.*[LEN_BYTES..];
    if (len > after.len) return error.MalformedFiles;
    rest.* = after[len..];
    return after[0..len];
}
