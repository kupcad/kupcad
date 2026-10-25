//! Where a script named on the command line runs: the folder its file system is rooted at
//! (its imports and its own exports are read and written from there) and its path from
//! there. One under the current directory runs there, as it always has, however it is named
//! (`parts/a.kup`, or its absolute path, which a file system refuses); one outside it
//! (`../parts/a.kup`) runs in its project's folder, the nearest above it that holds a
//! kupcad.json or a .kupcad.json, else in its own. Rooted at the current directory, either
//! could import nothing.

const std = @import("std");
const CONFIG_FILE_NAME = @import("config.zig").FILE_NAME;
const Reporter = @import("reporter.zig").Reporter;

/// What marks a project's folder: its package manifest, or its settings.
const PROJECT_FILES = [_][]const u8{ "kupcad.json", CONFIG_FILE_NAME };

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
        const inside = try std.fs.path.relativeAlloc(allocator, cwd, null, cwd, script_path);
        if (!isOutside(inside)) {
            errdefer allocator.free(inside);
            return .{ .dir = std.Io.Dir.cwd(), .opened = false, .input = script_path, .path = inside, .prefix = try allocator.dupe(u8, "") };
        }
        allocator.free(inside);

        const absolute = try std.fs.path.resolve(allocator, &.{ cwd, script_path });
        defer allocator.free(absolute);
        const folder = std.fs.path.dirname(absolute) orelse return error.FileNotFound;
        const project = try projectOf(io, allocator, folder);
        defer allocator.free(project);
        const path = try std.fs.path.relativeAlloc(allocator, cwd, null, project, absolute);
        errdefer allocator.free(path);
        const prefix = try std.fs.path.relativeAlloc(allocator, cwd, null, cwd, project);
        errdefer allocator.free(prefix);
        const dir = try std.Io.Dir.cwd().openDir(io, project, .{});
        return .{ .dir = dir, .opened = true, .input = script_path, .path = path, .prefix = prefix };
    }

    /// The root of the script at `script_path` for a command, or null, why not reported (its
    /// folder can't be opened).
    pub fn open(io: std.Io, allocator: std.mem.Allocator, script_path: []const u8, reporter: Reporter) !?ScriptRoot {
        return of(io, allocator, script_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                reporter.err("Error: Could not read '{s}': {s}\n", .{ script_path, @errorName(err) });
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

/// Whether a path relative to a folder leads out of it.
fn isOutside(relative: []const u8) bool {
    if (std.fs.path.isAbsolute(relative)) return true;
    var it = std.mem.tokenizeAny(u8, relative, "/\\");
    const first = it.next() orelse return false;
    return std.mem.eql(u8, first, "..");
}

/// The project folder `folder` is in (absolute): the nearest from it up holding one of
/// PROJECT_FILES, else `folder` itself. Owned.
fn projectOf(io: std.Io, allocator: std.mem.Allocator, folder: []const u8) ![]u8 {
    var at: ?[]const u8 = folder;
    while (at) |candidate| : (at = std.fs.path.dirname(candidate)) {
        for (PROJECT_FILES) |name| {
            const marker = try std.fs.path.join(allocator, &.{ candidate, name });
            defer allocator.free(marker);
            if (std.Io.Dir.cwd().access(io, marker, .{})) |_| return allocator.dupe(u8, candidate) else |_| {}
        }
    }
    return allocator.dupe(u8, folder);
}
