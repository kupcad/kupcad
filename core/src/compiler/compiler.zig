const std = @import("std");
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");

pub const CompileError = error{
    OutOfMemory,
    UnknownNode,
    TooManyConstants,
};

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,
    current_chunk: *chunk.Chunk,

    pub fn init(allocator: std.mem.Allocator, tree: *const ast.Tree, output_chunk: *chunk.Chunk) Compiler {
        return .{
            .allocator = allocator,
            .tree = tree,
            .current_chunk = output_chunk,
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
        const line: u32 = 1;

        switch (node.tag) {
            .number => {
                const val = self.tree.number(node);
                try self.emitConstant(value.Value.initNumber(val), line);
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

    fn emitConstant(self: *Compiler, val: value.Value, line: u32) CompileError!void {
        const index = self.current_chunk.addConstant(self.allocator, val) catch return error.OutOfMemory;
        if (index > 255) return error.TooManyConstants;

        try self.emitOp(.op_constant, line);
        try self.emitByte(index, line);
    }
};
