//! The formatter's import sorting (`Config.sort_imports`): each run of imports sorted by path,
//! a run with a comment on or between its imports left in the author's order.

const std = @import("std");
const ast = @import("../../core/ast.zig");

/// `stmts` with each run of imports sorted by path, in a copy from `temp_allocator` (the tree's
/// slice is left as it is). `commented[i]`: a comment sits on statement i's lines, or between
/// it and the statement before it; a run with one is left as it is, since comments are
/// printed in source order and sorting moved the imports away from theirs.
pub fn sortedImports(temp_allocator: std.mem.Allocator, tree: *const ast.Tree, stmts: []const ast.NodeIndex, commented: []const bool) ![]const ast.NodeIndex {
    if (stmts.len < 2) return stmts;
    const sorted = try temp_allocator.dupe(ast.NodeIndex, stmts);
    var i: usize = 0;
    while (i < sorted.len) {
        if (tree.getNode(sorted[i]).?.tag != .import_stmt) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < sorted.len and tree.getNode(sorted[j]).?.tag == .import_stmt) j += 1;
        if (std.mem.findScalar(bool, commented[i..j], true) == null) {
            std.mem.sort(ast.NodeIndex, sorted[i..j], tree, pathLessThan);
        }
        i = j;
    }
    return sorted;
}

fn pathLessThan(tree: *const ast.Tree, a: ast.NodeIndex, b: ast.NodeIndex) bool {
    const path_a = tree.getString(tree.importStmt(tree.getNode(a).?).path);
    const path_b = tree.getString(tree.importStmt(tree.getNode(b).?).path);
    return std.mem.lessThan(u8, path_a, path_b);
}
