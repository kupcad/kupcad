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
        try self.compileNode(root);

        // Every chunk cleanly returns
        try self.emitOp(.op_nil, 0);
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
            .block => {
                const block_payload = self.tree.block(node);
                const stmts = self.tree.getNodes(block_payload.stmts);
                for (stmts) |stmt_idx| {
                    try self.compileNode(stmt_idx);
                    try self.emitOp(.op_pop, line);
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
};
