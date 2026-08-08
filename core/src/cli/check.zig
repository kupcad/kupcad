const std = @import("std");
const api = @import("../api.zig");
const ProjectConfig = @import("config.zig").ProjectConfig;
const LintConfig = @import("../tools/lint/config.zig").Config;
const CommandOptions = @import("options.zig").CommandOptions;
const walker = @import("walker.zig");

const Color = struct {
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const reset = "\x1b[0m";
};

const Totals = struct {
    files: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,
    infos: usize = 0,
    config: LintConfig,
};

fn getSourceLine(source: []const u8, target_line: u32) []const u8 {
    var line_num: u32 = 1;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        if (line_num == target_line) {
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
    var setup = try @import("options.zig").CommandSetup.init(allocator, init.io, args_iter, "check");
    defer setup.deinit(allocator);

    var totals = Totals{ .config = setup.config.lint };
    try walker.walkPaths(init.io, allocator, setup.options.paths.items, &totals, processFile);

    if (totals.errors == 0 and totals.warnings == 0 and totals.infos == 0) {
        std.debug.print("\n{s}Success: No CAD geometry, syntax, or semantic issues found across {d} file(s).{s}\n", .{ Color.green, totals.files, Color.reset });
    } else {
        std.debug.print("\n{d} file(s) inspected, {s}{d} errors{s}, {s}{d} warnings{s}, {s}{d} info{s} detected.\n", .{
            totals.files, Color.red,       totals.errors, Color.reset,
            Color.yellow, totals.warnings, Color.reset,   Color.cyan,
            totals.infos, Color.reset,
        });
    }

    if (totals.errors > 0) std.process.exit(1);
}

fn processFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void {
    _ = io;
    var totals = @as(*Totals, @ptrCast(@alignCast(context.?)));
    totals.files += 1;

    const diags = api.checkCode(allocator, source, totals.config) catch |err| {
        std.debug.print("{s}Error checking '{s}': {}{s}\n", .{ Color.red, file_path, err, Color.reset });
        totals.errors += 1;
        return;
    };
    defer api.freeDiagnostics(allocator, diags);

    if (diags.len > 0) {
        for (diags) |d| {
            const sev_color = d.severity.toColor();
            const sev_char = d.severity.toChar();

            switch (d.severity) {
                .@"error" => totals.errors += 1,
                .warning => totals.warnings += 1,
                .info => totals.infos += 1,
            }

            std.debug.print("{s}{s}:{d}:{d}:{s} {s}{s}:{s} {s}\n", .{ Color.cyan, file_path, d.loc.line, d.loc.col, Color.reset, sev_color, sev_char, Color.reset, d.message });

            // Use the centralized utility from the LineIndex API
            const source_line = api.LineIndex.getSourceLine(source, d.loc.line);
            std.debug.print("{s}\n", .{source_line});

            const col_idx = if (d.loc.col > 0) d.loc.col - 1 else 0;
            for (0..col_idx) |_| std.debug.print(" ", .{});
            std.debug.print("{s}", .{sev_color});

            const squiggles = if (d.loc.length > 0) d.loc.length else 1;
            for (0..squiggles) |_| std.debug.print("^", .{});
            std.debug.print("{s}\n\n", .{Color.reset});
        }
    }
}
