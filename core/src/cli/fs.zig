//! File helpers for the CLI commands: `readFile` reads a file it is given and `readStdin`
//! what is piped in, under the size cap, `replaceFileAtomic` replaces a file's contents
//! without ever leaving it half-written, and `nearestAncestorWith` finds the folder a
//! project's file marks.

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

/// The nearest of `folder` (absolute) and the folders above it that holds one of `markers`:
/// a slice of `folder`, or null for none. The walk stops after `top` (absolute: `folder` or
/// a folder above it) when one is given, else at the root. A marker that can't be looked
/// for (a folder that can't be read) is an error. The settings file and the project's folder
/// were each found by a walk of their own.
pub fn nearestAncestorWith(io: std.Io, allocator: std.mem.Allocator, folder: []const u8, top: ?[]const u8, markers: []const []const u8) !?[]const u8 {
    var at: ?[]const u8 = folder;
    while (at) |candidate| : (at = std.fs.path.dirname(candidate)) {
        for (markers) |name| {
            const marker = try std.fs.path.join(allocator, &.{ candidate, name });
            defer allocator.free(marker);
            if (std.Io.Dir.cwd().access(io, marker, .{})) |_| return candidate else |err| if (err != error.FileNotFound) return err;
        }
        if (top) |last| if (std.mem.eql(u8, candidate, last)) return null;
    }
    return null;
}
