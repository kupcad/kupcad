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

        if (node.kind == .binary_op and node.kind.binary_op.op == .subtract) {
            const left = tree.getNode(node.kind.binary_op.left).?;
            const right = tree.getNode(node.kind.binary_op.right).?;

            if (left.kind == .identifier and right.kind == .identifier) {
                if (std.mem.eql(u8, left.kind.identifier, right.kind.identifier)) {
                    try engine.addDiagnostic(node.loc, .warning, "CSG Warning: Self-difference operation ('{s} - {s}') will result in empty geometry.", .{ left.kind.identifier, right.kind.identifier });
                }
            }
        }
    }
};
