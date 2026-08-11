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

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,
    symbols: []const resolver.ResolvedSymbol,
    current_chunk: *chunk.Chunk,
    vm: *VM,

    // Simulator State
    current_stack_depth: usize,
    max_stack_depth: usize,

    // --- Bytecode Limitations ---
    pub const MAX_LOCALS = std.math.maxInt(u8); // 255
    pub const MAX_CONSTANTS = std.math.maxInt(u8); // 255
    pub const MAX_ARGS = std.math.maxInt(u8); // 255

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
            .current_stack_depth = 0,
            .max_stack_depth = 0,
        };
    }

    pub fn compile(self: *Compiler, root: ast.NodeIndex) CompileError!void {
        if (root == .none) {
            try self.emitOp(.op_nil, 0);
        } else {
            try self.compileNode(root);
        }

        // Every chunk cleanly returns the result of the final expression
        try self.emitOp(.op_return, 0);

        // Commit the maximum required stack size to the chunk!
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
                // Get the raw string text from the AST
                const str_content = self.tree.getString(@as(ast.StringId, @enumFromInt(node.data)));

                // Allocate an ObjString on the VM heap
                const str_val = try self.vm.allocateString(str_content);

                // Temporarily push to stack to prevent GC during constant creation
                self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                self.vm.push(str_val);
                const str_idx = try self.makeConstant(str_val);
                _ = self.vm.pop();

                // Emit the bytecode instruction
                try self.emitOp(.op_constant, line);
                try self.emitByte(str_idx, line);
            },
            .identifier => {
                const sym = self.symbols[@intFromEnum(node_idx)];
                switch (sym.kind) {
                    .local => {
                        if (sym.index > MAX_LOCALS) return error.TooManyLocals;
                        try self.emitOp(.op_get_local, line);
                        try self.emitByte(@intCast(sym.index), line);
                    },
                    .global => {
                        const name = self.tree.getString(@as(ast.StringId, @enumFromInt(node.data)));
                        const name_val = try self.vm.allocateString(name);

                        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                        self.vm.push(name_val);
                        const name_idx = try self.makeConstant(name_val);
                        _ = self.vm.pop();

                        try self.emitOp(.op_get_global, line);
                        try self.emitByte(name_idx, line);
                    },
                    else => return error.UnsupportedScope,
                }
            },
            .method_call => {
                const mc = self.tree.methodCall(node);
                const func_name = self.tree.getString(mc.method_name);

                if (mc.receiver == .none) {
                    // Global function call (e.g., `cube()`)
                    const name_val = try self.vm.allocateString(func_name);

                    self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                    self.vm.push(name_val);
                    const name_idx = try self.makeConstant(name_val);
                    _ = self.vm.pop();

                    try self.emitOp(.op_get_global, line);
                    try self.emitByte(name_idx, line);

                    const args = self.tree.getNamedArgs(mc.args);
                    for (args) |arg| {
                        try self.compileNode(arg.value);
                    }

                    if (args.len > MAX_ARGS) return error.TooManyConstants;
                    try self.emitOp(.op_call, line);
                    try self.emitByte(@intCast(args.len), line);

                    // Manual adjustment: call drops arguments and callee, pushes result
                    self.simulatePop(args.len + 1);
                    self.simulatePush(1);
                } else {
                    // Method call on an object (e.g., `box.translate()`)

                    //  Compile the receiver (leaves the object on the stack)
                    try self.compileNode(mc.receiver);

                    // Compile the arguments (leaves them on the stack)
                    const args = self.tree.getNamedArgs(mc.args);
                    for (args) |arg| {
                        try self.compileNode(arg.value);
                    }

                    // Setup the method name constant
                    const name_val = try self.vm.allocateString(func_name);
                    self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                    self.vm.push(name_val);
                    const name_idx = try self.makeConstant(name_val);
                    _ = self.vm.pop();

                    // 4. Emit the Invoke Instruction
                    if (args.len > MAX_ARGS) return error.TooManyConstants;
                    try self.emitOp(.op_invoke, line);
                    try self.emitByte(name_idx, line);
                    try self.emitByte(@intCast(args.len), line);

                    // Simulator: drops arguments and receiver, pushes the mutated result
                    self.simulatePop(args.len + 1);
                    self.simulatePush(1);
                }
            },
            .assignment => {
                const assign_payload = self.tree.assignment(node);
                try self.compileNode(assign_payload.value);

                const sym = self.symbols[@intFromEnum(node_idx)];
                switch (sym.kind) {
                    .local => {
                        try self.emitOp(.op_set_local, line);
                        try self.emitByte(@intCast(sym.index), line);
                    },
                    .global => {
                        return error.UnsupportedScope;
                    },
                    else => return error.UnsupportedScope,
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
                for (elements) |elem| {
                    try self.compileNode(elem);
                }
                if (elements.len > MAX_ARGS) return error.TooManyConstants;
                try self.emitOp(.op_build_array, line);
                try self.emitByte(@intCast(elements.len), line);
                // Simulator: pop all N elements, push 1 Array object
                self.simulatePop(elements.len);
                self.simulatePush(1);
            },
            .hash_literal => {
                const entries = self.tree.getHashEntries(self.tree.nodeSpan(node));
                for (entries) |entry| {
                    const key_node = self.tree.getNode(entry.key).?;
                    // Automatically compile literal symbol keys into strings
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
                if (entries.len > 127) return error.TooManyConstants; // 127 pairs = 254 stack slots
                try self.emitOp(.op_build_map, line);
                try self.emitByte(@intCast(entries.len), line);
                // Simulator: pop N*2 elements, push 1 Map object
                self.simulatePop(entries.len * 2);
                self.simulatePush(1);
            },
            .if_stmt => {
                const if_payload = self.tree.ifStmt(node);
                try self.compileNode(if_payload.condition);

                // `unless` reverses the logic jump
                if (if_payload.is_unless) {
                    try self.emitOp(.op_not, line);
                }

                const then_jump = try self.emitJump(.op_jump_if_false, line);
                try self.emitOp(.op_pop, line); // Clean up the condition

                try self.compileNode(if_payload.then_branch);

                const else_jump = try self.emitJump(.op_jump, line);

                self.patchJump(then_jump);
                try self.emitOp(.op_pop, line); // Clean up condition for skipped branch

                if (if_payload.else_branch != .none) {
                    try self.compileNode(if_payload.else_branch);
                } else {
                    try self.emitOp(.op_nil, line); // If-expressions yield nil implicitly
                }

                self.patchJump(else_jump);
            },
            .while_stmt => {
                const while_payload = self.tree.whileStmt(node);
                const loop_start = self.current_chunk.code.items.len;

                try self.compileNode(while_payload.condition);

                // `until` loops run while the condition is false
                if (while_payload.is_until) {
                    try self.emitOp(.op_not, line);
                }

                const exit_jump = try self.emitJump(.op_jump_if_false, line);
                try self.emitOp(.op_pop, line); // Clean up condition

                try self.compileNode(while_payload.body);
                try self.emitOp(.op_pop, line); // Pop the body's yielded result

                try self.emitLoop(loop_start, line);

                self.patchJump(exit_jump);
                try self.emitOp(.op_pop, line);
                try self.emitOp(.op_nil, line); // While-expressions yield nil
            },
            .block => {
                const block_payload = self.tree.block(node);
                const stmts = self.tree.getNodes(block_payload.stmts);

                if (stmts.len == 0) {
                    try self.emitOp(.op_nil, line);
                } else {
                    for (stmts, 0..) |stmt_idx, i| {
                        try self.compileNode(stmt_idx);
                        // Pop all statements EXCEPT the last one, so the block yields a value
                        if (i < stmts.len - 1) {
                            try self.emitOp(.op_pop, line);
                        }
                    }
                }
            },
            else => {},
        }
    }

    // --- Helpers ---
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
            .op_nil, .op_true, .op_false, .op_get_local, .op_get_global, .op_constant => {
                self.simulatePush(1);
            },
            .op_pop => self.simulatePop(1),
            .op_add, .op_subtract, .op_multiply, .op_divide, .op_equal, .op_less, .op_greater => {
                self.simulatePop(2);
                self.simulatePush(1);
            },
            .op_negate, .op_not => {
                self.simulatePop(1);
                self.simulatePush(1);
            },
            .op_return => self.simulatePop(1),
            else => {}, // op_call is variable, handled manually!
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
        // We use 0xFF as a 16-bit dummy placeholder
        try self.emitByte(0xff, line);
        try self.emitByte(0xff, line);
        return self.current_chunk.code.items.len - 2;
    }

    fn patchJump(self: *Compiler, offset: usize) void {
        // Calculate jump distance (minus 2 bytes for the jump operand itself)
        const jump = self.current_chunk.code.items.len - offset - 2;
        std.debug.assert(jump <= std.math.maxInt(u16)); // Max jump limit

        self.current_chunk.code.items[offset] = @intCast((jump >> 8) & 0xff);
        self.current_chunk.code.items[offset + 1] = @intCast(jump & 0xff);
    }

    fn emitLoop(self: *Compiler, loop_start: usize, line: u32) CompileError!void {
        try self.emitOp(.op_loop, line);
        // Calculate backward jump distance (+2 to account for the operand)
        const jump = self.current_chunk.code.items.len - loop_start + 2;
        std.debug.assert(jump <= std.math.maxInt(u16));

        try self.emitByte(@intCast((jump >> 8) & 0xff), line);
        try self.emitByte(@intCast(jump & 0xff), line);
    }
};
