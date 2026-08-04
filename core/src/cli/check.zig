const std = @import("std");
const api = @import("../api.zig");
const ProjectConfig = @import("config.zig").ProjectConfig;
const LintConfig = @import("../tools/lint/config.zig").Config;

const FILE_SIZE_LIMIT = 1024 * 1024 * 10;

// ANSI Color Codes for terminal output
const Color = struct {
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const reset = "\x1b[0m";
};

// Track aggregate stats across all files
const Totals = struct {
    files: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,
    infos: usize = 0,
};

/// Helper to extract a specific 1-indexed line from the raw source string.
fn getSourceLine(source: []const u8, target_line: u32) []const u8 {
    var line_num: u32 = 1;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        if (line_num == target_line) {
            // Manually trim the trailing carriage return if on Windows CRLF
            var trimmed = line;
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }
            return trimmed;
        }
        line_num += 1;
    }
    return "";
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    var totals = Totals{};

    // Using Unmanaged ArrayList to bypass the removed `.init()` API
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);

    var config_path: ?[]const u8 = null;

    // Separate flags from target file/dir paths
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args_iter.next() orelse {
                std.debug.print("Error: Missing value for --config. Usage: kupcad check [--config <file>] <file|dir>...\n", .{});
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
        std.debug.print("Error: Missing file path. Usage: kupcad check [--config <file>] <file|dir>...\n", .{});
        std.process.exit(1);
    }

    for (paths.items) |path| {
        try processPath(init, allocator, path, &totals, config.lint);
    }

    // Final Summary Footer
    if (totals.errors == 0 and totals.warnings == 0 and totals.infos == 0) {
        std.debug.print("\n{s}Success: No CAD geometry, syntax, or semantic issues found across {d} file(s).{s}\n", .{ Color.green, totals.files, Color.reset });
    } else {
        std.debug.print("\n{d} file(s) inspected, {s}{d} errors{s}, {s}{d} warnings{s}, {s}{d} info{s} detected.\n", .{
            totals.files,
            Color.red,
            totals.errors,
            Color.reset,
            Color.yellow,
            totals.warnings,
            Color.reset,
            Color.cyan,
            totals.infos,
            Color.reset,
        });
    }

    // Ensure CI/CD pipelines fail if there are any linting errors
    if (totals.errors > 0) {
        std.process.exit(1);
    }
}

fn processPath(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8, totals: *Totals, lint_config: LintConfig) !void {
    const cwd = std.Io.Dir.cwd();

    // Attempt to open the path as a directory first (sidesteps needing to stat the path)
    if (cwd.openDir(init.io, path, .{ .iterate = true })) |dir_obj| {
        var dir = dir_obj;
        defer dir.close(init.io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(init.io)) |entry| {
            // Filter strictly for `.kup` files
            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".kup")) {
                const full_path = try std.fs.path.join(allocator, &.{ path, entry.path });
                defer allocator.free(full_path);
                try processFile(init, allocator, full_path, totals, lint_config);
            }
        }
    } else |err| {
        if (err == error.NotDir) {
            // It's a file, not a directory! Safely process it.
            try processFile(init, allocator, path, totals, lint_config);
        } else {
            std.debug.print("{s}Error accessing '{s}': {}{s}\n", .{ Color.red, path, err, Color.reset });
            // Consider an access error a failure condition
            totals.errors += 1;
        }
    }
}

fn processFile(init: std.process.Init, allocator: std.mem.Allocator, file_path: []const u8, totals: *Totals, lint_config: LintConfig) !void {
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, file_path, allocator, .limited(FILE_SIZE_LIMIT)) catch |err| {
        std.debug.print("{s}Error reading '{s}': {}{s}\n", .{ Color.red, file_path, err, Color.reset });
        totals.errors += 1;
        return;
    };
    defer allocator.free(source);

    totals.files += 1;

    const diags = try api.checkCode(allocator, source, lint_config);
    defer {
        for (diags) |d| allocator.free(d.message);
        allocator.free(diags);
    }

    if (diags.len > 0) {
        for (diags) |d| {
            const sev_color = switch (d.severity) {
                .@"error" => Color.red,
                .warning => Color.yellow,
                .info => Color.cyan,
            };
            const sev_char = switch (d.severity) {
                .@"error" => "E",
                .warning => "W",
                .info => "I",
            };

            switch (d.severity) {
                .@"error" => totals.errors += 1,
                .warning => totals.warnings += 1,
                .info => totals.infos += 1,
            }

            // Print the header (e.g., path/to/file.kup:10:5: W: Message goes here)
            std.debug.print("{s}{s}:{d}:{d}:{s} {s}{s}:{s} {s}\n", .{
                Color.cyan, file_path, d.loc.line,  d.loc.col, Color.reset,
                sev_color,  sev_char,  Color.reset, d.message,
            });

            // Extract and print the exact line of code
            const source_line = getSourceLine(source, d.loc.line);
            std.debug.print("{s}\n", .{source_line});

            // Print the squigglies mapping to the exact column and token length
            const col_idx = if (d.loc.col > 0) d.loc.col - 1 else 0;

            var i: usize = 0;
            while (i < col_idx) : (i += 1) {
                std.debug.print(" ", .{});
            }

            std.debug.print("{s}", .{sev_color});
            const squiggles = if (d.loc.length > 0) d.loc.length else 1;
            var j: u32 = 0;
            while (j < squiggles) : (j += 1) {
                std.debug.print("^", .{});
            }
            std.debug.print("{s}\n\n", .{Color.reset});
        }
    }
}
