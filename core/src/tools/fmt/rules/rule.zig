const std = @import("std");
const ast = @import("../../../core/ast.zig");

pub const FormatRule = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        /// `commented[i]`: a comment sits on statement i's lines, or between it and the
        /// statement before it. Comments are printed in source order, so a rule must not
        /// move such a statement.
        processBlockStmts: ?*const fn (ptr: *anyopaque, temp_allocator: std.mem.Allocator, tree: *const ast.Tree, stmts: []const ast.NodeIndex, commented: []const bool) []const ast.NodeIndex = null,
    };

    pub fn name(self: FormatRule) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn processBlockStmts(self: FormatRule, temp_allocator: std.mem.Allocator, tree: *const ast.Tree, stmts: []const ast.NodeIndex, commented: []const bool) []const ast.NodeIndex {
        if (self.vtable.processBlockStmts) |func| return func(self.ptr, temp_allocator, tree, stmts, commented);
        return stmts;
    }
};
