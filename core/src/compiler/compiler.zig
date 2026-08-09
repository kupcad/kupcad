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
        };
    }

    /// Entry point for compiling a KupCad AST root node.
    pub fn compile(self: *Compiler, root: ast.NodeIndex) CompileError!void {
        try self.compileNode(root);

        // Every chunk cleanly returns
        try self.emitOp(.op_nil, 0);
        try self.emitOp(.op_return, 0);
    }

    /// Recursively walks the Data-Oriented AST and emits bytecode.
    fn compileNode(self: *Compiler, node_idx: ast.NodeIndex) CompileError!void {
        if (node_idx == .none) return;
        const node = self.tree.getNode(node_idx) orelse return error.UnknownNode;
        const line: u32 = 1; // Simplification: in a real implementation, map node_idx to line_index

        switch (node.tag) {
            .number => {
                const val = self.tree.number(node);
                try self.emitConstant(value.Value.initNumber(val), line);
            },
            .identifier => {
                const sym = self.symbols[@intFromEnum(node_idx)];
                switch (sym.kind) {
                    .local => {
                        if (sym.index > 255) return error.TooManyLocals;
                        try self.emitOp(.op_get_local, line);
                        try self.emitByte(@intCast(sym.index), line);
                    },
                    .global => {
                        // 1. Get the raw string from the AST
                        const name = self.tree.getString(@as(ast.StringId, @enumFromInt(node.data)));
                        // 2. Allocate a managed string object in the VM
                        const name_val = try self.vm.allocateString(name);
                        // 3. Protect it from the GC while we add it to the chunk
                        try self.vm.push(name_val);
                        const name_idx = try self.makeConstant(name_val);
                        _ = self.vm.pop();

                        // 4. Emit the global lookup opcode
                        try self.emitOp(.op_get_global, line);
                        try self.emitByte(name_idx, line);
                    },
                    else => return error.UnsupportedScope,
                }
            },
            .method_call => {
                const mc = self.tree.methodCall(node);

                // 1. Resolve the Callee
                if (mc.receiver == .none) {
                    // Global function call (e.g., `cube()`)
                    const func_name = self.tree.getString(mc.method_name);
                    const name_val = try self.vm.allocateString(func_name);

                    try self.vm.push(name_val); // GC protection
                    const name_idx = try self.makeConstant(name_val);
                    _ = self.vm.pop();

                    try self.emitOp(.op_get_global, line);
                    try self.emitByte(name_idx, line);
                } else {
                    // Method call on an object (e.g., `box.translate()`) - to be implemented
                    return error.UnsupportedScope;
                }

                // 2. Compile Arguments
                const args = self.tree.getNamedArgs(mc.args);
                for (args) |arg| {
                    try self.compileNode(arg.value);
                }

                // 3. Emit Call Instruction
                if (args.len > 255) return error.TooManyConstants;
                try self.emitOp(.op_call, line);
                try self.emitByte(@intCast(args.len), line);
            },
            .assignment => {
                const assign_payload = self.tree.assignment(node);
                // Compile the Right-Hand Side (leaves value on top of stack)
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
    fn emitByte(self: *Compiler, byte: u8, line: u32) CompileError!void {
        self.current_chunk.write(self.allocator, byte, line) catch return error.OutOfMemory;
    }

    fn emitOp(self: *Compiler, op: chunk.OpCode, line: u32) CompileError!void {
        try self.emitByte(@intFromEnum(op), line);
    }

    /// Adds a constant to the chunk and returns its index
    fn makeConstant(self: *Compiler, val: value.Value) CompileError!u8 {
        const index = self.current_chunk.addConstant(self.allocator, val) catch return error.OutOfMemory;
        if (index > 255) return error.TooManyConstants;
        return @intCast(index);
    }

    /// Adds a constant and emits the op_constant instruction
    fn emitConstant(self: *Compiler, val: value.Value, line: u32) CompileError!void {
        const index = try self.makeConstant(val);
        try self.emitOp(.op_constant, line);
        try self.emitByte(index, line);
    }
};
