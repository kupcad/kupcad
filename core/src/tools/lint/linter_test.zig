const std = @import("std");
const testing = std.testing;
const linter = @import("linter.zig");
const parser_mod = @import("../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../frontend/kupcad/lexer.zig");

test "Linter: Registers default rules based on config" {
    var engine = linter.Linter.init(testing.allocator, .{});
    defer engine.deinit();

    try engine.registerDefaultRules();
    try testing.expect(engine.rules.items.len > 0);

    // Check that our first registered rule is the NegativeDimRule, which returns the name below:
    try testing.expectEqualStrings("Negative Dimension Check", engine.rules.items[0].vtable.name(engine.rules.items[0].ptr));
}

test "Linter: Scope shadowing inside blocks (do ... end) and lambdas" {
    const source =
        \\a = 10
        \\block do |a|
        \\end
    ;
    // We isolate this test to just the unused vars rule
    var engine = linter.Linter.init(testing.allocator, .{
        .check_negative_dims = false,
        .check_unused_vars = true,
        .check_unreachable_code = false,
        .check_self_subtraction = false,
    });
    defer engine.deinit();
    try engine.registerDefaultRules();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(arena.allocator());

    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const root = try parser.parseProgram();

    try engine.check(&parser.b.tree, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);

    // We expect exactly two warnings here: one for the global `a` and one for the shadowed block param `a`
    try testing.expectEqual(@as(usize, 2), engine.diagnostics.items.len);
    try testing.expectEqual(linter.LinterSeverity.warning, engine.diagnostics.items[0].severity);
    try testing.expectEqualStrings("Unused variable 'a'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
    try testing.expectEqualStrings("Unused variable 'a'. Prefix with '_' if intentional.", engine.diagnostics.items[1].message);
}

test "Linter: Iterative traversal prevents stack overflow on deeply nested AST" {
    const depth: usize = 500;
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

    // Verify linter runs on 500-deep nested AST without stack overflow
    try engine.check(&parser.b.tree, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);
}
