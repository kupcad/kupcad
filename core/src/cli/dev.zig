//! `kupcad dev`: tools for working on the compiler, the VM and the B-Rep kernel. `ast-dump`,
//! `disasm` and `lex-dump` write a script's AST, bytecode or token stream to a file next to
//! it; `bench` times its phases (tools/bench.zig); `brep-readiness` builds scripts on the
//! B-Rep engine and lists what each still lacks (tools/dev/brep_readiness.zig);
//! `brep-trace` writes the body after each phase of a script's operations
//! (tools/dev/brep_trace.zig). `execute` dispatches on the subcommand.

const std = @import("std");
const api = @import("../api.zig");
const ast_dumper = @import("../tools/dev/ast_dumper.zig");
const fs = @import("fs.zig");
const chunk = @import("../vm/chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");
const disassembler = @import("../tools/dev/disassembler.zig");
const Lexer = @import("../frontend/lexer.zig").Lexer;
const Outcome = @import("outcome.zig").Outcome;
const args = @import("args.zig");
const Args = args.Args;
const bench = @import("../tools/bench.zig");
const log_helpers = @import("../log.zig");
const ScriptSession = @import("../session/session.zig").ScriptSession;
const diagnostic_report = @import("diagnostic_report.zig");
const Reporter = @import("reporter.zig").Reporter;
const ScriptRoot = @import("script_root.zig").ScriptRoot;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const limits = @import("../core/limits.zig");
const brep_readiness = @import("../tools/dev/brep_readiness.zig");
const case_rig = @import("../tools/dev/case_rig.zig");
const brep_trace = @import("../tools/dev/brep_trace.zig");

const log = std.log.scoped(.dev);

/// The dump subcommands, each writing its file beside the script.
const AST_DUMP = Dump{ .name = "ast-dump", .extension = "dump", .what = "AST", .render = renderAst };
const DISASM = Dump{ .name = "disasm", .extension = "disasm", .what = "Bytecode", .render = renderBytecode };
const LEX_DUMP = Dump{ .name = "lex-dump", .extension = "lex", .what = "Tokens", .render = renderTokens };

pub const USAGE =
    \\Usage: kupcad dev <subcommand> [options]
    \\
    \\Subcommands:
    \\  ast-dump <file>  Generate an AST tree dump (.dump) for compiler debugging
    \\  disasm <file>    Disassemble KupCAD script into raw VM bytecode (.disasm)
    \\  lex-dump <file>  Dump the raw Lexer token stream (.lex)
    \\  bench <file>     Time parse, compile, VM run and geometry evaluation (medians over
    \\                   --repeat N runs, 5 by default; --no-profile, --no-eval, --json)
    \\  crash panic|abort  End the process with a panic or an abort, to check that
    \\                   KUPCAD_CRASH_DIR captures crash reports
    \\  brep-readiness [path...]  Build each script (or the .kup files of each folder;
    \\                   examples/ by default) on the B-Rep engine and list what each
    \\                   still lacks there, then the case rig's ladder with its frontier
    \\  brep-trace <file>  Run the script on the B-Rep engine writing the body after each
    \\                   phase of each operation into <file>.trace/
    \\
;

const Subcommand = enum { @"ast-dump", disasm, @"lex-dump", bench, crash, @"brep-readiness", @"brep-trace" };

/// Where `brep-readiness` looks without a path.
const EXAMPLES_DIR = "examples";

/// A dump subcommand: its name, the extension of the file it writes beside the script, what
/// it dumps (for the log), and how it renders the script into `out`, false once a failure
/// is reported.
const Dump = struct {
    name: []const u8,
    extension: []const u8,
    what: []const u8,
    render: *const fn (init: std.process.Init, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, out: *std.Io.Writer.Allocating) anyerror!bool,
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const name = args_iter.next() orelse {
        printUsage(init.io);
        return .failure;
    };
    const subcmd = std.meta.stringToEnum(Subcommand, name) orelse {
        log_helpers.printStderr(init.io, "Error: Unknown dev subcommand '{s}'\n\n", .{name});
        printUsage(init.io);
        return .failure;
    };
    return switch (subcmd) {
        .@"ast-dump" => runDump(init, allocator, args_iter, AST_DUMP),
        .disasm => runDump(init, allocator, args_iter, DISASM),
        .@"lex-dump" => runDump(init, allocator, args_iter, LEX_DUMP),
        .bench => executeBench(init, allocator, args_iter),
        .crash => executeCrash(init, args_iter),
        .@"brep-readiness" => executeReadiness(init, allocator, args_iter),
        .@"brep-trace" => executeTrace(init, allocator, args_iter),
    };
}

