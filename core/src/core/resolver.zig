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

// Packed to exactly 4 bytes for maximum cache density.
// In a 100k node AST, this entire array is only 400KB!
pub const ResolvedSymbol = packed struct {
    kind: ScopeKind,
    index: u24, // Local slot, upvalue index, or global ID
};

const Scope = struct {
    // Maps a StringId to a local slot index
    locals: std.AutoHashMapUnmanaged(ast.StringId, u24) = .empty,
    next_slot: u24 = 0,
    is_closure: bool, // Distinguishes between true closures and simple blocks

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.locals.deinit(allocator);
    }
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,
    symbols: []ResolvedSymbol,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    diagnostics: *errors.Diagnostics,

    pub fn init(allocator: std.mem.Allocator, tree: *const ast.Tree, diagnostics: *errors.Diagnostics) !Resolver {
        const symbols = try allocator.alloc(ResolvedSymbol, tree.nodes.items.len);

        // Default initialize the parallel array to unresolved
        @memset(symbols, .{ .kind = .unresolved, .index = 0 });

        return Resolver{
            .allocator = allocator,
            .tree = tree,
            .symbols = symbols,
            .diagnostics = diagnostics,
        };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.scopes.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.allocator.free(self.symbols);
    }

    pub fn resolve(self: *Resolver, root: ast.NodeIndex) !void {
        if (root == .none) return;

        // Push the global scope boundary (treat as a closure boundary)
        try self.pushScope(true);

        var ctx = ResolverContext{ .resolver = self };
        try visitor.walk(ResolverContext, &ctx, self.tree, root);

        // Pop the global scope
        try self.popScope();
    }

    pub fn pushScope(self: *Resolver, is_closure: bool) !void {
        var start_slot: u24 = 0;

        // If this is a standard block, inherit the local stack slot counter from the parent scope
        if (!is_closure and self.scopes.items.len > 0) {
            start_slot = self.scopes.items[self.scopes.items.len - 1].next_slot;
        }

        try self.scopes.append(self.allocator, .{
            .is_closure = is_closure,
            .next_slot = start_slot,
        });
    }

    pub fn popScope(self: *Resolver) !void {
        var scope = self.scopes.pop() orelse return;

        // If it wasn't a closure, propagate the highest stack slot count back up to the parent
        if (!scope.is_closure and self.scopes.items.len > 0) {
            self.scopes.items[self.scopes.items.len - 1].next_slot = scope.next_slot;
        }

        scope.deinit(self.allocator);
    }

    /// Declares a variable in the current lexical scope and returns its slot index.
    pub fn declareLocal(self: *Resolver, name: ast.StringId) !u24 {
        if (self.scopes.items.len == 0) return 0;
        const scope = &self.scopes.items[self.scopes.items.len - 1];

        // If it already exists in the CURRENT scope, return its slot (reassignment)
        if (scope.locals.get(name)) |slot| {
            return slot;
        }

        // Otherwise, allocate a new slot
        const slot = scope.next_slot;
        scope.next_slot += 1;
        try scope.locals.put(self.allocator, name, slot);
        return slot;
    }

    /// Resolves an identifier usage against the scope stack.
    pub fn resolveUsage(self: *Resolver, name: ast.StringId, node: ast.NodeIndex) void {
        const name_str = self.tree.getString(name);

        // Check for instance variables (@var)
        if (name_str.len > 0 and name_str[0] == '@') {
            self.symbols[@intFromEnum(node)] = .{ .kind = .instance_var, .index = 0 };
            return;
        }

        // Check for global variables ($var)
        if (name_str.len > 0 and name_str[0] == '$') {
            self.symbols[@intFromEnum(node)] = .{ .kind = .global, .index = 0 };
            return;
        }

        // Walk scopes backwards to find locals/upvalues
        var i: usize = self.scopes.items.len;
        var is_local = true;

        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];

            if (scope.locals.get(name)) |slot| {
                if (is_local) {
                    self.symbols[@intFromEnum(node)] = .{ .kind = .local, .index = slot };
                } else {
                    // Found in an outer scope! It's an upvalue closure capture.
                    self.symbols[@intFromEnum(node)] = .{ .kind = .upvalue, .index = slot };
                }
                return;
            }

            // Crossing a function/closure boundary makes outer variables upvalues.
            if (scope.is_closure) {
                is_local = false;
            }
        }

        // If we didn't find it in any scope, it must be a global module/function or undefined.
        self.symbols[@intFromEnum(node)] = .{ .kind = .global, .index = 0 };
    }
};

const ResolverContext = struct {
    resolver: *Resolver,

    pub fn enterNode(self: *ResolverContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;

        switch (node.tag) {
            // --- Scope Creating Nodes ---
            .block => {
                try self.resolver.pushScope(false); // Standard block (inherits locals)
                const b = tree.block(node);
                // Pre-declare block parameters as locals
                for (tree.getNodes(b.params)) |param_idx| {
                    const param_node = tree.getNode(param_idx).?;
                    if (param_node.tag == .identifier) {
                        const name_id = @as(ast.StringId, @enumFromInt(param_node.data));
                        _ = try self.resolver.declareLocal(name_id);
                        self.resolver.resolveUsage(name_id, param_idx);
                    }
                }
            },
            .def_stmt => {
                try self.resolver.pushScope(true); // Closure boundary
                const ds = tree.defStmt(node);
                for (tree.getParams(ds.params)) |param| {
                    _ = try self.resolver.declareLocal(param.name);
                }
            },
            .lambda_expr => {
                try self.resolver.pushScope(true); // Closure boundary
                const le = tree.lambdaExpr(node);
                for (tree.getParams(le.params)) |param| {
                    _ = try self.resolver.declareLocal(param.name);
                }
            },
            .for_stmt => {
                try self.resolver.pushScope(false);
                const fs = tree.forStmt(node);
                for (tree.getForBindings(fs.bindings)) |binding| {
                    _ = try self.resolver.declareLocal(binding.name);
                }
            },
            .class_stmt, .module_stmt => {
                try self.resolver.pushScope(true); // Closure boundary
            },

            // --- Variable Definitions ---
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

            // --- Variable Usages ---
            .identifier => {
                const name_id = @as(ast.StringId, @enumFromInt(node.data));
                self.resolver.resolveUsage(name_id, node_idx);
            },

            else => {},
        }
    }

    pub fn leaveNode(self: *ResolverContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;
        switch (node.tag) {
            .block, .def_stmt, .lambda_expr, .for_stmt, .class_stmt, .module_stmt => {
                try self.resolver.popScope();
            },
            else => {},
        }
    }
};
