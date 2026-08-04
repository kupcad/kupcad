const std = @import("std");
const api = @import("../api.zig");
const ProjectConfig = @import("config.zig").ProjectConfig;
const FmtConfig = @import("../tools/fmt/config.zig").Config;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);

    var config_path: ?[]const u8 = null;

    // Separate flags from target file/dir paths
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args_iter.next() orelse {
                std.debug.print("Error: Missing value for --config. Usage: kupcad fmt [--config <file>] <file|dir>...\n", .{});
                std.process.exit(1);
            };
        } else {
            try paths.append(allocator, arg);
        }
    }

    const config = ProjectConfig.load(init, allocator, config_path) catch |err| {
        std.debug.print("Error parsing configuration file: {}\n", .{err});
        std.process.exit(1);
    };

    if (paths.items.len == 0) {
        std.debug.print("Error: Missing file path. Usage: kupcad fmt [--config <file>] <file|dir>...\n", .{});
        std.process.exit(1);
    }

    for (paths.items) |path| {
        try processPath(init, allocator, path, config.fmt);
    }
}

fn processPath(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8, fmt_config: FmtConfig) !void {
    const cwd = std.Io.Dir.cwd();

    if (cwd.openDir(init.io, path, .{ .iterate = true })) |dir_obj| {
        var dir = dir_obj;
        defer dir.close(init.io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(init.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".kup")) {
                const full_path = try std.fs.path.join(allocator, &.{ path, entry.path });
                defer allocator.free(full_path);
                try processFile(init, allocator, full_path, fmt_config);
            }
        }
    } else |err| {
        if (err == error.NotDir) {
            try processFile(init, allocator, path, fmt_config);
        } else {
            std.debug.print("Error accessing '{s}': {}\n", .{ path, err });
        }
    }
}

fn processFile(init: std.process.Init, allocator: std.mem.Allocator, file_path: []const u8, fmt_config: FmtConfig) !void {
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, file_path, allocator, .limited(1024 * 1024 * 10)) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(source);

    const formatted = api.formatCode(allocator, source, fmt_config) catch |err| {
        std.debug.print("Format failed for '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(formatted);

    std.debug.print("{s}", .{formatted});
}
