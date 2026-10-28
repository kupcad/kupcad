//! Where a name in a document is defined, for the language server's go-to-definition
//! (cli/lsp.zig): a local's or an upvalue's declaration (`Document.declarations`, the
//! resolver's: its assignment, the `def`, lambda or block it is a parameter of, the `for`),
//! a name an `import` binds, a method's `def` (in the class the call is in first), a
//! class's or module's statement, and the file an `import`'s path names. Also `tokenAt`
//! and `nodeOfToken`, which hover finds its node with too.

const std = @import("std");
const ast = @import("../core/ast.zig");
const token_span = @import("../core/token_span.zig");
const Document = @import("../frontend/document.zig").Document;

/// A stretch of the document: a name where it is defined.
pub const Span = struct { offset: u32, length: u32 };

pub const Target = union(enum) {
    /// Where in the document itself.
    here: Span,
    /// The module an `import` reads, its path as written (relative to the document).
    module: []const u8,
};

/// The token `offset` is in, found by binary search (token starts are in order; a scan
/// from the first token made a hover near the end of a long file cost its length).
pub fn tokenAt(doc: *const Document, offset: usize) ?u24 {
    const starts = doc.tokens.starts;
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (starts[mid] <= offset) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const i = lo - 1;
    return if (offset < starts[i] + doc.tokens.lengths[i]) @intCast(i) else null;
}

/// The node of the tree whose main token is `tok`, or .none. The parser leaves nodes out
/// of the tree behind (an assignment's name, read first as a variable), which share the
/// token: only a node with a parent, or the root, counts (any node, in a document parsed
/// without its parent map).
pub fn nodeOfToken(doc: *const Document, tok: u24) ast.NodeIndex {
    for (doc.tree.nodes.items, 0..) |node, i| {
        if (node.main_token != tok) continue;
        const idx: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(i)));
        if (doc.parents.len == 0 or doc.parents[i] != .none or idx == doc.tree.root) return idx;
    }
    return .none;
}

/// The call whose method's name is `tok` (`helper` in `self.helper`, whose main token is
/// the receiver's), or .none.
fn callNamedAt(doc: *const Document, tok: u24) ast.NodeIndex {
    for (doc.tree.nodes.items, 0..) |node, i| {
        if (node.tag == .method_call and doc.tree.methodCall(&node).name_token == tok) return @fromBackingInt(@as(u32, @intCast(i)));
    }
    return .none;
}

/// Where what is at `offset` is defined; null when it names nothing the document defines
/// (a built-in, a method of a value, a number).
pub fn definitionAt(doc: *const Document, offset: usize) ?Target {
    const tok = tokenAt(doc, offset) orelse return null;
    var node_idx = nodeOfToken(doc, tok);
    if (node_idx == .none) node_idx = callNamedAt(doc, tok);
    if (node_idx == .none) return importPathAt(doc, tok);
    const tree = &doc.tree;
    const node = tree.getNode(node_idx).?;
    switch (node.tag) {
        .identifier => {
            const name = tree.nodeString(node);
            const declared = doc.declarations[@backingInt(node_idx)];
            if (declared != .none) return nameIn(doc, declared, name);
            // Not a local: a name an import binds, a method called without parentheses,
            // a class or module
            return importedName(doc, name) orelse defNamed(doc, node_idx, name) orelse typeNamed(doc, name);
        },
        .assignment => {
            const declared = doc.declarations[@backingInt(node_idx)];
            if (declared == .none) return null;
            return nameIn(doc, declared, tree.getString(tree.assignment(node).name));
        },
        .method_call => {
            const mc = tree.methodCall(node);
            const name = tree.getString(mc.method_name);
            if (mc.receiver != .none) {
                if (tree.getNode(mc.receiver).?.tag != .self_expr) return null;
                return defNamed(doc, node_idx, name);
            }
            // A bare name the parser doesn't know as a variable is a call: an imported
            // name read is one too
            return defNamed(doc, node_idx, name) orelse importedName(doc, name);
        },
        .import_stmt => return .{ .module = tree.getString(tree.importStmt(node).path) },
        else => return null,
    }
}

