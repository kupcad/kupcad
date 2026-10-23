//! File helpers for the CLI commands: `readFile` reads a file it is given and `readStdin`
//! what is piped in, under the size cap, and `replaceFileAtomic` replaces a file's contents
//! without ever leaving it half-written.

const std = @import("std");

/// The most the CLI reads of a file it is given (a script, a project or parameter file):
/// a script's limit, so the CLI never accepts a file the parser would reject.
const MAX_FILE_BYTES = @import("../core/limits.zig").MAX_SOURCE_BYTES;

/// The file at `file_path`, at most MAX_FILE_BYTES (error.StreamTooLong past it); the
/// caller frees it.
pub fn readFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(MAX_FILE_BYTES));
}

/// What stdin holds, to its end, at most MAX_FILE_BYTES (error.StreamTooLong past it); the
/// caller frees it.
pub fn readStdin(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buf);
    return reader.interface.allocRemaining(allocator, .limited(MAX_FILE_BYTES));
}

/// Replaces `file_path`'s contents with `data` atomically: the new contents go to a
/// temporary file beside it, which is renamed over it with its permissions, so a crash
/// or a full disk never leaves a half-written file.
pub fn replaceFileAtomic(io: std.Io, file_path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, file_path, .{});
    var atomic = try cwd.createFileAtomic(io, file_path, .{ .permissions = stat.permissions, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.replace(io);
}
