const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const UnreachableCodeRule = struct {
    pub fn rule(self: *@This()) LintRule {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = name,
                .checkNode = checkNode,
            },
        };
    }

    fn name(_: *anyopaque) []const u8 {
        return "Unreachable Code Check";
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;

        if (node.tag == .block) {
            const b = tree.blocks.items[node.data];
            var found_terminal = false;
            for (tree.getNodes(b.stmts)) |stmt_idx| {
                const stmt_node = tree.getNode(stmt_idx).?;

                if (found_terminal) {
                    try engine.addDiagnostic(stmt_node.loc, .warning, "Unreachable code detected after explicit control flow return/break.", .{});
                }

                if (stmt_node.tag == .return_stmt or stmt_node.tag == .break_stmt or stmt_node.tag == .next_stmt) {
                    found_terminal = true;
                }
            }
        }
    }
};
