const std = @import("std");
const ast = @import("../../../core/ast.zig");

pub const FormatRule = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,

        /// Allows a rule to non-destructively reorder or filter statements in a block.
        /// Must return either the original slice or a new slice allocated using `temp_allocator`.
        processBlockStmts: ?*const fn (ptr: *anyopaque, temp_allocator: std.mem.Allocator, stmts: []const *ast.Node) []const *ast.Node = null,
    };

    pub fn name(self: FormatRule) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn processBlockStmts(self: FormatRule, temp_allocator: std.mem.Allocator, stmts: []const *ast.Node) []const *ast.Node {
        if (self.vtable.processBlockStmts) |hook| {
            return hook(self.ptr, temp_allocator, stmts);
        }
        return stmts; // Pass-through if rule doesn't implement this hook
    }
};