/// `kupcad dev brep-readiness [path...]`: each script (a folder: its .kup files, in name
/// order) built on the B-Rep engine, a line per script and the count on stdout. The report
/// succeeds whatever the scripts lack; a path that can't be read fails it.
fn executeReadiness(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const reporter: Reporter = .forProcess(init);
    var scripts = std.ArrayList([]u8).empty;
    defer {
        for (scripts.items) |s| allocator.free(s);
        scripts.deinit(allocator);
    }
    var any = false;
    while (args_iter.next()) |path| {
        any = true;
        if (!try collectScripts(init.io, allocator, path, &scripts, reporter)) return .failure;
    }
    if (!any and !try collectScripts(init.io, allocator, EXAMPLES_DIR, &scripts, reporter)) return .failure;

    var results = std.ArrayList(brep_readiness.Result).empty;
    defer {
        for (results.items) |*r| r.outcome.deinit(allocator);
        results.deinit(allocator);
    }
    for (scripts.items) |path| {
        const outcome = try checkScript(init.io, allocator, path, reporter) orelse return .failure;
        try results.append(allocator, .{ .path = path, .outcome = outcome });
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try brep_readiness.writeReport(&out.writer, results.items);
    // The case rig's ladder (tools/dev/cases.zig): where the kernel stands, case by case
    const ladder = try case_rig.runAll(allocator, init.io, .brep_native, LADDER_TIME_LIMIT_MS);
    defer case_rig.freeResults(allocator, ladder);
    try out.writer.writeAll("\n");
    try case_rig.writeLadder(&out.writer, "B-Rep", ladder);
    reporter.out("{s}", .{out.written()});
    return .success;
}

/// The most a case of the ladder may take before it counts as a hang.
const LADDER_TIME_LIMIT_MS: u64 = 60_000;

/// Adds `path` to `scripts`: the file, or the `.kup` files of the folder in name order.
/// False, reported, when it can't be read.
fn collectScripts(io: std.Io, allocator: std.mem.Allocator, path: []const u8, scripts: *std.ArrayList([]u8), reporter: Reporter) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        reporter.err("Error: Could not read '{s}': {s}\n", .{ path, @errorName(err) });
        return false;
    };
    if (stat.kind != .directory) {
        try scripts.append(allocator, try allocator.dupe(u8, path));
        return true;
    }
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        reporter.err("Error: Could not read '{s}': {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer dir.close(io);
    const first = scripts.items.len;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".kup")) continue;
        try scripts.append(allocator, try std.fs.path.join(allocator, &.{ path, entry.name }));
    }
    std.mem.sort([]u8, scripts.items[first..], {}, lessThanBytes);
    return true;
}

