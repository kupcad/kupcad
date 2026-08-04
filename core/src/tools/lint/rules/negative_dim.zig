const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const NegativeDimRule = struct {
    pub fn rule(self: *NegativeDimRule) LintRule {
        return .{ .ptr = self, .vtable = &.{ .name = getName, .checkNode = checkNode } };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "Negative Dimension Check";
    }

    fn isDimensionName(name: []const u8) bool {
        const dims = [_][]const u8{ "r", "h", "d", "w", "l", "radius", "height", "diameter", "width", "length", "depth", "thickness", "size" };
        for (dims) |dim| {
            if (std.mem.eql(u8, name, dim)) return true;
        }
        return false;
    }

    fn isNodeNegative(node: *ast.Node) bool {
        switch (node.kind) {
            .number => |n| return n <= 0.0,
            .unary_op => |u| return u.op == .negate,
            .assignment => |a| return isNodeNegative(a.value),
            .array_literal => |arr| {
                for (arr) |elem| if (isNodeNegative(elem)) return true;
                return false;
            },
            else => return false,
        }
    }

    fn checkNode(_: *anyopaque, node: *ast.Node, engine: *linter.Linter) !void {
        switch (node.kind) {
            .property_assignment => |pa| {
                if (isDimensionName(pa.property) and isNodeNegative(pa.value)) {
                    try engine.addDiagnostic(pa.value.loc, .warning, "CAD Warning: Property '{s}' in primitive construction has non-positive dimension.", .{pa.property});
                }
            },
            .method_call => |mc| {
                for (mc.args) |arg| {
                    if (arg.name.len > 0 and isDimensionName(arg.name)) {
                        if (isNodeNegative(arg.value)) {
                            try engine.addDiagnostic(arg.value.loc, .warning, "CAD Warning: Property '{s}' in primitive construction has non-positive dimension.", .{arg.name});
                        }
                    }
                }
            },
            else => {},
        }
    }
};
