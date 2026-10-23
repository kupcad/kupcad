//! The `unused-param` lint rule (`UnusedParamRule`): a parameter defined on its own line
//! and never read.

const std = @import("std");
const ast = @import("../../../core/ast.zig");
const token = @import("../../../core/token.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;
const literals = @import("literals.zig");

/// Flags a parameter defined as a statement of its own (`param(:width, default: 20)`,
/// its value dropped) and never read with `param(:width)` or `params[:width]`: the UI
/// shows a slider that changes nothing. A definition assigned to a variable is left to
/// unused-variable.
pub const UnusedParamRule = struct {
    pub const id = "unused-param";
    pub const description = "A param defined on its own line and never read";

    /// Definitions whose value is dropped, by name, with where each is.
    dropped: std.array_hash_map.String(token.Location) = .empty,
    read: std.StringHashMapUnmanaged(void) = .empty,
    /// A read whose name is computed (`param(name)`): any parameter may be the one read.
    read_dynamically: bool = false,

    pub fn rule(self: *@This()) LintRule {
        return .{
            .id = id,
            .ptr = self,
            .vtable = &.{
                .checkNode = checkNode,
                .checkEOF = checkEOF,
                .deinit = deinit,
            },
        };
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const self: *UnusedParamRule = @ptrCast(@alignCast(ptr));
        const node = tree.getNode(node_idx) orelse return;
        switch (node.tag) {
            // A statement's value is dropped, unless it ends a body (then it is the result).
            .block => {
                const stmts = tree.getNodes(tree.block(node).stmts);
                if (stmts.len < 2) return;
                for (stmts[0 .. stmts.len - 1]) |stmt| {
                    const call_node = tree.getNode(stmt).?;
                    if (!literals.isCall(tree, call_node, null, "param")) continue;
                    const call = tree.methodCall(call_node);
                    if (!isDefinition(tree, call)) continue;
                    const name = paramName(tree, call) orelse continue;
                    try self.dropped.put(engine.allocator, name, engine.getLoc(call_node.main_token));
                }
            },
            .method_call => {
                if (!literals.isCall(tree, node, null, "param")) return;
                const call = tree.methodCall(node);
                if (isDefinition(tree, call)) return;
                if (paramName(tree, call)) |name| try self.read.put(engine.allocator, name, {}) else if (tree.getNamedArgs(call.args).len == 1) self.read_dynamically = true;
            },
            .index_access => {
                const access = tree.indexAccess(node);
                const target = tree.getNode(access.target) orelse return;
                if (target.tag != .identifier or !std.mem.eql(u8, tree.nodeString(target), "params")) return;
                if (literals.symbol(tree, access.index)) |name| try self.read.put(engine.allocator, name, {});
            },
            else => {},
        }
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *UnusedParamRule = @ptrCast(@alignCast(ptr));
        self.dropped.deinit(allocator);
        self.read.deinit(allocator);
        self.* = .{};
    }

    fn checkEOF(ptr: *anyopaque, engine: *linter.Linter) !void {
        const self: *UnusedParamRule = @ptrCast(@alignCast(ptr));
        if (self.read_dynamically) return;
        var it = self.dropped.iterator();
        while (it.next()) |entry| {
            if (self.read.contains(entry.key_ptr.*)) continue;
            try engine.report(id, entry.value_ptr.*, "Parameter ':{s}' is defined but never read; assign it (x = param(:{s}, ...)) or read it with param(:{s})", .{ entry.key_ptr.*, entry.key_ptr.*, entry.key_ptr.* });
        }
    }

    /// `param(:x, default: 1)` defines; `param(:x)` reads.
    fn isDefinition(tree: *const ast.Tree, call: ast.MethodCall) bool {
        const args = tree.getNamedArgs(call.args);
        return args.len > 1 or (args.len == 1 and args[0].name != .none);
    }

    fn paramName(tree: *const ast.Tree, call: ast.MethodCall) ?[]const u8 {
        const args = tree.getNamedArgs(call.args);
        if (args.len == 0 or args[0].name != .none) return null;
        return literals.symbol(tree, args[0].value);
    }
};
