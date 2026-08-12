const std = @import("std");
const chunk = @import("chunk.zig");
const memory = @import("memory.zig");
const dag = @import("dag.zig");
const value = @import("../core/value.zig");
const kernel_mod = @import("../kernel/kernel.zig");
const host_mod = @import("host.zig");
const geom = @import("../kernel/geometry_handle.zig");
const Brep = @import("../kernel/engines/brep/topology.zig").Brep;

pub const Host = host_mod.Host;

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

pub const CallFrame = struct {
    closure: *value.ObjClosure,
    ip: usize,
    base_slot: usize,
};

pub const RescueFrame = struct {
    handler_ip: usize,
    stack_top: usize,
    frame_count: usize,
    upvalue_ptr: ?*value.ObjUpvalue,
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
    strings: std.StringHashMapUnmanaged(*value.ObjString),
    open_upvalues: ?*value.ObjUpvalue = null,
    rescue_frames: std.ArrayListUnmanaged(RescueFrame) = .empty,
    host: Host = .{},
    active_kernel: ?*const kernel_mod.GeometryKernel = null,
    dag_builder: dag.DAGBuilder,
    mute_errors: bool = false,

    const INITIAL_STACK_CAPACITY: usize = 1024;
    const STACK_GROW_FACTOR: usize = 2;

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
            .strings = .empty,
            .dag_builder = dag.DAGBuilder.init(allocator),
            .mute_errors = false,
        };
    }

    pub fn deinit(self: *VM) void {
        self.resetStack();
        self.gc.collectGarbage(self, true);
        self.dag_builder.deinit();
        self.allocator.free(self.stack);
        self.globals.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.rescue_frames.deinit(self.allocator);
    }

    // --- Dynamic Stack Operations ---

    pub fn push(self: *VM, val: value.Value) void {
        std.debug.assert(self.stack_top < self.stack.len);
        self.retainValue(val);
        self.stack.ptr[self.stack_top] = val;
        self.stack_top += 1;
    }

    pub fn pop(self: *VM) value.Value {
        std.debug.assert(self.stack_top > 0);
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    pub fn getLocal(self: *VM, frame: *const CallFrame, slot_index: usize) value.Value {
        const absolute_slot = frame.base_slot + slot_index;
        std.debug.assert(absolute_slot < self.stack_top);
        return self.stack[absolute_slot];
    }

    pub fn setLocal(self: *VM, frame: *const CallFrame, slot_index: usize, val: value.Value) void {
        const absolute_slot = frame.base_slot + slot_index;
        std.debug.assert(absolute_slot < self.stack_top);
        self.retainValue(val);
        self.releaseValue(self.stack[absolute_slot]);
        self.stack[absolute_slot] = val;
    }

    pub fn ensureStackCapacity(self: *VM, required_capacity: usize) !void {
        if (required_capacity <= self.stack.len) return;
        var new_capacity = self.stack.len;
        while (new_capacity < required_capacity) {
            new_capacity *= STACK_GROW_FACTOR;
        }
        self.stack = try self.allocator.realloc(self.stack, new_capacity);
    }

    // --- Execution Core ---

    pub fn interpret(self: *VM, execution_chunk: *chunk.Chunk) InterpretResult {
        self.frames.clearRetainingCapacity();
        self.stack_top = 0;
        self.ensureStackCapacity(execution_chunk.max_stack_slots) catch return .runtime_error;

        const func = self.gc.allocateFunction(self) catch return .runtime_error;
        func.chunk = execution_chunk;
        func.owns_chunk = false;
        func.upvalue_count = 0;

        // Protect func from GC during allocateClosure
        self.push(value.Value.initObj(&func.obj));

        const closure = self.gc.allocateClosure(self, func) catch return .runtime_error;

        // Swap func for closure on stack
        _ = self.pop();
        self.push(value.Value.initObj(&closure.obj));

        self.frames.append(self.allocator, .{
            .closure = closure,
            .ip = 0,
            .base_slot = 0, // base_slot 0 is where our closure sits on the stack
        }) catch return .runtime_error;

        return self.run();
    }

    fn run(self: *VM) InterpretResult {
        while (true) {
            var frame = &self.frames.items[self.frames.items.len - 1];
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(frame.closure.function.chunk.?)));
            const instruction = exec_chunk.code.items[frame.ip];
            frame.ip += 1;
            const op: chunk.OpCode = @enumFromInt(instruction);

            switch (op) {
                .op_constant => {
                    const const_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.push(exec_chunk.constants.items[const_idx]);
                },
                .op_nil => self.push(value.Value.initNil()),
                .op_true => self.push(value.Value.initBool(true)),
                .op_false => self.push(value.Value.initBool(false)),
                .op_pop => {
                    const dropped = self.pop();
                    self.releaseValue(dropped);
                },
                .op_get_local => {
                    const slot = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.push(self.getLocal(frame, slot));
                },
                .op_set_local => {
                    const slot = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.setLocal(frame, slot, self.stack[self.stack_top - 1]);
                },
                .op_add => {
                    const b_val = self.pop();
                    defer self.releaseValue(b_val);
                    const a_val = self.pop();
                    defer self.releaseValue(a_val);

                    if (a_val.isNumber() and b_val.isNumber()) {
                        self.push(value.Value.initNumber(a_val.asNumber() + b_val.asNumber()));
                    } else if (self.host.binary_handler) |handler| {
                        const result = handler(self, .op_add, a_val, b_val) catch return .runtime_error;
                        self.stack.ptr[self.stack_top] = result;
                        self.stack_top += 1;
                    } else {
                        self.reportError("Runtime Error: Invalid operands for '+'\n", .{});
                        return .runtime_error;
                    }
                },
                .op_subtract => {
                    const b_val = self.pop();
                    defer self.releaseValue(b_val);
                    const a_val = self.pop();
                    defer self.releaseValue(a_val);

                    if (a_val.isNumber() and b_val.isNumber()) {
                        self.push(value.Value.initNumber(a_val.asNumber() - b_val.asNumber()));
                    } else if (self.host.binary_handler) |handler| {
                        const result = handler(self, .op_subtract, a_val, b_val) catch return .runtime_error;
                        self.stack.ptr[self.stack_top] = result;
                        self.stack_top += 1;
                    } else {
                        self.reportError("Runtime Error: Invalid operands for '-'\n", .{});
                        return .runtime_error;
                    }
                },
                .op_multiply => {
                    const b = self.pop();
                    defer self.releaseValue(b);
                    const a = self.pop();
                    defer self.releaseValue(a);
                    self.push(value.Value.initNumber(a.asNumber() * b.asNumber()));
                },
                .op_divide => {
                    const b = self.pop();
                    defer self.releaseValue(b);
                    const a = self.pop();
                    defer self.releaseValue(a);
                    self.push(value.Value.initNumber(a.asNumber() / b.asNumber()));
                },
                .op_negate => {
                    const a = self.pop();
                    defer self.releaseValue(a);
                    self.push(value.Value.initNumber(-a.asNumber()));
                },
                .op_get_global => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", name_val.asObj()));
                    if (self.globals.get(str_obj.chars)) |val| {
                        self.push(val);
                    } else {
                        self.reportError("Runtime Error: Undefined variable '{s}'\n", .{str_obj.chars});
                        return .runtime_error;
                    }
                },
                .op_get_index => {
                    const index = self.pop();
                    defer self.releaseValue(index);
                    const target = self.pop();
                    defer self.releaseValue(target);

                    if (target.isObject() and target.asObj().obj_type == .array and index.isNumber()) {
                        const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", target.asObj())));
                        const idx = @as(usize, @intFromFloat(index.asNumber()));
                        if (idx >= arr.items.items.len) {
                            self.reportError("Runtime Error: Array index out of bounds.\n", .{});
                            return .runtime_error;
                        }
                        self.push(arr.items.items[idx]);
                    } else if (target.isObject() and target.asObj().obj_type == .map) {
                        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", target.asObj())));
                        var found = false;
                        for (map.keys.items, 0..) |k, i| {
                            if (k.isNumber() and index.isNumber() and k.asNumber() == index.asNumber()) {
                                self.push(map.values.items[i]);
                                found = true;
                                break;
                            } else if (k.isObject() and k.asObj().obj_type == .string and index.isObject() and index.asObj().obj_type == .string) {
                                const k_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj())));
                                const idx_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", index.asObj())));
                                if (std.mem.eql(u8, k_str.chars, idx_str.chars)) {
                                    self.push(map.values.items[i]);
                                    found = true;
                                    break;
                                }
                            }
                        }
                        if (!found) self.push(value.Value.initNil());
                    } else {
                        self.reportError("Runtime Error: Cannot index target.\n", .{});
                        return .runtime_error;
                    }
                },
                .op_set_index => {
                    const val = self.pop();
                    const index = self.pop();
                    defer self.releaseValue(index);
                    const target = self.pop();
                    defer self.releaseValue(target);

                    if (target.isObject() and target.asObj().obj_type == .array and index.isNumber()) {
                        const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", target.asObj())));
                        const idx = @as(usize, @intFromFloat(index.asNumber()));
                        if (idx >= arr.items.items.len) {
                            self.reportError("Runtime Error: Array index out of bounds.\n", .{});
                            return .runtime_error;
                        }
                        // ARC: Safely release the old value before overwriting it
                        self.releaseValue(arr.items.items[idx]);
                        self.retainValue(val);

                        arr.items.items[idx] = val;
                        self.push(val);
                    } else if (target.isObject() and target.asObj().obj_type == .map) {
                        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", target.asObj())));
                        var found = false;
                        for (map.keys.items, 0..) |k, i| {
                            const is_num_match = k.isNumber() and index.isNumber() and k.asNumber() == index.asNumber();
                            var is_str_match = false;

                            if (k.isObject() and k.asObj().obj_type == .string and index.isObject() and index.asObj().obj_type == .string) {
                                const k_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj())));
                                const idx_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", index.asObj())));
                                is_str_match = std.mem.eql(u8, k_str.chars, idx_str.chars);
                            }

                            if (is_num_match or is_str_match) {
                                self.releaseValue(map.values.items[i]);
                                self.retainValue(val);
                                map.values.items[i] = val;
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            // If key doesn't exist, append it
                            self.retainValue(index);
                            self.retainValue(val);
                            map.keys.append(self.allocator, index) catch return .runtime_error;
                            map.values.append(self.allocator, val) catch return .runtime_error;
                        }
                        self.push(val);
                    } else {
                        self.reportError("Runtime Error: Cannot assign to index on target.\n", .{});
                        return .runtime_error;
                    }
                },
                .op_setup_rescue => {
                    const offset = (@as(u16, exec_chunk.code.items[frame.ip]) << 8) | exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;

                    self.rescue_frames.append(self.allocator, .{
                        .handler_ip = frame.ip + offset,
                        .stack_top = self.stack_top,
                        .frame_count = self.frames.items.len,
                        .upvalue_ptr = self.open_upvalues,
                    }) catch return .runtime_error;
                },
                .op_pop_rescue => {
                    _ = self.rescue_frames.pop();
                },
                .op_throw => {
                    const err_val = self.pop();

                    if (self.rescue_frames.items.len == 0) {
                        self.reportError("\n[Uncaught Exception]", .{});
                        if (err_val.isObject() and err_val.asObj().obj_type == .string) {
                            const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", err_val.asObj()))).chars;
                            self.reportError("{s}\n", .{str});
                        }
                        return .runtime_error;
                    }

                    const r_frame = self.rescue_frames.pop().?;

                    // Unwind and cleanly close any closures captured inside the failed block
                    self.closeUpvalues(&self.stack[r_frame.stack_top]);

                    // Unwind Call Frames
                    while (self.frames.items.len > r_frame.frame_count) {
                        _ = self.frames.pop();
                    }

                    // Unwind the Stack variables safely using ARC
                    while (self.stack_top > r_frame.stack_top) {
                        self.stack_top -= 1;
                        self.releaseValue(self.stack[self.stack_top]);
                    }

                    // Push the exception payload and jump into the rescue block!
                    self.push(err_val);
                    self.frames.items[self.frames.items.len - 1].ip = r_frame.handler_ip;
                },
                .op_is_instance => {
                    const class_val = self.pop();
                    defer self.releaseValue(class_val);
                    const instance_val = self.pop();
                    defer self.releaseValue(instance_val);

                    if (!class_val.isClass()) {
                        self.reportError("Runtime Error: Rescue type must be a Class.\n", .{});
                        return .runtime_error;
                    }

                    if (instance_val.isInstance()) {
                        const inst = instance_val.asInstance();
                        // For MVP, exact class match. (Later, we can walk superclasses).
                        self.push(value.Value.initBool(inst.class == class_val.asClass()));
                    } else {
                        // If user threw a primitive string instead of an Error object, it fails the class check
                        self.push(value.Value.initBool(false));
                    }
                },
                .op_call => {
                    const arg_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const callee = self.stack[self.stack_top - 1 - arg_count];

                    if (callee.isNative()) {
                        const native_obj = callee.asNative();
                        const args_ptr = self.stack.ptr + self.stack_top - arg_count;
                        const result = native_obj.function(self, arg_count, args_ptr) catch return .runtime_error;

                        var i: usize = 0;
                        while (i <= arg_count) : (i += 1) {
                            const dropped = self.pop();
                            self.releaseValue(dropped);
                        }

                        self.stack.ptr[self.stack_top] = result;
                        self.stack_top += 1;
                    } else if (callee.isClosure()) {
                        const closure = callee.asClosure();

                        // Enforce Arity Checking
                        if (arg_count != closure.function.arity) {
                            self.reportError("Runtime Error: Expected {d} arguments but got {d}.\n", .{ closure.function.arity, arg_count });
                            return .runtime_error;
                        }

                        // Push a new CallFrame onto the Execution Stack!
                        // The `base_slot` is set to point right at the start of the arguments
                        self.frames.append(self.allocator, .{
                            .closure = closure,
                            .ip = 0,
                            .base_slot = self.stack_top - arg_count - 1,
                        }) catch return .runtime_error;
                    } else if (callee.isClass()) {
                        const class_obj = callee.asClass();
                        const instance = self.gc.allocateInstance(self, class_obj) catch return .runtime_error;
                        self.stack.ptr[self.stack_top - 1 - arg_count] = value.Value.initObj(&instance.obj);

                        var i: usize = 0;
                        while (i < arg_count) : (i += 1) {
                            const dropped = self.pop();
                            self.releaseValue(dropped);
                        }
                    } else {
                        self.reportError("Runtime Error: Can only call functions and classes.\n", .{});
                        return .runtime_error;
                    }
                },
                .op_invoke => {
                    const method_name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const arg_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const method_name_val = exec_chunk.constants.items[method_name_idx];
                    const method_name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", method_name_val.asObj()))).chars;

                    const receiver = self.stack[self.stack_top - 1 - arg_count];
                    const args_ptr = self.stack.ptr + self.stack_top - arg_count;

                    // 1. Is it a KupCAD Custom Object?
                    if (receiver.isInstance()) {
                        const instance = receiver.asInstance();

                        // Property access behaves exactly like a 0-arg method call!
                        if (arg_count == 0) {
                            if (instance.fields.get(method_name_str)) |field_val| {
                                self.stack_top -= 1; // Pop receiver
                                self.push(field_val);
                                continue;
                            }
                        }

                        // Check class methods
                        if (instance.class.methods.get(method_name_str)) |method_val| {
                            const closure = method_val.asClosure();
                            if (arg_count != closure.function.arity - 1) { // -1 for implicit 'self'
                                self.reportError("Runtime Error: Expected {d} arguments but got {d}.\n", .{ closure.function.arity - 1, arg_count });
                                return .runtime_error;
                            }
                            self.frames.append(self.allocator, .{
                                .closure = closure,
                                .ip = 0,
                                .base_slot = self.stack_top - arg_count - 1,
                            }) catch return .runtime_error;
                            continue;
                        }

                        self.reportError("Runtime Error: Undefined property or method '{s}'.\n", .{method_name_str});
                        return .runtime_error;
                    }

                    // 2. Fallback to Native C++ Kernel Methods (for Geometry)
                    if (self.host.invoke_handler) |handler| {
                        const result = handler(self, receiver, method_name_str, arg_count, args_ptr) catch return .runtime_error;
                        var i: usize = 0;
                        while (i <= arg_count) : (i += 1) {
                            const dropped = self.pop();
                            self.releaseValue(dropped);
                        }
                        self.stack.ptr[self.stack_top] = result;
                        self.stack_top += 1;
                    } else {
                        self.reportError("Runtime Error: No invoke handler registered for method '{s}'.\n", .{method_name_str});
                        return .runtime_error;
                    }
                },
                .op_build_array => {
                    const item_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const arr_obj = self.gc.allocateArray(self) catch return .runtime_error;
                    const arr_val = value.Value.initObj(&arr_obj.obj);

                    arr_obj.items.ensureTotalCapacity(self.allocator, item_count) catch return .runtime_error;

                    // The elements were pushed in order, slice them off the top of the stack
                    const start_idx = self.stack_top - item_count;
                    for (self.stack[start_idx..self.stack_top]) |item| {
                        arr_obj.items.appendAssumeCapacity(item);
                    }

                    // Clear the consumed stack space and push the resulting Array
                    self.stack_top -= item_count;
                    self.push(arr_val);
                },
                .op_build_map => {
                    const pair_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const map_obj = self.gc.allocateMap(self) catch return .runtime_error;
                    const map_val = value.Value.initObj(&map_obj.obj);

                    map_obj.keys.ensureTotalCapacity(self.allocator, pair_count) catch return .runtime_error;
                    map_obj.values.ensureTotalCapacity(self.allocator, pair_count) catch return .runtime_error;

                    const start_idx = self.stack_top - (pair_count * 2);
                    var i: usize = 0;
                    while (i < pair_count * 2) : (i += 2) {
                        map_obj.keys.appendAssumeCapacity(self.stack[start_idx + i]);
                        map_obj.values.appendAssumeCapacity(self.stack[start_idx + i + 1]);
                    }

                    // Clear consumed keys & values, push the resulting Map
                    self.stack_top -= (pair_count * 2);
                    self.push(map_val);
                },
                .op_build_range => {
                    const is_exclusive = exec_chunk.code.items[frame.ip] == 1;
                    frame.ip += 1;

                    const step_val = self.pop();
                    defer self.releaseValue(step_val);
                    const end_val = self.pop();
                    defer self.releaseValue(end_val);
                    const start_val = self.pop();
                    defer self.releaseValue(start_val);

                    if (!start_val.isNumber() or !end_val.isNumber() or !step_val.isNumber()) {
                        self.reportError("Runtime Error: Range bounds must be numbers.\n", .{});
                        return .runtime_error;
                    }

                    const range_obj = self.gc.allocateRange(self, start_val.asNumber(), end_val.asNumber(), step_val.asNumber(), is_exclusive) catch return .runtime_error;
                    self.push(value.Value.initObj(&range_obj.obj));
                },
                .op_interpolate => {
                    const count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    var out: std.Io.Writer.Allocating = .init(self.allocator);
                    defer out.deinit();

                    // The string fragments were pushed in order; slice them off the top
                    const start_idx = self.stack_top - count;
                    for (self.stack[start_idx..self.stack_top]) |val| {
                        val.stringify(false, &out.writer) catch return .runtime_error;
                    }

                    const merged_str = self.allocateString(out.written()) catch return .runtime_error;

                    // Pop and release all original stack fragments
                    for (0..count) |_| {
                        const dropped = self.pop();
                        self.releaseValue(dropped);
                    }

                    self.push(merged_str);
                },
                .op_array_push => {
                    const val = self.pop();
                    defer self.releaseValue(val);
                    const arr_val = self.stack[self.stack_top - 1];
                    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));

                    self.retainValue(val);
                    arr.items.append(self.allocator, val) catch return .runtime_error;
                },
                .op_array_spread => {
                    const source_val = self.pop();
                    defer self.releaseValue(source_val);
                    const target_val = self.stack[self.stack_top - 1];
                    const target_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", target_val.asObj())));

                    if (source_val.isObject() and source_val.asObj().obj_type == .array) {
                        const source_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", source_val.asObj())));
                        for (source_arr.items.items) |item| {
                            self.retainValue(item);
                            target_arr.items.append(self.allocator, item) catch return .runtime_error;
                        }
                    } else {
                        self.reportError("Runtime Error: Can only spread arrays into arrays.\n", .{});
                        return .runtime_error;
                    }
                },
                .op_map_insert => {
                    const val = self.pop();
                    defer self.releaseValue(val);
                    const key = self.pop();
                    defer self.releaseValue(key);

                    const map_val = self.stack[self.stack_top - 1];
                    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", map_val.asObj())));

                    self.retainValue(key);
                    self.retainValue(val);
                    map.keys.append(self.allocator, key) catch return .runtime_error;
                    map.values.append(self.allocator, val) catch return .runtime_error;
                },
                .op_map_spread => {
                    const source_val = self.pop();
                    defer self.releaseValue(source_val);
                    const target_val = self.stack[self.stack_top - 1];
                    const target_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", target_val.asObj())));

                    if (source_val.isObject() and source_val.asObj().obj_type == .map) {
                        const source_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", source_val.asObj())));
                        for (source_map.keys.items, 0..) |key, i| {
                            const val = source_map.values.items[i];
                            self.retainValue(key);
                            self.retainValue(val);
                            target_map.keys.append(self.allocator, key) catch return .runtime_error;
                            target_map.values.append(self.allocator, val) catch return .runtime_error;
                        }
                    } else {
                        self.reportError("Runtime Error: Can only spread maps into maps.\n", .{});
                        return .runtime_error;
                    }
                },
                .op_jump => {
                    const offset = (@as(u16, exec_chunk.code.items[frame.ip]) << 8) | exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2 + offset;
                },
                .op_jump_if_false => {
                    const offset = (@as(u16, exec_chunk.code.items[frame.ip]) << 8) | exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;

                    // Falsey values in KupCAD are only `nil` and `false`
                    const val = self.stack[self.stack_top - 1];
                    const is_falsey = val.isNil() or (val.isBool() and !val.asBool());

                    if (is_falsey) {
                        frame.ip += offset;
                    }
                },
                .op_jump_if_nil => {
                    const offset = (@as(u16, exec_chunk.code.items[frame.ip]) << 8) | exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;

                    // Peek at the receiver. If it is nil, take the jump
                    const val = self.stack[self.stack_top - 1];
                    if (val.isNil()) {
                        frame.ip += offset;
                    }
                },
                .op_dup => {
                    const val = self.stack[self.stack_top - 1];
                    self.push(val);
                },
                .op_loop => {
                    const offset = (@as(u16, exec_chunk.code.items[frame.ip]) << 8) | exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;
                    frame.ip -= offset; // Jump backwards
                },
                .op_import => {
                    const path_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const path_val = exec_chunk.constants.items[path_idx];

                    if (self.host.import_handler) |handler| {
                        const str_obj = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", path_val.asObj())));
                        const module_obj = handler(self, str_obj.chars) catch return .runtime_error;
                        self.push(module_obj);
                    } else {
                        // Fallback if no Host import handler is bound
                        self.push(value.Value.initNil());
                    }
                },
                .op_get_upvalue => {
                    const slot = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.push(frame.closure.upvalues[slot].?.location.*);
                },
                .op_set_upvalue => {
                    const slot = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    frame.closure.upvalues[slot].?.location.* = self.stack[self.stack_top - 1];
                },
                .op_close_upvalue => {
                    self.closeUpvalues(&self.stack[self.stack_top - 1]);
                    self.releaseValue(self.pop());
                },
                .op_closure => {
                    const func_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const func_val = exec_chunk.constants.items[func_idx];
                    const func_obj = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", func_val.asObj())));

                    const closure = self.gc.allocateClosure(self, func_obj) catch return .runtime_error;
                    const closure_val = value.Value.initObj(&closure.obj);

                    // Push the closure to the stack BEFORE capturing upvalues to ensure GC safety
                    self.push(closure_val);

                    // Iterate over the operands to wire up the captured variables
                    for (0..func_obj.upvalue_count) |i| {
                        const is_local = exec_chunk.code.items[frame.ip];
                        frame.ip += 1;
                        const index = exec_chunk.code.items[frame.ip];
                        frame.ip += 1;

                        if (is_local == 1) {
                            // Capture directly from the parent's stack slot
                            closure.upvalues[i] = self.captureUpvalue(&self.stack[frame.base_slot + index]) catch return .runtime_error;
                        } else {
                            // Pass down an upvalue that the parent already captured
                            closure.upvalues[i] = frame.closure.upvalues[index];
                        }
                    }
                },
                .op_return => {
                    const result = self.pop();

                    // Close all remaining upvalues for this function before it dies
                    self.closeUpvalues(&self.stack[frame.base_slot]);

                    // Properly release all local variables AND the closure frame
                    // from the stack so their ARC ref_counts deterministically drop to 0!
                    while (self.stack_top > frame.base_slot) {
                        self.stack_top -= 1;
                        self.releaseValue(self.stack[self.stack_top]);
                    }

                    _ = self.frames.pop();

                    // Put the result back on the stack WITHOUT incrementing its ARC
                    // (It already holds a +1 reference from when it was initially popped)
                    self.stack.ptr[self.stack_top] = result;
                    self.stack_top += 1;

                    if (self.frames.items.len == 0) {
                        return .ok;
                    }
                },
                .op_unpack => {
                    const count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const val = self.pop();
                    defer self.releaseValue(val);

                    if (val.isObject() and val.asObj().obj_type == .array) {
                        const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", val.asObj())));
                        for (0..count) |i| {
                            // If the array doesn't have enough items, pad with nil
                            if (i < arr.items.items.len) {
                                self.push(arr.items.items[i]);
                            } else {
                                self.push(value.Value.initNil());
                            }
                        }
                    } else {
                        // If it's not an array, assign the value to the first slot, then nil for the rest
                        self.push(val);
                        for (1..count) |_| {
                            self.push(value.Value.initNil());
                        }
                    }
                },
                .op_class => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj())));

                    const class_obj = self.gc.allocateClass(self, name_str) catch return .runtime_error;
                    self.push(value.Value.initObj(&class_obj.obj));
                },
                .op_method => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;

                    const method = self.pop(); // The closure
                    const class_val = self.stack[self.stack_top - 1]; // Peek at class
                    const class_obj = class_val.asClass();

                    class_obj.methods.put(self.allocator, name_str, method) catch return .runtime_error;
                },
                .op_define_global => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;

                    const val = self.pop();
                    self.globals.put(self.allocator, name_str, val) catch return .runtime_error;
                },
                .op_set_property => {
                    const val = self.pop();
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;

                    const receiver = self.pop();
                    if (receiver.isInstance()) {
                        const instance = receiver.asInstance();
                        self.retainValue(val);
                        // Release old value if overriding
                        if (instance.fields.get(name_str)) |old_val| self.releaseValue(old_val);
                        instance.fields.put(self.allocator, name_str, val) catch return .runtime_error;
                        self.push(val);
                    } else {
                        self.reportError("Runtime Error: Only instances have properties.\n", .{});
                        return .runtime_error;
                    }
                },
                else => {
                    self.reportError("Runtime Error: Unhandled OpCode {}\n", .{op});
                    return .runtime_error;
                },
            }
        }
    }

    // --- Allocators ---

    pub fn allocateString(self: *VM, chars: []const u8) !value.Value {
        const str_obj = try self.gc.allocateString(self, chars);
        return value.Value.initObj(&str_obj.obj);
    }

    pub fn allocateGeometry(self: *VM, state: value.GeometryState) !value.Value {
        const geom_obj = try self.gc.allocateGeometry(state);
        return value.Value.initGeometry(geom_obj);
    }

    pub fn allocateWorkplane(self: *VM, parent: *value.ObjGeometry, origin: [3]f64, normal: [3]f64) !value.Value {
        const wp_obj = try self.gc.allocateWorkplane(parent, origin, normal);
        return value.Value.initWorkplane(wp_obj);
    }

    pub fn defineNative(self: *VM, name: []const u8, function: value.NativeFn) !void {
        const native_obj = try self.gc.allocateNative(self, function);
        const native_val = value.Value.initObj(&native_obj.obj);

        try self.ensureStackCapacity(self.stack_top + 1);
        self.push(native_val);
        try self.globals.put(self.allocator, name, native_val);

        const dropped = self.pop();
        self.releaseValue(dropped);
    }

    // --- ARC Helpers ---

    pub fn retainValue(self: *VM, val: value.Value) void {
        _ = self;
        if (val.isGeometry()) {
            val.asGeometry().ref_count += 1;
        } else if (val.isWorkplane()) {
            val.asWorkplane().ref_count += 1;
        }
    }

    pub fn releaseValue(self: *VM, val: value.Value) void {
        if (val.isGeometry()) {
            const geom_obj = val.asGeometry();
            std.debug.assert(geom_obj.ref_count > 0);
            geom_obj.ref_count -= 1;
            if (geom_obj.ref_count == 0) {
                self.gc.freeGeometry(self, geom_obj);
            }
        } else if (val.isWorkplane()) {
            const wp_obj = val.asWorkplane();
            std.debug.assert(wp_obj.ref_count > 0);
            wp_obj.ref_count -= 1;
            if (wp_obj.ref_count == 0) {
                self.gc.freeWorkplane(self, wp_obj);
            }
        }
    }

    pub fn resetStack(self: *VM) void {
        while (self.stack_top > 0) {
            self.stack_top -= 1;
            self.releaseValue(self.stack[self.stack_top]);
        }
    }

    // --- JIT Materialization ---

    pub fn ensureConcrete(self: *VM, val: value.Value) !geom.GeometryHandle {
        if (!val.isGeometry()) return error.RuntimeError;
        var geometry = val.asGeometry();

        if (geometry.cached_handle) |handle| return handle;

        const handle = try self.evaluateDAG(geometry.dag_idx);
        geometry.cached_handle = handle;
        return handle;
    }

    fn evaluateDAG(self: *VM, node_idx: dag.DAGNodeIndex) !geom.GeometryHandle {
        const node = self.dag_builder.nodes.items[node_idx];
        const kernel = self.active_kernel orelse {
            self.reportError("Runtime Error: No geometry kernel active\n", .{});
            return error.RuntimeError;
        };
        switch (node.tag) {
            .cube => {
                const dims = self.dag_builder.getCubeDimensions(node);
                return kernel.cube(dims.x, dims.y, dims.z, dims.center) orelse return error.RuntimeError;
            },
            .union_op, .difference_op, .intersection_op => {
                const payload = self.dag_builder.getBinaryPayload(node);
                const left_handle = try self.evaluateDAG(payload.left);
                const right_handle = try self.evaluateDAG(payload.right);
                const op: kernel_mod.BooleanOp = switch (node.tag) {
                    .union_op => .union_op,
                    .difference_op => .difference_op,
                    .intersection_op => .intersection_op,
                    else => unreachable,
                };
                return kernel.boolean(left_handle, right_handle, op) orelse return error.RuntimeError;
            },
            .translate => {
                return error.NotImplementedYet;
            },
            else => return error.RuntimeError,
        }
    }

    fn captureUpvalue(self: *VM, local_ptr: *value.Value) !*value.ObjUpvalue {
        var prev_upvalue: ?*value.ObjUpvalue = null;
        var upvalue = self.open_upvalues;

        // Search the linked list for an existing upvalue pointing to this exact stack slot
        while (upvalue != null and @intFromPtr(upvalue.?.location) > @intFromPtr(local_ptr)) {
            prev_upvalue = upvalue;
            upvalue = upvalue.?.next;
        }

        // If we found it, reuse it!
        if (upvalue != null and upvalue.?.location == local_ptr) {
            return upvalue.?;
        }

        // Delegate allocation and memory tracking entirely to the GC
        const created_upvalue = try self.gc.allocateUpvalue(local_ptr, upvalue);

        if (prev_upvalue == null) {
            self.open_upvalues = created_upvalue;
        } else {
            prev_upvalue.?.next = created_upvalue;
        }

        return created_upvalue;
    }

    // Add the Scope Closing algorithm
    fn closeUpvalues(self: *VM, last_stack_slot: *value.Value) void {
        while (self.open_upvalues != null and @intFromPtr(self.open_upvalues.?.location) >= @intFromPtr(last_stack_slot)) {
            var upvalue = self.open_upvalues.?;
            upvalue.closed = upvalue.location.*; // Move from Stack -> Heap
            upvalue.location = &upvalue.closed; // Repoint to internal field
            self.open_upvalues = upvalue.next; // Unlink from active list
        }
    }

    pub fn reportError(self: *VM, comptime fmt: []const u8, args: anytype) void {
        if (!self.mute_errors) {
            std.log.err(fmt, args);
        }
    }
};
