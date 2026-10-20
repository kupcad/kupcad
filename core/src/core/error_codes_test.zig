//! Each syntax and compile error's code (errors.Code): a script that makes it, and the
//! README's table of them. A code is what users search for and tooling matches on, so one
//! moving to another error, or missing from the docs, is a regression.

const std = @import("std");
const testing = std.testing;
const api = @import("../api.zig");
const limits = @import("limits.zig");
const Code = @import("errors.zig").Code;

/// The code of the first syntax or compile error `kupcad check` reports for `source`.
fn errorCodeOf(source: []const u8) !Code {
    const diags = try api.checkCode(testing.allocator, testing.io, source, .{});
    defer api.freeDiagnostics(testing.allocator, diags);
    for (diags) |d| switch (d.origin) {
        .error_code => |code| return code,
        .rule => {},
    };
    return error.NoError;
}

fn expectCode(expected: Code, source: []const u8) !void {
    errdefer std.debug.print("source: {s}\n", .{source[0..@min(source.len, 80)]});
    try testing.expectEqual(expected, try errorCodeOf(source));
}

test "Error codes: a script for each code gets that code" {
    const cases = [_]struct { Code, []const u8 }{
        .{ .@"invalid-utf8", "x = \"\xFF\"" },
        .{ .@"unexpected-character", "x = $" },
        .{ .@"unterminated-string", "x = \"abc" },
        .{ .@"unterminated-heredoc", "x = <<~EOS\nabc\n" },
        .{ .@"runs-into-heredoc", "x = <<~EOS + \"a\n\"\nbody\nEOS\n" },
        .{ .@"invalid-escape", "x = \"\\q\"" },
        .{ .@"invalid-number", "x = 1e999" },
        .{ .@"unexpected-token", "cube(1" },
        .{ .@"invalid-expression", "x = )" },
        .{ .@"invalid-assignment", "f() = 1" },
        .{ .@"misplaced-import", "def f\n  import { a } from \"./a.kup\"\nend" },
        .{ .@"import-without-from", "import { a }" },
        .{ .@"import-attribute", "import m from \"./m.dat\" with { type: \"yaml\" }" },
        .{ .@"file-import-names", "import { a } from \"./m.stl\"" },
        .{ .@"misplaced-do", "while true do\nend" },
        .{ .@"spaced-parentheses", "f (1, 2)" },
        .{ .@"invalid-parameter", "[1].each { |&b| b }" },
        .{ .@"unexpected-block", "f(&b) { 1 }" },
        .{ .@"outside-loop", "break" },
        .{ .@"outside-method", "yield" },
        .{ .@"builtin-redefined", "cube = 5" },
        .{ .@"import-collision", "a = 1\nimport { a } from \"./a.kup\"\n" },
    };
    for (cases) |case| try expectCode(case[0], case[1]);
}

test "Error codes: a script past each limit gets that limit's code" {
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    const w = &source.writer;

    try w.writeAll("x = ");
    try w.splatByteAll('(', limits.MAX_AST_DEPTH + 1);
    try w.writeByte('1');
    try w.splatByteAll(')', limits.MAX_AST_DEPTH + 1);
    try expectCode(.@"nesting-too-deep", source.written());

    source.clearRetainingCapacity();
    try w.writeAll("def f(p0");
    for (1..limits.MAX_ARGS + 1) |i| try w.print(", p{d}", .{i});
    try w.writeAll(")\nend\n");
    try expectCode(.@"too-many-parameters", source.written());

    source.clearRetainingCapacity();
    try w.writeAll("f(1");
    for (0..limits.MAX_ARGS) |_| try w.writeAll(", 1");
    try w.writeAll(")\n");
    try expectCode(.@"too-many-arguments", source.written());

    // A lambda capturing one more variable than a closure can hold
    source.clearRetainingCapacity();
    try w.writeAll("def f\n");
    for (0..limits.MAX_UPVALUES + 1) |i| try w.print("  v{d} = 0\n", .{i});
    try w.writeAll("  -> { [v0");
    for (1..limits.MAX_UPVALUES + 1) |i| try w.print(", v{d}", .{i});
    try w.writeAll("] }\nend\n");
    try expectCode(.@"too-many-variables", source.written());

    source.clearRetainingCapacity();
    try w.writeAll("x = {k0: 0");
    for (1..limits.MAX_HASH_ENTRIES + 1) |i| try w.print(", k{d}: 0", .{i});
    try w.writeAll("}\n");
    try expectCode(.@"too-many-constants", source.written());

    source.clearRetainingCapacity();
    for (0..limits.MAX_INLINE_CACHES + 2) |_| try w.writeAll("1.abs\n");
    try expectCode(.@"too-many-calls", source.written());

    source.clearRetainingCapacity();
    try w.writeAll("x = 1\n[1].each do\n");
    for (0..limits.MAX_INLINE_CACHES + 2) |_| try w.writeAll("  x\n");
    try w.writeAll("end\n");
    try expectCode(.@"too-many-global-uses", source.written());
}

test "Error codes: docs/README.md lists every code, and only codes" {
    // Not reachable from a script, so not in the tests above: out-of-memory, internal-error,
    // and misplaced-splat, which the parser reports first as an invalid expression (the
    // compiler's own test builds the tree).
    const readme = @embedFile("docs/README.md");
    const header = "| Code | Means |\n|---|---|\n";
    const start = (std.mem.find(u8, readme, header) orelse return error.MissingTable) + header.len;
    const table = readme[start .. std.mem.findPos(u8, readme, start, "\n\n") orelse readme.len];

    var listed: std.EnumSet(Code) = .empty;
    var rows = std.mem.splitScalar(u8, table, '\n');
    while (rows.next()) |row| {
        const name_start = (std.mem.find(u8, row, "| `") orelse return error.MalformedRow) + 3;
        const name = row[name_start .. std.mem.findScalarPos(u8, row, name_start, '`') orelse return error.MalformedRow];
        errdefer std.debug.print("README lists '{s}', which is no code\n", .{name});
        const code = std.meta.stringToEnum(Code, name) orelse return error.UnknownCode;
        try testing.expect(!listed.contains(code));
        listed.insert(code);
    }
    for (std.enums.values(Code)) |code| {
        errdefer std.debug.print("README's error code table doesn't list '{s}'\n", .{code.name()});
        try testing.expect(listed.contains(code));
    }
}
