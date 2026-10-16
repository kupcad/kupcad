const std = @import("std");
const testing = std.testing;
const linter = @import("linter.zig");
const parser_mod = @import("../../frontend/parser.zig");
const lexer_mod = @import("../../frontend/lexer.zig");
const limits = @import("../../core/limits.zig");
const lint_testing = @import("testing.zig");

test "Linter: Registers default rules based on config" {
    var engine = linter.Linter.init(testing.allocator, .{});
    defer engine.deinit();

    try engine.registerDefaultRules();
    // Every rule is enabled by default, each under its id
    try testing.expectEqual(linter.RuleSet.ids.len, engine.rules.items.len);
    for (engine.rules.items, linter.RuleSet.ids) |rule, id| try testing.expectEqualStrings(id, rule.id);

    // A rule the config turns off is not run
    var quiet = linter.Linter.init(testing.allocator, .{ .@"unused-variable" = .off });
    defer quiet.deinit();
    try quiet.registerDefaultRules();
    try testing.expectEqual(linter.RuleSet.ids.len - 1, quiet.rules.items.len);
    for (quiet.rules.items) |rule| try testing.expect(!std.mem.eql(u8, rule.id, "unused-variable"));
}

test "Linter: a rule reports at the level the config gives it, under its id" {
    const levels = [_]struct { level: @import("config.zig").Level, severity: linter.LinterSeverity }{
        .{ .level = .info, .severity = .info },
        .{ .level = .warning, .severity = .warning },
        .{ .level = .@"error", .severity = .@"error" },
    };
    for (levels) |case| {
        var config = lint_testing.only("unused-variable");
        config.@"unused-variable" = case.level;
        var engine = try lint_testing.lint(testing.allocator, "x = 1\nputs 2", config);
        defer engine.deinit();
        try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
        try testing.expectEqual(case.severity, engine.diagnostics.items[0].severity);
        try testing.expectEqualStrings("unused-variable", engine.diagnostics.items[0].rule.?);
    }
}

test "Linter: Scope shadowing inside blocks (do ... end)" {
    const source =
        \\a = 10
        \\block do |a|
        \\end
    ;
    // We isolate this test to just the unused vars rule
    var engine = linter.Linter.init(testing.allocator, lint_testing.only("unused-variable"));
    defer engine.deinit();
    try engine.registerDefaultRules();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(arena.allocator());

    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const root = try parser.parseProgram();

    try engine.check(&parser.b.tree, source, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);

    // We expect exactly two warnings here: one for the global `a` and one for the shadowed block param `a`
    try testing.expectEqual(@as(usize, 2), engine.diagnostics.items.len);
    try testing.expectEqual(linter.LinterSeverity.warning, engine.diagnostics.items[0].severity);
    try testing.expectEqualStrings("Unused variable 'a'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
    try testing.expectEqualStrings("Unused variable 'a'. Prefix with '_' if intentional.", engine.diagnostics.items[1].message);
}

test "Linter: Iterative traversal prevents stack overflow on deeply nested AST" {
    // Deep, but still within the parser's MAX_AST_DEPTH for nested `if`
    const depth: usize = limits.MAX_AST_DEPTH / 3;
    var source_buf = std.ArrayListUnmanaged(u8).empty;
    defer source_buf.deinit(testing.allocator);

    for (0..depth) |_| try source_buf.appendSlice(testing.allocator, "if true\n");
    try source_buf.appendSlice(testing.allocator, "x = 1\n");
    for (0..depth) |_| try source_buf.appendSlice(testing.allocator, "end\n");

    var engine = linter.Linter.init(testing.allocator, .{});
    defer engine.deinit();
    try engine.registerDefaultRules();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = lexer_mod.Lexer.init(source_buf.items, 0);
    const tokens = try lexer.lexAll(arena.allocator());

    var parser = try parser_mod.Parser.init(tokens, source_buf.items, arena.allocator());
    const root = try parser.parseProgram();

    // The parser must accept the whole tree, or the linter would see a shallow one
    try testing.expectEqual(@as(usize, 0), parser.diagnostics.list.items.len);
    try engine.check(&parser.b.tree, source_buf.items, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);
}
