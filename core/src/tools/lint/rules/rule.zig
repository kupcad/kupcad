const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");

pub const LintRule = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        // Updated to use the DoD Tree and NodeIndex
        checkNode: ?*const fn (ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) anyerror!void = null,
        exitScope: ?*const fn (ptr: *anyopaque, scope: *const linter.Scope, engine: *linter.Linter) anyerror!void = null,
        checkEOF: ?*const fn (ptr: *anyopaque, engine: *linter.Linter) anyerror!void = null,
    };

    pub fn checkNode(self: LintRule, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        if (self.vtable.checkNode) |func| try func(self.ptr, engine, tree, node_idx);
    }

    pub fn exitScope(self: LintRule, scope: *const linter.Scope, engine: *linter.Linter) !void {
        if (self.vtable.exitScope) |func| try func(self.ptr, scope, engine);
    }

    pub fn checkEOF(self: LintRule, engine: *linter.Linter) !void {
        if (self.vtable.checkEOF) |func| try func(self.ptr, engine);
    }
};
