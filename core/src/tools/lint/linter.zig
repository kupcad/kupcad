const std = @import("std");
const ast = @import("../../core/ast.zig");
const token = @import("../../core/token.zig");
const common_errors = @import("../../core/errors.zig");
const Config = @import("config.zig").Config;
const LintRule = @import("rules/rule.zig").LintRule;

const NegativeDimRule = @import("rules/negative_dim.zig").NegativeDimRule;
const UnusedVarsRule = @import("rules/unused_vars.zig").UnusedVarsRule;
const UnreachableCodeRule = @import("rules/unreachable_code.zig").UnreachableCodeRule;
const SelfSubtractionRule = @import("rules/self_subtraction.zig").SelfSubtractionRule;
const ParamDocsRule = @import("rules/param_docs.zig").ParamDocsRule;

pub const LinterSeverity = enum {
    @"error",
    warning,
    info,

    pub fn toString(self: LinterSeverity) []const u8 {
        return @tagName(self);
    }
    pub fn toColor(self: LinterSeverity) []const u8 {
        return switch (self) {
            .@"error" => "\x1b[31m",
            .warning => "\x1b[33m",
            .info => "\x1b[36m",
        };
    }
    pub fn toChar(self: LinterSeverity) []const u8 {
        return switch (self) {
            .@"error" => "E",
            .warning => "W",
            .info => "I",
        };
    }
};

pub const LinterDiagnostic = struct {
    loc: token.Location,
    severity: LinterSeverity,
    message: []const u8,
};

pub const Scope = struct {
    declared_vars: std.StringHashMapUnmanaged(token.Location) = .empty,
    used_vars: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.declared_vars.deinit(allocator);
        self.used_vars.deinit(allocator);
    }
};

pub const WorkItem = union(enum) {
    visit: ast.NodeIndex,
    pop_scope,
};

