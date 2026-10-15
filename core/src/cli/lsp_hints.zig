//! The editor's parameter hints (textDocument/inlayHint), kept apart from the LSP types so
//! they can be tested: before each positional argument of a built-in's call, the name its
//! Signature gives it. A method's are shown where the script shows its receiver is a solid
//! or a sketch, since a class of the script may have a `translate` of its own.

const std = @import("std");
const ast = @import("../core/ast.zig");
const Document = @import("../core/document.zig").Document;
const visitor = @import("../core/visitor.zig");
const token_span = @import("../core/token_span.zig");
const manifest = @import("../stdlib/manifest.zig");
const Signature = @import("../stdlib/signature.zig").Signature;
const Shapes = @import("../tools/lint/shapes.zig").Shapes;

pub const Hint = struct {
    /// Where the argument starts in the source.
    offset: u32,
    name: []const u8,
};

/// The parameter hints for `doc`'s calls, in source order, allocated in `arena`.
pub fn parameterHints(arena: std.mem.Allocator, doc: *const Document) ![]Hint {
    var walker = Walker{ .arena = arena, .doc = doc };
    try visitor.walk(Walker, &walker, &doc.tree, doc.tree.root);
    // The walk meets an outer call before the calls in its receiver (`square(4).extrude(10)`).
    std.sort.pdq(Hint, walker.hints.items, {}, before);
    return walker.hints.toOwnedSlice(arena);
}

fn before(_: void, a: Hint, b: Hint) bool {
    return a.offset < b.offset;
}

const Walker = struct {
    arena: std.mem.Allocator,
    doc: *const Document,
    shapes: Shapes = .{},
    hints: std.ArrayListUnmanaged(Hint) = .empty,

    pub fn enterNode(self: *Walker, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx) orelse return;
        try self.shapes.observe(self.arena, tree, node);
        if (node.tag != .method_call) return;
        const call = tree.methodCall(node);
        const signature = self.signatureOf(tree, call) orelse return;

        var positional: std.ArrayListUnmanaged(ast.NodeIndex) = .empty;
        for (tree.getNamedArgs(call.args)) |arg| {
            if (arg.name != .none) continue;
            // After a splat (`cube(*dims)`) the positions are unknown.
            if (arg.modifier != null) return;
            try positional.append(self.arena, arg.value);
        }
        const lone = if (positional.items.len == 1) signature.single else null;
        for (positional.items, 0..) |value, i| {
            const name = lone orelse if (i < signature.positional.len) signature.positional[i] else break;
            if (isNamed(tree, value, name)) continue; // `cube(x)` needs no `x:`
            try self.hints.append(self.arena, .{ .offset = self.doc.tokens.starts[token_span.first(tree, value)], .name = name });
        }
    }

    /// The built-in a call surely is: a primitive, or a method of a known solid or sketch.
    fn signatureOf(self: *const Walker, tree: *const ast.Tree, call: ast.MethodCall) ?*const Signature {
        const name = tree.getString(call.method_name);
        if (call.receiver == .none) return manifest.signatureOf(name);
        _ = self.shapes.of(tree, call.receiver) orelse return null;
        return manifest.methodSignatureOf(name);
    }

    fn isNamed(tree: *const ast.Tree, idx: ast.NodeIndex, name: []const u8) bool {
        const node = tree.getNode(idx) orelse return false;
        if (node.tag != .identifier) return false;
        return std.mem.eql(u8, tree.getString(@as(ast.StringId, @fromBackingInt(node.data))), name);
    }
};
