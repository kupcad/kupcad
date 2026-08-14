const std = @import("std");
const ast = @import("ast.zig");

/// A centralized AST Walker that guarantees all children of all nodes are visited sequentially.
/// To use this, create a context struct with optional `enterNode` and/or `leaveNode` methods.
pub fn walk(comptime Context: type, ctx: *Context, tree: *const ast.Tree, node_idx: ast.NodeIndex) anyerror!void {
    if (node_idx == .none) return;
    const node = tree.getNode(node_idx) orelse return;

    if (comptime std.meta.hasFn(Context, "enterNode")) {
        try ctx.enterNode(tree, node_idx);
    }

    switch (node.tag) {
        // Leaf nodes (0 children)
        .invalid, .number, .string, .boolean, .identifier, .symbol, .nil, .undef, .self_expr, .namespace_access, .defined_expr => {},

        // Multi-child nodes
        .interpolated_string, .array_literal, .yield_stmt => {
            for (tree.getNodes(tree.nodeSpan(node))) |child| try walk(Context, ctx, tree, child);
        },
        .hash_literal => {
            for (tree.getHashEntries(tree.nodeSpan(node))) |entry| {
                try walk(Context, ctx, tree, entry.key);
                try walk(Context, ctx, tree, entry.value);
            }
        },
        .assignment => try walk(Context, ctx, tree, tree.assignment(node).value),
        .multiple_assignment => try walk(Context, ctx, tree, tree.multipleAssignment(node).value),
        .property_assignment => {
            const pa = tree.propertyAssignment(node);
            try walk(Context, ctx, tree, pa.target);
            try walk(Context, ctx, tree, pa.value);
        },
        .index_assignment => {
            const ia = tree.indexAssignment(node);
            try walk(Context, ctx, tree, ia.target);
            try walk(Context, ctx, tree, ia.index);
            try walk(Context, ctx, tree, ia.value);
        },
        .binary_op => {
            const bin = tree.binaryExpr(node);
            try walk(Context, ctx, tree, bin.left);
            try walk(Context, ctx, tree, bin.right);
        },
        .unary_op => try walk(Context, ctx, tree, tree.unaryExpr(node).operand),
        .ternary_op => {
            const tern = tree.ternaryExpr(node);
            try walk(Context, ctx, tree, tern.condition);
            try walk(Context, ctx, tree, tern.then_branch);
            try walk(Context, ctx, tree, tern.else_branch);
        },
        .method_call => {
            const mc = tree.methodCall(node);
            try walk(Context, ctx, tree, mc.receiver);
            for (tree.getNamedArgs(mc.args)) |arg| try walk(Context, ctx, tree, arg.value);
            try walk(Context, ctx, tree, mc.block);
        },
        .super_call => {
            const sc = tree.superCall(node);
            for (tree.getNamedArgs(sc.args)) |arg| try walk(Context, ctx, tree, arg.value);
            try walk(Context, ctx, tree, sc.block);
        },
        .lambda_expr => {
            const le = tree.lambdaExpr(node);
            for (tree.getParams(le.params)) |param| try walk(Context, ctx, tree, param.default_value);
            try walk(Context, ctx, tree, le.body);
        },
        .import_stmt => try walk(Context, ctx, tree, tree.importStmt(node).attributes),
        .export_stmt => try walk(Context, ctx, tree, tree.exportStmt(node).attributes),
        .if_stmt => {
            const ifs = tree.ifStmt(node);
            try walk(Context, ctx, tree, ifs.condition);
            try walk(Context, ctx, tree, ifs.then_branch);
            try walk(Context, ctx, tree, ifs.else_branch);
        },
        .while_stmt => {
            const ws = tree.whileStmt(node);
            try walk(Context, ctx, tree, ws.condition);
            try walk(Context, ctx, tree, ws.body);
        },
        .for_stmt => {
            const fs = tree.forStmt(node);
            for (tree.getForBindings(fs.bindings)) |binding| try walk(Context, ctx, tree, binding.range);
            try walk(Context, ctx, tree, fs.body);
        },
        .case_stmt => {
            const cs = tree.caseStmt(node);
            try walk(Context, ctx, tree, cs.condition);
            for (tree.getWhenBranches(cs.when_branches)) |wb| {
                for (tree.getNodes(wb.conditions)) |cond| try walk(Context, ctx, tree, cond);
                try walk(Context, ctx, tree, wb.body);
            }
            try walk(Context, ctx, tree, cs.else_branch);
        },
        .def_stmt => {
            const ds = tree.defStmt(node);
            for (tree.getParams(ds.params)) |param| try walk(Context, ctx, tree, param.default_value);
            try walk(Context, ctx, tree, ds.body);
        },
        .class_stmt => {
            const cs = tree.classStmt(node);
            try walk(Context, ctx, tree, cs.name);
            try walk(Context, ctx, tree, cs.super_class);
            try walk(Context, ctx, tree, cs.body);
        },
        .module_stmt => {
            const ms = tree.moduleStmt(node);
            for (tree.getParams(ms.params)) |param| try walk(Context, ctx, tree, param.default_value);
            try walk(Context, ctx, tree, ms.body);
        },
        .begin_stmt => {
            const bs = tree.beginStmt(node);
            try walk(Context, ctx, tree, bs.body);
            for (tree.getRescueClauses(bs.rescues)) |rc| try walk(Context, ctx, tree, rc.body);
            try walk(Context, ctx, tree, bs.ensure_body);
        },
        .block => {
            for (tree.getNodes(tree.block(node).stmts)) |stmt| try walk(Context, ctx, tree, stmt);
        },
        .range => {
            const r = tree.range(node);
            try walk(Context, ctx, tree, r.start);
            try walk(Context, ctx, tree, r.end);
            try walk(Context, ctx, tree, r.step);
        },
        .index_access => {
            const ia = tree.indexAccess(node);
            try walk(Context, ctx, tree, ia.target);
            try walk(Context, ctx, tree, ia.index);
        },
        .rescue_modifier => {
            const rm = tree.rescueModifier(node);
            try walk(Context, ctx, tree, rm.expr);
            try walk(Context, ctx, tree, rm.rescue_expr);
        },
        .splat_expr, .double_splat_expr, .each_expr, .return_stmt, .break_stmt, .next_stmt => {
            try walk(Context, ctx, tree, tree.nodeIndex(node));
        },
        .param_doc => try walk(Context, ctx, tree, tree.paramDoc(node).options_expr),
    }

    if (comptime std.meta.hasFn(Context, "leaveNode")) {
        try ctx.leaveNode(tree, node_idx);
    }
}
