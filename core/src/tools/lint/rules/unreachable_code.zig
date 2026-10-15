const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

/// Flags the first statement of a body that can't run because a statement before it always
/// leaves: it returns, breaks, nexts or raises on every path through it, an `if` whose
/// branches all do, a `case` with an `else`, or a `begin` whose body and rescues all do.
pub const UnreachableCodeRule = struct {
    pub const id = "unreachable-code";
    pub const description = "Statements after one that always returns, breaks, nexts or raises";

    pub fn rule(self: *@This()) LintRule {
        return .{
            .id = id,
            .ptr = self,
            .vtable = &.{
                .checkNode = checkNode,
            },
        };
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;
        if (node.tag != .block) return;

        const stmts = tree.getNodes(tree.block(node).stmts);
        for (stmts, 0..) |stmt, i| {
            if (!alwaysLeaves(tree, stmt) or i + 1 == stmts.len) continue;
            const first_dead = tree.getNode(stmts[i + 1]).?;
            try engine.report(id, engine.getLoc(first_dead.main_token), "Unreachable: the statement before this always returns, breaks, nexts or raises", .{});
            return; // the rest of the body is dead too; one finding says so
        }
    }

    /// Whether control never passes `idx`. A `return` inside a block leaves only the block
    /// (KupCAD's difference from Ruby), so a call with a block never counts.
    pub fn alwaysLeaves(tree: *const ast.Tree, idx: ast.NodeIndex) bool {
        const node = tree.getNode(idx) orelse return false;
        return switch (node.tag) {
            .return_stmt, .break_stmt, .next_stmt => true,
            .method_call => isRaise(tree, node),
            .block => blockLeaves(tree, idx),
            .if_stmt => blk: {
                const s = tree.ifStmt(node);
                break :blk s.else_branch != .none and alwaysLeaves(tree, s.then_branch) and alwaysLeaves(tree, s.else_branch);
            },
            .case_stmt => blk: {
                const s = tree.caseStmt(node);
                if (s.else_branch == .none or !alwaysLeaves(tree, s.else_branch)) break :blk false;
                for (tree.getWhenBranches(s.when_branches)) |when| {
                    if (!alwaysLeaves(tree, when.body)) break :blk false;
                }
                break :blk true;
            },
            .begin_stmt => blk: {
                const s = tree.beginStmt(node);
                if (s.ensure_body != .none and alwaysLeaves(tree, s.ensure_body)) break :blk true;
                if (!alwaysLeaves(tree, s.body)) break :blk false;
                for (tree.getRescueClauses(s.rescues)) |rescue| {
                    if (!alwaysLeaves(tree, rescue.body)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn blockLeaves(tree: *const ast.Tree, idx: ast.NodeIndex) bool {
        const node = tree.getNode(idx) orelse return false;
        for (tree.getNodes(tree.block(node).stmts)) |stmt| {
            if (alwaysLeaves(tree, stmt)) return true;
        }
        return false;
    }

    /// `raise ...`, the built-in (it can't be redefined).
    fn isRaise(tree: *const ast.Tree, node: *const ast.Node) bool {
        const call = tree.methodCall(node);
        return call.receiver == .none and std.mem.eql(u8, tree.getString(call.method_name), "raise");
    }
};
