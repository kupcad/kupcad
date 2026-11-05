//! Where a script named on the command line runs: the folder its file system is rooted at
//! (its imports, its packages and its own exports are read and written from there) and its
//! path from there. One under the current directory runs in its project's folder there: the
//! nearest from its own folder up to the current directory that holds a kupcad.json (the
//! package manifest, whose packages are installed beside it), else the current directory,
//! as it always has, however it is named (`parts/a.kup`, or its absolute path, which a file
//! system refuses). Rooted at the current directory, `kupcad run proj/main.kup` read the
//! packages of `proj` from `./.kupcad/pkg`. One outside it (`../parts/a.kup`) runs in its
//! project's folder, the nearest above it that holds a kupcad.json or a .kupcad.json, else
//! in its own. Rooted at the current directory, it could import nothing.

const std = @import("std");
const fs = @import("fs.zig");
const CONFIG_FILE_NAME = @import("config.zig").FILE_NAME;
const MANIFEST_FILE_NAME = @import("../pkg/manifest.zig").FILE_NAME;
const under = @import("../core/subpath.zig").under;
const Reporter = @import("reporter.zig").Reporter;

/// What marks the folder of a project outside the current directory: its package manifest,
/// or its settings.
const PROJECT_FILES = [_][]const u8{ MANIFEST_FILE_NAME, CONFIG_FILE_NAME };

pub const ScriptRoot = struct {
    /// The folder: the current directory, or one opened here (`opened`)
    dir: std.Io.Dir,
    opened: bool,
    /// The script's path as it was named (borrowed), and from `dir` (owned)
    input: []const u8,
    path: []u8,
    /// The folder's path from the current directory: empty for the current directory. Owned.
    prefix: []u8,

    /// The root of the script at `script_path` (as given, from the current directory).
    pub fn of(io: std.Io, allocator: std.mem.Allocator, script_path: []const u8) !ScriptRoot {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        const absolute = try std.fs.path.resolve(allocator, &.{ cwd, script_path });
        defer allocator.free(absolute);
        const folder = std.fs.path.dirname(absolute) orelse return error.FileNotFound;
        const project = if (under(absolute, cwd) != null)
            try fs.nearestAncestorWith(io, allocator, folder, cwd, &.{MANIFEST_FILE_NAME}) orelse cwd
        else
            try fs.nearestAncestorWith(io, allocator, folder, null, &PROJECT_FILES) orelse folder;

        const path = try std.fs.path.relativeAlloc(allocator, cwd, null, project, absolute);
        errdefer allocator.free(path);
        const prefix = try std.fs.path.relativeAlloc(allocator, cwd, null, cwd, project);
        errdefer allocator.free(prefix);
        if (prefix.len == 0) return .{ .dir = std.Io.Dir.cwd(), .opened = false, .input = script_path, .path = modulePathOf(path), .prefix = prefix };
        const dir = try std.Io.Dir.cwd().openDir(io, project, .{});
        return .{ .dir = dir, .opened = true, .input = script_path, .path = modulePathOf(path), .prefix = prefix };
    }

    /// The root of the script at `script_path` for a command, or null, why not reported (its
    /// folder can't be opened).
    pub fn open(io: std.Io, allocator: std.mem.Allocator, script_path: []const u8, reporter: Reporter) !?ScriptRoot {
        return of(io, allocator, script_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                reporter.err("Error: Could not read '{s}': {s}\n", .{ script_path, @errorName(err) });
                reporter.fail(.{ .kind = "read", .message = @errorName(err), .file = script_path });
                return null;
            },
        };
    }

    pub fn deinit(self: *ScriptRoot, io: std.Io, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.prefix);
        if (self.opened) self.dir.close(io);
    }

    /// How a message names the module at `module_path` (from the root), as the person running
    /// kupcad finds it: the script as they named it, another from the current directory.
    /// Owned.
    pub fn shown(self: *const ScriptRoot, allocator: std.mem.Allocator, module_path: []const u8) ![]u8 {
        if (std.mem.eql(u8, module_path, self.path)) return allocator.dupe(u8, self.input);
        if (self.prefix.len == 0) return allocator.dupe(u8, module_path);
        return std.fs.path.join(allocator, &.{ self.prefix, module_path });
    }
};

/// `relative`, a path from the root, as a module's path: `/` between its folders, as imports
/// join them (import_path.zig). Windows gave `parts\main.kup`, whose folder an import's
/// POSIX join didn't find, so its neighbours were read from the root, or refused. In place.
fn modulePathOf(relative: []u8) []u8 {
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, relative, std.fs.path.sep, '/');
    return relative;
}

/// The project folder `folder` is in (absolute): the nearest from it up holding one of
/// PROJECT_FILES, else `folder` itself. Owned.
pub fn projectFolder(io: std.Io, allocator: std.mem.Allocator, folder: []const u8) ![]u8 {
    return allocator.dupe(u8, try fs.nearestAncestorWith(io, allocator, folder, null, &PROJECT_FILES) orelse folder);
}
