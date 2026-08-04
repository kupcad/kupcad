const std = @import("std");
const testing = std.testing;
const ast = @import("../../../core/ast.zig");
const linter_mod = @import("../linter.zig");
const config_mod = @import("../config.zig");
const UnusedVarsRule = @import("unused_vars.zig").UnusedVarsRule;

test "Linter Rule: UnusedVarsRule catches unused variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\x = 10
        \\_y = 20
        \\z = 30
        \\cube(z)
    ;

    // Init linter with ALL rules turned off via config
    var linter = linter_mod.Linter.init(arena.allocator(), .{ .check_negative_dims = false, .check_unused_vars = false });
    defer linter.deinit();

    // Manually register only the UnusedVarsRule
    var rule_impl = UnusedVarsRule{};
    try linter.rules.append(arena.allocator(), rule_impl.rule());

    // Run the AST walk
    try linter.check(source);

    try testing.expectEqual(@as(usize, 1), linter.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'x'. Prefix with '_' if intentional.", linter.diagnostics.items[0].message);
}
