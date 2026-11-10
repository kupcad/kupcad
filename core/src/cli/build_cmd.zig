//! `kupcad build`: runs a script with its parameter values (`-p`, `-P`) and the project's
//! memory limit, then exports its model as its export options say (export_flags.zig: a
//! format of `api.ExportFormat`, from `--format` or the `-o` extension, `--split`, `--bom`
//! and the rest). Entry points `execute` and `run`.

const std = @import("std");
const api = @import("../api.zig");
const fs = @import("fs.zig");
const param_flags = @import("param_flags.zig");
const memory_flag = @import("memory_flag.zig");
const time_flag = @import("time_flag.zig");
const ExportFlags = @import("export_flags.zig").ExportFlags;
const export_usage = @import("export_flags.zig").USAGE;
const ProjectConfig = @import("config.zig").ProjectConfig;
const diagnostic_report = @import("diagnostic_report.zig");
const session_mod = @import("../session/session.zig");
const debugger = @import("debugger.zig");
const Args = @import("args.zig").Args;
const ScriptSession = session_mod.ScriptSession;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const script_options = @import("script_options.zig");
const ScriptOptions = script_options.ScriptOptions;
const LineIndex = @import("../core/line_index.zig").LineIndex;
const progress = @import("progress.zig");
pub const Outcome = @import("outcome.zig").Outcome;
pub const Reporter = @import("reporter.zig").Reporter;

pub const USAGE =
    \\Usage: kupcad build <file.kup> [options]
    \\
    \\Runs a script and exports its final geometry.
    \\
    \\Options:
    \\
++ export_usage ++ param_flags.USAGE ++ memory_flag.USAGE ++ time_flag.USAGE ++ script_options.ERRORS_USAGE ++
    \\  -h, --help                Show this help
    \\
;

/// Prints a module's errors the way `kupcad check` does (file:line:col, the source line
/// and a caret), then a one-line summary; a host is told the first (Reporter.fail).
pub fn reportErrors(allocator: std.mem.Allocator, session: *const ScriptSession, failure: *const session_mod.Failure, root: *const ScriptRoot, kind: []const u8, reporter: Reporter) !void {
    const mod = &session.workspace.modules.items[@backingInt(failure.module)];
    const name = try root.shown(allocator, mod.path);
    defer allocator.free(name);
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    const count = try diagnostic_report.writeErrors(&rendered.writer, allocator, name, mod.source, failure.diagnostics, reporter.err_style);
    reporter.err("{s}Build failed: {d} error{s} in {s}\n", .{ rendered.written(), count, if (count == 1) "" else "s", name });
    if (failure.diagnostics.len > 0 and reporter.errors == .json) {
        const first = failure.diagnostics[0];
        const line_index = try LineIndex.init(allocator, mod.source);
        defer line_index.deinit(allocator);
        const at = line_index.humanPosition(first.loc.offset);
        reporter.fail(.{ .kind = kind, .message = first.message, .file = name, .line = at.line, .column = at.column });
    }
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    return run(allocator, args_iter, init.environ_map, .forProcess(init));
}

/// Runs `kupcad build` with the remaining CLI arguments (`args_iter` needs `next() ?[]const u8`)
/// in `environ`. User-facing failures are reported and return `.failure`; unexpected errors
/// propagate.
pub fn run(allocator: std.mem.Allocator, args_iter: anytype, environ: *const std.process.Environ.Map, given: Reporter) !Outcome {
    var options = try ScriptOptions.parse(allocator, args_iter, environ, given, .always, USAGE) orelse return .failure;
    defer options.deinit(allocator);
    var reporter = given;
    reporter.errors = options.errors;

    // The script reads and writes the disk from where its imports are
    var root = try ScriptRoot.open(reporter.io, allocator, options.input_path, reporter) orelse return .failure;
    defer root.deinit(reporter.io, allocator);
    var disk = NativeVfs.init(reporter.io, root.dir);
    var session = try ScriptSession.init(allocator, reporter.io, disk.vfs());
    defer session.deinit();
    progress.start(reporter, "Building {s}", .{std.fs.path.basename(options.input_path)});
    defer progress.stop();
    session.vm.progress = progress.core();
    progress.stage("running the script", .{});
    if (!try runScript(allocator, &session, &root, &options, &options.exports, reporter)) return .failure;
    return if (try options.exports.write(allocator, &session.vm, options.input_path, reporter)) .success else .failure;
}

