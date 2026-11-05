//! `dump`: prints a parsed document's AST, a node per line indented by its depth, each node's
//! tag with its payload and, for a name, what the resolver made of it, for
//! `kupcad dev ast-dump` (cli/dev.zig). It walks the tree as every pass does (core/visitor.zig):
//! with a list of children of its own, it left out a lambda's body, a map's entries, and the
//! insides of classes, cases, loops, begins, indexing and ternaries.

const std = @import("std");
const Document = @import("../../frontend/document.zig").Document;
const ast = @import("../../core/ast.zig");
const visitor = @import("../../core/visitor.zig");

/// How far a node's line is indented for each level of depth.
const INDENT = 2;

pub fn dump(doc: *const Document, out: *std.Io.Writer) !void {
    var dumper: Dumper = .{ .doc = doc, .out = out };
    try visitor.walk(Dumper, &dumper, &doc.tree, doc.tree.root);
}

const Dumper = struct {
    doc: *const Document,
    out: *std.Io.Writer,
    depth: usize = 0,

    pub fn enterNode(self: *Dumper, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;
        try self.out.splatByteAll(' ', INDENT * self.depth);
        try self.out.writeAll(@tagName(node.tag));
        switch (node.tag) {
            .identifier, .string, .symbol => try self.out.print(" '{s}'", .{tree.nodeString(node)}),
            .number => try self.out.print(" {d}", .{tree.number(node)}),
            .assignment => try self.out.print(" '{s}'", .{tree.getString(tree.assignment(node).name)}),
            .property_assignment => try self.out.print(" '{s}'", .{tree.getString(tree.propertyAssignment(node).property)}),
            .method_call => try self.out.print(" '{s}'", .{tree.getString(tree.methodCall(node).method_name)}),
            .def_stmt => {
                const def = tree.defStmt(node);
                try self.out.print(" '{s}'", .{tree.getString(def.name)});
                try self.params(tree, def.params);
            },
            .lambda_expr => try self.params(tree, tree.lambdaExpr(node).params),
            .block => try self.params(tree, tree.block(node).params),
            .module_stmt => try self.out.print(" '{s}'", .{tree.getString(tree.moduleStmt(node).name)}),
            .binary_op => try self.out.print(" '{s}'", .{@tagName(tree.binaryExpr(node).op)}),
            .unary_op => try self.out.print(" '{s}'", .{@tagName(tree.unaryExpr(node).op)}),
            else => {},
        }
        const kind = self.doc.symbols[@backingInt(node_idx)];
        if (kind != .unresolved) try self.out.print(" (symbol: {s})", .{@tagName(kind)});
        try self.out.writeByte('\n');
        self.depth += 1;
    }

    pub fn leaveNode(self: *Dumper, _: *const ast.Tree, _: ast.NodeIndex) !void {
        self.depth -= 1;
    }

    /// ` |a, *rest, (x, y)|`, the parameters a def, lambda or block binds (their defaults are
    /// the nodes below it); nothing when it has none.
    fn params(self: *Dumper, tree: *const ast.Tree, span: ast.Span) !void {
        if (span.isEmpty()) return;
        try self.out.writeAll(" |");
        try self.paramList(tree, span);
        try self.out.writeByte('|');
    }

    fn paramList(self: *Dumper, tree: *const ast.Tree, span: ast.Span) !void {
        for (tree.getParams(span), 0..) |param, i| {
            if (i > 0) try self.out.writeAll(", ");
            if (!param.pattern.isEmpty()) {
                try self.out.writeByte('(');
                try self.paramList(tree, param.pattern);
                try self.out.writeByte(')');
                continue;
            }
            if (param.modifier) |modifier| try self.out.writeAll(switch (modifier) {
                .splat => "*",
                .double_splat => "**",
                .block => "&",
            });
            try self.out.writeAll(tree.getString(param.name));
            if (param.is_keyword) try self.out.writeByte(':');
        }
    }
};
