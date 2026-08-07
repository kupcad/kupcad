const std = @import("std");
const testing = std.testing;
const api = @import("../../../api.zig");
const linter_mod = @import("../linter.zig");
const SelfSubtractionRule = @import("self_subtraction.zig").SelfSubtractionRule;

test "Linter Rule: SelfSubtractionRule catches a - a" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "result = part - part";

    var linter = linter_mod.Linter.init(arena.allocator(), .{
        .check_negative_dims = false,
        .check_unused_vars = false,
        .check_unreachable_code = false,
        .check_self_subtraction = false,
        .check_param_docs = false,
    });
    defer linter.deinit();

    var rule_impl = SelfSubtractionRule{};
    try linter.rules.append(arena.allocator(), rule_impl.rule());

    var doc = try api.Document.parse(testing.allocator, source);
    defer doc.deinit();

    try linter.check(&doc.tree, doc.tree.root, doc.diagnostics);

    try testing.expectEqual(@as(usize, 1), linter.diagnostics.items.len);
    try testing.expectEqualStrings("CSG Warning: Self-difference operation ('part - part') will result in empty geometry.", linter.diagnostics.items[0].message);
}
