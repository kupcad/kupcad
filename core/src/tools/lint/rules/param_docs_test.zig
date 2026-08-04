const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const ParamDocsRule = @import("param_docs.zig").ParamDocsRule;

test "Linter Rule: ParamDocsRule catches missing variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\# @param missing_var [Length] This variable doesn't exist
        \\actual_var = 100
    ;

    var linter = linter_mod.Linter.init(arena.allocator(), .{
        .check_negative_dims = false,
        .check_unused_vars = false,
        .check_unreachable_code = false,
        .check_self_subtraction = false,
        .check_param_docs = false,
    });
    defer linter.deinit();

    var rule_impl = ParamDocsRule{};
    try linter.rules.append(arena.allocator(), rule_impl.rule());

    try linter.check(source);

    try testing.expectEqual(@as(usize, 1), linter.diagnostics.items.len);
    try testing.expectEqualStrings("@param annotation references variable 'missing_var', which is never declared in standard scope.", linter.diagnostics.items[0].message);
}
