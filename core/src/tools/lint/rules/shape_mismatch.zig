//! The `shape-mismatch` lint rule: a method, or an operator, used on a kind of shape that
//! doesn't have it (`hook.extrude(3)` on a Path, `plate - hook`, `square(2).volume`), which
//! fails when the script runs.

const std = @import("std");
const ast = @import("../../../core/ast.zig");
const manifest = @import("../../../stdlib/manifest.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;
const shapes_mod = @import("../shapes.zig");
const Shapes = shapes_mod.Shapes;
const Shape = shapes_mod.Shape;

/// Flags a shape method called on a shape the script shows to be of a kind that doesn't
/// have it, and `+`, `-` and `&` between a Path and another shape (a Path joins another
/// Path with `+`, and that is all): each is an error when the script runs. The kinds come
/// from the manifest, as the VM binds them; a method of the script's own on an object of
/// its own is never reported, since the receiver's kind is unknown then.
pub const ShapeMismatchRule = struct {
    pub const id = "shape-mismatch";
    pub const description = "A method or operator used on a kind of shape that doesn't have it, such as extrude on a Path";

    shapes: Shapes = .{},

    pub fn rule(self: *@This()) LintRule {
        return .{
            .id = id,
            .ptr = self,
            .vtable = &.{
                .checkNode = checkNode,
                .deinit = deinit,
            },
        };
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ShapeMismatchRule = @ptrCast(@alignCast(ptr));
        self.shapes.deinit(allocator);
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const self: *ShapeMismatchRule = @ptrCast(@alignCast(ptr));
        const node = tree.getNode(node_idx) orelse return;
        try self.shapes.observe(engine.allocator, tree, node);
        switch (node.tag) {
            .method_call => {
                const call = tree.methodCall(node);
                if (call.receiver == .none) return;
                const shape = self.shapes.of(tree, call.receiver) orelse return;
                const name = tree.getString(call.method_name);
                const allowed = manifest.methodAllows(name, shape.on()) orelse return;
                if (allowed) return;
                const loc = engine.getLoc(node.main_token);
                if (manifest.missingMethodHint(shape.className(), name)) |hint| {
                    try engine.report(id, loc, "{s} isn't a {s}'s method: {s}", .{ name, shape.className(), hint });
                } else {
                    try engine.report(id, loc, "{s} isn't a {s}'s method ({s}), so this fails when the script runs", .{ name, shape.className(), owners(name) });
                }
            },
            .binary_op => {
                const b = tree.binaryExpr(node);
                const op = switch (b.op) {
                    .add => "+",
                    .subtract => "-",
                    .bitwise_and => "&",
                    else => return,
                };
                const left = self.shapes.of(tree, b.left) orelse return;
                const right = self.shapes.of(tree, b.right) orelse return;
                if (left != .path and right != .path) return;
                const loc = engine.getLoc(node.main_token);
                if (left == .path and right == .path) {
                    if (b.op == .add) return; // a join
                    try engine.report(id, loc, "'{s}' can't combine two Paths: '+' joins them where one ends and the next starts", .{op});
                } else {
                    const other = if (left == .path) right else left;
                    try engine.report(id, loc, "'{s}' can't combine a Path and a {s}: {s}", .{ op, other.className(), manifest.OPEN_PATH_HINT });
                }
            },
            else => {},
        }
    }

    /// Whose method `name` is, for the message: "a Solid's", "a Solid's or a Sketch's".
    fn owners(name: []const u8) []const u8 {
        const solid = manifest.methodAllows(name, .solids) orelse false;
        const sketch = manifest.methodAllows(name, .sketches) orelse false;
        const path = manifest.methodAllows(name, .paths) orelse false;
        if (solid and sketch) return if (path) "a Solid's, a Sketch's or a Path's" else "a Solid's or a Sketch's";
        if (solid) return if (path) "a Solid's or a Path's" else "a Solid's";
        if (sketch) return if (path) "a Sketch's or a Path's" else "a Sketch's";
        return "a Path's";
    }
};
