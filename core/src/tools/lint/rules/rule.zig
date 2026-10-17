//! `LintRule`: the interface every lint rule implements for `linter.zig`, an id and a vtable
//! of hooks called per node, at the end of the script, on entering and leaving a scope, and
//! after every check to free what the rule kept.

const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");

pub const LintRule = struct {
    /// The rule's stable id (`unused-variable`): shown with its messages, and how the
    /// config and suppressions name it.
    id: []const u8,
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        checkNode: *const fn (ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) anyerror!void,
        checkEOF: ?*const fn (ptr: *anyopaque, engine: *linter.Linter) anyerror!void = null,
        enterScope: ?*const fn (ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) anyerror!void = null,
        exitScope: ?*const fn (ptr: *anyopaque, scope: *const linter.Scope, engine: *linter.Linter) anyerror!void = null,
        /// Frees what the rule kept during a check and resets it for the next. Called after
        /// every check, finished or failed: freeing in checkEOF leaked when one failed.
        deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
    };

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

    pub fn deinit(self: LintRule, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |func| func(self.ptr, allocator);
    }
};
