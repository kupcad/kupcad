const std = @import("std");
const ast = @import("../../../core/ast.zig");

pub const FormatRule = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        normalize: *const fn (ptr: *anyopaque, node: *ast.Node) void,
    };

    pub fn normalize(self: FormatRule, node: *ast.Node) void {
        self.vtable.normalize(self.ptr, node);
    }
};
