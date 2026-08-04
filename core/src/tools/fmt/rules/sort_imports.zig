const std = @import("std");
const ast = @import("../../../core/ast.zig");
const FormatRule = @import("rule.zig").FormatRule;

pub const SortImportsRule = struct {
    pub fn rule(self: *SortImportsRule) FormatRule {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = getName,
                .normalize = normalize,
            },
        };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "Sort Imports";
    }

    fn normalize(_: *anyopaque, node: *ast.Node) void {
        var visitor = ast.Visitor{
            .ptr = undefined,
            .visitFn = visitNode,
        };
        visitor.walk(node) catch {};
    }

    fn visitNode(_: *anyopaque, node: *ast.Node) anyerror!bool {
        if (node.kind == .block) {
            const b = node.kind.block;
            var start_idx: ?usize = null;

            for (b.stmts, 0..) |stmt, i| {
                if (stmt.kind == .import_stmt) {
                    if (start_idx == null) start_idx = i;
                } else {
                    if (start_idx) |start| {
                        if (i - start > 1) {
                            std.mem.sort(*ast.Node, @constCast(b.stmts[start..i]), {}, importLessThan);
                        }
                    }
                    start_idx = null;
                }
            }
            if (start_idx) |start| {
                if (b.stmts.len - start > 1) {
                    std.mem.sort(*ast.Node, @constCast(b.stmts[start..b.stmts.len]), {}, importLessThan);
                }
            }
        }
        return true; // Always allow the generic visitor to continue recursing
    }

    fn importLessThan(_: void, a: *ast.Node, b: *ast.Node) bool {
        const path_a = a.kind.import_stmt.path;
        const path_b = b.kind.import_stmt.path;
        return std.mem.order(u8, path_a, path_b) == .lt;
    }
};
