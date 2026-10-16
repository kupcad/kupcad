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
const ScriptSession = @import("../daemon/session.zig").ScriptSession;

const log = std.log.scoped(.dev);

const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

pub const USAGE =
    \\Usage: kupcad dev <subcommand> [options]
    \\
    \\Subcommands:
    \\  ast-dump <file>  Generate an AST tree dump (.dump) for compiler debugging
    \\  disasm <file>    Disassemble KupCAD script into raw VM bytecode (.disasm)
    \\  lex-dump <file>  Dump the raw Lexer token stream (.lex)
    \\  bench <file>     Time parse, compile, VM run and geometry evaluation (medians over
    \\                   --repeat N runs, 5 by default; --no-profile, --no-eval, --json)
    \\
;

const Subcommand = enum { @"ast-dump", disasm, @"lex-dump", bench };

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
        .@"ast-dump" => executeAstDump(init, allocator, args_iter),
        .disasm => executeDisasm(init, allocator, args_iter),
        .@"lex-dump" => executeLexDump(init, allocator, args_iter),
        .bench => executeBench(init, allocator, args_iter),
    };
}

fn executeAstDump(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Missing file path for 'ast-dump'. Usage: kupcad dev ast-dump <file.kup>\n", .{});
        return .failure;
    };

    // Use our new centralized file reader
    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        log_helpers.printStderr(init.io, "Error reading file '{s}': {}\n", .{ file_path, err });
        return .failure;
    };
    defer allocator.free(source);

    // Fully parse the AST and resolve symbols/slots
    var doc = api.Document.parse(allocator, source) catch |err| {
        log_helpers.printStderr(init.io, "Error parsing file '{s}': {}\n", .{ file_path, err });
        return .failure;
    };
    defer doc.deinit();

    // Setup an allocating writer to buffer the tree dump
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try ast_dumper.dump(allocator, &doc, &out);

    // Construct output path and write file
    const out_path = try allocator.print("{s}.dump", .{file_path});
    defer allocator.free(out_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = out.written(),
    });

    log.info("Successfully dumped AST to {s}", .{out_path});
    return .success;
}

fn executeDisasm(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Missing file path for 'disasm'. Usage: kupcad dev disasm <file.kup>\n", .{});
        return .failure;
    };

    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        log_helpers.printStderr(init.io, "Error reading file '{s}': {}\n", .{ file_path, err });
        return .failure;
    };
    defer allocator.free(source);

    var doc = api.Document.parse(allocator, source) catch |err| {
        log_helpers.printStderr(init.io, "Error parsing file '{s}': {}\n", .{ file_path, err });
        return .failure;
    };
    defer doc.deinit();

    // Setup compilation environment
    var session = try ScriptSession.init(allocator, init.io);
    defer session.deinit();

    session.vm.line_index = &doc.line_index;
    try registry.registerStandardLibrary(&session.vm);

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(allocator);

    var compiler = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &main_chunk, &session.vm);
    defer compiler.deinit();
    compiler.compile(doc.tree.root) catch |err| {
        reportCompileError(init.io, allocator, &compiler, &doc, err);
        return .failure;
    };

    // Disassemble
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try disassembler.disassembleChunk(allocator, &main_chunk, "main", &out.writer);

    const out_path = try allocator.print("{s}.disasm", .{file_path});
    defer allocator.free(out_path);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = out.written(),
    });

    log.info("Successfully dumped Bytecode to {s}", .{out_path});
    return .success;
}

fn executeLexDump(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Missing file path for 'lex-dump'. Usage: kupcad dev lex-dump <file.kup>\n", .{});
        return .failure;
    };

    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        log_helpers.printStderr(init.io, "Error reading file '{s}': {}\n", .{ file_path, err });
        return .failure;
    };
    defer allocator.free(source);

    var lexer = Lexer.init(source, 0);
    const tokens = try lexer.lexAll(allocator);
    defer {
        allocator.free(tokens.tags);
        allocator.free(tokens.starts);
        allocator.free(tokens.lengths);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll("== Lexer Token Dump ==\n");
    for (tokens.tags, 0..) |tag, i| {
        const start = tokens.starts[i];
        const len = tokens.lengths[i];
        const lexeme = source[start .. start + len];

        // Example output: [0014] ident          'cube'
        try out.writer.print("[{d:0>4}] {s: <20} '{s}'\n", .{ start, @tagName(tag), lexeme });
    }

    const out_path = try allocator.print("{s}.lex", .{file_path});
    defer allocator.free(out_path);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = out.written(),
    });

    log.info("Successfully dumped Tokens to {s}", .{out_path});
    return .success;
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

    const source = fs.readFileLimit(init.io, allocator, path, MAX_FILE_SIZE) catch |err| {
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
