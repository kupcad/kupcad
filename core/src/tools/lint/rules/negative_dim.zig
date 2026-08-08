const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const NegativeDimRule = struct {
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
        return "Negative Dimension Check";
    }

    fn isCoordinate(name_str: []const u8) bool {
        return std.mem.eql(u8, name_str, "x") or std.mem.eql(u8, name_str, "y") or std.mem.eql(u8, name_str, "z");
    }

    fn checkValue(engine: *linter.Linter, tree: *const ast.Tree, val_idx: ast.NodeIndex, prop_name: []const u8) !void {
        if (val_idx == .none) return;
        const val = tree.getNode(val_idx) orelse return;

        if (val.tag == .unary_op and tree.unaryExpr(val).op == .negate) {
            const operand = tree.getNode(tree.unaryExpr(val).operand).?;
            if (operand.tag == .number) {
                try engine.addDiagnostic(engine.getLoc(val.main_token), .warning, "CAD Warning: Property '{s}' in primitive construction has non-positive dimension.", .{prop_name});
            }
        } else if (val.tag == .number and tree.number(val) < 0) {
            try engine.addDiagnostic(engine.getLoc(val.main_token), .warning, "CAD Warning: Property '{s}' in primitive construction has non-positive dimension.", .{prop_name});
        } else if (val.tag == .array_literal) {
            for (tree.getNodes(tree.nodeSpan(val))) |elem_idx| {
                try checkValue(engine, tree, elem_idx, prop_name);
            }
        }
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;

        if (node.tag == .method_call) {
            for (tree.getNamedArgs(tree.methodCall(node).args)) |arg| {
                const arg_name = tree.getString(arg.name);
                if (isCoordinate(arg_name)) continue;
                try checkValue(engine, tree, arg.value, arg_name);
            }
        } else if (node.tag == .property_assignment) {
            const pa = tree.propertyAssignment(node);
            const prop_name = tree.getString(pa.property);
            if (isCoordinate(prop_name)) return;
            try checkValue(engine, tree, pa.value, prop_name);
        }
    }
};
