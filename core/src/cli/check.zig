const std = @import("std");
const api = @import("../api.zig");
const LintConfig = @import("../tools/lint/config.zig").Config;
const walker = @import("walker.zig");
const log_helpers = @import("../log.zig");
const LimitAllocator = @import("../core/limit_allocator.zig").LimitAllocator;
const report = @import("diagnostic_report.zig");
const Color = report.Color;
const Outcome = @import("outcome.zig").Outcome;

const Totals = struct {
    files: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,
    infos: usize = 0,
    config: LintConfig,
    compiler_memory_limit: ?usize = null,
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !Outcome {
    // CommandSetup has already reported what was wrong with the arguments or config.
    var setup = @import("options.zig").CommandSetup.init(allocator, init.io, args_iter, "check") catch return .failure;
    defer setup.deinit(allocator);

    var totals = Totals{
        .config = setup.config.lint,
        .compiler_memory_limit = setup.config.compiler_memory_limit, // Hook it up
    };

    // A path that can't be read is an error, not "0 files, no issues". The count is added
    // after the walk: processFile updates `totals` itself, and `totals.errors += walk()`
    // would read the old count first and overwrite those updates.
    const unreadable = try walker.walkPaths(init.io, allocator, setup.options.paths.items, &totals, processFile);
    totals.errors += unreadable;

    if (totals.errors == 0 and totals.warnings == 0 and totals.infos == 0) {
        log_helpers.printStdout(init.io, "\n{s}Success: No CAD geometry, syntax, or semantic issues found across {d} file(s).{s}\n", .{ Color.green, totals.files, Color.reset });
    } else {
        log_helpers.printStderr(init.io, "\n{d} file(s) inspected, {s}{d} errors{s}, {s}{d} warnings{s}, {s}{d} info{s} detected.\n", .{
            totals.files, Color.red,       totals.errors, Color.reset,
            Color.yellow, totals.warnings, Color.reset,   Color.cyan,
            totals.infos, Color.reset,
        });
    }
    return if (totals.errors > 0) .failure else .success;
}

fn processFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void {
    var totals: *Totals = @ptrCast(@alignCast(context.?));
    totals.files += 1;

    // Apply the Memory Sandbox
    var limit_alloc: ?LimitAllocator = null;
    var compile_allocator = allocator;
    if (totals.compiler_memory_limit) |limit| {
        limit_alloc = LimitAllocator.init(allocator, limit);
        compile_allocator = limit_alloc.?.allocator();
    }

    const diags = api.checkCode(compile_allocator, io, source, totals.config) catch |err| {
        if (err == error.OutOfMemory) {
            log_helpers.printStderr(io, "{s}Sandbox Error: '{s}' exceeded memory limit during AST parsing.{s}\n", .{ Color.red, file_path, Color.reset });
        } else {
            log_helpers.printStderr(io, "{s}Error checking '{s}': {}{s}\n", .{ Color.red, file_path, err, Color.reset });
        }
        totals.errors += 1;
        return;
    };
    defer api.freeDiagnostics(compile_allocator, diags);

    if (diags.len > 0) {
        const line_index = try api.LineIndex.init(compile_allocator, source);
        defer line_index.deinit(compile_allocator);

        var rendered: std.Io.Writer.Allocating = .init(allocator);
        defer rendered.deinit();
        for (diags) |d| {
            switch (d.severity) {
                .@"error" => totals.errors += 1,
                .warning => totals.warnings += 1,
                .info => totals.infos += 1,
            }
            try report.write(&rendered.writer, .{
                .file_path = file_path,
                .source = source,
                .line_index = &line_index,
                .offset = d.loc.offset,
                .length = d.loc.length,
                .severity = d.severity,
                .message = d.message,
            });
        }
        log_helpers.printStderr(io, "{s}", .{rendered.written()});
    }
}
