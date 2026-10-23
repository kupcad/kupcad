//! `kupcad dev`: tools for working on the compiler and VM. `ast-dump`, `disasm` and
//! `lex-dump` write a script's AST, bytecode or token stream to a file next to it; `bench`
//! times its phases (tools/bench.zig). `execute` dispatches on the subcommand.

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
const Args = @import("args.zig").Args;
const bench = @import("../tools/bench.zig");
const log_helpers = @import("../log.zig");
const ScriptSession = @import("../session/session.zig").ScriptSession;

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
    \\
;

const Subcommand = enum { @"ast-dump", disasm, @"lex-dump", bench, crash };

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
    };
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
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Missing file path for '" ++ dump.name ++ "'. Usage: kupcad dev " ++ dump.name ++ " <file.kup>\n", .{});
        return .failure;
    };
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

/// The script parsed, its symbols and slots resolved, as a tree.
fn renderAst(init: std.process.Init, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, out: *std.Io.Writer.Allocating) !bool {
    var doc = api.Document.parse(allocator, source) catch |err| {
        log_helpers.printStderr(init.io, "Error parsing file '{s}': {}\n", .{ file_path, err });
        return false;
    };
    defer doc.deinit();
    try ast_dumper.dump(allocator, &doc, out);
    return true;
}

/// The script compiled, its main chunk disassembled.
fn renderBytecode(init: std.process.Init, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, out: *std.Io.Writer.Allocating) !bool {
    var doc = api.Document.parse(allocator, source) catch |err| {
        log_helpers.printStderr(init.io, "Error parsing file '{s}': {}\n", .{ file_path, err });
        return false;
    };
    defer doc.deinit();

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
    try disassembler.disassembleChunk(allocator, &main_chunk, "main", &out.writer);
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
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
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
    const where = if (compiler.errorDiagnostic()) |d| d.formatLine(allocator, &doc.line_index) catch null else null;
    defer if (where) |w| allocator.free(w);
    log_helpers.printStderr(io, "Compilation failed: {s}\n", .{where orelse @errorName(err)});
}
