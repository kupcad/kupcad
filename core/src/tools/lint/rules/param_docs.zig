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
        return "Param Doc Match Check";
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        var self = @as(*ParamDocsRule, @ptrCast(@alignCast(ptr)));
        const node = tree.getNode(node_idx) orelse return;

        if (node.kind == .param_doc) {
            if (node.kind.param_doc.target_name) |target| {
                try self.documented_vars.put(engine.allocator, target, node.loc);
            }
        }
    }

    fn checkEOF(ptr: *anyopaque, engine: *linter.Linter) !void {
        var self = @as(*ParamDocsRule, @ptrCast(@alignCast(ptr)));

        var iter = self.documented_vars.iterator();
        while (iter.next()) |entry| {
            const var_name = entry.key_ptr.*;
            const loc = entry.value_ptr.*;

            // Verify if the annotated variable was actually declared in the root scope
            var found = false;
            if (engine.scopes.items.len > 0) {
                if (engine.scopes.items[0].declared_vars.contains(var_name)) {
                    found = true;
                }
            }

            if (!found) {
                try engine.addDiagnostic(loc, .info, "@param annotation references variable '{s}', which is never declared in standard scope.", .{var_name});
            }
        }
        self.documented_vars.deinit(engine.allocator);
    }
};
