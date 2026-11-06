//! `Resolver`: walks the AST once and records, per node, whether a name is a local, an
//! upvalue (a local of an enclosing def, lambda or class body), a global or an instance
//! variable (`ScopeKind`) and, for a local or an upvalue, the node that declared it
//! (`declarations`: the assignment, the `def`, lambda or block whose parameter it is, the
//! `for`); it also reports `break` and `next` outside a loop, and a name the top level reads
//! or exports where only a line further down sets it. Run by `frontend/document.zig`.
//!
//! It scopes names as the parser, the linter and the compiler do: a def, lambda, class or
//! module body, and a call's block, see the names around them (a closure's as upvalues) and
//! drop their own at their end; an `if`, `while`, `case` or `begin` body doesn't scope. Slots
//! and captures are the compiler's (compiler/scope.zig), which only asks a name's kind.

const std = @import("std");
const ast = @import("ast.zig");
const visitor = @import("visitor.zig");
const errors = @import("errors.zig");
const token = @import("token.zig");
const identifier = @import("identifier.zig");

pub const ScopeKind = enum(u8) {
    unresolved,
    local,
    upvalue,
    global,
    instance_var,
};

const Scope = struct {
    /// What opened it: the def, lambda, class, module or call's block; .none for the script.
    node: ast.NodeIndex,
    /// The locals it declares, and the node that declared each: its first assignment, its
    /// `def`, ...
    declared_by: std.AutoHashMapUnmanaged(ast.StringId, ast.NodeIndex) = .empty,
    /// A def, lambda, class, module or the script, past which a local is an upvalue; else
    /// a call's block, which sees the locals around it as its own.
    is_closure: bool,
    saved_loop_depth: usize = 0,

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.declared_by.deinit(allocator);
    }
};

