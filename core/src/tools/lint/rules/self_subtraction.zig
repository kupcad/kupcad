//! The `self-subtraction` lint rule (`SelfSubtractionRule`): flags `a - a`, a variable
//! subtracted from itself, which always leaves an empty shape.

const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const SelfSubtractionRule = struct {
    pub const id = "self-subtraction";
    pub const description = "A shape subtracted from itself, which is always empty";

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

        if (node.tag == .binary_op) {
            const bin = tree.binaryExpr(node);
            if (bin.op == .subtract) {
                const left = tree.getNode(bin.left).?;
                const right = tree.getNode(bin.right).?;

                if (left.tag == .identifier and right.tag == .identifier) {
                    if (left.data == right.data) {
                        const var_name = tree.getString(@as(ast.StringId, @fromBackingInt(left.data)));
                        try engine.report(id, engine.getLoc(node.main_token), "'{s} - {s}' subtracts a shape from itself, which leaves nothing", .{ var_name, var_name });
                    }
                }
            }
        }
    }
};
