const std = @import("std");
const chunk = @import("chunk.zig");
const memory = @import("memory.zig");
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

/// A mock implementation of OpenSCAD's cube()
fn nativeCube(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const self: *VM = @ptrCast(@alignCast(vm_opaque));

    // In a real engine, we'd extract arguments and pass them to a C/C++ CAD Kernel here.
    // For now, we simulate allocating a 3D Mesh object (e.g., a cube has 8 vertices, 12 faces).
    return self.allocateMesh(null, 8, 12);
}

pub const VM = struct {
    allocator: std.mem.Allocator,

    // Dynamic Shadow Stack (WASM-safe, growable, index-addressed)
    stack: []value.Value,
    stack_top: usize,

    // Call Stack
    frames: std.ArrayListUnmanaged(CallFrame),
    // memory GC
    gc: memory.GC,
    // Global variables and built-in function registry
    globals: std.StringHashMapUnmanaged(value.Value),

    const INITIAL_STACK_CAPACITY: usize = 1024;

    pub fn init(allocator: std.mem.Allocator) !VM {
        const initial_stack = try allocator.alloc(value.Value, INITIAL_STACK_CAPACITY);
        var self = VM{
            .allocator = allocator,
            .stack = initial_stack,
            .stack_top = 0,
            .frames = .empty,
            .gc = memory.GC.init(allocator),
            .globals = .empty,
        };

        // Register built-in native functions
        try self.defineNative("cube", nativeCube);

        return self;
    }

    pub fn deinit(self: *VM) void {
        self.gc.collectGarbage(self, true);
        self.allocator.free(self.stack);
        self.globals.deinit(self.allocator);
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
        while (true) {
            var frame = &self.frames.items[self.frames.items.len - 1];
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

                .op_get_global => {
                    const name_idx = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const name_val = frame.chunk.constants.items[name_idx];
                    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", name_val.asObj()));

                    if (self.globals.get(str_obj.chars)) |val| {
                        self.push(val) catch return .runtime_error;
                    } else {
                        std.debug.print("Runtime Error: Undefined variable '{s}'\n", .{str_obj.chars});
                        return .runtime_error;
                    }
                },
                .op_call => {
                    const arg_count = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const callee = self.stack[self.stack_top - 1 - arg_count];
                    if (callee.isNative()) {
                        const native_obj = callee.asNative();
                        const args_ptr = self.stack.ptr + self.stack_top - arg_count;

                        // Execute the Zig/C function natively
                        const result = native_obj.function(self, arg_count, args_ptr) catch return .runtime_error;

                        // Pop arguments and callee off the stack, push the result
                        self.stack_top -= arg_count + 1;
                        self.push(result) catch return .runtime_error;
                    } else {
                        std.debug.print("Runtime Error: Can only call functions and classes.\n", .{});
                        return .runtime_error;
                    }
                },

                else => {
                    std.debug.print("Runtime Error: Unhandled OpCode {}\n", .{op});
                    return .runtime_error;
                },
            }
        }
    }

    /// Safely allocates a string and pushes it to the stack.
    /// Triggers GC automatically if memory pressure is high.
    pub fn allocateString(self: *VM, chars: []const u8) !value.Value {
        if (self.gc.bytes_allocated > self.gc.next_gc_threshold) {
            self.gc.collectGarbage(self, false);
        }

        const str_obj = try self.gc.allocateString(chars);
        return value.Value.initObj(&str_obj.obj);
    }

    /// Safely allocates a CAD Mesh and pushes it to the stack.
    /// Triggers GC automatically if memory pressure is high.
    pub fn allocateMesh(self: *VM, handle: ?*anyopaque, v_count: usize, f_count: usize) !value.Value {
        if (self.gc.bytes_allocated > self.gc.next_gc_threshold) {
            self.gc.collectGarbage(self, false);
        }
        const mesh_obj = try self.gc.allocateMesh(handle, v_count, f_count);
        return value.Value.initObj(&mesh_obj.obj);
    }

    /// Registers a native Zig/C function into the VM's global environment
    pub fn defineNative(self: *VM, name: []const u8, function: value.NativeFn) !void {
        // Wrap the Zig function in a GC-managed object
        const native_obj = try self.gc.allocateNative(function);
        const native_val = value.Value.initObj(&native_obj.obj);

        // Push to stack temporarily to protect from GC during map allocation
        try self.push(native_val);

        // Insert into the global symbol table
        try self.globals.put(self.allocator, name, native_val);

        // Pop the temporary protection
        _ = self.pop();
    }
};
