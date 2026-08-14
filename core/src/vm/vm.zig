const std = @import("std");
const chunk = @import("chunk.zig");
const memory = @import("memory.zig");
const dag = @import("dag.zig");
const value = @import("../core/value.zig");
const kernel_mod = @import("../kernel/kernel.zig");
const host_mod = @import("host.zig");
const geom = @import("../kernel/geometry_handle.zig");
const LineIndex = @import("../core/line_index.zig").LineIndex;
const Brep = @import("../kernel/engines/brep/topology.zig").Brep;

pub const Host = host_mod.Host;

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
    execution_limit_exceeded,
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
    line_index: ?*const LineIndex = null, // Injected by CLI for debugging
    globals: std.StringHashMapUnmanaged(value.Value),
    strings: std.StringHashMapUnmanaged(*value.ObjString),
    symbols: std.StringHashMapUnmanaged(*value.ObjSymbol),
    open_upvalues: ?*value.ObjUpvalue = null,
    rescue_frames: std.ArrayListUnmanaged(RescueFrame) = .empty,
    host: Host = .{},
    active_kernel: ?*const kernel_mod.GeometryKernel = null,
    dag_builder: dag.DAGBuilder,
    mute_errors: bool = false,
    // std classes
    string_class: ?*value.ObjClass = null,
    array_class: ?*value.ObjClass = null,
    map_class: ?*value.ObjClass = null,
    number_class: ?*value.ObjClass = null,
    // safety for infinite loops
    instruction_count: usize,
    instruction_limit: usize,

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
            .symbols = .empty,
            .dag_builder = dag.DAGBuilder.init(allocator),
            .mute_errors = false,
            .instruction_count = 0,
            .instruction_limit = 1_000_000,
        };
    }

    pub fn deinit(self: *VM) void {
        self.resetStack();
        self.gc.collectGarbage(self, true);
        self.dag_builder.deinit();
        self.allocator.free(self.stack);
        self.globals.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
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
        self.instruction_count = 0; // Reset gas on fresh run
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
        return self.runUntil(0);
    }

    fn runUntil(self: *VM, target_depth: usize) InterpretResult {
        while (self.frames.items.len > target_depth) {
            // Gas Check
            self.instruction_count += 1;
            if (self.instruction_count > self.instruction_limit) {
                self.reportError("Runtime Error: Execution limit exceeded (Infinite loop detected).\n", .{});
                return .execution_limit_exceeded;
            }

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
                    const nums = self.popBinaryNumbers() catch return .runtime_error;
                    self.push(value.Value.initNumber(nums[0] * nums[1]));
                },
                .op_divide => {
                    const nums = self.popBinaryNumbers() catch return .runtime_error;
                    self.push(value.Value.initNumber(nums[0] / nums[1]));
                },
                .op_negate => {
                    const a = self.pop();
                    defer self.releaseValue(a);
                    if (!a.isNumber()) {
                        self.reportError("Runtime Error: Invalid operand for '-'\n", .{});
                        return .runtime_error;
                    }
                    self.push(value.Value.initNumber(-a.asNumber()));
                },
                .op_modulo => {
                    const nums = self.popBinaryNumbers() catch return .runtime_error;
                    self.push(value.Value.initNumber(@mod(nums[0], nums[1])));
                },
                .op_exponent => {
                    const nums = self.popBinaryNumbers() catch return .runtime_error;
                    self.push(value.Value.initNumber(std.math.pow(f64, nums[0], nums[1])));
                },
                .op_not => {
                    const val = self.pop();
                    defer self.releaseValue(val);
                    const is_falsey = val.isNil() or (val.isBool() and !val.asBool());
                    self.push(value.Value.initBool(is_falsey));
                },
                .op_equal => {
                    const b = self.pop();
                    defer self.releaseValue(b);
                    const a = self.pop();
                    defer self.releaseValue(a);
                    self.push(value.Value.initBool(self.valuesEqual(a, b)));
                },
                .op_less => {
                    const nums = self.popBinaryNumbers() catch return .runtime_error;
                    self.push(value.Value.initBool(nums[0] < nums[1]));
                },
                .op_greater => {
                    const nums = self.popBinaryNumbers() catch return .runtime_error;
                    self.push(value.Value.initBool(nums[0] > nums[1]));
                },
                .op_get_property => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;
                    const receiver = self.stack[self.stack_top - 1];

                    if (receiver.isInstance()) {
                        const instance = receiver.asInstance();
                        if (instance.fields.get(name_str)) |val| {
                            self.stack_top -= 1; // Pop receiver
                            self.push(val);
                        } else {
                            self.reportError("Runtime Error: Undefined property '{s}'.\n", .{name_str});
                            return .runtime_error;
                        }
                    } else {
                        self.reportError("Runtime Error: Only instances have properties.\n", .{});
                        return .runtime_error;
                    }
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
                        if (self.findMapKey(map, index)) |i| {
                            self.push(map.values.items[i]);
                        } else {
                            self.push(value.Value.initNil());
                        }
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
                        if (self.findMapKey(map, index)) |i| {
                            self.releaseValue(map.values.items[i]);
                            self.retainValue(val);
                            map.values.items[i] = val;
                        } else {
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
                        self.reportError("\n[Uncaught Exception] ", .{});
                        if (err_val.isObject() and err_val.asObj().obj_type == .string) {
                            const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", err_val.asObj()))).chars;
                            self.reportError("{s}\n", .{str});
                        } else {
                            self.reportError("Unknown error.\n", .{});
                        }
                        self.printStacktrace(); // Natively formats the exact line and column
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

                    if (start_val.isNumber() and end_val.isNumber() and step_val.isNumber()) {
                        const range_obj = self.gc.allocateRange(self, start_val.asNumber(), end_val.asNumber(), step_val.asNumber(), is_exclusive) catch return .runtime_error;
                        self.push(value.Value.initObj(&range_obj.obj));
                    } else if (start_val.isObject() and start_val.asObj().obj_type == .string and end_val.isObject() and end_val.asObj().obj_type == .string) {
                        const s_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", start_val.asObj()))).chars;
                        const e_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", end_val.asObj()))).chars;

                        if (s_str.len == 1 and e_str.len == 1) {
                            const arr_obj = self.gc.allocateArray(self) catch return .runtime_error;
                            const arr_val = value.Value.initObj(&arr_obj.obj);
                            self.push(arr_val); // Protect from GC while building

                            var curr = s_str[0];
                            const limit = if (is_exclusive) e_str[0] else e_str[0] + 1;

                            while (curr < limit) : (curr += 1) {
                                const char_slice = &[_]u8{curr};
                                const char_str = self.allocateString(char_slice) catch return .runtime_error;
                                self.retainValue(char_str);
                                arr_obj.items.append(self.allocator, char_str) catch return .runtime_error;
                            }
                        } else {
                            self.reportError("Runtime Error: String ranges must be single characters.\n", .{});
                            return .runtime_error;
                        }
                    } else {
                        self.reportError("Runtime Error: Range bounds must be numbers or characters.\n", .{});
                        return .runtime_error;
                    }
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
                .op_switch => {
                    const test_val = self.pop();
                    defer self.releaseValue(test_val);

                    const case_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    var matched = false;
                    var jump_offset: u16 = 0;

                    for (0..case_count) |_| {
                        const const_idx = exec_chunk.code.items[frame.ip];
                        const offset = (@as(u16, exec_chunk.code.items[frame.ip + 1]) << 8) | exec_chunk.code.items[frame.ip + 2];
                        frame.ip += 3;

                        if (!matched) {
                            const case_val = exec_chunk.constants.items[const_idx];
                            if (self.valuesEqual(test_val, case_val)) {
                                matched = true;
                                jump_offset = offset;
                            }
                        }
                    }

                    const default_offset = (@as(u16, exec_chunk.code.items[frame.ip]) << 8) | exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;

                    if (matched) {
                        frame.ip += jump_offset;
                    } else {
                        frame.ip += default_offset;
                    }
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

                    if (self.frames.items.len == target_depth) {
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
                .op_unpack_splat => {
                    const pre_count = exec_chunk.code.items[frame.ip];
                    const post_count = exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;

                    const val = self.pop();
                    defer self.releaseValue(val);

                    if (val.isObject() and val.asObj().obj_type == .array) {
                        const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", val.asObj())));
                        const total = arr.items.items.len;

                        for (0..pre_count) |i| {
                            if (i < total) self.push(arr.items.items[i]) else self.push(value.Value.initNil());
                        }

                        const splat_arr = self.gc.allocateArray(self) catch return .runtime_error;
                        const splat_val = value.Value.initObj(&splat_arr.obj);
                        self.push(splat_val);

                        if (total > pre_count + post_count) {
                            const splat_size = total - pre_count - post_count;
                            splat_arr.items.ensureTotalCapacity(self.allocator, splat_size) catch return .runtime_error;
                            for (0..splat_size) |i| {
                                const item = arr.items.items[pre_count + i];
                                self.retainValue(item);
                                splat_arr.items.appendAssumeCapacity(item);
                            }
                        }

                        _ = self.pop();
                        self.push(splat_val);

                        for (0..post_count) |i| {
                            const rev_idx = post_count - i;
                            if (total >= pre_count + rev_idx) {
                                self.push(arr.items.items[total - rev_idx]);
                            } else {
                                self.push(value.Value.initNil());
                            }
                        }
                    } else {
                        // Fallback: If not array, splat gets empty array, first var gets the value
                        if (pre_count > 0) {
                            self.push(val);
                            for (1..pre_count) |_| self.push(value.Value.initNil());

                            const empty_arr = self.gc.allocateArray(self) catch return .runtime_error;
                            self.push(value.Value.initObj(&empty_arr.obj));

                            for (0..post_count) |_| self.push(value.Value.initNil());
                        } else if (post_count > 0) {
                            const empty_arr = self.gc.allocateArray(self) catch return .runtime_error;
                            self.push(value.Value.initObj(&empty_arr.obj));

                            for (0..post_count - 1) |_| self.push(value.Value.initNil());
                            self.push(val);
                        } else {
                            const arr_obj = self.gc.allocateArray(self) catch return .runtime_error;
                            self.push(value.Value.initObj(&arr_obj.obj));
                            self.retainValue(val);
                            arr_obj.items.append(self.allocator, val) catch return .runtime_error;
                            _ = self.pop();
                            self.push(value.Value.initObj(&arr_obj.obj));
                        }
                    }
                },
                .op_module => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];

                    // Removed `.chars` to pass the *ObjString pointer!
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj())));

                    const mod_obj = self.gc.allocateModule(self, name_str) catch return .runtime_error;
                    self.push(value.Value.initObj(&mod_obj.obj));
                },
                .op_mixin => {
                    const module_val = self.pop();
                    defer self.releaseValue(module_val);
                    if (!module_val.isModule()) {
                        self.reportError("Runtime Error: Can only include Modules.\n", .{});
                        return .runtime_error;
                    }

                    const class_val = self.stack[self.stack_top - 1]; // Peek at class
                    if (!class_val.isClass()) return .runtime_error;

                    const class_obj = class_val.asClass();
                    class_obj.included_modules.append(self.allocator, module_val.asModule()) catch return .runtime_error;
                },
                .op_class => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj())));

                    // RE-OPEN the class if it exists in globals!
                    if (self.globals.get(name_str.chars)) |existing| {
                        if (existing.isClass()) {
                            self.push(existing);
                            continue;
                        }
                    }

                    const class_obj = self.gc.allocateClass(self, name_str, null) catch return .runtime_error;
                    self.push(value.Value.initObj(&class_obj.obj));
                },
                .op_method => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;

                    const method = self.pop(); // The closure
                    const receiver_val = self.stack[self.stack_top - 1]; // Peek at class or module

                    if (receiver_val.isClass()) {
                        receiver_val.asClass().methods.put(self.allocator, name_str, method) catch return .runtime_error;
                    } else if (receiver_val.isModule()) {
                        receiver_val.asModule().methods.put(self.allocator, name_str, method) catch return .runtime_error;
                    } else return .runtime_error;
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
                .op_inherit => {
                    const super_val = self.pop();
                    if (!super_val.isClass()) return .runtime_error;
                    const sub_val = self.stack[self.stack_top - 1];
                    sub_val.asClass().superclass = super_val.asClass();
                },
                .op_call => {
                    const arg_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    // Natively calculate the absolute base slot of the closure!
                    const base_slot = self.stack_top - 1 - arg_count;
                    const callee = self.stack[base_slot];

                    if (callee.isNative()) {
                        const native_obj = callee.asNative();
                        const args_ptr = self.stack.ptr + base_slot + 1;
                        const result = native_obj.function(self, arg_count, args_ptr) catch return .runtime_error;
                        self.popAndRelease(arg_count + 1); // Clean up args and callee

                        // Absorb the native +1 reference directly
                        self.stack.ptr[self.stack_top] = result;
                        self.stack_top += 1;
                    } else if (callee.isClosure()) {
                        self.dispatchClosure(callee.asClosure(), arg_count, base_slot) catch return .runtime_error;
                    } else if (callee.isClass()) {
                        const class_obj = callee.asClass();
                        const instance = self.gc.allocateInstance(self, class_obj) catch return .runtime_error;
                        self.stack.ptr[base_slot] = value.Value.initObj(&instance.obj); // Overwrite class with instance safely

                        if (self.findMethod(class_obj, "initialize")) |init_method| {
                            self.dispatchClosure(init_method.asClosure(), arg_count, base_slot) catch return .runtime_error;
                            continue;
                        } else if (arg_count > 0) {
                            self.reportError("Runtime Error: Expected 0 args for default constructor.\n", .{});
                            return .runtime_error;
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

                    const base_slot = self.stack_top - 1 - arg_count;
                    const receiver = self.stack[base_slot];
                    const args_ptr = self.stack.ptr + base_slot + 1;

                    // Resolve Class of Receiver for Native Methods & Monkey-Patching
                    var class_obj: ?*value.ObjClass = null;
                    if (receiver.isInstance()) {
                        class_obj = receiver.asInstance().class;
                    } else if (receiver.isObject()) {
                        switch (receiver.asObj().obj_type) {
                            .string => class_obj = self.string_class,
                            .array => class_obj = self.array_class,
                            .map => class_obj = self.map_class,
                            else => {},
                        }
                    } else if (receiver.isNumber()) {
                        class_obj = self.number_class;
                    }

                    // Handle Property Access (Instances only)
                    if (receiver.isInstance() and arg_count == 0) {
                        if (receiver.asInstance().fields.get(method_name_str)) |val| {
                            self.popAndRelease(1); // Pop receiver
                            self.push(val);
                            continue;
                        }
                    }

                    // Method Lookup
                    var method_val: ?value.Value = null;
                    if (receiver.isClass()) {
                        method_val = self.findClassMethod(receiver.asClass(), method_name_str);
                        if (method_val == null and std.mem.eql(u8, method_name_str, "new")) {
                            const class_to_instantiate = receiver.asClass();
                            const instance = self.gc.allocateInstance(self, class_to_instantiate) catch return .runtime_error;
                            self.stack.ptr[base_slot] = value.Value.initObj(&instance.obj);

                            if (self.findMethod(class_to_instantiate, "initialize")) |init_method| {
                                if (init_method.isClosure()) {
                                    self.dispatchClosure(init_method.asClosure(), arg_count, base_slot) catch return .runtime_error;
                                }
                                continue;
                            } else if (arg_count > 0) {
                                self.reportError("Runtime Error: Expected 0 args for default constructor.\n", .{});
                                return .runtime_error;
                            }
                            continue;
                        }
                    } else if (class_obj) |c| {
                        method_val = self.findMethod(c, method_name_str);
                    }

                    // Dispatch Method if Found
                    if (method_val) |m_val| {
                        if (m_val.isNative()) {
                            const native_obj = m_val.asNative();
                            const result = native_obj.function(self, arg_count, args_ptr) catch return .runtime_error;

                            self.popAndRelease(arg_count + 1);

                            // Absorb the native +1 reference directly
                            self.stack.ptr[self.stack_top] = result;
                            self.stack_top += 1;
                            continue;
                        } else if (m_val.isClosure()) {
                            self.dispatchClosure(m_val.asClosure(), arg_count, base_slot) catch return .runtime_error;
                            continue;
                        }
                    }

                    // Dispatch Method if Found
                    if (method_val) |m_val| {
                        if (m_val.isNative()) {
                            const native_obj = m_val.asNative();
                            const result = native_obj.function(self, arg_count, args_ptr) catch return .runtime_error;

                            self.popAndRelease(arg_count + 1);
                            self.push(result); // Use push()
                            continue;
                        } else if (m_val.isClosure()) {
                            self.dispatchClosure(m_val.asClosure(), arg_count, base_slot) catch return .runtime_error;
                            continue;
                        }
                    }

                    // FALLBACK: NATIVE C++ KERNEL METHODS (Geometry)
                    if (self.host.invoke_handler) |handler| {
                        const result = handler(self, receiver, method_name_str, arg_count, args_ptr) catch return .runtime_error;

                        self.popAndRelease(arg_count + 1);

                        // Absorb the native +1 reference directly
                        self.stack.ptr[self.stack_top] = result;
                        self.stack_top += 1;
                    } else {
                        self.reportError("Runtime Error: No invoke handler registered for method '{s}'.\n", .{method_name_str});
                        return .runtime_error;
                    }
                },
                .op_super_invoke => {
                    const arg_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const base_slot = self.stack_top - 1 - arg_count;
                    const method_name_str = frame.closure.function.name.?.chars;
                    const receiver = self.stack[base_slot];
                    if (receiver.isInstance()) {
                        const instance = receiver.asInstance();
                        const superclass = instance.class.superclass orelse {
                            self.reportError("Runtime Error: No superclass exists for receiver.\n", .{});
                            return .runtime_error;
                        };
                        if (self.findMethod(superclass, method_name_str)) |method_val| {
                            self.dispatchClosure(method_val.asClosure(), arg_count, base_slot) catch return .runtime_error;
                            continue;
                        }
                        self.reportError("Runtime Error: Superclass method '{s}' not found.\n", .{method_name_str});
                        return .runtime_error;
                    }
                    self.reportError("Runtime Error: super can only be called on instances.\n", .{});
                    return .runtime_error;
                },
                .op_yield => {
                    const yield_arg_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const expected_args = frame.closure.function.arity;
                    const block_val = self.stack[frame.base_slot + expected_args + 1];

                    if (!block_val.isClosure()) {
                        self.reportError("Runtime Error: No block given to yield.\n", .{});
                        return .runtime_error;
                    }

                    const block_closure = block_val.asClosure();
                    const args_ptr = self.stack.ptr + self.stack_top - yield_arg_count;
                    const yield_args = args_ptr[0..yield_arg_count];

                    const result = self.callClosureSync(block_closure, yield_args) catch return .runtime_error;

                    // Pop yielded args off stack
                    self.popAndRelease(yield_arg_count);
                    self.push(result);
                },
                .op_block_given => {
                    const expected_args = frame.closure.function.arity;
                    const block_val = self.stack[frame.base_slot + expected_args + 1];
                    self.push(value.Value.initBool(block_val.isClosure()));
                },
                .op_pack_splat => {
                    const fixed_arity = exec_chunk.code.items[frame.ip];
                    const trailing_arity = exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;
                    const block_val = self.stack[self.stack_top - 1]; // Grab the implicit block early!

                    // The arguments start at frame.base_slot + 1 and end exactly before the block
                    const total_args_passed = (self.stack_top - 1) - (frame.base_slot + 1);
                    var splat_size: usize = 0;
                    if (total_args_passed > fixed_arity + trailing_arity) {
                        splat_size = total_args_passed - fixed_arity - trailing_arity;
                    }

                    const arr_obj = self.gc.allocateArray(self) catch return .runtime_error;
                    const arr_val = value.Value.initObj(&arr_obj.obj);
                    arr_obj.items.ensureTotalCapacity(self.allocator, splat_size) catch return .runtime_error;

                    // Pack all excess arguments starting immediately after the fixed arity
                    const start_idx = frame.base_slot + 1 + fixed_arity;
                    for (0..splat_size) |i| {
                        const item = self.stack[start_idx + i];
                        self.retainValue(item);
                        arr_obj.items.appendAssumeCapacity(item);
                    }

                    // Shift any trailing arguments down to close the gap left by the packed arguments
                    if (splat_size != 1) {
                        if (splat_size > 1) {
                            for (0..trailing_arity) |i| {
                                self.stack[start_idx + 1 + i] = self.stack[start_idx + splat_size + i];
                            }
                        } else {
                            var i: usize = trailing_arity;
                            while (i > 0) {
                                i -= 1;
                                self.stack[start_idx + 1 + i] = self.stack[start_idx + i];
                            }
                        }
                    }

                    // Rewrite the stack to hold the new Array in the splat parameter's slot
                    self.stack[start_idx] = arr_val;
                    self.stack_top = start_idx + 1 + trailing_arity;

                    // Push the block back on top to maintain the Uniform Padding invariant
                    self.push(block_val);
                },
                .op_class_method => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;
                    const method = self.pop();
                    const class_val = self.stack[self.stack_top - 1]; // Peek at class
                    const class_obj = class_val.asClass();
                    class_obj.class_methods.put(self.allocator, name_str, method) catch return .runtime_error;
                },
                .op_get_class_var => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;

                    const receiver = self.stack[frame.base_slot];
                    const class_obj = if (receiver.isInstance()) receiver.asInstance().class else if (receiver.isClass()) receiver.asClass() else null;

                    if (class_obj) |c| {
                        if (c.class_fields.get(name_str)) |val| {
                            self.push(val);
                        } else {
                            self.reportError("Runtime Error: Undefined class variable '{s}'.\n", .{name_str});
                            return .runtime_error;
                        }
                    } else return .runtime_error;
                },
                .op_set_class_var => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;

                    const val = self.stack[self.stack_top - 1]; // Peek
                    const receiver = self.stack[frame.base_slot];
                    const class_obj = if (receiver.isInstance()) receiver.asInstance().class else if (receiver.isClass()) receiver.asClass() else null;

                    if (class_obj) |c| {
                        self.retainValue(val);
                        if (c.class_fields.get(name_str)) |old_val| self.releaseValue(old_val);
                        c.class_fields.put(self.allocator, name_str, val) catch return .runtime_error;
                    } else return .runtime_error;
                },
                .op_is_instance => {
                    const class_val = self.pop();
                    defer self.releaseValue(class_val);
                    const thrown_val = self.pop();
                    defer self.releaseValue(thrown_val);

                    if (!class_val.isClass()) {
                        self.reportError("Runtime Error: Rescue type must be a Class.\n", .{});
                        return .runtime_error;
                    }

                    var match = false;
                    if (thrown_val.isInstance()) {
                        match = isSubclassOf(thrown_val.asInstance().class, class_val.asClass());
                    } else if (thrown_val.isClass()) {
                        // Allows naturally catching un-instantiated exception classes (e.g., `raise(ArgumentError)`)
                        match = isSubclassOf(thrown_val.asClass(), class_val.asClass());
                    } else {
                        // If user threw a primitive string instead of an Error object
                        match = false;
                    }
                    self.push(value.Value.initBool(match));
                },
                .op_jump_if_not_nil => {
                    const offset = (@as(u16, exec_chunk.code.items[frame.ip]) << 8) | exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;
                    const val = self.stack[self.stack_top - 1];
                    if (!val.isNil()) {
                        frame.ip += offset;
                    }
                },
                .op_defined => {
                    const name_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    const name_val = exec_chunk.constants.items[name_idx];
                    const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;

                    // Safely probe globals and natives without triggering a VM panic
                    const is_def = self.globals.contains(name_str);
                    self.push(if (is_def) value.Value.initBool(true) else value.Value.initNil());
                },
                .op_extract_kwarg => {
                    const map_slot = exec_chunk.code.items[frame.ip];
                    const name_idx = exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;

                    var extracted = value.Value.initNil();

                    // Safely check if the caller provided a map
                    if (frame.base_slot + map_slot < self.stack_top) {
                        const map_val = self.stack[frame.base_slot + map_slot];
                        if (map_val.isObject() and map_val.asObj().obj_type == .map) {
                            const name_val = exec_chunk.constants.items[name_idx];
                            const name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj()))).chars;
                            const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", map_val.asObj())));

                            for (map.keys.items, 0..) |k, i| {
                                if (k.isObject() and k.asObj().obj_type == .string) {
                                    const k_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;
                                    if (std.mem.eql(u8, k_str, name_str)) {
                                        extracted = map.values.items[i];
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    self.push(extracted);
                },
                else => {
                    self.reportError("Runtime Error: Unhandled OpCode {}\n", .{op});
                    return .runtime_error;
                },
            }
        }

        return .ok;
    }

    // --- Allocators ---

    pub fn allocateString(self: *VM, chars: []const u8) !value.Value {
        const str_obj = try self.gc.allocateString(self, chars);
        return value.Value.initObj(&str_obj.obj);
    }

    pub fn allocateSymbol(self: *VM, chars: []const u8) !value.Value {
        const sym_obj = try self.gc.allocateSymbol(self, chars);
        return value.Value.initObj(&sym_obj.obj);
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

    fn findMethod(self: *VM, class: *value.ObjClass, name: []const u8) ?value.Value {
        _ = self;
        var current: ?*value.ObjClass = class;
        while (current) |c| {
            if (c.methods.get(name)) |method| return method;

            // Check mixins (in reverse order, so latest included takes precedence)
            var i: usize = c.included_modules.items.len;
            while (i > 0) {
                i -= 1;
                const mod = c.included_modules.items[i];
                if (mod.methods.get(name)) |method| return method;
            }

            current = c.superclass;
        }
        return null;
    }

    pub fn dispatchClosure(self: *VM, closure: *value.ObjClosure, arg_count: usize, base_slot: usize) !void {
        var provided_args = arg_count;
        var has_block = false;

        // Extract implicit blocks cleanly
        if (provided_args > 0 and self.stack[self.stack_top - 1].isClosure()) {
            has_block = true;
            provided_args -= 1;
        }

        const expected_args = closure.function.arity;

        // Pad missing arguments with 'nil' natively
        if (provided_args < expected_args) {
            const missing = expected_args - provided_args;
            try self.ensureStackCapacity(self.stack_top + missing);

            const block_copy = if (has_block) self.stack[self.stack_top - 1] else null;
            if (has_block) self.stack_top -= 1;

            for (0..missing) |_| self.push(value.Value.initNil());
            if (has_block) self.push(block_copy.?);
        } else if (provided_args > expected_args and !closure.function.has_splat) {
            self.reportError("Runtime Error: Expected at most {d} args.\n", .{expected_args});
            return error.RuntimeError;
        }

        // Pad the implicit block slot with 'nil' if none was provided
        if (!has_block) {
            try self.ensureStackCapacity(self.stack_top + 1);
            self.push(value.Value.initNil());
        }

        try self.frames.append(self.allocator, .{
            .closure = closure,
            .ip = 0,
            .base_slot = base_slot,
        });
    }

    pub fn callClosureSync(self: *VM, closure: *value.ObjClosure, args: []const value.Value) !value.Value {
        const target_depth = self.frames.items.len;

        const provided_args = args.len;
        const expected_args = closure.function.arity;

        // Ensure stack capacity for closure, args, padded nils, and the implicit null block
        const total_pushes = 1 + @max(provided_args, expected_args) + 1;
        try self.ensureStackCapacity(self.stack_top + total_pushes);

        const base_slot = self.stack_top; // Record where the closure lands exactly

        self.push(value.Value.initObj(&closure.obj)); // closure itself

        for (args) |arg| self.push(arg);

        if (provided_args < expected_args) {
            const missing = expected_args - provided_args;
            for (0..missing) |_| self.push(value.Value.initNil());
        }

        // Pad the implicit empty block
        self.push(value.Value.initNil());

        try self.frames.append(self.allocator, .{
            .closure = closure,
            .ip = 0,
            .base_slot = base_slot,
        });

        const res = self.runUntil(target_depth);
        if (res != .ok) return error.RuntimeError;

        return self.pop();
    }

    // --- Shared Execution Helpers ---
    inline fn popAndRelease(self: *VM, count: usize) void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const dropped = self.pop();
            self.releaseValue(dropped);
        }
    }

    pub fn valuesEqual(self: *VM, a: value.Value, b: value.Value) bool {
        _ = self;
        if (a.isNumber() and b.isNumber()) return a.asNumber() == b.asNumber();
        if (a.isObject() and b.isObject() and a.asObj().obj_type == .string and b.asObj().obj_type == .string) {
            const a_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", a.asObj()))).chars;
            const b_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", b.asObj()))).chars;
            return std.mem.eql(u8, a_str, b_str);
        }
        return a.isEqual(b);
    }

    pub fn findMapKey(self: *VM, map: *value.ObjMap, key: value.Value) ?usize {
        for (map.keys.items, 0..) |k, i| {
            if (self.valuesEqual(k, key)) return i;
        }
        return null;
    }

    fn popBinaryNumbers(self: *VM) !struct { f64, f64 } {
        const b = self.pop();
        defer self.releaseValue(b);
        const a = self.pop();
        defer self.releaseValue(a);

        if (a.isNumber() and b.isNumber()) {
            return .{ a.asNumber(), b.asNumber() };
        }
        self.reportError("Runtime Error: Invalid operands for math operation.\n", .{});
        return error.RuntimeError;
    }

    fn findClassMethod(self: *VM, class: *value.ObjClass, name: []const u8) ?value.Value {
        _ = self;
        var current: ?*value.ObjClass = class;
        while (current) |c| {
            if (c.class_methods.get(name)) |method| return method;
            current = c.superclass;
        }
        return null;
    }

    fn isSubclassOf(class: *value.ObjClass, superclass: *value.ObjClass) bool {
        var current: ?*value.ObjClass = class;
        while (current) |c| {
            if (c == superclass) return true;
            current = c.superclass;
        }
        return false;
    }

    pub fn reportError(self: *VM, comptime fmt: []const u8, args: anytype) void {
        if (!self.mute_errors) {
            std.log.err(fmt, args);
        }
    }

    // --- Error Formatting Engine ---
    fn printStacktrace(self: *VM) void {
        var i: usize = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.frames.items[i];
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(frame.closure.function.chunk.?)));

            // The actual instruction that failed is immediately prior to the IP
            const instruction_ip = if (frame.ip > 0) frame.ip - 1 else 0;
            const source_offset = exec_chunk.getOffset(instruction_ip);
            const func_name = if (frame.closure.function.name) |n| n.chars else "script";

            // Format flawlessly using the injected LineIndex
            if (self.line_index) |li| {
                const line = li.getLine(source_offset) + 1;
                const col = li.getUtf8Column(source_offset) + 1;
                self.reportError("  at {s} (line {d}, col {d})\n", .{ func_name, line, col });
            } else {
                // Safe fallback if LineIndex was stripped/omitted
                self.reportError("  at {s} (offset {d})\n", .{ func_name, source_offset });
            }
        }
    }
};