fn lessThanBytes(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The script at `path`, read from its root, run on the B-Rep engine; null, reported, when
/// it can't be read.
fn checkScript(io: std.Io, allocator: std.mem.Allocator, path: []const u8, reporter: Reporter) !?brep_readiness.Outcome {
    var root = try ScriptRoot.open(io, allocator, path, reporter) orelse return null;
    defer root.deinit(io, allocator);
    const source = root.dir.readFileAlloc(io, root.path, allocator, .limited(limits.MAX_READ_BYTES)) catch |err| {
        reporter.err("Error: Could not read '{s}': {s}\n", .{ path, @errorName(err) });
        return null;
    };
    defer allocator.free(source);
    var disk = NativeVfs.init(io, root.dir);
    return try brep_readiness.check(allocator, io, source, disk.vfs());
}

/// `kupcad dev brep-trace <file.kup>`: the script run on the B-Rep engine, each phase of
/// each operation written into `<file>.trace/`; how many on stdout. The script's failure,
/// if any, is reported after the phases it left, and fails the command.
fn executeTrace(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const reporter: Reporter = .forProcess(init);
    const io = init.io;
    const path = args.onlyFile(args_iter, reporter, "Usage: kupcad dev brep-trace <file.kup>\n") orelse return .failure;
    var root = try ScriptRoot.open(io, allocator, path, reporter) orelse return .failure;
    defer root.deinit(io, allocator);
    const source = root.dir.readFileAlloc(io, root.path, allocator, .limited(limits.MAX_READ_BYTES)) catch |err| {
        reporter.err("Error: Could not read '{s}': {s}\n", .{ path, @errorName(err) });
        return .failure;
    };
    defer allocator.free(source);
    var disk = NativeVfs.init(io, root.dir);

    const out_path = try allocator.print("{s}.trace", .{path});
    defer allocator.free(out_path);
    var out_dir = std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{}) catch |err| {
        reporter.err("Error: Could not create '{s}': {s}\n", .{ out_path, @errorName(err) });
        return .failure;
    };
    defer out_dir.close(io);

    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(allocator);
    const phases = brep_trace.run(allocator, io, source, disk.vfs(), out_dir, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            reporter.err("Error: Could not write the trace into '{s}': {s}\n", .{ out_path, @errorName(err) });
            return .failure;
        },
    };
    reporter.out("{d} phase{s} written to {s}/\n", .{ phases, if (phases == 1) "" else "s", out_path });
    if (diag.message) |message| {
        reporter.err("{s}\n", .{message});
        return .failure;
    }
    return .success;
}

/// Ends the process the two ways a crash does: a Zig panic, or an abort (what the C++
/// kernel does when it fails, built without exceptions).
fn executeCrash(init: std.process.Init, args_iter: *Args) Outcome {
    const how = args_iter.next() orelse "";
    if (std.mem.eql(u8, how, "panic")) @panic("kupcad dev crash: a deliberate panic");
    if (std.mem.eql(u8, how, "abort")) std.c.abort();
    log_helpers.printStderr(init.io, "Usage: kupcad dev crash panic|abort\n", .{});
    return .failure;
}

/// `kupcad dev <dump.name> <file>`: the script read, rendered as `dump` does and written to
/// `<file>.<dump.extension>`.
fn runDump(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args, comptime dump: Dump) !Outcome {
    const file_path = args.onlyFile(args_iter, .forProcess(init), "Usage: kupcad dev " ++ dump.name ++ " <file.kup>\n") orelse return .failure;
    const source = fs.readFile(init.io, allocator, file_path) catch |err| {
        log_helpers.printStderr(init.io, "Error reading file '{s}': {}\n", .{ file_path, err });
        return .failure;
    };
    defer allocator.free(source);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (!try dump.render(init, allocator, file_path, source, &out)) return .failure;

    const out_path = try allocator.print("{s}." ++ dump.extension, .{file_path});
    defer allocator.free(out_path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = out.written() });
    log.info("Successfully dumped " ++ dump.what ++ " to {s}", .{out_path});
    return .success;
}

/// The script parsed, its names resolved, as a tree.
fn renderAst(init: std.process.Init, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, out: *std.Io.Writer.Allocating) !bool {
    var doc = api.Document.parse(allocator, source) catch |err| {
        log_helpers.printStderr(init.io, "Error parsing file '{s}': {}\n", .{ file_path, err });
        return false;
    };
    defer doc.deinit();
    try ast_dumper.dump(&doc, &out.writer);
    return true;
}

