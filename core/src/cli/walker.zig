//! `walkPaths`: runs a callback on every `.kup` file under the files and directories given to
//! `kupcad fmt` and `kupcad check`, skipping hidden directories and reporting unreadable paths.

const std = @import("std");
const fs = @import("fs.zig");
const Reporter = @import("reporter.zig").Reporter;
const progress = @import("progress.zig");

/// Generic file processor callback.
pub const ProcessFileFn = *const fn (io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void;

/// Calls `processFn` for every `.kup` file under `paths` (files or directories). Hidden
/// directories (`.git`, `.kupcad` with the installed packages) are skipped on the way: a
/// walk used to descend into them, so `fmt --write .` rewrote the dependencies. A hidden
/// path named outright is still processed. The files are found first and then processed,
/// so the progress line (progress.zig) counts them done of all.
/// Returns how many paths or files could not be read; they are reported through
/// `reporter` (the command's own output) and skipped, so one bad path doesn't hide
/// results for the rest, but callers must still fail.
pub fn walkPaths(reporter: Reporter, allocator: std.mem.Allocator, paths: []const []const u8, context: ?*anyopaque, processFn: ProcessFileFn) !usize {
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }
    var unreadable = try findFiles(reporter, allocator, paths, &files);
    for (files.items, 0..) |file, done| {
        progress.amount(done, files.items.len, .files);
        if (!try readAndProcess(reporter, allocator, file, context, processFn)) unreadable += 1;
    }
    return unreadable;
}

/// Appends the path of every `.kup` file under `paths` to `files` (owned), in the order
/// walked; returns how many paths couldn't be read, reported.
fn findFiles(reporter: Reporter, allocator: std.mem.Allocator, paths: []const []const u8, files: *std.ArrayList([]const u8)) !usize {
    const io = reporter.io;
    const cwd = std.Io.Dir.cwd();
    var unreadable: usize = 0;

    for (paths) |path| {
        if (cwd.openDir(io, path, .{ .iterate = true })) |dir_obj| {
            var dir = dir_obj;
            defer dir.close(io);

            var dir_walker = try dir.walk(allocator);
            defer dir_walker.deinit();

            while (try dir_walker.next(io)) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".kup") and !underHiddenDir(entry.path)) {
                    try appendOwned(allocator, files, try std.fs.path.join(allocator, &.{ path, entry.path }));
                }
            }
        } else |err| {
            if (err == error.NotDir) {
                try appendOwned(allocator, files, try allocator.dupe(u8, path));
            } else {
                reportUnreadable(reporter, path, err);
                unreadable += 1;
            }
        }
    }
    return unreadable;
}

fn appendOwned(allocator: std.mem.Allocator, files: *std.ArrayList([]const u8), path: []const u8) !void {
    errdefer allocator.free(path);
    try files.append(allocator, path);
}

/// Whether a path relative to the walked directory has a hidden directory among its parents.
fn underHiddenDir(rel_path: []const u8) bool {
    const dir_part = std.fs.path.dirname(rel_path) orelse return false;
    var parts = std.mem.splitAny(u8, dir_part, "/\\");
    while (parts.next()) |part| {
        if (part.len > 1 and part[0] == '.') return true;
    }
    return false;
}

fn reportUnreadable(reporter: Reporter, path: []const u8, err: anyerror) void {
    reporter.err("Error: Could not read '{s}': {s}\n", .{ path, @errorName(err) });
}

/// False if the file could not be read (reported; the walk continues).
fn readAndProcess(reporter: Reporter, allocator: std.mem.Allocator, file_path: []const u8, context: ?*anyopaque, processFn: ProcessFileFn) !bool {
    const source = fs.readFile(reporter.io, allocator, file_path) catch |err| {
        reportUnreadable(reporter, file_path, err);
        return false;
    };
    defer allocator.free(source);

    try processFn(reporter.io, allocator, file_path, source, context);
    return true;
}
