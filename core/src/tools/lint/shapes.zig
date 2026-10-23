//! Which expressions of a script are solids, sketches or paths, as far as it says before it runs:
//! a primitive, a variable last assigned one, a method that keeps or makes one, a boolean of
//! them. A rule feeds it the script's assignments in order (`observe`) and asks `of`.

const std = @import("std");
const ast = @import("../../core/ast.zig");
const manifest = @import("../../stdlib/manifest.zig");

pub const Shape = enum {
    solid,
    sketch,
    path,

    /// The class a script sees the shape as.
    pub fn className(self: Shape) []const u8 {
        return switch (self) {
            .solid => "Solid",
            .sketch => "Sketch",
            .path => "Path",
        };
    }

    /// Which shapes' methods, as the manifest binds them.
    pub fn on(self: Shape) manifest.On {
        return switch (self) {
            .solid => .solids,
            .sketch => .sketches,
            .path => .paths,
        };
    }
};

pub const Shapes = struct {
    /// Variables known to hold a solid or a sketch (the last assignment seen).
    vars: std.StringHashMapUnmanaged(Shape) = .empty,

    pub fn deinit(self: *Shapes, allocator: std.mem.Allocator) void {
        self.vars.deinit(allocator);
        self.* = .{};
    }

    /// Records what an assignment at `node` makes its variable; any other node is ignored.
    pub fn observe(self: *Shapes, allocator: std.mem.Allocator, tree: *const ast.Tree, node: *const ast.Node) !void {
        if (node.tag != .assignment) return;
        const a = tree.assignment(node);
        if (a.op != null) return;
        const name = tree.getString(a.name);
        if (self.of(tree, a.value)) |shape| try self.vars.put(allocator, name, shape) else _ = self.vars.remove(name);
    }

    /// Whether the expression at `idx` is a solid or a sketch, if the script says.
    pub fn of(self: *const Shapes, tree: *const ast.Tree, idx: ast.NodeIndex) ?Shape {
        const node = tree.getNode(idx) orelse return null;
        return switch (node.tag) {
            .identifier => self.vars.get(tree.nodeString(node)),
            .binary_op => blk: {
                const b = tree.binaryExpr(node);
                break :blk switch (b.op) {
                    .add, .subtract, .bitwise_and => self.of(tree, b.left) orelse self.of(tree, b.right),
                    else => null,
                };
            },
            .method_call => blk: {
                // What each built-in gives back comes from the manifest (it was three lists
                // kept here by hand); a method of a shape that isn't a built-in is unknown.
                const call = tree.methodCall(node);
                const name = tree.getString(call.method_name);
                if (call.receiver == .none) break :blk shapeOf(manifest.resultOf(name) orelse break :blk null, null);
                const receiver = self.of(tree, call.receiver) orelse break :blk null;
                break :blk shapeOf(manifest.methodResultOf(name) orelse break :blk null, receiver);
            },
            else => null,
        };
    }

    fn shapeOf(result: manifest.Result, receiver: ?Shape) ?Shape {
        return switch (result) {
            .receiver => receiver,
            .solid => .solid,
            .sketch => .sketch,
            .path => .path,
            else => null,
        };
    }
};
