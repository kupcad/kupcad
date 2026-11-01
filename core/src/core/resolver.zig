//! `Resolver`: walks the AST once and records, per node, whether a name is a local, an
//! upvalue, a global or an instance variable (`ResolvedSymbol`) and, for a local or an
//! upvalue, the node that declared it (`declarations`: the assignment, the `def` or lambda
//! whose parameter it is, the block parameter, the `for`), and which variables each
//! closure captures; it also reports `break` and `next` outside a loop, and a name the top
//! level reads or exports where only a line further down sets it. Run by
//! `frontend/document.zig`.

const std = @import("std");
const ast = @import("ast.zig");
const visitor = @import("visitor.zig");
const errors = @import("errors.zig");
const token = @import("token.zig");

pub const ScopeKind = enum(u8) {
    unresolved,
    local,
    upvalue,
    global,
    instance_var,
};

pub const ResolvedSymbol = packed struct {
    kind: ScopeKind,
    index: u24,
};

// Represents a single VM capture instruction
pub const UpvalueCapture = packed struct {
    index: u24, // The slot or upvalue index in the enclosing scope
    is_local: bool, // True if capturing a local, False if capturing an upvalue
};

const Scope = struct {
    node: ast.NodeIndex, // The AST node defining this closure (e.g. lambda_expr). .none if it's just a block.
    locals: std.AutoHashMapUnmanaged(ast.StringId, u24) = .empty,
    /// The node that declared each of `locals`: its first assignment, its `def`, ...
    declared_by: std.AutoHashMapUnmanaged(ast.StringId, ast.NodeIndex) = .empty,

    // Tracks the exact captures this closure requires
    upvalues: std.ArrayList(UpvalueCapture) = .empty,

    next_slot: u24 = 0,
    is_closure: bool = false,
    is_block: bool = false,
    saved_loop_depth: usize = 0,

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.locals.deinit(allocator);
        self.declared_by.deinit(allocator);
        self.upvalues.deinit(allocator);
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

    symbols: []ResolvedSymbol,
    /// Per node: for a name that is a local or an upvalue, the node that declared it;
    /// .none for anything else.
    declarations: []ast.NodeIndex,

    // The side-table storing the finalized capture array for every closure node
    closure_captures: std.AutoHashMapUnmanaged(ast.NodeIndex, []const UpvalueCapture) = .empty,
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
        const symbols = try allocator.alloc(ResolvedSymbol, tree.nodes.items.len);
        errdefer allocator.free(symbols);
        @memset(symbols, .{ .kind = .unresolved, .index = 0 });
        const declarations = try allocator.alloc(ast.NodeIndex, tree.nodes.items.len);
        @memset(declarations, .none);

        return Resolver{
            .allocator = allocator,
            .tree = tree,
            .token_starts = token_starts,
            .token_lengths = token_lengths,
            .symbols = symbols,
            .declarations = declarations,
            .closure_captures = .empty,
            .active_method_blocks = .empty,
            .scopes = .empty,
            .diagnostics = diagnostics,
            .loop_depth = 0,
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

        // Clean up the closure_captures side-table and its slices
        var it = self.closure_captures.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.closure_captures.deinit(self.allocator);
    }

    pub fn resolve(self: *Resolver, root: ast.NodeIndex) !void {
        if (root == .none) return;
        try self.pushScope(true, false, .none);

        var ctx = ResolverContext{ .resolver = self };
        try visitor.walk(ResolverContext, &ctx, self.tree, root);

        try self.popScope();
        self.reportEarlyUses();
    }

    /// Whether the walk is at the top level: not in a method, class or a call's block (the
    /// bodies of the program, an `if` or a loop are blocks of its own).
    fn atTopLevel(self: *const Resolver) bool {
        for (self.scopes.items[1..]) |scope| if (scope.is_closure or scope.is_block) return false;
        return true;
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
        if (self.symbols[@backingInt(node)].kind != .global or self.top_level_names.contains(name)) return;
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

    pub fn pushScope(self: *Resolver, is_closure: bool, is_block: bool, node: ast.NodeIndex) !void {
        var start_slot: u24 = 0;
        const current_loop_depth = self.loop_depth;

        if (!is_closure and self.scopes.items.len > 0) {
            start_slot = self.scopes.items[self.scopes.items.len - 1].next_slot;
        }

        if (is_closure) {
            self.loop_depth = 0;
        }

        try self.scopes.append(self.allocator, .{
            .node = node,
            .is_closure = is_closure,
            .is_block = is_block,
            .next_slot = start_slot,
            .saved_loop_depth = current_loop_depth,
        });
    }

    pub fn popScope(self: *Resolver) !void {
        var scope = self.scopes.pop() orelse return;

        if (!scope.is_closure and self.scopes.items.len > 0) {
            self.scopes.items[self.scopes.items.len - 1].next_slot = scope.next_slot;
        }

        if (scope.is_closure) {
            self.loop_depth = scope.saved_loop_depth;

            // Finalize the closure's captures and save them in the side-table
            if (scope.node != .none) {
                const captures = try scope.upvalues.toOwnedSlice(self.allocator);
                try self.closure_captures.put(self.allocator, scope.node, captures);
            }
        }

        scope.deinit(self.allocator);
    }

    /// `name` as a local of the innermost scope, declared by `by` unless it was already.
    pub fn declareLocal(self: *Resolver, name: ast.StringId, by: ast.NodeIndex) !u24 {
        if (self.scopes.items.len == 0) return 0;
        const scope = &self.scopes.items[self.scopes.items.len - 1];

        if (scope.locals.get(name)) |slot| {
            return slot;
        }

        const slot = scope.next_slot;
        scope.next_slot += 1;
        try scope.locals.put(self.allocator, name, slot);
        try scope.declared_by.put(self.allocator, name, by);
        return slot;
    }

    /// The node that declared `name` in the innermost scope (after declareLocal).
    fn declaredBy(self: *const Resolver, name: ast.StringId) ast.NodeIndex {
        if (self.scopes.items.len == 0) return .none;
        return self.scopes.items[self.scopes.items.len - 1].declared_by.get(name) orelse .none;
    }

    /// A name resolved, and the node that declared it.
    const Found = struct { symbol: ResolvedSymbol, declared_by: ast.NodeIndex };

    // Search for a local variable in the current closure (which may span multiple blocks)
    fn findLocalInClosure(self: *Resolver, start_scope_idx: usize, name: ast.StringId) ?Found {
        var i = start_scope_idx;
        while (true) {
            const scope = &self.scopes.items[i];
            if (scope.locals.get(name)) |slot| return .{ .symbol = .{ .kind = .local, .index = slot }, .declared_by = scope.declared_by.get(name).? };
            if (scope.is_closure or i == 0) break;
            i -= 1;
        }
        return null;
    }

    // The Recursive Upvalue Algorithm!
    fn resolveInClosure(self: *Resolver, closure_end_idx: usize, name: ast.StringId) !?Found {
        // 1. Is it a local in THIS closure?
        if (self.findLocalInClosure(closure_end_idx, name)) |found| return found;

        // Find the closure boundary that defines this scope block
        var i = closure_end_idx;
        while (i > 0 and !self.scopes.items[i].is_closure) {
            i -= 1;
        }
        if (i == 0) return null; // We hit the global scope, no parent exists

        // 2. Not a local here, ask the parent closure to resolve it
        const parent_closure_end_idx = i - 1;
        const parent_sym = try self.resolveInClosure(parent_closure_end_idx, name);

        if (parent_sym) |parent| {
            // 3. The parent found it! Add an upvalue capture instruction to OUR closure boundary.
            const is_local = (parent.symbol.kind == .local);
            const index = parent.symbol.index;

            const upvalue_idx = try self.addUpvalue(i, index, is_local);
            return .{ .symbol = .{ .kind = .upvalue, .index = upvalue_idx }, .declared_by = parent.declared_by };
        }

        return null;
    }

    fn addUpvalue(self: *Resolver, closure_scope_idx: usize, index: u24, is_local: bool) !u24 {
        const scope = &self.scopes.items[closure_scope_idx];
        std.debug.assert(scope.is_closure);

        // Deduplicate captures so we don't capture the same variable twice
        for (scope.upvalues.items, 0..) |uv, idx| {
            if (uv.index == index and uv.is_local == is_local) {
                return @intCast(idx);
            }
        }

        const new_idx: u24 = @intCast(scope.upvalues.items.len);
        try scope.upvalues.append(self.allocator, .{ .index = index, .is_local = is_local });
        return new_idx;
    }

    pub fn resolveUsage(self: *Resolver, name: ast.StringId, node: ast.NodeIndex) !void {
        const name_str = self.tree.getString(name);

        // Check @@ before @ so class variables aren't tagged as instance variables
        if (std.mem.startsWith(u8, name_str, "@@")) {
            self.symbols[@backingInt(node)] = .{ .kind = .global, .index = 0 };
            return;
        }
        if (std.mem.startsWith(u8, name_str, "@")) {
            self.symbols[@backingInt(node)] = .{ .kind = .instance_var, .index = 0 };
            return;
        }
        if (std.mem.startsWith(u8, name_str, "$")) {
            self.symbols[@backingInt(node)] = .{ .kind = .global, .index = 0 };
            return;
        }

        // Trigger recursive local/upvalue resolution from the current depth
        if (self.scopes.items.len > 0) {
            const top_idx = self.scopes.items.len - 1;
            if (try self.resolveInClosure(top_idx, name)) |found| {
                self.symbols[@backingInt(node)] = found.symbol;
                self.declarations[@backingInt(node)] = found.declared_by;
                return;
            }
        }

        self.symbols[@backingInt(node)] = .{ .kind = .global, .index = 0 };
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
                var is_valid = self.resolver.loop_depth > 0;
                if (!is_valid) {
                    var i = self.resolver.scopes.items.len;
                    while (i > 0) {
                        i -= 1;
                        const scope = self.resolver.scopes.items[i];
                        if (scope.is_block) {
                            is_valid = true;
                            break;
                        }
                        if (scope.is_closure) break;
                    }
                }
                if (!is_valid) {
                    const offset = self.resolver.token_starts[node.main_token];
                    const length = self.resolver.token_lengths[node.main_token];
                    self.resolver.diagnostics.add(.{ .offset = offset, .length = length, .file_id = 0 }, .@"outside-loop", "Cannot use 'break' outside of a loop", .{});
                }
            },
            .next_stmt => {
                var is_valid = self.resolver.loop_depth > 0;
                if (!is_valid) {
                    var i = self.resolver.scopes.items.len;
                    while (i > 0) {
                        i -= 1;
                        const scope = self.resolver.scopes.items[i];
                        if (scope.is_block or (scope.is_closure and scope.node != .none)) {
                            const scope_node = tree.getNode(scope.node);
                            if (scope.is_block or (scope_node != null and (scope_node.?.tag == .def_stmt or scope_node.?.tag == .lambda_expr))) {
                                is_valid = true;
                                break;
                            }
                        }
                    }
                }
                if (!is_valid) {
                    const offset = self.resolver.token_starts[node.main_token];
                    const length = self.resolver.token_lengths[node.main_token];
                    self.resolver.diagnostics.add(.{ .offset = offset, .length = length, .file_id = 0 }, .@"outside-loop", "Cannot use 'next' outside of a loop", .{});
                }
            },
            .method_call => {
                const mc = tree.methodCall(node);
                if (mc.block != .none) {
                    try self.resolver.active_method_blocks.put(self.resolver.allocator, mc.block, {});
                }
            },
            .block => {
                const is_mb = self.resolver.active_method_blocks.contains(node_idx);
                try self.resolver.pushScope(false, is_mb, node_idx);
                const b = tree.block(node);
                for (tree.getNodes(b.params)) |param_idx| {
                    const param_node = tree.getNode(param_idx).?;
                    if (param_node.tag == .identifier) {
                        const name_id: ast.StringId = @fromBackingInt(param_node.data);
                        _ = try self.resolver.declareLocal(name_id, param_idx);
                        try self.resolver.resolveUsage(name_id, param_idx);
                    }
                }
            },
            .def_stmt => {
                const ds = tree.defStmt(node);
                try self.resolver.noteTopLevel(ds.name);
                try self.resolver.pushScope(true, false, node_idx);
                for (tree.getParams(ds.params)) |param| {
                    _ = try self.resolver.declareLocal(param.name, node_idx);
                }
            },
            .lambda_expr => {
                try self.resolver.pushScope(true, false, node_idx);
                const le = tree.lambdaExpr(node);
                for (tree.getParams(le.params)) |param| {
                    _ = try self.resolver.declareLocal(param.name, node_idx);
                }
            },
            .for_stmt => {
                // Like Ruby's, a for loop opens no scope: its variables stay after it.
                self.resolver.loop_depth += 1;
                const fs = tree.forStmt(node);
                for (tree.getLhsExprs(fs.targets)) |target| {
                    _ = try self.resolver.declareLocal(target.name, node_idx);
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
                try self.resolver.pushScope(true, false, node_idx);
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
                _ = try self.resolver.declareLocal(assign.name, node_idx);
                try self.resolver.noteTopLevel(assign.name);
                // A reassignment's declaration is the first one
                self.resolver.declarations[@backingInt(node_idx)] = self.resolver.declaredBy(assign.name);
            },
            .multiple_assignment => {
                const ma = tree.multipleAssignment(node);
                for (tree.getLhsExprs(ma.lhs)) |lhs| {
                    _ = try self.resolver.declareLocal(lhs.name, node_idx);
                    try self.resolver.noteTopLevel(lhs.name);
                }
            },
            .identifier => {
                const name_id: ast.StringId = @fromBackingInt(node.data);
                try self.resolver.resolveUsage(name_id, node_idx);
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
            .block => {
                _ = self.resolver.active_method_blocks.remove(node_idx);
                try self.resolver.popScope();
            },
            .def_stmt, .lambda_expr, .class_stmt, .module_stmt, .singleton_class => {
                try self.resolver.popScope();
            },
            else => {},
        }
    }
};
