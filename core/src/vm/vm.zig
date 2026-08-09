const std = @import("std");
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

pub const VM = struct {
    current_chunk: *chunk.Chunk,
    ip: usize, // Instruction Pointer (index into the chunk's code array)

    stack: [256]value.Value,
    stack_top: usize,

    pub fn init() VM {
        return .{
            .current_chunk = undefined,
            .ip = 0,
            .stack = undefined,
            .stack_top = 0,
        };
    }

    pub fn interpret(self: *VM, execution_chunk: *chunk.Chunk) InterpretResult {
        self.current_chunk = execution_chunk;
        self.ip = 0;
        self.stack_top = 0;
        return self.run();
    }

    // --- Stack Manipulation ---

    inline fn push(self: *VM, val: value.Value) void {
        std.debug.assert(self.stack_top < 256); // Prevent stack overflow
        self.stack[self.stack_top] = val;
        self.stack_top += 1;
    }

    inline fn pop(self: *VM) value.Value {
        std.debug.assert(self.stack_top > 0); // Prevent stack underflow
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    // --- Execution Loop ---

    inline fn readByte(self: *VM) u8 {
        const byte = self.current_chunk.code.items[self.ip];
        self.ip += 1;
        return byte;
    }

    inline fn readConstant(self: *VM) value.Value {
        const index = self.readByte();
        return self.current_chunk.constants.items[index];
    }

    fn run(self: *VM) InterpretResult {
        while (true) {
            const instruction = self.readByte();
            const op: chunk.OpCode = @enumFromInt(instruction);

            switch (op) {
                .op_constant => {
                    const constant = self.readConstant();
                    self.push(constant);
                },
                .op_nil => self.push(value.Value.initNil()),
                .op_true => self.push(value.Value.initBool(true)),
                .op_false => self.push(value.Value.initBool(false)),
                .op_pop => _ = self.pop(),

                // Math Operations
                .op_add => {
                    const b = self.pop().asNumber();
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(a + b));
                },
                .op_subtract => {
                    const b = self.pop().asNumber();
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(a - b));
                },
                .op_multiply => {
                    const b = self.pop().asNumber();
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(a * b));
                },
                .op_divide => {
                    const b = self.pop().asNumber();
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(a / b));
                },
                .op_negate => {
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(-a));
                },

                .op_return => {
                    // For now, simply exit successfully
                    return .ok;
                },

                // Fallback for unimplemented operations
                else => {
                    std.debug.print("Runtime Error: Unknown OpCode {}\n", .{op});
                    return .runtime_error;
                },
            }
        }
    }
};
