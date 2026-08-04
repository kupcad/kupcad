const std = @import("std");
const api = @import("../api.zig");

const FILE_SIZE_LIMIT = 1024 * 1024 * 10;

// ANSI Color Codes for terminal output
const Color = struct {
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const reset = "\x1b[0m";
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
    const file_path = args_iter.next() orelse {
        std.debug.print("Error: Missing file path. Usage: kupcad check <file>\n", .{});
        return;
    };

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, allocator, .limited(FILE_SIZE_LIMIT));
    defer allocator.free(source);

    const diags = try api.checkCode(allocator, source);
    defer {
        for (diags) |d| allocator.free(d.message);
        allocator.free(diags);
    }

    if (diags.len == 0) {
        std.debug.print("{s}Success: No CAD geometry, syntax, or semantic issues found.{s}\n", .{ Color.green, Color.reset });
    } else {
        std.debug.print("\n", .{});

        var errors: usize = 0;
        var warnings: usize = 0;
        var infos: usize = 0;

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
                .@"error" => errors += 1,
                .warning => warnings += 1,
                .info => infos += 1,
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

            // Pad spaces up to the column
            var i: usize = 0;
            while (i < col_idx) : (i += 1) {
                std.debug.print(" ", .{});
            }

            // Print the correct number of carets (fallback to 1 if length is 0 for EOF/synthetic nodes)
            std.debug.print("{s}", .{sev_color});
            const squiggles = if (d.loc.length > 0) d.loc.length else 1;
            var j: u32 = 0;
            while (j < squiggles) : (j += 1) {
                std.debug.print("^", .{});
            }
            std.debug.print("{s}\n\n", .{Color.reset});
        }

        // Summary footer
        std.debug.print("{d} files inspected, {s}{d} errors{s}, {s}{d} warnings{s}, {s}{d} info{s} detected.\n", .{
            1, // Hardcoded to 1 for now since the CLI takes a single file path
            Color.red,
            errors,
            Color.reset,
            Color.yellow,
            warnings,
            Color.reset,
            Color.cyan,
            infos,
            Color.reset,
        });
    }
}
