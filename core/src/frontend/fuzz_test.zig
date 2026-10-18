//! Fuzzing the front end: any bytes go through the lexer, the parser, the linter and the
//! compiler (with its bytecode verifier) without crashing, the compiler never reports an
//! internal error, and a script that parses formats to the same program, stably (formatting
//! the output again changes nothing). A plain test run replays the corpus (fuzz_corpus.zig);
//! `zig build fuzz --fuzz=<runs>` searches from it (nightly in CI).

const std = @import("std");
const testing = std.testing;
const api = @import("../api.zig");
const Document = @import("../core/document.zig").Document;
const corpus = @import("fuzz_corpus.zig");

/// What describeError calls an error that is the compiler's fault, not the script's.
const INTERNAL_COMPILER_ERROR = "internal compiler error";

test "fuzz: the front end takes any input" {
    const buf = try testing.allocator.create([corpus.MAX_INPUT_BYTES]u8);
    defer testing.allocator.destroy(buf);
    try testing.fuzz(buf, frontEnd, .{ .corpus = &corpus.CORPUS });
}

fn frontEnd(buf: *[corpus.MAX_INPUT_BYTES]u8, smith: *testing.Smith) anyerror!void {
    const source = buf[0..smith.slice(buf)];
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    const diagnostics = try api.checkDocument(testing.allocator, testing.io, &doc, .{});
    defer api.freeDiagnostics(testing.allocator, diagnostics);
    for (diagnostics) |d| {
        errdefer std.debug.print("source:\n{s}\n", .{source});
        try testing.expect(!std.mem.eql(u8, d.message, INTERNAL_COMPILER_ERROR));
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
