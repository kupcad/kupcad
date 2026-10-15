//! End-to-end lint tests: each `snapshots/<case>.kup` is checked as `kupcad check` checks
//! it (syntax, compile errors and every rule at its default level), and the findings must
//! match `<case>.snap`. `zig build test -Dupdate-snapshots` rewrites the .snap files from
//! the current output; review the diff before committing it.
//!
//! Both files are embedded, so the build reruns the test when either changes. To add a case,
//! write `<case>.kup` and an empty `<case>.snap`, list the case in CASES and update.

const std = @import("std");
const testing = std.testing;
const api = @import("../../api.zig");
const update = @import("lint_snapshot_options").update;

const SNAPSHOT_DIR = "src/tools/lint/snapshots";
const CASES = [_][]const u8{
    "clean_model",
    "compile_error",
    "nonpositive_size",
    "param_order",
    "self_subtraction",
    "syntax_error",
    "unreachable_code",
    "unused_variable",
};

test "Lint snapshots: every case's findings match its .snap" {
    // Every case is checked, so one run reports all that differ.
    var failed: usize = 0;
    inline for (CASES) |case| {
        checkCase(case, @embedFile("snapshots/" ++ case ++ ".kup"), @embedFile("snapshots/" ++ case ++ ".snap")) catch |err| switch (err) {
            error.TestExpectedEqual => failed += 1,
            else => return err,
        };
    }
    if (failed > 0) {
        std.debug.print("{d} of {d} lint snapshots differ\n", .{ failed, CASES.len });
        return error.TestExpectedEqual;
    }
}

test "Lint snapshots: every case in the directory is listed" {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, SNAPSHOT_DIR, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".kup")) continue;
        const case = entry.name[0 .. entry.name.len - ".kup".len];
        for (CASES) |listed| {
            if (std.mem.eql(u8, listed, case)) break;
        } else {
            std.debug.print("{s}/{s} isn't in snapshot_test.zig's CASES, so it is never checked\n", .{ SNAPSHOT_DIR, entry.name });
            return error.UnlistedSnapshot;
        }
    }
}

fn checkCase(comptime case: []const u8, source: []const u8, expected: []const u8) !void {
    const allocator = testing.allocator;
    const actual = try render(allocator, source);
    defer allocator.free(actual);
    if (update) {
        var dir = try std.Io.Dir.cwd().openDir(testing.io, SNAPSHOT_DIR, .{});
        defer dir.close(testing.io);
        return dir.writeFile(testing.io, .{ .sub_path = case ++ ".snap", .data = actual });
    }
    errdefer std.debug.print("{s}/{s}.snap differs; if the new output is right, run zig build test -Dupdate-snapshots\n", .{ SNAPSHOT_DIR, case });
    try testing.expectEqualStrings(expected, actual);
}

/// One line per finding, in source order: `line:column severity [rule] message` (no rule
/// for a syntax or compile error).
fn render(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const diags = try api.checkCode(allocator, testing.io, source, .{});
    defer api.freeDiagnostics(allocator, diags);
    std.mem.sort(api.LinterDiagnostic, diags, {}, struct {
        fn before(_: void, a: api.LinterDiagnostic, b: api.LinterDiagnostic) bool {
            return a.loc.offset < b.loc.offset;
        }
    }.before);

    const line_index = try api.LineIndex.init(allocator, source);
    defer line_index.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (diags) |d| {
        try out.writer.print("{d}:{d} {s} ", .{ line_index.getLine(d.loc.offset) + 1, line_index.getUtf8Column(d.loc.offset) + 1, d.severity.toChar() });
        // Syntax and compile errors come from no rule.
        if (d.rule) |rule| try out.writer.print("[{s}] ", .{rule});
        try out.writer.print("{s}\n", .{d.message});
    }
    if (diags.len == 0) try out.writer.writeAll("(no findings)\n");
    return out.toOwnedSlice();
}