pub const Linter = struct {
    allocator: std.mem.Allocator,
    config: Config,
    diagnostics: std.ArrayListUnmanaged(LinterDiagnostic) = .empty,
    rules: std.ArrayListUnmanaged(LintRule) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,

    // Rule instances
    rule_negative_dim: NegativeDimRule = .{},
    rule_unused_vars: UnusedVarsRule = .{},
    rule_unreachable_code: UnreachableCodeRule = .{},
    rule_self_subtraction: SelfSubtractionRule = .{},
    rule_param_docs: ParamDocsRule = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config) Linter {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Linter) void {
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        for (self.diagnostics.items) |d| self.allocator.free(d.message);
        self.diagnostics.deinit(self.allocator);
    }

    pub fn registerDefaultRules(self: *Linter) !void {
        if (self.config.check_negative_dims) try self.rules.append(self.allocator, self.rule_negative_dim.rule());
        if (self.config.check_unused_vars) try self.rules.append(self.allocator, self.rule_unused_vars.rule());
        if (self.config.check_unreachable_code) try self.rules.append(self.allocator, self.rule_unreachable_code.rule());
        if (self.config.check_self_subtraction) try self.rules.append(self.allocator, self.rule_self_subtraction.rule());
        if (self.config.check_param_docs) try self.rules.append(self.allocator, self.rule_param_docs.rule());
    }

    pub fn addDiagnostic(self: *Linter, loc: token.Location, severity: LinterSeverity, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.diagnostics.append(self.allocator, .{
            .loc = loc,
            .severity = severity,
            .message = msg,
        });
    }

    pub fn pushScope(self: *Linter) !void {
        try self.scopes.append(self.allocator, .{});
    }

    pub fn popScope(self: *Linter) !void {
        if (self.scopes.items.len == 0) return;

        const last_idx = self.scopes.items.len - 1;
        const scope_ptr = &self.scopes.items[last_idx];

        for (self.rules.items) |rule| {
            try rule.exitScope(scope_ptr, self);
        }

        scope_ptr.deinit(self.allocator);
        self.scopes.items.len -= 1;
    }

    pub fn declareVar(self: *Linter, name: []const u8, loc: token.Location) !void {
        if (self.scopes.items.len > 0) {
            const scope = &self.scopes.items[self.scopes.items.len - 1];
            try scope.declared_vars.put(self.allocator, name, loc);
        }
    }

    pub fn markUsed(self: *Linter, name: []const u8) !void {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            if (scope.declared_vars.contains(name)) {
                try scope.used_vars.put(self.allocator, name, {});
                return;
            }
        }
    }

    inline fn pushNode(stack: *std.ArrayListUnmanaged(WorkItem), allocator: std.mem.Allocator, node_idx: ast.NodeIndex) !void {
        if (node_idx != .none) {
            try stack.append(allocator, .{ .visit = node_idx });
        }
    }

    inline fn pushNodesReverse(stack: *std.ArrayListUnmanaged(WorkItem), allocator: std.mem.Allocator, nodes: []const ast.NodeIndex) !void {
        var i: usize = nodes.len;
        while (i > 0) {
            i -= 1;
            try pushNode(stack, allocator, nodes[i]);
        }
    }

    pub fn check(self: *Linter, tree: *const ast.Tree, root: ast.NodeIndex, parser_diagnostics: []const common_errors.Diagnostic) !void {
        for (parser_diagnostics) |diag| {
            try self.diagnostics.append(self.allocator, .{
                .loc = diag.loc,
                .severity = .@"error",
                .message = try self.allocator.dupe(u8, diag.message),
            });
        }

        if (root == .none) return;

        var stack: std.ArrayListUnmanaged(WorkItem) = .empty;
        defer stack.deinit(self.allocator);

        try self.pushScope();
        try pushNode(&stack, self.allocator, root);

        while (stack.pop()) |item| {
            switch (item) {
                .pop_scope => {
                    try self.popScope();
                },
                .visit => |node_idx| {
                    if (node_idx == .none) continue;
                    const node = tree.getNode(node_idx) orelse continue;

                    for (self.rules.items) |rule| {
                        try rule.checkNode(self, tree, node_idx);
                    }

                    switch (node.tag) {
                        .block => {
                            const b = tree.blocks.items[node.data];
                            try self.pushScope();
                            for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                            try stack.append(self.allocator, .pop_scope);
                            try pushNodesReverse(&stack, self.allocator, tree.getNodes(b.stmts));
                        },
                        .lambda_expr => {
                            const le = tree.lambda_exprs.items[node.data];
                            try self.pushScope();
                            for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                            try stack.append(self.allocator, .pop_scope);
                            try pushNode(&stack, self.allocator, le.body);
                            const params = tree.getParams(le.params);
                            var i: usize = params.len;
                            while (i > 0) {
                                i -= 1;
                                try pushNode(&stack, self.allocator, params[i].default_value);
                            }
                        },
                        .for_stmt => {
                            const fs = tree.for_stmts.items[node.data];
                            try self.pushScope();
                            for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                            try stack.append(self.allocator, .pop_scope);
                            try pushNode(&stack, self.allocator, fs.body);
                            const bindings = tree.getForBindings(fs.bindings);
                            var i: usize = bindings.len;
                            while (i > 0) {
                                i -= 1;
                                try pushNode(&stack, self.allocator, bindings[i].range);
                            }
                        },
                        .while_stmt => {
                            const ws = tree.while_stmts.items[node.data];
                            try self.pushScope();
                            for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                            try stack.append(self.allocator, .pop_scope);
                            try pushNode(&stack, self.allocator, ws.body);
                            try pushNode(&stack, self.allocator, ws.condition);
                        },
                        .def_stmt => {
                            const ds = tree.def_stmts.items[node.data];
                            try self.pushScope();
                            for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                            try stack.append(self.allocator, .pop_scope);
                            try pushNode(&stack, self.allocator, ds.body);
                            const params = tree.getParams(ds.params);
                            var i: usize = params.len;
                            while (i > 0) {
                                i -= 1;
                                try pushNode(&stack, self.allocator, params[i].default_value);
                            }
                        },
                        .class_stmt => {
                            const cs = tree.class_stmts.items[node.data];
                            try self.pushScope();
                            for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                            try stack.append(self.allocator, .pop_scope);
                            try pushNode(&stack, self.allocator, cs.body);
                            try pushNode(&stack, self.allocator, cs.super_class);
                            try pushNode(&stack, self.allocator, cs.name);
                        },
                        .module_stmt => {
                            const ms = tree.module_stmts.items[node.data];
                            try self.pushScope();
                            for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                            try stack.append(self.allocator, .pop_scope);
                            try pushNode(&stack, self.allocator, ms.body);
                            const params = tree.getParams(ms.params);
                            var i: usize = params.len;
                            while (i > 0) {
                                i -= 1;
                                try pushNode(&stack, self.allocator, params[i].default_value);
                            }
                        },

                        // Non-scope opening nodes
                        .number, .string, .symbol, .boolean, .nil, .undef, .self_expr, .identifier, .namespace_access => {},
                        .param_doc => {
                            const doc = tree.param_docs.items[node.data];
                            try pushNode(&stack, self.allocator, doc.options_expr);
                        },
                        .interpolated_string => {
                            const span = tree.getSpan(node.data);
                            try pushNodesReverse(&stack, self.allocator, tree.getNodes(span));
                        },
                        .array_literal => {
                            const span = tree.getSpan(node.data);
                            try pushNodesReverse(&stack, self.allocator, tree.getNodes(span));
                        },
                        .hash_literal => {
                            const span = tree.getSpan(node.data);
                            const entries = tree.getHashEntries(span);
                            var i: usize = entries.len;
                            while (i > 0) {
                                i -= 1;
                                try pushNode(&stack, self.allocator, entries[i].value);
                                try pushNode(&stack, self.allocator, entries[i].key);
                            }
                        },
                        .range => {
                            const r = tree.ranges.items[node.data];
                            try pushNode(&stack, self.allocator, r.step);
                            try pushNode(&stack, self.allocator, r.end);
                            try pushNode(&stack, self.allocator, r.start);
                        },
                        .assignment => {
                            const a = tree.assignment(node).*;
                            try pushNode(&stack, self.allocator, a.value);
                        },
                        .multiple_assignment => {
                            const ma = tree.multiple_assignments.items[node.data];
                            try pushNode(&stack, self.allocator, ma.value);
                        },
                        .property_assignment => {
                            const pa = tree.property_assignments.items[node.data];
                            try pushNode(&stack, self.allocator, pa.value);
                            try pushNode(&stack, self.allocator, pa.target);
                        },
                        .index_assignment => {
                            const ia = tree.index_assignments.items[node.data];
                            try pushNode(&stack, self.allocator, ia.value);
                            try pushNode(&stack, self.allocator, ia.index);
                            try pushNode(&stack, self.allocator, ia.target);
                        },
                        .unary_op => {
                            const u = tree.unaryExpr(node).*;
                            try pushNode(&stack, self.allocator, u.operand);
                        },
                        .rescue_modifier => {
                            const rm = tree.rescue_modifiers.items[node.data];
                            try pushNode(&stack, self.allocator, rm.rescue_expr);
                            try pushNode(&stack, self.allocator, rm.expr);
                        },
                        .binary_op => {
                            const b = tree.binaryExpr(node).*;
                            try pushNode(&stack, self.allocator, b.right);
                            try pushNode(&stack, self.allocator, b.left);
                        },
                        .ternary_op => {
                            const t = tree.ternary_exprs.items[node.data];
                            try pushNode(&stack, self.allocator, t.else_branch);
                            try pushNode(&stack, self.allocator, t.then_branch);
                            try pushNode(&stack, self.allocator, t.condition);
                        },
                        .index_access => {
                            const ia = tree.index_accesses.items[node.data];
                            try pushNode(&stack, self.allocator, ia.index);
                            try pushNode(&stack, self.allocator, ia.target);
                        },
                        .splat_expr => {
                            const s = @as(ast.NodeIndex, @enumFromInt(node.data));
                            try pushNode(&stack, self.allocator, s);
                        },
                        .double_splat_expr => {
                            const s = @as(ast.NodeIndex, @enumFromInt(node.data));
                            try pushNode(&stack, self.allocator, s);
                        },
                        .each_expr => {
                            const e = @as(ast.NodeIndex, @enumFromInt(node.data));
                            try pushNode(&stack, self.allocator, e);
                        },
                        .method_call => {
                            const mc = tree.methodCall(node).*;
                            try pushNode(&stack, self.allocator, mc.block);
                            const args = tree.getNamedArgs(mc.args);
                            var i: usize = args.len;
                            while (i > 0) {
                                i -= 1;
                                try pushNode(&stack, self.allocator, args[i].value);
                            }
                            try pushNode(&stack, self.allocator, mc.receiver);
                        },
                        .super_call => {
                            const sc = tree.super_calls.items[node.data];
                            try pushNode(&stack, self.allocator, sc.block);
                            const args = tree.getNamedArgs(sc.args);
                            var i: usize = args.len;
                            while (i > 0) {
                                i -= 1;
                                try pushNode(&stack, self.allocator, args[i].value);
                            }
                        },
                        .import_stmt => {
                            const is_stmt = tree.import_stmts.items[node.data];
                            try pushNode(&stack, self.allocator, is_stmt.attributes);
                        },
                        .export_stmt => {
                            const es_stmt = tree.export_stmts.items[node.data];
                            try pushNode(&stack, self.allocator, es_stmt.attributes);
                        },
                        .if_stmt => {
                            const ifs = tree.ifStmt(node).*;
                            try pushNode(&stack, self.allocator, ifs.else_branch);
                            try pushNode(&stack, self.allocator, ifs.then_branch);
                            try pushNode(&stack, self.allocator, ifs.condition);
                        },
                        .case_stmt => {
                            const cs = tree.case_stmts.items[node.data];
                            try pushNode(&stack, self.allocator, cs.else_branch);
                            const branches = tree.getWhenBranches(cs.when_branches);
                            var i: usize = branches.len;
                            while (i > 0) {
                                i -= 1;
                                try pushNode(&stack, self.allocator, branches[i].body);
                                try pushNodesReverse(&stack, self.allocator, tree.getNodes(branches[i].conditions));
                            }
                            try pushNode(&stack, self.allocator, cs.condition);
                        },
                        .begin_stmt => {
                            const bs = tree.begin_stmts.items[node.data];
                            try pushNode(&stack, self.allocator, bs.ensure_body);
                            const rescues = tree.getRescueClauses(bs.rescues);
                            var i: usize = rescues.len;
                            while (i > 0) {
                                i -= 1;
                                try pushNode(&stack, self.allocator, rescues[i].body);
                            }
                            try pushNode(&stack, self.allocator, bs.body);
                        },
                        .return_stmt => {
                            const r = @as(ast.NodeIndex, @enumFromInt(node.data));
                            try pushNode(&stack, self.allocator, r);
                        },
                        .yield_stmt => {
                            const span = tree.getSpan(node.data);
                            try pushNodesReverse(&stack, self.allocator, tree.getNodes(span));
                        },
                        .break_stmt => {
                            const b = @as(ast.NodeIndex, @enumFromInt(node.data));
                            try pushNode(&stack, self.allocator, b);
                        },
                        .next_stmt => {
                            const n = @as(ast.NodeIndex, @enumFromInt(node.data));
                            try pushNode(&stack, self.allocator, n);
                        },
                    }
                },
            }
        }

        for (self.rules.items) |rule| {
            try rule.checkEOF(self);
        }

        try self.popScope();
    }
};
