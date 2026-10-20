//! The `unused-variable` lint rule (`UnusedVarsRule`): tracks the variables each scope
//! declares and reads, reports those never read when the scope closes (unless named with a
//! leading `_`), and offers a fix that renames every binding to `_name`.

const std = @import("std");
const ast = @import("../../../core/ast.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;

pub const UnusedVarsRule = struct {
    pub const id = "unused-variable";
    pub const description = "A variable assigned and never read";

    /// The `def`s and constants of class, module and singleton bodies: what others reach
    /// through the class (`Gear.new.teeth`, `Gear::TEETH`), so they are never unused here.
    members: std.AutoHashMapUnmanaged(ast.NodeIndex, void) = .empty,
    /// For each open scope, the `def` it is the body of (null for a block, a lambda, a
    /// class): a bare `super` passes that method's parameters on.
    scope_defs: std.ArrayList(?ast.NodeIndex) = .empty,

    pub fn rule(self: *@This()) LintRule {
        return .{
            .id = id,
            .ptr = self,
            .vtable = &.{
                .checkNode = checkNode,
                .enterScope = enterScope,
                .exitScope = exitScope,
                .deinit = deinit,
            },
        };
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *UnusedVarsRule = @ptrCast(@alignCast(ptr));
        self.members.deinit(allocator);
        self.scope_defs.deinit(allocator);
        self.* = .{};
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const self: *UnusedVarsRule = @ptrCast(@alignCast(ptr));
        const node = tree.getNode(node_idx) orelse return;

        switch (node.tag) {
            .class_stmt => try self.addMembers(engine, tree, tree.classStmt(node).body),
            .module_stmt => try self.addMembers(engine, tree, tree.moduleStmt(node).body),
            .singleton_class => try self.addMembers(engine, tree, tree.singletonClassPayload(node).body),
            .assignment => {
                const a = tree.assignment(node);
                const var_name = tree.getString(a.name);
                // `n += 1` reads n as well as writing it.
                if (a.op != null) {
                    try engine.markUsed(var_name);
                } else if (isLocal(var_name) and !self.members.contains(node_idx)) {
                    try engine.declareAssigned(var_name, engine.getLoc(node.main_token), true);
                }
            },
            .multiple_assignment => {
                const ma = tree.multipleAssignment(node);
                for (tree.getLhsExprs(ma.lhs)) |lhs| {
                    const var_name = tree.getString(lhs.name);
                    if (isLocal(var_name)) try engine.declareAssigned(var_name, engine.getLoc(node.main_token), false);
                }
            },
            .for_stmt => {
                // The loop opens no scope: its variables belong to the enclosing one.
                const fs = tree.forStmt(node);
                for (tree.getLhsExprs(fs.targets)) |t| {
                    try engine.declareAssigned(tree.getString(t.name), engine.getLoc(node.main_token), false);
                }
            },
            .export_stmt => {
                // A re-export (`export { a } from "./a.kup"`) names another file's `a`, not this one's
                const stmt = tree.exportStmt(node);
                if (stmt.path == .none) for (tree.getAliasPairs(stmt.symbols)) |pair| {
                    try engine.markUsed(tree.getString(pair.original));
                };
            },
            .def_stmt => {
                const ds = tree.defStmt(node);
                // Function names belong to the scope they are declared in
                if (!self.members.contains(node_idx)) try engine.declareVar(tree.getString(ds.name), engine.getLoc(node.main_token), false);
                try markResultUsed(engine, tree, ds.body);
            },
            .lambda_expr => try markResultUsed(engine, tree, tree.lambdaExpr(node).body),
            .block => {
                try self.declareMethods(engine, tree, node_idx);
                // The script's last statement is the model, and a call block's is its value.
                if (node_idx == engine.root or engine.closure_blocks.contains(node_idx)) try markResultUsed(engine, tree, node_idx);
            },
            .identifier => {
                try engine.markUsed(tree.getString(@as(ast.StringId, @fromBackingInt(node.data))));
            },
            .method_call => {
                const mc = tree.methodCall(node);
                try engine.markUsed(tree.getString(mc.method_name));
            },
            .super_call => if (tree.superCall(node).implicit_args) try self.markMethodParamsUsed(engine, tree),
            else => {},
        }
    }

    /// Declares the methods a body defines before any of its statements is checked: a call
    /// from a method defined above (`def a = b()` before `def b`) runs once both exist, and
    /// was lost, reporting `b` unused.
    fn declareMethods(self: *UnusedVarsRule, engine: *linter.Linter, tree: *const ast.Tree, body_idx: ast.NodeIndex) !void {
        const body = tree.getNode(body_idx) orelse return;
        for (tree.getNodes(tree.block(body).stmts)) |stmt| {
            const node = tree.getNode(stmt).?;
            if (node.tag != .def_stmt or self.members.contains(stmt)) continue;
            try engine.declareVar(tree.getString(tree.defStmt(node).name), engine.getLoc(node.main_token), false);
        }
    }

    /// Whether `name` is a local of the scope that assigns it. `@field`, `@@class_var` and
    /// `$global` outlive the method: one set in `initialize` and read in another method was
    /// reported unused unless it was the last statement.
    fn isLocal(name: []const u8) bool {
        return name.len > 0 and name[0] != '@' and name[0] != '$';
    }

    fn addMembers(self: *UnusedVarsRule, engine: *linter.Linter, tree: *const ast.Tree, body_idx: ast.NodeIndex) !void {
        const body = tree.getNode(body_idx) orelse return;
        if (body.tag != .block) return;
        for (tree.getNodes(tree.block(body).stmts)) |stmt| {
            const node = tree.getNode(stmt).?;
            const is_member = switch (node.tag) {
                .def_stmt => true,
                // A name the lexer makes a constant: it starts with a capital
                .assignment => std.ascii.isUpper(tree.getString(tree.assignment(node).name)[0]),
                else => false,
            };
            if (is_member) try self.members.put(engine.allocator, stmt, {});
        }
    }

    /// A body whose last statement is `name = value` hands that value back (the script's
    /// model, a method's or a block's result), so `name` is used: `part = box - drill` at
    /// the end of a script was reported unused.
    fn markResultUsed(engine: *linter.Linter, tree: *const ast.Tree, body_idx: ast.NodeIndex) !void {
        const body = tree.getNode(body_idx) orelse return;
        if (body.tag != .block) return;
        const stmts = tree.getNodes(tree.block(body).stmts);
        if (stmts.len == 0) return;
        const last = tree.getNode(stmts[stmts.len - 1]).?;
        if (last.tag != .assignment) return;
        const var_name = tree.getString(tree.assignment(last).name);
        try engine.declareAssigned(var_name, engine.getLoc(last.main_token), true);
        try engine.markUsed(var_name);
    }

    fn declareLhsBindings(engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        if (node_idx == .none) return;
        const node = tree.getNode(node_idx) orelse return;

        switch (node.tag) {
            .identifier => {
                try engine.declareVar(tree.getString(@as(ast.StringId, @fromBackingInt(node.data))), engine.getLoc(node.main_token), true);
            },
            .array_literal => {
                const span = tree.nodeSpan(node);
                for (tree.getNodes(span)) |elem_idx| {
                    try declareLhsBindings(engine, tree, elem_idx);
                }
            },
            .hash_literal => {
                const span = tree.nodeSpan(node);
                for (tree.getHashEntries(span)) |entry| {
                    try declareLhsBindings(engine, tree, entry.value);
                }
            },
            .splat_expr => {
                const inner = tree.nodeIndex(node);
                try declareLhsBindings(engine, tree, inner);
            },
            .double_splat_expr => {
                const inner = tree.nodeIndex(node);
                try declareLhsBindings(engine, tree, inner);
            },
            else => {},
        }
    }

    /// A bare `super` passes the method's parameters on, so they are used: a parameter
    /// only `super` hands on was reported unused.
    fn markMethodParamsUsed(self: *UnusedVarsRule, engine: *linter.Linter, tree: *const ast.Tree) !void {
        var i = self.scope_defs.items.len;
        const def_idx = while (i > 0) {
            i -= 1;
            if (self.scope_defs.items[i]) |idx| break idx;
        } else return;
        for (tree.getParams(tree.defStmt(tree.getNode(def_idx).?).params)) |p| try engine.markUsed(tree.getString(p.name));
    }

    fn enterScope(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const self: *UnusedVarsRule = @ptrCast(@alignCast(ptr));
        const node = tree.getNode(node_idx) orelse return;
        try self.scope_defs.append(engine.allocator, if (node.tag == .def_stmt) node_idx else null);

        // Variables declared here belong specifically to the newly pushed inner scope
        switch (node.tag) {
            .def_stmt => {
                const ds = tree.defStmt(node);
                for (tree.getParams(ds.params)) |p| {
                    try engine.declareVar(tree.getString(p.name), engine.getLoc(node.main_token), false);
                }
            },
            .lambda_expr => {
                const le = tree.lambdaExpr(node);
                for (tree.getParams(le.params)) |p| {
                    try engine.declareVar(tree.getString(p.name), engine.getLoc(node.main_token), false);
                }
            },
            .block => {
                const b = tree.block(node);
                for (tree.getNodes(b.params)) |p_idx| {
                    try declareLhsBindings(engine, tree, p_idx);
                }
            },
            else => {},
        }
    }

    fn exitScope(ptr: *anyopaque, scope: *const linter.Scope, engine: *linter.Linter) !void {
        const self: *UnusedVarsRule = @ptrCast(@alignCast(ptr));
        _ = self.scope_defs.pop();
        var iter = scope.declared_vars.iterator();

        while (iter.next()) |entry| {
            const var_name = entry.key_ptr.*;
            const binding = entry.value_ptr;

            // Flag if not used and doesn't start with an underscore (which marks intentional disuse)
            if (!scope.used_vars.contains(var_name) and (var_name.len == 0 or var_name[0] != '_')) {
                try engine.reportFix(id, binding.loc, try renameFix(engine, var_name, binding), "Unused variable '{s}'. Prefix with '_' if intentional.", .{var_name});
            }
        }
    }

    /// Renames every binding of the variable to `_name`, which says it is unused on purpose.
    /// None when a binding can't be renamed alone, or `_name` is already in the file (the
    /// rename would merge two variables).
    fn renameFix(engine: *linter.Linter, name: []const u8, binding: *const linter.Binding) !?linter.Fix {
        if (!binding.renamable or binding.sites.items.len == 0) return null;
        const allocator = engine.allocator;
        const new_name = try allocator.print("_{s}", .{name});
        defer allocator.free(new_name);
        if (try engine.sourceHasWord(new_name)) return null;

        const edits = try allocator.alloc(linter.Edit, binding.sites.items.len);
        var made: usize = 0;
        errdefer {
            for (edits[0..made]) |e| allocator.free(e.replacement);
            allocator.free(edits);
        }
        for (binding.sites.items, edits) |site, *edit| {
            edit.* = .{ .offset = site.offset, .length = site.length, .replacement = try allocator.dupe(u8, new_name) };
            made += 1;
        }
        return .{ .title = try allocator.print("Rename '{s}' to '{s}'", .{ name, new_name }), .edits = edits, .safe = true };
    }
};
