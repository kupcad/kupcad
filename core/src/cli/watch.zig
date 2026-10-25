//! `kupcad watch`: builds a script, then rebuilds it through its `ScriptSession` whenever the `Watcher` sees it or a module it imports change; given export options
//! (export_flags.zig, as `kupcad build` takes them), each build that succeeds writes them.

const std = @import("std");
const watcher_mod = @import("../session/watcher.zig");
const Watcher = watcher_mod.Watcher;
const ScriptSession = @import("../session/session.zig").ScriptSession;
const Reporter = @import("reporter.zig").Reporter;
const build_cmd = @import("build_cmd.zig");
const fs = @import("fs.zig");
const ProjectConfig = @import("config.zig").ProjectConfig;
const CONFIG_FILE_NAME = @import("config.zig").FILE_NAME;
const limits = @import("../core/limits.zig");
const debugger = @import("debugger.zig");
const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;
const param_flags = @import("param_flags.zig");
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const ScriptOptions = @import("script_options.zig").ScriptOptions;
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
++ export_usage ++ param_flags.USAGE ++
    \\  -h, --help                Show this help
    \\
;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const reporter: Reporter = .forProcess(init);
    var options = try ScriptOptions.parse(allocator, args_iter, reporter, .when_given, USAGE) orelse return .failure;
    defer options.deinit(allocator);
    const file_path = options.input_path;

    // The script reads and writes the disk from where its imports are
    var root = try ScriptRoot.open(init.io, allocator, file_path, reporter) orelse return .failure;
    defer root.deinit(init.io, allocator);
    var disk = NativeVfs.init(init.io, root.dir);
    var script_session = try ScriptSession.init(allocator, init.io, disk.vfs());
    defer script_session.deinit();
    // The watcher holds it for the life of the process
    const session = &script_session;
    session.setParams(&options.params);
    session.vm.debugger_handler = debugger.terminalDebugger(init.io);
    // A long-lived session caps the script heap: the project's `vm_memory_limit`, else the
    // interactive default, so a runaway loop ends with an error instead of the machine.
    var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
    const config = ProjectConfig.forScript(init.io, allocator, file_path, &where) catch |err| {
        reporter.err("Error: {s} near {s}:{d}:{d}: {s}\n", .{ CONFIG_FILE_NAME, file_path, where.line, where.column, ProjectConfig.describeError(err) });
        return .failure;
    };
    session.vm.setMemoryLimit(config.vm_memory_limit orelse limits.INTERACTIVE_MEMORY_LIMIT);
    if (options.writes) try options.exports.prepare(&session.vm);

    const source = fs.readFile(init.io, allocator, file_path) catch |err| {
        reporter.err("Error: Could not read '{s}': {s}\n", .{ file_path, @errorName(err) });
        return .failure;
    };
    defer allocator.free(source);

    _ = try session.workspace.addModule(root.path, source);
    try session.loadImports();

    var printer = EventPrinter{ .allocator = allocator, .session = session, .root = &root, .reporter = reporter, .exports = if (options.writes) &options.exports else null };
    var watcher = try Watcher.init(session, init.io, root.dir, printer.listener());
    defer watcher.deinit();

    // The first build is reported like any other, and a failed one is watched for a fix
    // (the command used to exit on it).
    _ = watcher.evaluate();
    reporter.err("Watching {s} and the modules it imports; Ctrl+C stops.\n", .{file_path});
    try watcher.start();
    return .success;
}

/// Prints the watcher's events the way `kupcad build` reports: diagnostics with their
/// file, line and column, then a one-line summary.
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
            .failed => |failure| build_cmd.reportErrors(self.allocator, self.session, failure, self.root, self.reporter) catch |err| {
                self.reporter.err("Build failed ({s}); the errors couldn't be printed: {s}\n", .{ self.root.input, @errorName(err) });
            },
            .run_failed => |err| self.reporter.err("Build failed: {s}\n", .{@errorName(err)}),
            .reload_failed => |r| self.reporter.err("Could not reload '{s}': {s}\n", .{ r.path, @errorName(r.err) }),
        }
    }
};
