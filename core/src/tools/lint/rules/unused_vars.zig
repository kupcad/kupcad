const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const UnusedVarsRule = struct {
    pub fn rule(self: *@This()) LintRule {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = name,
                .checkNode = checkNode,
                .enterScope = enterScope,
                .exitScope = exitScope,
            },
        };
    }

    fn name(_: *anyopaque) []const u8 {
        return "Unused Variable Check";
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;

        switch (node.tag) {
            .assignment => {
                const a = tree.assignment(node);
                try engine.declareVar(tree.getString(a.name), engine.getLoc(node.main_token));
            },
            .multiple_assignment => {
                const ma = tree.multipleAssignment(node);
                for (tree.getLhsExprs(ma.lhs)) |lhs| {
                    try engine.declareVar(tree.getString(lhs.name), engine.getLoc(node.main_token));
                }
            },
            .def_stmt => {
                const ds = tree.defStmt(node);
                // Function names belong to the scope they are declared in
                try engine.declareVar(tree.getString(ds.name), engine.getLoc(node.main_token));
            },
            .identifier => {
                try engine.markUsed(tree.getString(@as(ast.StringId, @enumFromInt(node.data))));
            },
            .method_call => {
                const mc = tree.methodCall(node);
                try engine.markUsed(tree.getString(mc.method_name));
            },
            else => {},
        }
    }

    fn declareLhsBindings(engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        if (node_idx == .none) return;
        const node = tree.getNode(node_idx) orelse return;

        switch (node.tag) {
            .identifier => {
                try engine.declareVar(tree.getString(@as(ast.StringId, @enumFromInt(node.data))), engine.getLoc(node.main_token));
            },
            .array_literal => {
                const span = tree.nodeSpan(node);
                for (tree.getNodes(span)) |elem_idx| {
                    try declareLhsBindings(engine, tree, elem_idx);
                }
            },
            .hash_literal => {
                const span = tree.nodeSpan(node);
                for (tree.getHashEntries(span)) |entry| {
                    try declareLhsBindings(engine, tree, entry.value);
                }
            },
            .splat_expr => {
                const inner = tree.nodeIndex(node);
                try declareLhsBindings(engine, tree, inner);
            },
            .double_splat_expr => {
                const inner = tree.nodeIndex(node);
                try declareLhsBindings(engine, tree, inner);
            },
            else => {},
        }
    }

    fn enterScope(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;

        // Variables declared here belong specifically to the newly pushed inner scope
        switch (node.tag) {
            .for_stmt => {
                const fs = tree.forStmt(node);
                for (tree.getForBindings(fs.bindings)) |b| {
                    try engine.declareVar(tree.getString(b.name), engine.getLoc(node.main_token));
                }
            },
            .def_stmt => {
                const ds = tree.defStmt(node);
                for (tree.getParams(ds.params)) |p| {
                    try engine.declareVar(tree.getString(p.name), engine.getLoc(node.main_token));
                }
            },
            .lambda_expr => {
                const le = tree.lambdaExpr(node);
                for (tree.getParams(le.params)) |p| {
                    try engine.declareVar(tree.getString(p.name), engine.getLoc(node.main_token));
                }
            },
            .block => {
                const b = tree.block(node);
                for (tree.getNodes(b.params)) |p_idx| {
                    try declareLhsBindings(engine, tree, p_idx);
                }
            },
            else => {},
        }
    }

    fn exitScope(ptr: *anyopaque, scope: *const linter.Scope, engine: *linter.Linter) !void {
        _ = ptr;
        var iter = scope.declared_vars.iterator();

        while (iter.next()) |entry| {
            const var_name = entry.key_ptr.*;
            const loc = entry.value_ptr.*;

            // Flag if not used and doesn't start with an underscore (which marks intentional disuse)
            if (!scope.used_vars.contains(var_name) and (var_name.len == 0 or var_name[0] != '_')) {
                try engine.addDiagnostic(loc, .warning, "Unused variable '{s}'. Prefix with '_' if intentional.", .{var_name});
            }
        }
    }
};
