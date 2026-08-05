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

    fn processBlockStmts(_: *anyopaque, temp_allocator: std.mem.Allocator, stmts: []const *ast.Node) []const *ast.Node {
        if (stmts.len <= 1) return stmts;

        // Allocate a temporary slice so we don't mutate the original AST
        var sorted = std.ArrayListUnmanaged(*ast.Node).empty;
        sorted.appendSlice(temp_allocator, stmts) catch return stmts;

        var start_idx: ?usize = null;
        for (sorted.items, 0..) |stmt, i| {
            if (stmt.kind == .import_stmt) {
                if (start_idx == null) start_idx = i;
            } else {
                if (start_idx) |start| {
                    if (i - start > 1) {
                        std.mem.sort(*ast.Node, sorted.items[start..i], {}, importLessThan);
                    }
                }
                start_idx = null;
            }
        }
        if (start_idx) |start| {
            if (sorted.items.len - start > 1) {
                std.mem.sort(*ast.Node, sorted.items[start..], {}, importLessThan);
            }
        }

        // Return the ephemerally sorted array
        return sorted.items;
    }

    fn importLessThan(_: void, a: *ast.Node, b: *ast.Node) bool {
        const path_a = a.kind.import_stmt.path;
        const path_b = b.kind.import_stmt.path;
        return std.mem.order(u8, path_a, path_b) == .lt;
    }
};
