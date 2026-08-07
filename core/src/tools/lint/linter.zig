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

        // Run exit hooks (like UnusedVars missing usage checks)
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

    fn walk(self: *Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const visitor = ast.Visitor{
            .ptr = self,
            .visitFn = visitNode,
        };
        try visitor.walk(tree, node_idx);
    }

    fn visitNode(ptr: *anyopaque, tree: *const ast.Tree, node_idx: ast.NodeIndex) anyerror!bool {
        var self = @as(*Linter, @ptrCast(@alignCast(ptr)));
        const node = tree.getNode(node_idx) orelse return true;

        for (self.rules.items) |rule| {
            try rule.checkNode(self, tree, node_idx);
        }

        // Handle AST nodes that spawn a new lexical scope
        switch (node.kind) {
            .block => |b| {
                try self.pushScope();
                for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                // We intentionally do NOT walk `b.params` here so rules do not flag parameter declarations as usages.
                for (tree.getNodes(b.stmts)) |s| try self.walk(tree, s);
                try self.popScope();
                return false;
            },
            .lambda_expr => |le| {
                try self.pushScope();
                for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                for (tree.getParams(le.params)) |p| {
                    if (p.default_value != .none) try self.walk(tree, p.default_value);
                }
                try self.walk(tree, le.body);
                try self.popScope();
                return false;
            },
            .for_stmt => |fs| {
                try self.pushScope();
                for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                for (tree.getForBindings(fs.bindings)) |b| try self.walk(tree, b.range);
                try self.walk(tree, fs.body);
                try self.popScope();
                return false;
            },
            .while_stmt => |ws| {
                try self.pushScope();
                for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                try self.walk(tree, ws.condition);
                try self.walk(tree, ws.body);
                try self.popScope();
                return false;
            },
            .def_stmt => |ds| {
                try self.pushScope();
                for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                for (tree.getParams(ds.params)) |p| {
                    if (p.default_value != .none) try self.walk(tree, p.default_value);
                }
                try self.walk(tree, ds.body);
                try self.popScope();
                return false;
            },
            .class_stmt => |cs| {
                try self.pushScope();
                for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                try self.walk(tree, cs.name);
                try self.walk(tree, cs.super_class);
                try self.walk(tree, cs.body);
                try self.popScope();
                return false;
            },
            .module_stmt => |ms| {
                try self.pushScope();
                for (self.rules.items) |rule| try rule.enterScope(self, tree, node_idx);
                for (tree.getParams(ms.params)) |p| {
                    if (p.default_value != .none) try self.walk(tree, p.default_value);
                }
                try self.walk(tree, ms.body);
                try self.popScope();
                return false;
            },
            else => return true,
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

        try self.pushScope();
        try self.walk(tree, root);

        for (self.rules.items) |rule| {
            try rule.checkEOF(self);
        }

        try self.popScope();
    }
};
