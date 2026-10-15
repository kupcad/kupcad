const std = @import("std");
const ast = @import("../../../core/ast.zig");
const kernel = @import("../../../kernel/kernel.zig");
const EngineType = @import("../../../kernel/geometry_handle.zig").EngineType;
const token_span = @import("../../../core/token_span.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;
const literals = @import("literals.zig");

/// Warns, before the script runs, about a call the engine it runs on can't do yet:
/// `translate` after `CAD.config(engine: :brep)` or inside
/// `CAD.with_config(engine: :brep) do ... end`. It follows the script as written (a method
/// defined before the switch and called after it isn't followed), and asks kernel.supports,
/// so a feature Locus gains stops being reported.
pub const BrepUnsupportedRule = struct {
    pub const id = "brep-unsupported";
    pub const description = "A call the B-Rep engine can't do yet, after engine: :brep";

    /// The engine the script selects with CAD.config, from that statement on.
    script_engine: EngineType = .manifold,
    /// CAD.with_config blocks that select an engine, by the tokens they span.
    scoped: std.ArrayListUnmanaged(Scoped) = .empty,

    const Scoped = struct { first: u32, last: u32, engine: EngineType };

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

    fn checkEOF(ptr: *anyopaque, engine: *linter.Linter) !void {
        const self: *BrepUnsupportedRule = @ptrCast(@alignCast(ptr));
        self.scoped.deinit(engine.allocator);
        self.* = .{};
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const self: *BrepUnsupportedRule = @ptrCast(@alignCast(ptr));
        const node = tree.getNode(node_idx) orelse return;
        if (node.tag != .method_call) return;
        const call = tree.methodCall(node);

        if (literals.isCall(tree, node, "CAD", "config")) {
            if (engineSetting(tree, call)) |chosen| self.script_engine = chosen;
            return;
        }
        if (literals.isCall(tree, node, "CAD", "with_config") and call.block != .none) {
            if (engineSetting(tree, call)) |chosen| {
                try self.scoped.append(engine.allocator, .{ .first = token_span.first(tree, call.block), .last = token_span.last(tree, call.block), .engine = chosen });
            }
            return;
        }

        const runs_on = self.engineAt(node.main_token);
        if (runs_on == .manifold) return;
        const feature = featureOf(tree, node, call) orelse return;
        if (kernel.supports(runs_on, feature)) return;
        try engine.report(id, engine.getLoc(node.main_token), "the {s} engine can't {s} yet, so this fails when the script runs", .{ runs_on.scriptName(), feature.describe() });
    }

    /// The engine in force at `tok`: the innermost CAD.with_config around it, else the
    /// script's.
    fn engineAt(self: *const BrepUnsupportedRule, tok: u32) EngineType {
        var best: ?Scoped = null;
        for (self.scoped.items) |s| {
            if (tok < s.first or tok > s.last) continue;
            if (best == null or s.first >= best.?.first) best = s;
        }
        return if (best) |s| s.engine else self.script_engine;
    }

    /// The engine a CAD.config / with_config call names as a literal (`engine: :brep`).
    fn engineSetting(tree: *const ast.Tree, call: ast.MethodCall) ?EngineType {
        const arg = literals.keyword(tree, call, "engine") orelse return null;
        return EngineType.fromScriptName(literals.symbol(tree, arg.value) orelse return null);
    }

    /// The feature a call needs, if the call alone says: its method name, or a cylinder
    /// whose two radii are different literals (a cone).
    fn featureOf(tree: *const ast.Tree, node: *const ast.Node, call: ast.MethodCall) ?kernel.Feature {
        const method = tree.getString(call.method_name);
        if (literals.isCall(tree, node, null, "cylinder") and isCone(tree, call)) return .cone;
        inline for (comptime std.enums.values(kernel.Feature)) |feature| {
            for (comptime feature.methods()) |name| {
                if (std.mem.eql(u8, name, method)) return feature;
            }
        }
        return null;
    }

    fn isCone(tree: *const ast.Tree, call: ast.MethodCall) bool {
        const r1 = radius(tree, call, "r1", "d1") orelse return false;
        const r2 = radius(tree, call, "r2", "d2") orelse return false;
        return r1 != r2;
    }

    fn radius(tree: *const ast.Tree, call: ast.MethodCall, r_name: []const u8, d_name: []const u8) ?f64 {
        if (literals.keyword(tree, call, r_name)) |arg| return literals.number(tree, arg.value);
        if (literals.keyword(tree, call, d_name)) |arg| if (literals.number(tree, arg.value)) |d| return d / 2;
        return null;
    }
};
