const std = @import("std");
const api = @import("../api.zig");
const ast = @import("ast.zig");

pub fn dump(allocator: std.mem.Allocator, doc: *const api.Document, out: *std.Io.Writer.Allocating) !void {
    try dumpNode(allocator, doc, doc.tree.root, out, "", true);
}

fn dumpNode(
    allocator: std.mem.Allocator,
    doc: *const api.Document,
    node_idx: ast.NodeIndex,
    out: *std.Io.Writer.Allocating,
    prefix: []const u8,
    is_last: bool,
) !void {
    if (node_idx == .none) return;
    const tree = &doc.tree;
    const node = tree.getNode(node_idx) orelse return;

    // Draw the tree lines
    const branch = if (is_last) "└── " else "├── ";
    out.writer.print("{s}{s}{s}", .{ prefix, branch, @tagName(node.tag) }) catch return error.OutOfMemory;

    // Extract and print specific Node payloads
    switch (node.tag) {
        .identifier, .symbol, .string => {
            out.writer.print(" '{s}'", .{tree.getString(@as(ast.StringId, @enumFromInt(node.data)))}) catch {};
        },
        .number => {
            out.writer.print(" {d}", .{tree.number(node)}) catch {};
        },
        .assignment => {
            out.writer.print(" '{s}'", .{tree.getString(tree.assignment(node).name)}) catch {};
        },
        .method_call => {
            out.writer.print(" '{s}'", .{tree.getString(tree.methodCall(node).method_name)}) catch {};
        },
        .def_stmt => {
            out.writer.print(" '{s}'", .{tree.getString(tree.defStmt(node).name)}) catch {};
        },
        .binary_op => {
            out.writer.print(" '{s}'", .{@tagName(tree.binaryExpr(node).op)}) catch {};
        },
        .unary_op => {
            out.writer.print(" '{s}'", .{@tagName(tree.unaryExpr(node).op)}) catch {};
        },
        else => {},
    }

    // Print Semantic Resolver Scope data (if available)
    const sym = doc.symbols[@intFromEnum(node_idx)];
    if (sym.kind != .unresolved) {
        out.writer.print(" (symbol: {s} slot {d})", .{ @tagName(sym.kind), sym.index }) catch {};
    }

    // Upvalue closures (Lambda/Def)
    if (doc.closure_captures.get(node_idx)) |captures| {
        out.writer.print(" [captures: {d}]", .{captures.len}) catch {};
    }

    out.writer.print("\n", .{}) catch {};

    // Calculate indentation for children
    const next_prefix_chunk = if (is_last) "    " else "│   ";
    const next_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, next_prefix_chunk });
    defer allocator.free(next_prefix);

    // Gather children dynamically based on AST Tag
    var children = std.ArrayListUnmanaged(ast.NodeIndex).empty;
    defer children.deinit(allocator);

    switch (node.tag) {
        .block => {
            const b = tree.block(node);
            try children.appendSlice(allocator, tree.getNodes(b.params));
            try children.appendSlice(allocator, tree.getNodes(b.stmts));
        },
        .assignment => {
            try children.append(allocator, tree.assignment(node).value);
        },
        .binary_op => {
            const b = tree.binaryExpr(node);
            try children.append(allocator, b.left);
            try children.append(allocator, b.right);
        },
        .unary_op => {
            try children.append(allocator, tree.unaryExpr(node).operand);
        },
        .method_call => {
            const mc = tree.methodCall(node);
            if (mc.receiver != .none) try children.append(allocator, mc.receiver);
            for (tree.getNamedArgs(mc.args)) |arg| {
                try children.append(allocator, arg.value);
            }
            if (mc.block != .none) try children.append(allocator, mc.block);
        },
        .def_stmt => {
            const ds = tree.defStmt(node);
            try children.append(allocator, ds.body);
        },
        .if_stmt => {
            const ifs = tree.ifStmt(node);
            try children.append(allocator, ifs.condition);
            try children.append(allocator, ifs.then_branch);
            if (ifs.else_branch != .none) try children.append(allocator, ifs.else_branch);
        },
        .while_stmt => {
            const ws = tree.whileStmt(node);
            try children.append(allocator, ws.condition);
            try children.append(allocator, ws.body);
        },
        .array_literal, .interpolated_string => {
            try children.appendSlice(allocator, tree.getNodes(tree.nodeSpan(node)));
        },
        else => {}, // No children, or unhandled in quick-dump
    }

    // Recursively dump children
    for (children.items, 0..) |child, i| {
        try dumpNode(allocator, doc, child, out, next_prefix, i == children.items.len - 1);
    }
}
