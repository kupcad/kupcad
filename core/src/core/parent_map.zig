const std = @import("std");
const ast = @import("ast.zig");
const visitor = @import("visitor.zig");

pub const ParentMap = struct {
    allocator: std.mem.Allocator,

    // The flat, parallel array. Index = Child NodeIndex, Value = Parent NodeIndex.
    parents: []ast.NodeIndex,

    // Internal stack to track the current parent during traversal
    stack: std.ArrayListUnmanaged(ast.NodeIndex) = .empty,

    pub fn init(allocator: std.mem.Allocator, tree: *const ast.Tree) !ParentMap {
        const parents = try allocator.alloc(ast.NodeIndex, tree.nodes.items.len);

        // Default everything to .none (the root node has no parent)
        @memset(parents, .none);

        return ParentMap{
            .allocator = allocator,
            .parents = parents,
        };
    }

    pub fn deinit(self: *ParentMap) void {
        self.stack.deinit(self.allocator);
        self.allocator.free(self.parents);
    }

    pub fn build(self: *ParentMap, tree: *const ast.Tree, start_node: ast.NodeIndex) !void {
        if (start_node == .none) return;
        var ctx = BuilderContext{ .map = self };
        try visitor.walk(BuilderContext, &ctx, tree, start_node);
    }
};

const BuilderContext = struct {
    map: *ParentMap,

    pub fn enterNode(self: *BuilderContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = tree;
        // If there is a parent on the stack, record it as this node's parent
        if (self.map.stack.items.len > 0) {
            const parent_idx = self.map.stack.items[self.map.stack.items.len - 1];
            self.map.parents[@intFromEnum(node_idx)] = parent_idx;
        }

        // Push this node onto the stack so it becomes the parent for its children
        try self.map.stack.append(self.map.allocator, node_idx);
    }

    pub fn leaveNode(self: *BuilderContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = tree;
        _ = node_idx;
        // Pop this node off the stack as we leave it
        _ = self.map.stack.pop();
    }
};
