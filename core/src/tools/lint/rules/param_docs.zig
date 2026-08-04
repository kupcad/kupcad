const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const token = @import("../../../core/token.zig");
const LintRule = @import("rule.zig").LintRule;

pub const ParamDocsRule = struct {
    param_docs: std.StringHashMapUnmanaged(token.Location) = .empty,

    pub fn rule(self: *ParamDocsRule) LintRule {
        return .{ .ptr = self, .vtable = &.{ .name = getName, .checkNode = checkNode, .exitScope = exitScope } };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "Param Doc Match Check";
    }

    fn checkNode(ptr: *anyopaque, node: *ast.Node, engine: *linter.Linter) !void {
        var self: *ParamDocsRule = @ptrCast(@alignCast(ptr));
        if (node.kind == .param_doc) {
            if (node.kind.param_doc.target_name) |target| {
                try self.param_docs.put(engine.allocator, target, node.loc);
            }
        }
    }

    fn exitScope(ptr: *anyopaque, scope: *const linter.Scope, engine: *linter.Linter) !void {
        var self: *ParamDocsRule = @ptrCast(@alignCast(ptr));
        // The root scope is popped last, leaving 0 scopes in the engine stack
        if (engine.scopes.items.len == 0) {
            var doc_iter = self.param_docs.iterator();
            while (doc_iter.next()) |entry| {
                const param_name = entry.key_ptr.*;
                if (!scope.declared_vars.contains(param_name)) {
                    try engine.addDiagnostic(entry.value_ptr.*, .info, "@param annotation references variable '{s}', which is never declared in standard scope.", .{param_name});
                }
            }
            self.param_docs.deinit(engine.allocator);
            self.param_docs = .empty; // crucial reset for Linter reuse
        }
    }
};
