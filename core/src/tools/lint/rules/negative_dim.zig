const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const NegativeDimRule = struct {
    pub fn rule(self: *NegativeDimRule) LintRule {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = getName,
                .checkNode = checkNode,
            },
        };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "Negative Dimension Check";
    }

    fn isNodeNegative(node: *ast.Node) bool {
        switch (node.kind) {
            .number => |n| return n <= 0.0,
            .unary_op => |u| return u.op == .negate,
            .assignment => |a| return isNodeNegative(a.value),
            .array_literal => |arr| {
                for (arr) |elem| {
                    if (isNodeNegative(elem)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn checkNode(
        _: *anyopaque,
        node: *ast.Node,
        diagnostics: *std.ArrayListUnmanaged(linter.LinterDiagnostic),
        allocator: std.mem.Allocator,
    ) !void {
        switch (node.kind) {
            .property_assignment => |pa| {
                if (isNodeNegative(pa.value)) {
                    const msg = try std.fmt.allocPrint(allocator, "CAD Warning: Property '{s}' in primitive construction has non-positive dimension.", .{pa.property});
                    try diagnostics.append(allocator, .{
                        .loc = pa.value.loc,
                        .message = msg,
                        .severity = .warning,
                    });
                }
            },
            .method_call => |mc| {
                for (mc.args) |arg| {
                    if (isNodeNegative(arg.value)) {
                        const param_name = if (arg.name.len > 0) arg.name else "unnamed";
                        const msg = try std.fmt.allocPrint(allocator, "CAD Warning: Property '{s}' in primitive construction has non-positive dimension.", .{param_name});
                        try diagnostics.append(allocator, .{
                            .loc = arg.value.loc,
                            .message = msg,
                            .severity = .warning,
                        });
                    }
                }
            },
            else => {},
        }
    }
};
