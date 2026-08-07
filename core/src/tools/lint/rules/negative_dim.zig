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

        if (val.kind == .unary_op and val.kind.unary_op.op == .negate) {
            const operand = tree.getNode(val.kind.unary_op.operand).?;
            if (operand.kind == .number) {
                try engine.addDiagnostic(val.loc, .warning, "CAD Warning: Property '{s}' in primitive construction has non-positive dimension.", .{prop_name});
            }
        } else if (val.kind == .number and val.kind.number < 0) {
            try engine.addDiagnostic(val.loc, .warning, "CAD Warning: Property '{s}' in primitive construction has non-positive dimension.", .{prop_name});
        } else if (val.kind == .array_literal) {
            for (val.kind.array_literal) |elem_idx| {
                try checkValue(engine, tree, elem_idx, prop_name);
            }
        }
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;

        if (node.kind == .method_call) {
            for (node.kind.method_call.args) |arg| {
                if (isCoordinate(arg.name)) continue;
                try checkValue(engine, tree, arg.value, arg.name);
            }
        } else if (node.kind == .property_assignment) {
            if (isCoordinate(node.kind.property_assignment.property)) return;
            try checkValue(engine, tree, node.kind.property_assignment.value, node.kind.property_assignment.property);
        }
    }
};
