//! `kupcad check`: reports syntax errors, compile errors and lint findings in .kup files as
//! text, JSON or SARIF (through `api.checkCode`), and with `--fix` applies the safe fixes
//! (`api.fixCode`) and rewrites the files.

const std = @import("std");
const api = @import("../api.zig");
const LintConfig = @import("../tools/lint/config.zig").Config;
const RuleSet = @import("../tools/lint/linter.zig").RuleSet;
const walker = @import("walker.zig");
const LimitAllocator = @import("../core/limit_allocator.zig").LimitAllocator;
const report = @import("diagnostic_report.zig");
const Reporter = @import("reporter.zig").Reporter;
const plural = @import("reporter.zig").plural;
const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;
const CommandSetup = @import("options.zig").CommandSetup(struct {
    fix: bool = false,
    format: ?[]const u8 = null,
    @"max-warnings": ?[]const u8 = null,
});
const output = @import("check_output.zig");
const fs = @import("fs.zig");

pub const USAGE =
    \\Usage: kupcad check [--fix] [--format text|json|sarif] [--max-warnings <n>]
    \\                    [--config <file>] <file|dir>...
    \\
    \\Reports syntax errors, mistakes the compiler finds and lint warnings in .kup files.
    \\
    \\Options:
    \\  --fix            Apply the fixes that keep the model the same (renaming an unused
    \\                   `x` to `_x`) and rewrite the files, then report what is left
    \\  --format <kind>  text (the default), json, or sarif for code scanning (GitHub);
    \\                   json and sarif write one document to stdout
    \\  --max-warnings <n>
    \\                   Fail when there are more than <n> warnings (0 fails on any)
    \\  --config <file>  Read lint settings from <file> instead of .kupcad.json
    \\  -h, --help       Show this help
    \\
    \\Rules. Set a rule's level (off, info, warning or error) under "lint" in .kupcad.json,
    \\for example "unused-variable": "off".
    \\
++ ruleList() ++ "\n";

/// One line per lint rule: its id and what it finds.
fn ruleList() []const u8 {
    comptime var list: []const u8 = "";
    inline for (RuleSet.ids) |id| list = list ++ std.fmt.comptimePrint("  {s:<18} {s}\n", .{ id, @FieldType(RuleSet, id).description });
    return list;
}

