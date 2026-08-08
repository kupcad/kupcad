const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const ParamDocsRule = struct {
    documented_vars: std.StringHashMapUnmanaged(ast.Location) = .empty,

    pub fn rule(self: *@This()) LintRule {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = name,
                .checkNode = checkNode,
                .checkEOF = checkEOF,
            },
        };
    }

    fn name(_: *anyopaque) []const u8 {
        return "Param Docs Check";
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        var self = @as(*ParamDocsRule, @ptrCast(@alignCast(ptr)));
        const node = tree.getNode(node_idx) orelse return;

        if (node.kind == .param_doc) {
            const doc_idx = node.kind.param_doc;
            const doc = tree.param_docs.items[doc_idx];
            if (doc.target_name != .none) {
                const target_str = tree.getString(doc.target_name);
                try self.documented_vars.put(engine.allocator, target_str, node.loc);
            }
        } else if (node.kind == .def_stmt) {
            for (tree.getParams(node.kind.def_stmt.params)) |p| {
                const p_name = tree.getString(p.name);
                _ = self.documented_vars.remove(p_name);
            }
        } else if (node.kind == .assignment) {
            const a_name = tree.getString(node.kind.assignment.name);
            _ = self.documented_vars.remove(a_name);
        }
    }

    fn checkEOF(ptr: *anyopaque, engine: *linter.Linter) !void {
        var self = @as(*ParamDocsRule, @ptrCast(@alignCast(ptr)));
        defer self.documented_vars.deinit(engine.allocator);

        var it = self.documented_vars.iterator();
        while (it.next()) |entry| {
            try engine.addDiagnostic(entry.value_ptr.*, .info, "@param annotation references variable '{s}', which is never declared in standard scope.", .{entry.key_ptr.*});
        }
    }
};
