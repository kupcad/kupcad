//! `kupcad run`: runs a script with its parameter values (`-p`, `-P`) and the project's
//! memory limit, as `kupcad build` does, and writes no model: what it prints, and the
//! errors it raises, are the result (a script may still export with `export_stl` and the
//! rest). A model that is one Solid is evaluated by the kernel (the session fingerprints its
//! output), so a kernel error shows here too; an Array or an Assembly waits for `kupcad build`.

const std = @import("std");
const build_cmd = @import("build_cmd.zig");
const param_flags = @import("param_flags.zig");
const memory_flag = @import("memory_flag.zig");
const time_flag = @import("time_flag.zig");
const ScriptSession = @import("../session/session.zig").ScriptSession;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const script_options = @import("script_options.zig");
const ScriptOptions = script_options.ScriptOptions;
const Args = @import("args.zig").Args;
pub const Outcome = @import("outcome.zig").Outcome;
const Reporter = @import("reporter.zig").Reporter;
const progress = @import("progress.zig");

pub const USAGE =
    \\Usage: kupcad run <file.kup> [options]
    \\
    \\Runs a script, printing what it prints, and writes no model (use kupcad build).
    \\
    \\Options:
    \\
++ param_flags.USAGE ++ memory_flag.USAGE ++ time_flag.USAGE ++ script_options.ERRORS_USAGE ++
    \\  -h, --help                Show this help
    \\
;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    return run(allocator, args_iter, init.environ_map, .forProcess(init));
}

/// Runs `kupcad run` with the remaining CLI arguments (`next() ?[]const u8`) in `environ`; a
/// script that doesn't parse, compile or run is a failure, reported.
pub fn run(allocator: std.mem.Allocator, args: anytype, environ: *const std.process.Environ.Map, given: Reporter) !Outcome {
    var options = try ScriptOptions.parse(allocator, args, environ, given, .none, USAGE) orelse return .failure;
    defer options.deinit(allocator);
    var reporter = given;
    reporter.errors = options.errors;
    const input_path = options.input_path;
    // The script reads and writes the disk, as under kupcad build
    var root = try ScriptRoot.open(reporter.io, allocator, input_path, reporter) orelse return .failure;
    defer root.deinit(reporter.io, allocator);
    var disk = NativeVfs.init(reporter.io, root.dir);
    var session = try ScriptSession.init(allocator, reporter.io, disk.vfs());
    defer session.deinit();
    progress.start(reporter, "Running {s}", .{std.fs.path.basename(input_path)});
    defer progress.stop();
    session.vm.progress = progress.core();
    return if (try build_cmd.runScript(allocator, &session, &root, &options, null, reporter)) .success else .failure;
}
