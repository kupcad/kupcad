const std = @import("std");
const ast = @import("../../core/ast.zig");
const token = @import("../../core/token.zig");
const lexer_mod = @import("../../frontend/kupcad/lexer.zig");
const parser_mod = @import("../../frontend/kupcad/parser.zig");
const LintRule = @import("rules/rule.zig").LintRule;
const NegativeDimRule = @import("rules/negative_dim.zig").NegativeDimRule;

pub const DiagnosticSeverity = enum {
    @"error",
    warning,
    info,
};

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
    diagnostics: std.ArrayListUnmanaged(LinterDiagnostic) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    param_docs: std.StringHashMapUnmanaged(token.Location) = .empty,
    rules: std.ArrayListUnmanaged(LintRule) = .empty,

    // Keep stateful rule instances alive for the lifetime of the Linter
    negative_dim_rule: NegativeDimRule = .{},

    pub fn init(allocator: std.mem.Allocator) !Linter {
        var linter = Linter{ .allocator = allocator };

        // Register default plugins
        try linter.rules.append(allocator, linter.negative_dim_rule.rule());

        return linter;
    }

    pub fn deinit(self: *Linter) void {
        for (self.diagnostics.items) |d| {
            self.allocator.free(d.message);
        }
        self.diagnostics.deinit(self.allocator);
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.param_docs.deinit(self.allocator);
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

        for (parser.diagnostics.list.items) |diag| {
            try self.addDiagnostic(diag.loc, diag.message, .@"error");
        }

        if (tree) |root| {
            try self.pushScope();
            try self.analyzeNode(root);
            try self.checkParamDocMatches();
            try self.popScope();
        }
    }

    fn addDiagnostic(self: *Linter, loc: token.Location, message: []const u8, severity: DiagnosticSeverity) !void {
        try self.diagnostics.append(self.allocator, .{
            .loc = loc,
            .message = try self.allocator.dupe(u8, message),
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

            var var_iter = scope.declared_vars.iterator();
            while (var_iter.next()) |entry| {
                const var_name = entry.key_ptr.*;
                if (!scope.used_vars.contains(var_name) and var_name[0] != '_') {
                    const msg = try std.fmt.allocPrint(self.allocator, "Unused variable '{s}'. Prefix with '_' if intentional.", .{var_name});
                    defer self.allocator.free(msg);
                    try self.addDiagnostic(entry.value_ptr.*, msg, .warning);
                }
            }
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
        // 1. Fire all registered Linter plugins against this node
        for (self.rules.items) |rule| {
            try rule.checkNode(node, &self.diagnostics, self.allocator);
        }

        // 2. Stateful Analysis & AST Traversal Recursive Pass
        switch (node.kind) {
            .block => |b| {
                var unreachable_found = false;
                for (b.stmts) |stmt| {
                    if (unreachable_found) {
                        try self.addDiagnostic(stmt.loc, "Unreachable code detected after explicit control flow return/break.", .warning);
                    }
                    try self.analyzeNode(stmt);
                    if (stmt.kind == .return_stmt or stmt.kind == .break_stmt or stmt.kind == .next_stmt) {
                        unreachable_found = true;
                    }
                }
            },
            .assignment => |a| {
                try self.declareVariable(a.name, node.loc);
                try self.analyzeNode(a.value);
            },
            .property_assignment => |pa| {
                try self.analyzeNode(pa.target);
                try self.analyzeNode(pa.value);
            },
            .identifier => |i| {
                self.markVariableUsed(i);
            },
            .method_call => |mc| {
                if (mc.receiver) |r| try self.analyzeNode(r);
                for (mc.args) |arg| try self.analyzeNode(arg.value);
                if (mc.block) |b| try self.analyzeNode(b);
            },
            .binary_op => |b| {
                try self.analyzeNode(b.left);
                try self.analyzeNode(b.right);
                if (b.op == .subtract) {
                    if (b.left.kind == .identifier and b.right.kind == .identifier) {
                        if (std.mem.eql(u8, b.left.kind.identifier, b.right.kind.identifier)) {
                            try self.addDiagnostic(node.loc, "CSG Warning: Self-difference operation ('a - a') will result in empty geometry.", .warning);
                        }
                    }
                }
            },
            .param_doc => |doc| {
                if (doc.target_name) |target| {
                    try self.param_docs.put(self.allocator, target, node.loc);
                }
            },
            .if_stmt => |ifs| {
                try self.analyzeNode(ifs.condition);
                try self.analyzeNode(ifs.then_branch);
                if (ifs.else_branch) |eb| try self.analyzeNode(eb);
            },
            .def_stmt => |def| {
                try self.pushScope();
                for (def.params) |p| try self.declareVariable(p.name, node.loc);
                try self.analyzeNode(def.body);
                try self.popScope();
            },
            else => {},
        }
    }

    fn checkParamDocMatches(self: *Linter) !void {
        var doc_iter = self.param_docs.iterator();
        while (doc_iter.next()) |entry| {
            const param_name = entry.key_ptr.*;
            if (self.scopes.items.len > 0) {
                const root_scope = &self.scopes.items[0];
                if (!root_scope.declared_vars.contains(param_name)) {
                    const msg = try std.fmt.allocPrint(self.allocator, "@param annotation references variable '{s}', which is never declared in standard scope.", .{param_name});
                    defer self.allocator.free(msg);
                    try self.addDiagnostic(entry.value_ptr.*, msg, .info);
                }
            }
        }
    }
};