/// Runs the script `root` names in `session` (reading `root`'s folder), set up as `setUp`
/// does, with no memory limit unless one is given. Whether its model was built; false, the
/// failure reported, when it can't be set up or the script doesn't parse, compile or run.
pub fn runScript(allocator: std.mem.Allocator, session: *ScriptSession, root: *const ScriptRoot, options: *ScriptOptions, exports: ?*const ExportFlags, reporter: Reporter) !bool {
    const source = try setUp(allocator, session, root, options, exports, null, reporter) orelse return false;
    defer allocator.free(source);
    return evaluate(allocator, session, root, source, reporter);
}

/// Sets `session` up to run the script `root` names, as the command and the project ask:
/// `options`' parameter values (which the session takes), the terminal debugger, the memory
/// limit (`--memory-limit` or `KUPCAD_MEMORY_LIMIT`, else the project's `vm_memory_limit` in
/// .kupcad.json, else `default_memory_limit`), the time limit (`--timeout` or
/// `KUPCAD_TIMEOUT`; none without either) and the engine `exports` need (STEP's exact
/// B-Rep). The script's source (owned), or null, the failure reported. `kupcad watch` set
/// itself up with a copy of this, which told a host none of its failures.
pub fn setUp(allocator: std.mem.Allocator, session: *ScriptSession, root: *const ScriptRoot, options: *ScriptOptions, exports: ?*const ExportFlags, default_memory_limit: ?usize, reporter: Reporter) !?[]u8 {
    const io = reporter.io;
    const input_path = root.input;
    // Read first: a file that isn't there is named so, before a session is made for it
    const source = fs.readFile(io, allocator, input_path) catch |err| {
        reporter.err("Error: Could not read '{s}': {s}\n", .{ input_path, @errorName(err) });
        reporter.fail(.{ .kind = "read", .message = @errorName(err), .file = input_path });
        return null;
    };
    errdefer allocator.free(source);
    session.setParams(&options.params);
    session.vm.debugger_handler = debugger.terminalDebugger(io);
    var failure: ?ProjectConfig.Failure = null;
    defer if (failure) |*f| f.deinit(allocator);
    const config = ProjectConfig.forScript(io, allocator, input_path, &failure) catch |err| {
        const f = failure orelse return err;
        reporter.err("Error: {f}\n", .{f});
        const said = try std.fmt.allocPrint(allocator, "{f}", .{f});
        defer allocator.free(said);
        reporter.fail(.{ .kind = "settings", .message = said, .file = f.path, .line = if (f.where.line > 0) @intCast(f.where.line) else null, .column = if (f.where.line > 0) @intCast(f.where.column) else null });
        allocator.free(source);
        return null;
    };
    session.vm.setMemoryLimit(memory_flag.limitFor(config.vm_memory_limit, options.memory_limit, default_memory_limit));
    session.vm.setTimeLimit(options.timeout_ms);
    if (exports) |e| try e.prepare(&session.vm);
    return source;
}

/// Runs the script `root` names, of `source`, and the modules it imports, dependencies
/// first; false, the errors reported, when one doesn't parse, compile or run.
fn evaluate(allocator: std.mem.Allocator, session: *ScriptSession, root: *const ScriptRoot, source: []const u8, reporter: Reporter) !bool {
    _ = try session.workspace.addModule(root.path, source);
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();
    session.evaluateWorkspace() catch |err| {
        try reportEvaluationFailure(allocator, session, err, root, reporter);
        return false;
    };
    return true;
}

/// Reports why an evaluation of `session` failed with `err`, as `build`, `run` and `watch`
/// report it: a module that doesn't parse or compile with its errors (reportErrors), a run
/// that failed (which the VM reported as it happened) in a line, and a host is told it.
pub fn reportEvaluationFailure(allocator: std.mem.Allocator, session: *const ScriptSession, err: anyerror, root: *const ScriptRoot, reporter: Reporter) !void {
    if (err == error.ParseError or err == error.CompileError) if (session.failure) |*failure| {
        return reportErrors(allocator, session, failure, root, if (err == error.ParseError) "syntax" else "compile", reporter);
    };
    reporter.err("Build failed: {}\n", .{err});
    const position = session.vm.last_error_position;
    reporter.fail(.{
        .kind = "runtime",
        .message = session.vm.last_error orelse @errorName(err),
        .file = root.input,
        .line = if (position) |p| p.line else null,
        .column = if (position) |p| p.column else null,
    });
}
