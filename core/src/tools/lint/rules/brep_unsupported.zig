const std = @import("std");
const ast = @import("../../../core/ast.zig");
const kernel = @import("../../../kernel/kernel.zig");
const EngineType = @import("../../../kernel/geometry_handle.zig").EngineType;
const token_span = @import("../../../core/token_span.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;
const literals = @import("literals.zig");
const Shapes = @import("../shapes.zig").Shapes;

/// Warns, before the script runs, about what the engine it runs on can't do yet: a call
/// such as `translate`, a boolean on shapes (`a - b`), or a call to a method of the script
/// whose body needs one, after `CAD.config(engine: :brep)` or inside
/// `CAD.with_config(engine: :brep) do ... end`. A method's body runs under the engine of
/// the call, so it is reported where it is called. It asks kernel.supports, so a feature
/// Locus gains stops being reported.
pub const BrepUnsupportedRule = struct {
    pub const id = "brep-unsupported";
    pub const description = "Something the B-Rep engine can't do yet, after engine: :brep";

    /// The engine the script selects with CAD.config, from that statement on.
    script_engine: EngineType = .manifold,
    /// CAD.with_config blocks that select an engine, by the tokens they span.
    scoped: std.ArrayListUnmanaged(Scoped) = .empty,
    /// The script's methods, by the tokens of their bodies and their names.
    methods: std.ArrayListUnmanaged(Method) = .empty,
    shapes: Shapes = .{},

    const Scoped = struct { first: u32, last: u32, engine: EngineType };
    const Method = struct {
        name: []const u8,
        first: u32,
        last: u32,
        /// The first thing its body needs that an engine may lack, and what needed it.
        needs: ?Need = null,
    };
    const Need = struct {
        feature: kernel.Feature,
        /// The call or operator that needs it.
        what: []const u8,
        /// The script's method called here, when `what` is in its body.
        via: ?[]const u8 = null,
    };

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
        self.methods.deinit(engine.allocator);
        self.shapes.deinit(engine.allocator);
        self.* = .{};
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const self: *BrepUnsupportedRule = @ptrCast(@alignCast(ptr));
        const node = tree.getNode(node_idx) orelse return;
        switch (node.tag) {
            .def_stmt => {
                const def = tree.defStmt(node);
                try self.methods.append(engine.allocator, .{ .name = tree.getString(def.name), .first = token_span.first(tree, def.body), .last = token_span.last(tree, def.body) });
            },
            .assignment => try self.shapes.observe(engine.allocator, tree, node),
            .binary_op => {
                const b = tree.binaryExpr(node);
                switch (b.op) {
                    .add, .subtract, .bitwise_and => {},
                    else => return,
                }
                const shape = self.shapes.of(tree, b.left) orelse self.shapes.of(tree, b.right) orelse return;
                const feature: kernel.Feature = if (shape == .solid) .boolean else .sketch_boolean;
                try self.found(engine, node, .{ .feature = feature, .what = opName(b.op) });
            },
            .method_call => {
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
                const need = self.needOf(tree, node, call) orelse return;
                try self.found(engine, node, need);
            },
            else => {},
        }
    }

    /// Something at `node` needs `need`. Inside a method it is the method's need, reported
    /// where it is called, unless a CAD.with_config inside the method sets the engine;
    /// elsewhere it is reported if the engine there lacks it.
    fn found(self: *BrepUnsupportedRule, engine: *linter.Linter, node: *const ast.Node, need: Need) !void {
        const tok = node.main_token;
        if (self.methodAt(tok)) |method| {
            const scoped_inside = if (self.scopeAt(tok)) |s| s.first > method.first else false;
            if (!scoped_inside) {
                if (method.needs == null) method.needs = need;
                return;
            }
        }
        const runs_on = self.engineAt(tok);
        if (runs_on == .manifold or kernel.supports(runs_on, need.feature)) return;
        const loc = engine.getLoc(tok);
        if (need.via) |method| {
            try engine.report(id, loc, "{s}() uses {s}: the {s} engine can't {s} yet, so this fails when the script runs", .{ method, need.what, runs_on.scriptName(), need.feature.describe() });
        } else {
            try engine.report(id, loc, "{s}: the {s} engine can't {s} yet, so this fails when the script runs", .{ need.what, runs_on.scriptName(), need.feature.describe() });
        }
    }

    /// What a call needs: its method's feature, a cylinder whose two radii are different
    /// literals (a cone), or the need of a method of the script it calls.
    fn needOf(self: *BrepUnsupportedRule, tree: *const ast.Tree, node: *const ast.Node, call: ast.MethodCall) ?Need {
        const name = tree.getString(call.method_name);
        if (literals.isCall(tree, node, null, "cylinder") and isCone(tree, call)) return .{ .feature = .cone, .what = "cylinder(r1:, r2:)" };
        inline for (comptime std.enums.values(kernel.Feature)) |feature| {
            for (comptime feature.methods()) |method| {
                if (std.mem.eql(u8, method, name)) return .{ .feature = feature, .what = method };
            }
        }
        if (call.receiver != .none) return null;
        for (self.methods.items) |m| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            const inner = m.needs orelse return null;
            // Named by the method called here, through however many others it calls.
            return .{ .feature = inner.feature, .what = inner.what, .via = m.name };
        }
        return null;
    }

    /// The innermost method of the script whose body holds `tok`.
    fn methodAt(self: *BrepUnsupportedRule, tok: u32) ?*Method {
        var best: ?*Method = null;
        for (self.methods.items) |*m| {
            if (tok < m.first or tok > m.last) continue;
            if (best == null or m.first >= best.?.first) best = m;
        }
        return best;
    }

    /// The engine in force at `tok`: the innermost CAD.with_config around it, else the
    /// script's.
    fn engineAt(self: *const BrepUnsupportedRule, tok: u32) EngineType {
        return if (self.scopeAt(tok)) |s| s.engine else self.script_engine;
    }

    fn scopeAt(self: *const BrepUnsupportedRule, tok: u32) ?Scoped {
        var best: ?Scoped = null;
        for (self.scoped.items) |s| {
            if (tok < s.first or tok > s.last) continue;
            if (best == null or s.first >= best.?.first) best = s;
        }
        return best;
    }

    fn opName(op: ast.BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .subtract => "-",
            else => "&",
        };
    }

    /// The engine a CAD.config / with_config call names as a literal (`engine: :brep`).
    fn engineSetting(tree: *const ast.Tree, call: ast.MethodCall) ?EngineType {
        const arg = literals.keyword(tree, call, "engine") orelse return null;
        return EngineType.fromScriptName(literals.symbol(tree, arg.value) orelse return null);
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
