//! The `kupcad` executable: dispatches the first argument to a subcommand from `COMMANDS`
//! (build, watch, check, fmt, doc, pkg, lsp, dev, version) and answers `--help` and
//! `--version`.

const std = @import("std");
const build_cmd = @import("cli/build_cmd.zig");
const fmt_cmd = @import("cli/fmt.zig");
const check_cmd = @import("cli/check.zig");
const lsp_cmd = @import("cli/lsp.zig");
const doc_cmd = @import("cli/doc.zig");
const pkg_cmd = @import("cli/pkg_cmd.zig");
const dev_cmd = @import("cli/dev.zig");
const watch_cmd = @import("cli/watch.zig");
const run_cmd = @import("cli/run_cmd.zig");
const version_cmd = @import("cli/version_cmd.zig");
const outcome_mod = @import("cli/outcome.zig");
const Outcome = outcome_mod.Outcome;
const log_helpers = @import("log.zig");
const cli_args = @import("cli/args.zig");
const Args = cli_args.Args;
const crash_report = @import("crash_report.zig");

// Export std_options for the compiler
pub const std_options = log_helpers.std_options;
/// A panic writes a crash report first when KUPCAD_CRASH_DIR asks for one (crash_report.zig).
pub const panic = std.debug.FullPanic(crash_report.panic);

const Command = struct {
    name: []const u8,
    summary: []const u8,
    /// What `kupcad <name> --help` prints; the command's own errors quote it too.
    usage: []const u8,
    run: *const fn (std.process.Init, std.mem.Allocator, *Args) anyerror!Outcome,
};

/// Every subcommand: dispatch and the usage text both come from this table.
pub const COMMANDS = [_]Command{
    .{ .name = "build", .summary = "Run a KupCAD script and export its final geometry", .usage = build_cmd.USAGE, .run = build_cmd.execute },
    .{ .name = "run", .summary = "Run a KupCAD script, printing what it prints, writing no model", .usage = run_cmd.USAGE, .run = run_cmd.execute },
    .{ .name = "watch", .summary = "Rebuild a script whenever it changes", .usage = watch_cmd.USAGE, .run = watch_cmd.execute },
    .{ .name = "check", .summary = "Lint and analyze KupCAD files", .usage = check_cmd.USAGE, .run = check_cmd.execute },
    .{ .name = "fmt", .summary = "Format KupCAD files", .usage = fmt_cmd.USAGE, .run = fmt_cmd.execute },
    .{ .name = "doc", .summary = "Extract parameter metadata and docstrings as JSON", .usage = doc_cmd.USAGE, .run = doc_cmd.execute },
    .{ .name = "pkg", .summary = "Manage dependencies (init, add, install, prune, doctor)", .usage = pkg_cmd.USAGE, .run = pkg_cmd.execute },
    .{ .name = "lsp", .summary = "Start the Language Server over stdio", .usage = lsp_cmd.USAGE, .run = runLsp },
    .{ .name = "dev", .summary = "Developer tools and compiler debugging utilities", .usage = dev_cmd.USAGE, .run = dev_cmd.execute },
    .{ .name = "version", .summary = "Show the version (--json: with the protocol and platform)", .usage = version_cmd.USAGE, .run = version_cmd.execute },
};

pub const USAGE = blk: {
    var text: []const u8 = "Usage: kupcad <command> [options]\n\nCommands:\n";
    for (COMMANDS) |c| text = text ++ std.fmt.comptimePrint("  {s: <7} {s}\n", .{ c.name, c.summary });
    break :blk text ++ "\nOptions:\n  -h, --help     Show this help\n  -V, --version  Show the kupcad version\n\nRun 'kupcad <command> --help' for a command's options.\n";
};

const GlobalFlag = enum { help, version };

fn globalFlag(arg: []const u8) ?GlobalFlag {
    const flags = [_]struct { []const u8, GlobalFlag }{
        .{ "-h", .help },    .{ "--help", .help },       .{ "help", .help },
        .{ "-V", .version }, .{ "--version", .version },
    };
    for (flags) |f| if (std.mem.eql(u8, arg, f[0])) return f[1];
    return null;
}

fn runLsp(init: std.process.Init, allocator: std.mem.Allocator, args: *Args) anyerror!Outcome {
    return lsp_cmd.execute(init, allocator, args);
}

pub fn main(init: std.process.Init) void {
    const outcome = dispatch(init) catch |err| blk: {
        // Commands report the failures they expect; anything reaching here is unexpected,
        // so name it instead of dumping an error return trace on the user.
        log_helpers.printStderr(init.io, "Error: {s}\n", .{@errorName(err)});
        break :blk .failure;
    };
    if (outcome == .failure) std.process.exit(outcome_mod.EXIT_FAILURE);
}

/// The arguments after the executable name, for the life of the process.
fn processArgs(init: std.process.Init) ![]const []const u8 {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const items = try arena.alloc([]const u8, argv.len -| 1);
    for (items, argv[argv.len - items.len ..]) |*item, arg| item.* = arg;
    return items;
}

fn dispatch(init: std.process.Init) !Outcome {
    const argv = try processArgs(init);
    if (argv.len == 0) {
        log_helpers.printStderr(init.io, USAGE, .{});
        return .failure;
    }
    const name = argv[0];
    if (globalFlag(name)) |flag| {
        log_helpers.printStdout(init.io, "{s}", .{switch (flag) {
            .help => USAGE,
            .version => version_cmd.TEXT,
        }});
        return .success;
    }
    for (COMMANDS) |c| {
        if (!std.mem.eql(u8, name, c.name)) continue;
        crash_report.enable(init.environ_map, c.name);
        if (cli_args.wantsHelp(argv[1..])) {
            log_helpers.printStdout(init.io, "{s}", .{c.usage});
            return .success;
        }
        var args: Args = .{ .items = argv[1..] };
        return c.run(init, init.gpa, &args);
    }
    log_helpers.printStderr(init.io, "Error: Unknown command '{s}'\n\n" ++ USAGE, .{name});
    return .failure;
}

test {
    _ = @import("main_test.zig");
    _ = @import("crash_report_test.zig");
    _ = @import("cli/lsp.zig");
    _ = @import("cli/lsp_test.zig");
    _ = @import("cli/lsp_inbox_test.zig");
    _ = @import("cli/lsp_preview_test.zig");
    _ = @import("cli/lsp_worker_test.zig");
    _ = @import("cli/version_cmd_test.zig");
}
