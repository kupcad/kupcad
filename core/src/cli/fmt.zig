//! `kupcad fmt`: formats .kup files with `api.formatCode`, printing them, listing the ones
//! that aren't formatted (`--check`) or rewriting them in place (`--write`); with `--stdin`,
//! the source piped in, for an editor that formats a buffer.

const std = @import("std");
const api = @import("../api.zig");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const walker = @import("walker.zig");
const fs = @import("fs.zig");
const Reporter = @import("reporter.zig").Reporter;
const plural = @import("reporter.zig").plural;
pub const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;
const CommandSetup = @import("options.zig").CommandSetup(struct { check: bool = false, write: bool = false, stdin: bool = false });

pub const USAGE =
    \\Usage: kupcad fmt [--check | --write] [--config <file>] <file|dir>...
    \\       kupcad fmt --stdin [--check] [--config <file>]
    \\
    \\Formats .kup files. Without --check or --write it prints them formatted.
    \\
    \\Options:
    \\  --check          List the files that aren't formatted, and fail if there are any
    \\  --write          Rewrite the files that aren't formatted, in place
    \\  --stdin          Format the source piped in and print it (with --check, name it
    \\                   <stdin> and fail if it isn't formatted)
    \\  --config <file>  Read format settings from <file> instead of .kupcad.json
    \\  -h, --help       Show this help
    \\
;

/// What the source piped in is called where a file's path would be.
pub const STDIN_NAME = "<stdin>";

pub const Mode = enum {
    /// Print each file formatted.
    print,
    /// Name each file that isn't formatted; fail if any.
    check,
    /// Rewrite each file that isn't formatted.
    write,
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    // CommandSetup has already reported what was wrong with the arguments or config.
    var setup = CommandSetup.init(allocator, init.io, args_iter, USAGE) catch return .failure;
    defer setup.deinit(allocator);
    const flags = setup.options.flags;
    const reporter: Reporter = .forProcess(init);
    if (flags.check and flags.write) {
        reporter.err("Error: --check and --write can't be used together\n\n" ++ USAGE, .{});
        return .failure;
    }
    const mode: Mode = if (flags.check) .check else if (flags.write) .write else .print;
    if (flags.stdin) {
        if (flags.write or setup.options.paths.items.len > 0) {
            reporter.err("Error: --stdin formats what is piped in: it takes no files and no --write\n\n" ++ USAGE, .{});
            return .failure;
        }
        const source = fs.readStdin(init.io, allocator) catch |err| {
            reporter.err("Error: Could not read stdin: {s}\n", .{@errorName(err)});
            return .failure;
        };
        defer allocator.free(source);
        return runSource(allocator, source, setup.config.fmt, mode, reporter);
    }
    return run(allocator, setup.options.paths.items, setup.config.fmt, mode, reporter);
}

/// Formats `source` (piped in, named STDIN_NAME) as `mode` says: printed formatted, or with
/// `.check` named and failing if it isn't formatted.
pub fn runSource(allocator: std.mem.Allocator, source: []const u8, config: FmtConfig, mode: Mode, reporter: Reporter) !Outcome {
    std.debug.assert(mode != .write);
    var state: Run = .{ .config = config, .mode = mode, .reporter = reporter };
    try processFile(reporter.io, allocator, STDIN_NAME, source, &state);
    return state.outcome();
}

const Run = struct {
    config: FmtConfig,
    mode: Mode,
    reporter: Reporter,
    /// Files that couldn't be formatted (a syntax error, a write that failed, ...).
    failed: usize = 0,
    /// Files whose formatting differs from their contents.
    unformatted: usize = 0,
    fn outcome(self: *const Run) Outcome {
        return if (self.failed > 0 or (self.mode == .check and self.unformatted > 0)) .failure else .success;
    }
};

/// Formats every .kup file under `paths` as `mode` says. Returns failure if a file can't
/// be formatted, or with `.check` if one isn't formatted.
pub fn run(allocator: std.mem.Allocator, paths: []const []const u8, config: FmtConfig, mode: Mode, reporter: Reporter) !Outcome {
    var state: Run = .{ .config = config, .mode = mode, .reporter = reporter };
    // Added after the walk: processFile updates `state.failed` itself (see check.zig).
    const unreadable = try walker.walkPaths(reporter, allocator, paths, &state, processFile);
    state.failed += unreadable;
    if (mode == .check and state.unformatted > 0) {
        reporter.err("{d} {s} formatting; run kupcad fmt --write to fix {s}.\n", .{ state.unformatted, plural(state.unformatted, "file needs", "files need"), plural(state.unformatted, "it", "them") });
    }
    return state.outcome();
}

fn processFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void {
    const state: *Run = @ptrCast(@alignCast(context.?));

    const formatted = api.formatCode(allocator, source, state.config) catch |err| {
        switch (err) {
            error.SyntaxError => state.reporter.err("Error: '{s}' has syntax errors; kupcad check shows them\n", .{file_path}),
            error.FormatChangedProgram => state.reporter.err("Error: formatting '{s}' would change what it does, so it was left as it is. This is a formatter bug; please report it.\n", .{file_path}),
            else => state.reporter.err("Error: Could not format '{s}': {s}\n", .{ file_path, @errorName(err) }),
        }
        state.failed += 1;
        return;
    };
    defer allocator.free(formatted);

    const changed = !std.mem.eql(u8, source, formatted);
    switch (state.mode) {
        .print => state.reporter.out("{s}", .{formatted}),
        .check => if (changed) {
            state.reporter.out("{s}\n", .{file_path});
            state.unformatted += 1;
        },
        .write => if (changed) {
            fs.replaceFileAtomic(io, file_path, formatted) catch |err| {
                state.reporter.err("Error: Could not write '{s}': {s}\n", .{ file_path, @errorName(err) });
                state.failed += 1;
                return;
            };
            state.reporter.out("{s}\n", .{file_path});
        },
    }
}
