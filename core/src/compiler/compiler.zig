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
            .assignment => {
                const assign_payload = self.tree.assignment(node);
                try self.compileNode(assign_payload.value);

                const sym = self.symbols[@intFromEnum(node_idx)];
                const name_id = assign_payload.name;

                if (sym.kind == .global) return error.UnsupportedScope;

                if (self.resolveLocal(name_id)) |local_slot| {
                    try self.emitOp(.op_set_local, line);
                    try self.emitByte(local_slot, line);
                } else if (try self.resolveUpvalue(name_id)) |upvalue_slot| {
                    try self.emitOp(.op_set_upvalue, line);
                    try self.emitByte(upvalue_slot, line);
                } else {
                    // The current scope asserts ownership of this variable!
                    self.addLocal(name_id, @intCast(sym.index));
                    try self.emitOp(.op_set_local, line);
                    try self.emitByte(@intCast(sym.index), line);
                }
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

                // Assign the parameters their starting stack slots
                for (params, 0..) |param, i| {
                    child_compiler.addLocal(param.name, @intCast(i));
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

                if (node.tag == .def_stmt) {
                    const sym = self.symbols[@intFromEnum(node_idx)];
                    self.addLocal(def_name_id, @intCast(sym.index));
                    try self.emitOp(.op_set_local, line);
                    try self.emitByte(@intCast(sym.index), line);
                } else {
                    self.simulatePush(1);
                }
            },
            .method_call => {
                const mc = self.tree.methodCall(node);
                const func_name = self.tree.getString(mc.method_name);

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
                for (elements) |elem| try self.compileNode(elem);
                if (elements.len > MAX_ARGS) return error.TooManyConstants;
                try self.emitOp(.op_build_array, line);
                try self.emitByte(@intCast(elements.len), line);
                self.simulatePop(elements.len);
                self.simulatePush(1);
            },
            .hash_literal => {
                const entries = self.tree.getHashEntries(self.tree.nodeSpan(node));
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
            .while_stmt => {
                const while_payload = self.tree.whileStmt(node);
                const loop_start = self.current_chunk.code.items.len;

                try self.compileNode(while_payload.condition);
                if (while_payload.is_until) try self.emitOp(.op_not, line);

                const exit_jump = try self.emitJump(.op_jump_if_false, line);
                try self.emitOp(.op_pop, line);

                try self.compileNode(while_payload.body);
                try self.emitOp(.op_pop, line);

                try self.emitLoop(loop_start, line);
                self.patchJump(exit_jump);
                try self.emitOp(.op_pop, line);
                try self.emitOp(.op_nil, line);
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
            else => {},
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
            .op_nil, .op_true, .op_false, .op_get_local, .op_get_global, .op_constant, .op_closure, .op_get_upvalue => self.simulatePush(1),
            .op_pop, .op_return, .op_close_upvalue => self.simulatePop(1),
            .op_add, .op_subtract, .op_multiply, .op_divide, .op_equal, .op_less, .op_greater => {
                self.simulatePop(2);
                self.simulatePush(1);
            },
            .op_negate, .op_not => {
                self.simulatePop(1);
                self.simulatePush(1);
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
