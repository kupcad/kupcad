const std = @import("std");
const ast = @import("../../core/ast.zig");
const token = @import("../../core/token.zig");
const lexer_mod = @import("../../frontend/kupcad/lexer.zig");
const parser_mod = @import("../../frontend/kupcad/parser.zig");
const LintRule = @import("rules/rule.zig").LintRule;
const Config = @import("config.zig").Config;

// Import our decoupled plugins
const NegativeDimRule = @import("rules/negative_dim.zig").NegativeDimRule;
const UnusedVarsRule = @import("rules/unused_vars.zig").UnusedVarsRule;
const UnreachableCodeRule = @import("rules/unreachable_code.zig").UnreachableCodeRule;
const SelfSubtractionRule = @import("rules/self_subtraction.zig").SelfSubtractionRule;
const ParamDocsRule = @import("rules/param_docs.zig").ParamDocsRule;

pub const DiagnosticSeverity = enum { @"error", warning, info };

pub const LinterDiagnostic = struct {
    loc: token.Location,
    message: []const u8,
    severity: DiagnosticSeverity,
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
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    rules: std.ArrayListUnmanaged(LintRule) = .empty,

    // Rule persistent states
    negative_dim_rule: NegativeDimRule = .{},
    unused_vars_rule: UnusedVarsRule = .{},
    unreachable_code_rule: UnreachableCodeRule = .{},
    self_subtraction_rule: SelfSubtractionRule = .{},
    param_docs_rule: ParamDocsRule = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config) Linter {
        return Linter{ .allocator = allocator, .config = config };
    }

    pub fn registerDefaultRules(self: *Linter) !void {
        if (self.config.check_negative_dims) try self.rules.append(self.allocator, self.negative_dim_rule.rule());
        if (self.config.check_unused_vars) try self.rules.append(self.allocator, self.unused_vars_rule.rule());
        if (self.config.check_unreachable_code) try self.rules.append(self.allocator, self.unreachable_code_rule.rule());
        if (self.config.check_self_subtraction) try self.rules.append(self.allocator, self.self_subtraction_rule.rule());
        if (self.config.check_param_docs) try self.rules.append(self.allocator, self.param_docs_rule.rule());
    }

    pub fn deinit(self: *Linter) void {
        for (self.diagnostics.items) |d| self.allocator.free(d.message);
        self.diagnostics.deinit(self.allocator);
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.rules.deinit(self.allocator);
    }

    pub fn check(self: *Linter, source: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var lexer = lexer_mod.Lexer.init(source, 0);
        var parser = parser_mod.Parser.init(&lexer, arena.allocator());

        const tree: ?*ast.Node = parser.parseProgram() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };

        // Format and copy Parser syntax errors into the Linter Diagnostics Array
        for (parser.diagnostics.list.items) |diag| {
            try self.addDiagnostic(diag.loc, .@"error", "{s}", .{diag.message});
        }

        if (tree) |root| {
            try self.pushScope();
            try self.analyzeNode(root);
            try self.popScope();

            // Fire EOF Hook on all plugins
            for (self.rules.items) |rule| try rule.checkEOF(self);
        }
    }

    // DRY: Unified formatting diagnostic helper for all plugins!
    pub fn addDiagnostic(self: *Linter, loc: token.Location, severity: DiagnosticSeverity, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.diagnostics.append(self.allocator, .{
            .loc = loc,
            .message = msg,
            .severity = severity,
        });
    }

    fn pushScope(self: *Linter) !void {
        try self.scopes.append(self.allocator, Scope{});
    }

    fn popScope(self: *Linter) !void {
        if (self.scopes.items.len > 0) {
            var scope = self.scopes.items[self.scopes.items.len - 1];
            self.scopes.shrinkRetainingCapacity(self.scopes.items.len - 1);

            // Fire exitScope hook on all plugins
            for (self.rules.items) |rule| try rule.exitScope(&scope, self);
            scope.deinit(self.allocator);
        }
    }

    fn declareVariable(self: *Linter, name: []const u8, loc: token.Location) !void {
        if (self.scopes.items.len > 0) {
            const current = &self.scopes.items[self.scopes.items.len - 1];
            try current.declared_vars.put(self.allocator, name, loc);
        }
    }

    fn markVariableUsed(self: *Linter, name: []const u8) void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            var scope = &self.scopes.items[i];
            if (scope.declared_vars.contains(name)) {
                scope.used_vars.put(self.allocator, name, {}) catch {};
                break;
            }
        }
    }

    fn analyzeNode(self: *Linter, node: *ast.Node) !void {
        var visitor = ast.Visitor{
            .ptr = self,
            .visitFn = visitNode,
        };
        try visitor.walk(node);
    }

    fn visitNode(ptr: *anyopaque, node: *ast.Node) anyerror!bool {
        const self = @as(*Linter, @ptrCast(@alignCast(ptr)));

        // Fire all registered Linter plugins against this node
        for (self.rules.items) |rule| try rule.checkNode(node, self);

        // Handle specific nodes that require strict Scope management or ordering
        switch (node.kind) {
            .assignment => |a| {
                try self.analyzeNode(a.value);
                try self.declareVariable(a.name, node.loc);
                return false; // Skip default child traversal
            },
            .multiple_assignment => |ma| {
                try self.analyzeNode(ma.value);
                for (ma.lhs) |l| try self.declareVariable(l.name, node.loc);
                return false;
            },
            .identifier => |i| {
                self.markVariableUsed(i);
                return true;
            },
            .for_stmt => |fs| {
                try self.pushScope();
                for (fs.bindings) |b| {
                    try self.analyzeNode(b.range);
                    try self.declareVariable(b.name, node.loc);
                }
                try self.analyzeNode(fs.body);
                try self.popScope();
                return false;
            },
            .begin_stmt => |bs| {
                try self.analyzeNode(bs.body);
                for (bs.rescues) |r| {
                    try self.pushScope();
                    if (r.variable) |v| try self.declareVariable(v, node.loc);
                    try self.analyzeNode(r.body);
                    try self.popScope();
                }
                if (bs.ensure_body) |eb| try self.analyzeNode(eb);
                return false;
            },
            .def_stmt => |def| {
                try self.pushScope();
                for (def.params) |p| try self.declareVariable(p.name, node.loc);
                try self.analyzeNode(def.body);
                try self.popScope();
                return false;
            },
            .lambda_expr => |le| {
                try self.pushScope();
                for (le.params) |p| try self.declareVariable(p.name, node.loc);
                try self.analyzeNode(le.body);
                try self.popScope();
                return false;
            },
            else => {}, // Yield to the fallback return
        }

        // Default behavior: automatically traverse children
        return true;
    }
};
