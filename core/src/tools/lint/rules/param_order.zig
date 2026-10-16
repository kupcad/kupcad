//! The `param-order` lint rule: flags a top-level `param` read before its definition, and a
//! definition inside a body (a def, a block, an if), where the UI's static extraction can't
//! find it.

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
                .deinit = deinit,
            },
        };
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ParamOrderRule = @ptrCast(@alignCast(ptr));
        self.defined_params.deinit(allocator);
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
            // Getter mode: warn if invoked before its top-level definition. A read inside a
            // def or block runs when that is called, which may be after the definition
            // below it, so only a top-level read is judged by its position.
            if (engine.body_depth == 0 and !self.defined_params.contains(param_name)) {
                try engine.report(
                    id,
                    engine.getLoc(node.main_token),
                    "Parameter ':{s}' used before definition.",
                    .{param_name},
                );
            }
        }
    }

    /// The name a `param` call gives as a literal; null for one computed at run time
    /// (`param(name)` with a variable used to be taken for a parameter called "name").
    fn extractParamName(tree: *const ast.Tree, node_idx: ast.NodeIndex) ?[]const u8 {
        const node = tree.getNode(node_idx) orelse return null;
        return switch (node.tag) {
            .symbol, .string => tree.getString(@as(ast.StringId, @fromBackingInt(node.data))),
            else => null,
        };
    }
};
