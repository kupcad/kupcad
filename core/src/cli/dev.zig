const std = @import("std");
const api = @import("../api.zig");
const ast_dumper = @import("../tools/dev/ast_dumper.zig");
const profiler_mod = @import("../vm/profiler.zig");
const fs = @import("fs.zig");
const VM = @import("../vm/vm.zig").VM;
const chunk = @import("../vm/chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");
const disassembler = @import("../tools/dev/disassembler.zig");
const Lexer = @import("../frontend/kupcad/lexer.zig").Lexer;
const log_helpers = @import("../log.zig");

const log = std.log.scoped(.dev);

const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const subcmd = args_iter.next() orelse {
        printUsage(init.io);
        std.process.exit(1);
    };

    if (std.mem.eql(u8, subcmd, "ast-dump")) {
        try executeAstDump(init, allocator, args_iter);
    } else if (std.mem.eql(u8, subcmd, "disasm")) {
        try executeDisasm(init, allocator, args_iter);
    } else if (std.mem.eql(u8, subcmd, "lex-dump")) {
        try executeLexDump(init, allocator, args_iter);
    } else if (std.mem.eql(u8, subcmd, "bench")) {
        try executeBench(init, allocator, args_iter);
    } else {
        log_helpers.printStderr(init.io, "Error: Unknown dev subcommand '{s}'\n\n", .{subcmd});
        printUsage(init.io);
        std.process.exit(1);
    }
}

fn executeAstDump(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Missing file path for 'ast-dump'. Usage: kupcad dev ast-dump <file.kup>\n", .{});
        std.process.exit(1);
    };

    // Use our new centralized file reader
    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        log_helpers.printStderr(init.io, "Error reading file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Fully parse the AST and resolve symbols/slots
    var doc = api.Document.parse(allocator, source) catch |err| {
        log_helpers.printStderr(init.io, "Error parsing file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer doc.deinit();

    // Setup an allocating writer to buffer the tree dump
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try ast_dumper.dump(allocator, &doc, &out);

    // Construct output path and write file
    const out_path = try std.fmt.allocPrint(allocator, "{s}.dump", .{file_path});
    defer allocator.free(out_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = out.written(),
    });

    log.info("Successfully dumped AST to {s}", .{out_path});
}

fn executeDisasm(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Missing file path for 'disasm'. Usage: kupcad dev disasm <file.kup>\n", .{});
        std.process.exit(1);
    };

    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        log_helpers.printStderr(init.io, "Error reading file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    var doc = api.Document.parse(allocator, source) catch |err| {
        log_helpers.printStderr(init.io, "Error parsing file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer doc.deinit();

    // Setup compilation environment
    var vm = try VM.init(allocator, init.io);
    defer vm.deinit();

    vm.line_index = &doc.line_index;

    try registry.registerStandardLibrary(&vm);

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(allocator);

    var compiler = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &main_chunk, &vm);
    compiler.compile(doc.tree.root) catch |err| {
        log_helpers.printStderr(init.io, "Compilation failed: {}\n", .{err});
        std.process.exit(1);
    };

    // Disassemble
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try disassembler.disassembleChunk(allocator, &main_chunk, "main", &out.writer);

    const out_path = try std.fmt.allocPrint(allocator, "{s}.disasm", .{file_path});
    defer allocator.free(out_path);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = out.written(),
    });

    log.info("Successfully dumped Bytecode to {s}", .{out_path});
}

fn executeLexDump(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Missing file path for 'lex-dump'. Usage: kupcad dev lex-dump <file.kup>\n", .{});
        std.process.exit(1);
    };

    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        log_helpers.printStderr(init.io, "Error reading file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
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

    const out_path = try std.fmt.allocPrint(allocator, "{s}.lex", .{file_path});
    defer allocator.free(out_path);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = out.written(),
    });

    log.info("Successfully dumped Tokens to {s}", .{out_path});
}

