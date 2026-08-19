const std = @import("std");
const ast = @import("../../core/ast.zig");
const token = @import("../../core/token.zig");
const common_errors = @import("../../core/errors.zig");
const Config = @import("config.zig").Config;
const LintRule = @import("rules/rule.zig").LintRule;
const visitor = @import("../../core/visitor.zig");

const NegativeDimRule = @import("rules/negative_dim.zig").NegativeDimRule;
const UnusedVarsRule = @import("rules/unused_vars.zig").UnusedVarsRule;
const UnreachableCodeRule = @import("rules/unreachable_code.zig").UnreachableCodeRule;
const SelfSubtractionRule = @import("rules/self_subtraction.zig").SelfSubtractionRule;

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

pub fn isScopeNode(tag: ast.Tag) bool {
    return switch (tag) {
        .block, .lambda_expr, .for_stmt, .while_stmt, .def_stmt, .class_stmt, .module_stmt => true,
        else => false,
    };
}

const LintContext = struct {
    linter: *Linter,

    pub fn enterNode(self: *LintContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;

        // 1. Trigger general lint rules
        for (self.linter.rules.items) |rule| try rule.checkNode(self.linter, tree, node_idx);

        // 2. Open a new scope if we entered a block or function
        if (isScopeNode(node.tag)) {
            try self.linter.pushScope();
            for (self.linter.rules.items) |rule| try rule.enterScope(self.linter, tree, node_idx);
        }
    }

    pub fn leaveNode(self: *LintContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;

        // Close the scope now that all children have been traversed
        if (isScopeNode(node.tag)) {
            try self.linter.popScope();
        }
    }
};

pub const Linter = struct {
    allocator: std.mem.Allocator,
    config: Config,
    diagnostics: std.ArrayListUnmanaged(LinterDiagnostic) = .empty,
    rules: std.ArrayListUnmanaged(LintRule) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,

    // Token location lookup
    token_starts: []const u32 = &.{},
    token_lengths: []const u32 = &.{},
    file_id: u32 = 0,

    // Rule instances
    rule_negative_dim: NegativeDimRule = .{},
    rule_unused_vars: UnusedVarsRule = .{},
    rule_unreachable_code: UnreachableCodeRule = .{},
    rule_self_subtraction: SelfSubtractionRule = .{},

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
    }

    pub fn getLoc(self: *const Linter, main_token: u24) token.Location {
        if (main_token >= self.token_starts.len) return .{ .offset = 0, .length = 0, .file_id = self.file_id };
        return .{
            .offset = self.token_starts[main_token],
            .length = self.token_lengths[main_token],
            .file_id = self.file_id,
        };
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

    pub fn check(self: *Linter, tree: *const ast.Tree, token_starts: []const u32, token_lengths: []const u32, root: ast.NodeIndex, parser_diagnostics: []const common_errors.Diagnostic) !void {
        self.token_starts = token_starts;
        self.token_lengths = token_lengths;

        for (parser_diagnostics) |diag| {
            try self.diagnostics.append(self.allocator, .{
                .loc = diag.loc,
                .severity = .@"error",
                .message = try self.allocator.dupe(u8, diag.message),
            });
        }

        if (root == .none) return;

        // Establish the global scope
        try self.pushScope();

        // Automatically walk the AST
        var ctx = LintContext{ .linter = self };
        try visitor.walk(LintContext, &ctx, tree, root);

        // Conclude linting
        for (self.rules.items) |rule| {
            try rule.checkEOF(self);
        }
        try self.popScope();
    }
};
