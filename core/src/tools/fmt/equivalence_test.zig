const std = @import("std");
const testing = std.testing;
const Document = @import("../../core/document.zig").Document;
const equivalence = @import("equivalence.zig");
const api = @import("../../api.zig");

fn same(a: []const u8, b: []const u8) !bool {
    var doc_a = try Document.parse(testing.allocator, a);
    defer doc_a.deinit();
    var doc_b = try Document.parse(testing.allocator, b);
    defer doc_b.deinit();
    try testing.expectEqual(@as(usize, 0), doc_a.diagnostics.len + doc_b.diagnostics.len);
    return equivalence.samePrograms(testing.allocator, &doc_a.tree, &doc_b.tree);
}

test "equivalence: layout, grouping that changes nothing and call style are the same program" {
    const pairs = [_][2][]const u8{
        .{ "x = (a * b) + c", "x = a * b + c" },
        .{ "puts -1", "puts(-1)" },
        .{ "f 1, 2", "f(1, 2)" },
        .{ "[1].each { |v| puts v }", "[1].each do |v|\n  puts(v)\nend" },
        .{ "x = 1\n\n\ny = 2 # note", "x = 1; y = 2" },
        .{ "o = { width: width }", "o = { width: }" },
        .{ "n = 1.0", "n = 1" },
        // The formatter sorts each run of imports.
        .{ "import { b } from \"./b.kup\"\nimport { a } from \"./a.kup\"\ncube(1)", "import { a } from \"./a.kup\"\nimport { b } from \"./b.kup\"\ncube(1)" },
    };
    for (pairs) |pair| {
        errdefer std.debug.print("{s}\n  vs\n{s}\n", .{ pair[0], pair[1] });
        try testing.expect(try same(pair[0], pair[1]));
    }
}

test "equivalence: a change of meaning is a different program" {
    const pairs = [_][2][]const u8{
        .{ "x = (a + b) * c", "x = a + b * c" },
        .{ "x = -(a + b)", "x = -a + b" },
        .{ "x = 2 ** (1 + 1)", "x = 2 ** 1 + 1" },
        .{ "x = 1", "y = 1" },
        .{ "x = 1", "x = 2" },
        .{ "x = \"a\"", "x = \"b\"" },
        .{ "x = :a", "x = \"a\"" },
        .{ "x += 1", "x -= 1" },
        .{ "f(a: 1)", "f(b: 1)" },
        .{ "f(*a)", "f(a)" },
        .{ "a&.b", "a.b" },
        .{ "r = 1..2", "r = 1...2" },
        .{ "[1].map { |a, b| a }", "[1].map { |b, a| a }" },
        .{ "def f(a, b) = a", "def f(b, a) = a" },
        .{ "if c then x = 1 end", "unless c then x = 1 end" },
        .{ "x = 1\ny = 2", "y = 2\nx = 1" },
        .{ "import { a } from \"./a.kup\"\ncube(1)\nimport { b } from \"./b.kup\"", "import { b } from \"./b.kup\"\ncube(1)\nimport { a } from \"./a.kup\"" },
    };
    for (pairs) |pair| {
        errdefer std.debug.print("{s}\n  vs\n{s}\n", .{ pair[0], pair[1] });
        try testing.expect(!try same(pair[0], pair[1]));
    }
}

test "equivalence: formatting checks its own output" {
    // formatDocument re-parses what it produced; these all format to the same program.
    const sources = [_][]const u8{
        @embedFile("../../fixtures/format_in.kup"),
        @embedFile("../../fixtures/linter_bad.kup"),
        "puts (1 + 2) * 3\nx = -(a + b)\n# trailing\n",
        "chain = cube(1)\n  .translate(1, 2, 3) # c\n  .rotate(z: 5)\n",
    };
    for (sources) |src| {
        const out = try api.formatCode(testing.allocator, src, .{});
        testing.allocator.free(out);
    }
}

test "equivalence: formatDocument rejects output that parses differently, drops a comment or doesn't parse" {
    var doc = try Document.parse(testing.allocator, "x = (1 + 2) * 3 # why\n");
    defer doc.deinit();
    try testing.expect(try api.formatKeepsProgram(testing.allocator, &doc, "x = (1 + 2) * 3 # why\n"));
    try testing.expect(!try api.formatKeepsProgram(testing.allocator, &doc, "x = 1 + 2 * 3 # why\n"));
    try testing.expect(!try api.formatKeepsProgram(testing.allocator, &doc, "x = (1 + 2) * 3\n"));
    try testing.expect(!try api.formatKeepsProgram(testing.allocator, &doc, "x = (1 + 2) * 3 # other\n"));
    try testing.expect(!try api.formatKeepsProgram(testing.allocator, &doc, "x = (1 + 2 * 3 # why\n"));
}
