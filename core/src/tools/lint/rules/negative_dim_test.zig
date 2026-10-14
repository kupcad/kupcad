const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const NegativeDimRule = @import("negative_dim.zig").NegativeDimRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, .{});
    errdefer engine.deinit();
    var rule_impl = NegativeDimRule{};
    try engine.rules.append(allocator, rule_impl.rule());

    // Tokens and AST are scratch; only the engine (and its diagnostics) is returned
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lexer = lexer_mod.Lexer.init(source, 0);

    // Lex everything upfront to SoA tokens
    const tokens = try lexer.lexAll(arena.allocator());

    // Initialize parser with tokens and source
    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const root = try parser.parseProgram();

    // Pass token bounds to the linter engine for diagnostic locations
    try engine.check(&parser.b.tree, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);

    return engine;
}

test "Linter Rule: NegativeDimRule flags a primitive's size given as zero or a negative literal" {
    const cases = [_]struct { src: []const u8, message: []const u8 }{
        .{ .src = "cube(-5)", .message = "cube expects x to be greater than zero, got -5" },
        .{ .src = "cube(10, 0, 5)", .message = "cube expects y to be greater than zero, got 0" },
        .{ .src = "cube(size: -2.5)", .message = "cube expects size to be greater than zero, got -2.5" },
        .{ .src = "cylinder(5, -10)", .message = "cylinder expects h to be greater than zero, got -10" },
        .{ .src = "cylinder(d: -3, h: 4)", .message = "cylinder expects d to be greater than zero, got -3" },
        .{ .src = "sphere(r: 0)", .message = "sphere expects r to be greater than zero, got 0" },
        .{ .src = "regular_polygon(6, -1)", .message = "regular_polygon expects r to be greater than zero, got -1" },
        .{ .src = "torus(10, -2)", .message = "torus expects minor_r to be greater than zero, got -2" },
        .{ .src = "text(\"A\", -4)", .message = "text expects size to be greater than zero, got -4" },
    };
    for (cases) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.src});
        var engine = try runRule(testing.allocator, case.src);
        defer engine.deinit();
        try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
        try testing.expectEqualStrings(case.message, engine.diagnostics.items[0].message);
    }
}

test "Linter Rule: NegativeDimRule leaves coordinates and non-size arguments alone" {
    // It used to warn on any negative argument of any call: 10 warnings across the examples.
    const sources = [_][]const u8{
        "cube(10).translate(-5, 0, -1)",
        "part.trim_by_plane(0, 0, -1, -18)",
        "part.ray_cast([0, 0, 50], [0, 0, -50])",
        "cube(10, 10, 10, center: true)",
        "cylinder(r: 5, h: 10, center: false)",
        "regular_polygon(6, 5)",
        // A computed size, a splat or a method of the same name: nothing to read statically.
        "w = 5\ncube(w - 10)",
        "dims = [1, 2, 3]\ncube(*dims, -1)",
        "part.cube(-5)",
        "box.width = -10",
    };
    for (sources) |src| {
        errdefer std.debug.print("source: {s}\n", .{src});
        var engine = try runRule(testing.allocator, src);
        defer engine.deinit();
        try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
    }
}
