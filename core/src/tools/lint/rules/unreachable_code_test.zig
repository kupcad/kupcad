const std = @import("std");
const testing = std.testing;
const api = @import("../../../api.zig");
const linter_mod = @import("../linter.zig");
const UnreachableCodeRule = @import("unreachable_code.zig").UnreachableCodeRule;

test "Linter Rule: UnreachableCodeRule catches code after return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\def check_flow()
        \\  return
        \\  cube()
        \\end
    ;

    // Init linter with ALL rules turned off via config to isolate this test
    var linter = linter_mod.Linter.init(arena.allocator(), .{
        .check_negative_dims = false,
        .check_unused_vars = false,
        .check_unreachable_code = false,
        .check_self_subtraction = false,
        .check_param_docs = false,
    });
    defer linter.deinit();

    // Manually register only the UnreachableCodeRule
    var rule_impl = UnreachableCodeRule{};
    try linter.rules.append(arena.allocator(), rule_impl.rule());

    // Run the full engine pipeline
    var doc = try api.Document.parse(testing.allocator, source);
    defer doc.deinit();

    try linter.check(doc.tree, doc.diagnostics);

    try testing.expectEqual(@as(usize, 1), linter.diagnostics.items.len);
    try testing.expectEqualStrings("Unreachable code detected after explicit control flow return/break.", linter.diagnostics.items[0].message);
}

test "Linter Rule: UnreachableCodeRule catches code after break and next" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\while true
        \\  break
        \\  cube() # Unreachable
        \\end
    ;

    var linter = linter_mod.Linter.init(arena.allocator(), .{
        .check_negative_dims = false,
        .check_unused_vars = false,
        .check_unreachable_code = false, // Overridden below
        .check_self_subtraction = false,
        .check_param_docs = false,
    });
    defer linter.deinit();

    var rule_impl = UnreachableCodeRule{};
    try linter.rules.append(arena.allocator(), rule_impl.rule());

    var doc = try api.Document.parse(testing.allocator, source);
    defer doc.deinit();

    try linter.check(doc.tree, doc.diagnostics);

    try testing.expectEqual(@as(usize, 1), linter.diagnostics.items.len);
    try testing.expectEqualStrings("Unreachable code detected after explicit control flow return/break.", linter.diagnostics.items[0].message);
}
