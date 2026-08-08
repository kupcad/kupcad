const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const SelfSubtractionRule = struct {
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
        return "Self Subtraction Check";
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;

        if (node.tag == .binary_op) {
            const bin = tree.binaryExpr(node);
            if (bin.op == .subtract) {
                const left = tree.getNode(bin.left).?;
                const right = tree.getNode(bin.right).?;

                if (left.tag == .identifier and right.tag == .identifier) {
                    if (left.data == right.data) {
                        const var_name = tree.getString(@as(ast.StringId, @enumFromInt(left.data)));
                        try engine.addDiagnostic(engine.getLoc(node.main_token), .warning, "CSG Warning: Self-difference operation ('{s} - {s}') will result in empty geometry.", .{ var_name, var_name });
                    }
                }
            }
        }
    }
};
