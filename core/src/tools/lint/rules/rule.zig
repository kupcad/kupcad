const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");

pub const LintRule = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        checkNode: ?*const fn (
            ptr: *anyopaque,
            node: *ast.Node,
            diagnostics: *std.ArrayListUnmanaged(linter.LinterDiagnostic),
            allocator: std.mem.Allocator,
        ) anyerror!void = null,
        exitScope: ?*const fn (
            ptr: *anyopaque,
            scope: *const linter.Scope,
            diagnostics: *std.ArrayListUnmanaged(linter.LinterDiagnostic),
            allocator: std.mem.Allocator,
        ) anyerror!void = null,
    };

    pub fn checkNode(
        self: LintRule,
        node: *ast.Node,
        diagnostics: *std.ArrayListUnmanaged(linter.LinterDiagnostic),
        allocator: std.mem.Allocator,
    ) !void {
        if (self.vtable.checkNode) |func| {
            try func(self.ptr, node, diagnostics, allocator);
        }
    }

    pub fn exitScope(
        self: LintRule,
        scope: *const linter.Scope,
        diagnostics: *std.ArrayListUnmanaged(linter.LinterDiagnostic),
        allocator: std.mem.Allocator,
    ) !void {
        if (self.vtable.exitScope) |func| {
            try func(self.ptr, scope, diagnostics, allocator);
        }
    }
};
