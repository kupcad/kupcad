const std = @import("std");
const build_info = @import("build_info");
const build_cmd = @import("cli/build_cmd.zig");
const fmt_cmd = @import("cli/fmt.zig");
const check_cmd = @import("cli/check.zig");
const lsp_cmd = @import("cli/lsp.zig");
const doc_cmd = @import("cli/doc.zig");
const pkg_cmd = @import("cli/pkg_cmd.zig");
const dev_cmd = @import("cli/dev.zig");
const watch_cmd = @import("cli/watch.zig");
const outcome_mod = @import("cli/outcome.zig");
const Outcome = outcome_mod.Outcome;
const log_helpers = @import("log.zig");

// Export std_options for the compiler
pub const std_options = log_helpers.std_options;

const Command = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (std.process.Init, std.mem.Allocator, *std.process.Args.Iterator) anyerror!Outcome,
};

/// Every subcommand: dispatch and the usage text both come from this table.
const COMMANDS = [_]Command{
    .{ .name = "build", .summary = "Run a KupCAD script and export its final geometry", .run = build_cmd.execute },
    .{ .name = "watch", .summary = "Rebuild a script whenever it changes", .run = watch_cmd.execute },
    .{ .name = "check", .summary = "Lint and analyze KupCAD files", .run = check_cmd.execute },
    .{ .name = "fmt", .summary = "Format KupCAD files", .run = fmt_cmd.execute },
    .{ .name = "doc", .summary = "Extract parameter metadata and docstrings as JSON", .run = doc_cmd.execute },
    .{ .name = "pkg", .summary = "Manage dependencies (init, add, install, prune, doctor)", .run = pkg_cmd.execute },
    .{ .name = "lsp", .summary = "Start the Language Server over stdio", .run = runLsp },
    .{ .name = "dev", .summary = "Developer tools and compiler debugging utilities", .run = dev_cmd.execute },
};

pub const USAGE = blk: {
    var text: []const u8 = "Usage: kupcad <command> [options]\n\nCommands:\n";
    for (COMMANDS) |c| text = text ++ std.fmt.comptimePrint("  {s: <6} {s}\n", .{ c.name, c.summary });
    break :blk text ++ "\nOptions:\n  -h, --help     Show this help\n  -V, --version  Show the kupcad version\n";
};

pub const VERSION_TEXT = "kupcad " ++ build_info.version ++ "\n";

const GlobalFlag = enum { help, version };

fn globalFlag(arg: []const u8) ?GlobalFlag {
    const flags = [_]struct { []const u8, GlobalFlag }{
        .{ "-h", .help },    .{ "--help", .help },       .{ "help", .help },
        .{ "-V", .version }, .{ "--version", .version }, .{ "version", .version },
    };
    for (flags) |f| if (std.mem.eql(u8, arg, f[0])) return f[1];
    return null;
}

fn runLsp(init: std.process.Init, allocator: std.mem.Allocator, _: *std.process.Args.Iterator) anyerror!Outcome {
    return lsp_cmd.execute(init, allocator);
}

pub fn main(init: std.process.Init) void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip(); // Skip the executable name itself

    const outcome = dispatch(init, &args_iter) catch |err| blk: {
        // Commands report the failures they expect; anything reaching here is unexpected,
        // so name it instead of dumping an error return trace on the user.
        log_helpers.printStderr(init.io, "Error: {s}\n", .{@errorName(err)});
        break :blk .failure;
    };
    if (outcome == .failure) std.process.exit(outcome_mod.EXIT_FAILURE);
}

fn dispatch(init: std.process.Init, args_iter: *std.process.Args.Iterator) !Outcome {
    const name = args_iter.next() orelse {
        log_helpers.printStderr(init.io, USAGE, .{});
        return .failure;
    };
    if (globalFlag(name)) |flag| {
        log_helpers.printStdout(init.io, "{s}", .{switch (flag) {
            .help => USAGE,
            .version => VERSION_TEXT,
        }});
        return .success;
    }
    for (COMMANDS) |c| {
        if (std.mem.eql(u8, name, c.name)) return c.run(init, init.gpa, args_iter);
    }
    log_helpers.printStderr(init.io, "Error: Unknown command '{s}'\n\n" ++ USAGE, .{name});
    return .failure;
}

test {
    _ = @import("main_test.zig");
}
