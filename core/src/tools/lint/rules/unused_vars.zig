const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const UnusedVarsRule = struct {
    pub const id = "unused-variable";
    pub const description = "A variable assigned and never read";

    pub fn rule(self: *@This()) LintRule {
        return .{
            .id = id,
            .ptr = self,
            .vtable = &.{
                .checkNode = checkNode,
                .enterScope = enterScope,
                .exitScope = exitScope,
            },
        };
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;

        switch (node.tag) {
            .assignment => {
                const a = tree.assignment(node);
                const var_name = tree.getString(a.name);
                // `n += 1` reads n as well as writing it.
                if (a.op != null) try engine.markUsed(var_name) else try engine.declareAssigned(var_name, engine.getLoc(node.main_token));
            },
            .multiple_assignment => {
                const ma = tree.multipleAssignment(node);
                for (tree.getLhsExprs(ma.lhs)) |lhs| {
                    const var_name = tree.getString(lhs.name);
                    if (ma.op != null) try engine.markUsed(var_name) else try engine.declareAssigned(var_name, engine.getLoc(node.main_token));
                }
            },
            .for_stmt => {
                // The loop opens no scope: its variables belong to the enclosing one.
                const fs = tree.forStmt(node);
                for (tree.getLhsExprs(fs.targets)) |t| {
                    try engine.declareAssigned(tree.getString(t.name), engine.getLoc(node.main_token));
                }
            },
            .export_stmt => {
                for (tree.getAliasPairs(tree.exportStmt(node).symbols)) |pair| {
                    try engine.markUsed(tree.getString(pair.original));
                }
            },
            .def_stmt => {
                const ds = tree.defStmt(node);
                // Function names belong to the scope they are declared in
                try engine.declareVar(tree.getString(ds.name), engine.getLoc(node.main_token));
                try markResultUsed(engine, tree, ds.body);
            },
            .lambda_expr => try markResultUsed(engine, tree, tree.lambdaExpr(node).body),
            .block => {
                // The script's last statement is the model, and a call block's is its value.
                if (node_idx == engine.root or engine.closure_blocks.contains(node_idx)) try markResultUsed(engine, tree, node_idx);
            },
            .identifier => {
                try engine.markUsed(tree.getString(@as(ast.StringId, @fromBackingInt(node.data))));
            },
            .method_call => {
                const mc = tree.methodCall(node);
                try engine.markUsed(tree.getString(mc.method_name));
            },
            else => {},
        }
    }

    /// A body whose last statement is `name = value` hands that value back (the script's
    /// model, a method's or a block's result), so `name` is used: `part = box - drill` at
    /// the end of a script was reported unused.
    fn markResultUsed(engine: *linter.Linter, tree: *const ast.Tree, body_idx: ast.NodeIndex) !void {
        const body = tree.getNode(body_idx) orelse return;
        if (body.tag != .block) return;
        const stmts = tree.getNodes(tree.block(body).stmts);
        if (stmts.len == 0) return;
        const last = tree.getNode(stmts[stmts.len - 1]).?;
        if (last.tag != .assignment) return;
        const var_name = tree.getString(tree.assignment(last).name);
        try engine.declareAssigned(var_name, engine.getLoc(last.main_token));
        try engine.markUsed(var_name);
    }

    fn declareLhsBindings(engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        if (node_idx == .none) return;
        const node = tree.getNode(node_idx) orelse return;

        switch (node.tag) {
            .identifier => {
                try engine.declareVar(tree.getString(@as(ast.StringId, @fromBackingInt(node.data))), engine.getLoc(node.main_token));
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
                try engine.report(id, loc, "Unused variable '{s}'. Prefix with '_' if intentional.", .{var_name});
            }
        }
    }
};
