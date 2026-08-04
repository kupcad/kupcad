const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const UnusedVarsRule = struct {
    pub fn rule(self: *UnusedVarsRule) LintRule {
        return .{ .ptr = self, .vtable = &.{ .name = getName, .exitScope = exitScope } };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "Unused Variables Check";
    }

    fn exitScope(_: *anyopaque, scope: *const linter.Scope, engine: *linter.Linter) !void {
        var var_iter = scope.declared_vars.iterator();
        while (var_iter.next()) |entry| {
            const var_name = entry.key_ptr.*;
            if (!scope.used_vars.contains(var_name) and var_name[0] != '_') {
                try engine.addDiagnostic(entry.value_ptr.*, .warning, "Unused variable '{s}'. Prefix with '_' if intentional.", .{var_name});
            }
        }
    }
};
