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
    host: Host = .{},
    active_kernel: ?*const kernel_mod.GeometryKernel = null,
    dag_builder: dag.DAGBuilder,

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
            .dag_builder = dag.DAGBuilder.init(allocator),
        };
    }

    pub fn deinit(self: *VM) void {
        self.resetStack();
        self.gc.collectGarbage(self, true);
        self.dag_builder.deinit();
        self.allocator.free(self.stack);
        self.globals.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    // --- Dynamic Stack Operations ---

    pub inline fn push(self: *VM, val: value.Value) void {
        std.debug.assert(self.stack_top < self.stack.len);
        self.retainValue(val);
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
        self.retainValue(val);
        self.releaseValue(self.stack[absolute_slot]);
        self.stack[absolute_slot] = val;
    }

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
                    self.push(frame.chunk.constants.items[const_idx]);
                },
                .op_nil => self.push(value.Value.initNil()),
                .op_true => self.push(value.Value.initBool(true)),
                .op_false => self.push(value.Value.initBool(false)),
                .op_pop => {
                    const dropped = self.pop();
                    self.releaseValue(dropped);
                },
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
                        std.log.err("Runtime Error: Invalid operands for '+'\n", .{});
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
                        std.log.err("Runtime Error: Invalid operands for '-'\n", .{});
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

                        var i: usize = 0;
                        while (i <= arg_count) : (i += 1) {
                            const dropped = self.pop();
                            self.releaseValue(dropped);
                        }

                        self.stack.ptr[self.stack_top] = result;
                        self.stack_top += 1;
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
                    const method_name_val = frame.chunk.constants.items[method_name_idx];
                    const method_name_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", method_name_val.asObj()))).chars;
                    const receiver = self.stack[self.stack_top - 1 - arg_count];
                    const args_ptr = self.stack.ptr + self.stack_top - arg_count;
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
                        std.log.err("Runtime Error: No invoke handler registered for method '{s}'.\n", .{method_name_str});
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

    // --- Allocators ---

    pub fn allocateString(self: *VM, chars: []const u8) !value.Value {
        if (self.gc.bytes_allocated > self.gc.next_gc_threshold) {
            self.gc.collectGarbage(self, false);
        }
        const str_obj = try self.gc.allocateString(chars);
        return value.Value.initObj(&str_obj.obj);
    }

    pub fn allocateGeometry(self: *VM, state: value.GeometryState) !value.Value {
        const ptr = try self.allocator.create(value.ObjGeometry);
        ptr.* = .{
            .obj = .{
                .obj_type = .geometry,
                .is_marked = false,
                .next = null,
            },
            .ref_count = 1, // Creates a +1 owned reference
            .dag_idx = switch (state) {
                .symbolic => |idx| idx,
                .concrete => 0,
            },
            .cached_handle = switch (state) {
                .symbolic => null,
                .concrete => |h| h,
            },
            .cached_bbox = null,
        };
        return value.Value.initGeometry(ptr);
    }

    pub fn defineNative(self: *VM, name: []const u8, function: value.NativeFn) !void {
        const native_obj = try self.gc.allocateNative(function);
        const native_val = value.Value.initObj(&native_obj.obj);
        try self.ensureStackCapacity(self.stack_top + 1);
        self.push(native_val);
        try self.globals.put(self.allocator, name, native_val);
        const dropped = self.pop();
        self.releaseValue(dropped);
    }

    // --- ARC Helpers ---

    pub inline fn retainValue(self: *VM, val: value.Value) void {
        _ = self;
        if (val.isGeometry()) {
            val.asGeometry().ref_count += 1;
        }
    }

    pub inline fn releaseValue(self: *VM, val: value.Value) void {
        if (val.isGeometry()) {
            const geom_obj = val.asGeometry();
            std.debug.assert(geom_obj.ref_count > 0);
            geom_obj.ref_count -= 1;
            if (geom_obj.ref_count == 0) {
                self.freeGeometry(geom_obj);
            }
        }
    }

    fn freeGeometry(self: *VM, geom_obj: *value.ObjGeometry) void {
        if (geom_obj.cached_handle) |handle| {
            if (self.host.mesh_destructor) |destructor| {
                destructor(handle);
            }
        }
        self.allocator.destroy(geom_obj);
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
            std.log.err("Runtime Error: No geometry kernel active\n", .{});
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
};
