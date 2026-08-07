const std = @import("std");
const ast = @import("../../../core/ast.zig");
const FormatRule = @import("rule.zig").FormatRule;

pub const SortImportsRule = struct {
    pub fn rule(self: *SortImportsRule) FormatRule {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = getName,
                .processBlockStmts = processBlockStmts,
            },
        };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "Sort Imports";
    }

    fn processBlockStmts(ptr: *anyopaque, temp_allocator: std.mem.Allocator, tree: *const ast.Tree, stmts: []const ast.NodeIndex) []const ast.NodeIndex {
        _ = ptr;
        if (stmts.len < 2) return stmts;

        // Note: Because rules must be non-destructive to the original AST slice,
        // we copy the slice into the temporary arena passed by the Formatter.
        var new_stmts = temp_allocator.dupe(ast.NodeIndex, stmts) catch return stmts;

        var i: usize = 0;
        while (i < new_stmts.len) {
            const start_node = tree.getNode(new_stmts[i]).?;
            if (start_node.kind == .import_stmt) {
                var j = i + 1;
                while (j < new_stmts.len) {
                    const next_node = tree.getNode(new_stmts[j]).?;
                    if (next_node.kind != .import_stmt) break;
                    j += 1;
                }

                if (j - i > 1) {
                    const block = new_stmts[i..j];
                    // Sort the indices based on the path of their resolved nodes
                    std.mem.sort(ast.NodeIndex, block, tree, struct {
                        fn lessThan(ctx_tree: *const ast.Tree, a_idx: ast.NodeIndex, b_idx: ast.NodeIndex) bool {
                            const a = ctx_tree.getNode(a_idx).?;
                            const b = ctx_tree.getNode(b_idx).?;
                            return std.mem.lessThan(u8, a.kind.import_stmt.path, b.kind.import_stmt.path);
                        }
                    }.lessThan);
                }
                i = j;
            } else {
                i += 1;
            }
        }

        return new_stmts;
    }

    fn importLessThan(_: void, a: *ast.Node, b: *ast.Node) bool {
        const path_a = a.kind.import_stmt.path;
        const path_b = b.kind.import_stmt.path;
        return std.mem.order(u8, path_a, path_b) == .lt;
    }
};
