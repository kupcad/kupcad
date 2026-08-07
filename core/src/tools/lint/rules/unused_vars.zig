const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const UnusedVarsRule = struct {
    pub fn rule(self: *@This()) LintRule {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = name,
                .exitScope = exitScope,
            },
        };
    }

    fn name(_: *anyopaque) []const u8 {
        return "Unused Variables Check";
    }

    fn exitScope(ptr: *anyopaque, scope: *const linter.Scope, engine: *linter.Linter) !void {
        _ = ptr;
        var iter = scope.declared_vars.iterator();

        while (iter.next()) |entry| {
            const var_name = entry.key_ptr.*;
            const loc = entry.value_ptr.*;

            // Flag if not used and doesn't start with an underscore (which marks intentional disuse)
            if (!scope.used_vars.contains(var_name) and (var_name.len == 0 or var_name[0] != '_')) {
                try engine.addDiagnostic(loc, .warning, "Unused variable '{s}'. Prefix with '_' if intentional.", .{var_name});
            }
        }
    }
};
