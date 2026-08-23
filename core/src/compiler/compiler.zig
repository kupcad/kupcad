const std = @import("std");
const macros = @import("macros.zig");
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const limits = @import("../vm/limits.zig");
const resolver = @import("../core/resolver.zig");
const verifier = @import("../vm/verifier.zig");
const VM = @import("../vm/vm.zig").VM;

pub const CompileError = error{
    OutOfMemory,
    UnknownNode,
    TooManyConstants,
    TooManyLocals,
    UnsupportedScope,
    ProtectedSymbol,
    CorruptedBytecode,
};

pub const Upvalue = struct {
    index: u16,
    is_local: bool,
};

pub const Local = struct {
    name_id: ast.StringId,
    slot: u16,
};

pub const LoopState = struct {
    start: usize,
    depth: usize,
    exit_jumps: std.ArrayListUnmanaged(usize) = .empty,
};

const VarType = enum {
    constant,
    class_var,
    instance_var,
    local,
    upvalue,
    global,
    new_local,
};

const ResolvedVar = struct {
    kind: VarType,
    index: usize = 0,
};

const Intrinsic = enum {
    raise_err,
    block_given_chk,
    yield_call,
    defined_chk,
    protected_symbol,
};

const compiler_intrinsics = std.StaticStringMap(Intrinsic).initComptime(.{
    .{ "raise", .raise_err },
    .{ "block_given?", .block_given_chk },
    .{ "yield", .yield_call },
    .{ "defined?", .defined_chk },
    .{ "param", .protected_symbol },
    // Protect the CLI injection map
    .{ "params", .protected_symbol },

    // IO & Debugging
    .{ "puts", .protected_symbol },
    .{ "print", .protected_symbol },
    .{ "inspect", .protected_symbol },
    .{ "debugger", .protected_symbol },

    // 3D Primitives
    .{ "cube", .protected_symbol },
    .{ "cylinder", .protected_symbol },
    .{ "sphere", .protected_symbol },

    // 2D Primitives
    .{ "square", .protected_symbol },
    .{ "circle", .protected_symbol },
    .{ "polygon", .protected_symbol },

    // Core Classes
    .{ "Array", .protected_symbol },
    .{ "String", .protected_symbol },
    .{ "Map", .protected_symbol },
    .{ "Number", .protected_symbol },
    .{ "Symbol", .protected_symbol },
    .{ "Boolean", .protected_symbol },
    .{ "BoundingBox", .protected_symbol },
    .{ "Math", .protected_symbol },
    .{ "GC", .protected_symbol },
});

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,

    // Track script globals purely by String Slice to decouple from AST integer IDs
    script_globals: std.StringHashMapUnmanaged(void) = .empty,

    symbols: []const resolver.ResolvedSymbol,
    token_starts: []const u32, // Map AST nodes back to Lexer byte offsets
    current_source_offset: u32, // Implictly passed to Chunk
    current_chunk: *chunk.Chunk,
    vm: *VM,

    // Lexical Scope Tracking
    enclosing: ?*Compiler = null,
    function: ?*value.ObjFunction = null,
    is_method: bool = false,
    active_namespaces: usize = 0,
    // Lexical Scope tracking
    namespace_stack: std.ArrayListUnmanaged(ast.StringId) = .empty,

    upvalues: std.ArrayListUnmanaged(Upvalue) = .empty,
    locals: std.ArrayListUnmanaged(Local) = .empty,
    loops: std.ArrayListUnmanaged(LoopState) = .empty,

    current_stack_depth: usize = 0,
    max_stack_depth: usize = 0,
    max_local_slot: usize = 0,

    seeded_locals: []const []const u8 = &.{},
    seeded_slot_offset: u16 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        tree: *const ast.Tree,
        symbols: []const resolver.ResolvedSymbol,
        token_starts: []const u32,
        output_chunk: *chunk.Chunk,
        vm: *VM,
    ) Compiler {
        return .{
            .allocator = allocator,
            .tree = tree,
            .script_globals = .empty,
            .symbols = symbols,
            .token_starts = token_starts,
            .current_chunk = output_chunk,
            .vm = vm,
            .enclosing = null,
            .function = null,
            .is_method = false,
            .namespace_stack = .empty,
            .upvalues = .empty,
            .locals = .empty,
            .loops = .empty,
            .current_stack_depth = 0,
            .max_stack_depth = 0,
            .current_source_offset = 0,
            .max_local_slot = 0,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.upvalues.deinit(self.allocator);
        self.script_globals.deinit(self.allocator);
        self.locals.deinit(self.allocator);
        for (self.loops.items) |*loop| {
            loop.exit_jumps.deinit(self.allocator);
        }
        self.loops.deinit(self.allocator);
        self.namespace_stack.deinit(self.allocator);
    }

    // --- Lexical Scope Resolvers ---

    fn classifyVariable(self: *Compiler, name_id: ast.StringId, sym_opt: ?resolver.ResolvedSymbol) CompileError!ResolvedVar {
        const name_str = self.tree.getString(name_id);
        if (std.ascii.isUpper(name_str[0])) return .{ .kind = .constant };
        if (std.mem.startsWith(u8, name_str, "@@")) return .{ .kind = .class_var };
        if (std.mem.startsWith(u8, name_str, "@")) return .{ .kind = .instance_var };

        if (self.resolveLocal(name_id)) |slot| return .{ .kind = .local, .index = slot };
        if (try self.resolveUpvalue(name_id)) |upv_slot| return .{ .kind = .upvalue, .index = upv_slot };

        if (sym_opt) |sym| {
            if (sym.kind == .global or self.enclosing == null or self.isScriptGlobal(name_id)) {
                return .{ .kind = .global };
            }
            return .{ .kind = .new_local };
        }

        return .{ .kind = .global };
    }

    fn buildFullyQualifiedPath(self: *Compiler, target: []const u8, depth: usize) CompileError![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(self.allocator);

        for (self.namespace_stack.items[0..depth]) |ns_id| {
            try buf.appendSlice(self.allocator, self.tree.getString(ns_id));
            try buf.appendSlice(self.allocator, "::");
        }
        try buf.appendSlice(self.allocator, target);

        // Return the owned slice directly to prevent duping leaks
        return try buf.toOwnedSlice(self.allocator);
    }

    pub fn addLocal(self: *Compiler, name_id: ast.StringId, slot: u16) CompileError!void {
        // Allow anonymous padding slots (.none) to bypass deduplication ---
        if (name_id != .none) {
            for (self.locals.items) |loc| {
                if (loc.name_id == name_id) return;
            }
        }
        if (self.locals.items.len >= limits.MAX_LOCALS) return error.TooManyLocals;
        try self.locals.append(self.allocator, .{ .name_id = name_id, .slot = slot });
        if (slot > self.max_local_slot) self.max_local_slot = slot;

        // --- DEBUGGER METADATA: Track local names ---
        const name_str = if (name_id != .none) self.tree.getString(name_id) else "<anonymous>";

        // Pad the array dynamically since block parameters can be registered out-of-order
        while (self.current_chunk.local_names.items.len <= slot) {
            try self.current_chunk.local_names.append(self.allocator, "<anonymous>");
        }
        self.current_chunk.local_names.items[slot] = name_str;
    }

    fn resolveLocal(self: *Compiler, name_id: ast.StringId) ?u16 {
        const target_str = self.tree.getString(name_id);
        var i: usize = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const loc = self.locals.items[i];
            if (loc.name_id != .none) {
                if (std.mem.eql(u8, self.tree.getString(loc.name_id), target_str)) return loc.slot;
            }
        }

        for (self.seeded_locals, 0..) |seeded_name, idx| {
            if (std.mem.eql(u8, seeded_name, target_str)) return @intCast(idx + self.seeded_slot_offset);
        }

        return null;
    }

    fn resolveUpvalue(self: *Compiler, name_id: ast.StringId) CompileError!?u8 {
        if (self.enclosing == null) return null;
        const enclosing = self.enclosing.?;

        // Look for it as a direct local variable in the parent
        if (enclosing.resolveLocal(name_id)) |local_idx| {
            return try self.addUpvalue(local_idx, true);
        }

        // Recursively look up the scope chain for an already captured upvalue
        if (try enclosing.resolveUpvalue(name_id)) |upv_idx| {
            return try self.addUpvalue(upv_idx, false);
        }

        return null;
    }

    fn resolveSelfUpvalue(self: *Compiler) CompileError!?u8 {
        if (self.enclosing == null) return null;
        const enclosing = self.enclosing.?;

        if (enclosing.is_method) {
            // The parent IS a method. Its `self` is at local 0.
            return try self.addUpvalue(0, true);
        }

        // The parent is also a block. Recursively capture.
        if (try enclosing.resolveSelfUpvalue()) |upv_idx| {
            return try self.addUpvalue(upv_idx, false);
        }

        return null;
    }

    fn addUpvalue(self: *Compiler, index: u16, is_local: bool) CompileError!u8 {
        for (self.upvalues.items, 0..) |upv, i| {
            if (upv.index == index and upv.is_local == is_local) {
                return @intCast(i);
            }
        }
        if (self.upvalues.items.len >= limits.MAX_UPVALUES) return error.TooManyLocals;
        try self.upvalues.append(self.allocator, .{ .index = index, .is_local = is_local });
        if (self.function) |f| f.upvalue_count = @intCast(self.upvalues.items.len);
        return @intCast(self.upvalues.items.len - 1);
    }

    // --- Compilation Engine ---

    pub fn compile(self: *Compiler, root: ast.NodeIndex) CompileError!void {
        if (root == .none) {
            try self.emitOp(.op_nil);
        } else {
            try self.compileNode(root);
        }
        try self.emitOp(.op_return);
        self.current_chunk.max_stack_slots = self.max_stack_depth;
        self.current_chunk.local_count = @max(self.locals.items.len, self.max_local_slot + 1);

        // Verify bytecode integrity before allowing execution
        verifier.verifyChunk(self.current_chunk) catch {
            return error.CorruptedBytecode; // Or create a dedicated CompilerError.CorruptedBytecode
        };
    }

    fn compileNode(self: *Compiler, node_idx: ast.NodeIndex) CompileError!void {
        if (node_idx == .none) return;

        // Track where we started
        const expected_entry_depth = self.current_stack_depth;

        const node = self.tree.getNode(node_idx) orelse return error.UnknownNode;

        if (node.main_token < self.token_starts.len) {
            self.current_source_offset = self.token_starts[node.main_token];
        }

        switch (node.tag) {
            .number => {
                const val = self.tree.number(node);
                try self.emitConstant(value.Value.initNumber(val));
            },
            .string => {
                const str_content = self.tree.getString(self.tree.stringId(node));
                const str_idx = try self.makeStringConstant(str_content);
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, str_idx);
            },
            .symbol => {
                const sym_str = self.tree.getString(self.tree.stringId(node));
                const sym_idx = try self.makeSymbolConstant(sym_str);
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, sym_idx);
            },
            .boolean => {
                const val = self.tree.boolean(node);
                if (val) try self.emitOp(.op_true) else try self.emitOp(.op_false);
            },
            .undef => {
                try self.emitOp(.op_nil);
            },
            .yield_stmt => {
                const args = self.tree.getNodes(self.tree.nodeSpan(node));
                for (args) |arg| {
                    try self.compileNode(arg);
                }
                if (args.len > limits.MAX_ARGS) return error.TooManyConstants;
                try self.emitOp(.op_yield);
                try self.emitByte(@intCast(args.len));
                self.simulatePop(args.len); // Yield consumes args
                self.simulatePush(1); // Yield pushes block return value
            },
            .identifier => {
                // Ensure the Resolver properly mapped this node
                std.debug.assert(@intFromEnum(node_idx) < self.symbols.len);

                const sym = self.symbols[@intFromEnum(node_idx)];
                const name_id = self.tree.stringId(node);
                const name_str = self.tree.getString(name_id);

                const is_local = (self.resolveLocal(name_id) != null) or
                    (sym.kind == .local);
                const is_upvalue = (try self.resolveUpvalue(name_id)) != null;
                const is_script_global = self.isScriptGlobal(name_id);

                // --- REPL FIX: Check the VM's active runtime memory! ---
                const is_vm_global = self.vm.globals.contains(name_str);

                const is_special_or_const = name_str.len == 0 or
                    std.mem.startsWith(u8, name_str, "@") or
                    std.mem.startsWith(u8, name_str, "$") or
                    std.ascii.isUpper(name_str[0]);

                // If it exists in the VM already, treat it as a variable, not a function call
                const is_variable = is_local or is_upvalue or is_script_global or is_special_or_const or is_vm_global;

                if (!is_variable) {
                    // Bare identifier that is not a known variable or constant:
                    // In Ruby/KupCAD, this is a 0-argument function/method invocation!
                    const name_idx = try self.makeStringConstant(name_str);
                    try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, name_idx);
                    try self.emitOp(.op_call);
                    try self.emitByte(0); // 0 arguments
                    self.simulatePop(1); // Consumes function pointer
                    self.simulatePush(1); // Pushes function return value
                } else {
                    try self.emitVariableLoad(name_id, sym);
                }
            },
            .singleton_class => {
                const sc = self.tree.singletonClassPayload(node);
                const target_node = self.tree.getNode(sc.target).?;

                // If `self` is referenced at the root level of a class/module definition,
                // the namespace object is already sitting at the top of the stack baseline!
                if (target_node.tag == .self_expr and self.enclosing == null and self.active_namespaces > 0) {
                    try self.emitOp(.op_dup);
                } else {
                    try self.compileNode(sc.target);
                }

                const body_node = self.tree.getNode(sc.body).?;
                const block_payload = self.tree.block(body_node);
                const stmts = self.tree.getNodes(block_payload.stmts);

                // Compile entire body as singleton methods
                try self.compileNamespaceBody(stmts, true);

                // Stack equilibrium: The target remains on the stack as the expression's return value
            },
            .return_stmt => {
                const ret_idx = self.tree.nodeIndex(node);
                if (ret_idx != .none) {
                    try self.compileNode(ret_idx);
                } else {
                    try self.emitOp(.op_nil);
                }
                try self.emitOp(.op_return);
                self.simulatePush(1); // Equilibrium for dead code
            },
            .next_stmt => {
                const next_idx = self.tree.nodeIndex(node);
                if (next_idx != .none) {
                    try self.compileNode(next_idx);
                } else {
                    try self.emitOp(.op_nil);
                }
                if (self.loops.items.len > 0) {
                    try self.emitOp(.op_pop);
                    const cur_loop = &self.loops.items[self.loops.items.len - 1];

                    if (self.current_stack_depth > cur_loop.depth) return error.UnsupportedScope;

                    try self.emitLoop(cur_loop.start);
                    self.simulatePush(1);
                } else if (self.enclosing != null or self.function != null) {
                    try self.emitOp(.op_return);
                    self.simulatePush(1);
                } else {
                    return error.UnknownNode;
                }
            },
            .break_stmt => {
                const break_idx = self.tree.nodeIndex(node);
                if (break_idx != .none) {
                    try self.compileNode(break_idx);
                } else {
                    try self.emitOp(.op_nil);
                }
                if (self.loops.items.len > 0) {
                    const cur_loop = &self.loops.items[self.loops.items.len - 1];

                    if (self.current_stack_depth > cur_loop.depth + 1) return error.UnsupportedScope;

                    const jump = try self.emitJump(.op_jump);
                    try cur_loop.exit_jumps.append(self.allocator, jump);
                } else if (self.enclosing != null or self.function != null) {
                    try self.emitOp(.op_break_block);
                    self.simulatePush(1);
                } else {
                    return error.UnknownNode;
                }
            },
            .assignment => {
                const assign_payload = self.tree.assignment(node);
                const sym = self.symbols[@intFromEnum(node_idx)];
                const name_id = assign_payload.name;
                const name_str = self.tree.getString(name_id);

                if (compiler_intrinsics.has(name_str)) {
                    return error.ProtectedSymbol;
                }

                // Intercept Instance Variables (@x) securely
                if (std.mem.startsWith(u8, name_str, "@") and !std.mem.startsWith(u8, name_str, "@@")) {
                    try self.emitPushSelf(); // Stack: [self]

                    // Strip '@' at compile time
                    const clean_name = if (name_str.len > 1) name_str[1..] else name_str;

                    if (assign_payload.op) |op| {
                        try self.emitOp(.op_dup); // Stack: [self, self]
                        const name_idx = try self.makeStringConstant(clean_name);
                        try self.emitOpWithOperand(.op_get_property, .op_get_property_wide, name_idx);
                        try self.emitInlineCacheIndex();

                        try self.compileNode(assign_payload.value);
                        switch (op) {
                            .add => try self.emitOp(.op_add),
                            .subtract => try self.emitOp(.op_subtract),
                            .multiply => try self.emitOp(.op_multiply),
                            .divide => try self.emitOp(.op_divide),
                            else => return error.UnknownNode,
                        }
                    } else {
                        try self.compileNode(assign_payload.value); // Stack: [self, new_val]
                    }

                    const name_idx = try self.makeStringConstant(clean_name);
                    try self.emitOpWithOperand(.op_set_property, .op_set_property_wide, name_idx);
                    try self.emitInlineCacheIndex();
                    return;
                }

                // Check if the variable exists locally or in an upvalue FIRST
                const local_slot = self.resolveLocal(name_id);
                const upval_slot = try self.resolveUpvalue(name_id);

                // If it doesn't exist locally/upvalue, and we're at the top-level, it's a global.
                // Otherwise, if it's a new local declaration inside a block:
                const is_new_local = self.enclosing != null and
                    sym.kind == .local and
                    !std.mem.startsWith(u8, name_str, "@@") and
                    !std.mem.startsWith(u8, name_str, "@") and
                    local_slot == null and
                    upval_slot == null and
                    !self.isScriptGlobal(name_id);

                if (is_new_local) {
                    const slot = self.getNextLocalSlot();
                    try self.addLocal(name_id, slot);
                }

                // Evaluate RHS (with Compound Operator getters if necessary)
                if (assign_payload.op) |op| {
                    try self.emitVariableLoad(name_id, sym);
                    try self.compileNode(assign_payload.value);
                    switch (op) {
                        .add => try self.emitOp(.op_add),
                        .subtract => try self.emitOp(.op_subtract),
                        .multiply => try self.emitOp(.op_multiply),
                        .divide => try self.emitOp(.op_divide),
                        else => return error.UnknownNode,
                    }
                } else {
                    try self.compileNode(assign_payload.value);
                }

                // Set the Target Variable
                try self.emitVariableStore(name_id, sym);
            },
            .rescue_modifier => {
                const rm = self.tree.rescueModifier(node);
                const rescue_jump = try self.emitJump(.op_setup_rescue);
                try self.compileNode(rm.expr);
                try self.emitOp(.op_pop_rescue);
                const end_jump = try self.emitJump(.op_jump);

                self.patchJump(rescue_jump);

                // `op_setup_rescue` jumps here with the error value pushed to the stack
                self.current_stack_depth = expected_entry_depth + 1;

                try self.emitOp(.op_pop); // Discard error value
                try self.compileNode(rm.rescue_expr);
                self.patchJump(end_jump);
            },
            .namespace_access => {
                const path = self.tree.getStringLists(self.tree.nodeSpan(node));
                if (path.len == 0) {
                    try self.emitOp(.op_nil);
                    return;
                }

                // Get the root of the namespace
                const root_idx = try self.makeStringConstant(self.tree.getString(path[0]));
                try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, root_idx);

                // Chain property accesses for the rest of the namespace path
                for (path[1..]) |segment_id| {
                    const seg_idx = try self.makeStringConstant(self.tree.getString(segment_id));
                    try self.emitOpWithOperand(.op_get_property, .op_get_property_wide, seg_idx);
                    try self.emitInlineCacheIndex();
                }
            },
            .import_stmt => {
                const is_stmt = self.tree.importStmt(node);
                const path_str = self.tree.getString(is_stmt.path);

                const path_val = try self.vm.allocateString(path_str);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(path_val);
                const path_idx = try self.makeConstant(path_val);
                _ = self.vm.pop();

                try self.emitOpWithOperand(.op_import, .op_import_wide, path_idx);

                // MVP: Standard import for side-effects. Ignore returned module.
                // Destructuring explicit symbols will be implemented in future phases.
                try self.emitOp(.op_pop);
                try self.emitOp(.op_nil);
            },
            .export_stmt => {
                // MVP: Yields nil. Real exporting requires writing to the VM's active export Map.
                try self.emitOp(.op_nil);
            },
            .def_stmt, .lambda_expr => {
                var params: []const ast.Param = &.{};
                var body_node: ast.NodeIndex = .none;
                var def_name_id: ast.StringId = .none;

                if (node.tag == .def_stmt) {
                    const ds = self.tree.defStmt(node);
                    params = self.tree.getParams(ds.params);
                    body_node = ds.body;
                    def_name_id = ds.name;
                } else {
                    const ls = self.tree.lambdaExpr(node);
                    params = self.tree.getParams(ls.params);
                    body_node = ls.body;
                }

                const is_method = (node.tag == .def_stmt);
                const name_str = if (def_name_id != .none) self.tree.getString(def_name_id) else null;
                try self.compileClosureBlock(params, body_node, name_str, is_method);

                if (node.tag == .def_stmt) {
                    const sym = self.symbols[@intFromEnum(node_idx)];
                    if (self.enclosing == null or sym.kind == .global) {
                        const def_name_str = self.tree.getString(def_name_id);
                        if (compiler_intrinsics.has(def_name_str)) {
                            return error.ProtectedSymbol;
                        }

                        const name_idx = try self.makeStringConstant(self.tree.getString(def_name_id));
                        try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
                        try self.emitOp(.op_nil);
                    } else {
                        const slot = self.getNextLocalSlot();
                        try self.addLocal(def_name_id, slot);
                        try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
                    }
                }
            },
            .index_access => {
                const ia = self.tree.indexAccess(node);
                try self.compileNode(ia.target);
                try self.compileNode(ia.index);
                try self.emitOp(.op_get_index);
            },
            .index_assignment => {
                const ia = self.tree.indexAssignment(node);

                try self.compileNode(ia.target);
                try self.compileNode(ia.index);

                if (ia.op) |op| {
                    // Stack is currently: [target, index]

                    // Duplicate BOTH so we can fetch the current value without losing the target/index pointers for the setter
                    try self.emitOp(.op_dup_two);
                    // Stack is now: [target, index, target, index]

                    try self.emitOp(.op_get_index);
                    // Stack is now: [target, index, current_val]

                    try self.compileNode(ia.value);
                    // Stack is now: [target, index, current_val, rhs_val]

                    switch (op) {
                        .add => try self.emitOp(.op_add),
                        .subtract => try self.emitOp(.op_subtract),
                        .multiply => try self.emitOp(.op_multiply),
                        .divide => try self.emitOp(.op_divide),
                        else => return error.UnknownNode,
                    }
                    // Stack is now: [target, index, new_val]
                } else {
                    try self.compileNode(ia.value); // Stack: [target, index, new_val]
                }

                // op_set_index consumes [target, index, new_val] and pushes [new_val] back
                try self.emitOp(.op_set_index);
            },
            .unary_op => {
                const un_expr = self.tree.unaryExpr(node);
                try self.compileNode(un_expr.operand);
                switch (un_expr.op) {
                    .negate => try self.emitOp(.op_negate),
                    .not => try self.emitOp(.op_not),
                    else => return error.UnknownNode,
                }
            },
            .binary_op => try self.compileBinaryOp(node),
            .array_literal => try self.compileArrayLiteral(node),
            .hash_literal => try self.compileHashLiteral(node),
            .case_stmt => try self.compileCaseStmt(node),
            .begin_stmt => try self.compileBeginStmt(node),
            .method_call => try self.compileMethodCall(node),
            .if_stmt => {
                const if_payload = self.tree.ifStmt(node);
                try self.compileNode(if_payload.condition);
                if (if_payload.is_unless) try self.emitOp(.op_not);

                const then_jump = try self.emitJump(.op_jump_if_false);
                try self.emitOp(.op_pop); // pop cond for true branch

                try self.compileNode(if_payload.then_branch);

                // Force sync before branch jump
                self.current_stack_depth = expected_entry_depth + 1;
                const else_jump = try self.emitJump(.op_jump);

                self.patchJump(then_jump);

                // False branch: VM stack still has the condition on it
                self.current_stack_depth = expected_entry_depth + 1;

                try self.emitOp(.op_pop); // pop cond for false branch

                if (if_payload.else_branch != .none) {
                    try self.compileNode(if_payload.else_branch);
                } else {
                    try self.emitOp(.op_nil);
                }

                self.patchJump(else_jump);
                // Guarantee perfectly balanced exit
                self.current_stack_depth = expected_entry_depth + 1;
            },
            .self_expr => {
                try self.emitPushSelf();
            },
            .while_stmt => {
                const while_payload = self.tree.whileStmt(node);
                const loop_start = self.current_chunk.code.items.len;

                // Push loop state WITH stack depth
                try self.loops.append(self.allocator, .{
                    .start = loop_start,
                    .depth = self.current_stack_depth,
                });

                try self.compileNode(while_payload.condition);
                if (while_payload.is_until) try self.emitOp(.op_not);

                const exit_jump = try self.emitJump(.op_jump_if_false);
                try self.emitOp(.op_pop); // Clean up condition

                try self.compileNode(while_payload.body);

                // Force sync before loop jump
                self.current_stack_depth = expected_entry_depth + 1;
                try self.emitOp(.op_pop); // Pop the body's yielded result

                try self.emitLoop(loop_start);

                self.patchJump(exit_jump);

                // VM stack still has the condition on it when it jumps here!
                self.current_stack_depth = expected_entry_depth + 1;

                try self.emitOp(.op_pop);
                try self.emitOp(.op_nil); // Natural exit yields nil

                // Pop loop state and safely patch all 'break' jump addresses
                var cur_loop = self.loops.pop().?;
                defer cur_loop.exit_jumps.deinit(self.allocator);
                for (cur_loop.exit_jumps.items) |jmp| {
                    self.patchJump(jmp);
                }

                // Guarantee perfectly balanced exit
                self.current_stack_depth = expected_entry_depth + 1;
            },
            .ternary_op => {
                const ternary = self.tree.ternaryExpr(node);
                try self.compileNode(ternary.condition);
                const then_jump = try self.emitJump(.op_jump_if_false);
                try self.emitOp(.op_pop); // pop condition if true
                try self.compileNode(ternary.then_branch);
                const else_jump = try self.emitJump(.op_jump);

                self.patchJump(then_jump);

                // False branch: VM stack still has the condition on it!
                self.current_stack_depth = expected_entry_depth + 1;

                try self.emitOp(.op_pop); // pop condition if false
                try self.compileNode(ternary.else_branch);
                self.patchJump(else_jump);
            },
            .range => {
                const r = self.tree.range(node);
                try self.compileNode(r.start);
                try self.compileNode(r.end);

                if (r.step != .none) {
                    try self.compileNode(r.step);
                } else {
                    try self.emitConstant(value.Value.initNumber(1.0)); // Default step
                }

                try self.emitOp(.op_build_range);
                try self.emitByte(if (r.is_exclusive) 1 else 0);

                self.simulatePop(3); // Pops start, end, step
                self.simulatePush(1); // Pushes ObjRange
            },
            .interpolated_string => {
                const parts = self.tree.getNodes(self.tree.nodeSpan(node));
                for (parts) |part| {
                    try self.compileNode(part);
                }

                if (parts.len > limits.MAX_SHORT_CONSTANTS) return error.TooManyConstants;

                try self.emitOp(.op_interpolate);
                try self.emitByte(@intCast(parts.len));

                self.simulatePop(parts.len);
                self.simulatePush(1); // Pushes the final merged String
            },
            .multiple_assignment => try self.compileMultipleAssignment(node),
            .class_stmt => try self.compileClassStmt(node, node_idx),
            .module_stmt => try self.compileModuleStmt(node),
            .super_call => try self.compileSuperCall(node),
            .property_assignment => {
                const pa = self.tree.propertyAssignment(node);
                const prop_name = self.tree.getString(pa.property);

                const name_idx = try self.makeStringConstant(prop_name);

                try self.compileNode(pa.target); // Stack: [target]

                if (pa.op) |op| {
                    // Duplicate the pointer instead of re-evaluating the AST
                    try self.emitOp(.op_dup); // Stack: [target, target]

                    // Compound assignments must read properties via op_get_property, not op_invoke
                    try self.emitOpWithOperand(.op_get_property, .op_get_property_wide, name_idx);
                    try self.emitInlineCacheIndex();
                    // Stack is now: [target, old_val]

                    try self.compileNode(pa.value); // Stack: [target, old_val, rhs_val]

                    switch (op) {
                        .add => try self.emitOp(.op_add),
                        .subtract => try self.emitOp(.op_subtract),
                        .multiply => try self.emitOp(.op_multiply),
                        .divide => try self.emitOp(.op_divide),
                        else => return error.UnknownNode,
                    }
                    // Stack is now: [target, new_val]
                } else {
                    try self.compileNode(pa.value); // Stack: [target, new_val]
                }

                // op_set_property consumes both target and new_val, then pushes new_val back
                try self.emitOpWithOperand(.op_set_property, .op_set_property_wide, name_idx);
                try self.emitInlineCacheIndex();
            },
            .defined_expr => {
                const target_node = self.tree.getNode(node_idx).?;
                if (self.tree.stringId(target_node) != .none) {
                    const name_id = self.tree.stringId(target_node);
                    if (self.resolveLocal(name_id) != null or (try self.resolveUpvalue(name_id)) != null) {
                        try self.emitOp(.op_true); // Locals are statically known
                    } else {
                        const name_str = self.tree.getString(name_id);
                        const name_idx = try self.makeStringConstant(name_str);
                        try self.emitOpWithOperand(.op_defined, .op_defined_wide, name_idx);
                    }
                } else {
                    try self.emitOp(.op_true);
                }
            },
            .block => {
                const block_payload = self.tree.block(node);
                const stmts = self.tree.getNodes(block_payload.stmts);

                // Unpack destructured block arguments
                const param_nodes = self.tree.getNodes(block_payload.params);
                for (param_nodes, 0..) |p_idx, i| {
                    const p_node = self.tree.getNode(p_idx).?;
                    if (p_node.tag == .array_literal) {
                        // The tuple is sitting in local slot (i + 1) because slot 0 is the closure itself
                        try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, @intCast(i + 1));

                        const elements = self.tree.getNodes(self.tree.nodeSpan(p_node));
                        try self.emitOp(.op_unpack);
                        try self.emitByte(@intCast(elements.len));
                        self.simulatePop(1);
                        self.simulatePush(elements.len);

                        // Unpack in reverse order to match the stack
                        var el_i: usize = elements.len;
                        while (el_i > 0) {
                            el_i -= 1;
                            const el_node = self.tree.getNode(elements[el_i]).?;

                            // Safe Guard against unsupported nested destructuring
                            if (el_node.tag != .identifier) {
                                return error.UnknownNode;
                            }

                            // Re-use your existing destructuring engine
                            const lhs = ast.LhsExpr{
                                .name = self.tree.stringId(el_node),
                                .modifier = null,
                            };
                            try self.compileDestructure(lhs);
                        }
                    }
                }

                if (stmts.len == 0) {
                    try self.emitOp(.op_nil);
                } else {
                    for (stmts, 0..) |stmt_idx, i| {
                        try self.compileNode(stmt_idx);

                        // Unconditionally pop every statement except the last one!
                        if (i < stmts.len - 1) {
                            try self.emitOp(.op_pop);
                        }
                    }
                }
            },
            else => {
                try self.emitOp(.op_nil); // Push dummy value for unknown AST nodes
            },
        }

        // Every compiled node is an expression in KupCAD.
        // It MUST result in exactly ONE net value pushed to the stack
        if (node.tag != .return_stmt and node.tag != .break_stmt and node.tag != .next_stmt and node.tag != .class_stmt and node.tag != .module_stmt) {
            std.debug.assert(self.current_stack_depth == expected_entry_depth + 1);
        }
    }

    fn simulatePush(self: *Compiler, count: usize) void {
        self.current_stack_depth += count;
        if (self.current_stack_depth > self.max_stack_depth) {
            self.max_stack_depth = self.current_stack_depth;
        }
    }

    fn simulatePop(self: *Compiler, count: usize) void {
        std.debug.assert(self.current_stack_depth >= count);
        self.current_stack_depth -= count;
    }

    pub fn emitInlineCacheIndex(self: *Compiler) CompileError!void {
        const ic_idx = self.current_chunk.addInlineCache(self.allocator) catch return error.OutOfMemory;
        try self.emitByte(@intCast((ic_idx >> 8) & 0xff));
        try self.emitByte(@intCast(ic_idx & 0xff));
    }

    fn emitByte(self: *Compiler, byte: u8) CompileError!void {
        self.current_chunk.write(self.allocator, byte, self.current_source_offset) catch return error.OutOfMemory;
    }

    pub fn emitOp(self: *Compiler, op: chunk.OpCode) CompileError!void {
        try self.emitByte(@intFromEnum(op));

        // Automatically apply static stack effects
        if (getStaticStackEffect(op)) |effect| {
            if (effect > 0) {
                self.simulatePush(@intCast(effect));
            } else if (effect < 0) {
                self.simulatePop(@intCast(-effect));
            }
        }
    }

    pub fn makeConstant(self: *Compiler, val: value.Value) CompileError!usize {
        // Linear scan over constants to reuse existing matching values
        for (self.current_chunk.constants.items, 0..) |existing, i| {
            if (self.vm.valuesEqual(existing, val)) return i;
        }

        const index = self.current_chunk.addConstant(self.allocator, val) catch return error.OutOfMemory;
        if (index > limits.MAX_CONSTANTS) return error.TooManyConstants;
        return index;
    }

    fn emitConstant(self: *Compiler, val: value.Value) CompileError!void {
        const index = try self.makeConstant(val);
        try self.emitOpWithOperand(.op_constant, .op_constant_wide, index);
    }

    fn emitJump(self: *Compiler, op: chunk.OpCode) CompileError!usize {
        try self.emitOp(op);
        // Write 4 bytes for a 32-bit jump offset
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        return self.current_chunk.code.items.len - 4;
    }

    fn patchJump(self: *Compiler, offset: usize) void {
        const jump = self.current_chunk.code.items.len - offset - 4;
        std.debug.assert(jump <= 0xFFFFFFFF); // Assert it fits in 32 bits
        self.writeJumpOffset(offset, jump);
    }

    fn emitLoop(self: *Compiler, loop_start: usize) CompileError!void {
        try self.emitOp(.op_loop);
        const jump = self.current_chunk.code.items.len - loop_start + 4;
        std.debug.assert(jump <= 0xFFFFFFFF);
        try self.emitByte(@intCast((jump >> 24) & 0xff));
        try self.emitByte(@intCast((jump >> 16) & 0xff));
        try self.emitByte(@intCast((jump >> 8) & 0xff));
        try self.emitByte(@intCast(jump & 0xff));
    }

    fn makeMethodNameConstant(self: *Compiler, name: []const u8, is_private: bool) CompileError!usize {
        if (is_private) {
            var name_buf: [256]u8 = undefined;
            const mangled_name = std.fmt.bufPrint(&name_buf, "@private:{s}", .{name}) catch return error.OutOfMemory;
            return self.makeStringConstant(mangled_name);
        }
        return self.makeStringConstant(name);
    }

    /// Unifies Positional and Keyword Argument compilation for Method and Super calls
    fn compileCallArguments(self: *Compiler, args: []const ast.NamedArg) CompileError!usize {
        var pos_count: usize = 0;
        var kw_count: usize = 0;

        // 1. Compile Positional Arguments
        for (args) |arg| {
            if (arg.name == .none and (arg.modifier == null or arg.modifier.? != .block)) {
                try self.compileNode(arg.value);
                pos_count += 1;
            }
        }

        // 2. Compile Keyword Arguments
        for (args) |arg| {
            if (arg.name != .none and (arg.modifier == null or arg.modifier.? != .block)) {
                const name_idx = try self.makeSymbolConstant(self.tree.getString(arg.name));
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, name_idx);
                try self.compileNode(arg.value);
                kw_count += 1;
            }
        }

        // 3. Pack Keyword Arguments into a trailing Map
        if (kw_count > 0) {
            if (kw_count <= limits.MAX_SHORT_CONSTANTS) {
                try self.emitOp(.op_build_map);
                try self.emitByte(@intCast(kw_count));
            } else {
                try self.emitOp(.op_build_map_wide);
                try self.emitByte(@intCast((kw_count >> 8) & 0xff));
                try self.emitByte(@intCast(kw_count & 0xff));
            }

            self.simulatePop(kw_count * 2);
            self.simulatePush(1);
            pos_count += 1; // The Hash Map becomes the final trailing positional argument!
        }

        return pos_count;
    }

    /// Unifies Method, Macro, and Statement parsing for Classes, Modules, and Singleton blocks
    fn compileNamespaceBody(self: *Compiler, stmts: []const ast.NodeIndex, is_singleton: bool) CompileError!void {
        for (stmts) |stmt_idx| {
            const stmt_node = self.tree.getNode(stmt_idx).?;
            if (stmt_node.tag == .def_stmt) {
                const ds = self.tree.defStmt(stmt_node);
                const method_name = self.tree.getString(ds.name);

                var is_class_method = ds.is_class_method or std.mem.startsWith(u8, method_name, "self.");
                if (is_singleton) is_class_method = true; // In `class << self`, all methods are class methods

                var final_name = method_name;
                if (std.mem.startsWith(u8, method_name, "self.")) {
                    final_name = method_name[5..];
                }

                const m_name_idx = try self.makeMethodNameConstant(final_name, ds.is_private);
                const params = self.tree.getParams(ds.params);

                try self.compileClosureBlock(params, ds.body, final_name, true);
                try self.emitOpWithOperand(if (is_class_method) .op_class_method else .op_method, if (is_class_method) .op_class_method_wide else .op_method_wide, m_name_idx);
            } else if (try self.handleMacroMethod(stmt_node, is_singleton)) {
                // Macro handled successfully
            } else {
                try self.compileNode(stmt_idx);
                try self.emitOp(.op_pop);
            }
        }
    }

    /// Emits the fully qualified alias for nested modules and classes
    fn defineFullyQualifiedNamespace(self: *Compiler, short_name: []const u8) CompileError!void {
        const fq_name = try self.buildFullyQualifiedPath(short_name, self.namespace_stack.items.len - 1);
        defer self.allocator.free(fq_name);

        if (!std.mem.eql(u8, fq_name, short_name)) {
            const fq_name_idx = try self.makeStringConstant(fq_name);
            try self.emitOp(.op_dup);
            try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, fq_name_idx);
        }
    }

    pub fn makeStringConstant(self: *Compiler, text: []const u8) CompileError!usize {
        const str_val = try self.vm.allocateString(text);
        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
        self.vm.push(str_val);
        const idx = try self.makeConstant(str_val);
        _ = self.vm.pop();
        return idx;
    }

    fn makeSymbolConstant(self: *Compiler, text: []const u8) CompileError!usize {
        const sym_val = try self.vm.allocateSymbol(text);
        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
        self.vm.push(sym_val);
        const idx = try self.makeConstant(sym_val);
        _ = self.vm.pop();
        return idx;
    }

    pub fn emitOpWithOperand(self: *Compiler, short_op: chunk.OpCode, wide_op: chunk.OpCode, operand: usize) CompileError!void {
        if (short_op == .op_get_local or short_op == .op_set_local) {
            if (operand > self.max_local_slot) self.max_local_slot = operand;
        }

        if (operand <= limits.MAX_SHORT_CONSTANTS) {
            try self.emitOp(short_op);
            try self.emitByte(@intCast(operand));
        } else {
            try self.emitOp(wide_op);
            try self.emitByte(@intCast((operand >> 8) & 0xff)); // High byte
            try self.emitByte(@intCast(operand & 0xff)); // Low byte
        }
    }

    fn compileClosureBlock(self: *Compiler, params: []const ast.Param, body_node: ast.NodeIndex, func_name: ?[]const u8, is_method: bool) CompileError!void {
        const func = try self.vm.gc.allocateFunction(self.vm);

        // Assign the method name so `super()` can dynamically look up the hierarchy
        if (func_name) |n| {
            const str_val = try self.vm.allocateString(n);
            func.name = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", str_val.asObj())));
        }

        var positional_count: usize = 0;
        var splat_pos: ?u8 = null;
        var has_kwargs = false;

        for (params) |p| {
            if (p.modifier != null) {
                if (p.modifier.? == .splat or p.modifier.? == .double_splat) {
                    if (p.modifier.? == .splat) splat_pos = @intCast(positional_count);
                }
            }
            if (p.is_keyword or (p.modifier != null and p.modifier.? == .double_splat)) {
                has_kwargs = true;
            } else if (p.modifier == null or p.modifier.? == .splat) {
                positional_count += 1;
            }
        }

        // Kwargs are passed as a single Dictionary map taking exactly 1 positional slot
        const kwarg_slot_offset = positional_count;
        if (has_kwargs) positional_count += 1;
        // Include the implicit block slot in the arity so the VM pads it with nil when omitted
        func.arity = @intCast(positional_count);
        func.splat_pos = splat_pos;

        // Protect the function from GC while compiling the child block!
        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
        self.vm.push(value.Value.initObj(&func.obj));
        errdefer _ = self.vm.pop();

        const child_chunk = try self.allocator.create(chunk.Chunk);
        child_chunk.* = chunk.Chunk.init();
        func.chunk = child_chunk;

        var child_compiler = Compiler{
            .allocator = self.allocator,
            .tree = self.tree,
            .script_globals = .empty,
            .symbols = self.symbols,
            .token_starts = self.token_starts,
            .current_chunk = child_chunk,
            .vm = self.vm,
            .enclosing = self,
            .function = func,
            .is_method = is_method,
            .active_namespaces = self.active_namespaces,
            .namespace_stack = try self.namespace_stack.clone(self.allocator), // Inherit lexical scope dynamically
            .upvalues = .empty,
            .locals = .empty,
            .loops = .empty,
            .current_stack_depth = 0,
            .max_stack_depth = 0,
            .current_source_offset = self.current_source_offset,
            .max_local_slot = 0,
            .seeded_locals = &.{},
            .seeded_slot_offset = 0,
        };
        defer child_compiler.deinit();

        // Reserve slot 0 for the closure itself
        try child_compiler.addLocal(.none, 0);

        var current_slot: u8 = 1;
        // The kwarg map goes AFTER the standard positionals
        const map_slot = if (has_kwargs) @as(u8, @intCast(kwarg_slot_offset + 1)) else 0;

        for (params) |param| {
            if (param.modifier != null and param.modifier.? == .block) {
                try child_compiler.addLocal(param.name, @intCast(positional_count + 1));
            } else if (param.is_keyword) {
                // Handled dynamically via virtual slots below
            } else if (param.modifier != null and param.modifier.? == .double_splat) {
                try child_compiler.addLocal(param.name, map_slot);
            } else {
                try child_compiler.addLocal(param.name, current_slot);
                current_slot += 1;
            }
        }

        // Reserve slot (positional_count + 1) for the implicit block slot safely
        while (child_compiler.locals.items.len <= positional_count + 1) {
            try child_compiler.addLocal(.none, @intCast(child_compiler.locals.items.len));
        }

        var virtual_slot: u8 = @intCast(positional_count + 2);
        var num_virtuals: usize = 0;
        for (params) |param| {
            if (param.is_keyword) {
                try child_compiler.addLocal(param.name, virtual_slot);
                virtual_slot += 1;
                num_virtuals += 1;
            }
        }

        if (has_kwargs) {
            for (params) |param| {
                if (param.is_keyword) {
                    const name_str = self.tree.getString(param.name);
                    const kw_name_idx = try child_compiler.makeSymbolConstant(name_str);

                    if (kw_name_idx <= limits.MAX_SHORT_CONSTANTS) {
                        try child_compiler.emitOp(.op_extract_kwarg);
                        try child_compiler.emitByte(map_slot);
                        try child_compiler.emitByte(@intCast(kw_name_idx));
                    } else {
                        try child_compiler.emitOp(.op_extract_kwarg_wide);
                        try child_compiler.emitByte(map_slot);
                        try child_compiler.emitByte(@intCast((kw_name_idx >> 8) & 0xff));
                        try child_compiler.emitByte(@intCast(kw_name_idx & 0xff));
                    }

                    if (param.default_value != .none) {
                        // The extracted value is already sitting on top of the stack.
                        // Peek at it. If it is NOT nil, jump directly to setting the local variable.
                        const skip_default_jump = try child_compiler.emitJump(.op_jump_if_not_nil);

                        // If it IS nil, pop the nil and evaluate the default AST expression
                        try child_compiler.emitOp(.op_pop);
                        try child_compiler.compileNode(param.default_value);

                        child_compiler.patchJump(skip_default_jump);
                    }

                    const local_slot = child_compiler.resolveLocal(param.name).?;
                    try child_compiler.emitOpWithOperand(.op_set_local, .op_set_local_wide, local_slot);
                    try child_compiler.emitOp(.op_pop);
                }
            }
        }

        // Positional Parameter Defaults Handling
        for (params) |param| {
            if (!param.is_keyword and param.modifier == null and param.default_value != .none) {
                if (child_compiler.resolveLocal(param.name)) |local_slot| {
                    // Read the padded parameter from the stack
                    try child_compiler.emitOpWithOperand(.op_get_local, .op_get_local_wide, local_slot);

                    // If the caller provided an argument (it is NOT nil), jump over the default assignment
                    const skip_default_jump = try child_compiler.emitJump(.op_jump_if_not_nil);

                    // If it IS nil, pop the nil and evaluate the default AST expression
                    try child_compiler.emitOp(.op_pop);
                    try child_compiler.compileNode(param.default_value);

                    // Store the evaluated default back into the local variable slot
                    try child_compiler.emitOpWithOperand(.op_set_local, .op_set_local_wide, local_slot);

                    // The landing zone for the jump
                    child_compiler.patchJump(skip_default_jump);

                    // Clean up the stack (pop the result of set_local or the unskipped get_local)
                    try child_compiler.emitOp(.op_pop);
                }
            }
        }

        try child_compiler.compile(body_node);
        _ = self.vm.pop();

        // Extract the exact local footprint from the child AFTER compiling
        func.local_count = @max(child_compiler.locals.items.len, child_compiler.max_local_slot + 1);

        const func_val = value.Value.initObj(&func.obj);
        const func_idx = try self.makeConstant(func_val);

        try self.emitOpWithOperand(.op_closure, .op_closure_wide, func_idx);

        for (child_compiler.upvalues.items) |upv| {
            try self.emitByte(if (upv.is_local) 1 else 0);
            try self.emitByte(@intCast((upv.index >> 8) & 0xff));
            try self.emitByte(@intCast(upv.index & 0xff));
        }
    }

    fn compileDestructure(self: *Compiler, target: anytype) CompileError!void {
        // Assign the unpacked value currently on top of the stack to the target identifier
        if (target.name != .none) {
            // Provide a dummy symbol. The classification engine will figure out if it's a
            // constant, class variable, existing local, upvalue, or global automatically!
            const dummy_sym = resolver.ResolvedSymbol{ .kind = .local, .index = 0 };

            try self.emitVariableStore(target.name, dummy_sym);

            // `emitVariableStore` is designed for standard assignments, so it ALWAYS leaves
            // the assigned value on the stack. Destructuring expects to consume the value
            // to move to the next array element, so we must pop it unconditionally here.
            try self.emitOp(.op_pop);
        } else {
            // Unhandled pattern or skipped element (e.g., `_`): pop to maintain stack equilibrium
            try self.emitOp(.op_pop);
        }
    }

    fn compileArrayLiteral(self: *Compiler, node: *const ast.Node) CompileError!void {
        const elements = self.tree.getNodes(self.tree.nodeSpan(node));
        if (elements.len == 0) {
            try self.emitOp(.op_build_array);
            try self.emitByte(0);
            self.simulatePush(1);
            return;
        }

        var has_splat = false;
        for (elements) |elem| {
            if (self.tree.getNode(elem).?.tag == .splat_expr) has_splat = true;
        }

        // Fallback to Dynamic Build Mode if array contains splats OR exceeds 65,535 elements
        const use_static_build = !has_splat and elements.len <= limits.MAX_CONSTANTS;

        if (use_static_build) {
            for (elements) |elem| try self.compileNode(elem);

            if (elements.len <= limits.MAX_SHORT_CONSTANTS) {
                try self.emitOp(.op_build_array);
                try self.emitByte(@intCast(elements.len));
            } else {
                try self.emitOp(.op_build_array_wide);
                try self.emitByte(@intCast((elements.len >> 8) & 0xff));
                try self.emitByte(@intCast(elements.len & 0xff));
            }

            self.simulatePop(elements.len);
            self.simulatePush(1);
        } else {
            // Dynamic Build Mode (Handles splats and point clouds/arrays exceeding 65,535 items)
            try self.emitOp(.op_build_array);
            try self.emitByte(0); // Create empty array
            self.simulatePush(1);

            for (elements) |elem| {
                const el_node = self.tree.getNode(elem).?;
                if (el_node.tag == .splat_expr) {
                    try self.compileNode(self.tree.nodeIndex(el_node));
                    try self.emitOp(.op_array_spread);
                } else {
                    try self.compileNode(elem);
                    try self.emitOp(.op_array_push);
                }
            }
        }
    }

    fn compileHashLiteral(self: *Compiler, node: *const ast.Node) CompileError!void {
        const entries = self.tree.getHashEntries(self.tree.nodeSpan(node));
        if (entries.len == 0) {
            try self.emitOp(.op_build_map);
            try self.emitByte(0);
            self.simulatePush(1);
            return;
        }

        var has_splat = false;
        for (entries) |entry| {
            if (self.tree.getNode(entry.key).?.tag == .double_splat_expr) has_splat = true;
        }

        if (!has_splat) {
            for (entries) |entry| {
                const key_node = self.tree.getNode(entry.key).?;
                if (key_node.tag == .identifier) {
                    const str_content = self.tree.getString(self.tree.stringId(key_node));
                    const str_idx = try self.makeStringConstant(str_content);
                    try self.emitOpWithOperand(.op_constant, .op_constant_wide, str_idx);
                } else {
                    try self.compileNode(entry.key);
                }
                try self.compileNode(entry.value);
            }

            if (entries.len > limits.MAX_HASH_ENTRIES) return error.TooManyConstants;

            if (entries.len <= limits.MAX_SHORT_CONSTANTS) {
                try self.emitOp(.op_build_map);
                try self.emitByte(@intCast(entries.len));
            } else {
                try self.emitOp(.op_build_map_wide);
                try self.emitByte(@intCast((entries.len >> 8) & 0xff));
                try self.emitByte(@intCast(entries.len & 0xff));
            }

            self.simulatePop(entries.len * 2);
            self.simulatePush(1);
        } else {
            // Dynamic Build Mode
            try self.emitOp(.op_build_map);
            try self.emitByte(0);
            self.simulatePush(1);

            for (entries) |entry| {
                const key_node = self.tree.getNode(entry.key).?;
                if (key_node.tag == .double_splat_expr) {
                    try self.compileNode(self.tree.nodeIndex(key_node));
                    try self.emitOp(.op_map_spread);
                } else {
                    if (key_node.tag == .identifier) {
                        const str_content = self.tree.getString(self.tree.stringId(key_node));
                        const str_val = try self.vm.allocateString(str_content);
                        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                        self.vm.push(str_val);
                        const str_idx = try self.makeConstant(str_val);
                        _ = self.vm.pop();
                        try self.emitOpWithOperand(.op_constant, .op_constant_wide, str_idx);
                    } else {
                        try self.compileNode(entry.key);
                    }
                    try self.compileNode(entry.value);
                    try self.emitOp(.op_map_insert);
                }
            }
        }
    }

    fn compileCaseStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        const cs = self.tree.caseStmt(node);
        const saved_depth = self.current_stack_depth;
        const branches = self.tree.getWhenBranches(cs.when_branches);
        const has_cond = cs.condition != .none;

        // --- Heuristic: Can we use a Fast Jump Table? ---
        var can_use_jump_table = has_cond;
        var total_conditions: u16 = 0;

        if (can_use_jump_table) {
            for (branches) |branch| {
                const conds = self.tree.getNodes(branch.conditions);
                for (conds) |cond_idx| {
                    const c_node = self.tree.getNode(cond_idx).?;
                    if (c_node.tag != .number and c_node.tag != .string) {
                        can_use_jump_table = false;
                        break;
                    }
                    total_conditions += 1;
                }
                if (!can_use_jump_table) break;
            }
        }

        if (can_use_jump_table and total_conditions > 0) {
            // ====== FAST PATH: OP_SWITCH ======
            try self.compileNode(cs.condition);
            try self.emitOpWithOperand(.op_switch, .op_switch_wide, total_conditions);

            // Pre-allocate the jump table in bytecode (6 bytes per entry)
            const table_start_offset = self.current_chunk.code.items.len;
            for (0..total_conditions) |_| {
                try self.emitByte(0); // const_high
                try self.emitByte(0); // const_low
                try self.emitByte(0xFF); // jump b3
                try self.emitByte(0xFF); // jump b2
                try self.emitByte(0xFF); // jump b1
                try self.emitByte(0xFF); // jump b0
            }
            const default_jump_offset = self.current_chunk.code.items.len;
            try self.emitByte(0xFF); // default b3
            try self.emitByte(0xFF); // default b2
            try self.emitByte(0xFF); // default b1
            try self.emitByte(0xFF); // default b0

            var condition_idx: usize = 0;
            var end_jumps: std.ArrayListUnmanaged(usize) = .empty;
            defer end_jumps.deinit(self.allocator);

            for (branches) |branch| {
                const body_jump_target = self.current_chunk.code.items.len;
                const conds = self.tree.getNodes(branch.conditions);

                self.current_stack_depth = saved_depth;

                // Backpatch table entries
                for (conds) |cond_node_idx| {
                    const c_node = self.tree.getNode(cond_node_idx).?;
                    const table_idx = table_start_offset + (condition_idx * 6);

                    var raw_idx: usize = 0;
                    if (c_node.tag == .number) {
                        raw_idx = try self.makeConstant(value.Value.initNumber(self.tree.number(c_node)));
                    } else if (c_node.tag == .string) {
                        const str_content = self.tree.getString(self.tree.stringId(c_node));
                        raw_idx = try self.makeStringConstant(str_content);
                    }

                    self.current_chunk.code.items[table_idx] = @intCast((raw_idx >> 8) & 0xFF);
                    self.current_chunk.code.items[table_idx + 1] = @intCast(raw_idx & 0xFF);

                    const offset = body_jump_target - (default_jump_offset + 4);
                    self.writeJumpOffset(table_idx + 2, offset);
                    condition_idx += 1;
                }

                try self.compileNode(branch.body);
                try end_jumps.append(self.allocator, try self.emitJump(.op_jump));
            }

            // Backpatch Default Branch
            const default_target = self.current_chunk.code.items.len;
            const d_offset = default_target - (default_jump_offset + 4);
            self.writeJumpOffset(default_jump_offset, d_offset);

            self.current_stack_depth = saved_depth;

            if (cs.else_branch != .none) {
                try self.compileNode(cs.else_branch);
            } else {
                try self.emitOp(.op_nil);
            }

            for (end_jumps.items) |jmp| {
                self.patchJump(jmp);
            }
            self.current_stack_depth = saved_depth + 1;
        } else {
            // ====== LINEAR FALLBACK PATH ======
            if (has_cond) {
                try self.compileNode(cs.condition);
            }

            var end_jumps: std.ArrayListUnmanaged(usize) = .empty;
            defer end_jumps.deinit(self.allocator);

            for (branches) |branch| {
                const conds = self.tree.getNodes(branch.conditions);
                for (conds) |cond_idx| {
                    if (has_cond) {
                        self.current_stack_depth = saved_depth + 1; // Condition is on stack
                        try self.emitOp(.op_dup);
                        try self.compileNode(cond_idx);
                        try self.emitOp(.op_case_equal);
                    } else {
                        self.current_stack_depth = saved_depth;
                        try self.compileNode(cond_idx);
                    }

                    const skip_jump = try self.emitJump(.op_jump_if_false);
                    try self.emitOp(.op_pop); // pop false
                    if (has_cond) try self.emitOp(.op_pop); // pop cond

                    try self.compileNode(branch.body);
                    try end_jumps.append(self.allocator, try self.emitJump(.op_jump));

                    if (has_cond) {
                        self.current_stack_depth = saved_depth + 2; // Jump lands here with false + cond on stack
                    } else {
                        self.current_stack_depth = saved_depth + 1; // Jump lands here with false
                    }

                    self.patchJump(skip_jump);
                    try self.emitOp(.op_pop); // pop false
                }
            }

            if (has_cond) {
                self.current_stack_depth = saved_depth + 1; // Condition is on stack
                try self.emitOp(.op_pop);
            } else {
                self.current_stack_depth = saved_depth;
            }

            if (cs.else_branch != .none) {
                try self.compileNode(cs.else_branch);
            } else {
                try self.emitOp(.op_nil);
            }

            for (end_jumps.items) |jmp| {
                self.patchJump(jmp);
            }
            self.current_stack_depth = saved_depth + 1;
        }
    }

    fn compileBeginStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        const bs = self.tree.beginStmt(node);
        const saved_depth = self.current_stack_depth;

        const rescues = self.tree.getRescueClauses(bs.rescues);
        var rescue_jump: usize = 0;

        if (rescues.len > 0) {
            rescue_jump = try self.emitJump(.op_setup_rescue);
        }

        try self.compileNode(bs.body);

        if (rescues.len > 0) {
            try self.emitOp(.op_pop_rescue);
        }

        const end_jump = try self.emitJump(.op_jump);

        if (rescues.len > 0) {
            self.patchJump(rescue_jump);
            // Reset compiler stack depth to the begin block's entry depth
            self.current_stack_depth = saved_depth;

            self.simulatePush(1); // Simulator: op_throw pushed the error value on the stack
            const error_depth = self.current_stack_depth; // Save the stack depth!
            var rescue_end_jumps: std.ArrayListUnmanaged(usize) = .empty;
            defer rescue_end_jumps.deinit(self.allocator);

            var next_rescue_jump: ?usize = null;

            for (rescues) |rescue| {
                self.current_stack_depth = error_depth; // Reset for each rescue block
                if (next_rescue_jump) |jmp| {
                    self.patchJump(jmp);
                }
                next_rescue_jump = null;

                const errors = self.tree.getStringLists(rescue.errors);
                var match_jumps: std.ArrayListUnmanaged(usize) = .empty;
                defer match_jumps.deinit(self.allocator);

                if (errors.len > 0) {
                    for (errors) |err_id| {
                        self.current_stack_depth = error_depth; // Reset for each type check
                        const name_idx = try self.makeStringConstant(self.tree.getString(err_id));
                        try self.emitOp(.op_dup); // Copy error payload
                        try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, name_idx);
                        try self.emitOp(.op_is_instance);

                        const skip_jump = try self.emitJump(.op_jump_if_false);
                        try self.emitOp(.op_pop); // Discard True

                        try match_jumps.append(self.allocator, try self.emitJump(.op_jump));

                        self.current_stack_depth = error_depth + 1; // False branch has error + false
                        self.patchJump(skip_jump);
                        try self.emitOp(.op_pop); // Discard False
                    }
                    // If no error type matched, jump to the next rescue block
                    next_rescue_jump = try self.emitJump(.op_jump);
                }

                // --- MATCHED ROUTE ---
                self.current_stack_depth = error_depth; // Jump lands here with error on top
                for (match_jumps.items) |jmp| {
                    self.patchJump(jmp);
                }

                const var_str = self.tree.getString(rescue.variable);
                if (var_str.len > 0) {
                    const name_id = rescue.variable;
                    const dummy_sym = resolver.ResolvedSymbol{ .kind = .local, .index = 0 };
                    try self.emitVariableStore(name_id, dummy_sym);
                }

                // Always pop the temporary error value off the expression stack!
                try self.emitOp(.op_pop);

                try self.compileNode(rescue.body);

                try rescue_end_jumps.append(self.allocator, try self.emitJump(.op_jump));
            }

            // If it fell through ALL rescue blocks without matching, re-throw it!
            if (next_rescue_jump) |jmp| {
                self.current_stack_depth = error_depth;
                self.patchJump(jmp);
                try self.emitOp(.op_throw); // op_throw inherently calls simulatePop(1)
                self.simulatePush(1); // Dead code equilibrium instead of double-popping!
            }

            // Patch all successful rescue block ends to arrive here
            for (rescue_end_jumps.items) |jmp| {
                self.patchJump(jmp);
            }
            self.current_stack_depth = error_depth; // The block successfully yields 1 value (error_depth is depth + 1)
        }

        self.patchJump(end_jump);

        if (bs.ensure_body != .none) {
            try self.compileNode(bs.ensure_body);
            try self.emitOp(.op_pop); // discard ensure block output
        }
    }

    fn compileBinaryOp(self: *Compiler, node: *const ast.Node) CompileError!void {
        const bin_expr = self.tree.binaryExpr(node);

        // Handle Short-Circuiting Logical Operators BEFORE compiling the right side!
        if (bin_expr.op == .logical_and) {
            try self.compileNode(bin_expr.left);
            const end_jump = try self.emitJump(.op_jump_if_false);
            try self.emitOp(.op_pop); // pop the true left value
            try self.compileNode(bin_expr.right);
            self.patchJump(end_jump);
            return;
        } else if (bin_expr.op == .logical_or) {
            try self.compileNode(bin_expr.left);
            const else_jump = try self.emitJump(.op_jump_if_false);
            const end_jump = try self.emitJump(.op_jump); // If true, skip right side
            self.patchJump(else_jump); // If false, land here
            try self.emitOp(.op_pop); // pop the false left value
            try self.compileNode(bin_expr.right);
            self.patchJump(end_jump); // True branch lands here
            return;
        }

        // Standard Binary Operators
        try self.compileNode(bin_expr.left);
        try self.compileNode(bin_expr.right);

        switch (bin_expr.op) {
            .add => try self.emitOp(.op_add),
            .subtract => try self.emitOp(.op_subtract),
            .multiply => try self.emitOp(.op_multiply),
            .divide => try self.emitOp(.op_divide),
            .modulo => try self.emitOp(.op_modulo),
            .exponent => try self.emitOp(.op_exponent),
            .equal => try self.emitOp(.op_equal),
            .not_equal => {
                try self.emitOp(.op_equal);
                try self.emitOp(.op_not);
            },
            .less => try self.emitOp(.op_less),
            .greater => try self.emitOp(.op_greater),
            .less_equal => {
                try self.emitOp(.op_greater);
                try self.emitOp(.op_not);
            },
            .greater_equal => {
                try self.emitOp(.op_less);
                try self.emitOp(.op_not);
            },
            .bitwise_and => try self.emitOp(.op_bitwise_and),
            else => return error.UnknownNode,
        }
    }

    fn emitPushSelf(self: *Compiler) CompileError!void {
        if (self.is_method or self.enclosing == null) {
            try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, 0);
        } else {
            // We are in a block. Capture the parent method's `self`
            if (try self.resolveSelfUpvalue()) |upv_idx| {
                try self.emitOp(.op_get_upvalue);
                try self.emitByte(upv_idx);
            } else {
                // Fallback (shouldn't happen in valid code)
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, 0);
            }
        }
    }

    fn emitVariableLoad(self: *Compiler, name_id: ast.StringId, sym: ?resolver.ResolvedSymbol) CompileError!void {
        const name_str = self.tree.getString(name_id);
        const classification = try self.classifyVariable(name_id, sym);

        switch (classification.kind) {
            .constant => {
                if (self.namespace_stack.items.len > 0) {
                    var end_jumps = std.ArrayListUnmanaged(usize).empty;
                    defer end_jumps.deinit(self.allocator);

                    var i: usize = self.namespace_stack.items.len;
                    while (i > 0) {
                        const fq_name = try self.buildFullyQualifiedPath(name_str, i);
                        defer self.allocator.free(fq_name);

                        const fq_idx = try self.makeStringConstant(fq_name);

                        try self.emitOpWithOperand(.op_defined, .op_defined_wide, fq_idx);
                        const skip_jump = try self.emitJump(.op_jump_if_false);
                        try self.emitOp(.op_pop); // pop true

                        try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, fq_idx);
                        try end_jumps.append(self.allocator, try self.emitJump(.op_jump));

                        self.patchJump(skip_jump);
                        try self.emitOp(.op_pop); // pop false
                        i -= 1;
                    }

                    const global_idx = try self.makeStringConstant(name_str);
                    try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, global_idx);

                    for (end_jumps.items) |jmp| self.patchJump(jmp);
                } else {
                    const name_idx = try self.makeStringConstant(name_str);
                    try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, name_idx);
                }
            },
            .class_var => {
                try self.emitPushSelf();
                const name_idx = try self.makeStringConstant(name_str);
                try self.emitOpWithOperand(.op_get_class_var, .op_get_class_var_wide, name_idx);
            },
            .instance_var => {
                try self.emitPushSelf();
                const clean_name = if (name_str.len > 1) name_str[1..] else name_str;
                const name_idx = try self.makeStringConstant(clean_name);
                try self.emitOpWithOperand(.op_get_property, .op_get_property_wide, name_idx);
                try self.emitInlineCacheIndex();
            },
            .local => {
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, classification.index);
            },
            .upvalue => {
                try self.emitOp(.op_get_upvalue);
                try self.emitByte(@intCast(classification.index));
            },
            .global, .new_local => {
                const name_idx = try self.makeStringConstant(name_str);
                try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, name_idx);
            },
        }
    }

    fn emitVariableStore(self: *Compiler, name_id: ast.StringId, sym: resolver.ResolvedSymbol) CompileError!void {
        const name_str = self.tree.getString(name_id);
        const classification = try self.classifyVariable(name_id, sym);

        switch (classification.kind) {
            .constant => {
                const fq_name = try self.buildFullyQualifiedPath(name_str, self.namespace_stack.items.len);
                defer self.allocator.free(fq_name);
                const fq_name_idx = try self.makeStringConstant(fq_name);

                try self.emitOp(.op_dup);
                try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, fq_name_idx);

                if (self.namespace_stack.items.len == 0) {
                    try self.emitOp(.op_dup);
                    const short_name_idx = try self.makeStringConstant(name_str);
                    try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, short_name_idx);
                }
            },
            .class_var => {
                try self.emitPushSelf();
                const name_idx = try self.makeStringConstant(name_str);
                try self.emitOpWithOperand(.op_set_class_var, .op_set_class_var_wide, name_idx);
            },
            .instance_var => {
                // Instance variables are primarily handled in the Assignment AST node directly
                // because they require a Stack Swap (`emitPushSelf` -> evaluate RHS -> Assign).
                // Reaching this branch means we fell through a destructuring assignment or rescue variable mapping.
                unreachable;
            },
            .local => {
                try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, classification.index);
            },
            .upvalue => {
                try self.emitOp(.op_set_upvalue);
                try self.emitByte(@intCast(classification.index));
            },
            .global => {
                if (self.enclosing == null) {
                    try self.script_globals.put(self.allocator, name_str, {});
                }
                try self.emitOp(.op_dup);
                const name_idx = try self.makeStringConstant(name_str);
                try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
            },
            .new_local => {
                const slot = self.getNextLocalSlot();
                try self.addLocal(name_id, @intCast(slot));
                try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
            },
        }
    }

    fn compileMultipleAssignment(self: *Compiler, node: *const ast.Node) CompileError!void {
        const ma = self.tree.multipleAssignment(node);
        const lhs = self.tree.getLhsExprs(ma.lhs);

        for (lhs) |l| {
            if (l.name != .none) {
                const name_id = l.name;
                const name_str = self.tree.getString(name_id);
                if (!std.mem.startsWith(u8, name_str, "@@") and
                    !std.mem.startsWith(u8, name_str, "@") and
                    self.resolveLocal(name_id) == null and
                    (try self.resolveUpvalue(name_id)) == null)
                {
                    const slot = self.getNextLocalSlot();
                    try self.addLocal(name_id, slot);
                }
            }
        }

        try self.compileNode(ma.value);

        var splat_idx: ?usize = null;
        for (lhs, 0..) |l, i| {
            if (l.modifier != null and l.modifier.? == .splat) {
                splat_idx = i;
                break;
            }
        }

        if (splat_idx) |s_idx| {
            const pre_count = s_idx;
            const post_count = lhs.len - 1 - s_idx;
            if (pre_count > limits.MAX_SHORT_CONSTANTS or post_count > limits.MAX_SHORT_CONSTANTS) return error.TooManyConstants;
            try self.emitOp(.op_unpack_splat);
            try self.emitByte(@intCast(pre_count));
            try self.emitByte(@intCast(post_count));
            self.simulatePop(1);
            self.simulatePush(lhs.len);
        } else {
            if (lhs.len > limits.MAX_SHORT_CONSTANTS) return error.TooManyConstants;
            try self.emitOp(.op_unpack);
            try self.emitByte(@intCast(lhs.len));
            self.simulatePop(1);
            self.simulatePush(lhs.len);
        }

        var i: usize = lhs.len;
        while (i > 0) {
            i -= 1;
            try self.compileDestructure(lhs[i]);
        }
        try self.emitOp(.op_nil);
    }

    fn handleMacroMethod(self: *Compiler, stmt_node: *const ast.Node, is_singleton: bool) CompileError!bool {
        if (stmt_node.tag != .method_call) return false;
        const mc = self.tree.methodCall(stmt_node);
        const func_name = self.tree.getString(mc.method_name);

        if (std.mem.eql(u8, func_name, "include") and mc.receiver == .none) {
            const args = self.tree.getNamedArgs(mc.args);
            if (args.len == 1) {
                try self.compileNode(args[0].value);
                try self.emitOp(.op_mixin);
                return true;
            }
        } else if ((std.mem.eql(u8, func_name, "attr_accessor") or std.mem.eql(u8, func_name, "attr_reader") or std.mem.eql(u8, func_name, "attr_writer")) and mc.receiver == .none) {
            const args = self.tree.getNamedArgs(mc.args);
            for (args) |arg| {
                const arg_node = self.tree.getNode(arg.value).?;
                if (arg_node.tag == .symbol or arg_node.tag == .string) {
                    const name_str = self.tree.getString(@as(ast.StringId, @enumFromInt(arg_node.data)));
                    if (std.mem.eql(u8, func_name, "attr_reader") or std.mem.eql(u8, func_name, "attr_accessor")) {
                        try macros.emitAttrReader(self, name_str, is_singleton);
                    }
                    if (std.mem.eql(u8, func_name, "attr_writer") or std.mem.eql(u8, func_name, "attr_accessor")) {
                        try macros.emitAttrWriter(self, name_str, is_singleton);
                    }
                } else {
                    return error.UnknownNode;
                }
            }
            return true;
        }
        return false;
    }

    fn compileClassStmt(self: *Compiler, node: *const ast.Node, node_idx: ast.NodeIndex) CompileError!void {
        self.active_namespaces += 1;
        defer self.active_namespaces -= 1;

        const cs = self.tree.classStmt(node);
        const name_node = self.tree.getNode(cs.name).?;
        const name_id = self.tree.stringId(name_node);
        const name_idx = try self.makeStringConstant(self.tree.getString(name_id));
        const name_str = self.tree.getString(name_id);

        if (compiler_intrinsics.has(name_str)) {
            return error.ProtectedSymbol;
        }

        try self.namespace_stack.append(self.allocator, name_id);
        defer _ = self.namespace_stack.pop();

        try self.emitOpWithOperand(.op_class, .op_class_wide, name_idx);

        if (cs.super_class != .none) {
            try self.compileNode(cs.super_class);
            try self.emitOp(.op_inherit);
        }

        const body_node = self.tree.getNode(cs.body).?;
        const block_payload = self.tree.block(body_node);
        const stmts = self.tree.getNodes(block_payload.stmts);

        // Compile entire class body natively!
        try self.compileNamespaceBody(stmts, false);

        // Export Fully Qualified Name
        try self.defineFullyQualifiedNamespace(name_str);

        const sym = self.symbols[@intFromEnum(node_idx)];
        if (self.active_namespaces > 1) {
            try self.emitOpWithOperand(.op_set_member, .op_set_member_wide, name_idx);
        } else if (sym.kind == .local and self.enclosing != null) {
            const slot = self.getNextLocalSlot();
            try self.addLocal(name_id, slot);
            try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
        } else {
            try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
            try self.emitOp(.op_nil);
        }
    }

    fn compileModuleStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        self.active_namespaces += 1;
        defer self.active_namespaces -= 1;

        const ms = self.tree.moduleStmt(node);
        const name_id = ms.name;
        const name_str = self.tree.getString(name_id);
        const name_idx = try self.makeStringConstant(name_str);

        try self.namespace_stack.append(self.allocator, name_id);
        defer _ = self.namespace_stack.pop();

        try self.emitOpWithOperand(.op_module, .op_module_wide, name_idx);

        const body_node = self.tree.getNode(ms.body).?;
        const block_payload = self.tree.block(body_node);
        const stmts = self.tree.getNodes(block_payload.stmts);

        // Compile entire module body natively
        try self.compileNamespaceBody(stmts, false);

        // Export Fully Qualified Name
        try self.defineFullyQualifiedNamespace(name_str);

        if (self.active_namespaces > 1) {
            try self.emitOpWithOperand(.op_set_member, .op_set_member_wide, name_idx);
        } else {
            try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
            try self.emitOp(.op_nil);
        }
    }

    fn compileMethodCall(self: *Compiler, node: *const ast.Node) CompileError!void {
        const mc = self.tree.methodCall(node);
        const func_name = self.tree.getString(mc.method_name);

        // Fast-path: compile `obj.nil?` directly into op_is_nil
        if (std.mem.eql(u8, func_name, "nil?") and mc.receiver != .none) {
            try self.compileNode(mc.receiver);
            try self.emitOp(.op_is_nil);
            return;
        }

        // Intercept Compiler Intrinsics via O(1) lookup
        if (compiler_intrinsics.get(func_name)) |intrinsic| {
            switch (intrinsic) {
                .raise_err => {
                    const args = self.tree.getNamedArgs(mc.args);
                    if (args.len > 0) try self.compileNode(args[0].value) else try self.emitOp(.op_nil);
                    try self.emitOp(.op_throw);
                    self.simulatePush(1); // Dead code equilibrium
                    return;
                },
                .block_given_chk => {
                    try self.emitOp(.op_block_given);
                    return;
                },
                .yield_call => {
                    const args = self.tree.getNamedArgs(mc.args);
                    for (args) |arg| {
                        if (arg.name != .none) return error.UnsupportedScope; // Kwargs to yield not yet supported
                        try self.compileNode(arg.value);
                    }
                    if (args.len > limits.MAX_ARGS) return error.TooManyConstants;
                    try self.emitOp(.op_yield);
                    try self.emitByte(@intCast(args.len));
                    self.simulatePop(args.len); // Yield consumes the args
                    self.simulatePush(1); // Yield returns the block's result
                    return;
                },
                .defined_chk => {
                    const args = self.tree.getNamedArgs(mc.args);
                    if (args.len > 0) {
                        const target_node = self.tree.getNode(args[0].value).?;
                        if (target_node.tag == .identifier) {
                            const name_id = @as(ast.StringId, @enumFromInt(target_node.data));
                            if (self.resolveLocal(name_id) != null or (try self.resolveUpvalue(name_id)) != null) {
                                try self.emitOp(.op_true); // Locals are statically known
                            } else {
                                const name_str = self.tree.getString(name_id);
                                const name_idx = try self.makeStringConstant(name_str);
                                try self.emitOpWithOperand(.op_defined, .op_defined_wide, name_idx);
                            }
                        } else {
                            try self.emitOp(.op_true); // Complex expressions evaluate to true
                        }
                    } else {
                        try self.emitOp(.op_nil);
                    }
                    return;
                },
                .protected_symbol => {},
            }
        }

        var safe_jump: usize = 0;

        // Push Receiver/Target
        if (mc.receiver == .none) {
            try self.emitVariableLoad(mc.method_name, null);
        } else {
            try self.compileNode(mc.receiver);
            if (mc.is_safe) safe_jump = try self.emitJump(.op_jump_if_nil);
        }

        // Delegate Argument Packing
        var actual_arg_count = try self.compileCallArguments(self.tree.getNamedArgs(mc.args));

        // Push the Block as a Closure Argument
        if (mc.block != .none) {
            const block_node = self.tree.getNode(mc.block).?;
            const block_payload = self.tree.block(block_node);
            const lowered_params = try self.lowerBlockParams(block_payload.params);
            defer self.allocator.free(lowered_params);

            try self.compileClosureBlock(lowered_params, mc.block, null, false);
            actual_arg_count += 1;
        }

        if (actual_arg_count > limits.MAX_ARGS) return error.TooManyConstants;

        // 4. Execute Invocation
        if (mc.receiver == .none) {
            try self.emitOp(.op_call);
            try self.emitByte(@intCast(actual_arg_count));
        } else {
            const name_idx = try self.makeStringConstant(func_name);
            try self.emitOpWithOperand(.op_invoke, .op_invoke_wide, name_idx);
            try self.emitByte(@intCast(actual_arg_count));

            try self.emitInlineCacheIndex();

            if (mc.is_safe) self.patchJump(safe_jump);
        }

        self.simulatePop(actual_arg_count + 1); // Pops args + receiver
        self.simulatePush(1); // Pushes the returned result
    }

    fn compileSuperCall(self: *Compiler, node: *const ast.Node) CompileError!void {
        const sc = self.tree.superCall(node);
        try self.emitOp(.op_get_local);
        try self.emitByte(0); // push `self`

        var actual_arg_count: usize = 0;

        if (sc.implicit_args) {
            const func = self.function orelse return error.UnknownNode;
            const arity = func.arity;

            // Push positional arguments AND the kwarg map (located inside the standard arity length)
            for (0..arity) |i| {
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, @intCast(i + 1));
            }
            actual_arg_count = arity;

            if (sc.block == .none) {
                // Forward the parent's block!
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, @intCast(arity + 1));
                actual_arg_count += 1;
            } else {
                // Compile explicitly passed block overriding the implicit one
                const block_node = self.tree.getNode(sc.block).?;
                const block_payload = self.tree.block(block_node);
                const lowered_params = try self.lowerBlockParams(block_payload.params);
                defer self.allocator.free(lowered_params);
                try self.compileClosureBlock(lowered_params, sc.block, null, false);
                actual_arg_count += 1;
            }
        } else {
            const args = self.tree.getNamedArgs(sc.args);

            // Extract Block explicitly passed via reference (`&b`)
            var block_arg: ?ast.NodeIndex = null;
            for (args) |arg| {
                if (arg.modifier != null and arg.modifier.? == .block) {
                    block_arg = arg.value;
                }
            }

            // Delegate Argument Packing
            actual_arg_count = try self.compileCallArguments(args);

            // Block Argument (Always Pushed LAST)
            if (block_arg) |b_node| {
                try self.compileNode(b_node);
                actual_arg_count += 1;
            } else if (sc.block != .none) {
                const block_node = self.tree.getNode(sc.block).?;
                const block_payload = self.tree.block(block_node);
                const lowered_params = try self.lowerBlockParams(block_payload.params);
                defer self.allocator.free(lowered_params);
                try self.compileClosureBlock(lowered_params, sc.block, null, false);
                actual_arg_count += 1;
            }
        }

        if (actual_arg_count > limits.MAX_ARGS) return error.TooManyConstants;

        try self.emitOp(.op_super_invoke);
        try self.emitByte(@intCast(actual_arg_count));

        // Pop the arguments + the implicit `self` receiver
        self.simulatePop(actual_arg_count + 1);
        self.simulatePush(1);
    }

    fn lowerBlockParams(self: *Compiler, param_span: ast.Span) CompileError![]const ast.Param {
        const param_nodes = self.tree.getNodes(param_span);
        var lowered = try self.allocator.alloc(ast.Param, param_nodes.len);

        for (param_nodes, 0..) |node_idx, i| {
            const node = self.tree.getNode(node_idx) orelse return error.UnknownNode;

            switch (node.tag) {
                .identifier => {
                    lowered[i] = .{
                        .name = self.tree.stringId(node),
                        .default_value = .none,
                        .modifier = null,
                        .is_keyword = false,
                    };
                },
                .assignment => {
                    const assign = self.tree.assignment(node);
                    lowered[i] = .{
                        .name = assign.name,
                        .default_value = assign.value,
                        .modifier = null,
                        .is_keyword = false,
                    };
                },
                .symbol => {
                    lowered[i] = .{
                        .name = self.tree.stringId(node),
                        .default_value = .none,
                        .modifier = null,
                        .is_keyword = true,
                    };
                },
                .hash_literal => {
                    const entries = self.tree.getHashEntries(self.tree.nodeSpan(node));
                    const key_node = self.tree.getNode(entries[0].key).?;
                    lowered[i] = .{
                        .name = self.tree.stringId(key_node),
                        .default_value = entries[0].value,
                        .modifier = null,
                        .is_keyword = true,
                    };
                },
                .splat_expr => {
                    const inner_node = self.tree.getNode(@as(ast.NodeIndex, @enumFromInt(node.data))).?;
                    lowered[i] = .{
                        .name = self.tree.stringId(inner_node),
                        .default_value = .none,
                        .modifier = .splat,
                        .is_keyword = false,
                    };
                },
                .double_splat_expr => {
                    const inner_node = self.tree.getNode(@as(ast.NodeIndex, @enumFromInt(node.data))).?;
                    lowered[i] = .{
                        .name = self.tree.stringId(inner_node),
                        .default_value = .none,
                        .modifier = .double_splat,
                        .is_keyword = false,
                    };
                },
                .array_literal => {
                    // This represents destructuring like |(x, y)|
                    lowered[i] = .{
                        .name = .none, // Anonymous parameter
                        .default_value = .none,
                        .modifier = null,
                        .is_keyword = false,
                    };
                },
                else => return error.UnknownNode,
            }
        }
        return lowered;
    }

    fn writeJumpOffset(self: *Compiler, target_index: usize, offset: usize) void {
        // Prevent silent out-of-bounds overwrites in the bytecode array
        std.debug.assert(target_index + 3 < self.current_chunk.code.items.len);

        self.current_chunk.code.items[target_index] = @intCast((offset >> 24) & 0xFF);
        self.current_chunk.code.items[target_index + 1] = @intCast((offset >> 16) & 0xFF);
        self.current_chunk.code.items[target_index + 2] = @intCast((offset >> 8) & 0xFF);
        self.current_chunk.code.items[target_index + 3] = @intCast(offset & 0xFF);
    }

    fn isScriptGlobal(self: *Compiler, name_id: ast.StringId) bool {
        var root: *Compiler = self;
        while (root.enclosing) |parent| {
            root = parent;
        }

        // Use pure string lookup to bypass integer ID caching discrepancies
        const name_str = self.tree.getString(name_id);
        return root.script_globals.contains(name_str);
    }

    /// Returns the net stack effect of an OpCode.
    /// Returns `null` if the effect is dynamic (e.g., depends on call arity or operand length).
    fn getStaticStackEffect(op: chunk.OpCode) ?i32 {
        return switch (op) {
            // --- Pushes 1 (Net: +1) ---
            // These operations introduce a new value onto the top of the stack.
            .op_nil, .op_true, .op_false, .op_get_local, .op_get_local_wide, .op_get_global, .op_get_global_wide, .op_constant, .op_constant_wide, .op_closure, .op_closure_wide, .op_get_upvalue, .op_dup, .op_import, .op_import_wide, .op_block_given, .op_defined, .op_defined_wide, .op_module, .op_module_wide, .op_extract_kwarg, .op_extract_kwarg_wide, .op_class, .op_class_wide => 1,

            // --- Pops 1 (Net: -1) ---
            // These operations consume exactly one value from the stack without pushing anything back.
            .op_pop, .op_return, .op_close_upvalue, .op_throw, .op_array_push, .op_array_spread, .op_map_spread, .op_switch, .op_switch_wide, .op_inherit, .op_class_method, .op_class_method_wide, .op_mixin, .op_method, .op_method_wide, .op_define_global, .op_define_global_wide, .op_bitwise_and, .op_break_block => -1,

            // --- Pops 2 (Net: -2) ---
            // Consumes two values (e.g. key and value) without replacing them.
            .op_map_insert => -2,

            // --- Pops 2, Pushes 1 (Net: -1) ---
            // Binary operations that consume a left and right operand, and yield a single result.
            .op_add, .op_subtract, .op_multiply, .op_divide, .op_modulo, .op_exponent, .op_less, .op_greater, .op_equal, .op_case_equal, .op_is_instance, .op_get_index, .op_set_property, .op_set_property_wide, .op_set_class_var, .op_set_class_var_wide => -1,

            // --- Pops 3, Pushes 1 (Net: -2) ---
            // Consumes a target, an index, and a value, yielding the assigned value back.
            .op_set_index => -2,

            // --- Pops 1, Pushes 1 (Net: 0) ---
            // Unary modifiers that consume a value and replace it with a mutated version.
            // op_set_member pops a class, peeks at the namespace, attaches it, and pushes the class back.
            .op_negate, .op_not, .op_is_nil, .op_set_member, .op_set_member_wide => 0,

            // --- Pushes 2 (Net: +2) ---
            // Duplicates the top two values on the stack.
            .op_dup_two => 2,

            // --- Doesn't pop or push (Net: 0) ---
            // Pure side-effects or control flow jumps that leave the stack exactly as they found it.
            .op_set_local, .op_set_local_wide, .op_jump_if_not_nil, .op_jump_if_false, .op_jump_if_nil, .op_jump, .op_loop, .op_setup_rescue, .op_pop_rescue, .op_get_class_var, .op_get_class_var_wide, .op_set_upvalue => 0,

            // --- Dynamic Ops (Requires manual tracking) ---
            // These operations consume a variable number of arguments based on bytecode operands.
            .op_call, .op_invoke, .op_invoke_wide, .op_super_invoke, .op_build_array, .op_build_array_wide, .op_build_map, .op_build_map_wide, .op_unpack, .op_unpack_splat, .op_pack_splat, .op_interpolate, .op_yield, .op_build_range => null,

            else => 0, // Fallback for any implicitly balanced ops
        };
    }

    pub fn seedLocals(self: *Compiler, names: []const []const u8, offset: u16) void {
        self.seeded_locals = names;
        self.seeded_slot_offset = offset;
        if (names.len > 0) {
            self.max_local_slot = @intCast(names.len + offset - 1);
        }
    }

    pub fn getNextLocalSlot(self: *Compiler) u16 {
        return @as(u16, @intCast(self.locals.items.len + self.seeded_locals.len + self.seeded_slot_offset));
    }
};
