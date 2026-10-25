//! `kupcad run`: runs a script with its parameter values (`-p`, `-P`) and the project's
//! memory limit, as `kupcad build` does, and writes no model: what it prints, and the
//! errors it raises, are the result (a script may still export with `export_stl` and the
//! rest). The model is built but not evaluated by the kernel, so a kernel error waits for
//! `kupcad build`.

const std = @import("std");
const build_cmd = @import("build_cmd.zig");
const param_flags = @import("param_flags.zig");
const ScriptSession = @import("../session/session.zig").ScriptSession;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const ScriptOptions = @import("script_options.zig").ScriptOptions;
const Args = @import("args.zig").Args;
pub const Outcome = @import("outcome.zig").Outcome;
const Reporter = @import("reporter.zig").Reporter;

pub const USAGE =
    \\Usage: kupcad run <file.kup> [options]
    \\
    \\Runs a script, printing what it prints, and writes no model (use kupcad build).
    \\
    \\Options:
    \\
++ param_flags.USAGE ++
    \\  -h, --help                Show this help
    \\
;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    return run(allocator, args_iter, .forProcess(init));
}

/// Runs `kupcad run` with the remaining CLI arguments (`next() ?[]const u8`); a script that
/// doesn't parse, compile or run is a failure, reported.
pub fn run(allocator: std.mem.Allocator, args: anytype, reporter: Reporter) !Outcome {
    var options = try ScriptOptions.parse(allocator, args, reporter, .none, USAGE) orelse return .failure;
    defer options.deinit(allocator);
    const input_path = options.input_path;
    // The script reads and writes the disk, as under kupcad build
    var root = try ScriptRoot.open(reporter.io, allocator, input_path, reporter) orelse return .failure;
    defer root.deinit(reporter.io, allocator);
    var disk = NativeVfs.init(reporter.io, root.dir);
    var session = try ScriptSession.init(allocator, reporter.io, disk.vfs());
    defer session.deinit();
    return if (try build_cmd.runScript(allocator, &session, &root, &options.params, null, reporter)) .success else .failure;
}
