//! Fuzzing the front end: any bytes go through the lexer, the parser, the linter and the
//! compiler (with its bytecode verifier) without crashing, the compiler never reports an
//! internal error, and a script that parses formats to the same program, stably (formatting
//! the output again changes nothing). A plain test run replays the corpus (fuzz_corpus.zig);
//! `zig build fuzz --fuzz=<runs>` searches from it (nightly in CI).

const std = @import("std");
const testing = std.testing;
const api = @import("../api.zig");
const Document = @import("document.zig").Document;
const corpus = @import("fuzz_corpus.zig");
const program = @import("fuzz_program.zig");

/// What describeError calls an error that is the compiler's fault, not the script's.
const INTERNAL_COMPILER_ERROR = "internal compiler error";

/// Generated programs each plain test run checks.
const PLAIN_RUN_PROGRAMS = 100;

// The name is `-Dfuzz-target`'s filter in build.zig: renaming it means changing that.
test "fuzz: the front end takes any input" {
    const buf = try testing.allocator.create([corpus.MAX_INPUT_BYTES]u8);
    defer testing.allocator.destroy(buf);
    try testing.fuzz(buf, frontEnd, .{ .corpus = &corpus.CORPUS });
}

fn frontEnd(buf: *[corpus.MAX_INPUT_BYTES]u8, smith: *testing.Smith) anyerror!void {
    try checkFrontEnd(buf[0..smith.slice(buf)], .any);
}

// The name is `-Dfuzz-target`'s filter in build.zig: renaming it means changing that.
test "fuzz: the front end takes any generated program" {
    try testing.fuzz({}, frontEndGenerated, .{});
}

fn frontEndGenerated(_: void, smith: *testing.Smith) anyerror!void {
    try checkGenerated(.{ .smith = smith });
}

fn checkGenerated(choices: program.Choices) !void {
    const source = try program.generate(testing.allocator, choices);
    defer testing.allocator.free(source);
    try checkFrontEnd(source, .generated);
}

test "Fuzz programs: generated programs parse and go through the front end" {
    // The programs the fuzzer would start from, on every test run: a syntax error in one is
    // the generator's bug or the parser's.
    for (0..PLAIN_RUN_PROGRAMS) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        try checkGenerated(.{ .random = prng.random() });
    }
}

/// Where a source comes from: any bytes may fail to parse; a generated program must not.
const Source = enum { any, generated };

/// The front end's promises for `source`: no crash, no internal compiler error, and a
/// program that parses formats to the same program, stably.
fn checkFrontEnd(source: []const u8, from: Source) !void {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    const diagnostics = try api.checkDocument(testing.allocator, testing.io, &doc, .{});
    defer api.freeDiagnostics(testing.allocator, diagnostics);
    for (diagnostics) |d| {
        errdefer std.debug.print("source:\n{s}\n", .{source});
        try testing.expect(!std.mem.eql(u8, d.message, INTERNAL_COMPILER_ERROR));
    }

    if (from == .generated and doc.diagnostics.len > 0) {
        std.debug.print("source:\n{s}\nsyntax error: {s}\n", .{ source, doc.diagnostics[0].message });
        return error.GeneratedProgramDoesNotParse;
    }
    if (doc.diagnostics.len > 0 or doc.tree.root == .none) return;
    errdefer std.debug.print("source:\n{s}\n", .{source});
    const formatted = try api.formatDocument(testing.allocator, &doc, .{});
    defer testing.allocator.free(formatted);
    var again = try Document.parse(testing.allocator, formatted);
    defer again.deinit();
    const twice = try api.formatDocument(testing.allocator, &again, .{});
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(formatted, twice);
}

test "Fuzz corpus: every program in fuzz_corpus/ is listed" {
    inline for (.{ .{ "canonical", &corpus.CANONICAL }, .{ "raw", &corpus.RAW } }) |sub| {
        var dir = try std.Io.Dir.cwd().openDir(testing.io, corpus.CORPUS_DIR ++ "/" ++ sub[0], .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".kup")) continue;
            const name = entry.name[0 .. entry.name.len - ".kup".len];
            for (sub[1]) |listed| {
                if (std.mem.eql(u8, listed, name)) break;
            } else {
                std.debug.print("{s}/{s}/{s} isn't listed in fuzz_corpus.zig, so the fuzzers never start from it\n", .{ corpus.CORPUS_DIR, sub[0], entry.name });
                return error.UnlistedCorpusFile;
            }
        }
    }
}
