const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const SelfSubtractionRule = struct {
    pub fn rule(self: *SelfSubtractionRule) LintRule {
        return .{ .ptr = self, .vtable = &.{ .name = getName, .checkNode = checkNode } };
    }
    fn getName(_: *anyopaque) []const u8 {
        return "Self Subtraction Check";
    }

    fn checkNode(_: *anyopaque, node: *ast.Node, engine: *linter.Linter) !void {
        if (node.kind == .binary_op) {
            const b = node.kind.binary_op;
            if (b.op == .subtract and b.left.kind == .identifier and b.right.kind == .identifier) {
                if (std.mem.eql(u8, b.left.kind.identifier, b.right.kind.identifier)) {
                    try engine.addDiagnostic(node.loc, .warning, "CSG Warning: Self-difference operation ('a - a') will result in empty geometry.", .{});
                }
            }
        }
    }
};
