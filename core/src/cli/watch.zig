//! `kupcad watch`: builds a script, then rebuilds it through its `ScriptSession` whenever the
//! `Watcher` sees it or a module it imports change; given export options (export_flags.zig,
//! as `kupcad build` takes them), each build that succeeds writes them.

const std = @import("std");
const watcher_mod = @import("../session/watcher.zig");
const Watcher = watcher_mod.Watcher;
const ScriptSession = @import("../session/session.zig").ScriptSession;
const Reporter = @import("reporter.zig").Reporter;
const build_cmd = @import("build_cmd.zig");
const limits = @import("../core/limits.zig");
const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;
const param_flags = @import("param_flags.zig");
const memory_flag = @import("memory_flag.zig");
const time_flag = @import("time_flag.zig");
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const script_options = @import("script_options.zig");
const ScriptOptions = script_options.ScriptOptions;
const ExportFlags = @import("export_flags.zig").ExportFlags;
const export_usage = @import("export_flags.zig").USAGE;

pub const USAGE =
    \\Usage: kupcad watch <file.kup> [options]
    \\
    \\Builds a script, then rebuilds it whenever it, a module it imports or a file it
    \\reads as data changes. With an export option, as build takes them, each build
    \\that succeeds writes its files.
    \\
    \\Options:
    \\
++ export_usage ++ param_flags.USAGE ++ memory_flag.USAGE ++ time_flag.USAGE ++ script_options.ERRORS_USAGE ++
    \\  -h, --help                Show this help
    \\
;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    var reporter: Reporter = .forProcess(init);
    var options = try ScriptOptions.parse(allocator, args_iter, init.environ_map, reporter, .when_given, USAGE) orelse return .failure;
    defer options.deinit(allocator);
    reporter.errors = options.errors;
    const file_path = options.input_path;

    // The script reads and writes the disk from where its imports are
    var root = try ScriptRoot.open(init.io, allocator, file_path, reporter) orelse return .failure;
    defer root.deinit(init.io, allocator);
    var disk = NativeVfs.init(init.io, root.dir);
    var script_session = try ScriptSession.init(allocator, init.io, disk.vfs());
    defer script_session.deinit();
    // The watcher holds it for the life of the process
    const session = &script_session;
    // As `kupcad build` sets up, but a long-lived session caps the script heap: without a
    // limit given or the project's, the interactive default, so a runaway loop ends with an
    // error instead of the machine. --timeout holds each build, which evaluateWorkspace
    // starts it again for.
    const exports: ?*const ExportFlags = if (options.writes) &options.exports else null;
    const source = try build_cmd.setUp(allocator, session, &root, &options, exports, limits.INTERACTIVE_MEMORY_LIMIT, reporter) orelse return .failure;
    defer allocator.free(source);

    _ = try session.workspace.addModule(root.path, source);
    try session.loadImports();

    var printer = EventPrinter{ .allocator = allocator, .session = session, .root = &root, .reporter = reporter, .exports = exports };
    var watcher = try Watcher.init(session, init.io, root.dir, printer.listener());
    defer watcher.deinit();
    // What is exported is the root's run, which the VM must hold after every build
    if (exports != null) watcher.run_again = root.path;

    // The first build is reported like any other, and a failed one is watched for a fix
    // (the command used to exit on it).
    _ = watcher.evaluate();
    reporter.err("Watching {s} and the modules it imports; Ctrl+C stops.\n", .{file_path});
    try watcher.start();
    return .success;
}

/// Prints the watcher's events the way `kupcad build` reports: diagnostics with their
/// file, line and column, then a one-line summary, and with `--errors json` the line a host
/// reads (it told a compile error as a syntax one, and a run's failure not at all).
pub const EventPrinter = struct {
    allocator: std.mem.Allocator,
    session: *ScriptSession,
    /// Where the script runs, and how it was named
    root: *const ScriptRoot,
    reporter: Reporter,
    /// What a build that succeeds writes, if anything.
    exports: ?*const ExportFlags = null,

    pub fn listener(self: *EventPrinter) watcher_mod.Listener {
        return .{ .ptr = self, .onEvent = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: watcher_mod.Event) void {
        const self: *EventPrinter = @ptrCast(@alignCast(ptr));
        switch (event) {
            .changed => |path| self.reporter.err("Changed: {s}\n", .{path}),
            .built => {
                self.reporter.err("Built {s}\n", .{self.root.input});
                // A file that can't be written is reported, and the next build tries again
                if (self.exports) |exports| _ = exports.write(self.allocator, &self.session.vm, self.root.input, self.reporter) catch |err| {
                    self.reporter.err("Could not write the model: {s}\n", .{@errorName(err)});
                };
            },
            .failed => |failed| build_cmd.reportEvaluationFailure(self.allocator, self.session, failed, self.root, self.reporter) catch |err| {
                self.reporter.err("Build failed ({s}); the errors couldn't be printed: {s}\n", .{ self.root.input, @errorName(err) });
            },
            .reload_failed => |r| self.reporter.err("Could not reload '{s}': {s}\n", .{ r.path, @errorName(r.err) }),
        }
    }
};