/// The path of the import whose path is the token `tok`: the one after its `from` (or
/// after `import`, for `import "hardware"`), in the last import before it.
fn importPathAt(doc: *const Document, tok: u24) ?Target {
    if (tok == 0) return null;
    const before = doc.tokens.tags[tok - 1];
    if (before != .keyword_from and before != .keyword_import) return null;
    const tree = &doc.tree;
    var import: ?*const ast.Node = null;
    for (tree.nodes.items) |*node| {
        if (node.tag != .import_stmt or node.main_token >= tok) continue;
        if (import == null or node.main_token > import.?.main_token) import = node;
    }
    return .{ .module = tree.getString(tree.importStmt(import orelse return null).path) };
}

/// Where `name` is written in the statement or expression `node`: its first token with
/// that text (the name an assignment, a `def`'s parameters, a `for` or an `import` binds).
fn nameIn(doc: *const Document, node: ast.NodeIndex, name: []const u8) ?Target {
    const first = token_span.first(&doc.tree, node);
    const last = token_span.last(&doc.tree, node);
    var tok = first;
    while (tok <= last) : (tok += 1) {
        const start = doc.tokens.starts[tok];
        const len = doc.tokens.lengths[tok];
        if (std.mem.eql(u8, doc.source[start..][0..len], name)) return .{ .here = .{ .offset = start, .length = len } };
    }
    return null;
}

/// The name `name` an `import` binds (`import box from "./box.kup"`, `import { a as b }`).
fn importedName(doc: *const Document, name: []const u8) ?Target {
    const tree = &doc.tree;
    for (tree.nodes.items) |node| {
        if (node.tag != .import_stmt) continue;
        for (tree.getAliasPairs(tree.importStmt(&node).symbols)) |pair| {
            const bound = if (pair.alias != .none) pair.alias else pair.original;
            if (std.mem.eql(u8, tree.getString(bound), name)) return importedNameIn(doc, node.main_token, name);
        }
    }
    return null;
}

/// Where the import whose `import` is the token `start` names `name`: its last mention
/// before `from` (`import { a as a2 }` binds the second). The names aren't nodes, so the
/// import's own tokens are read.
fn importedNameIn(doc: *const Document, start: u24, name: []const u8) ?Target {
    var found: ?Target = null;
    var tok: usize = start + 1;
    while (tok < doc.tokens.tags.len and doc.tokens.tags[tok] != .keyword_from) : (tok += 1) {
        const at = doc.tokens.starts[tok];
        const len = doc.tokens.lengths[tok];
        if (std.mem.eql(u8, doc.source[at..][0..len], name)) found = .{ .here = .{ .offset = at, .length = len } };
    }
    return found;
}

/// The `def` of `name` a call at `from` reaches: in the class (or module) the call is in,
/// else at the top of the script, else anywhere.
fn defNamed(doc: *const Document, from: ast.NodeIndex, name: []const u8) ?Target {
    const tree = &doc.tree;
    const home = enclosingType(doc, from);
    var anywhere: ?ast.NodeIndex = null;
    var top: ?ast.NodeIndex = null;
    for (tree.nodes.items, 0..) |node, i| {
        if (node.tag != .def_stmt or !std.mem.eql(u8, tree.getString(tree.defStmt(&node).name), name)) continue;
        const idx: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(i)));
        const owner = enclosingType(doc, idx);
        if (home != .none and owner == home) return nameIn(doc, idx, name);
        if (owner == .none and top == null) top = idx;
        if (anywhere == null) anywhere = idx;
    }
    return nameIn(doc, top orelse anywhere orelse return null, name);
}

/// The class or module `node` is inside, or .none.
fn enclosingType(doc: *const Document, node: ast.NodeIndex) ast.NodeIndex {
    var at = doc.parents[@backingInt(node)];
    while (at != .none) : (at = doc.parents[@backingInt(at)]) {
        switch (doc.tree.getNode(at).?.tag) {
            .class_stmt, .module_stmt => return at,
            else => {},
        }
    }
    return .none;
}

/// The `class` or `module` statement of `name`.
fn typeNamed(doc: *const Document, name: []const u8) ?Target {
    const tree = &doc.tree;
    for (tree.nodes.items, 0..) |node, i| {
        const idx: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(i)));
        const named = switch (node.tag) {
            // `Nut` in `class Fasteners::Nut` too, whose path is no identifier's string
            .class_stmt => std.mem.eql(u8, tree.getString(tree.className(tree.classStmt(&node))), name),
            .module_stmt => std.mem.eql(u8, tree.getString(tree.moduleStmt(&node).name), name),
            else => false,
        };
        if (named) return nameIn(doc, idx, name);
    }
    return null;
}
