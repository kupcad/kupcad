//! Whether two syntax trees describe the same program. A pre-order walk of each yields
//! one fingerprint per node: its tag and whatever else changes the program's meaning
//! (names, operators, literal values, flags). Positions and layout are left out, so
//! `(a * b) + c` and `a * b + c` match while `(a + b) * c` and `a + b * c` don't.
//!
//! The formatter checks its output with this before handing it back, as black and
//! rustfmt do: a formatter bug then fails loudly instead of rewriting someone's model.

const std = @import("std");
const ast = @import("../../core/ast.zig");
const visitor = @import("../../core/visitor.zig");

/// One fingerprint per node, in pre-order. Caller frees.
pub fn fingerprints(allocator: std.mem.Allocator, tree: *const ast.Tree, root: ast.NodeIndex) ![]u64 {
    var ctx: Collector = .{ .allocator = allocator };
    errdefer ctx.prints.deinit(allocator);
    try visitor.walk(Collector, &ctx, tree, root);
    return ctx.prints.toOwnedSlice(allocator);
}

/// Whether `a` and `b` are the same program, up to the order of each run of top-level
/// imports, which the formatter sorts.
pub fn samePrograms(allocator: std.mem.Allocator, a: *const ast.Tree, b: *const ast.Tree) !bool {
    const stmts_a = try statementPrints(allocator, a);
    defer allocator.free(stmts_a);
    const stmts_b = try statementPrints(allocator, b);
    defer allocator.free(stmts_b);
    return std.mem.eql(u64, stmts_a, stmts_b);
}

/// One fingerprint per top-level statement (covering all of it), with each run of
/// consecutive imports sorted.
fn statementPrints(allocator: std.mem.Allocator, tree: *const ast.Tree) ![]u64 {
    const root = tree.getNode(tree.root) orelse return allocator.alloc(u64, 0);
    const stmts = tree.getNodes(tree.block(root).stmts);
    const out = try allocator.alloc(u64, stmts.len);
    errdefer allocator.free(out);
    for (stmts, out) |stmt, *print| {
        const prints = try fingerprints(allocator, tree, stmt);
        defer allocator.free(prints);
        print.* = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(prints));
    }
    var i: usize = 0;
    while (i < stmts.len) {
        var end = i;
        while (end < stmts.len and tree.getNode(stmts[end]).?.tag == .import_stmt) end += 1;
        std.mem.sort(u64, out[i..end], {}, std.sort.asc(u64));
        i = @max(end, i + 1);
    }
    return out;
}

const Collector = struct {
    allocator: std.mem.Allocator,
    prints: std.ArrayList(u64) = .empty,

    pub fn enterNode(self: *Collector, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;
        try self.prints.append(self.allocator, fingerprint(tree, node));
        // The walker skips a block's parameters, which are nodes too (`|a, b = 1|`).
        if (node.tag == .block) {
            for (tree.getNodes(tree.block(node).params)) |param| try visitor.walk(Collector, self, tree, param);
        }
    }
};

fn fingerprint(tree: *const ast.Tree, node: *const ast.Node) u64 {
    var h: Hasher = .{};
    h.add(node.tag);
    switch (node.tag) {
        .number => h.add(@as(u64, @bitCast(tree.number(node)))),
        .string, .identifier, .symbol => h.string(tree, @fromBackingInt(node.data)),
        .boolean => h.add(tree.boolean(node)),
        .binary_op => h.add(tree.binaryExpr(node).op),
        .unary_op => h.add(tree.unaryExpr(node).op),
        .method_call => {
            const mc = tree.methodCall(node);
            h.string(tree, mc.method_name);
            h.add(mc.is_safe);
            h.args(tree, mc.args);
        },
        .super_call => {
            const sc = tree.superCall(node);
            h.add(sc.implicit_args);
            h.args(tree, sc.args);
        },
        .assignment => {
            const a = tree.assignment(node);
            h.string(tree, a.name);
            h.add(a.op);
        },
        .multiple_assignment => {
            const ma = tree.multipleAssignment(node);
            h.add(ma.op);
            for (tree.getLhsExprs(ma.lhs)) |lhs| {
                h.string(tree, lhs.name);
                h.add(lhs.modifier);
            }
        },
        .property_assignment => {
            const pa = tree.propertyAssignment(node);
            h.string(tree, pa.property);
            h.add(pa.op);
        },
        .index_assignment => h.add(tree.indexAssignment(node).op),
        .def_stmt => {
            const ds = tree.defStmt(node);
            h.string(tree, ds.name);
            h.add(ds.is_class_method);
            h.add(ds.is_private);
            h.params(tree, ds.params);
        },
        .lambda_expr => h.params(tree, tree.lambdaExpr(node).params),
        .module_stmt => {
            const ms = tree.moduleStmt(node);
            h.string(tree, ms.name);
            h.params(tree, ms.params);
        },
        .range => h.add(tree.range(node).is_exclusive),
        .for_stmt => {
            const fs = tree.forStmt(node);
            for (tree.getLhsExprs(fs.targets)) |t| {
                h.string(tree, t.name);
                h.add(t.modifier);
            }
        },
        .if_stmt => h.add(tree.ifStmt(node).is_unless),
        .while_stmt => h.add(tree.whileStmt(node).is_until),
        .namespace_access => for (tree.getStringLists(tree.nodeSpan(node))) |s| h.string(tree, s),
        .block => h.add(tree.getNodes(tree.block(node).params).len),
        .begin_stmt => for (tree.getRescueClauses(tree.beginStmt(node).rescues)) |rc| {
            for (tree.getStringLists(rc.errors)) |e| h.string(tree, e);
            h.string(tree, rc.variable);
        },
        .import_stmt => h.importish(tree, tree.importStmt(node).path, tree.importStmt(node).symbols),
        .export_stmt => h.importish(tree, tree.exportStmt(node).path, tree.exportStmt(node).symbols),
        .docstring => {
            const ds = tree.docString(node);
            h.string(tree, ds.tag_name);
            h.string(tree, ds.content);
        },
        else => {},
    }
    return h.inner.final();
}

const Hasher = struct {
    inner: std.hash.Wyhash = .init(0),

    fn add(self: *Hasher, v: anytype) void {
        std.hash.autoHash(&self.inner, v);
    }

    /// By content: the two trees intern their strings separately.
    fn string(self: *Hasher, tree: *const ast.Tree, id: ast.StringId) void {
        const text = if (id == .none) "" else tree.getString(id);
        self.add(text.len);
        self.inner.update(text);
    }

    fn args(self: *Hasher, tree: *const ast.Tree, span: ast.Span) void {
        for (tree.getNamedArgs(span)) |arg| {
            self.string(tree, arg.name);
            self.add(arg.modifier);
        }
    }

    fn params(self: *Hasher, tree: *const ast.Tree, span: ast.Span) void {
        for (tree.getParams(span)) |param| {
            self.string(tree, param.name);
            self.add(param.modifier);
            self.add(param.is_keyword);
        }
    }

    fn importish(self: *Hasher, tree: *const ast.Tree, path: ast.StringId, symbols: ast.Span) void {
        self.string(tree, path);
        for (tree.getAliasPairs(symbols)) |pair| {
            self.string(tree, pair.original);
            self.string(tree, pair.alias);
        }
    }
};
