//! The `self-subtraction` lint rule (`SelfSubtractionRule`): flags a shape subtracted from
//! itself, `a - a` or `a.difference(a)`, which always leaves an empty shape.

const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

/// Reports a variable the script shows to hold a shape (a Solid, a Sketch or a Path) taken
/// away from itself; a number (`n - n`) or a value of unknown kind is left alone, as it
/// may mean something.
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

    fn checkNode(_: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx) orelse return;
        const operands: [2]ast.NodeIndex = switch (node.tag) {
            .binary_op => operands: {
                const bin = tree.binaryExpr(node);
                if (bin.op != .subtract) return;
                break :operands .{ bin.left, bin.right };
            },
            .method_call => operands: {
                const call = tree.methodCall(node);
                if (call.receiver == .none or !std.mem.eql(u8, tree.getString(call.method_name), "difference")) return;
                const args = tree.getNamedArgs(call.args);
                if (args.len != 1 or args[0].name != .none or args[0].modifier != null) return;
                break :operands .{ call.receiver, args[0].value };
            },
            else => return,
        };
        const name = sameShape(engine, tree, operands[0], operands[1]) orelse return;
        if (node.tag == .binary_op) {
            try engine.report(id, engine.getLoc(node.main_token), "'{s} - {s}' subtracts a shape from itself, which leaves nothing", .{ name, name });
        } else {
            try engine.report(id, engine.getLoc(node.main_token), "'{s}.difference({s})' subtracts a shape from itself, which leaves nothing", .{ name, name });
        }
    }

    /// The name of the variable `a` and `b` both are, when it holds a shape.
    fn sameShape(engine: *const linter.Linter, tree: *const ast.Tree, a: ast.NodeIndex, b: ast.NodeIndex) ?[]const u8 {
        const left = tree.getNode(a) orelse return null;
        const right = tree.getNode(b) orelse return null;
        if (left.tag != .identifier or right.tag != .identifier or left.data != right.data) return null;
        if (engine.shapes.of(tree, a) == null) return null;
        return tree.nodeString(left);
    }
};
