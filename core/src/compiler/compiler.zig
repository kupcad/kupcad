const std = @import("std");
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const limits = @import("../vm/limits.zig");
const resolver = @import("../core/resolver.zig");
const VM = @import("../vm/vm.zig").VM;

pub const CompileError = error{
    OutOfMemory,
    UnknownNode,
    TooManyConstants,
    TooManyLocals,
    UnsupportedScope,
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
    exit_jumps: std.ArrayListUnmanaged(usize) = .empty,
};

const Intrinsic = enum {
    raise_err,
    block_given_chk,
    yield_call,
};

const compiler_intrinsics = std.StaticStringMap(Intrinsic).initComptime(.{
    .{ "raise", .raise_err },
    .{ "block_given?", .block_given_chk },
    .{ "yield", .yield_call },
});

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,
    script_globals: std.AutoHashMapUnmanaged(ast.StringId, void) = .empty,
    symbols: []const resolver.ResolvedSymbol,
    token_starts: []const u32, // Map AST nodes back to Lexer byte offsets
    current_source_offset: u32, // Implictly passed to Chunk
    current_chunk: *chunk.Chunk,
    vm: *VM,

    // Lexical Scope Tracking
    enclosing: ?*Compiler = null,
    function: ?*value.ObjFunction = null,

    upvalues: std.ArrayListUnmanaged(Upvalue) = .empty,
    locals: std.ArrayListUnmanaged(Local) = .empty,
    loops: std.ArrayListUnmanaged(LoopState) = .empty,

    current_stack_depth: usize = 0,
    max_stack_depth: usize = 0,
    max_local_slot: usize = 0,

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
    }

    // --- Lexical Scope Resolvers ---

    fn addLocal(self: *Compiler, name_id: ast.StringId, slot: u16) CompileError!void {
        for (self.locals.items) |loc| {
            if (loc.name_id == name_id) return;
        }
        if (self.locals.items.len >= limits.MAX_LOCALS) return error.TooManyLocals;
        try self.locals.append(self.allocator, .{ .name_id = name_id, .slot = slot });
        if (slot > self.max_local_slot) self.max_local_slot = slot;
    }

    fn resolveLocal(self: *Compiler, name_id: ast.StringId) ?u16 {
        var i: usize = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (self.locals.items[i].name_id == name_id) return self.locals.items[i].slot;
        }
        return null;
    }

    fn resolveUpvalue(self: *Compiler, name_id: ast.StringId) CompileError!?u8 {
        if (self.enclosing == null) return null;
        const enclosing = self.enclosing.?;

        // 1. Look for it as a direct local variable in the parent
        if (enclosing.resolveLocal(name_id)) |local_idx| {
            return try self.addUpvalue(local_idx, true);
        }

        // 2. Recursively look up the scope chain for an already captured upvalue
        if (try enclosing.resolveUpvalue(name_id)) |upv_idx| {
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
    }

    fn compileNode(self: *Compiler, node_idx: ast.NodeIndex) CompileError!void {
        if (node_idx == .none) return;
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
                const str_content = self.tree.getString(@as(ast.StringId, @enumFromInt(node.data)));
                const str_idx = try self.makeStringConstant(str_content);
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, str_idx);
            },
            .symbol => {
                const sym_str = self.tree.getString(@as(ast.StringId, @enumFromInt(node.data)));
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
            .identifier => {
                const sym = self.symbols[@intFromEnum(node_idx)];
                const name_id = @as(ast.StringId, @enumFromInt(node.data));
                const name_str = self.tree.getString(name_id);

                const is_local = (self.resolveLocal(name_id) != null) or
                    (sym.kind == .local);
                const is_upvalue = (try self.resolveUpvalue(name_id)) != null;
                const is_script_global = self.isScriptGlobal(name_id);

                const is_special_or_const = name_str.len == 0 or
                    std.mem.startsWith(u8, name_str, "@") or
                    std.mem.startsWith(u8, name_str, "$") or
                    std.ascii.isUpper(name_str[0]);

                const is_variable = is_local or is_upvalue or is_script_global or is_special_or_const;

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
            .break_stmt => {
                const break_idx = self.tree.nodeIndex(node);
                if (break_idx != .none) {
                    try self.compileNode(break_idx);
                } else {
                    try self.emitOp(.op_nil);
                }

                if (self.loops.items.len == 0) return error.UnknownNode;

                const jump = try self.emitJump(.op_jump);
                var cur_loop = &self.loops.items[self.loops.items.len - 1];
                try cur_loop.exit_jumps.append(self.allocator, jump);
                self.simulatePush(1); // Equilibrium for dead code
            },
            .next_stmt => {
                const next_idx = self.tree.nodeIndex(node);
                if (next_idx != .none) {
                    try self.compileNode(next_idx);
                } else {
                    try self.emitOp(.op_nil);
                }
                try self.emitOp(.op_pop);

                if (self.loops.items.len == 0) return error.UnknownNode;

                const cur_loop = &self.loops.items[self.loops.items.len - 1];
                try self.emitLoop(cur_loop.start);
                self.simulatePush(1); // Equilibrium for dead code
            },
            .assignment => {
                const assign_payload = self.tree.assignment(node);
                const sym = self.symbols[@intFromEnum(node_idx)];
                const name_id = assign_payload.name;

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
                self.simulatePush(1); // Error value
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

                try self.compileClosureBlock(params, body_node);

                if (node.tag == .def_stmt) {
                    const sym = self.symbols[@intFromEnum(node_idx)];
                    if (self.enclosing == null or sym.kind == .global) {
                        const name_idx = try self.makeStringConstant(self.tree.getString(def_name_id));
                        try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
                        try self.emitOp(.op_nil);
                    } else {
                        const slot = @as(u16, @intCast(self.locals.items.len));
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
                    try self.compileNode(ia.value);
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
                try self.emitOp(.op_pop);

                try self.compileNode(if_payload.then_branch);
                const else_jump = try self.emitJump(.op_jump);

                self.patchJump(then_jump);
                try self.emitOp(.op_pop);

                if (if_payload.else_branch != .none) {
                    try self.compileNode(if_payload.else_branch);
                } else {
                    try self.emitOp(.op_nil);
                }
                self.patchJump(else_jump);
            },
            .self_expr => {
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, 0);
            },
            .while_stmt => {
                const while_payload = self.tree.whileStmt(node);
                const loop_start = self.current_chunk.code.items.len;

                // Push loop state
                try self.loops.append(self.allocator, .{ .start = loop_start });

                try self.compileNode(while_payload.condition);
                if (while_payload.is_until) try self.emitOp(.op_not);

                const exit_jump = try self.emitJump(.op_jump_if_false);
                try self.emitOp(.op_pop); // Clean up condition

                try self.compileNode(while_payload.body);
                try self.emitOp(.op_pop); // Pop the body's yielded result

                try self.emitLoop(loop_start);

                self.patchJump(exit_jump);
                self.simulatePush(1); // The condition that was bypassed
                try self.emitOp(.op_pop);
                try self.emitOp(.op_nil); // Natural exit yields nil

                // Pop loop state and safely patch all 'break' jump addresses
                var cur_loop = self.loops.pop().?;
                defer cur_loop.exit_jumps.deinit(self.allocator);
                for (cur_loop.exit_jumps.items) |jmp| {
                    self.patchJump(jmp);
                }
            },
            .ternary_op => {
                const ternary = self.tree.ternaryExpr(node);
                try self.compileNode(ternary.condition);

                const then_jump = try self.emitJump(.op_jump_if_false);
                try self.emitOp(.op_pop); // pop condition if true

                try self.compileNode(ternary.then_branch);
                const else_jump = try self.emitJump(.op_jump);

                self.patchJump(then_jump);
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
                    try self.emitOpWithOperand(.op_invoke, .op_invoke_wide, name_idx);
                    try self.emitByte(0); // 0 args -> Stack: [target, old_val]

                    try self.compileNode(pa.value); // Stack: [target, old_val, rhs_val]

                    switch (op) {
                        .add => try self.emitOp(.op_add),
                        .subtract => try self.emitOp(.op_subtract),
                        .multiply => try self.emitOp(.op_multiply),
                        .divide => try self.emitOp(.op_divide),
                        else => return error.UnknownNode,
                    }
                    // Stack: [target, new_val]
                } else {
                    try self.compileNode(pa.value); // Stack: [target, new_val]
                }

                // op_set_property consumes both target and new_val, then pushes new_val back
                try self.emitOpWithOperand(.op_set_property, .op_set_property_wide, name_idx);
            },
            .defined_expr => {
                const target_node = self.tree.getNode(node_idx).?;
                if (target_node.data != @intFromEnum(ast.StringId.none)) {
                    const name_id = @as(ast.StringId, @enumFromInt(target_node.data));
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

                if (stmts.len == 0) {
                    try self.emitOp(.op_nil);
                } else {
                    for (stmts, 0..) |stmt_idx, i| {
                        try self.compileNode(stmt_idx);
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

    fn emitByte(self: *Compiler, byte: u8) CompileError!void {
        self.current_chunk.write(self.allocator, byte, self.current_source_offset) catch return error.OutOfMemory;
    }

    fn emitOp(self: *Compiler, op: chunk.OpCode) CompileError!void {
        try self.emitByte(@intFromEnum(op));
        switch (op) {
            .op_nil, .op_true, .op_false, .op_get_local, .op_get_global, .op_get_global_wide, .op_constant, .op_constant_wide, .op_closure, .op_closure_wide, .op_get_upvalue, .op_dup, .op_import, .op_import_wide, .op_block_given, .op_get_class_var, .op_get_class_var_wide, .op_defined, .op_defined_wide, .op_extract_kwarg, .op_extract_kwarg_wide, .op_module, .op_module_wide => self.simulatePush(1),
            .op_pop, .op_return, .op_close_upvalue, .op_pop_rescue, .op_throw, .op_array_push, .op_array_spread, .op_map_spread, .op_switch, .op_inherit, .op_super_invoke, .op_class_method, .op_class_method_wide, .op_unpack, .op_unpack_splat, .op_mixin => self.simulatePop(1),
            .op_map_insert => self.simulatePop(2),
            .op_is_instance, .op_case_equal, .op_add, .op_subtract, .op_multiply, .op_divide, .op_equal, .op_less, .op_greater, .op_modulo, .op_exponent => {
                self.simulatePop(2);
                self.simulatePush(1);
            },
            .op_get_index => {
                self.simulatePop(2);
                self.simulatePush(1);
            },
            .op_set_index => {
                self.simulatePop(3);
                self.simulatePush(1); // Assignment yields the assigned value
            },
            .op_negate, .op_not => {
                self.simulatePop(1);
                self.simulatePush(1);
            },
            .op_class, .op_class_wide => self.simulatePush(1),
            .op_dup_two => self.simulatePush(2),
            .op_method, .op_method_wide, .op_define_global, .op_define_global_wide => self.simulatePop(1),
            .op_set_property, .op_set_property_wide => {
                self.simulatePop(2);
                self.simulatePush(1); // Assignment yields value
            },
            .op_set_class_var, .op_set_class_var_wide, .op_jump_if_not_nil => {},
            else => {},
        }
    }

    fn makeConstant(self: *Compiler, val: value.Value) CompileError!usize {
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
        // Write 3 bytes for a 24-bit jump offset
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        return self.current_chunk.code.items.len - 3;
    }

    fn patchJump(self: *Compiler, offset: usize) void {
        const jump = self.current_chunk.code.items.len - offset - 3;
        std.debug.assert(jump <= 0xFFFFFF); // Assert it fits in 24 bits
        self.current_chunk.code.items[offset] = @intCast((jump >> 16) & 0xff);
        self.current_chunk.code.items[offset + 1] = @intCast((jump >> 8) & 0xff);
        self.current_chunk.code.items[offset + 2] = @intCast(jump & 0xff);
    }

    fn emitLoop(self: *Compiler, loop_start: usize) CompileError!void {
        try self.emitOp(.op_loop);
        const jump = self.current_chunk.code.items.len - loop_start + 3;
        std.debug.assert(jump <= 0xFFFFFF);
        try self.emitByte(@intCast((jump >> 16) & 0xff));
        try self.emitByte(@intCast((jump >> 8) & 0xff));
        try self.emitByte(@intCast(jump & 0xff));
    }

    fn makeStringConstant(self: *Compiler, text: []const u8) CompileError!usize {
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

    fn emitOpWithOperand(self: *Compiler, short_op: chunk.OpCode, wide_op: chunk.OpCode, operand: usize) CompileError!void {
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

    fn compileClosureBlock(self: *Compiler, params: []const ast.Param, body_node: ast.NodeIndex) CompileError!void {
        const func = try self.vm.gc.allocateFunction(self.vm);

        var positional_count: usize = 0;
        var splat_idx: ?usize = null;
        var has_kwargs = false;

        for (params, 0..) |p, i| {
            if (p.modifier != null) {
                if (p.modifier.? == .splat or p.modifier.? == .double_splat) {
                    func.has_splat = true;
                    if (p.modifier.? == .splat) splat_idx = i;
                }
            }
            if (p.is_keyword or (p.modifier != null and p.modifier.? == .double_splat)) {
                has_kwargs = true;
            } else if (p.modifier == null or p.modifier.? == .splat) {
                positional_count += 1;
            }
        }

        // Kwargs are passed as a single Dictionary map taking exactly 1 positional slot
        if (has_kwargs) positional_count += 1;
        func.arity = @intCast(positional_count);

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
            .symbols = self.symbols,
            .token_starts = self.token_starts,
            .current_chunk = child_chunk,
            .vm = self.vm,
            .enclosing = self,
            .function = func,
            .upvalues = .empty,
            .locals = .empty,
            .loops = .empty,
            .current_stack_depth = 0,
            .max_stack_depth = 0,
            .current_source_offset = self.current_source_offset,
        };
        defer child_compiler.deinit();

        // Reserve slot 0 for the closure itself
        try child_compiler.addLocal(.none, 0);

        var current_slot: u8 = 1;
        const map_slot = if (has_kwargs) @as(u8, @intCast(positional_count)) else 0;

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
            for (0..num_virtuals) |_| try child_compiler.emitOp(.op_nil);

            for (params) |param| {
                if (param.is_keyword) {
                    const name_str = self.tree.getString(param.name);
                    const kw_name_idx = try child_compiler.makeStringConstant(name_str);

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
                        try child_compiler.emitOp(.op_dup);
                        const skip_default_jump = try child_compiler.emitJump(.op_jump_if_not_nil);
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

        if (splat_idx) |s_idx| {
            try child_compiler.emitOp(.op_pack_splat);
            try child_compiler.emitByte(@intCast(s_idx));
            try child_compiler.emitByte(@intCast(params.len - 1 - s_idx));
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
            const name_id = target.name;
            if (self.resolveLocal(name_id)) |local_slot| {
                try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, local_slot);
                try self.emitOp(.op_pop);
            } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                try self.emitOp(.op_set_upvalue);
                try self.emitByte(upvalue_slot);
                try self.emitOp(.op_pop);
            } else {
                const name_idx = try self.makeStringConstant(self.tree.getString(name_id));
                if (self.enclosing == null or self.isScriptGlobal(name_id)) {
                    // Track it if we are assigning it for the first time at the top level
                    if (self.enclosing == null) {
                        try self.script_globals.put(self.allocator, name_id, {});
                    }
                    try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
                } else {
                    try self.addLocal(name_id, @intCast(self.locals.items.len));
                    try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, self.locals.items.len - 1);
                    try self.emitOp(.op_pop);
                }
            }
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

        if (!has_splat) {
            for (elements) |elem| try self.compileNode(elem);

            // Allow up to 65_535 elements in an array
            if (elements.len > limits.MAX_CONSTANTS) return error.TooManyConstants;

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
            // Dynamic Build Mode
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
                    const str_content = self.tree.getString(@as(ast.StringId, @enumFromInt(key_node.data)));
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
                        const str_content = self.tree.getString(@as(ast.StringId, @enumFromInt(key_node.data)));
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

        // --- Heuristic: Can we use a Fast Jump Table? ---
        var can_use_jump_table = true;
        var total_conditions: u16 = 0;
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

        if (can_use_jump_table and total_conditions > 0) {
            // ====== FAST PATH: OP_SWITCH ======
            try self.compileNode(cs.condition);
            try self.emitOpWithOperand(.op_switch, .op_switch_wide, total_conditions);

            // Pre-allocate the jump table in bytecode so we can backpatch it later
            const table_start_offset = self.current_chunk.code.items.len;
            for (0..total_conditions) |_| {
                try self.emitByte(0); // const_high
                try self.emitByte(0); // const_low
                try self.emitByte(0xFF); // jump high
                try self.emitByte(0xFF); // jump mid
                try self.emitByte(0xFF); // jump low
            }
            const default_jump_offset = self.current_chunk.code.items.len;
            try self.emitByte(0xFF); // default high
            try self.emitByte(0xFF); // default mid
            try self.emitByte(0xFF); // default low

            var condition_idx: usize = 0;
            var end_jumps: std.ArrayListUnmanaged(usize) = .empty;
            defer end_jumps.deinit(self.allocator);

            for (branches) |branch| {
                const body_jump_target = self.current_chunk.code.items.len;
                const conds = self.tree.getNodes(branch.conditions);

                // Backpatch the table entries for this branch
                for (conds) |cond_node_idx| {
                    const c_node = self.tree.getNode(cond_node_idx).?;
                    const table_idx = table_start_offset + (condition_idx * 5); // Step by 5!

                    // Extract constant index directly
                    var raw_idx: usize = 0;
                    if (c_node.tag == .number) {
                        raw_idx = try self.makeConstant(value.Value.initNumber(self.tree.number(c_node)));
                    } else if (c_node.tag == .string) {
                        const str_content = self.tree.getString(@as(ast.StringId, @enumFromInt(c_node.data)));
                        raw_idx = try self.makeStringConstant(str_content);
                    }

                    // No more artificial limits! Write the 16-bit constant index:
                    self.current_chunk.code.items[table_idx] = @intCast((raw_idx >> 8) & 0xFF);
                    self.current_chunk.code.items[table_idx + 1] = @intCast(raw_idx & 0xFF);

                    // Calculate offset from the END of the entire switch instruction block
                    const offset = body_jump_target - (default_jump_offset + 3);
                    self.current_chunk.code.items[table_idx + 2] = @intCast((offset >> 16) & 0xFF);
                    self.current_chunk.code.items[table_idx + 3] = @intCast((offset >> 8) & 0xFF);
                    self.current_chunk.code.items[table_idx + 4] = @intCast(offset & 0xFF);
                    condition_idx += 1;
                }

                // Compile the actual body
                try self.compileNode(branch.body);
                try end_jumps.append(self.allocator, try self.emitJump(.op_jump));
            }

            // Backpatch Default Branch
            const default_target = self.current_chunk.code.items.len;
            const d_offset = default_target - (default_jump_offset + 3);
            self.current_chunk.code.items[default_jump_offset] = @intCast((d_offset >> 16) & 0xFF);
            self.current_chunk.code.items[default_jump_offset + 1] = @intCast((d_offset >> 8) & 0xFF);
            self.current_chunk.code.items[default_jump_offset + 2] = @intCast(d_offset & 0xFF);

            if (cs.else_branch != .none) {
                try self.compileNode(cs.else_branch);
            } else {
                try self.emitOp(.op_nil);
            }

            // Cap off all successful branch executions
            for (end_jumps.items) |jmp| {
                self.patchJump(jmp);
            }
            self.current_stack_depth = saved_depth + 1;
        } else {
            // ====== LINEAR FALLBACK PATH ======
            try self.compileNode(cs.condition);

            var end_jumps: std.ArrayListUnmanaged(usize) = .empty;
            defer end_jumps.deinit(self.allocator);

            for (branches) |branch| {
                const conds = self.tree.getNodes(branch.conditions);
                for (conds) |cond_idx| {
                    try self.emitOp(.op_dup);
                    try self.compileNode(cond_idx);
                    try self.emitOp(.op_case_equal);
                    const skip_jump = try self.emitJump(.op_jump_if_false);
                    try self.emitOp(.op_pop);
                    try self.emitOp(.op_pop);

                    try self.compileNode(branch.body);
                    try end_jumps.append(self.allocator, try self.emitJump(.op_jump));
                    self.current_stack_depth = saved_depth + 2;
                    self.patchJump(skip_jump);
                    try self.emitOp(.op_pop);
                }
            }

            try self.emitOp(.op_pop);
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
                    const slot = @as(u16, @intCast(self.locals.items.len));
                    try self.addLocal(rescue.variable, slot);
                    try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
                }
                try self.emitOp(.op_pop); // Pop the error value off stack
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

    fn compileMethodCall(self: *Compiler, node: *const ast.Node) CompileError!void {
        const mc = self.tree.methodCall(node);
        const func_name = self.tree.getString(mc.method_name);

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

        // Push Arguments (Positional first, then Keyword Args packed as a Map)
        const args = self.tree.getNamedArgs(mc.args);
        var pos_count: usize = 0;
        var kw_count: usize = 0;

        for (args) |arg| {
            if (arg.name == .none) {
                try self.compileNode(arg.value);
                pos_count += 1;
            }
        }

        for (args) |arg| {
            if (arg.name != .none) {
                const name_idx = try self.makeStringConstant(self.tree.getString(arg.name));
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, name_idx);
                try self.compileNode(arg.value);
                kw_count += 1;
            }
        }

        if (kw_count > 0) {
            if (kw_count <= limits.MAX_SHORT_CONSTANTS) {
                try self.emitOp(.op_build_map);
                try self.emitByte(@intCast(kw_count));
            } else {
                try self.emitOp(.op_build_map_wide);
                try self.emitByte(@intCast((kw_count >> 8) & 0xff));
                try self.emitByte(@intCast(kw_count & 0xff));
            }
            pos_count += 1; // The Hash Map becomes the final trailing positional argument!
        }

        var actual_arg_count = pos_count;

        // Push the Block as a Closure Argument!
        if (mc.block != .none) {
            const block_node = self.tree.getNode(mc.block).?;
            const block_payload = self.tree.block(block_node);
            const block_params = self.tree.getNodes(block_payload.params);

            const func = try self.vm.gc.allocateFunction(self.vm);
            func.arity = @intCast(block_params.len);

            self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
            self.vm.push(value.Value.initObj(&func.obj));
            errdefer _ = self.vm.pop();

            const child_chunk = try self.allocator.create(chunk.Chunk);
            child_chunk.* = chunk.Chunk.init();
            func.chunk = child_chunk;

            var child_compiler = Compiler{
                .allocator = self.allocator,
                .tree = self.tree,
                .symbols = self.symbols,
                .token_starts = self.token_starts,
                .current_chunk = child_chunk,
                .vm = self.vm,
                .enclosing = self,
                .function = func,
                .upvalues = .empty,
                .locals = .empty,
                .loops = .empty,
                .current_stack_depth = 0,
                .max_stack_depth = 0,
                .current_source_offset = self.current_source_offset,
            };
            defer child_compiler.deinit();

            // Reserve slot 0 for the closure itself
            try child_compiler.addLocal(.none, 0);

            for (block_params, 0..) |p_idx, i| {
                const p_node = self.tree.getNode(p_idx).?;
                const name_id = @as(ast.StringId, @enumFromInt(p_node.data));
                try child_compiler.addLocal(name_id, @intCast(i + 1));
            }

            // Compiling a block automatically leaves the last statement on the stack as an implicit return!
            try child_compiler.compile(mc.block);

            _ = self.vm.pop();

            const func_val = value.Value.initObj(&func.obj);
            const func_idx = try self.makeConstant(func_val);

            try self.emitOpWithOperand(.op_closure, .op_closure_wide, func_idx);

            for (child_compiler.upvalues.items) |upv| {
                try self.emitByte(if (upv.is_local) 1 else 0);
                try self.emitByte(@intCast((upv.index >> 8) & 0xff));
                try self.emitByte(@intCast(upv.index & 0xff));
            }

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
            if (mc.is_safe) self.patchJump(safe_jump);
        }

        self.simulatePop(actual_arg_count + 1);
        self.simulatePush(1);
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

    fn emitVariableLoad(self: *Compiler, name_id: ast.StringId, sym: ?resolver.ResolvedSymbol) CompileError!void {
        _ = sym;
        const name_str = self.tree.getString(name_id);
        if (std.mem.startsWith(u8, name_str, "@@")) {
            const name_idx = try self.makeStringConstant(name_str);
            try self.emitOpWithOperand(.op_get_class_var, .op_get_class_var_wide, name_idx);
        } else if (self.resolveLocal(name_id)) |local_slot| {
            try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, local_slot);
        } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
            try self.emitOp(.op_get_upvalue);
            try self.emitByte(upvalue_slot);
        } else {
            const name_idx = try self.makeStringConstant(name_str);
            try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, name_idx);
        }
    }

    fn emitVariableStore(self: *Compiler, name_id: ast.StringId, sym: resolver.ResolvedSymbol) CompileError!void {
        const name_str = self.tree.getString(name_id);
        if (std.mem.startsWith(u8, name_str, "@@")) {
            const name_idx = try self.makeStringConstant(name_str);
            try self.emitOpWithOperand(.op_set_class_var, .op_set_class_var_wide, name_idx);
        } else if (self.resolveLocal(name_id)) |local_slot| {
            try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, local_slot);
        } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
            try self.emitOp(.op_set_upvalue);
            try self.emitByte(upvalue_slot);
        } else if (self.enclosing == null or sym.kind == .global or self.isScriptGlobal(name_id)) {
            // Track it if we are assigning it for the first time at the top level
            if (self.enclosing == null) {
                try self.script_globals.put(self.allocator, name_id, {});
            }
            const name_idx = try self.makeStringConstant(name_str);
            try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
            try self.emitOp(.op_nil); // Equilibrium: Assignment blocks yield nil
        } else {
            // Allocate sequential local slots starting at 1 (slot 0 is reserved for closure)
            const slot = @as(u16, @intCast(self.locals.items.len));
            try self.addLocal(name_id, slot);
            try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
        }
    }

    fn compileMultipleAssignment(self: *Compiler, node: *const ast.Node) CompileError!void {
        const ma = self.tree.multipleAssignment(node);
        const lhs = self.tree.getLhsExprs(ma.lhs);
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
            self.simulatePush(lhs.len);
        } else {
            if (lhs.len > limits.MAX_SHORT_CONSTANTS) return error.TooManyConstants;
            try self.emitOp(.op_unpack);
            try self.emitByte(@intCast(lhs.len));
            self.simulatePush(lhs.len);
        }

        var i: usize = lhs.len;
        while (i > 0) {
            i -= 1;
            try self.compileDestructure(lhs[i]);
        }
        try self.emitOp(.op_nil);
    }

    fn compileClassStmt(self: *Compiler, node: *const ast.Node, node_idx: ast.NodeIndex) CompileError!void {
        const cs = self.tree.classStmt(node);
        const name_node = self.tree.getNode(cs.name).?;
        const name_id = @as(ast.StringId, @enumFromInt(name_node.data));
        const name_idx = try self.makeStringConstant(self.tree.getString(name_id));

        try self.emitOpWithOperand(.op_class, .op_class_wide, name_idx);

        if (cs.super_class != .none) {
            try self.compileNode(cs.super_class);
            try self.emitOp(.op_inherit);
        }

        const body_node = self.tree.getNode(cs.body).?;
        const block_payload = self.tree.block(body_node);
        const stmts = self.tree.getNodes(block_payload.stmts);

        for (stmts) |stmt_idx| {
            const stmt_node = self.tree.getNode(stmt_idx).?;
            if (stmt_node.tag == .def_stmt) {
                const ds = self.tree.defStmt(stmt_node);
                const method_name = self.tree.getString(ds.name);
                const is_class_method = ds.is_class_method or std.mem.startsWith(u8, method_name, "self.");

                var final_name = method_name;
                if (std.mem.startsWith(u8, method_name, "self.")) {
                    final_name = method_name[5..];
                }
                const m_name_idx = try self.makeStringConstant(final_name);

                const params = self.tree.getParams(ds.params);
                try self.compileClosureBlock(params, ds.body);

                try self.emitOpWithOperand(if (is_class_method) .op_class_method else .op_method, if (is_class_method) .op_class_method_wide else .op_method_wide, m_name_idx);
            } else if (stmt_node.tag == .method_call) {
                const mc = self.tree.methodCall(stmt_node);
                const func_name = self.tree.getString(mc.method_name);
                if (std.mem.eql(u8, func_name, "include") and mc.receiver == .none) {
                    const args = self.tree.getNamedArgs(mc.args);
                    if (args.len == 1) {
                        try self.compileNode(args[0].value);
                        try self.emitOp(.op_mixin);
                        continue;
                    }
                }
            }
        }

        const sym = self.symbols[@intFromEnum(node_idx)];
        if (sym.kind == .local and self.enclosing != null) {
            const slot = @as(u16, @intCast(self.locals.items.len));
            try self.addLocal(name_id, slot);
            try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
        } else {
            try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
            try self.emitOp(.op_nil);
        }
    }

    fn compileModuleStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        const ms = self.tree.moduleStmt(node);
        const name_str = self.tree.getString(ms.name);
        const name_idx = try self.makeStringConstant(name_str);

        try self.emitOpWithOperand(.op_module, .op_module_wide, name_idx);

        const body_node = self.tree.getNode(ms.body).?;
        const block_payload = self.tree.block(body_node);
        const stmts = self.tree.getNodes(block_payload.stmts);

        for (stmts) |stmt_idx| {
            const stmt_node = self.tree.getNode(stmt_idx).?;
            if (stmt_node.tag == .def_stmt) {
                const ds = self.tree.defStmt(stmt_node);
                const method_name = self.tree.getString(ds.name);
                const m_name_idx = try self.makeStringConstant(method_name);
                const params = self.tree.getParams(ds.params);
                try self.compileClosureBlock(params, ds.body);
                try self.emitOpWithOperand(.op_method, .op_method_wide, m_name_idx);
            }
        }

        try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
        try self.emitOp(.op_nil);
    }

    fn compileSuperCall(self: *Compiler, node: *const ast.Node) CompileError!void {
        const sc = self.tree.superCall(node);
        try self.emitOp(.op_get_local);
        try self.emitByte(0); // push `self`

        const args = self.tree.getNamedArgs(sc.args);
        var pos_count: usize = 0;
        var kw_count: usize = 0;

        for (args) |arg| {
            if (arg.name == .none) {
                try self.compileNode(arg.value);
                pos_count += 1;
            }
        }
        for (args) |arg| {
            if (arg.name != .none) {
                const name_idx = try self.makeStringConstant(self.tree.getString(arg.name));
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, name_idx);
                try self.compileNode(arg.value);
                kw_count += 1;
            }
        }

        if (kw_count > 0) {
            try self.emitOp(.op_build_map);
            try self.emitByte(@intCast(kw_count));
            pos_count += 1;
        }

        try self.emitOp(.op_super_invoke);
        try self.emitByte(@intCast(pos_count));

        self.simulatePop(pos_count + 1);
        self.simulatePush(1);
    }

    fn isScriptGlobal(self: *Compiler, name_id: ast.StringId) bool {
        var root: *Compiler = self;
        while (root.enclosing) |parent| {
            root = parent;
        }

        // Pure O(1) integer matching. No string comparisons required!
        return root.script_globals.contains(name_id);
    }
};