/// A name the top level reads (`node` an identifier) or exports (an `export`) where nothing
/// has set it yet.
const EarlyUse = struct { name: ast.StringId, node: ast.NodeIndex, use: enum { read, @"export" } };

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,
    token_starts: []const u32,
    token_lengths: []const u32,

    symbols: []ScopeKind,
    /// Per node: for a name that is a local or an upvalue, the node that declared it;
    /// .none for anything else.
    declarations: []ast.NodeIndex,

    /// The blocks given to the calls being walked: the only blocks that open a scope.
    active_method_blocks: std.AutoHashMapUnmanaged(ast.NodeIndex, void) = .empty,

    scopes: std.ArrayList(Scope) = .empty,
    diagnostics: *errors.Diagnostics,
    loop_depth: usize = 0,
    /// The names the top level has set so far, in source order: assigned, defined, imported.
    top_level_names: std.AutoHashMapUnmanaged(ast.StringId, void) = .empty,
    /// Reads and exports that came before their names were set, an error if the file sets
    /// them later.
    early_uses: std.ArrayList(EarlyUse) = .empty,

    pub fn init(allocator: std.mem.Allocator, tree: *const ast.Tree, token_starts: []const u32, token_lengths: []const u32, diagnostics: *errors.Diagnostics) !Resolver {
        const symbols = try allocator.alloc(ScopeKind, tree.nodes.items.len);
        errdefer allocator.free(symbols);
        @memset(symbols, .unresolved);
        const declarations = try allocator.alloc(ast.NodeIndex, tree.nodes.items.len);
        @memset(declarations, .none);

        return .{
            .allocator = allocator,
            .tree = tree,
            .token_starts = token_starts,
            .token_lengths = token_lengths,
            .symbols = symbols,
            .declarations = declarations,
            .diagnostics = diagnostics,
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.active_method_blocks.deinit(self.allocator);
        self.top_level_names.deinit(self.allocator);
        self.early_uses.deinit(self.allocator);

        for (self.scopes.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.allocator.free(self.symbols);
        self.allocator.free(self.declarations);
    }

    pub fn resolve(self: *Resolver, root: ast.NodeIndex) !void {
        if (root == .none) return;
        try self.pushScope(true, .none);

        var ctx = ResolverContext{ .resolver = self };
        try visitor.walk(ResolverContext, &ctx, self.tree, root);

        self.popScope();
        self.reportEarlyUses();
    }

    /// Whether the walk is at the top level: not in a method, class or a call's block (an
    /// `if` or a loop opens no scope).
    fn atTopLevel(self: *const Resolver) bool {
        return self.scopes.items.len == 1;
    }

    /// Records `name` as set, when the top level sets it.
    fn noteTopLevel(self: *Resolver, name: ast.StringId) !void {
        if (self.atTopLevel()) try self.top_level_names.put(self.allocator, name, {});
    }

    /// Records the top level's read of `name` at `node` (an identifier, resolved) if nothing
    /// has set it yet. Not in a loop, whose body may read what its last pass set, nor in a
    /// method or block, which may run later.
    fn noteRead(self: *Resolver, name: ast.StringId, node: ast.NodeIndex) !void {
        if (self.loop_depth > 0 or !self.atTopLevel()) return;
        if (self.symbols[@backingInt(node)] != .global or self.top_level_names.contains(name)) return;
        try self.early_uses.append(self.allocator, .{ .name = name, .node = node, .use = .read });
    }

    /// A read or an export of a name set only further down found it unset where it stands:
    /// "Undefined variable", which reads as though the file never set it. A name the file
    /// never sets (a typo, a built-in) is left to the run, which says so.
    fn reportEarlyUses(self: *Resolver) void {
        for (self.early_uses.items) |early| {
            if (!self.top_level_names.contains(early.name)) continue;
            const node = self.tree.getNode(early.node).?;
            const at: token.Location = .{ .offset = self.token_starts[node.main_token], .length = self.token_lengths[node.main_token], .file_id = 0 };
            const name = self.tree.getString(early.name);
            switch (early.use) {
                .read => self.diagnostics.add(at, .@"used-before-definition", "Cannot use '{s}' before it is defined; it is set further down", .{name}),
                .@"export" => self.diagnostics.add(at, .@"export-before-definition", "Cannot export '{s}' before it is defined; move the export below where '{s}' is set", .{ name, name }),
            }
        }
    }

    pub fn pushScope(self: *Resolver, is_closure: bool, node: ast.NodeIndex) !void {
        try self.scopes.append(self.allocator, .{
            .node = node,
            .is_closure = is_closure,
            .saved_loop_depth = self.loop_depth,
        });
        // A loop around a def, a lambda or a class is none of its body's
        if (is_closure) self.loop_depth = 0;
    }

    pub fn popScope(self: *Resolver) void {
        var scope = self.scopes.pop() orelse return;
        if (scope.is_closure) self.loop_depth = scope.saved_loop_depth;
        scope.deinit(self.allocator);
    }

    /// `name` as a local of the innermost scope, declared by `by` unless it was already.
    pub fn declareLocal(self: *Resolver, name: ast.StringId, by: ast.NodeIndex) !void {
        if (self.scopes.items.len == 0) return;
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        const entry = try scope.declared_by.getOrPut(self.allocator, name);
        if (!entry.found_existing) entry.value_ptr.* = by;
    }

    /// Declares the names `params` bind, a destructured one's included, as locals of the
    /// innermost scope, declared by `by` (the def, lambda or block). Only a block's plain
    /// names were, so `|(c, d), *rest|` left c, d and rest unresolved.
    fn declareParams(self: *Resolver, params: ast.Span, by: ast.NodeIndex) !void {
        for (self.tree.getParams(params)) |param| {
            if (param.name != .none) try self.declareLocal(param.name, by);
            try self.declareParams(param.pattern, by);
        }
    }

    /// The node that declared `name` in the innermost scope (after declareLocal).
    fn declaredBy(self: *const Resolver, name: ast.StringId) ast.NodeIndex {
        if (self.scopes.items.len == 0) return .none;
        return self.scopes.items[self.scopes.items.len - 1].declared_by.get(name) orelse .none;
    }

    /// A name resolved, and the node that declared it.
    const Found = struct { kind: ScopeKind, declared_by: ast.NodeIndex };

    /// The local `name` names here, innermost first: one of a scope past a closure's body is
    /// an upvalue, except the script's own (scope 0), whose variables are globals when it
    /// runs: hover showed no facts for a script variable read inside a def.
    fn findLocal(self: *const Resolver, name: ast.StringId) ?Found {
        var crossed_closure = false;
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            if (scope.declared_by.get(name)) |by| {
                const kind: ScopeKind = if (!crossed_closure) .local else if (i == 0) .global else .upvalue;
                return .{ .kind = kind, .declared_by = by };
            }
            if (scope.is_closure) crossed_closure = true;
        }
        return null;
    }

    pub fn resolveUsage(self: *Resolver, name: ast.StringId, node: ast.NodeIndex) void {
        switch (identifier.kindOf(self.tree.getString(name))) {
            .class_var, .global => {
                self.symbols[@backingInt(node)] = .global;
                return;
            },
            .instance_var => {
                self.symbols[@backingInt(node)] = .instance_var;
                return;
            },
            .local, .constant => {},
        }
        if (self.findLocal(name)) |found| {
            self.symbols[@backingInt(node)] = found.kind;
            self.declarations[@backingInt(node)] = found.declared_by;
        } else {
            self.symbols[@backingInt(node)] = .global;
        }
    }
};

