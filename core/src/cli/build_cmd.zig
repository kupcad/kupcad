//! `kupcad build`: runs a script with its parameter values (`-p`, `-P`) and the project's
//! memory limit, then exports its model as its export options say (export_flags.zig: a
//! format of `api.ExportFormat`, from `--format` or the `-o` extension, `--split`, `--bom`
//! and the rest). Entry points `execute` and `run`.

const std = @import("std");
const api = @import("../api.zig");
const fs = @import("fs.zig");
const param_flags = @import("param_flags.zig");
const ExportFlags = @import("export_flags.zig").ExportFlags;
const export_usage = @import("export_flags.zig").USAGE;
const SessionManager = @import("../session/session_manager.zig").SessionManager;
const ProjectConfig = @import("config.zig").ProjectConfig;
const CONFIG_FILE_NAME = @import("config.zig").FILE_NAME;
const diagnostic_report = @import("diagnostic_report.zig");
const session_mod = @import("../session/session.zig");
const debugger = @import("debugger.zig");
const Args = @import("args.zig").Args;
const ScriptSession = session_mod.ScriptSession;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const ScriptOptions = @import("script_options.zig").ScriptOptions;
pub const Outcome = @import("outcome.zig").Outcome;
pub const Reporter = @import("reporter.zig").Reporter;

pub const USAGE =
    \\Usage: kupcad build <file.kup> [options]
    \\
    \\Runs a script and exports its final geometry.
    \\
    \\Options:
    \\
++ export_usage ++ param_flags.USAGE ++
    \\  -h, --help                Show this help
    \\
;

/// Prints a module's errors the way `kupcad check` does (file:line:col, the source line
/// and a caret), then a one-line summary.
pub fn reportErrors(allocator: std.mem.Allocator, session: *const ScriptSession, failure: *const session_mod.Failure, root: *const ScriptRoot, reporter: Reporter) !void {
    const mod = &session.workspace.modules.items[@backingInt(failure.module)];
    const name = try root.shown(allocator, mod.path);
    defer allocator.free(name);
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    const count = try diagnostic_report.writeErrors(&rendered.writer, allocator, name, mod.source, failure.diagnostics, reporter.err_style);
    reporter.err("{s}Build failed: {d} error{s} in {s}\n", .{ rendered.written(), count, if (count == 1) "" else "s", name });
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    return run(allocator, args_iter, .forProcess(init));
}

/// Runs `kupcad build` with the remaining CLI arguments (`args_iter` needs `next() ?[]const u8`).
/// User-facing failures are reported and return `.failure`; unexpected errors propagate.
pub fn run(allocator: std.mem.Allocator, args_iter: anytype, reporter: Reporter) !Outcome {
    var options = try ScriptOptions.parse(allocator, args_iter, reporter, .always, USAGE) orelse return .failure;
    defer options.deinit(allocator);

    // A one-shot command: one session is all it needs, reading and writing the disk from
    // where the script's imports are
    var root = try ScriptRoot.open(reporter.io, allocator, options.input_path, reporter) orelse return .failure;
    defer root.deinit(reporter.io, allocator);
    var disk = NativeVfs.init(reporter.io, root.dir);
    var manager = SessionManager.init(allocator, reporter.io, 1, disk.vfs());
    defer manager.deinit();
    const session = try runScript(allocator, &manager, &root, &options.params, &options.exports, reporter) orelse return .failure;
    return if (try options.exports.write(allocator, &session.vm, options.input_path, reporter)) .success else .failure;
}

/// Runs the script `root` names (its file system `manager`'s) in a session of `manager`, set
/// up as the command and the project ask: `params` (which the session takes), the terminal debugger, the
/// project's memory limit (`vm_memory_limit` in .kupcad.json) and the engine `exports`
/// need (STEP's exact B-Rep). The session, its model built; null, the failure reported,
/// when it can't be set up or the script doesn't parse, compile or run.
pub fn runScript(allocator: std.mem.Allocator, manager: *SessionManager, root: *const ScriptRoot, params: *api.ParamValues, exports: ?*const ExportFlags, reporter: Reporter) !?*ScriptSession {
    const io = reporter.io;
    const input_path = root.input;
    // Read first: a file that isn't there is named so, before a session is made for it
    const source = fs.readFile(io, allocator, input_path) catch |err| {
        reporter.err("Error: Could not read '{s}': {s}\n", .{ input_path, @errorName(err) });
        return null;
    };
    defer allocator.free(source);
    const session = manager.getOrInitializeSession(input_path) catch |err| {
        reporter.err("Failed to initialize session: {}\n", .{err});
        return null;
    };
    session.setParams(params);
    session.vm.debugger_handler = debugger.terminalDebugger(io);
    var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
    const config = ProjectConfig.forScript(io, allocator, input_path, &where) catch |err| {
        reporter.err("Error: {s} near {s}:{d}:{d}: {s}\n", .{ CONFIG_FILE_NAME, input_path, where.line, where.column, ProjectConfig.describeError(err) });
        return null;
    };
    session.vm.setMemoryLimit(config.vm_memory_limit);
    if (exports) |e| try e.prepare(&session.vm);
    return if (try evaluate(allocator, session, root, source, reporter)) session else null;
}

/// Runs the script `root` names, of `source`, and the modules it imports, dependencies
/// first; false, the errors reported, when one doesn't parse, compile or run.
fn evaluate(allocator: std.mem.Allocator, session: *ScriptSession, root: *const ScriptRoot, source: []const u8, reporter: Reporter) !bool {
    _ = try session.workspace.addModule(root.path, source);
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();
    session.evaluateWorkspace() catch |err| {
        if (err == error.ParseError or err == error.CompileError) if (session.failure) |*failure| {
            try reportErrors(allocator, session, failure, root, reporter);
            return false;
        };
        reporter.err("Build failed: {}\n", .{err});
        return false;
    };
    return true;
}
