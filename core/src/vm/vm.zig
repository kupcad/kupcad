const std = @import("std");
const chunk = @import("chunk.zig");
const memory = @import("memory.zig");
const value = @import("../core/value.zig");

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

pub const CallFrame = struct {
    chunk: *chunk.Chunk,
    ip: usize,
    base_slot: usize,
};

pub const VM = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    stack: []value.Value,
    stack_top: usize,
    frames: std.ArrayListUnmanaged(CallFrame),
    gc: memory.GC,
    globals: std.StringHashMapUnmanaged(value.Value),
    binary_handler: ?*const fn (vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value = null,

    const INITIAL_STACK_CAPACITY: usize = 1024;

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !VM {
        const initial_stack = try allocator.alloc(value.Value, INITIAL_STACK_CAPACITY);
        return .{
            .allocator = allocator,
            .io = io,
            .cwd = std.Io.Dir.cwd(),
            .stack = initial_stack,
            .stack_top = 0,
            .frames = .empty,
            .gc = memory.GC.init(allocator),
            .globals = .empty,
        };
    }

    pub fn deinit(self: *VM) void {
        self.gc.collectGarbage(self, true);
        self.allocator.free(self.stack);
        self.globals.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    // --- Dynamic Stack Operations ---

    /// Fast, unchecked push. Caller MUST ensure capacity beforehand!
    pub inline fn push(self: *VM, val: value.Value) void {
        std.debug.assert(self.stack_top < self.stack.len);
        self.stack.ptr[self.stack_top] = val;
        self.stack_top += 1;
    }

    pub inline fn pop(self: *VM) value.Value {
        std.debug.assert(self.stack_top > 0);
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    pub inline fn getLocal(self: *VM, frame: *const CallFrame, slot_index: usize) value.Value {
        const absolute_slot = frame.base_slot + slot_index;
        std.debug.assert(absolute_slot < self.stack_top);
        return self.stack[absolute_slot];
    }

    pub inline fn setLocal(self: *VM, frame: *const CallFrame, slot_index: usize, val: value.Value) void {
        const absolute_slot = frame.base_slot + slot_index;
        std.debug.assert(absolute_slot < self.stack_top);
        self.stack[absolute_slot] = val;
    }

    /// Pre-allocates space on the stack buffer for the requested total capacity.
    pub fn ensureStackCapacity(self: *VM, required_capacity: usize) !void {
        if (required_capacity <= self.stack.len) return;
        var new_capacity = self.stack.len;
        while (new_capacity < required_capacity) {
            new_capacity *= 2;
        }
        self.stack = try self.allocator.realloc(self.stack, new_capacity);
    }

    // --- Execution Core ---

    pub fn interpret(self: *VM, execution_chunk: *chunk.Chunk) InterpretResult {
        self.frames.clearRetainingCapacity();
        self.stack_top = 0;

        // One-time pre-allocation for the entire script's maximum requirements!
        self.ensureStackCapacity(execution_chunk.max_stack_slots) catch return .runtime_error;

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
                    self.push(constant);
                },
                .op_nil => self.push(value.Value.initNil()),
                .op_true => self.push(value.Value.initBool(true)),
                .op_false => self.push(value.Value.initBool(false)),
                .op_pop => _ = self.pop(),
                .op_get_local => {
                    const slot = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.push(self.getLocal(frame, slot));
                },
                .op_set_local => {
                    const slot = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.setLocal(frame, slot, self.stack[self.stack_top - 1]);
                },
                .op_add => {
                    const b_val = self.pop();
                    const a_val = self.pop();
                    if (a_val.isNumber() and b_val.isNumber()) {
                        self.push(value.Value.initNumber(a_val.asNumber() + b_val.asNumber()));
                    } else if (self.binary_handler) |handler| {
                        // Delegate to the Standard Library!
                        const result = handler(self, .op_add, a_val, b_val) catch return .runtime_error;
                        self.push(result);
                    } else {
                        std.log.err("Runtime Error: Invalid operands for '+'\n", .{});
                        return .runtime_error;
                    }
                },
                .op_subtract => {
                    const b_val = self.pop();
                    const a_val = self.pop();
                    if (a_val.isNumber() and b_val.isNumber()) {
                        self.push(value.Value.initNumber(a_val.asNumber() - b_val.asNumber()));
                    } else if (self.binary_handler) |handler| {
                        // Delegate to the Standard Library!
                        const result = handler(self, .op_subtract, a_val, b_val) catch return .runtime_error;
                        self.push(result);
                    } else {
                        std.log.err("Runtime Error: Invalid operands for '-'\n", .{});
                        return .runtime_error;
                    }
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
                .op_return => return .ok,
                .op_get_global => {
                    const name_idx = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = frame.chunk.constants.items[name_idx];
                    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", name_val.asObj()));
                    if (self.globals.get(str_obj.chars)) |val| {
                        self.push(val);
                    } else {
                        std.log.err("Runtime Error: Undefined variable '{s}'\n", .{str_obj.chars});
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

                        const result = native_obj.function(self, arg_count, args_ptr) catch return .runtime_error;

                        self.stack_top -= arg_count + 1;
                        self.push(result);
                    } else {
                        std.log.err("Runtime Error: Can only call functions and classes.\n", .{});
                        return .runtime_error;
                    }
                },
                .op_invoke => {
                    const method_name_idx = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const arg_count = frame.chunk.code.items[frame.ip];
                    frame.ip += 1;

                    // Retrieve the method name from the constant pool
                    const method_name_val = frame.chunk.constants.items[method_name_idx];
                    const method_name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", method_name_val.asObj()))).chars;

                    // The receiver object sits just below the arguments on the stack
                    const receiver = self.stack[self.stack_top - 1 - arg_count];

                    if (receiver.isMesh()) {
                        // Phase 1 Mock: Accept transform methods and return the mesh unmodified.
                        // In Phase 3, we will apply math matrices to the vertices here.
                        if (std.mem.eql(u8, method_name_str, "translate") or
                            std.mem.eql(u8, method_name_str, "rotate") or
                            std.mem.eql(u8, method_name_str, "chamfer"))
                        {
                            const result = receiver; // Mutated result would go here
                            self.stack_top -= arg_count + 1;
                            self.push(result);
                        } else {
                            std.log.err("Runtime Error: Unknown method '{s}' on Mesh object.\n", .{method_name_str});
                            return .runtime_error;
                        }
                    } else {
                        std.log.err("Runtime Error: Only Mesh objects support method calls.\n", .{});
                        return .runtime_error;
                    }
                },
                else => {
                    std.log.err("Runtime Error: Unhandled OpCode {}\n", .{op});
                    return .runtime_error;
                },
            }
        }
    }

    pub fn allocateString(self: *VM, chars: []const u8) !value.Value {
        if (self.gc.bytes_allocated > self.gc.next_gc_threshold) {
            self.gc.collectGarbage(self, false);
        }
        const str_obj = try self.gc.allocateString(chars);
        return value.Value.initObj(&str_obj.obj);
    }

    pub fn allocateMesh(self: *VM, handle: ?*anyopaque, vertices: []const value.Vec3, faces: []const [3]u32) !value.Value {
        if (self.gc.bytes_allocated > self.gc.next_gc_threshold) {
            self.gc.collectGarbage(self, false);
        }
        const mesh_obj = try self.gc.allocateMesh(handle, vertices, faces);
        return value.Value.initObj(&mesh_obj.obj);
    }

    pub fn defineNative(self: *VM, name: []const u8, function: value.NativeFn) !void {
        const native_obj = try self.gc.allocateNative(function);
        const native_val = value.Value.initObj(&native_obj.obj);

        try self.ensureStackCapacity(self.stack_top + 1);
        self.push(native_val);
        try self.globals.put(self.allocator, name, native_val);
        _ = self.pop();
    }
};
