const std = @import("std");
const ast = @import("ast.zig");
const visitor = @import("visitor.zig");
const errors = @import("errors.zig");

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

    // Tracks the exact captures this closure requires
    upvalues: std.ArrayListUnmanaged(UpvalueCapture) = .empty,

    next_slot: u24 = 0,
    is_closure: bool,
    saved_loop_depth: usize = 0,

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.locals.deinit(allocator);
        self.upvalues.deinit(allocator);
    }
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,
    token_starts: []const u32,
    token_lengths: []const u32,

    symbols: []ResolvedSymbol,

    // The side-table storing the finalized capture array for every closure node
    closure_captures: std.AutoHashMapUnmanaged(ast.NodeIndex, []const UpvalueCapture) = .empty,

    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    diagnostics: *errors.Diagnostics,
    loop_depth: usize = 0,

    pub fn init(allocator: std.mem.Allocator, tree: *const ast.Tree, token_starts: []const u32, token_lengths: []const u32, diagnostics: *errors.Diagnostics) !Resolver {
        const symbols = try allocator.alloc(ResolvedSymbol, tree.nodes.items.len);
        @memset(symbols, .{ .kind = .unresolved, .index = 0 });

        return Resolver{
            .allocator = allocator,
            .tree = tree,
            .token_starts = token_starts,
            .token_lengths = token_lengths,
            .symbols = symbols,
            .diagnostics = diagnostics,
            .loop_depth = 0,
        };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.scopes.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.allocator.free(self.symbols);

        // Clean up the closure_captures side-table and its slices
        var it = self.closure_captures.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.closure_captures.deinit(self.allocator);
    }

    pub fn resolve(self: *Resolver, root: ast.NodeIndex) !void {
        if (root == .none) return;
        try self.pushScope(true, .none);

        var ctx = ResolverContext{ .resolver = self };
        try visitor.walk(ResolverContext, &ctx, self.tree, root);

        try self.popScope();
    }

    pub fn pushScope(self: *Resolver, is_closure: bool, node: ast.NodeIndex) !void {
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

    pub fn declareLocal(self: *Resolver, name: ast.StringId) !u24 {
        if (self.scopes.items.len == 0) return 0;
        const scope = &self.scopes.items[self.scopes.items.len - 1];

        if (scope.locals.get(name)) |slot| {
            return slot;
        }

        const slot = scope.next_slot;
        scope.next_slot += 1;
        try scope.locals.put(self.allocator, name, slot);
        return slot;
    }

    // Search for a local variable in the current closure (which may span multiple blocks)
    fn findLocalInClosure(self: *Resolver, start_scope_idx: usize, name: ast.StringId) ?u24 {
        var i = start_scope_idx;
        while (true) {
            const scope = &self.scopes.items[i];
            if (scope.locals.get(name)) |slot| return slot;
            if (scope.is_closure or i == 0) break;
            i -= 1;
        }
        return null;
    }

    // The Recursive Upvalue Algorithm!
    fn resolveInClosure(self: *Resolver, closure_end_idx: usize, name: ast.StringId) !?ResolvedSymbol {
        // 1. Is it a local in THIS closure?
        if (self.findLocalInClosure(closure_end_idx, name)) |slot| {
            return .{ .kind = .local, .index = slot };
        }

        // Find the closure boundary that defines this scope block
        var i = closure_end_idx;
        while (i > 0 and !self.scopes.items[i].is_closure) {
            i -= 1;
        }
        if (i == 0) return null; // We hit the global scope, no parent exists

        // 2. Not a local here, ask the parent closure to resolve it
        const parent_closure_end_idx = i - 1;
        const parent_sym = try self.resolveInClosure(parent_closure_end_idx, name);

        if (parent_sym) |psym| {
            // 3. The parent found it! Add an upvalue capture instruction to OUR closure boundary.
            const is_local = (psym.kind == .local);
            const index = psym.index;

            const upvalue_idx = try self.addUpvalue(i, index, is_local);
            return .{ .kind = .upvalue, .index = upvalue_idx };
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

        if (name_str.len > 0 and name_str[0] == '@') {
            self.symbols[@intFromEnum(node)] = .{ .kind = .instance_var, .index = 0 };
            return;
        }
        if (name_str.len > 0 and name_str[0] == '$') {
            self.symbols[@intFromEnum(node)] = .{ .kind = .global, .index = 0 };
            return;
        }

        // Trigger the recursive resolution from the current depth
        if (self.scopes.items.len > 0) {
            const top_idx = self.scopes.items.len - 1;
            if (try self.resolveInClosure(top_idx, name)) |sym| {
                self.symbols[@intFromEnum(node)] = sym;
                return;
            }
        }

        self.symbols[@intFromEnum(node)] = .{ .kind = .global, .index = 0 };
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
            .break_stmt, .next_stmt => {
                if (self.resolver.loop_depth == 0) {
                    const stmt_name = if (node.tag == .break_stmt) "break" else "next";
                    const offset = self.resolver.token_starts[node.main_token];
                    const length = self.resolver.token_lengths[node.main_token];
                    self.resolver.diagnostics.add(.{ .offset = offset, .length = length, .file_id = 0 }, "Cannot use '{s}' outside of a loop", .{stmt_name});
                }
            },
            .block => {
                try self.resolver.pushScope(false, .none);
                const b = tree.block(node);
                for (tree.getNodes(b.params)) |param_idx| {
                    const param_node = tree.getNode(param_idx).?;
                    if (param_node.tag == .identifier) {
                        const name_id = @as(ast.StringId, @enumFromInt(param_node.data));
                        _ = try self.resolver.declareLocal(name_id);
                        try self.resolver.resolveUsage(name_id, param_idx);
                    }
                }
            },
            .def_stmt => {
                try self.resolver.pushScope(true, node_idx);
                const ds = tree.defStmt(node);
                for (tree.getParams(ds.params)) |param| {
                    _ = try self.resolver.declareLocal(param.name);
                }
            },
            .lambda_expr => {
                try self.resolver.pushScope(true, node_idx);
                const le = tree.lambdaExpr(node);
                for (tree.getParams(le.params)) |param| {
                    _ = try self.resolver.declareLocal(param.name);
                }
            },
            .for_stmt => {
                try self.resolver.pushScope(false, .none);
                self.resolver.loop_depth += 1;
                const fs = tree.forStmt(node);
                for (tree.getForBindings(fs.bindings)) |binding| {
                    _ = try self.resolver.declareLocal(binding.name);
                }
            },
            .class_stmt, .module_stmt => {
                try self.resolver.pushScope(true, node_idx);
            },
            .assignment => {
                const assign = tree.assignment(node);
                _ = try self.resolver.declareLocal(assign.name);
            },
            .multiple_assignment => {
                const ma = tree.multipleAssignment(node);
                for (tree.getLhsExprs(ma.lhs)) |lhs| {
                    _ = try self.resolver.declareLocal(lhs.name);
                }
            },
            .identifier => {
                const name_id = @as(ast.StringId, @enumFromInt(node.data));
                try self.resolver.resolveUsage(name_id, node_idx);
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
                try self.resolver.popScope();
            },
            .block, .def_stmt, .lambda_expr, .class_stmt, .module_stmt => {
                try self.resolver.popScope();
            },
            else => {},
        }
    }
};
