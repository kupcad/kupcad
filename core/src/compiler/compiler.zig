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

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,
    symbols: []const resolver.ResolvedSymbol,
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
        output_chunk: *chunk.Chunk,
        vm: *VM,
    ) Compiler {
        return .{
            .allocator = allocator,
            .tree = tree,
            .symbols = symbols,
            .current_chunk = output_chunk,
            .vm = vm,
            .enclosing = null,
            .function = null,
            .upvalue_count = 0,
            .local_count = 0,
            .current_stack_depth = 0,
            .max_stack_depth = 0,
            .loop_count = 0,
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
            try self.emitOp(.op_nil, 0);
        } else {
            try self.compileNode(root);
        }
        try self.emitOp(.op_return, 0);
        self.current_chunk.max_stack_slots = self.max_stack_depth;
    }

    fn compileNode(self: *Compiler, node_idx: ast.NodeIndex) CompileError!void {
        if (node_idx == .none) return;
        const node = self.tree.getNode(node_idx) orelse return error.UnknownNode;
        const line: u32 = 1;

        switch (node.tag) {
            .number => {
                const val = self.tree.number(node);
                try self.emitConstant(value.Value.initNumber(val), line);
            },
            .string => {
                const str_content = self.tree.getString(@as(ast.StringId, @enumFromInt(node.data)));
                const str_val = try self.vm.allocateString(str_content);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(str_val);
                const str_idx = try self.makeConstant(str_val);
                _ = self.vm.pop();
                try self.emitOp(.op_constant, line);
                try self.emitByte(str_idx, line);
            },
            .identifier => {
                const sym = self.symbols[@intFromEnum(node_idx)];
                const name_id = @as(ast.StringId, @enumFromInt(node.data));

                if (sym.kind == .global) {
                    const name = self.tree.getString(name_id);
                    const name_val = try self.vm.allocateString(name);
                    self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                    self.vm.push(name_val);
                    const name_idx = try self.makeConstant(name_val);
                    _ = self.vm.pop();
                    try self.emitOp(.op_get_global, line);
                    try self.emitByte(name_idx, line);
                } else {
                    // Try to resolve in the current compiler, then recurse upwards!
                    if (self.resolveLocal(name_id)) |local_slot| {
                        try self.emitOp(.op_get_local, line);
                        try self.emitByte(local_slot, line);
                    } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                        try self.emitOp(.op_get_upvalue, line);
                        try self.emitByte(upvalue_slot, line);
                    } else {
                        // Top-level scripts fallback
                        try self.emitOp(.op_get_local, line);
                        try self.emitByte(@intCast(sym.index), line);
                    }
                }
            },
            .return_stmt => {
                const ret_idx = self.tree.nodeIndex(node);
                if (ret_idx != .none) {
                    try self.compileNode(ret_idx);
                } else {
                    try self.emitOp(.op_nil, line);
                }
                try self.emitOp(.op_return, line);
                self.simulatePush(1); // Equilibrium for dead code
            },
            .break_stmt => {
                const break_idx = self.tree.nodeIndex(node);
                if (break_idx != .none) {
                    try self.compileNode(break_idx);
                } else {
                    try self.emitOp(.op_nil, line);
                }
                if (self.loop_count == 0) return error.UnknownNode;
                const jump = try self.emitJump(.op_jump, line);
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
                    try self.emitOp(.op_nil, line);
                }
                try self.emitOp(.op_pop, line);
                if (self.loop_count == 0) return error.UnknownNode;
                const cur_loop = &self.loops[self.loop_count - 1];
                try self.emitLoop(cur_loop.start, line);
                self.simulatePush(1); // Equilibrium for dead code
            },
            .assignment => {
                const assign_payload = self.tree.assignment(node);
                const sym = self.symbols[@intFromEnum(node_idx)];
                const name_id = assign_payload.name;

                // 1. Evaluate RHS (with Compound Operator getters if necessary)
                if (assign_payload.op) |op| {
                    if (sym.kind == .global) {
                        const name_str = self.tree.getString(name_id);
                        const name_val = try self.vm.allocateString(name_str);
                        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                        self.vm.push(name_val);
                        const name_idx = try self.makeConstant(name_val);
                        _ = self.vm.pop();

                        try self.emitOp(.op_get_global, line);
                        try self.emitByte(name_idx, line);
                    } else if (self.resolveLocal(name_id)) |local_slot| {
                        try self.emitOp(.op_get_local, line);
                        try self.emitByte(local_slot, line);
                    } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                        try self.emitOp(.op_get_upvalue, line);
                        try self.emitByte(upvalue_slot, line);
                    } else {
                        try self.emitOp(.op_get_local, line);
                        try self.emitByte(@intCast(sym.index), line);
                    }

                    try self.compileNode(assign_payload.value);

                    switch (op) {
                        .add => try self.emitOp(.op_add, line),
                        .subtract => try self.emitOp(.op_subtract, line),
                        .multiply => try self.emitOp(.op_multiply, line),
                        .divide => try self.emitOp(.op_divide, line),
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

                    try self.emitOp(.op_define_global, line);
                    try self.emitByte(name_idx, line);
                    try self.emitOp(.op_nil, line); // Equilibrium: Assignment blocks yield nil
                } else if (self.resolveLocal(name_id)) |local_slot| {
                    try self.emitOp(.op_set_local, line);
                    try self.emitByte(local_slot, line);
                } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                    try self.emitOp(.op_set_upvalue, line);
                    try self.emitByte(upvalue_slot, line);
                } else {
                    self.addLocal(name_id, @intCast(sym.index));
                    try self.emitOp(.op_set_local, line);
                    try self.emitByte(@intCast(sym.index), line);
                }
            },
            .case_stmt => {
                const cs = self.tree.caseStmt(node);

                const saved_depth = self.current_stack_depth;
                try self.compileNode(cs.condition); // Pushes 'case' value

                var end_jumps: [64]usize = undefined;
                var end_jump_count: usize = 0;

                const branches = self.tree.getWhenBranches(cs.when_branches);
                for (branches) |branch| {
                    const conds = self.tree.getNodes(branch.conditions);

                    for (conds) |cond_idx| {
                        try self.emitOp(.op_dup, line);
                        try self.compileNode(cond_idx);
                        try self.emitOp(.op_equal, line);

                        const skip_jump = try self.emitJump(.op_jump_if_false, line);

                        // Simulator trick: we are exploring the TRUE branch now.
                        try self.emitOp(.op_pop, line); // pop `true` result
                        try self.emitOp(.op_pop, line); // pop `case` value

                        try self.compileNode(branch.body);

                        if (end_jump_count < 64) {
                            end_jumps[end_jump_count] = try self.emitJump(.op_jump, line);
                            end_jump_count += 1;
                        }

                        // Now we simulate the FALSE branch path.
                        // In the false path, op_equal left `false` on the stack.
                        // So we force the simulator back to depth 2 (case_val, false).
                        self.current_stack_depth = saved_depth + 2;

                        self.patchJump(skip_jump);
                        try self.emitOp(.op_pop, line); // pop `false` result
                    }
                }

                try self.emitOp(.op_pop, line); // pop case value (no match found)

                if (cs.else_branch != .none) {
                    try self.compileNode(cs.else_branch);
                } else {
                    try self.emitOp(.op_nil, line);
                }

                for (end_jumps[0..end_jump_count]) |jmp| {
                    self.patchJump(jmp);
                }

                // Final equilibrium reset
                self.current_stack_depth = saved_depth + 1;
            },
            .begin_stmt => {
                const bs = self.tree.beginStmt(node);
                const rescues = self.tree.getRescueClauses(bs.rescues);

                var rescue_jump: usize = 0;
                if (rescues.len > 0) {
                    rescue_jump = try self.emitJump(.op_setup_rescue, line);
                }

                try self.compileNode(bs.body);

                if (rescues.len > 0) {
                    try self.emitOp(.op_pop_rescue, line);
                }

                const end_jump = try self.emitJump(.op_jump, line);

                if (rescues.len > 0) {
                    self.patchJump(rescue_jump);
                    self.simulatePush(1); // Simulator: op_throw pushed the error value on the stack

                    var rescue_end_jumps: [64]usize = undefined;
                    var rescue_end_jump_count: usize = 0;
                    var next_rescue_jump: ?usize = null;

                    for (rescues) |rescue| {
                        if (next_rescue_jump) |jmp| {
                            self.patchJump(jmp);
                        }
                        next_rescue_jump = null;

                        const errors = self.tree.getStringLists(rescue.errors);
                        var match_jumps: [16]usize = undefined;
                        var match_jump_count: usize = 0;

                        if (errors.len > 0) {
                            for (errors) |err_id| {
                                const err_str = self.tree.getString(err_id);
                                const name_val = try self.vm.allocateString(err_str);
                                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                                self.vm.push(name_val);
                                const name_idx = try self.makeConstant(name_val);
                                _ = self.vm.pop();

                                try self.emitOp(.op_dup, line); // Copy error payload
                                try self.emitOp(.op_get_global, line);
                                try self.emitByte(name_idx, line);
                                try self.emitOp(.op_is_instance, line);

                                const skip_jump = try self.emitJump(.op_jump_if_false, line);
                                try self.emitOp(.op_pop, line); // Discard True

                                if (match_jump_count < 16) {
                                    match_jumps[match_jump_count] = try self.emitJump(.op_jump, line);
                                    match_jump_count += 1;
                                }

                                self.patchJump(skip_jump);
                                try self.emitOp(.op_pop, line); // Discard False
                            }
                            // If no error type matched, jump to the next rescue block
                            next_rescue_jump = try self.emitJump(.op_jump, line);
                        }

                        // --- MATCHED ROUTE ---
                        for (match_jumps[0..match_jump_count]) |jmp| {
                            self.patchJump(jmp);
                        }

                        const var_str = self.tree.getString(rescue.variable);
                        if (var_str.len > 0) {
                            self.addLocal(rescue.variable, @intCast(self.local_count));
                            try self.emitOp(.op_set_local, line);
                            try self.emitByte(@intCast(self.local_count - 1), line);
                        }
                        try self.emitOp(.op_pop, line); // Pop the error value off stack

                        try self.compileNode(rescue.body);

                        if (rescue_end_jump_count < 64) {
                            rescue_end_jumps[rescue_end_jump_count] = try self.emitJump(.op_jump, line);
                            rescue_end_jump_count += 1;
                        }
                    }

                    // If it fell through ALL rescue blocks without matching, re-throw it
                    if (next_rescue_jump) |jmp| {
                        self.patchJump(jmp);
                        try self.emitOp(.op_throw, line);
                        self.simulatePop(1); // Simulator: op_throw consumes the error value
                    }

                    // Patch all successful rescue block ends to arrive here
                    for (rescue_end_jumps[0..rescue_end_jump_count]) |jmp| {
                        self.patchJump(jmp);
                    }
                }

                self.patchJump(end_jump);

                if (bs.ensure_body != .none) {
                    try self.compileNode(bs.ensure_body);
                    try self.emitOp(.op_pop, line); // discard ensure block output
                }
            },
            .rescue_modifier => {
                const rm = self.tree.rescueModifier(node);
                const rescue_jump = try self.emitJump(.op_setup_rescue, line);

                try self.compileNode(rm.expr);
                try self.emitOp(.op_pop_rescue, line);

                const end_jump = try self.emitJump(.op_jump, line);

                self.patchJump(rescue_jump);
                self.simulatePush(1); // Error value
                try self.emitOp(.op_pop, line); // Discard error value
                try self.compileNode(rm.rescue_expr);

                self.patchJump(end_jump);
            },
            .namespace_access => {
                const path = self.tree.getStringLists(self.tree.nodeSpan(node));
                if (path.len == 0) {
                    try self.emitOp(.op_nil, line);
                    return;
                }

                // Get the root of the namespace
                const root_str = self.tree.getString(path[0]);
                const root_val = try self.vm.allocateString(root_str);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(root_val);
                const root_idx = try self.makeConstant(root_val);
                _ = self.vm.pop();

                try self.emitOp(.op_get_global, line);
                try self.emitByte(root_idx, line);

                // Chain property accesses for the rest of the namespace path
                for (path[1..]) |segment_id| {
                    const segment_str = self.tree.getString(segment_id);
                    const seg_val = try self.vm.allocateString(segment_str);
                    self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                    self.vm.push(seg_val);
                    const seg_idx = try self.makeConstant(seg_val);
                    _ = self.vm.pop();

                    try self.emitOp(.op_get_property, line);
                    try self.emitByte(seg_idx, line);
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

                try self.emitOp(.op_class, line);
                try self.emitByte(name_idx, line);

                try self.emitOp(.op_define_global, line);
                try self.emitByte(name_idx, line);

                try self.compileNode(ms.body); // Compile module contents
                try self.emitOp(.op_pop, line); // Pop body result
                try self.emitOp(.op_nil, line); // module stmt yields nil
            },
            .import_stmt => {
                const is_stmt = self.tree.importStmt(node);
                const path_str = self.tree.getString(is_stmt.path);

                const path_val = try self.vm.allocateString(path_str);
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(path_val);
                const path_idx = try self.makeConstant(path_val);
                _ = self.vm.pop();

                try self.emitOp(.op_import, line);
                try self.emitByte(path_idx, line);

                const symbols = self.tree.getStringLists(is_stmt.symbols);
                if (symbols.len == 0) {
                    // Standard import for side-effects. Ignore returned module.
                    try self.emitOp(.op_pop, line);
                    try self.emitOp(.op_nil, line);
                } else {
                    // Extract specific symbols via destructuring
                    try self.emitOp(.op_pop, line);
                    try self.emitOp(.op_nil, line); // Yield nil for MVP
                }
            },
            .export_stmt => {
                // MVP: Yields nil. Real exporting requires writing to the VM's active export Map.
                try self.emitOp(.op_nil, line);
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
                    .current_chunk = child_chunk,
                    .vm = self.vm,
                    .enclosing = self,
                    .function = func,
                    .upvalue_count = 0,
                    .local_count = 0,
                    .current_stack_depth = 0,
                    .max_stack_depth = 0,
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

                try self.emitOp(.op_closure, line);
                try self.emitByte(func_idx, line);

                for (child_compiler.upvalues[0..child_compiler.upvalue_count]) |upv| {
                    try self.emitByte(if (upv.is_local) 1 else 0, line);
                    try self.emitByte(upv.index, line);
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

                        try self.emitOp(.op_define_global, line);
                        try self.emitByte(name_idx, line);
                        try self.emitOp(.op_nil, line); // Equilibrium: yield nil to the block
                    } else {
                        self.addLocal(def_name_id, @intCast(sym.index));
                        try self.emitOp(.op_set_local, line);
                        try self.emitByte(@intCast(sym.index), line);
                    }
                }
            },
            .index_access => {
                const ia = self.tree.indexAccess(node);
                try self.compileNode(ia.target);
                try self.compileNode(ia.index);
                try self.emitOp(.op_get_index, line);
            },
            .index_assignment => {
                const ia = self.tree.indexAssignment(node);

                try self.compileNode(ia.target);
                try self.compileNode(ia.index);

                if (ia.op) |op| {
                    // Double-evaluate target and index to fetch current value.
                    try self.compileNode(ia.target);
                    try self.compileNode(ia.index);
                    try self.emitOp(.op_get_index, line);

                    try self.compileNode(ia.value);

                    switch (op) {
                        .add => try self.emitOp(.op_add, line),
                        .subtract => try self.emitOp(.op_subtract, line),
                        .multiply => try self.emitOp(.op_multiply, line),
                        .divide => try self.emitOp(.op_divide, line),
                        else => return error.UnknownNode,
                    }
                } else {
                    try self.compileNode(ia.value);
                }

                try self.emitOp(.op_set_index, line);
            },
            .method_call => {
                const mc = self.tree.methodCall(node);
                const func_name = self.tree.getString(mc.method_name);

                // Intercept raise as a true language throw
                if (std.mem.eql(u8, func_name, "raise")) {
                    const args = self.tree.getNamedArgs(mc.args);
                    if (args.len > 0) {
                        try self.compileNode(args[0].value);
                    } else {
                        try self.emitOp(.op_nil, line);
                    }
                    try self.emitOp(.op_throw, line);
                    self.simulatePush(1); // Dead code equilibrium
                    return;
                }

                if (mc.receiver == .none) {
                    const name_val = try self.vm.allocateString(func_name);
                    self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                    self.vm.push(name_val);
                    const name_idx = try self.makeConstant(name_val);
                    _ = self.vm.pop();
                    try self.emitOp(.op_get_global, line);
                    try self.emitByte(name_idx, line);

                    const args = self.tree.getNamedArgs(mc.args);
                    for (args) |arg| try self.compileNode(arg.value);

                    if (args.len > MAX_ARGS) return error.TooManyConstants;
                    try self.emitOp(.op_call, line);
                    try self.emitByte(@intCast(args.len), line);
                    self.simulatePop(args.len + 1);
                    self.simulatePush(1);
                } else {
                    try self.compileNode(mc.receiver);

                    // If it is a safe call (&.), we inject a conditional jump over the arguments and invocation
                    var safe_jump: usize = 0;
                    if (mc.is_safe) {
                        safe_jump = try self.emitJump(.op_jump_if_nil, line);
                    }

                    const args = self.tree.getNamedArgs(mc.args);
                    for (args) |arg| try self.compileNode(arg.value);

                    const name_val = try self.vm.allocateString(func_name);
                    self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                    self.vm.push(name_val);
                    const name_idx = try self.makeConstant(name_val);
                    _ = self.vm.pop();

                    if (args.len > MAX_ARGS) return error.TooManyConstants;
                    try self.emitOp(.op_invoke, line);
                    try self.emitByte(name_idx, line);
                    try self.emitByte(@intCast(args.len), line);
                    self.simulatePop(args.len + 1);
                    self.simulatePush(1);

                    // Cap off the safe navigation jump here. The stack naturally maintains equilibrium!
                    if (mc.is_safe) {
                        self.patchJump(safe_jump);
                    }
                }
            },
            .binary_op => {
                const bin_expr = self.tree.binaryExpr(node);
                try self.compileNode(bin_expr.left);
                try self.compileNode(bin_expr.right);
                switch (bin_expr.op) {
                    .add => try self.emitOp(.op_add, line),
                    .subtract => try self.emitOp(.op_subtract, line),
                    .multiply => try self.emitOp(.op_multiply, line),
                    .divide => try self.emitOp(.op_divide, line),
                    .equal => try self.emitOp(.op_equal, line),
                    .less => try self.emitOp(.op_less, line),
                    .greater => try self.emitOp(.op_greater, line),
                    else => return error.UnknownNode,
                }
            },
            .unary_op => {
                const un_expr = self.tree.unaryExpr(node);
                try self.compileNode(un_expr.operand);
                switch (un_expr.op) {
                    .negate => try self.emitOp(.op_negate, line),
                    .not => try self.emitOp(.op_not, line),
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
                    try self.emitOp(.op_build_array, line);
                    try self.emitByte(@intCast(elements.len), line);
                    self.simulatePop(elements.len);
                    self.simulatePush(1);
                } else {
                    // Dynamic Build Mode
                    try self.emitOp(.op_build_array, line);
                    try self.emitByte(0, line); // Create empty array
                    self.simulatePush(1);

                    for (elements) |elem| {
                        const el_node = self.tree.getNode(elem).?;
                        if (el_node.tag == .splat_expr) {
                            try self.compileNode(self.tree.nodeIndex(el_node));
                            try self.emitOp(.op_array_spread, line);
                        } else {
                            try self.compileNode(elem);
                            try self.emitOp(.op_array_push, line);
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
                            try self.emitOp(.op_constant, line);
                            try self.emitByte(str_idx, line);
                        } else {
                            try self.compileNode(entry.key);
                        }
                        try self.compileNode(entry.value);
                    }
                    if (entries.len > 127) return error.TooManyConstants;
                    try self.emitOp(.op_build_map, line);
                    try self.emitByte(@intCast(entries.len), line);
                    self.simulatePop(entries.len * 2);
                    self.simulatePush(1);
                } else {
                    // Dynamic Build Mode
                    try self.emitOp(.op_build_map, line);
                    try self.emitByte(0, line);
                    self.simulatePush(1);

                    for (entries) |entry| {
                        const key_node = self.tree.getNode(entry.key).?;
                        if (key_node.tag == .double_splat_expr) {
                            try self.compileNode(self.tree.nodeIndex(key_node));
                            try self.emitOp(.op_map_spread, line);
                        } else {
                            if (key_node.tag == .identifier) {
                                const str_content = self.tree.getString(@as(ast.StringId, @enumFromInt(key_node.data)));
                                const str_val = try self.vm.allocateString(str_content);
                                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                                self.vm.push(str_val);
                                const str_idx = try self.makeConstant(str_val);
                                _ = self.vm.pop();
                                try self.emitOp(.op_constant, line);
                                try self.emitByte(str_idx, line);
                            } else {
                                try self.compileNode(entry.key);
                            }
                            try self.compileNode(entry.value);
                            try self.emitOp(.op_map_insert, line);
                        }
                    }
                }
            },
            .if_stmt => {
                const if_payload = self.tree.ifStmt(node);
                try self.compileNode(if_payload.condition);
                if (if_payload.is_unless) try self.emitOp(.op_not, line);

                const then_jump = try self.emitJump(.op_jump_if_false, line);
                try self.emitOp(.op_pop, line);

                try self.compileNode(if_payload.then_branch);
                const else_jump = try self.emitJump(.op_jump, line);

                self.patchJump(then_jump);
                try self.emitOp(.op_pop, line);

                if (if_payload.else_branch != .none) {
                    try self.compileNode(if_payload.else_branch);
                } else {
                    try self.emitOp(.op_nil, line);
                }
                self.patchJump(else_jump);
            },
            .self_expr => {
                // 'self' is intrinsically bound to local slot 0
                try self.emitOp(.op_get_local, line);
                try self.emitByte(0, line);
            },
            .while_stmt => {
                const while_payload = self.tree.whileStmt(node);
                const loop_start = self.current_chunk.code.items.len;

                // Push loop state
                if (self.loop_count >= 8) return error.UnknownNode;
                self.loops[self.loop_count] = .{ .start = loop_start, .exit_count = 0 };
                self.loop_count += 1;

                try self.compileNode(while_payload.condition);
                if (while_payload.is_until) try self.emitOp(.op_not, line);

                const exit_jump = try self.emitJump(.op_jump_if_false, line);
                try self.emitOp(.op_pop, line); // Clean up condition

                try self.compileNode(while_payload.body);
                try self.emitOp(.op_pop, line); // Pop the body's yielded result

                try self.emitLoop(loop_start, line);

                self.patchJump(exit_jump);
                self.simulatePush(1); // The condition that was bypassed
                try self.emitOp(.op_pop, line);
                try self.emitOp(.op_nil, line); // Natural exit yields nil

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

                const then_jump = try self.emitJump(.op_jump_if_false, line);
                try self.emitOp(.op_pop, line); // pop condition if true

                try self.compileNode(ternary.then_branch);
                const else_jump = try self.emitJump(.op_jump, line);

                self.patchJump(then_jump);
                try self.emitOp(.op_pop, line); // pop condition if false

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
                    try self.emitConstant(value.Value.initNumber(1.0), line); // Default step
                }

                try self.emitOp(.op_build_range, line);
                try self.emitByte(if (r.is_exclusive) 1 else 0, line);

                self.simulatePop(3); // Pops start, end, step
                self.simulatePush(1); // Pushes ObjRange
            },
            .interpolated_string => {
                const parts = self.tree.getNodes(self.tree.nodeSpan(node));
                for (parts) |part| {
                    try self.compileNode(part);
                }

                if (parts.len > 255) return error.TooManyConstants;

                try self.emitOp(.op_interpolate, line);
                try self.emitByte(@intCast(parts.len), line);

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

                // 1. Evaluate the right side (pushes an Array or Value)
                try self.compileNode(ma.value);

                if (lhs.len > 255) return error.TooManyConstants;

                // 2. Unpack the array into N stack slots
                try self.emitOp(.op_unpack, line);
                try self.emitByte(@intCast(lhs.len), line);
                self.simulatePush(lhs.len); // Tell the simulator we pushed N items

                // 3. Assign them in reverse order (top of stack is the last variable)
                var i: usize = lhs.len;
                while (i > 0) {
                    i -= 1;
                    const name_id = lhs[i].name;

                    if (self.resolveLocal(name_id)) |local_slot| {
                        try self.emitOp(.op_set_local, line);
                        try self.emitByte(local_slot, line);
                        try self.emitOp(.op_pop, line);
                    } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                        try self.emitOp(.op_set_upvalue, line);
                        try self.emitByte(upvalue_slot, line);
                        try self.emitOp(.op_pop, line);
                    } else {
                        const name_str = self.tree.getString(name_id);
                        const name_val = try self.vm.allocateString(name_str);
                        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                        self.vm.push(name_val);
                        const name_idx = try self.makeConstant(name_val);
                        _ = self.vm.pop();

                        if (self.enclosing == null) {
                            try self.emitOp(.op_define_global, line);
                            try self.emitByte(name_idx, line);
                        } else {
                            // Automatically hoist to a new local variable
                            self.addLocal(name_id, @intCast(self.local_count));
                            try self.emitOp(.op_set_local, line);
                            try self.emitByte(@intCast(self.local_count - 1), line);
                            try self.emitOp(.op_pop, line);
                        }
                    }
                }

                // Multiple assignments yield nil to maintain block equilibrium
                try self.emitOp(.op_nil, line);
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
                try self.emitOp(.op_class, line);
                try self.emitByte(name_idx, line);

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
                            .current_chunk = child_chunk,
                            .vm = self.vm,
                            .enclosing = self,
                            .function = func,
                            .upvalue_count = 0,
                            .local_count = 0,
                            .current_stack_depth = 0,
                            .max_stack_depth = 0,
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

                        try self.emitOp(.op_closure, line); // (+1)
                        try self.emitByte(func_idx, line);

                        for (child_compiler.upvalues[0..child_compiler.upvalue_count]) |upv| {
                            try self.emitByte(if (upv.is_local) 1 else 0, line);
                            try self.emitByte(upv.index, line);
                        }

                        try self.emitOp(.op_method, line); // (-1)
                        try self.emitByte(m_name_idx, line);
                    }
                }

                // 3. Define the Class variable
                const sym = self.symbols[@intFromEnum(node_idx)];
                if (sym.kind == .local) {
                    self.addLocal(name_id, @intCast(sym.index));
                    try self.emitOp(.op_set_local, line);
                    try self.emitByte(@intCast(sym.index), line);
                    // Equilibrium: Class remains on stack (+1)
                } else {
                    try self.emitOp(.op_define_global, line);
                    try self.emitByte(name_idx, line);
                    try self.emitOp(.op_nil, line);
                    // Equilibrium: Class popped, dummy nil pushed (+1)
                }
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
                    try self.emitOp(.op_invoke, line);
                    try self.emitByte(name_idx, line);
                    try self.emitByte(0, line); // 0 args

                    try self.compileNode(pa.value);

                    switch (op) {
                        .add => try self.emitOp(.op_add, line),
                        .subtract => try self.emitOp(.op_subtract, line),
                        .multiply => try self.emitOp(.op_multiply, line),
                        .divide => try self.emitOp(.op_divide, line),
                        else => return error.UnknownNode,
                    }
                } else {
                    try self.compileNode(pa.value);
                }

                try self.emitOp(.op_set_property, line);
                try self.emitByte(name_idx, line);
            },
            .block => {
                const block_payload = self.tree.block(node);
                const stmts = self.tree.getNodes(block_payload.stmts);

                if (stmts.len == 0) {
                    try self.emitOp(.op_nil, line);
                } else {
                    for (stmts, 0..) |stmt_idx, i| {
                        try self.compileNode(stmt_idx);
                        if (i < stmts.len - 1) {
                            try self.emitOp(.op_pop, line);
                        }
                    }
                }
            },
            else => {
                try self.emitOp(.op_nil, line); // Push dummy value for unknown AST nodes
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

    fn emitByte(self: *Compiler, byte: u8, line: u32) CompileError!void {
        self.current_chunk.write(self.allocator, byte, line) catch return error.OutOfMemory;
    }

    fn emitOp(self: *Compiler, op: chunk.OpCode, line: u32) CompileError!void {
        try self.emitByte(@intFromEnum(op), line);
        switch (op) {
            .op_nil, .op_true, .op_false, .op_get_local, .op_get_global, .op_constant, .op_closure, .op_get_upvalue, .op_dup, .op_import => self.simulatePush(1),
            .op_pop, .op_return, .op_close_upvalue, .op_pop_rescue, .op_throw, .op_array_push, .op_array_spread => self.simulatePop(1),
            .op_map_insert, .op_map_spread => self.simulatePop(2),
            .op_is_instance, .op_add, .op_subtract, .op_multiply, .op_divide, .op_equal, .op_less, .op_greater => {
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

    fn emitConstant(self: *Compiler, val: value.Value, line: u32) CompileError!void {
        const index = try self.makeConstant(val);
        try self.emitOp(.op_constant, line);
        try self.emitByte(index, line);
    }

    fn emitJump(self: *Compiler, op: chunk.OpCode, line: u32) CompileError!usize {
        try self.emitOp(op, line);
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
        return self.current_chunk.code.items.len - 2;
    }

    fn patchJump(self: *Compiler, offset: usize) void {
        const jump = self.current_chunk.code.items.len - offset - 2;
        std.debug.assert(jump <= std.math.maxInt(u16));
        self.current_chunk.code.items[offset] = @intCast((jump >> 8) & 0xff);
        self.current_chunk.code.items[offset + 1] = @intCast(jump & 0xff);
    }

    fn emitLoop(self: *Compiler, loop_start: usize, line: u32) CompileError!void {
        try self.emitOp(.op_loop, line);
        const jump = self.current_chunk.code.items.len - loop_start + 2;
        std.debug.assert(jump <= std.math.maxInt(u16));
        try self.emitByte(@intCast((jump >> 8) & 0xff), line);
        try self.emitByte(@intCast(jump & 0xff), line);
    }
};
