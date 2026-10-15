const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const ParamOrderRule = struct {
    pub const id = "param-order";
    pub const description = "A param read before it is defined, or defined where the UI can't find it";

    defined_params: std.StringHashMapUnmanaged(void) = .empty,

    pub fn rule(self: *@This()) LintRule {
        return .{
            .id = id,
            .ptr = self,
            .vtable = &.{
                .checkNode = checkNode,
                .checkEOF = checkEOF,
            },
        };
    }

    pub fn deinit(self: *ParamOrderRule, allocator: std.mem.Allocator) void {
        self.defined_params.deinit(allocator);
    }

    fn checkEOF(ptr: *anyopaque, engine: *linter.Linter) !void {
        const self: *ParamOrderRule = @ptrCast(@alignCast(ptr));
        self.defined_params.deinit(engine.allocator);
        self.defined_params = .empty;
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const self: *ParamOrderRule = @ptrCast(@alignCast(ptr));
        const node = tree.getNode(node_idx) orelse return;

        if (node.tag != .method_call) return;

        const mc = tree.methodCall(node);
        const method_name = tree.getString(mc.method_name);

        if (!std.mem.eql(u8, method_name, "param")) return;

        const args = tree.getNamedArgs(mc.args);
        if (args.len == 0) return;

        const param_name = extractParamName(tree, args[0].value) orelse return;

        // Setter mode has >1 argument or attached keyword arguments
        const is_setter = args.len > 1 or args[0].name != .none;

        if (is_setter) {
            // Static UI extraction reads the script's own statements, so a definition inside
            // any body (a def, a block, an if) is out of its reach.
            if (engine.body_depth > 0) {
                try engine.report(
                    id,
                    engine.getLoc(node.main_token),
                    "Parameter ':{s}' definition should be placed at the top level for static UI extraction.",
                    .{param_name},
                );
            }

            try self.defined_params.put(engine.allocator, param_name, {});
        } else {
            // Getter mode: warn if invoked before its top-level definition
            if (!self.defined_params.contains(param_name)) {
                try engine.report(
                    id,
                    engine.getLoc(node.main_token),
                    "Parameter ':{s}' used before definition.",
                    .{param_name},
                );
            }
        }
    }

    fn extractParamName(tree: *const ast.Tree, node_idx: ast.NodeIndex) ?[]const u8 {
        const node = tree.getNode(node_idx) orelse return null;
        return switch (node.tag) {
            .symbol, .string, .identifier => tree.getString(@as(ast.StringId, @fromBackingInt(node.data))),
            else => null,
        };
    }
};
