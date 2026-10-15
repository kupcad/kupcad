const std = @import("std");
const ast = @import("../../../core/ast.zig");
const value = @import("../../../core/value.zig");
const manifest = @import("../../../stdlib/manifest.zig");
const Signature = @import("../../../stdlib/primitives.zig").Signature;
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;
const literals = @import("literals.zig");

/// Flags a primitive's size given as a literal zero or negative number, such as
/// `cube(-5)` or `cylinder(h: 0)`, which the primitive rejects when the script runs.
/// The sizes come from each primitive's Signature, so a coordinate (`translate(-5)`) or
/// a parameter that may be negative is never flagged.
pub const NegativeDimRule = struct {
    pub const id = "nonpositive-size";
    pub const description = "A primitive's size written as zero or a negative number";

    pub fn rule(self: *@This()) LintRule {
        return .{
            .id = id,
            .ptr = self,
            .vtable = &.{
                .checkNode = checkNode,
            },
        };
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;
        if (node.tag != .method_call) return;
        const call = tree.methodCall(node);
        if (call.receiver != .none) return;
        const method = tree.getString(call.method_name);
        const signature = manifest.signatureOf(method) orelse return;

        var position: usize = 0;
        for (tree.getNamedArgs(call.args)) |arg| {
            // A splat hides which positions the arguments after it fill.
            if (arg.modifier != null) return;
            const param = if (arg.name != .none) tree.getString(arg.name) else nextPositional(signature, &position) orelse continue;
            if (!isSize(signature, param)) continue;
            const n = literals.number(tree, arg.value) orelse continue;
            if (n > 0) continue;
            const at = tree.getNode(arg.value).?.main_token;
            try engine.report(id, engine.getLoc(at), "{s} expects {s} to be greater than zero, got {f}", .{ method, param, value.fmtNumber(n) });
        }
    }

    /// The name of the next positional argument, if the primitive has that many.
    fn nextPositional(signature: *const Signature, position: *usize) ?[]const u8 {
        defer position.* += 1;
        return if (position.* < signature.positional.len) signature.positional[position.*] else null;
    }

    fn isSize(signature: *const Signature, param: []const u8) bool {
        for (signature.sizes) |size| {
            if (std.mem.eql(u8, size, param)) return true;
        }
        return false;
    }
};
