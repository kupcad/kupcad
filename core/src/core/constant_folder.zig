const std = @import("std");
const ast = @import("ast.zig");
const visitor = @import("visitor.zig");

pub const ConstantFolder = struct {
    b: *ast.Builder,
    folded_count: usize = 0, // Used for statistics/testing

    pub fn fold(self: *ConstantFolder, root: ast.NodeIndex) !void {
        if (root == .none) return;
        var ctx = FoldingContext{ .folder = self };
        try visitor.walk(FoldingContext, &ctx, &self.b.tree, root);
    }
};

const FoldingContext = struct {
    folder: *ConstantFolder,

    // We use leaveNode (post-order traversal) so that children are fully folded
    // into numbers before we attempt to fold their parent binary/unary operations!
    pub fn leaveNode(self: *FoldingContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;

        switch (node.tag) {
            .binary_op => {
                const bin = tree.binaryExpr(node);
                const left_node = tree.getNode(bin.left).?;
                const right_node = tree.getNode(bin.right).?;

                // We can only fold if both children are raw numbers
                if (left_node.tag == .number and right_node.tag == .number) {
                    const left_val = tree.number(left_node);
                    const right_val = tree.number(right_node);

                    const folded_val: ?f64 = switch (bin.op) {
                        .add => left_val + right_val,
                        .subtract => left_val - right_val,
                        .multiply => left_val * right_val,
                        .divide => if (right_val != 0.0) left_val / right_val else null,
                        .modulo => if (right_val != 0.0) @mod(left_val, right_val) else null,
                        .exponent => std.math.pow(f64, left_val, right_val),
                        else => null, // Comparison operators can't be folded to a number
                    };

                    if (folded_val) |val| {
                        // Create the new number node using our deduplication pool!
                        const new_node_idx = try self.folder.b.numberRaw(val, node.main_token);

                        // Mutate the AST by copying the newly created number node over the old binary node
                        const target_node = &self.folder.b.tree.nodes.items[@intFromEnum(node_idx)];
                        const src_node = tree.getNode(new_node_idx).?;
                        target_node.tag = src_node.tag;
                        target_node.data = src_node.data;

                        self.folder.folded_count += 1;
                    }
                }
            },
            .unary_op => {
                const un = tree.unaryExpr(node);
                const operand_node = tree.getNode(un.operand).?;

                if (operand_node.tag == .number) {
                    const operand_val = tree.number(operand_node);

                    const folded_val: ?f64 = switch (un.op) {
                        .negate => -operand_val,
                        .positive => operand_val,
                        else => null,
                    };

                    if (folded_val) |val| {
                        const new_node_idx = try self.folder.b.numberRaw(val, node.main_token);

                        const target_node = &self.folder.b.tree.nodes.items[@intFromEnum(node_idx)];
                        const src_node = tree.getNode(new_node_idx).?;
                        target_node.tag = src_node.tag;
                        target_node.data = src_node.data;

                        self.folder.folded_count += 1;
                    }
                }
            },
            else => {},
        }
    }
};