const ResolverContext = struct {
    resolver: *Resolver,

    pub fn enterNode(self: *ResolverContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;

        switch (node.tag) {
            .while_stmt => {
                self.resolver.loop_depth += 1;
            },
            .break_stmt => {
                // In a loop, or straight in a call's block (not in a def or lambda inside it)
                const innermost = self.resolver.scopes.items[self.resolver.scopes.items.len - 1];
                if (self.resolver.loop_depth == 0 and innermost.is_closure) {
                    const offset = self.resolver.token_starts[node.main_token];
                    const length = self.resolver.token_lengths[node.main_token];
                    self.resolver.diagnostics.add(.{ .offset = offset, .length = length, .file_id = 0 }, .@"outside-loop", "Cannot use 'break' outside of a loop", .{});
                }
            },
            .next_stmt => {
                // In a loop, a call's block, a def or a lambda, which `next` leaves
                var is_valid = self.resolver.loop_depth > 0;
                for (self.resolver.scopes.items) |scope| {
                    const opener = tree.getNode(scope.node) orelse continue;
                    if (!scope.is_closure or opener.tag == .def_stmt or opener.tag == .lambda_expr) is_valid = true;
                }
                if (!is_valid) {
                    const offset = self.resolver.token_starts[node.main_token];
                    const length = self.resolver.token_lengths[node.main_token];
                    self.resolver.diagnostics.add(.{ .offset = offset, .length = length, .file_id = 0 }, .@"outside-loop", "Cannot use 'next' outside of a loop", .{});
                }
            },
            .method_call, .super_call => {
                const block = if (node.tag == .method_call) tree.methodCall(node).block else tree.superCall(node).block;
                if (block != .none) try self.resolver.active_method_blocks.put(self.resolver.allocator, block, {});
            },
            .block => {
                // An `if`, `while` or `case` body, also a block, isn't a scope: what it
                // assigns is the enclosing body's (it was resolved as a global after it)
                if (!self.resolver.active_method_blocks.contains(node_idx)) return;
                try self.resolver.pushScope(false, node_idx);
                try self.resolver.declareParams(tree.block(node).params, node_idx);
            },
            .def_stmt => {
                const ds = tree.defStmt(node);
                try self.resolver.noteTopLevel(ds.name);
                try self.resolver.pushScope(true, node_idx);
                try self.resolver.declareParams(ds.params, node_idx);
            },
            .lambda_expr => {
                try self.resolver.pushScope(true, node_idx);
                try self.resolver.declareParams(tree.lambdaExpr(node).params, node_idx);
            },
            .for_stmt => {
                // Like Ruby's, a for loop opens no scope: its variables stay after it.
                self.resolver.loop_depth += 1;
                const fs = tree.forStmt(node);
                for (tree.getLhsExprs(fs.targets)) |target| {
                    try self.resolver.declareLocal(target.name, node_idx);
                    try self.resolver.noteTopLevel(target.name);
                }
            },
            .class_stmt, .module_stmt, .singleton_class => {
                switch (node.tag) {
                    .class_stmt => if (tree.getNode(tree.classStmt(node).name)) |name| {
                        if (name.tag == .identifier) try self.resolver.noteTopLevel(@fromBackingInt(name.data));
                    },
                    .module_stmt => try self.resolver.noteTopLevel(tree.moduleStmt(node).name),
                    else => {},
                }
                try self.resolver.pushScope(true, node_idx);
            },
            .import_stmt => {
                for (tree.getAliasPairs(tree.importStmt(node).symbols)) |pair| try self.resolver.noteTopLevel(pair.alias);
            },
            .export_stmt => {
                const ex = tree.exportStmt(node);
                // A re-export (`export { a } from "./a.kup"`) reads its names from the file it names
                if (ex.path == .none) for (tree.getAliasPairs(ex.symbols)) |pair| {
                    if (!self.resolver.top_level_names.contains(pair.original)) {
                        try self.resolver.early_uses.append(self.resolver.allocator, .{ .name = pair.original, .node = node_idx, .use = .@"export" });
                    }
                };
            },
            .assignment => {
                const assign = tree.assignment(node);
                try self.resolver.declareLocal(assign.name, node_idx);
                try self.resolver.noteTopLevel(assign.name);
                // A reassignment's declaration is the first one
                self.resolver.declarations[@backingInt(node_idx)] = self.resolver.declaredBy(assign.name);
            },
            .multiple_assignment => {
                const ma = tree.multipleAssignment(node);
                for (tree.getLhsExprs(ma.lhs)) |lhs| {
                    try self.resolver.declareLocal(lhs.name, node_idx);
                    try self.resolver.noteTopLevel(lhs.name);
                }
            },
            .identifier => {
                const name_id: ast.StringId = @fromBackingInt(node.data);
                self.resolver.resolveUsage(name_id, node_idx);
                try self.resolver.noteRead(name_id, node_idx);
            },
            else => {},
        }
    }

    pub fn leaveNode(self: *ResolverContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;
        switch (node.tag) {
            .while_stmt => {
                self.resolver.loop_depth -= 1;
            },
            .for_stmt => {
                self.resolver.loop_depth -= 1;
            },
            .block => if (self.resolver.active_method_blocks.remove(node_idx)) self.resolver.popScope(),
            .def_stmt, .lambda_expr, .class_stmt, .module_stmt, .singleton_class => self.resolver.popScope(),
            else => {},
        }
    }
};
