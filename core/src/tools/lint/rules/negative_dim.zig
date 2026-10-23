//! The `nonpositive-size` lint rule (`NegativeDimRule`): flags a size argument written as a
//! literal zero or negative number, using the built-in's `Signature` to tell sizes from other
//! arguments: a primitive's, or a method's on a shape the script is known to hold.

const std = @import("std");
const ast = @import("../../../core/ast.zig");
const value = @import("../../../core/value.zig");
const manifest = @import("../../../stdlib/manifest.zig");
const Signature = @import("../../../stdlib/signature.zig").Signature;
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;
const Shapes = @import("../shapes.zig").Shapes;
const literals = @import("literals.zig");

/// Flags a size given as a literal zero or negative number, which the built-in rejects when
/// the script runs: `cube(-5)`, `cylinder(h: 0)`, `cube(1).offset(-1)`, `part.min_gap(other,
/// 0)`. The sizes come from each built-in's Signature, so a coordinate (`translate(-5)`) or a
/// parameter that may be negative (a sketch's offset) is never flagged. A method is checked
/// only on a receiver known to be a solid or a sketch: an object of the script's own class
/// may name its methods like the kernel's.
pub const NegativeDimRule = struct {
    pub const id = "nonpositive-size";
    pub const description = "A size written as zero or a negative number";

    /// Which variables hold solids and sketches, as far as the script says.
    shapes: Shapes = .{},

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
        const self: *NegativeDimRule = @ptrCast(@alignCast(ptr));
        self.shapes.deinit(allocator);
        self.* = .{};
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const self: *NegativeDimRule = @ptrCast(@alignCast(ptr));
        const node = tree.getNode(node_idx) orelse return;
        if (node.tag == .assignment or node.tag == .import_stmt) return self.shapes.observe(engine.allocator, tree, node);
        if (node.tag != .method_call) return;
        const call = tree.methodCall(node);
        const method = tree.getString(call.method_name);
        var on_solid = false;
        const signature = if (call.receiver == .none)
            manifest.signatureOf(method) orelse return
        else blk: {
            const shape = self.shapes.of(tree, call.receiver) orelse return;
            on_solid = shape == .solid;
            break :blk manifest.methodSignatureOf(method) orelse return;
        };

        var position: usize = 0;
        for (tree.getNamedArgs(call.args)) |arg| {
            // A splat hides which positions the arguments after it fill.
            if (arg.modifier != null) return;
            const param = if (arg.name != .none) tree.getString(arg.name) else nextPositional(signature, &position) orelse continue;
            const solid_only = on_solid and contains(signature.solid_sizes, param);
            if (!contains(signature.sizes, param) and !solid_only) continue;
            const n = literals.number(tree, arg.value) orelse continue;
            if (n > 0) continue;
            const loc = engine.nodeLoc(tree, arg.value);
            if (solid_only) {
                try engine.report(id, loc, "a Solid's {s} expects {s} to be greater than zero, got {f}", .{ method, param, value.fmtNumber(n) });
            } else {
                try engine.report(id, loc, "{s} expects {s} to be greater than zero, got {f}", .{ method, param, value.fmtNumber(n) });
            }
        }
    }

    /// The name of the next positional argument, if the primitive has that many.
    fn nextPositional(signature: *const Signature, position: *usize) ?[]const u8 {
        defer position.* += 1;
        return if (position.* < signature.positional.len) signature.positional[position.*] else null;
    }

    fn contains(names: []const []const u8, name: []const u8) bool {
        for (names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
};
