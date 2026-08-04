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
        walk(node);
    }

    fn walk(node: *ast.Node) void {
        switch (node.kind) {
            .block => |b| {
                var start_idx: ?usize = null;
                for (b.stmts, 0..) |stmt, i| {
                    if (stmt.kind == .import_stmt) {
                        if (start_idx == null) start_idx = i;
                    } else {
                        if (start_idx) |start| {
                            if (i - start > 1) {
                                // Safely cast away constness because we own this dynamically allocated AST
                                std.mem.sort(*ast.Node, @constCast(b.stmts[start..i]), {}, importLessThan);
                            }
                        }
                        start_idx = null;
                    }
                }
                // Handle trailing imports at the end of a block
                if (start_idx) |start| {
                    if (b.stmts.len - start > 1) {
                        std.mem.sort(*ast.Node, @constCast(b.stmts[start..b.stmts.len]), {}, importLessThan);
                    }
                }
                // Recurse into statements
                for (b.stmts) |stmt| walk(stmt);
            },
            .def_stmt => |d| walk(d.body),
            .class_stmt => |c| walk(c.body),
            .module_stmt => |m| walk(m.body),
            .if_stmt => |ifs| {
                walk(ifs.then_branch);
                if (ifs.else_branch) |eb| walk(eb);
            },
            .while_stmt => |w| walk(w.body),
            .begin_stmt => |b| {
                walk(b.body);
                for (b.rescues) |r| walk(r.body);
                if (b.ensure_body) |eb| walk(eb);
            },
            else => {},
        }
    }

    fn importLessThan(_: void, a: *ast.Node, b: *ast.Node) bool {
        const path_a = a.kind.import_stmt.path;
        const path_b = b.kind.import_stmt.path;
        return std.mem.order(u8, path_a, path_b) == .lt;
    }
};
