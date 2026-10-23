//! The editor's inlay hints (textDocument/inlayHint), kept apart from the LSP types so they
//! can be tested: before each positional argument of a built-in's call, the name its
//! Signature gives it, and after a variable assigned a built-in's result, that result's
//! class (stdlib/manifest.zig). A method's are shown where the script shows its receiver
//! is a solid or a sketch, since a class of the script may have a `translate` of its own.

const std = @import("std");
const ast = @import("../core/ast.zig");
const Document = @import("../frontend/document.zig").Document;
const visitor = @import("../core/visitor.zig");
const token_span = @import("../core/token_span.zig");
const manifest = @import("../stdlib/manifest.zig");
const Signature = @import("../stdlib/signature.zig").Signature;
const shapes_mod = @import("../tools/lint/shapes.zig");
const Shapes = shapes_mod.Shapes;

pub const Hint = struct {
    /// Where it goes in the source: the start of the argument, or the end of the variable.
    offset: u32,
    /// The parameter's name, or the class's.
    name: []const u8,
    kind: enum { parameter, type },
};

/// The inlay hints for `doc`, in source order, allocated in `arena`.
pub fn hints(arena: std.mem.Allocator, doc: *const Document) ![]Hint {
    var walker = Walker{ .arena = arena, .doc = doc };
    try visitor.walk(Walker, &walker, &doc.tree, doc.tree.root);
    // The walk meets an outer call before the calls in its receiver (`square(4).extrude(10)`).
    std.sort.pdq(Hint, walker.found.items, {}, before);
    return walker.found.toOwnedSlice(arena);
}

fn before(_: void, a: Hint, b: Hint) bool {
    return a.offset < b.offset;
}

const Walker = struct {
    arena: std.mem.Allocator,
    doc: *const Document,
    shapes: Shapes = .{},
    found: std.ArrayList(Hint) = .empty,

    pub fn enterNode(self: *Walker, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx) orelse return;
        // Before the assignment is recorded: `a = a.translate(1)` is typed by the old `a`.
        if (node.tag == .assignment) try self.typeHint(tree, node);
        try self.shapes.observe(self.arena, tree, node);
        if (node.tag != .method_call) return;
        const call = tree.methodCall(node);
        const signature = self.signatureOf(tree, call) orelse return;

        var positional: std.ArrayList(ast.NodeIndex) = .empty;
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
            try self.found.append(self.arena, .{ .offset = self.doc.tokens.starts[token_span.first(tree, value)], .name = name, .kind = .parameter });
        }
    }

    /// `part = cube(1)` gets `: Geometry` after `part`, when the call is a built-in whose
    /// result's class is known.
    fn typeHint(self: *Walker, tree: *const ast.Tree, node: *const ast.Node) !void {
        const assignment = tree.assignment(node);
        if (assignment.op != null) return;
        const value = tree.getNode(assignment.value) orelse return;
        if (value.tag != .method_call) return;
        const call = tree.methodCall(value);
        const name = tree.getString(call.method_name);
        const result = if (call.receiver == .none) shapes_mod.globalResult(tree, call) orelse return else blk: {
            const receiver = self.shapes.of(tree, call.receiver) orelse return;
            const result = manifest.methodResultOf(name) orelse return;
            if (result == .receiver) break :blk if (receiver == .solid) manifest.Result.solid else manifest.Result.sketch;
            break :blk result;
        };
        if (result == .nothing) return; // nothing worth saying
        const class = result.className() orelse return;
        const tok = node.main_token;
        try self.found.append(self.arena, .{ .offset = self.doc.tokens.starts[tok] + self.doc.tokens.lengths[tok], .name = class, .kind = .type });
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
        return std.mem.eql(u8, tree.nodeString(node), name);
    }
};