const Totals = struct {
    files: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,
    infos: usize = 0,
    config: LintConfig,
    fix: bool = false,
    format: output.Format = .text,
    /// Findings for the json and sarif formats, written once the run ends.
    collected: ?*output.Collector = null,
    compiler_memory_limit: ?usize = null,
    reporter: Reporter,
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    // CommandSetup has already reported what was wrong with the arguments or config.
    var setup = CommandSetup.init(allocator, init.io, args_iter, USAGE) catch return .failure;
    defer setup.deinit(allocator);

    const reporter: Reporter = .forProcess(init);
    const flags = setup.options.flags;
    const format = if (flags.format) |name| std.meta.stringToEnum(output.Format, name) orelse {
        reporter.err("Error: --format is text, json or sarif, not '{s}'\n", .{name});
        return .failure;
    } else .text;
    const max_warnings: ?usize = if (flags.@"max-warnings") |n| std.fmt.parseInt(usize, n, 10) catch {
        reporter.err("Error: --max-warnings takes a whole number, not '{s}'\n", .{n});
        return .failure;
    } else null;
    var collector = output.Collector.init(allocator);
    defer collector.deinit();

    var totals = Totals{
        .config = setup.config.lint,
        .fix = flags.fix,
        .format = format,
        .collected = if (format == .text) null else &collector,
        .compiler_memory_limit = setup.config.compiler_memory_limit, // Hook it up
        .reporter = reporter,
    };

    // A path that can't be read is an error, not "0 files, no issues". The count is added
    // after the walk: processFile updates `totals` itself, and `totals.errors += walk()`
    // would read the old count first and overwrite those updates.
    const unreadable = try walker.walkPaths(reporter, allocator, setup.options.paths.items, &totals, processFile);
    totals.errors += unreadable;

    const too_many_warnings = if (max_warnings) |max| totals.warnings > max else false;
    const outcome: Outcome = if (totals.errors > 0 or too_many_warnings) .failure else .success;
    if (format != .text) {
        var buffer: std.Io.Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        switch (format) {
            .json => try collector.writeJson(&buffer.writer, .{ .files = totals.files, .errors = totals.errors, .warnings = totals.warnings, .infos = totals.infos }),
            .sarif => try collector.writeSarif(&buffer.writer),
            .text => unreachable,
        }
        reporter.out("{s}", .{buffer.written()});
        if (too_many_warnings) reporter.err("{d} {s}, more than --max-warnings {d}\n", .{ totals.warnings, plural(totals.warnings, "warning", "warnings"), max_warnings.? });
        return outcome;
    }

    if (totals.errors == 0 and totals.warnings == 0 and totals.infos == 0) {
        const c = reporter.out_style;
        reporter.out("\n{s}Success: No CAD geometry, syntax, or semantic issues found across {d} {s}.{s}\n", .{ c.green, totals.files, plural(totals.files, "file", "files"), c.reset });
    } else {
        const c = reporter.err_style;
        reporter.err("\n{d} {s} inspected, {s}{d} {s}{s}, {s}{d} {s}{s}, {s}{d} info{s} detected.\n", .{
            totals.files,                                   plural(totals.files, "file", "files"),
            c.red,                                          totals.errors,
            plural(totals.errors, "error", "errors"),       c.reset,
            c.yellow,                                       totals.warnings,
            plural(totals.warnings, "warning", "warnings"), c.reset,
            c.cyan,                                         totals.infos,
            c.reset,
        });
    }
    if (too_many_warnings) reporter.err("{s}Failed: {d} {s}, more than --max-warnings {d}.{s}\n", .{ reporter.err_style.red, totals.warnings, plural(totals.warnings, "warning", "warnings"), max_warnings.?, reporter.err_style.reset });
    return outcome;
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
    // With --fix, what is reported is what the fixed file still has.
    var fixed: ?[]u8 = null;
    defer if (fixed) |f| compile_allocator.free(f);
    if (totals.fix) fixed = fixFile(io, compile_allocator, file_path, source, totals) catch |err| blk: {
        totals.reporter.err("{s}Error fixing '{s}': {}{s}\n", .{ c.red, file_path, err, c.reset });
        totals.errors += 1;
        break :blk null;
    };
    const checked = fixed orelse source;

    const diags = api.checkCode(compile_allocator, io, checked, totals.config) catch |err| {
        if (err == error.OutOfMemory) {
            totals.reporter.err("{s}Sandbox Error: '{s}' exceeded memory limit during AST parsing.{s}\n", .{ c.red, file_path, c.reset });
        } else {
            totals.reporter.err("{s}Error checking '{s}': {}{s}\n", .{ c.red, file_path, err, c.reset });
        }
        totals.errors += 1;
        return;
    };
    defer api.freeDiagnostics(compile_allocator, diags);

    if (totals.collected) |collector| {
        for (diags) |d| countFinding(totals, d);
        return collector.add(file_path, checked, diags);
    }
    if (diags.len > 0) {
        const line_index = try api.LineIndex.init(compile_allocator, checked);
        defer line_index.deinit(compile_allocator);

        var rendered: std.Io.Writer.Allocating = .init(allocator);
        defer rendered.deinit();
        for (diags) |d| {
            countFinding(totals, d);
            try report.write(&rendered.writer, .{
                .file_path = file_path,
                .source = checked,
                .line_index = &line_index,
                .offset = d.loc.offset,
                .length = d.loc.length,
                .severity = d.severity,
                .message = d.message,
                .rule = d.rule,
            }, c);
        }
        totals.reporter.err("{s}", .{rendered.written()});
    }
}

/// Applies the safe fixes to the file and writes it back if anything changed. Returns the
/// fixed text (the caller frees it), or null when nothing changed.
fn fixFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, totals: *Totals) !?[]u8 {
    const c = totals.reporter.err_style;
    const result = try api.fixCode(allocator, io, source, totals.config);
    if (result.refused) {
        totals.reporter.err("{s}{s}: a fix would have broken or changed the model in this file and was left out; please report it{s}\n", .{ c.yellow, file_path, c.reset });
    }
    if (std.mem.eql(u8, result.source, source)) {
        allocator.free(result.source);
        return null;
    }
    errdefer allocator.free(result.source);
    try fs.replaceFileAtomic(io, file_path, result.source);
    totals.reporter.err("{s}Fixed {d} {s} in {s}{s}\n", .{ c.green, result.fixes, plural(result.fixes, "problem", "problems"), file_path, c.reset });
    return result.source;
}

fn countFinding(totals: *Totals, d: api.LinterDiagnostic) void {
    switch (d.severity) {
        .@"error" => totals.errors += 1,
        .warning => totals.warnings += 1,
        .info => totals.infos += 1,
    }
}