/// The script compiled, its main chunk disassembled.
fn renderBytecode(init: std.process.Init, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, out: *std.Io.Writer.Allocating) !bool {
    var doc = api.Document.parse(allocator, source) catch |err| {
        log_helpers.printStderr(init.io, "Error parsing file '{s}': {}\n", .{ file_path, err });
        return false;
    };
    defer doc.deinit();
    // Compiling a tree with errors in it is no compile error of the script's: it was
    // reported as an internal compiler error
    if (doc.diagnostics.len > 0) {
        const reporter: Reporter = .forProcess(init);
        var rendered: std.Io.Writer.Allocating = .init(allocator);
        defer rendered.deinit();
        const count = try diagnostic_report.writeErrors(&rendered.writer, allocator, file_path, source, doc.diagnostics, reporter.err_style);
        reporter.err("{s}Not disassembled: {d} syntax error{s} in {s}\n", .{ rendered.written(), count, if (count == 1) "" else "s", file_path });
        return false;
    }

    // Compiled, not run: it reads no files
    var session = try ScriptSession.init(allocator, init.io, .none);
    defer session.deinit();
    session.vm.line_index = &doc.line_index;
    try registry.registerStandardLibrary(&session.vm);

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(allocator);
    var compiler = Compiler.forDocument(allocator, &doc, &main_chunk, &session.vm);
    defer compiler.deinit();
    compiler.compile(doc.tree.root) catch |err| {
        reportCompileError(init.io, allocator, &compiler, &doc, err);
        return false;
    };
    try disassembler.disassembleChunk(&main_chunk, "main", &out.writer);
    return true;
}

/// The script's tokens, each with where it starts: `[0014] ident 'cube'`.
fn renderTokens(init: std.process.Init, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, out: *std.Io.Writer.Allocating) !bool {
    _ = init;
    _ = file_path;
    var lexer = Lexer.init(source, 0);
    var tokens = try lexer.lexAll(allocator);
    defer tokens.deinit(allocator);
    try out.writer.writeAll("== Lexer Token Dump ==\n");
    for (tokens.tags, tokens.starts, tokens.lengths) |tag, start, len| {
        try out.writer.print("[{d:0>4}] {s: <20} '{s}'\n", .{ start, @tagName(tag), source[start .. start + len] });
    }
    return true;
}

fn executeBench(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    var file_path: ?[]const u8 = null;
    var options: bench.Options = .{};
    var json = false;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--repeat")) {
            const count = args_iter.next() orelse return benchUsage(init.io, "--repeat needs a count");
            options.repeat = std.fmt.parseInt(usize, count, 10) catch return benchUsage(init.io, "--repeat needs a whole number");
            if (options.repeat == 0) return benchUsage(init.io, "--repeat needs at least 1");
        } else if (std.mem.eql(u8, arg, "--no-profile")) {
            options.profile = false;
        } else if (std.mem.eql(u8, arg, "--no-eval")) {
            options.evaluate = false;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return benchUsage(init.io, "unknown option");
        } else if (file_path == null) {
            file_path = arg;
        } else return benchUsage(init.io, "one file at a time");
    }
    const path = file_path orelse return benchUsage(init.io, "missing file path");

    const source = fs.readFile(init.io, allocator, path) catch |err| {
        log_helpers.printStderr(init.io, "Error reading file '{s}': {}\n", .{ path, err });
        return .failure;
    };
    defer allocator.free(source);

    var report = bench.run(allocator, init.io, source, options) catch |err| {
        log_helpers.printStderr(init.io, "Benchmark failed: {s} ({s})\n", .{ @errorName(err), path });
        return .failure;
    };
    defer report.deinit();

    var stdout_buf: [4096]u8 = undefined;
    // Streaming, as log.printStdout writes: stdout may be a file it appends to
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    if (json) try report.writeJson(stdout) else try report.writeText(stdout, path);
    try stdout.flush();
    return .success;
}

fn benchUsage(io: std.Io, problem: []const u8) Outcome {
    log_helpers.printStderr(io, "Error: {s}.\nUsage: kupcad dev bench <file.kup> [--repeat N] [--no-profile] [--no-eval] [--json]\n", .{problem});
    return .failure;
}

fn printUsage(io: std.Io) void {
    log_helpers.printStderr(io, USAGE, .{});
}

/// "Compilation failed: line:col: message", or the error name when the compiler kept none.
fn reportCompileError(io: std.Io, allocator: std.mem.Allocator, compiler: *const Compiler, doc: *const api.Document, err: anyerror) void {
    const where = compiler.errorLine(allocator, &doc.line_index);
    defer if (where) |w| allocator.free(w);
    log_helpers.printStderr(io, "Compilation failed: {s}\n", .{where orelse @errorName(err)});
}
