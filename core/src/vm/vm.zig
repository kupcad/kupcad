const std = @import("std");
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

/// CallFrame tracks function call boundaries using stack slot OFFSETS (not pointers),
/// allowing the underlying stack array to grow/reallocate safely.
pub const CallFrame = struct {
    chunk: *chunk.Chunk,
    ip: usize,
    base_slot: usize, // Stack offset where this frame's local variables start
};

pub const VM = struct {
    allocator: std.mem.Allocator,

    // Dynamic Shadow Stack (WASM-safe, growable, index-addressed)
    stack: []value.Value,
    stack_top: usize,

    // Call Stack
    frames: std.ArrayListUnmanaged(CallFrame),

    const INITIAL_STACK_CAPACITY: usize = 1024;

    pub fn init(allocator: std.mem.Allocator) !VM {
        const initial_stack = try allocator.alloc(value.Value, INITIAL_STACK_CAPACITY);
        return .{
            .allocator = allocator,
            .stack = initial_stack,
            .stack_top = 0,
            .frames = .empty,
        };
    }

    pub fn deinit(self: *VM) void {
        self.allocator.free(self.stack);
        self.frames.deinit(self.allocator);
    }

    // --- Dynamic Stack Operations ---

    /// Pushes a value to the stack. Automatically grows memory if capacity is reached.
    pub inline fn push(self: *VM, val: value.Value) !void {
        if (self.stack_top >= self.stack.len) {
            try self.growStack();
        }
        self.stack[self.stack_top] = val;
        self.stack_top += 1;
    }

    /// Pops a value from the stack.
    pub inline fn pop(self: *VM) value.Value {
        std.debug.assert(self.stack_top > 0);
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    /// Accesses a local variable relative to the active call frame's base slot.
    pub inline fn getLocal(self: *VM, frame: *const CallFrame, slot_index: usize) value.Value {
        const absolute_slot = frame.base_slot + slot_index;
        std.debug.assert(absolute_slot < self.stack_top);
        return self.stack[absolute_slot];
    }

    /// Sets a local variable relative to the active call frame's base slot.
    pub inline fn setLocal(self: *VM, frame: *const CallFrame, slot_index: usize, val: value.Value) void {
        const absolute_slot = frame.base_slot + slot_index;
        std.debug.assert(absolute_slot < self.stack_top);
        self.stack[absolute_slot] = val;
    }

    /// Doubles the stack memory buffer. Safe across all targets (WASM, CLI, Lib).
    fn growStack(self: *VM) !void {
        const new_capacity = self.stack.len * 2;
        self.stack = try self.allocator.realloc(self.stack, new_capacity);
    }

    // --- Execution Core ---

    pub fn interpret(self: *VM, execution_chunk: *chunk.Chunk) InterpretResult {
        // Clear frame stack for a fresh run
        self.frames.clearRetainingCapacity();
        self.stack_top = 0;

        // Push top-level script frame (starts at base_slot 0)
        self.frames.append(self.allocator, .{
            .chunk = execution_chunk,
            .ip = 0,
            .base_slot = 0,
        }) catch return .runtime_error;

        return self.run();
    }

    fn run(self: *VM) InterpretResult {
        var frame = &self.frames.items[self.frames.items.len - 1];

        while (true) {
            const instruction = frame.chunk.code.items[frame.ip];
            frame.ip += 1;
            const op: chunk.OpCode = @enumFromInt(instruction);

            switch (op) {
                .op_constant => {
                    const const_idx = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const constant = frame.chunk.constants.items[const_idx];
                    self.push(constant) catch return .runtime_error;
                },
                .op_nil => self.push(value.Value.initNil()) catch return .runtime_error,
                .op_true => self.push(value.Value.initBool(true)) catch return .runtime_error,
                .op_false => self.push(value.Value.initBool(false)) catch return .runtime_error,
                .op_pop => _ = self.pop(),

                // Local Variable Ops (Relocation-Safe)
                .op_get_local => {
                    const slot = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.push(self.getLocal(frame, slot)) catch return .runtime_error;
                },
                .op_set_local => {
                    const slot = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;
                    // Peek top of stack and assign to slot
                    self.setLocal(frame, slot, self.stack[self.stack_top - 1]);
                },

                // Math Operations
                .op_add => {
                    const b = self.pop().asNumber();
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(a + b)) catch return .runtime_error;
                },
                .op_subtract => {
                    const b = self.pop().asNumber();
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(a - b)) catch return .runtime_error;
                },
                .op_multiply => {
                    const b = self.pop().asNumber();
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(a * b)) catch return .runtime_error;
                },
                .op_divide => {
                    const b = self.pop().asNumber();
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(a / b)) catch return .runtime_error;
                },
                .op_negate => {
                    const a = self.pop().asNumber();
                    self.push(value.Value.initNumber(-a)) catch return .runtime_error;
                },

                .op_return => return .ok,

                else => {
                    std.debug.print("Runtime Error: Unhandled OpCode {}\n", .{op});
                    return .runtime_error;
                },
            }
        }
    }
};
