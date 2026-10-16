//! File helpers for the CLI commands: `readFileLimit` reads a file under a size cap and
//! `replaceFileAtomic` replaces a file's contents without ever leaving it half-written.

const std = @import("std");

/// Reads a file with a maximum size limit.
/// Returns an allocated slice that the caller is responsible for freeing.
pub fn readFileLimit(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    max_size: usize,
) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    return try cwd.readFileAlloc(io, file_path, allocator, .limited(max_size));
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
