//! The tokens a subtree spans, for the byte range of a whole statement: where the
//! formatter keeps a trailing comment, what a lint fix deletes.

const std = @import("std");
const ast = @import("ast.zig");
const visitor = @import("visitor.zig");

/// The smallest token the subtree mentions: every node records its main token, and a
/// statement's leftmost node (a call's receiver, an assignment's name) has the first one.
pub fn first(tree: *const ast.Tree, node_idx: ast.NodeIndex) u32 {
    var walker: First = .{};
    visitor.walk(First, &walker, tree, node_idx) catch {};
    return walker.token;
}

/// The largest token the subtree mentions: every node's main token, and the closing token
/// of the nodes that record one (`)`, `]`, `end`, `}`).
pub fn last(tree: *const ast.Tree, node_idx: ast.NodeIndex) u32 {
    var walker: Last = .{};
    visitor.walk(Last, &walker, tree, node_idx) catch {};
    return walker.token;
}

const First = struct {
    token: u32 = std.math.maxInt(u32),

    pub fn enterNode(self: *First, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        self.token = @min(self.token, tree.getNode(node_idx).?.main_token);
    }
};

const Last = struct {
    token: u32 = 0,

    pub fn enterNode(self: *Last, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;
        const end: u32 = switch (node.tag) {
            .method_call => tree.methodCall(node).end_token,
            .if_stmt => tree.ifStmt(node).end_token,
            .def_stmt => tree.defStmt(node).end_token,
            .class_stmt => tree.classStmt(node).end_token,
            .module_stmt => tree.moduleStmt(node).end_token,
            .block => tree.block(node).end_token,
            .array_literal => tree.arrayLiteral(node).end_token,
            .hash_literal => tree.hashEndToken(node),
            else => 0,
        };
        self.token = @max(self.token, node.main_token, end);
    }
};
