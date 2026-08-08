const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");

pub const LintRule = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        checkNode: *const fn (ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) anyerror!void,
        checkEOF: ?*const fn (ptr: *anyopaque, engine: *linter.Linter) anyerror!void = null,
        enterScope: ?*const fn (ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) anyerror!void = null,
        exitScope: ?*const fn (ptr: *anyopaque, scope: *const linter.Scope, engine: *linter.Linter) anyerror!void = null,
    };

    pub fn name(self: LintRule) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn checkNode(self: LintRule, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        return self.vtable.checkNode(self.ptr, engine, tree, node_idx);
    }

    pub fn checkEOF(self: LintRule, engine: *linter.Linter) !void {
        if (self.vtable.checkEOF) |func| return func(self.ptr, engine);
    }

    pub fn enterScope(self: LintRule, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        if (self.vtable.enterScope) |func| return func(self.ptr, engine, tree, node_idx);
    }

    pub fn exitScope(self: LintRule, scope: *const linter.Scope, engine: *linter.Linter) !void {
        if (self.vtable.exitScope) |func| return func(self.ptr, scope, engine);
    }
};
