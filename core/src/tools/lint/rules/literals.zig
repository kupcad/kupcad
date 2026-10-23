//! Reading literal values out of the syntax tree, for rules that check what a script
//! states outright (`cube(-5)`, `segments: 6`, `engine: :brep`).

const std = @import("std");
const ast = @import("../../../core/ast.zig");

/// The value of a number literal, negated or not (`5`, `-5`).
pub fn number(tree: *const ast.Tree, idx: ast.NodeIndex) ?f64 {
    const node = tree.getNode(idx) orelse return null;
    if (node.tag == .number) return tree.number(node);
    if (node.tag == .unary_op and tree.unaryExpr(node).op == .negate) {
        if (number(tree, tree.unaryExpr(node).operand)) |n| return -n;
    }
    return null;
}

/// The name of a symbol literal (`:brep` is "brep").
pub fn symbol(tree: *const ast.Tree, idx: ast.NodeIndex) ?[]const u8 {
    const node = tree.getNode(idx) orelse return null;
    if (node.tag != .symbol) return null;
    return tree.nodeString(node);
}

/// The keyword argument `name` of a call, if it is given.
pub fn keyword(tree: *const ast.Tree, call: ast.MethodCall, name: []const u8) ?ast.NamedArg {
    for (tree.getNamedArgs(call.args)) |arg| {
        if (arg.name != .none and std.mem.eql(u8, tree.getString(arg.name), name)) return arg;
    }
    return null;
}

/// Whether `node` calls `method` on `receiver` (`CAD.config`); a null receiver means a
/// call on nothing (`cube(...)`).
pub fn isCall(tree: *const ast.Tree, node: *const ast.Node, receiver: ?[]const u8, method: []const u8) bool {
    if (node.tag != .method_call) return false;
    const call = tree.methodCall(node);
    if (!std.mem.eql(u8, tree.getString(call.method_name), method)) return false;
    if (receiver) |name| {
        const target = tree.getNode(call.receiver) orelse return false;
        return target.tag == .identifier and std.mem.eql(u8, tree.nodeString(target), name);
    }
    return call.receiver == .none;
}

/// The token holding a keyword argument's name: in `sise: 3`, two before its value.
pub fn keywordToken(value_first_token: u32) ?u32 {
    return if (value_first_token >= 2) value_first_token - 2 else null;
}