fn executeBench(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Missing file path for 'bench'. Usage: kupcad dev bench <file.kup>\n", .{});
        std.process.exit(1);
    };

    // Load source code using central file utility
    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        log_helpers.printStderr(init.io, "Error reading file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // ---------------------------------------------------------------
    // 1. Benchmark Parsing Phase
    // ---------------------------------------------------------------
    const start_parse = std.Io.Clock.now(.awake, init.io);

    var doc = api.Document.parse(allocator, source) catch |err| {
        log_helpers.printStderr(init.io, "Parse failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer doc.deinit();

    const end_parse = std.Io.Clock.now(.awake, init.io);
    const parse_time = start_parse.durationTo(end_parse).toNanoseconds();

    // ---------------------------------------------------------------
    // 2. Benchmark Compilation Phase
    // ---------------------------------------------------------------
    var vm = try VM.init(allocator, init.io);
    defer vm.deinit();

    // Inject line index mapping for rich error backtraces
    vm.line_index = &doc.line_index;

    try registry.registerStandardLibrary(&vm);

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(allocator);

    const start_compile = std.Io.Clock.now(.awake, init.io);

    var compiler = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &main_chunk, &vm);
    compiler.compile(doc.tree.root) catch |err| {
        log_helpers.printStderr(init.io, "Compilation failed: {}\n", .{err});
        std.process.exit(1);
    };

    const end_compile = std.Io.Clock.now(.awake, init.io);
    const compile_time = start_compile.durationTo(end_compile).toNanoseconds();

    // ---------------------------------------------------------------
    // 3. Setup Tracing Profiler & Benchmark VM Execution Phase
    // ---------------------------------------------------------------
    var p = profiler_mod.Profiler.init(allocator, init.io);
    defer p.deinit();
    vm.profiler = &p;

    const start_exec = std.Io.Clock.now(.awake, init.io);

    const result = vm.interpret(&main_chunk);

    const end_exec = std.Io.Clock.now(.awake, init.io);
    const execute_time = start_exec.durationTo(end_exec).toNanoseconds();

    // ---------------------------------------------------------------
    // 4. Output Summary Reports
    // ---------------------------------------------------------------
    log_helpers.printStdout(init.io, "\n=== KupCAD Benchmark: {s} ===\n", .{file_path});
    if (result != .ok) {
        log_helpers.printStdout(init.io, "Execution Result: FAILED\n\n", .{});
    }

    const ns_per_ms: f64 = 1_000_000.0;

    // High-level phase breakdown
    log_helpers.printStdout(init.io, "Parse Time:   {d:>6.2} ms\n", .{@as(f64, @floatFromInt(parse_time)) / ns_per_ms});
    log_helpers.printStdout(init.io, "Compile Time: {d:>6.2} ms\n", .{@as(f64, @floatFromInt(compile_time)) / ns_per_ms});
    log_helpers.printStdout(init.io, "VM Exec Time: {d:>6.2} ms\n", .{@as(f64, @floatFromInt(execute_time)) / ns_per_ms});
    log_helpers.printStdout(init.io, "---------------------------------\n", .{});
    log_helpers.printStdout(init.io, "Total Time:   {d:>6.2} ms\n\n", .{@as(f64, @floatFromInt(parse_time + compile_time + execute_time)) / ns_per_ms});

    // Detailed function-level tracing table
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try api.benchmarkScript(allocator, source, init.io, stdout);
    try stdout.flush();
}

fn printUsage(io: std.Io) void {
    log_helpers.printStderr(io,
        \\Usage: kupcad dev <subcommand> [options]
        \\
        \\Subcommands:
        \\  ast-dump <file>  Generate an AST tree dump (.dump) for compiler debugging
        \\  disasm <file>    Disassemble KupCAD script into raw VM bytecode (.disasm)
        \\  lex-dump <file>  Dump the raw Lexer token stream (.lex)
        \\  bench <file>     Profile Parse, Compile, and VM Execution times
        \\
    , .{});
}
