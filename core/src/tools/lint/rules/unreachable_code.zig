const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const UnreachableCodeRule = struct {
    pub fn rule(self: *UnreachableCodeRule) LintRule {
        return .{ .ptr = self, .vtable = &.{ .name = getName, .checkNode = checkNode } };
    }
    fn getName(_: *anyopaque) []const u8 {
        return "Unreachable Code Check";
    }

    fn checkNode(_: *anyopaque, node: *ast.Node, engine: *linter.Linter) !void {
        if (node.kind == .block) {
            var unreachable_found = false;
            for (node.kind.block.stmts) |stmt| {
                if (unreachable_found) {
                    try engine.addDiagnostic(stmt.loc, .warning, "Unreachable code detected after explicit control flow return/break.", .{});
                }
                if (stmt.kind == .return_stmt or stmt.kind == .break_stmt or stmt.kind == .next_stmt) {
                    unreachable_found = true;
                }
            }
        }
    }
};
