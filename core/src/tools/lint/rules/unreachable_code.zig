const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const UnreachableCodeRule = struct {
    pub const id = "unreachable-code";
    pub const description = "Statements after a return, break or next";

    pub fn rule(self: *@This()) LintRule {
        return .{
            .id = id,
            .ptr = self,
            .vtable = &.{
                .checkNode = checkNode,
            },
        };
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;

        if (node.tag == .block) {
            const b = tree.block(node);
            var found_terminal = false;
            for (tree.getNodes(b.stmts)) |stmt_idx| {
                const stmt_node = tree.getNode(stmt_idx).?;

                if (found_terminal) {
                    try engine.report(id, engine.getLoc(stmt_node.main_token), "Unreachable code detected after explicit control flow return/break.", .{});
                }

                if (stmt_node.tag == .return_stmt or stmt_node.tag == .break_stmt or stmt_node.tag == .next_stmt) {
                    found_terminal = true;
                }
            }
        }
    }
};
