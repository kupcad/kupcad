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
    saved_loop_depth: usize = 0, // Preserves the parent's loop depth across closures

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

    token_starts: []const u32,
    token_lengths: []const u32,

    // Tracks the current nesting of while/for loops
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
        const current_loop_depth = self.loop_depth;

        // If this is a standard block, inherit the local stack slot counter from the parent scope
        if (!is_closure and self.scopes.items.len > 0) {
            start_slot = self.scopes.items[self.scopes.items.len - 1].next_slot;
        }

        // If we are crossing a closure boundary (like a function def), you cannot break
        // out of a loop that is outside the function. We reset the loop depth safely.
        if (is_closure) {
            self.loop_depth = 0;
        }

        try self.scopes.append(self.allocator, .{
            .is_closure = is_closure,
            .next_slot = start_slot,
            .saved_loop_depth = current_loop_depth,
        });
    }

    pub fn popScope(self: *Resolver) !void {
        var scope = self.scopes.pop() orelse return;

        // If it wasn't a closure, propagate the highest stack slot count back up to the parent
        if (!scope.is_closure and self.scopes.items.len > 0) {
            self.scopes.items[self.scopes.items.len - 1].next_slot = scope.next_slot;
        }

        // Restore the outer loop depth when escaping the closure boundary
        if (scope.is_closure) {
            self.loop_depth = scope.saved_loop_depth;
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
            // --- Loop Control Constraints ---
            .while_stmt => {
                self.resolver.loop_depth += 1;
            },
            .break_stmt, .next_stmt => {
                if (self.resolver.loop_depth == 0) {
                    const stmt_name = if (node.tag == .break_stmt) "break" else "next";

                    // Extract exact source code coordinates for the error!
                    const offset = self.resolver.token_starts[node.main_token];
                    const length = self.resolver.token_lengths[node.main_token];

                    self.resolver.diagnostics.add(.{ .line = 0, .col = 0, .offset = offset, .length = length, .file_id = 0 }, "Cannot use '{s}' outside of a loop", .{stmt_name});
                }
            },

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
                self.resolver.loop_depth += 1; // It is a loop!
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
