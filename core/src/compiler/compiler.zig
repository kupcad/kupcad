const std = @import("std");
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
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
    index: u8,
    is_local: bool,
};

pub const Local = struct {
    name_id: ast.StringId,
    slot: u8,
};

pub const LoopState = struct {
    start: usize,
    exit_jumps: [16]usize = undefined,
    exit_count: usize = 0,
};

const Intrinsic = enum {
    raise_err,
    // Future compiler intrinsics (e.g., typeof, sizeof) will go here
};

const compiler_intrinsics = std.StaticStringMap(Intrinsic).initComptime(.{
    .{ "raise", .raise_err },
});

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,
    symbols: []const resolver.ResolvedSymbol,
    token_starts: []const u32, // Map AST nodes back to Lexer byte offsets
    current_source_offset: u32, // Implictly passed to Chunk
    current_chunk: *chunk.Chunk,
    vm: *VM,

    // Lexical Scope Tracking
    enclosing: ?*Compiler = null,
    function: ?*value.ObjFunction = null,

    upvalues: [255]Upvalue = undefined,
    upvalue_count: usize = 0,

    locals: [255]Local = undefined,
    local_count: usize = 0,

    loops: [8]LoopState = undefined,
    loop_count: usize = 0,

    current_stack_depth: usize,
    max_stack_depth: usize,

    pub const MAX_LOCALS = std.math.maxInt(u8);
    pub const MAX_CONSTANTS = std.math.maxInt(u8);
    pub const MAX_ARGS = std.math.maxInt(u8);

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
            .symbols = symbols,
            .token_starts = token_starts,
            .current_chunk = output_chunk,
            .vm = vm,
            .enclosing = null,
            .function = null,
            .upvalue_count = 0,
            .local_count = 0,
            .current_stack_depth = 0,
            .max_stack_depth = 0,
            .loop_count = 0,
            .current_source_offset = 0,
        };
    }

    // --- Lexical Scope Resolvers ---

    fn addLocal(self: *Compiler, name_id: ast.StringId, slot: u8) void {
        for (self.locals[0..self.local_count]) |loc| {
            if (loc.name_id == name_id) return;
        }
        if (self.local_count < 255) {
            self.locals[self.local_count] = .{ .name_id = name_id, .slot = slot };
            self.local_count += 1;
        }
    }

    fn resolveLocal(self: *Compiler, name_id: ast.StringId) ?u8 {
        var i: usize = self.local_count;
        while (i > 0) {
            i -= 1;
            if (self.locals[i].name_id == name_id) return self.locals[i].slot;
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

    fn addUpvalue(self: *Compiler, index: u8, is_local: bool) CompileError!u8 {
        for (self.upvalues[0..self.upvalue_count], 0..) |upv, i| {
            if (upv.index == index and upv.is_local == is_local) {
                return @intCast(i);
            }
        }
        if (self.upvalue_count >= 255) return error.TooManyLocals;
        self.upvalues[self.upvalue_count] = .{ .index = index, .is_local = is_local };
        self.upvalue_count += 1;
        if (self.function) |f| f.upvalue_count = @intCast(self.upvalue_count);
        return @intCast(self.upvalue_count - 1);
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
                const str_val = try self.vm.allocateString(str_content);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(str_val);
                const str_idx = try self.makeConstant(str_val);
                _ = self.vm.pop();
                try self.emitOp(.op_constant);
                try self.emitByte(str_idx);
            },
            .boolean => {
                const val = self.tree.boolean(node);
                if (val) try self.emitOp(.op_true) else try self.emitOp(.op_false);
            },
            .undef => {
                try self.emitOp(.op_nil);
            },
            .symbol => {
                const sym_str = self.tree.getString(@as(ast.StringId, @enumFromInt(node.data)));
                const sym_val = try self.vm.allocateSymbol(sym_str);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(sym_val);
                const sym_idx = try self.makeConstant(sym_val);
                _ = self.vm.pop();
                try self.emitOp(.op_constant);
                try self.emitByte(sym_idx);
            },
            .identifier => {
                const sym = self.symbols[@intFromEnum(node_idx)];
                const name_id = @as(ast.StringId, @enumFromInt(node.data));

                if (sym.kind == .global) {
                    const name = self.tree.getString(name_id);
                    const name_idx = try self.makeStringConstant(name);
                    _ = self.vm.pop();
                    try self.emitOp(.op_get_global);
                    try self.emitByte(name_idx);
                } else {
                    // Try to resolve in the current compiler, then recurse upwards!
                    if (self.resolveLocal(name_id)) |local_slot| {
                        try self.emitOp(.op_get_local);
                        try self.emitByte(local_slot);
                    } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                        try self.emitOp(.op_get_upvalue);
                        try self.emitByte(upvalue_slot);
                    } else {
                        // Top-level scripts fallback
                        try self.emitOp(.op_get_local);
                        try self.emitByte(@intCast(sym.index));
                    }
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
                if (self.loop_count == 0) return error.UnknownNode;
                const jump = try self.emitJump(.op_jump);
                var cur_loop = &self.loops[self.loop_count - 1];
                if (cur_loop.exit_count >= 16) return error.UnknownNode;
                cur_loop.exit_jumps[cur_loop.exit_count] = jump;
                cur_loop.exit_count += 1;
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
                if (self.loop_count == 0) return error.UnknownNode;
                const cur_loop = &self.loops[self.loop_count - 1];
                try self.emitLoop(cur_loop.start);
                self.simulatePush(1); // Equilibrium for dead code
            },
            .assignment => {
                const assign_payload = self.tree.assignment(node);
                const sym = self.symbols[@intFromEnum(node_idx)];
                const name_id = assign_payload.name;

                // 1. Evaluate RHS (with Compound Operator getters if necessary)
                if (assign_payload.op) |op| {
                    if (sym.kind == .global) {
                        const name_idx = try self.makeStringConstant(self.tree.getString(name_id));
                        try self.emitOp(.op_get_global);
                        try self.emitByte(name_idx);
                    } else if (self.resolveLocal(name_id)) |local_slot| {
                        try self.emitOp(.op_get_local);
                        try self.emitByte(local_slot);
                    } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                        try self.emitOp(.op_get_upvalue);
                        try self.emitByte(upvalue_slot);
                    } else {
                        try self.emitOp(.op_get_local);
                        try self.emitByte(@intCast(sym.index));
                    }

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

                // 2. Set the Target Variable
                if (sym.kind == .global) {
                    const name_str = self.tree.getString(name_id);
                    const name_val = try self.vm.allocateString(name_str);
                    self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                    self.vm.push(name_val);
                    const name_idx = try self.makeConstant(name_val);
                    _ = self.vm.pop();

                    try self.emitOp(.op_define_global);
                    try self.emitByte(name_idx);
                    try self.emitOp(.op_nil); // Equilibrium: Assignment blocks yield nil
                } else if (self.resolveLocal(name_id)) |local_slot| {
                    try self.emitOp(.op_set_local);
                    try self.emitByte(local_slot);
                } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                    try self.emitOp(.op_set_upvalue);
                    try self.emitByte(upvalue_slot);
                } else {
                    self.addLocal(name_id, @intCast(sym.index));
                    try self.emitOp(.op_set_local);
                    try self.emitByte(@intCast(sym.index));
                }
            },
            .case_stmt => {
                const cs = self.tree.caseStmt(node);
                const saved_depth = self.current_stack_depth;
                const branches = self.tree.getWhenBranches(cs.when_branches);

                // --- Heuristic: Can we use a Fast Jump Table? ---
                var can_use_jump_table = true;
                var total_conditions: u8 = 0;
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

                    try self.emitOp(.op_switch);
                    try self.emitByte(total_conditions);

                    // Pre-allocate the jump table in bytecode so we can backpatch it later
                    const table_start_offset = self.current_chunk.code.items.len;
                    for (0..total_conditions) |_| {
                        try self.emitByte(0); // const_idx
                        try self.emitByte(0xFF); // jump high
                        try self.emitByte(0xFF); // jump low
                    }
                    const default_jump_offset = self.current_chunk.code.items.len;
                    try self.emitByte(0xFF); // default high
                    try self.emitByte(0xFF); // default low

                    var condition_idx: usize = 0;
                    var end_jumps: [64]usize = undefined;
                    var end_jump_count: usize = 0;

                    for (branches) |branch| {
                        const body_jump_target = self.current_chunk.code.items.len;
                        const conds = self.tree.getNodes(branch.conditions);

                        // Backpatch the table entries for this branch
                        for (conds) |cond_node_idx| {
                            const c_node = self.tree.getNode(cond_node_idx).?;
                            const table_idx = table_start_offset + (condition_idx * 3);

                            // Extract constant index directly
                            if (c_node.tag == .number) {
                                self.current_chunk.code.items[table_idx] = try self.makeConstant(value.Value.initNumber(self.tree.number(c_node)));
                            } else if (c_node.tag == .string) {
                                const str_content = self.tree.getString(@as(ast.StringId, @enumFromInt(c_node.data)));
                                self.current_chunk.code.items[table_idx] = try self.makeStringConstant(str_content);
                            }

                            // Calculate offset from the END of the entire switch instruction block
                            const offset = body_jump_target - (default_jump_offset + 2);
                            self.current_chunk.code.items[table_idx + 1] = @intCast((offset >> 8) & 0xFF);
                            self.current_chunk.code.items[table_idx + 2] = @intCast(offset & 0xFF);
                            condition_idx += 1;
                        }

                        // Compile the actual body
                        try self.compileNode(branch.body);

                        if (end_jump_count < 64) {
                            end_jumps[end_jump_count] = try self.emitJump(.op_jump);
                            end_jump_count += 1;
                        }
                    }

                    // Backpatch Default Branch
                    const default_target = self.current_chunk.code.items.len;
                    const d_offset = default_target - (default_jump_offset + 2);
                    self.current_chunk.code.items[default_jump_offset] = @intCast((d_offset >> 8) & 0xFF);
                    self.current_chunk.code.items[default_jump_offset + 1] = @intCast(d_offset & 0xFF);

                    if (cs.else_branch != .none) {
                        try self.compileNode(cs.else_branch);
                    } else {
                        try self.emitOp(.op_nil);
                    }

                    // Cap off all successful branch executions
                    for (end_jumps[0..end_jump_count]) |jmp| {
                        self.patchJump(jmp);
                    }
                    self.current_stack_depth = saved_depth + 1;
                } else {
                    // ====== LINEAR FALLBACK PATH ======
                    try self.compileNode(cs.condition);

                    var end_jumps: [64]usize = undefined;
                    var end_jump_count: usize = 0;

                    for (branches) |branch| {
                        const conds = self.tree.getNodes(branch.conditions);
                        for (conds) |cond_idx| {
                            try self.emitOp(.op_dup);
                            try self.compileNode(cond_idx);
                            try self.emitOp(.op_equal);
                            const skip_jump = try self.emitJump(.op_jump_if_false);

                            try self.emitOp(.op_pop);
                            try self.emitOp(.op_pop);
                            try self.compileNode(branch.body);

                            if (end_jump_count < 64) {
                                end_jumps[end_jump_count] = try self.emitJump(.op_jump);
                                end_jump_count += 1;
                            }

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

                    for (end_jumps[0..end_jump_count]) |jmp| {
                        self.patchJump(jmp);
                    }
                    self.current_stack_depth = saved_depth + 1;
                }
            },
            .begin_stmt => {
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

                    var rescue_end_jumps: [64]usize = undefined;
                    var rescue_end_jump_count: usize = 0;
                    var next_rescue_jump: ?usize = null;

                    for (rescues) |rescue| {
                        self.current_stack_depth = error_depth; // Reset for each rescue block

                        if (next_rescue_jump) |jmp| {
                            self.patchJump(jmp);
                        }
                        next_rescue_jump = null;

                        const errors = self.tree.getStringLists(rescue.errors);
                        var match_jumps: [16]usize = undefined;
                        var match_jump_count: usize = 0;

                        if (errors.len > 0) {
                            for (errors) |err_id| {
                                self.current_stack_depth = error_depth; // Reset for each type check

                                const name_idx = try self.makeStringConstant(self.tree.getString(err_id));

                                try self.emitOp(.op_dup); // Copy error payload
                                try self.emitOp(.op_get_global);
                                try self.emitByte(name_idx);
                                try self.emitOp(.op_is_instance);

                                const skip_jump = try self.emitJump(.op_jump_if_false);
                                try self.emitOp(.op_pop); // Discard True

                                if (match_jump_count < 16) {
                                    match_jumps[match_jump_count] = try self.emitJump(.op_jump);
                                    match_jump_count += 1;
                                }

                                self.current_stack_depth = error_depth + 1; // False branch has error + false
                                self.patchJump(skip_jump);
                                try self.emitOp(.op_pop); // Discard False
                            }
                            // If no error type matched, jump to the next rescue block
                            next_rescue_jump = try self.emitJump(.op_jump);
                        }

                        // --- MATCHED ROUTE ---
                        self.current_stack_depth = error_depth; // Jump lands here with error on top
                        for (match_jumps[0..match_jump_count]) |jmp| {
                            self.patchJump(jmp);
                        }

                        const var_str = self.tree.getString(rescue.variable);
                        if (var_str.len > 0) {
                            self.addLocal(rescue.variable, @intCast(self.local_count));
                            try self.emitOp(.op_set_local);
                            try self.emitByte(@intCast(self.local_count - 1));
                        }
                        try self.emitOp(.op_pop); // Pop the error value off stack

                        try self.compileNode(rescue.body);

                        if (rescue_end_jump_count < 64) {
                            rescue_end_jumps[rescue_end_jump_count] = try self.emitJump(.op_jump);
                            rescue_end_jump_count += 1;
                        }
                    }

                    // If it fell through ALL rescue blocks without matching, re-throw it!
                    if (next_rescue_jump) |jmp| {
                        self.current_stack_depth = error_depth;
                        self.patchJump(jmp);
                        try self.emitOp(.op_throw); // op_throw inherently calls simulatePop(1)
                        self.simulatePush(1); // Dead code equilibrium instead of double-popping!
                    }

                    // Patch all successful rescue block ends to arrive here
                    for (rescue_end_jumps[0..rescue_end_jump_count]) |jmp| {
                        self.patchJump(jmp);
                    }
                    self.current_stack_depth = error_depth; // The block successfully yields 1 value (error_depth is depth + 1)
                }

                self.patchJump(end_jump);

                if (bs.ensure_body != .none) {
                    try self.compileNode(bs.ensure_body);
                    try self.emitOp(.op_pop); // discard ensure block output
                }
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
                try self.emitOp(.op_get_global);
                try self.emitByte(root_idx);

                // Chain property accesses for the rest of the namespace path
                for (path[1..]) |segment_id| {
                    const seg_idx = try self.makeStringConstant(self.tree.getString(segment_id));
                    try self.emitOp(.op_get_property);
                    try self.emitByte(seg_idx);
                }
            },
            .module_stmt => {
                const ms = self.tree.moduleStmt(node);
                const name_str = self.tree.getString(ms.name);

                // For MVP, compile a Module just like a Class to act as a singleton namespace container
                const name_val = try self.vm.allocateString(name_str);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(name_val);
                const name_idx = try self.makeConstant(name_val);
                _ = self.vm.pop();

                try self.emitOp(.op_class);
                try self.emitByte(name_idx);

                try self.emitOp(.op_define_global);
                try self.emitByte(name_idx);

                try self.compileNode(ms.body); // Compile module contents
                try self.emitOp(.op_pop); // Pop body result
                try self.emitOp(.op_nil); // module stmt yields nil
            },
            .import_stmt => {
                const is_stmt = self.tree.importStmt(node);
                const path_str = self.tree.getString(is_stmt.path);

                const path_val = try self.vm.allocateString(path_str);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(path_val);
                const path_idx = try self.makeConstant(path_val);
                _ = self.vm.pop();

                try self.emitOp(.op_import);
                try self.emitByte(path_idx);

                const symbols = self.tree.getStringLists(is_stmt.symbols);
                if (symbols.len == 0) {
                    // Standard import for side-effects. Ignore returned module.
                    try self.emitOp(.op_pop);
                    try self.emitOp(.op_nil);
                } else {
                    // Extract specific symbols via destructuring
                    try self.emitOp(.op_pop);
                    try self.emitOp(.op_nil); // Yield nil for MVP
                }
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

                // 1. Setup an isolated function on the VM heap
                const func = try self.vm.gc.allocateFunction(self.vm);
                func.arity = @intCast(params.len);

                // Protect the function from GC while compiling the child block!
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(value.Value.initObj(&func.obj));

                // Guarantee the function is popped off the stack if compilation fails
                errdefer _ = self.vm.pop();

                const child_chunk = try self.allocator.create(chunk.Chunk);
                child_chunk.* = chunk.Chunk.init();
                func.chunk = child_chunk;

                // 2. Link a Child Compiler to parse the inner block
                var child_compiler = Compiler{
                    .allocator = self.allocator,
                    .tree = self.tree,
                    .symbols = self.symbols,
                    .token_starts = self.token_starts,
                    .current_chunk = child_chunk,
                    .vm = self.vm,
                    .enclosing = self,
                    .function = func,
                    .upvalue_count = 0,
                    .local_count = 0,
                    .current_stack_depth = 0,
                    .max_stack_depth = 0,
                    .current_source_offset = self.current_source_offset,
                };

                // Reserve slot 0 for the closure itself
                child_compiler.local_count = 1;
                child_compiler.locals[0] = .{ .name_id = .none, .slot = 0 };

                // Assign the parameters their starting stack slots (starting at 1)
                for (params, 0..) |param, i| {
                    child_compiler.addLocal(param.name, @intCast(i + 1));
                }

                // Compile the inner body recursively
                try child_compiler.compile(body_node);

                // Unprotect the function now that compilation is done
                _ = self.vm.pop();

                // 3. Emit the Closure and its exact Upvalue captures into the PARENT chunk
                const func_val = value.Value.initObj(&func.obj);
                const func_idx = try self.makeConstant(func_val);

                try self.emitOp(.op_closure);
                try self.emitByte(func_idx);

                for (child_compiler.upvalues[0..child_compiler.upvalue_count]) |upv| {
                    try self.emitByte(if (upv.is_local) 1 else 0);
                    try self.emitByte(upv.index);
                }

                // 4. Bind the closure to its name (if it's a def statement)
                if (node.tag == .def_stmt) {
                    const sym = self.symbols[@intFromEnum(node_idx)];
                    if (sym.kind == .global) {
                        const name_str = self.tree.getString(def_name_id);
                        const name_val = try self.vm.allocateString(name_str);
                        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                        self.vm.push(name_val);
                        const name_idx = try self.makeConstant(name_val);
                        _ = self.vm.pop();

                        try self.emitOp(.op_define_global);
                        try self.emitByte(name_idx);
                        try self.emitOp(.op_nil); // Equilibrium: yield nil to the block
                    } else {
                        self.addLocal(def_name_id, @intCast(sym.index));
                        try self.emitOp(.op_set_local);
                        try self.emitByte(@intCast(sym.index));
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
                    // Double-evaluate target and index to fetch current value.
                    try self.compileNode(ia.target);
                    try self.compileNode(ia.index);
                    try self.emitOp(.op_get_index);

                    try self.compileNode(ia.value);

                    switch (op) {
                        .add => try self.emitOp(.op_add),
                        .subtract => try self.emitOp(.op_subtract),
                        .multiply => try self.emitOp(.op_multiply),
                        .divide => try self.emitOp(.op_divide),
                        else => return error.UnknownNode,
                    }
                } else {
                    try self.compileNode(ia.value);
                }

                try self.emitOp(.op_set_index);
            },
            .method_call => {
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
                    }
                }

                var safe_jump: usize = 0;

                // Push Receiver/Target
                if (mc.receiver == .none) {
                    const name_idx = try self.makeStringConstant(func_name);
                    try self.emitOp(.op_get_global);
                    try self.emitByte(name_idx);
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
                        try self.emitOp(.op_constant);
                        try self.emitByte(name_idx);
                        try self.compileNode(arg.value);
                        kw_count += 1;
                    }
                }

                if (kw_count > 0) {
                    try self.emitOp(.op_build_map);
                    try self.emitByte(@intCast(kw_count));
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
                        .upvalue_count = 0,
                        .local_count = 0,
                        .current_stack_depth = 0,
                        .max_stack_depth = 0,
                        .current_source_offset = self.current_source_offset,
                    };

                    child_compiler.local_count = 1;
                    child_compiler.locals[0] = .{ .name_id = .none, .slot = 0 };
                    for (block_params, 0..) |p_idx, i| {
                        const p_node = self.tree.getNode(p_idx).?;
                        const name_id = @as(ast.StringId, @enumFromInt(p_node.data));
                        child_compiler.addLocal(name_id, @intCast(i + 1));
                    }

                    // Compiling a block automatically leaves the last statement on the stack as an implicit return!
                    try child_compiler.compile(mc.block);

                    _ = self.vm.pop();
                    const func_val = value.Value.initObj(&func.obj);
                    const func_idx = try self.makeConstant(func_val);
                    try self.emitOp(.op_closure);
                    try self.emitByte(func_idx);
                    for (child_compiler.upvalues[0..child_compiler.upvalue_count]) |upv| {
                        try self.emitByte(if (upv.is_local) 1 else 0);
                        try self.emitByte(upv.index);
                    }
                    actual_arg_count += 1;
                }

                if (actual_arg_count > MAX_ARGS) return error.TooManyConstants;

                // 4. Execute Invocation
                if (mc.receiver == .none) {
                    try self.emitOp(.op_call);
                    try self.emitByte(@intCast(actual_arg_count));
                } else {
                    const name_idx = try self.makeStringConstant(func_name);
                    try self.emitOp(.op_invoke);
                    try self.emitByte(name_idx);
                    try self.emitByte(@intCast(actual_arg_count));
                    if (mc.is_safe) self.patchJump(safe_jump);
                }

                self.simulatePop(actual_arg_count + 1);
                self.simulatePush(1);
            },
            .binary_op => {
                const bin_expr = self.tree.binaryExpr(node);

                // 1. Handle Short-Circuiting Logical Operators BEFORE compiling the right side!
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

                // 2. Standard Binary Operators
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
                    else => return error.UnknownNode,
                }
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
            .array_literal => {
                const elements = self.tree.getNodes(self.tree.nodeSpan(node));

                var has_splat = false;
                for (elements) |elem| {
                    if (self.tree.getNode(elem).?.tag == .splat_expr) has_splat = true;
                }

                if (!has_splat) {
                    for (elements) |elem| try self.compileNode(elem);
                    if (elements.len > MAX_ARGS) return error.TooManyConstants;
                    try self.emitOp(.op_build_array);
                    try self.emitByte(@intCast(elements.len));
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
            },
            .hash_literal => {
                const entries = self.tree.getHashEntries(self.tree.nodeSpan(node));

                var has_splat = false;
                for (entries) |entry| {
                    if (self.tree.getNode(entry.key).?.tag == .double_splat_expr) has_splat = true;
                }

                if (!has_splat) {
                    for (entries) |entry| {
                        const key_node = self.tree.getNode(entry.key).?;
                        if (key_node.tag == .identifier) {
                            const str_content = self.tree.getString(@as(ast.StringId, @enumFromInt(key_node.data)));
                            const str_val = try self.vm.allocateString(str_content);
                            self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                            self.vm.push(str_val);
                            const str_idx = try self.makeConstant(str_val);
                            _ = self.vm.pop();
                            try self.emitOp(.op_constant);
                            try self.emitByte(str_idx);
                        } else {
                            try self.compileNode(entry.key);
                        }
                        try self.compileNode(entry.value);
                    }
                    if (entries.len > 127) return error.TooManyConstants;
                    try self.emitOp(.op_build_map);
                    try self.emitByte(@intCast(entries.len));
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
                                try self.emitOp(.op_constant);
                                try self.emitByte(str_idx);
                            } else {
                                try self.compileNode(entry.key);
                            }
                            try self.compileNode(entry.value);
                            try self.emitOp(.op_map_insert);
                        }
                    }
                }
            },
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
                // 'self' is intrinsically bound to local slot 0
                try self.emitOp(.op_get_local);
                try self.emitByte(0);
            },
            .while_stmt => {
                const while_payload = self.tree.whileStmt(node);
                const loop_start = self.current_chunk.code.items.len;

                // Push loop state
                if (self.loop_count >= 8) return error.UnknownNode;
                self.loops[self.loop_count] = .{ .start = loop_start, .exit_count = 0 };
                self.loop_count += 1;

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
                self.loop_count -= 1;
                const cur_loop = self.loops[self.loop_count];
                for (cur_loop.exit_jumps[0..cur_loop.exit_count]) |jmp| {
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

                if (parts.len > 255) return error.TooManyConstants;

                try self.emitOp(.op_interpolate);
                try self.emitByte(@intCast(parts.len));

                self.simulatePop(parts.len);
                self.simulatePush(1); // Pushes the final merged String
            },
            .multiple_assignment => {
                const ma = self.tree.multipleAssignment(node);
                const lhs = self.tree.getLhsExprs(ma.lhs);

                for (lhs) |l| {
                    if (l.modifier != null and l.modifier.? == .splat) {
                        std.log.err("Compile Error: Destructuring splats (LHS) like `a, *b = arr` are not yet supported.", .{});
                        return error.UnsupportedScope;
                    }
                }

                try self.compileNode(ma.value);
                if (lhs.len > 255) return error.TooManyConstants;

                try self.emitOp(.op_unpack);
                try self.emitByte(@intCast(lhs.len));
                self.simulatePush(lhs.len);

                var i: usize = lhs.len;
                while (i > 0) {
                    i -= 1;
                    try self.compileDestructure(lhs[i]);
                }
                try self.emitOp(.op_nil);
            },
            .class_stmt => {
                const cs = self.tree.classStmt(node);
                const name_node = self.tree.getNode(cs.name).?;
                const name_id = @as(ast.StringId, @enumFromInt(name_node.data));
                const class_name = self.tree.getString(name_id);

                const name_val = try self.vm.allocateString(class_name);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(name_val);
                const name_idx = try self.makeConstant(name_val);
                _ = self.vm.pop();

                // 1. Push the un-initialized class onto the stack (+1)
                try self.emitOp(.op_class);
                try self.emitByte(name_idx);

                if (cs.super_class != .none) {
                    try self.compileNode(cs.super_class); // Evaluates base class and leaves it on stack
                    try self.emitOp(.op_inherit); // Wires base to child
                }

                // 2. Compile all inner methods while the Class sits on top of the stack
                const body_node = self.tree.getNode(cs.body).?;
                const block_payload = self.tree.block(body_node);
                const stmts = self.tree.getNodes(block_payload.stmts);

                for (stmts) |stmt_idx| {
                    const stmt_node = self.tree.getNode(stmt_idx).?;
                    if (stmt_node.tag == .def_stmt) {
                        const ds = self.tree.defStmt(stmt_node);
                        const method_name = self.tree.getString(ds.name);

                        const m_name_val = try self.vm.allocateString(method_name);
                        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                        self.vm.push(m_name_val);
                        const m_name_idx = try self.makeConstant(m_name_val);
                        _ = self.vm.pop();

                        // Compile the closure isolated from the parent
                        const func = try self.vm.gc.allocateFunction(self.vm);
                        const params = self.tree.getParams(ds.params);
                        func.arity = @intCast(params.len);

                        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                        self.vm.push(value.Value.initObj(&func.obj));

                        // Guarantee the function is popped off the stack if compilation fails!
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
                            .upvalue_count = 0,
                            .local_count = 0,
                            .current_stack_depth = 0,
                            .max_stack_depth = 0,
                            .current_source_offset = self.current_source_offset,
                        };

                        // Reserve slot 0 as the implicit 'self' receiver
                        child_compiler.local_count = 1;
                        child_compiler.locals[0] = .{ .name_id = .none, .slot = 0 };

                        for (params, 0..) |param, i| {
                            child_compiler.addLocal(param.name, @intCast(i + 1));
                        }
                        try child_compiler.compile(ds.body);
                        _ = self.vm.pop(); // unprotect

                        const func_val = value.Value.initObj(&func.obj);
                        const func_idx = try self.makeConstant(func_val);

                        try self.emitOp(.op_closure); // (+1)
                        try self.emitByte(func_idx);

                        for (child_compiler.upvalues[0..child_compiler.upvalue_count]) |upv| {
                            try self.emitByte(if (upv.is_local) 1 else 0);
                            try self.emitByte(upv.index);
                        }

                        try self.emitOp(.op_method); // (-1)
                        try self.emitByte(m_name_idx);
                    }
                }

                // 3. Define the Class variable
                const sym = self.symbols[@intFromEnum(node_idx)];
                if (sym.kind == .local) {
                    self.addLocal(name_id, @intCast(sym.index));
                    try self.emitOp(.op_set_local);
                    try self.emitByte(@intCast(sym.index));
                    // Equilibrium: Class remains on stack (+1)
                } else {
                    try self.emitOp(.op_define_global);
                    try self.emitByte(name_idx);
                    try self.emitOp(.op_nil);
                    // Equilibrium: Class popped, dummy nil pushed (+1)
                }
            },
            .super_call => {
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
                        try self.emitOp(.op_constant);
                        try self.emitByte(name_idx);
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
            },
            .property_assignment => {
                const pa = self.tree.propertyAssignment(node);

                const prop_name = self.tree.getString(pa.property);
                const name_val = try self.vm.allocateString(prop_name);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(name_val);
                const name_idx = try self.makeConstant(name_val);
                _ = self.vm.pop();

                try self.compileNode(pa.target);

                if (pa.op) |op| {
                    try self.compileNode(pa.target);
                    try self.emitOp(.op_invoke);
                    try self.emitByte(name_idx);
                    try self.emitByte(0); // 0 args

                    try self.compileNode(pa.value);

                    switch (op) {
                        .add => try self.emitOp(.op_add),
                        .subtract => try self.emitOp(.op_subtract),
                        .multiply => try self.emitOp(.op_multiply),
                        .divide => try self.emitOp(.op_divide),
                        else => return error.UnknownNode,
                    }
                } else {
                    try self.compileNode(pa.value);
                }

                try self.emitOp(.op_set_property);
                try self.emitByte(name_idx);
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
            .op_nil, .op_true, .op_false, .op_get_local, .op_get_global, .op_constant, .op_closure, .op_get_upvalue, .op_dup, .op_import => self.simulatePush(1),
            .op_pop, .op_return, .op_close_upvalue, .op_pop_rescue, .op_throw, .op_array_push, .op_array_spread, .op_map_spread, .op_switch, .op_inherit, .op_super_invoke => self.simulatePop(1),
            .op_map_insert => self.simulatePop(2),
            .op_is_instance, .op_add, .op_subtract, .op_multiply, .op_divide, .op_equal, .op_less, .op_greater, .op_modulo, .op_exponent => {
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
            .op_class => self.simulatePush(1),
            .op_method, .op_define_global => self.simulatePop(1),
            .op_set_property => {
                self.simulatePop(2); // Pops value and object
                self.simulatePush(1); // Assignment yields value
            },
            .op_unpack => {
                self.simulatePop(1);
            },
            else => {},
        }
    }

    fn makeConstant(self: *Compiler, val: value.Value) CompileError!u8 {
        const index = self.current_chunk.addConstant(self.allocator, val) catch return error.OutOfMemory;
        if (index > MAX_CONSTANTS) return error.TooManyConstants;
        return @intCast(index);
    }

    fn emitConstant(self: *Compiler, val: value.Value) CompileError!void {
        const index = try self.makeConstant(val);
        try self.emitOp(.op_constant);
        try self.emitByte(index);
    }

    fn emitJump(self: *Compiler, op: chunk.OpCode) CompileError!usize {
        try self.emitOp(op);
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        return self.current_chunk.code.items.len - 2;
    }

    fn patchJump(self: *Compiler, offset: usize) void {
        const jump = self.current_chunk.code.items.len - offset - 2;
        std.debug.assert(jump <= std.math.maxInt(u16));
        self.current_chunk.code.items[offset] = @intCast((jump >> 8) & 0xff);
        self.current_chunk.code.items[offset + 1] = @intCast(jump & 0xff);
    }

    fn emitLoop(self: *Compiler, loop_start: usize) CompileError!void {
        try self.emitOp(.op_loop);
        const jump = self.current_chunk.code.items.len - loop_start + 2;
        std.debug.assert(jump <= std.math.maxInt(u16));
        try self.emitByte(@intCast((jump >> 8) & 0xff));
        try self.emitByte(@intCast(jump & 0xff));
    }

    fn makeStringConstant(self: *Compiler, text: []const u8) CompileError!u8 {
        const str_val = try self.vm.allocateString(text);
        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
        self.vm.push(str_val);
        const idx = try self.makeConstant(str_val);
        _ = self.vm.pop();
        return idx;
    }

    fn compileDestructure(self: *Compiler, target: anytype) CompileError!void {
        // Assign the unpacked value currently on top of the stack to the target identifier
        if (target.name != .none) {
            const name_id = target.name;
            if (self.resolveLocal(name_id)) |local_slot| {
                try self.emitOp(.op_set_local);
                try self.emitByte(local_slot);
                try self.emitOp(.op_pop);
            } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                try self.emitOp(.op_set_upvalue);
                try self.emitByte(upvalue_slot);
                try self.emitOp(.op_pop);
            } else {
                const name_idx = try self.makeStringConstant(self.tree.getString(name_id));
                if (self.enclosing == null) {
                    try self.emitOp(.op_define_global);
                    try self.emitByte(name_idx);
                } else {
                    self.addLocal(name_id, @intCast(self.local_count));
                    try self.emitOp(.op_set_local);
                    try self.emitByte(@intCast(self.local_count - 1));
                    try self.emitOp(.op_pop);
                }
            }
        } else {
            // Unhandled pattern or skipped element (e.g., `_`): pop to maintain stack equilibrium
            try self.emitOp(.op_pop);
        }
    }
};
