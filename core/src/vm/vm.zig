const std = @import("std");
const chunk = @import("chunk.zig");
const memory = @import("memory.zig");
const dag = @import("dag.zig");
const limits = @import("limits.zig");
const value = @import("../core/value.zig");
const parameters = @import("../core/parameters.zig");
const kernel_mod = @import("../kernel/kernel.zig");
const host_mod = @import("host.zig");
const geom = @import("../kernel/geometry_handle.zig");
const dag_evaluator = @import("dag_evaluator.zig");
const profiler_mod = @import("profiler.zig");
const LineIndex = @import("../core/line_index.zig").LineIndex;
const Brep = @import("../kernel/engines/brep/topology.zig").Brep;

pub const Host = host_mod.Host;

pub const InterpretResult = enum {
    ok,
    block_break,
    compile_error,
    runtime_error,
    execution_limit_exceeded,
    paused,
};

pub const CallFrame = struct {
    closure: *value.ObjClosure,
    ip: usize,
    base_slot: usize,
    is_constructor: bool = false,
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
    stack: []value.Value,
    stack_top: usize,
    frames: std.ArrayListUnmanaged(CallFrame),

    gc: memory.GC,
    line_index: ?*const LineIndex = null, // Injected by CLI for debugging
    profiler: ?*profiler_mod.Profiler = null, // First-class tracing profiler

    globals: std.StringHashMapUnmanaged(value.Value),
    strings: std.StringHashMapUnmanaged(*value.ObjString),
    symbols: std.StringHashMapUnmanaged(*value.ObjSymbol),

    open_upvalues: ?*value.ObjUpvalue = null,
    rescue_frames: std.ArrayListUnmanaged(RescueFrame) = .empty,
    param_registry: parameters.ParamList = .{},

    host: Host = .{},
    dag_builder: dag.DAGBuilder,
    mute_errors: bool = false,
    step_mode: bool = false,

    // std classes
    string_class: ?*value.ObjClass = null,
    array_class: ?*value.ObjClass = null,
    map_class: ?*value.ObjClass = null,
    number_class: ?*value.ObjClass = null,
    symbol_class: ?*value.ObjClass = null,
    boolean_class: ?*value.ObjClass = null,
    bbox_class: ?*value.ObjClass = null,
    object_class: ?*value.ObjClass = null,
    geometry_class: ?*value.ObjClass = null,
    cross_section_class: ?*value.ObjClass = null,

    // safety for infinite loops
    instruction_count: usize,
    instruction_limit: usize,
    // max call stack
    max_call_frames: usize = 100_000,
    /// Set to true during tests to brutally expose unrooted allocations
    zealous_gc: bool = false,

    const STACK_GROW_FACTOR: usize = 2;

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !VM {
        // Pre-allocate a massive 64K stack (512KB of contiguous memory)
        const initial_stack = try allocator.alloc(value.Value, 65536);

        // Pre-allocate 4,096 frames (~128KB of contiguous memory)
        var frames = std.ArrayListUnmanaged(CallFrame).empty;
        try frames.ensureTotalCapacity(allocator, 4096);

        // Pre-allocate rescue frames
        var rescue_frames = std.ArrayListUnmanaged(RescueFrame).empty;
        try rescue_frames.ensureTotalCapacity(allocator, 256);

        return .{
            .allocator = allocator,
            .io = io,
            .stack = initial_stack,
            .stack_top = 0,
            .frames = frames,
            .gc = memory.GC.init(allocator),
            .globals = .empty,
            .strings = .empty,
            .symbols = .empty,
            .open_upvalues = null,
            .rescue_frames = rescue_frames,
            .param_registry = .{},
            .host = .{},
            .dag_builder = dag.DAGBuilder.init(allocator),
            .mute_errors = false,
            .instruction_count = 0,
            .instruction_limit = limits.DEFAULT_INSTRUCTION_LIMIT,
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
        self.param_registry.deinit(self.allocator);
        self.gc.deinit();
    }

    // --- Dynamic Stack Operations ---
    pub fn push(self: *VM, val: value.Value) void {
        // Dynamically grow the stack gracefully if we hit the limit
        if (self.stack_top >= self.stack.len) {
            self.ensureStackCapacity(self.stack_top + 1) catch @panic("OOM during stack expansion");
        }
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
        self.stack[absolute_slot] = val;
    }

    pub fn mapSet(self: *VM, map: *value.ObjMap, key: value.Value, val: value.Value) !void {
        if (self.findMapKey(map, key)) |idx| {
            map.values.items[idx] = val;
        } else {
            try map.keys.append(self.allocator, key);
            try map.values.append(self.allocator, val);
        }
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
        // Start small (64 initial frames) and let it grow dynamically
        self.frames.ensureTotalCapacity(self.allocator, 64) catch return .runtime_error;
        self.stack_top = 0;

        const func = self.gc.allocateFunction(self) catch return .runtime_error;
        func.chunk = execution_chunk;
        func.owns_chunk = false;
        func.upvalue_count = 0;
        func.local_count = execution_chunk.local_count;

        // Protect func from GC during allocateClosure
        self.push(value.Value.initObj(&func.obj));
        const closure = self.gc.allocateClosure(self, func) catch return .runtime_error;

        // Swap func for closure on stack
        _ = self.pop();
        self.push(value.Value.initObj(&closure.obj));

        // Pad the top-level script frame for its local variables
        const total_locals = func.local_count;
        if (total_locals > 1) {
            const locals_to_pad = total_locals - 1; // Slot 0 is occupied by the script closure
            self.ensureStackCapacity(self.stack_top + locals_to_pad) catch return .runtime_error;
            for (0..locals_to_pad) |_| self.push(value.Value.initNil());
        }

        self.frames.appendAssumeCapacity(.{
            .closure = closure,
            .ip = 0,
            .base_slot = 0, // base_slot 0 is where our closure sits on the stack
        });

        // --- PROFILER: Top-Level Script ---
        if (self.profiler) |p| p.enterFrame("script") catch {};

        return self.run();
    }

    pub fn run(self: *VM) InterpretResult {
        return self.runUntil(0);
    }

    pub fn runUntil(self: *VM, target_depth: usize) InterpretResult {
        var previous_line: ?u32 = null; // Track line boundary

        while (self.frames.items.len > target_depth) {

            // Gas Check
            if (self.instruction_limit > 0) {
                self.instruction_count += 1;
                if (self.instruction_count > self.instruction_limit) {
                    self.runtimeError("Runtime Error: Execution limit exceeded (Infinite loop detected).\n", .{});
                    return .execution_limit_exceeded;
                }
            }

            if (self.zealous_gc) {
                // Run a full Mark-and-Sweep before executing the opcode.
                // If ANY native method forgot to root a temporary object, it will be
                // swept right now, and the next instruction will immediately crash.
                self.gc.collectGarbage(self, false);
            }

            var frame = &self.frames.items[self.frames.items.len - 1];
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(frame.closure.function.chunk.?)));

            // --- DEBUGGER: Step Mechanics ---
            if (self.step_mode) {
                if (self.line_index) |li| {
                    const current_offset = exec_chunk.getOffset(frame.ip);
                    const current_line = li.getLine(current_offset);

                    if (previous_line) |prev| {
                        if (current_line != prev) {
                            // We crossed a line boundary! Yield to the REPL.
                            return .paused;
                        }
                    } else {
                        // Initialize tracking on the first instruction of this step
                        previous_line = current_line;
                    }
                }
            }

            // Prevent runaway instruction pointer
            std.debug.assert(frame.ip < exec_chunk.code.items.len);

            const instruction = exec_chunk.code.items[frame.ip];
            frame.ip += 1;

            const op: chunk.OpCode = @enumFromInt(instruction);

            switch (op) {
                .op_nil => self.push(value.Value.initNil()),
                .op_true => self.push(value.Value.initBool(true)),
                .op_false => self.push(value.Value.initBool(false)),
                .op_pop => {
                    _ = self.pop();
                },
                .op_constant => {
                    const const_idx = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.push(exec_chunk.constants.items[const_idx]);
                },
                .op_constant_wide => {
                    const high = @as(usize, exec_chunk.code.items[frame.ip]);
                    const low = @as(usize, exec_chunk.code.items[frame.ip + 1]);
                    frame.ip += 2;
                    self.push(exec_chunk.constants.items[(high << 8) | low]);
                },
                .op_get_local => {
                    const slot = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.push(self.getLocal(frame, slot));
                },
                .op_get_local_wide => {
                    const high = @as(usize, exec_chunk.code.items[frame.ip]);
                    const low = @as(usize, exec_chunk.code.items[frame.ip + 1]);
                    frame.ip += 2;
                    self.push(self.getLocal(frame, (high << 8) | low));
                },
                .op_set_local => {
                    const slot = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.setLocal(frame, slot, self.stack[self.stack_top - 1]);
                },
                .op_set_local_wide => {
                    const high = @as(usize, exec_chunk.code.items[frame.ip]);
                    const low = @as(usize, exec_chunk.code.items[frame.ip + 1]);
                    frame.ip += 2;
                    self.setLocal(frame, (high << 8) | low, self.stack[self.stack_top - 1]);
                },
                .op_add, .op_subtract, .op_bitwise_and => {
                    const res = self.executeBinaryArithmetic(op);
                    if (res != .ok) return res;
                },
                .op_multiply, .op_divide, .op_modulo, .op_exponent, .op_less, .op_greater => {
                    const res = self.executeNumericBinary(op);
                    if (res != .ok) return res;
                },
                .op_negate => {
                    const a = self.pop();
                    if (!a.isNumber()) {
                        if (self.throwDynamicError("Runtime Error: Invalid operand for '-'\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                    self.push(value.Value.initNumber(-a.asNumber()));
                },
                .op_not => {
                    self.push(value.Value.initBool(isFalsey(self.pop())));
                },
                .op_equal => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(value.Value.initBool(self.valuesEqual(a, b)));
                },
                .op_case_equal => {
                    const case_val = self.pop();
                    const test_val = self.pop();
                    self.push(value.Value.initBool(self.valuesCaseEqual(case_val, test_val)));
                },

                .op_set_member, .op_set_member_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_set_member_wide);
                    const val = self.pop();
                    const receiver = self.stack[self.stack_top - 1]; // Peek at namespace (Module/Class)

                    if (receiver.isModule()) {
                        const mod = receiver.asModule();
                        mod.methods.put(self.allocator, name_str, val) catch return .runtime_error;
                    } else if (receiver.isClass()) {
                        const cls = receiver.asClass();
                        cls.class_fields.put(self.allocator, name_str, val) catch return .runtime_error;
                    } else {
                        if (self.throwDynamicError("Runtime Error: Cannot attach member to non-namespace.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                    self.push(val); // Push the namespace back to maintain stack equilibrium
                },
                .op_get_global, .op_get_global_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_get_global_wide);
                    if (self.globals.get(name_str)) |val| {
                        self.push(val);
                    } else {
                        if (self.throwDynamicError("Runtime Error: Undefined variable '{s}'\n", .{name_str}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_get_index => {
                    const index = self.pop();
                    const target = self.pop();

                    if (target.isObject() and target.asObj().obj_type == .array and index.isNumber()) {
                        const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", target.asObj())));
                        if (self.resolveArrayIndex(arr.items.items.len, index)) |idx| {
                            self.push(arr.items.items[idx]);
                        } else |_| {
                            if (self.throwDynamicError("Runtime Error: Array index out of bounds.", .{}) != .ok) return .runtime_error;
                            continue;
                        }
                    } else if (target.isObject() and target.asObj().obj_type == .map) {
                        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", target.asObj())));
                        if (self.findMapKey(map, index)) |i| {
                            self.push(map.values.items[i]);
                        } else {
                            self.push(value.Value.initNil());
                        }
                    } else {
                        if (self.throwDynamicError("Runtime Error: Cannot index target.", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_set_index => {
                    const val = self.pop();
                    const index = self.pop();
                    const target = self.pop();

                    if (target.isObject() and target.asObj().obj_type == .array and index.isNumber()) {
                        const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", target.asObj())));
                        if (self.resolveArrayIndex(arr.items.items.len, index)) |idx| {
                            arr.items.items[idx] = val;
                            self.push(val);
                        } else |_| {
                            if (self.throwDynamicError("Runtime Error: Array index out of bounds.", .{}) != .ok) return .runtime_error;
                            continue;
                        }
                    } else if (target.isObject() and target.asObj().obj_type == .map) {
                        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", target.asObj())));

                        self.mapSet(map, index, val) catch return .runtime_error;
                        self.push(val);
                    } else {
                        if (self.throwDynamicError("Runtime Error: Cannot assign to index on target.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_setup_rescue => {
                    // Properly read the 3-byte offset
                    const offset = self.readJumpOffset(exec_chunk, frame);
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
                    const res = self.executeThrow();
                    if (res != .ok) return res;
                },
                .op_break_block => {
                    const break_val = self.pop();

                    self.closeUpvalues(&self.stack[frame.base_slot]);
                    self.shrinkStack(frame.base_slot);
                    std.debug.assert(self.frames.items.len > 0);

                    _ = self.frames.pop();

                    self.stack.ptr[self.stack_top] = break_val;
                    self.stack_top += 1;

                    return .block_break;
                },
                .op_build_array, .op_build_array_wide => {
                    const item_count = self.readOperand(exec_chunk, frame, op == .op_build_array_wide);
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
                .op_build_map, .op_build_map_wide => {
                    const pair_count = self.readOperand(exec_chunk, frame, op == .op_build_map_wide);
                    const map_obj = self.gc.allocateMap(self) catch return .runtime_error;
                    const map_val = value.Value.initObj(&map_obj.obj);

                    // Pre-allocate for performance
                    map_obj.keys.ensureTotalCapacity(self.allocator, pair_count) catch return .runtime_error;
                    map_obj.values.ensureTotalCapacity(self.allocator, pair_count) catch return .runtime_error;

                    const start_idx = self.stack_top - (pair_count * 2);
                    var i: usize = 0;
                    while (i < pair_count * 2) : (i += 2) {
                        const key = self.stack[start_idx + i];
                        const val = self.stack[start_idx + i + 1];

                        self.mapSet(map_obj, key, val) catch return .runtime_error;
                    }
                    self.stack_top -= (pair_count * 2);
                    self.push(map_val);
                },
                .op_build_range => {
                    const res = self.executeBuildRange(frame, exec_chunk);
                    if (res != .ok) return res;
                },
                .op_is_nil => {
                    const val = self.pop();
                    self.push(value.Value.initBool(val.isNil()));
                },
                .op_interpolate => {
                    const count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    var out: std.Io.Writer.Allocating = .init(self.allocator);

                    // The string fragments were pushed in order; slice them off the top
                    const start_idx = self.stack_top - count;
                    for (self.stack[start_idx..self.stack_top]) |val| {
                        val.stringify(false, &out.writer) catch {
                            out.deinit();
                            return .runtime_error;
                        };
                    }

                    const merged_bytes = self.allocator.dupe(u8, out.written()) catch {
                        out.deinit();
                        return .runtime_error;
                    };
                    out.deinit(); // Clean up the writer explicitly

                    // The critical memory leak patch
                    errdefer self.allocator.free(merged_bytes);

                    // Pass ownership to the VM
                    const merged_str = self.allocateStringTakeOwnership(merged_bytes) catch return .runtime_error;

                    // Pop and release all original stack fragments
                    for (0..count) |_| {
                        _ = self.pop();
                    }
                    self.push(merged_str);
                },
                .op_array_push => {
                    const val = self.pop();
                    const arr_val = self.stack[self.stack_top - 1];
                    const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
                    arr.items.append(self.allocator, val) catch return .runtime_error;
                },
                .op_array_spread => {
                    const source_val = self.pop();
                    const target_val = self.stack[self.stack_top - 1];
                    const target_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", target_val.asObj())));

                    if (source_val.isObject() and source_val.asObj().obj_type == .array) {
                        const source_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", source_val.asObj())));
                        for (source_arr.items.items) |item| {
                            target_arr.items.append(self.allocator, item) catch return .runtime_error;
                        }
                    } else {
                        if (self.throwDynamicError("Runtime Error: Can only spread arrays into arrays.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_map_insert => {
                    const val = self.pop();
                    const key = self.pop();
                    const map_val = self.stack[self.stack_top - 1];
                    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", map_val.asObj())));

                    self.mapSet(map, key, val) catch return .runtime_error;
                },
                .op_map_spread => {
                    const source_val = self.pop();
                    const target_val = self.stack[self.stack_top - 1];
                    const target_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", target_val.asObj())));

                    if (source_val.isObject() and source_val.asObj().obj_type == .map) {
                        const source_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", source_val.asObj())));
                        for (source_map.keys.items, 0..) |key, i| {
                            const val = source_map.values.items[i];

                            self.mapSet(target_map, key, val) catch return .runtime_error;
                        }
                    } else {
                        if (self.throwDynamicError("Runtime Error: Can only spread maps into maps.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_jump => {
                    // Properly read 3-byte offset
                    const offset = self.readJumpOffset(exec_chunk, frame);
                    frame.ip += offset;
                },
                .op_jump_if_false => {
                    const offset = self.readJumpOffset(exec_chunk, frame);
                    if (isFalsey(self.stack[self.stack_top - 1])) {
                        frame.ip += offset;
                    }
                },
                .op_jump_if_nil => {
                    // Properly read 3-byte offset
                    const offset = self.readJumpOffset(exec_chunk, frame);
                    // Peek at the receiver. If it is nil, take the jump
                    const val = self.stack[self.stack_top - 1];
                    if (val.isNil()) {
                        frame.ip += offset;
                    }
                },
                .op_jump_if_not_nil => {
                    // Properly read 3-byte offset
                    const offset = self.readJumpOffset(exec_chunk, frame);
                    const val = self.stack[self.stack_top - 1];
                    if (!val.isNil()) {
                        frame.ip += offset;
                    }
                },
                .op_dup => {
                    const val = self.stack[self.stack_top - 1];
                    self.push(val);
                },
                .op_dup_two => {
                    const b = self.stack[self.stack_top - 1];
                    const a = self.stack[self.stack_top - 2];
                    self.push(a); // Push copies in the exact same order
                    self.push(b);
                },
                .op_loop => {
                    // Properly read 3-byte offset
                    const offset = self.readJumpOffset(exec_chunk, frame);
                    frame.ip -= offset; // Jump backwards
                },
                .op_import, .op_import_wide => {
                    const path_idx = self.readOperand(exec_chunk, frame, op == .op_import_wide);
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
                },
                .op_switch, .op_switch_wide => {
                    const test_val = self.pop();

                    const case_count = self.readOperand(exec_chunk, frame, op == .op_switch_wide);
                    var matched = false;
                    var jump_offset: usize = 0;

                    for (0..case_count) |_| {
                        // Read 6 bytes per case: [const_high] [const_low] [b3] [b2] [b1] [b0]
                        const const_high = @as(u16, exec_chunk.code.items[frame.ip]);
                        const const_low = @as(u16, exec_chunk.code.items[frame.ip + 1]);
                        const j_b3 = @as(usize, exec_chunk.code.items[frame.ip + 2]);
                        const j_b2 = @as(usize, exec_chunk.code.items[frame.ip + 3]);
                        const j_b1 = @as(usize, exec_chunk.code.items[frame.ip + 4]);
                        const j_b0 = @as(usize, exec_chunk.code.items[frame.ip + 5]);
                        frame.ip += 6;

                        if (!matched) {
                            const const_idx = (const_high << 8) | const_low;
                            const case_val = exec_chunk.constants.items[const_idx];
                            if (self.valuesCaseEqual(case_val, test_val)) {
                                matched = true;
                                jump_offset = (j_b3 << 24) | (j_b2 << 16) | (j_b1 << 8) | j_b0;
                            }
                        }
                    }

                    const default_offset = self.readJumpOffset(exec_chunk, frame);

                    if (matched) {
                        frame.ip += jump_offset;
                    } else {
                        frame.ip += default_offset;
                    }
                },
                .op_closure, .op_closure_wide => {
                    const func_idx = self.readOperand(exec_chunk, frame, op == .op_closure_wide);
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
                        // Read 16-bit upvalue index
                        const index = (@as(u16, exec_chunk.code.items[frame.ip]) << 8) | exec_chunk.code.items[frame.ip + 1];
                        frame.ip += 2;

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
                    // --- PROFILER: Stop Timer ---
                    if (self.profiler) |p| p.exitFrame() catch {};

                    const result = self.pop();

                    self.closeUpvalues(&self.stack[frame.base_slot]);

                    // Constructor intercepts the return and yields `self` instead of the function's result
                    const return_val = if (frame.is_constructor) self.stack[frame.base_slot] else result;

                    self.shrinkStack(frame.base_slot);
                    // Catch runaway returns
                    std.debug.assert(self.frames.items.len > 0);

                    _ = self.frames.pop();

                    self.stack.ptr[self.stack_top] = return_val;
                    self.stack_top += 1;

                    if (self.frames.items.len == target_depth) {
                        return .ok;
                    }
                },
                .op_unpack => {
                    const count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const val = self.pop();

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
                .op_module, .op_module_wide => {
                    const name_str_obj = self.readStringObjectOperand(exec_chunk, frame, op == .op_module_wide);
                    const mod_obj = self.gc.allocateModule(self, name_str_obj) catch return .runtime_error;
                    self.push(value.Value.initObj(&mod_obj.obj));
                },
                .op_mixin => {
                    const module_val = self.pop();
                    if (!module_val.isModule()) {
                        if (self.throwDynamicError("Runtime Error: Can only include Modules.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                    const class_val = self.stack[self.stack_top - 1]; // Peek at class
                    if (!class_val.isClass()) return .runtime_error;
                    const class_obj = class_val.asClass();
                    class_obj.included_modules.append(self.allocator, module_val.asModule()) catch return .runtime_error;
                },
                .op_class, .op_class_wide => {
                    const name_str_obj = self.readStringObjectOperand(exec_chunk, frame, op == .op_class_wide);

                    // RE-OPEN the class if it exists in globals!
                    if (self.globals.get(name_str_obj.chars)) |existing| {
                        if (existing.isClass()) {
                            self.push(existing);
                            continue;
                        }
                    }

                    // Ensure new classes inherit from Object by default
                    const class_obj = self.gc.allocateClass(self, name_str_obj, self.object_class) catch return .runtime_error;
                    self.push(value.Value.initObj(&class_obj.obj));
                },
                .op_method, .op_method_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_method_wide);
                    const method = self.pop(); // The closure
                    const receiver_val = self.stack[self.stack_top - 1]; // Peek at class or module

                    if (receiver_val.isClass()) {
                        receiver_val.asClass().methods.put(self.allocator, name_str, method) catch return .runtime_error;
                    } else if (receiver_val.isModule()) {
                        receiver_val.asModule().methods.put(self.allocator, name_str, method) catch return .runtime_error;
                    } else return .runtime_error;
                },
                .op_define_global, .op_define_global_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_define_global_wide);
                    const val = self.pop();
                    self.globals.put(self.allocator, name_str, val) catch return .runtime_error;
                },
                .op_get_property, .op_get_property_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_get_property_wide);
                    const ic = self.readInlineCache(exec_chunk, frame);
                    const receiver = self.stack[self.stack_top - 1];

                    if (receiver.isInstance()) {
                        self.stack_top -= 1; // Pop receiver
                        if (self.getPropertyCached(receiver.asInstance(), name_str, ic)) |val| {
                            self.push(val);
                        } else {
                            // Phase 4A FIX: Missing properties on instances evaluate to nil
                            self.push(value.Value.initNil());
                        }
                    } else if (receiver.isModule()) {
                        self.stack_top -= 1; // Pop receiver
                        const mod = receiver.asModule();
                        if (mod.methods.get(name_str)) |val| {
                            self.push(val);
                        } else {
                            if (self.throwDynamicError("Runtime Error: Undefined module member '{s}'.", .{name_str}) != .ok) return .runtime_error;
                            continue;
                        }
                    } else if (receiver.isClass()) {
                        self.stack_top -= 1; // Pop receiver
                        const cls = receiver.asClass();

                        // Check class_fields first to prioritize stored values over accessor methods
                        if (cls.class_fields.get(name_str)) |val| {
                            self.push(val);
                        } else if (self.findClassMethod(cls, name_str)) |val| {
                            self.push(val);
                        } else {
                            if (self.throwDynamicError("Runtime Error: Undefined class member '{s}'.", .{name_str}) != .ok) return .runtime_error;
                            continue;
                        }
                    } else {
                        if (self.throwDynamicError("Runtime Error: Only instances, modules, and classes have properties.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_set_property, .op_set_property_wide => {
                    const val = self.pop();
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_set_property_wide);
                    const ic = self.readInlineCache(exec_chunk, frame);
                    const receiver = self.pop();

                    if (receiver.isInstance()) {
                        self.setInstanceField(receiver.asInstance(), name_str, val, ic) catch return .runtime_error;
                        self.push(val);
                    } else if (receiver.isClass()) {
                        const cls = receiver.asClass();
                        cls.class_fields.put(self.allocator, name_str, val) catch return .runtime_error;
                        self.push(val);
                    } else {
                        if (self.throwDynamicError("Runtime Error: Only instances and classes have properties.", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_inherit => {
                    const super_val = self.pop();
                    if (!super_val.isClass()) return .runtime_error;
                    const sub_val = self.stack[self.stack_top - 1];
                    sub_val.asClass().superclass = super_val.asClass();
                },
                .op_call => {
                    const res = self.executeCall(frame, exec_chunk);
                    if (res != .ok) return res;
                },
                .op_invoke, .op_invoke_wide => {
                    const res = self.executeInvoke(frame, exec_chunk, op == .op_invoke_wide);
                    if (res != .ok) return res;
                },
                .op_unpack_splat => {
                    const res = self.executeUnpackSplat(frame, exec_chunk);
                    if (res != .ok) return res;
                },
                .op_pack_splat => {
                    const res = self.executePackSplat(frame, exec_chunk);
                    if (res != .ok) return res;
                },
                .op_super_invoke => {
                    const arg_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const base_slot = self.stack_top - 1 - arg_count;

                    const method_name_str = if (frame.closure.function.name) |n| n.chars else "";
                    const receiver = self.stack[base_slot];

                    if (receiver.isInstance()) {
                        const instance = receiver.asInstance();
                        const superclass = instance.class.superclass orelse {
                            return self.throwDynamicError("Runtime Error: No superclass exists for receiver.\n", .{});
                        };

                        var method_val = self.findMethod(superclass, method_name_str);
                        if (method_val == null) {
                            var buf: [256]u8 = undefined;
                            const priv_name = std.fmt.bufPrint(&buf, "@private:{s}", .{method_name_str}) catch "";
                            method_val = self.findMethod(superclass, priv_name);
                        }

                        if (method_val) |m_val| {
                            if (m_val.isClosure()) {
                                self.dispatchClosure(m_val.asClosure(), arg_count, base_slot, false) catch return .runtime_error;
                                continue;
                            } else if (m_val.isNative()) {
                                const args_ptr = self.stack.ptr + base_slot + 1;
                                const res = self.executeNative(m_val.asNative(), arg_count, args_ptr, method_name_str);
                                if (res != .ok) return res;
                                continue;
                            } else {
                                if (self.throwDynamicError("Runtime Error: Superclass method '{s}' is not callable.\n", .{method_name_str}) != .ok) return .runtime_error;
                                continue;
                            }
                        }

                        if (self.throwDynamicError("Runtime Error: Superclass method '{s}' not found.\n", .{method_name_str}) != .ok) return .runtime_error;
                        continue;
                    }

                    if (self.throwDynamicError("Runtime Error: super can only be called on instances.\n", .{}) != .ok) return .runtime_error;
                    continue;
                },
                .op_yield => {
                    const yield_arg_count = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const expected_args = frame.closure.function.arity;
                    const block_val = self.stack[frame.base_slot + expected_args + 1];

                    if (!block_val.isClosure()) {
                        if (self.throwDynamicError("Runtime Error: No block given to yield.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }

                    const block_closure = block_val.asClosure();
                    const args_ptr = self.stack.ptr + self.stack_top - yield_arg_count;
                    const yield_args = args_ptr[0..yield_arg_count];

                    // Safely propagate limits through native yields
                    const result = self.callClosureSync(block_closure, yield_args) catch |err| {
                        if (err == error.ExecutionLimitExceeded) return .execution_limit_exceeded;
                        if (err == error.BlockBreak) {
                            self.popAndRelease(yield_arg_count);
                            const break_val = self.pop();
                            self.closeUpvalues(&self.stack[frame.base_slot]);
                            self.shrinkStack(frame.base_slot);
                            std.debug.assert(self.frames.items.len > 0);
                            _ = self.frames.pop();
                            self.stack.ptr[self.stack_top] = break_val;
                            self.stack_top += 1;
                            if (self.frames.items.len == target_depth) return .ok;
                            continue;
                        }
                        return .runtime_error;
                    };

                    // Pop yielded args off stack
                    self.popAndRelease(yield_arg_count);
                    self.push(result);
                },
                .op_block_given => {
                    const expected_args = frame.closure.function.arity;
                    const block_val = self.stack[frame.base_slot + expected_args + 1];
                    self.push(value.Value.initBool(block_val.isClosure()));
                },
                .op_class_method, .op_class_method_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_class_method_wide);
                    const method = self.pop();
                    const receiver_val = self.stack[self.stack_top - 1]; // Peek at target

                    if (receiver_val.isClass()) {
                        receiver_val.asClass().class_methods.put(self.allocator, name_str, method) catch return .runtime_error;
                    } else if (receiver_val.isModule()) {
                        receiver_val.asModule().methods.put(self.allocator, name_str, method) catch return .runtime_error;
                    } else {
                        if (self.throwDynamicError("Runtime Error: Can only define singleton methods on classes or modules.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_get_class_var, .op_get_class_var_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_get_class_var_wide);
                    const receiver = self.pop(); // Explicitly pop receiver from stack

                    const class_obj = if (receiver.isInstance()) receiver.asInstance().class else if (receiver.isClass()) receiver.asClass() else null;

                    if (class_obj) |c| {
                        var current: ?*value.ObjClass = c;
                        var found_val: ?value.Value = null;

                        // Search up the hierarchy
                        while (current) |cls| {
                            if (cls.class_fields.get(name_str)) |val| {
                                found_val = val;
                                break;
                            }
                            current = cls.superclass;
                        }

                        if (found_val) |v| {
                            self.push(v);
                        } else {
                            if (self.throwDynamicError("Runtime Error: Undefined class variable '{s}'.\n", .{name_str}) != .ok) return .runtime_error;
                            continue;
                        }
                    } else {
                        if (self.throwDynamicError("Runtime Error: Receiver has no class context.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_set_class_var, .op_set_class_var_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_set_class_var_wide);
                    const receiver = self.pop(); // Pop explicit receiver
                    const val = self.pop(); // Pop RHS value

                    const class_obj = if (receiver.isInstance()) receiver.asInstance().class else if (receiver.isClass()) receiver.asClass() else null;

                    if (class_obj) |c| {
                        var current: ?*value.ObjClass = c;
                        var target_class: *value.ObjClass = c;

                        // Update the variable if it exists anywhere in the hierarchy
                        var found = false;
                        while (current) |cls| {
                            if (cls.class_fields.contains(name_str)) {
                                target_class = cls;
                                found = true;
                                break;
                            }
                            current = cls.superclass;
                        }

                        // If it's a new variable, bind it to the highest root class to ensure it is shared!
                        if (!found) {
                            var root = c;
                            while (root.superclass) |sup| {
                                root = sup;
                            }
                            target_class = root;
                        }

                        target_class.class_fields.put(self.allocator, name_str, val) catch return .runtime_error;

                        self.push(val); // Yield the assigned value
                    } else {
                        if (self.throwDynamicError("Runtime Error: Receiver has no class context.\n", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_is_instance => {
                    const class_val = self.pop();
                    const thrown_val = self.pop();

                    if (!class_val.isClass()) {
                        if (self.throwDynamicError("Runtime Error: Rescue type must be a Class.\n", .{}) != .ok) return .runtime_error;
                        continue;
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
                .op_defined, .op_defined_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_defined_wide);
                    var is_def = false;

                    if (std.mem.startsWith(u8, name_str, "@@")) {
                        // Class Variable Check: Grab `self` and walk the class hierarchy
                        const self_val = self.getLocal(frame, 0);
                        const class_obj = if (self_val.isInstance()) self_val.asInstance().class else if (self_val.isClass()) self_val.asClass() else null;
                        if (class_obj) |c| {
                            var current: ?*value.ObjClass = c;
                            while (current) |cls| {
                                if (cls.class_fields.contains(name_str)) {
                                    is_def = true;
                                    break;
                                }
                                current = cls.superclass;
                            }
                        }
                    } else if (std.mem.startsWith(u8, name_str, "@")) {
                        // Instance Variable Check: Strip `@` and check layout map
                        const self_val = self.getLocal(frame, 0);
                        if (self_val.isInstance()) {
                            const clean_name = name_str[1..];
                            is_def = self_val.asInstance().class.instance_layout.contains(clean_name);
                        }
                    } else {
                        // Global / Native Check
                        is_def = self.globals.contains(name_str);
                    }

                    self.push(if (is_def) value.Value.initBool(true) else value.Value.initNil());
                },
                .op_extract_kwarg, .op_extract_kwarg_wide => {
                    const map_slot = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;

                    const name_idx = self.readOperand(exec_chunk, frame, op == .op_extract_kwarg_wide);
                    var extracted = value.Value.initNil();

                    // Safely check if the caller provided a map
                    if (frame.base_slot + map_slot < self.stack_top) {
                        const map_val = self.stack[frame.base_slot + map_slot];
                        if (map_val.isObject() and map_val.asObj().obj_type == .map) {
                            const name_val = exec_chunk.constants.items[name_idx];
                            const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", map_val.asObj())));

                            // Use findMapKey natively
                            if (self.findMapKey(map, name_val)) |i| {
                                extracted = map.values.items[i];
                            }
                        }
                    }

                    self.push(extracted);
                },
                else => {
                    self.runtimeError("Runtime Error: Unhandled OpCode {}\n", .{op});
                    return .runtime_error;
                },
            }
        }
        return .ok;
    }

    // --- Allocators ---
    pub fn allocateString(self: *VM, chars: []const u8) !value.Value {
        if (self.strings.get(chars)) |existing| {
            return value.Value.initObj(&existing.obj);
        }

        // We must duplicate because the passed slice is likely a temporary stack buffer or constant
        const heap_chars = try self.allocator.dupe(u8, chars);
        return try self.allocateStringTakeOwnership(heap_chars);
    }

    pub fn allocateStringTakeOwnership(self: *VM, chars: []u8) !value.Value {
        // Use gc.takeString so the exact slice is adopted and not duped again!
        // This stops the memory leak immediately.
        const str_obj = try self.gc.takeString(self, chars);

        // Ensure it is protected from immediate GC
        const str_val = value.Value.initObj(&str_obj.obj);
        self.push(str_val);
        // (gc.takeString safely handles map insertion)
        _ = self.pop();
        return str_val;
    }

    pub fn allocateSymbol(self: *VM, chars: []const u8) !value.Value {
        const sym_obj = try self.gc.allocateSymbol(self, chars);
        return value.Value.initObj(&sym_obj.obj);
    }

    pub fn allocateGeometry(self: *VM, state: value.GeometryState) !value.Value {
        const geom_obj = try self.gc.allocateGeometry(self, state);
        return value.Value.initGeometry(geom_obj);
    }

    pub fn allocateWorkplane(self: *VM, parent: *value.ObjGeometry, origin: [3]f64, normal: [3]f64) !value.Value {
        const wp_obj = try self.gc.allocateWorkplane(self, parent, origin, normal);
        return value.Value.initWorkplane(wp_obj);
    }

    pub fn defineNative(self: *VM, name: []const u8, function: value.NativeFn) !void {
        const native_obj = try self.gc.allocateNative(self, function);
        const native_val = value.Value.initObj(&native_obj.obj);
        try self.ensureStackCapacity(self.stack_top + 1);
        self.push(native_val);
        try self.globals.put(self.allocator, name, native_val);
        _ = self.pop();
    }

    pub inline fn shrinkStack(self: *VM, target_slot: usize) void {
        std.debug.assert(self.stack_top >= target_slot);
        while (self.stack_top > target_slot) {
            self.stack_top -= 1;
        }
    }

    inline fn popAndRelease(self: *VM, count: usize) void {
        std.debug.assert(self.stack_top >= count);
        self.shrinkStack(self.stack_top - count);
    }

    pub fn resetStack(self: *VM) void {
        self.shrinkStack(0);
    }

    // --- JIT Materialization ---
    pub fn ensureConcrete(self: *VM, val: value.Value) !geom.GeometryHandle {
        if (!val.isGeometry()) return error.RuntimeError;
        var geometry = val.asGeometry();

        if (geometry.cached_handle) |handle| return handle;

        const handle = try dag_evaluator.evaluateDAG(self, geometry.dag_idx);
        geometry.cached_handle = handle;
        return handle;
    }

    pub fn ensureConcreteCrossSection(self: *VM, val: value.Value) !geom.CrossSectionHandle {
        if (!val.isCrossSection()) return error.RuntimeError;
        var cs = val.asCrossSection();
        if (cs.cached_handle) |handle| return handle;
        const handle = try dag_evaluator.evaluateCrossSectionDAG(self, cs.dag_idx);
        cs.cached_handle = handle;
        return handle;
    }

    fn captureUpvalue(self: *VM, local_ptr: *value.Value) !*value.ObjUpvalue {
        // Ensure the pointer is strictly within the VM's active stack memory
        std.debug.assert(@intFromPtr(local_ptr) >= @intFromPtr(self.stack.ptr));
        std.debug.assert(@intFromPtr(local_ptr) < @intFromPtr(self.stack.ptr + self.stack.len));

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
        const created_upvalue = try self.gc.allocateUpvalue(self, local_ptr, upvalue);

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
            // Ensure the location we are closing actually belongs to the VM stack!
            std.debug.assert(@intFromPtr(upvalue.location) >= @intFromPtr(self.stack.ptr));
            std.debug.assert(@intFromPtr(upvalue.location) < @intFromPtr(self.stack.ptr + self.stack.len));

            upvalue.closed = upvalue.location.*; // Move from Stack -> Heap
            upvalue.location = &upvalue.closed; // Repoint to internal field
            self.open_upvalues = upvalue.next; // Unlink from active list
        }
    }

    pub fn findMethod(self: *VM, class: *value.ObjClass, name: []const u8) ?value.Value {
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

    pub fn dispatchClosure(self: *VM, closure: *value.ObjClosure, arg_count: usize, base_slot: usize, is_constructor: bool) !void {
        if (self.frames.items.len >= self.max_call_frames) {
            self.runtimeError("Runtime Error: Call stack overflow (exceeded max frame depth of {d}).\n", .{self.max_call_frames});
            return error.RuntimeError;
        }
        try self.frames.ensureUnusedCapacity(self.allocator, 1);

        var provided_args = arg_count;
        var has_block = false;

        if (provided_args > 0 and self.stack[self.stack_top - 1].isClosure()) {
            has_block = true;
            provided_args -= 1;
        }

        const block_val = if (has_block) self.pop() else null;
        const expected_args = closure.function.arity;

        // Pad missing arguments so we strictly match `expected_args`
        if (provided_args < expected_args) {
            const missing = expected_args - provided_args;
            try self.ensureStackCapacity(self.stack_top + missing);

            // Trailing Map Heuristic for skipped Positional Defaults
            if (provided_args > 0) {
                const last_arg = self.stack[self.stack_top - 1];
                if (last_arg.isObject() and last_arg.asObj().obj_type == .map) {
                    const map_val = self.pop();
                    for (0..missing) |_| self.push(value.Value.initNil());
                    self.push(map_val); // Shift the kwargs map to the end
                } else {
                    for (0..missing) |_| self.push(value.Value.initNil());
                }
            } else {
                for (0..missing) |_| self.push(value.Value.initNil());
            }

            provided_args = expected_args;
        } else if (provided_args > expected_args and closure.function.splat_pos == null) {
            const excess = provided_args - expected_args;
            self.popAndRelease(excess);
            provided_args = expected_args;
        }

        // Safely Pack Splat Arguments in-place
        if (closure.function.splat_pos) |splat_pos| {
            const fixed_arity = splat_pos;
            const trailing_arity = expected_args - fixed_arity - 1;
            const splat_size = provided_args - fixed_arity - trailing_arity;

            const arr_obj = try self.gc.allocateArray(self);
            const arr_val = value.Value.initObj(&arr_obj.obj);
            try arr_obj.items.ensureTotalCapacity(self.allocator, splat_size);

            const start_idx = base_slot + 1 + fixed_arity;
            for (0..splat_size) |i| {
                const item = self.stack[start_idx + i];
                arr_obj.items.appendAssumeCapacity(item);
            }

            if (splat_size != 1 and trailing_arity > 0) {
                const dest = self.stack[start_idx + 1 .. start_idx + 1 + trailing_arity];
                const src = self.stack[start_idx + splat_size .. start_idx + splat_size + trailing_arity];
                if (@intFromPtr(dest.ptr) > @intFromPtr(src.ptr)) {
                    std.mem.copyBackwards(value.Value, dest, src);
                } else {
                    std.mem.copyForwards(value.Value, dest, src);
                }
            }

            self.stack[start_idx] = arr_val;
            self.stack_top = start_idx + 1 + trailing_arity;
        }

        // Restore the implicit block slot
        if (has_block) {
            self.push(block_val.?);
        } else {
            try self.ensureStackCapacity(self.stack_top + 1);
            self.push(value.Value.initNil());
        }

        // Pad Virtual Local Slots perfectly
        const total_locals = closure.function.local_count;
        const current_frame_size = self.stack_top - base_slot;
        if (total_locals > current_frame_size) {
            const locals_to_pad = total_locals - current_frame_size;
            try self.ensureStackCapacity(self.stack_top + locals_to_pad);
            for (0..locals_to_pad) |_| self.push(value.Value.initNil());
        }

        // --- PROFILER: Start Closure Timer ---
        if (self.profiler) |p| {
            const func_name = if (closure.function.name) |n| n.chars else "block";
            p.enterFrame(func_name) catch {};
        }

        try self.frames.append(self.allocator, .{
            .closure = closure,
            .ip = 0,
            .base_slot = base_slot,
            .is_constructor = is_constructor,
        });
    }

    pub fn callClosureSync(self: *VM, closure: *value.ObjClosure, args: []const value.Value) !value.Value {
        if (self.frames.items.len >= self.max_call_frames) {
            self.runtimeError("Runtime Error: Call stack overflow (exceeded max frame depth of {d}).\n", .{self.max_call_frames});
            return error.RuntimeError;
        }
        try self.frames.ensureUnusedCapacity(self.allocator, 1);

        const target_depth = self.frames.items.len;
        var provided_args = args.len;
        const expected_args = closure.function.arity;

        // Ensure stack capacity for closure, args, padded nils, and the implicit null block
        const total_pushes = 1 + @max(provided_args, expected_args) + 1;
        try self.ensureStackCapacity(self.stack_top + total_pushes);

        const base_slot = self.stack_top; // Record where the closure lands exactly

        self.push(value.Value.initObj(&closure.obj)); // closure itself

        for (args) |arg| self.push(arg);

        if (provided_args < expected_args) {
            const missing = expected_args - provided_args;

            // --- Trailing Map Heuristic for C++ Synchronous Calls ---
            if (provided_args > 0) {
                const last_arg = self.stack[self.stack_top - 1];
                if (last_arg.isObject() and last_arg.asObj().obj_type == .map) {
                    const map_val = self.pop();
                    for (0..missing) |_| self.push(value.Value.initNil());
                    self.push(map_val); // Shift the kwargs map to the end
                } else {
                    for (0..missing) |_| self.push(value.Value.initNil());
                }
            } else {
                for (0..missing) |_| self.push(value.Value.initNil());
            }
        } else if (provided_args > expected_args and closure.function.splat_pos == null) {
            const excess = provided_args - expected_args;
            self.popAndRelease(excess);
            provided_args = expected_args;
        }

        // Pad the implicit empty block
        self.push(value.Value.initNil());

        const total_locals = closure.function.local_count;
        const current_frame_size = self.stack_top - base_slot;

        if (total_locals > current_frame_size) {
            const locals_to_pad = total_locals - current_frame_size;
            try self.ensureStackCapacity(self.stack_top + locals_to_pad);
            for (0..locals_to_pad) |_| self.push(value.Value.initNil());
        }

        // --- PROFILER: Start Sync Closure Timer ---
        if (self.profiler) |p| {
            const func_name = if (closure.function.name) |n| n.chars else "block";
            p.enterFrame(func_name) catch {};
        }

        try self.frames.append(self.allocator, .{
            .closure = closure,
            .ip = 0,
            .base_slot = base_slot,
        });

        const res = self.runUntil(target_depth);

        // --- SAFE RE-ENTRANT UNWINDING ---
        if (res == .execution_limit_exceeded) return error.ExecutionLimitExceeded;
        if (res == .block_break) return error.BlockBreak;
        if (res == .runtime_error) return error.FatalError;
        if (self.frames.items.len < target_depth) return error.Unwind; // A rescue block ate our frame
        if (res != .ok) return error.FatalError;

        return self.pop();
    }

    pub fn allocateCrossSection(self: *VM, dag_idx: u32) !value.Value {
        const cs_obj = try self.gc.allocateCrossSection(self, dag_idx);
        return value.Value.initCrossSection(cs_obj);
    }

    // --- Shared Execution Helpers ---
    pub fn valuesEqual(self: *VM, a: value.Value, b: value.Value) bool {
        _ = self;
        if (a.isNumber() and b.isNumber()) return a.asNumber() == b.asNumber();

        if (a.isObject() and b.isObject()) {
            if (a.asObj() == b.asObj()) return true;
        }

        return a.isEqual(b);
    }

    pub fn findMapKey(self: *VM, map: *value.ObjMap, key: value.Value) ?usize {
        for (map.keys.items, 0..) |k, i| {
            if (self.valuesEqual(k, key)) return i;
        }
        return null;
    }

    fn executeBinaryArithmetic(self: *VM, op: chunk.OpCode) InterpretResult {
        const b_val = self.pop();
        const a_val = self.pop();
        if (a_val.isNumber() and b_val.isNumber()) {
            const res = switch (op) {
                .op_add => a_val.asNumber() + b_val.asNumber(),
                .op_subtract => a_val.asNumber() - b_val.asNumber(),
                .op_bitwise_and => @as(f64, @floatFromInt(@as(i64, @intFromFloat(a_val.asNumber())) & @as(i64, @intFromFloat(b_val.asNumber())))),
                else => unreachable,
            };
            self.push(value.Value.initNumber(res));
            return .ok;
        } else if (op == .op_add and a_val.isObject() and b_val.isObject() and a_val.asObj().obj_type == .string and b_val.asObj().obj_type == .string) {
            const a_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", a_val.asObj()))).chars;
            const b_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", b_val.asObj()))).chars;

            // Allocates a brand new slice on the heap.
            const merged = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ a_str, b_str }) catch return .runtime_error;

            // Pass ownership directly to the VM! No double-duping!
            const str_val = self.allocateStringTakeOwnership(merged) catch return .runtime_error;

            self.push(str_val);
            return .ok;
        } else if (op == .op_add and a_val.isObject() and b_val.isObject() and a_val.asObj().obj_type == .array and b_val.asObj().obj_type == .array) {
            const a_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", a_val.asObj())));
            const b_arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", b_val.asObj())));
            const new_arr = self.gc.allocateArray(self) catch return .runtime_error;
            const new_val = value.Value.initObj(&new_arr.obj);
            new_arr.items.ensureTotalCapacity(self.allocator, a_arr.items.items.len + b_arr.items.items.len) catch return .runtime_error;
            for (a_arr.items.items) |item| {
                new_arr.items.appendAssumeCapacity(item);
            }
            for (b_arr.items.items) |item| {
                new_arr.items.appendAssumeCapacity(item);
            }
            self.push(new_val);
            return .ok;
        } else if (self.host.binary_handler) |handler| {
            const result = handler(self, op, a_val, b_val) catch {
                return self.throwDynamicError("Runtime Error: CSG Binary Operation Failed", .{});
            };

            self.stack.ptr[self.stack_top] = result;
            self.stack_top += 1;
            return .ok;
        } else {
            const op_symbol = if (op == .op_add) "+" else "-";
            return self.throwDynamicError("Runtime Error: Invalid operands for '{s}'", .{op_symbol});
        }
    }

    inline fn executeNumericBinary(self: *VM, op: chunk.OpCode) InterpretResult {
        const nums = self.popBinaryNumbers() catch {
            return self.throwDynamicError("Runtime Error: Invalid operands for math operation.", .{});
        };
        switch (op) {
            .op_multiply => self.push(value.Value.initNumber(nums[0] * nums[1])),
            .op_divide => {
                if (nums[1] == 0.0) return self.throwDynamicError("ZeroDivisionError: Division by zero.\n", .{});
                self.push(value.Value.initNumber(nums[0] / nums[1]));
            },
            .op_modulo => {
                if (nums[1] == 0.0) return self.throwDynamicError("ZeroDivisionError: Modulo by zero.\n", .{});
                self.push(value.Value.initNumber(@mod(nums[0], nums[1])));
            },
            .op_exponent => self.push(value.Value.initNumber(std.math.pow(f64, nums[0], nums[1]))),
            .op_less => self.push(value.Value.initBool(nums[0] < nums[1])),
            .op_greater => self.push(value.Value.initBool(nums[0] > nums[1])),
            else => unreachable,
        }
        return .ok;
    }

    inline fn executeInvoke(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk, is_wide: bool) InterpretResult {
        // Use new string operand reader
        const method_name_str = self.readStringOperand(exec_chunk, frame, is_wide);
        const arg_count = exec_chunk.code.items[frame.ip];
        frame.ip += 1;

        // Prevent usize underflow if stack is corrupted
        std.debug.assert(self.stack_top > arg_count);

        // Read IC
        const ic = self.readInlineCache(exec_chunk, frame);

        const base_slot = self.stack_top - 1 - arg_count;
        const receiver = self.stack[base_slot];
        const args_ptr = self.stack.ptr + base_slot + 1;

        // Resolve Class of Receiver seamlessly
        const class_obj: ?*value.ObjClass = self.getClass(receiver);

        // --- 1. METHOD LOOKUP (Takes precedence over raw property fields) ---
        var method_val: ?value.Value = null;
        var is_private_call = false;

        if (receiver.isClass()) {
            method_val = self.findClassMethod(receiver.asClass(), method_name_str);

            if (method_val == null and std.mem.eql(u8, method_name_str, "new")) {
                const class_to_instantiate = receiver.asClass();
                const instance = self.gc.allocateInstance(self, class_to_instantiate) catch return .runtime_error;
                self.stack.ptr[base_slot] = value.Value.initObj(&instance.obj); // Overwrite class with instance safely

                if (self.findMethod(class_to_instantiate, "initialize")) |init_method| {
                    if (init_method.isClosure()) {
                        self.dispatchClosure(init_method.asClosure(), arg_count, base_slot, true) catch return .runtime_error;
                        return .ok;
                    } else if (init_method.isNative()) {
                        const native_obj = init_method.asNative();
                        _ = native_obj.function(self, arg_count, args_ptr) catch {
                            return self.throwDynamicError("Runtime Error: Native Constructor Error", .{});
                        };
                        self.popAndRelease(arg_count);
                        return .ok;
                    }
                }

                if (arg_count > 0) {
                    return self.throwDynamicError("Runtime Error: Expected 0 args for default constructor.\n", .{});
                }
                return .ok;
            } else if (method_val == null) {
                var buf: [256]u8 = undefined;
                const priv_name = std.fmt.bufPrint(&buf, "@private:{s}", .{method_name_str}) catch "";
                method_val = self.findClassMethod(receiver.asClass(), priv_name);
                if (method_val != null) is_private_call = true;
            }

            // Fallback to Object methods (so Class.responds_to? works)
            if (method_val == null and self.object_class != null) {
                method_val = self.findMethod(self.object_class.?, method_name_str);
            }
        } else if (receiver.isModule()) {
            // Fallback to Object methods for modules
            if (self.object_class != null) {
                method_val = self.findMethod(self.object_class.?, method_name_str);
            }
        } else if (class_obj) |c| {
            method_val = self.findMethodCached(c, method_name_str, ic);
            if (method_val == null) {
                var buf: [256]u8 = undefined;
                const priv_name = std.fmt.bufPrint(&buf, "@private:{s}", .{method_name_str}) catch "";
                method_val = self.findMethod(c, priv_name);
                if (method_val != null) is_private_call = true;
            }
        }

        // --- ENFORCE VISIBILITY ---
        if (is_private_call) {
            const current_self = self.stack[frame.base_slot];
            if (!self.valuesEqual(receiver, current_self)) {
                return self.throwDynamicError("NoMethodError: private method '{s}' called.\n", .{method_name_str});
            }
        }

        // Dispatch Method if Found
        if (method_val) |m_val| {
            if (m_val.isNative()) {
                return self.executeNative(m_val.asNative(), arg_count, args_ptr, method_name_str);
            } else if (m_val.isClosure()) {
                self.dispatchClosure(m_val.asClosure(), arg_count, base_slot, false) catch return .runtime_error;
                return .ok;
            }
        }

        // --- 2. PROPERTY FALLBACK (Instances only when no method matches) ---
        if (receiver.isInstance() and arg_count == 0) {
            const instance = receiver.asInstance();

            if (instance.class.instance_layout.get(method_name_str)) |idx| {
                ic.class = instance.class;
                ic.offset = idx;

                self.popAndRelease(1); // Pop receiver
                if (idx < instance.fields.items.len) {
                    self.push(instance.fields.items[idx]);
                } else {
                    self.push(value.Value.initNil());
                }
                return .ok;
            }
        }

        // --- 3. FALLBACK: NATIVE C++ KERNEL METHODS (Geometry) ---
        if (self.host.invoke_handler) |handler| {
            const result = handler(self, receiver, method_name_str, arg_count, args_ptr) catch {
                return self.throwDynamicError("Runtime Error: CAD Kernel / Method Error", .{});
            };

            self.popAndRelease(arg_count + 1);

            // Absorb the native +1 reference directly
            self.stack.ptr[self.stack_top] = result;
            self.stack_top += 1;
            return .ok;
        } else {
            self.runtimeError("Runtime Error: No invoke handler registered for method '{s}'.\n", .{method_name_str});
            return .runtime_error;
        }
    }

    inline fn executeUnpackSplat(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk) InterpretResult {
        const pre_count = exec_chunk.code.items[frame.ip];
        const post_count = exec_chunk.code.items[frame.ip + 1];
        frame.ip += 2;

        const val = self.pop();

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
                arr_obj.items.append(self.allocator, val) catch return .runtime_error;
                _ = self.pop();
                self.push(value.Value.initObj(&arr_obj.obj));
            }
        }
        return .ok;
    }

    inline fn executePackSplat(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk) InterpretResult {
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
            arr_obj.items.appendAssumeCapacity(item);
        }

        // Shift any trailing arguments down to close the gap left by the packed arguments
        if (splat_size != 1) {
            // Ensure we never slice past the VM's active stack top
            std.debug.assert(start_idx + 1 + trailing_arity <= self.stack.len);
            std.debug.assert(start_idx + splat_size + trailing_arity <= self.stack.len);

            const dest = self.stack[start_idx + 1 .. start_idx + 1 + trailing_arity];
            const src = self.stack[start_idx + splat_size .. start_idx + splat_size + trailing_arity];
            if (@intFromPtr(dest.ptr) > @intFromPtr(src.ptr)) {
                std.mem.copyBackwards(value.Value, dest, src);
            } else {
                std.mem.copyForwards(value.Value, dest, src);
            }
        }

        // Rewrite the stack to hold the new Array in the splat parameter's slot
        self.stack[start_idx] = arr_val;
        self.stack_top = start_idx + 1 + trailing_arity;

        // Push the block back on top to maintain the Uniform Padding invariant
        self.push(block_val);

        return .ok;
    }

    inline fn executeBuildRange(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk) InterpretResult {
        const is_exclusive = exec_chunk.code.items[frame.ip] == 1;
        frame.ip += 1;

        const step_val = self.pop();
        const end_val = self.pop();
        const start_val = self.pop();

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
                    arr_obj.items.append(self.allocator, char_str) catch return .runtime_error;
                }
            } else {
                self.runtimeError("Runtime Error: String ranges must be single characters.\n", .{});
                return .runtime_error;
            }
        } else {
            self.runtimeError("Runtime Error: Range bounds must be numbers or characters.\n", .{});
            return .runtime_error;
        }
        return .ok;
    }

    inline fn resolveArrayIndex(self: *VM, arr_len: usize, index_val: value.Value) !usize {
        _ = self;
        const num_idx = index_val.asNumber();

        // Prevent floats like `1.5` or `NaN` from succeeding
        if (std.math.isNan(num_idx) or std.math.trunc(num_idx) != num_idx) {
            return error.RuntimeError;
        }

        if (num_idx < 0) {
            const offset = @as(usize, @intFromFloat(-num_idx));
            if (offset == 0 or offset > arr_len) return error.RuntimeError;
            return arr_len - offset;
        } else {
            const idx = @as(usize, @intFromFloat(num_idx));
            if (idx >= arr_len) return error.RuntimeError;
            return idx;
        }
    }

    // --- Centralized Type & Operand Resolution Helpers ---

    /// Unified Receiver Type-to-Class resolution used by executeInvoke and Native methods
    pub inline fn getClass(self: *VM, receiver: value.Value) ?*value.ObjClass {
        if (receiver.isInstance()) {
            return receiver.asInstance().class;
        } else if (receiver.isGeometry()) {
            return self.geometry_class;
        } else if (receiver.isCrossSection()) {
            return self.cross_section_class;
        } else if (receiver.isObject()) {
            switch (receiver.asObj().obj_type) {
                .string => return self.string_class,
                .symbol => return self.symbol_class,
                .array => return self.array_class,
                .map => return self.map_class,
                else => return null,
            }
        } else if (receiver.isNumber()) {
            return self.number_class;
        } else if (receiver.isBool()) {
            return self.boolean_class;
        }
        return null;
    }

    /// Centralized Truthiness definition (Only nil and false are falsey)
    pub inline fn isFalsey(val: value.Value) bool {
        return val.isNil() or (val.isBool() and !val.asBool());
    }

    /// Extracts a String constant from the bytecode stream
    inline fn readStringObjectOperand(self: *VM, exec_chunk: *chunk.Chunk, frame: *CallFrame, is_wide: bool) *value.ObjString {
        const name_idx = self.readOperand(exec_chunk, frame, is_wide);
        const name_val = exec_chunk.constants.items[name_idx];
        return @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", name_val.asObj())));
    }

    /// Extracts a String character slice from the bytecode stream
    inline fn readStringOperand(self: *VM, exec_chunk: *chunk.Chunk, frame: *CallFrame, is_wide: bool) []const u8 {
        return self.readStringObjectOperand(exec_chunk, frame, is_wide).chars;
    }

    inline fn readOperand(self: *VM, exec_chunk: *chunk.Chunk, frame: *CallFrame, is_wide: bool) u16 {
        _ = self;
        if (is_wide) {
            std.debug.assert(frame.ip + 2 <= exec_chunk.code.items.len); // Hardened check
            const high = @as(u16, exec_chunk.code.items[frame.ip]);
            const low = @as(u16, exec_chunk.code.items[frame.ip + 1]);
            frame.ip += 2;
            return (high << 8) | low;
        } else {
            std.debug.assert(frame.ip + 1 <= exec_chunk.code.items.len); // Hardened check
            const idx = exec_chunk.code.items[frame.ip];
            frame.ip += 1;
            return idx;
        }
    }

    inline fn readJumpOffset(self: *VM, exec_chunk: *chunk.Chunk, frame: *CallFrame) usize {
        _ = self;
        std.debug.assert(frame.ip + 4 <= exec_chunk.code.items.len); // Hardened check
        const b3 = @as(usize, exec_chunk.code.items[frame.ip]);
        const b2 = @as(usize, exec_chunk.code.items[frame.ip + 1]);
        const b1 = @as(usize, exec_chunk.code.items[frame.ip + 2]);
        const b0 = @as(usize, exec_chunk.code.items[frame.ip + 3]);
        frame.ip += 4;
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
    }

    inline fn executeCall(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk) InterpretResult {
        const arg_count = exec_chunk.code.items[frame.ip];
        frame.ip += 1;

        const base_slot = self.stack_top - 1 - arg_count;
        const callee = self.stack[base_slot];

        if (callee.isNative()) {
            const args_ptr = self.stack.ptr + base_slot + 1;
            return self.executeNative(callee.asNative(), arg_count, args_ptr, "native_call");
        } else if (callee.isClosure()) {
            self.dispatchClosure(callee.asClosure(), arg_count, base_slot, false) catch return .runtime_error;
        } else if (callee.isClass()) {
            const class_obj = callee.asClass();
            const instance = self.gc.allocateInstance(self, class_obj) catch return .runtime_error;
            self.stack.ptr[base_slot] = value.Value.initObj(&instance.obj);

            if (self.findMethod(class_obj, "initialize")) |init_method| {
                self.dispatchClosure(init_method.asClosure(), arg_count, base_slot, false) catch return .runtime_error;
            } else if (arg_count > 0) {
                self.runtimeError("Runtime Error: Expected 0 args for default constructor.\n", .{});
                return .runtime_error;
            }
        } else {
            return self.throwDynamicError("Runtime Error: Can only call functions and classes.", .{});
        }
        return .ok;
    }

    inline fn executeNative(self: *VM, native_obj: *value.ObjNative, arg_count: u8, args_ptr: [*]value.Value, func_name: []const u8) InterpretResult {
        // --- PROFILER: Native Enter ---
        if (self.profiler) |p| p.enterFrame(func_name) catch {};

        const result = native_obj.function(self, arg_count, args_ptr) catch |err| {
            if (self.profiler) |p| p.exitFrame() catch {};
            if (err == error.ExecutionLimitExceeded) return .execution_limit_exceeded;
            if (err == error.Unwind) return .ok;
            if (err == error.FatalError) return .runtime_error;
            return self.throwDynamicError("Runtime Error: Native Execution Error", .{});
        };

        // --- PROFILER: Native Exit ---
        if (self.profiler) |p| p.exitFrame() catch {};

        self.popAndRelease(arg_count + 1);
        self.stack.ptr[self.stack_top] = result;
        self.stack_top += 1;
        return .ok;
    }

    inline fn executeThrow(self: *VM) InterpretResult {
        const err_val = self.pop();
        if (self.rescue_frames.items.len == 0) {
            // We removed the [Uncaught Exception] header!
            if (err_val.isObject() and err_val.asObj().obj_type == .string) {
                const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", err_val.asObj()))).chars;
                self.reportError("\nRuntimeError: {s}\n", .{str});
                self.printStacktrace();
            } else if (err_val.isInstance()) {
                const inst = err_val.asInstance();
                var printed = false;

                // Format: ClassName: Message
                if (inst.class.instance_layout.get("message")) |idx| {
                    if (idx < inst.fields.items.len) {
                        const msg_val = inst.fields.items[idx];
                        if (msg_val.isObject() and msg_val.asObj().obj_type == .string) {
                            const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", msg_val.asObj()))).chars;
                            self.reportError("\n{s}: {s}\n", .{ inst.class.name.chars, str });
                            printed = true;
                        }
                    }
                }
                if (!printed) self.reportError("\n{s}\n", .{inst.class.name.chars});

                // Print First-Class Backtrace seamlessly
                var printed_bt = false;
                if (inst.class.instance_layout.get("backtrace")) |bt_idx| {
                    if (bt_idx < inst.fields.items.len) {
                        const bt_val = inst.fields.items[bt_idx];
                        if (bt_val.isObject() and bt_val.asObj().obj_type == .array) {
                            const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", bt_val.asObj())));
                            for (arr_obj.items.items) |frame_val| {
                                if (frame_val.isObject() and frame_val.asObj().obj_type == .string) {
                                    const frame_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", frame_val.asObj()))).chars;
                                    self.reportError("{s}\n", .{frame_str});
                                }
                            }
                            printed_bt = true;
                        }
                    }
                }

                if (!printed_bt) self.printStacktrace();
            } else {
                self.reportError("\nUnknown error.\n", .{});
                self.printStacktrace();
            }
            return .runtime_error;
        }

        const r_frame = self.rescue_frames.pop().?;
        self.closeUpvalues(&self.stack[r_frame.stack_top]);

        while (self.frames.items.len > r_frame.frame_count) {
            _ = self.frames.pop();
        }

        self.shrinkStack(r_frame.stack_top);
        self.push(err_val);
        self.frames.items[self.frames.items.len - 1].ip = r_frame.handler_ip;

        return .ok;
    }

    /// Zero-allocation lookup for String and Symbol map keys
    pub fn findMapKeyByString(self: *VM, map: *value.ObjMap, search_str: []const u8) ?usize {
        _ = self; // Included for future-proofing or if VM context is needed later
        for (map.keys.items, 0..) |k, i| {
            if (k.isObject()) {
                if (k.asObj().obj_type == .string) {
                    const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj())));
                    if (std.mem.eql(u8, str.chars, search_str)) return i;
                } else if (k.asObj().obj_type == .symbol) {
                    const sym = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj())));
                    if (std.mem.eql(u8, sym.chars, search_str)) return i;
                }
            }
        }
        return null;
    }

    pub fn valuesCaseEqual(self: *VM, case_val: value.Value, test_val: value.Value) bool {
        if (case_val.isClass()) {
            if (test_val.isInstance()) {
                return isSubclassOf(test_val.asInstance().class, case_val.asClass());
            } else if (test_val.isObject()) {
                const c = case_val.asClass();
                switch (test_val.asObj().obj_type) {
                    .string => return c == self.string_class,
                    .array => return c == self.array_class,
                    .map => return c == self.map_class,
                    .symbol => return c == self.symbol_class,
                    else => return false,
                }
            } else if (test_val.isNumber()) {
                return case_val.asClass() == self.number_class;
            }
            return false;
        } else if (case_val.isObject() and case_val.asObj().obj_type == .range) {
            const range = @as(*value.ObjRange, @alignCast(@fieldParentPtr("obj", case_val.asObj())));
            if (!test_val.isNumber()) return false;
            const n = test_val.asNumber();
            if (range.is_exclusive) {
                return n >= range.start and n < range.end;
            } else {
                return n >= range.start and n <= range.end;
            }
        }

        // Fallback to standard equality
        return self.valuesEqual(case_val, test_val);
    }

    inline fn getPropertyCached(self: *VM, instance: *value.ObjInstance, name_str: []const u8, ic: *chunk.InlineCache) ?value.Value {
        _ = self;
        var offset: usize = 0;

        // Fast Path (O(1) Array Read)
        if (ic.class == instance.class) {
            offset = ic.offset;
        }
        // Slow Path (Hash Map Lookup)
        else if (instance.class.instance_layout.get(name_str)) |idx| {
            ic.class = instance.class;
            ic.offset = idx;
            offset = idx;
        } else {
            // Uninitialized instance variables gracefully return nil
            return value.Value.initNil();
        }

        if (offset < instance.fields.items.len) {
            return instance.fields.items[offset];
        } else {
            return value.Value.initNil();
        }
    }

    pub fn setInstanceField(self: *VM, instance: *value.ObjInstance, name: []const u8, val: value.Value, ic: ?*chunk.InlineCache) !void {
        var idx: usize = 0;

        // Fast Path
        if (ic != null and ic.?.class == instance.class) {
            idx = ic.?.offset;
        }
        // Slow Path
        else {
            if (instance.class.instance_layout.get(name)) |existing_idx| {
                idx = existing_idx;
            } else {
                idx = instance.class.instance_layout.count();
                try instance.class.instance_layout.put(self.allocator, name, idx);
            }
            if (ic) |cache| {
                cache.class = instance.class;
                cache.offset = idx;
            }
        }

        // Ensure the instance's flat array is large enough
        if (idx >= instance.fields.items.len) {
            const old_len = instance.fields.items.len;
            try instance.fields.resize(self.allocator, idx + 1);
            for (old_len..idx) |i| instance.fields.items[i] = value.Value.initNil();
        }

        instance.fields.items[idx] = val;
    }

    fn popBinaryNumbers(self: *VM) !struct { f64, f64 } {
        const b = self.pop();
        const a = self.pop();

        if (a.isNumber() and b.isNumber()) {
            return .{ a.asNumber(), b.asNumber() };
        }

        return error.RuntimeError;
    }

    pub fn findClassMethod(self: *VM, class: *value.ObjClass, name: []const u8) ?value.Value {
        _ = self;
        var current: ?*value.ObjClass = class;
        while (current) |c| {
            if (c.class_methods.get(name)) |method| return method;
            current = c.superclass;
        }
        return null;
    }

    pub fn isSubclassOf(class: *value.ObjClass, superclass: *value.ObjClass) bool {
        var current: ?*value.ObjClass = class;
        while (current) |c| {
            if (c == superclass) return true;
            current = c.superclass;
        }
        return false;
    }

    pub fn throwDynamicError(self: *VM, comptime fmt: []const u8, args: anytype) InterpretResult {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "Runtime Error";

        // Try to instantiate a real `RuntimeError` object so it can be rescued natively
        if (self.globals.get("RuntimeError")) |rt_class_val| {
            if (rt_class_val.isClass()) {
                if (self.gc.allocateInstance(self, rt_class_val.asClass())) |inst| {
                    if (self.allocateString(msg)) |str_val| {
                        self.push(value.Value.initObj(&inst.obj));
                        self.setInstanceField(inst, "message", str_val, null) catch {};

                        // --- EAGER BACKTRACE CAPTURE ---
                        if (self.buildBacktrace()) |bt_arr| {
                            self.push(value.Value.initObj(&bt_arr.obj)); // Protect during assignment
                            self.setInstanceField(inst, "backtrace", value.Value.initObj(&bt_arr.obj), null) catch {};
                            _ = self.pop();
                        } else |_| {}

                        _ = self.pop();

                        self.push(value.Value.initObj(&inst.obj));
                        return self.executeThrow();
                    } else |_| {}
                } else |_| {}
            }
        }

        // Fallback to string if the standard library isn't loaded yet
        if (self.allocateString(msg)) |err_val| {
            self.push(err_val);
            return self.executeThrow();
        } else |_| {
            self.runtimeError("Fatal: OOM while throwing exception.\n", .{});
            return .runtime_error;
        }
    }

    pub fn runtimeError(self: *VM, comptime fmt: []const u8, args: anytype) void {
        self.reportError(fmt, args);
        self.printStacktrace(); // Append the exact line and column
    }

    pub fn reportError(self: *VM, comptime fmt: []const u8, args: anytype) void {
        if (!self.mute_errors) {
            std.debug.print(fmt, args);
        }
    }

    // --- Error Formatting Engine ---
    fn printStacktrace(self: *VM) void {
        var i: usize = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.frames.items[i];
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(frame.closure.function.chunk.?)));

            const instruction_ip = if (frame.ip > 0) frame.ip - 1 else 0;
            const source_offset = exec_chunk.getOffset(instruction_ip);
            const func_name = if (frame.closure.function.name) |n| n.chars else "script";

            if (self.line_index) |li| {
                const line = li.getLine(source_offset) + 1;
                const col = li.getUtf8Column(source_offset) + 1;
                self.reportError("    from script:{d}:{d}:in '{s}'\n", .{ line, col, func_name });
            } else {
                self.reportError("    from script:offset {d}:in '{s}'\n", .{ source_offset, func_name });
            }
        }
    }

    // --- First-Class Error Backtraces ---
    pub fn buildBacktrace(self: *VM) !*value.ObjArray {
        const arr_obj = try self.gc.allocateArray(self);
        self.push(value.Value.initObj(&arr_obj.obj)); // Protect array from GC
        defer _ = self.pop();

        var i: usize = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.frames.items[i];
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(frame.closure.function.chunk.?)));

            const instruction_ip = if (frame.ip > 0) frame.ip - 1 else 0;
            const source_offset = exec_chunk.getOffset(instruction_ip);
            const func_name = if (frame.closure.function.name) |n| n.chars else "script";

            var buf: [256]u8 = undefined;
            var trace_str: []const u8 = "";

            if (self.line_index) |li| {
                const line = li.getLine(source_offset) + 1;
                const col = li.getUtf8Column(source_offset) + 1;
                trace_str = std.fmt.bufPrint(&buf, "    from script:{d}:{d}:in '{s}'", .{ line, col, func_name }) catch "    from unknown";
            } else {
                trace_str = std.fmt.bufPrint(&buf, "    from script:offset {d}:in '{s}'", .{ source_offset, func_name }) catch "    from unknown";
            }

            const str_val = try self.allocateString(trace_str);
            try arr_obj.items.append(self.allocator, str_val);
        }

        return arr_obj;
    }

    // --- Safe FFI Pointer Extraction ---
    pub inline fn getReceiver(self: *VM, args: [*]value.Value) value.Value {
        const stack_start = @intFromPtr(self.stack.ptr);
        const args_ptr = @intFromPtr(args);

        // Ensure `args` points strictly inside our allocated VM stack,
        // and is at least 1 slot above the bottom so `args - 1` can never underflow.
        std.debug.assert(args_ptr > stack_start);
        std.debug.assert(args_ptr <= @intFromPtr(self.stack.ptr + self.stack.len));

        return (args - 1)[0];
    }

    // --- Inline Caching Helpers ---

    inline fn readInlineCache(self: *VM, exec_chunk: *chunk.Chunk, frame: *CallFrame) *chunk.InlineCache {
        _ = self;
        std.debug.assert(frame.ip + 2 <= exec_chunk.code.items.len); // Hardened check
        const ic_high = @as(u16, exec_chunk.code.items[frame.ip]);
        const ic_low = @as(u16, exec_chunk.code.items[frame.ip + 1]);
        frame.ip += 2;
        const ic_idx = (ic_high << 8) | ic_low;
        return &exec_chunk.inline_caches.items[ic_idx];
    }

    inline fn findMethodCached(self: *VM, class: *value.ObjClass, name: []const u8, ic: *chunk.InlineCache) ?value.Value {
        // Fast Path
        if (ic.class == class) {
            if (!ic.cached_value.isNil()) return ic.cached_value;
        }
        // Slow Path (Traverse inheritance hierarchy)
        if (self.findMethod(class, name)) |method_val| {
            ic.class = class;
            ic.cached_value = method_val;
            return method_val;
        }
        return null;
    }
};
