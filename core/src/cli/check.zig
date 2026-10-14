const std = @import("std");
const api = @import("../api.zig");
const LintConfig = @import("../tools/lint/config.zig").Config;
const walker = @import("walker.zig");
const LimitAllocator = @import("../core/limit_allocator.zig").LimitAllocator;
const report = @import("diagnostic_report.zig");
const Reporter = @import("reporter.zig").Reporter;
const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;
const CommandSetup = @import("options.zig").CommandSetup(struct {});

pub const USAGE =
    \\Usage: kupcad check [--config <file>] <file|dir>...
    \\
    \\Reports syntax errors, mistakes the compiler finds and lint warnings in .kup files.
    \\
    \\Options:
    \\  --config <file>  Read lint settings from <file> instead of .kupcad.json
    \\  -h, --help       Show this help
    \\
;

const Totals = struct {
    files: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,
    infos: usize = 0,
    config: LintConfig,
    compiler_memory_limit: ?usize = null,
    reporter: Reporter,
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    // CommandSetup has already reported what was wrong with the arguments or config.
    var setup = CommandSetup.init(allocator, init.io, args_iter, USAGE) catch return .failure;
    defer setup.deinit(allocator);

    const reporter: Reporter = .forProcess(init);
    var totals = Totals{
        .config = setup.config.lint,
        .compiler_memory_limit = setup.config.compiler_memory_limit, // Hook it up
        .reporter = reporter,
    };

    // A path that can't be read is an error, not "0 files, no issues". The count is added
    // after the walk: processFile updates `totals` itself, and `totals.errors += walk()`
    // would read the old count first and overwrite those updates.
    const unreadable = try walker.walkPaths(init.io, allocator, setup.options.paths.items, &totals, processFile);
    totals.errors += unreadable;

    if (totals.errors == 0 and totals.warnings == 0 and totals.infos == 0) {
        const c = reporter.out_style;
        reporter.out("\n{s}Success: No CAD geometry, syntax, or semantic issues found across {d} file(s).{s}\n", .{ c.green, totals.files, c.reset });
    } else {
        const c = reporter.err_style;
        reporter.err("\n{d} file(s) inspected, {s}{d} errors{s}, {s}{d} warnings{s}, {s}{d} info{s} detected.\n", .{
            totals.files, c.red,           totals.errors, c.reset,
            c.yellow,     totals.warnings, c.reset,       c.cyan,
            totals.infos, c.reset,
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

    const c = totals.reporter.err_style;
    const diags = api.checkCode(compile_allocator, io, source, totals.config) catch |err| {
        if (err == error.OutOfMemory) {
            totals.reporter.err("{s}Sandbox Error: '{s}' exceeded memory limit during AST parsing.{s}\n", .{ c.red, file_path, c.reset });
        } else {
            totals.reporter.err("{s}Error checking '{s}': {}{s}\n", .{ c.red, file_path, err, c.reset });
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
            }, c);
        }
        totals.reporter.err("{s}", .{rendered.written()});
    }
}
