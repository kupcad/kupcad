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
