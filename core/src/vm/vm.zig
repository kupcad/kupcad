//! `VM`: the bytecode interpreter. It verifies a chunk and runs it (`interpret`), with call
//! frames, rescue frames and inline caches; keeps the globals, modules and classes; records
//! geometry as DAG nodes and evaluates them on demand (`ensureConcrete`); and raises runtime
//! errors (`raiseError`).

const std = @import("std");
const builtin = @import("builtin");
const chunk = @import("chunk.zig");
const memory = @import("memory.zig");
const dag = @import("dag.zig");
const error_kind = @import("error_kind.zig");
pub const ErrorKind = error_kind.ErrorKind;
const verifier = @import("verifier.zig");
const limits = @import("../core/limits.zig");
const value = @import("../core/value.zig");
const parameters = @import("../core/parameters.zig");
const host_mod = @import("host.zig");
const geom = @import("../kernel/geometry_handle.zig");
const dag_evaluator = @import("dag_evaluator.zig");
const profiler_mod = @import("profiler.zig");
const material_mod = @import("../core/material.zig");
const kernel = @import("../kernel/kernel.zig");
const Vfs = @import("../vfs/vfs.zig").Vfs;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const LineIndex = @import("../core/line_index.zig").LineIndex;
const EngineConfig = @import("../core/engine_config.zig").EngineConfig;
const sequence = @import("sequence.zig");
const owned_keys = @import("../core/owned_keys.zig");

const log = std.log.scoped(.vm);

pub const Host = host_mod.Host;

/// Stack slots every native call may push (GC roots) without reserving them (see VM.push).
const NATIVE_STACK_RESERVE = 16;

/// Backtraces list at most this many frames (see VM.BacktraceLines).
const MAX_BACKTRACE_FRAMES = 32;
/// Room for one backtrace line such as "    from script:12:3:in 'name'".
const MAX_TRACE_LINE_LEN = 256;

/// Values a call site pushes after its packed positional Array: the keyword Map and the block.
const MAX_TRAILING_CALL_VALUES = 2;
/// Bits a shift count may name in a bitwise op.
const BITWISE_INT_BITS: i64 = @bitSizeOf(i64);
/// 2^63: the smallest float magnitude outside i64 (-2^63 itself still fits).
const I64_FLOAT_BOUND: f64 = 0x1p63;

pub const MethodLookupResult = struct {
    method: ?value.Value,
    is_private: bool,
};

pub const LookupTarget = enum {
    instance,
    class,
};

pub const InterpretResult = enum {
    ok,
    block_break,
    compile_error,
    runtime_error,
    execution_limit_exceeded,
};

const SwitchMatch = struct {
    matched: bool,
    jump_offset: usize,
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

/// A block's `break` between the block and the call it leaves.
pub const PendingBreak = struct {
    /// What the call hands back.
    value: value.Value,
    /// The frame of the method the block was given to; null when a native got the block
    /// (`xs.each { break }`), which then takes the value (takeBlockBreak).
    target: ?usize,
};

/// Pending exception transfer across a native (Zig) boundary.
///
/// executeThrow pops frames down to the rescuing frame immediately, but every
/// native between the raise and the handler still has to return error.Unwind,
/// and its defers (HandleScope etc.) can rewrite stack_top on the way out. Each
/// boundary re-applies `stack_top` + `err_val`; the boundary whose caller frame
/// owns the handler (`frame_count`) consumes the entry. At most one entry is live:
/// no bytecode runs while an unwind propagates, so a new throw supersedes any
/// entry left behind by a handler reached without crossing a native.
pub const UnwindFrame = struct {
    err_val: value.Value,
    stack_top: usize,
    frame_count: usize = 0,
};

pub const VM = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stack: []value.Value,
    stack_top: usize,
    frames: std.ArrayListUnmanaged(CallFrame),

    native_vfs_ptr: *NativeVfs,
    vfs: Vfs,
    gc: memory.GC,
    line_index: ?*const LineIndex = null, // Injected by CLI for debugging
    profiler: ?*profiler_mod.Profiler = null, // First-class tracing profiler
    debugger_step_handler: ?*const fn (vm: *VM) void = null,
    /// Opens the interactive debugger when a script calls `debugger()`. Null (the default)
    /// where no one is at a terminal to answer it, such as the LSP, whose stdin and stdout
    /// carry the protocol: there `debugger()` does nothing.
    debugger_handler: ?*const fn (vm: *VM) void = null,

    globals: std.StringHashMapUnmanaged(value.Value),
    // Owned copies of the global names defined by bytecode (see defineGlobal); keys
    // registered by the host are static literals and are not in here.
    owned_global_keys: std.ArrayListUnmanaged([]const u8) = .empty,
    // Names the main script itself defined in `globals` (keys borrowed from `globals`).
    // Everything else in `globals` was registered by the host (builtins, natives), and
    // only those are visible to imported modules.
    script_defined_globals: std.StringHashMapUnmanaged(void) = .empty,
    /// Paths of the imports in progress, each keyed by its importer's constant, which
    /// outlives the import (see op_import).
    loading_modules: std.StringHashMapUnmanaged(void) = .empty,
    // Builtin values the main script shadowed (e.g. `cube = 5`), so modules still see
    // the original builtin rather than the main script's variable.
    shadowed_builtins: std.StringHashMapUnmanaged(value.Value) = .empty,
    // One top-level namespace per imported module (see value.Namespace).
    module_namespaces: std.ArrayListUnmanaged(*value.Namespace) = .empty,
    modules: std.StringHashMapUnmanaged(value.Value),
    strings: std.StringHashMapUnmanaged(*value.ObjString),
    symbols: std.StringHashMapUnmanaged(*value.ObjSymbol),

    open_upvalues: ?*value.ObjUpvalue = null,
    rescue_frames: std.ArrayListUnmanaged(RescueFrame) = .empty,
    param_registry: parameters.ParamList = .{},
    param_lookup: std.AutoHashMapUnmanaged(value.Value, usize) = .empty,

    materials: std.ArrayListUnmanaged(material_mod.MaterialDef) = .empty,
    display_list: std.ArrayListUnmanaged(geom.GeometryHandle) = .empty,

    host: Host = .{},
    dag_builder: dag.DAGBuilder,
    dag_cache: std.AutoHashMapUnmanaged(u64, geom.GeometryHandle) = .empty,
    mute_errors: bool = false,
    /// The first error reported since the run started or the last exception was rescued,
    /// as printed to stderr (e.g. "ValueError: ..."): what failed the run. Kept even with
    /// `mute_errors`, so embedders (api, wasm) can show it. Owned by `allocator`.
    last_error: ?[]u8 = null,
    step_mode: bool = false,

    // std classes
    string_class: ?*value.ObjClass = null,
    array_class: ?*value.ObjClass = null,
    map_class: ?*value.ObjClass = null,
    number_class: ?*value.ObjClass = null,
    range_class: ?*value.ObjClass = null,
    /// The class for each runtime error kind, registered by stdlib/exceptions.zig.
    error_classes: std.EnumArray(ErrorKind, ?*value.ObjClass) = .initFill(null),
    symbol_class: ?*value.ObjClass = null,
    boolean_class: ?*value.ObjClass = null,
    bbox_class: ?*value.ObjClass = null,
    object_class: ?*value.ObjClass = null,
    geometry_class: ?*value.ObjClass = null,
    cross_section_class: ?*value.ObjClass = null,
    /// The classes of values that are not instances (Ruby's NilClass, Proc, Method,
    /// Class, Module), so every value has a class.
    nil_class: ?*value.ObjClass = null,
    proc_class: ?*value.ObjClass = null,
    method_class: ?*value.ObjClass = null,
    class_class: ?*value.ObjClass = null,
    module_class: ?*value.ObjClass = null,
    assembly_class: ?*value.ObjClass = null,
    workplane_class: ?*value.ObjClass = null,

    // DOD Memory Fields
    scratch_arena: std.heap.ArenaAllocator,
    /// How many runUntil calls are active (more than one while a native runs a block).
    run_depth: u32 = 0,
    static_true: ?*value.ObjString = null,
    static_false: ?*value.ObjString = null,
    static_nil: ?*value.ObjString = null,

    // --- Track stack state to prevent native FFI corruption ---
    unwind_stack: std.ArrayListUnmanaged(UnwindFrame) = .empty,
    // Bumped by every executeThrow so a native boundary can tell that the native
    // already raised (e.g. raiseError + `return error.RuntimeError`) and must
    // not raise a second "Native Execution Error" on top of it.
    throw_seq: u64 = 0,
    // frame_count of the rescuing frame for the latest throw, null if it was uncaught.
    last_throw_target: ?usize = null,
    /// A block's `break` on its way out (see carryBreak). It travels here, not on the
    /// stack, so the natives it passes through find the stack as they left it.
    pending_break: ?PendingBreak = null,

    /// Features already warned about (warnUnsupported), so each is reported once per run.
    warned_features: std.EnumSet(kernel.Feature) = .empty,
    /// The settings in force, as ids into dag_builder's settings table: CAD.with_config
    /// pushes, CAD.config changes the top; never empty. Read with `config`, change only with
    /// setConfig / pushConfig / popConfig, which keep the DAG builder's settings in step.
    config_stack: std.ArrayListUnmanaged(dag.SettingsId) = .empty,

    // safety for infinite loops
    instruction_count: usize,
    instruction_limit: usize,
    import_depth: u8 = 0,
    // max call stack
    max_call_frames: usize = 100_000,
    /// Set to true during tests to brutally expose unrooted allocations
    zealous_gc: bool = false,

    cancel_token: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Bumped whenever a method table changes (op_method, op_class_method, op_mixin,
    /// op_inherit): an inline cache from an earlier epoch is stale (chunk.InlineCache).
    method_epoch: u32 = 0,

    const STACK_GROW_FACTOR: usize = 2;
    pub const MAX_IMPORT_DEPTH: u8 = 64;
    /// How deep `==` follows nested Arrays and Maps before calling them unequal.
    pub const MAX_EQUALITY_DEPTH: usize = 64;
    pub const MAX_STACK_STRING_LEN: usize = 1024;

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !VM {
        // Each allocation is released if a later one fails, until the VM owns them all (a VM
        // that ran out of memory while starting leaked everything it had allocated so far).
        var vm = vm: {
            var config_stack = std.ArrayListUnmanaged(dag.SettingsId).empty;
            errdefer config_stack.deinit(allocator);
            try config_stack.append(allocator, 0); // the default settings

            // Pre-allocate a massive 64K stack (512KB of contiguous memory)
            const initial_stack = try allocator.alloc(value.Value, 65536);
            errdefer allocator.free(initial_stack);

            // Pre-allocate 4,096 frames (~128KB of contiguous memory)
            var frames = std.ArrayListUnmanaged(CallFrame).empty;
            errdefer frames.deinit(allocator);
            try frames.ensureTotalCapacity(allocator, 4096);

            // Pre-allocate rescue frames
            var rescue_frames = std.ArrayListUnmanaged(RescueFrame).empty;
            errdefer rescue_frames.deinit(allocator);
            try rescue_frames.ensureTotalCapacity(allocator, 256);

            // Dynamically allocate the NativeVfs so its memory address stays valid
            const native_vfs = try allocator.create(NativeVfs);
            errdefer allocator.destroy(native_vfs);
            native_vfs.* = NativeVfs.init(io, std.Io.Dir.cwd());

            break :vm VM{
                .allocator = allocator,
                .io = io,
                .stack = initial_stack,
                .stack_top = 0,
                .frames = frames,
                .native_vfs_ptr = native_vfs,
                .vfs = native_vfs.vfs(),
                .gc = memory.GC.init(allocator),
                .globals = .empty,
                .modules = .empty,
                .strings = .empty,
                .symbols = .empty,
                .open_upvalues = null,
                .profiler = null,
                .config_stack = config_stack,
                .line_index = null,
                .debugger_step_handler = null,
                .step_mode = false,
                .rescue_frames = rescue_frames,
                .param_registry = .{},
                .param_lookup = .empty,
                .host = .{},
                .materials = .empty,
                .display_list = .empty,
                .dag_builder = dag.DAGBuilder.init(allocator),
                .dag_cache = .empty,
                .mute_errors = builtin.is_test,
                .scratch_arena = std.heap.ArenaAllocator.init(allocator),
                .static_true = null,
                .static_false = null,
                .static_nil = null,
                .unwind_stack = .empty,
                .instruction_count = 0,
                .instruction_limit = limits.DEFAULT_INSTRUCTION_LIMIT,
                .import_depth = 0,
            };
        };

        // From here the VM owns everything above, and deinit releases it.
        errdefer vm.deinit();

        // preallocate true, false and nil strings
        vm.static_true = (try vm.allocateString("true")).asString();
        vm.static_false = (try vm.allocateString("false")).asString();
        vm.static_nil = (try vm.allocateString("nil")).asString();

        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.resetStack();
        self.clearLastError();

        self.gc.collectGarbage(self, true);
        // --- GC Teardown Memory Assert ---
        if (builtin.is_test) {
            std.debug.assert(self.gc.bytes_allocated == 0);
        }

        self.dag_builder.deinit();

        self.clearDagCache();
        self.dag_cache.deinit(self.allocator);

        self.allocator.destroy(self.native_vfs_ptr);

        self.allocator.free(self.stack);
        self.globals.deinit(self.allocator);
        self.script_defined_globals.deinit(self.allocator);
        self.loading_modules.deinit(self.allocator);
        self.shadowed_builtins.deinit(self.allocator);
        for (self.module_namespaces.items) |ns| {
            ns.deinit(self.allocator);
            self.allocator.destroy(ns);
        }
        self.module_namespaces.deinit(self.allocator);
        for (self.owned_global_keys.items) |key| self.allocator.free(key);
        self.owned_global_keys.deinit(self.allocator);
        var module_keys = self.modules.keyIterator();
        while (module_keys.next()) |key| self.allocator.free(key.*);
        self.modules.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.rescue_frames.deinit(self.allocator);
        self.param_registry.deinit(self.allocator);
        self.param_lookup.deinit(self.allocator);
        self.config_stack.deinit(self.allocator);
        self.unwind_stack.deinit(self.allocator);
        self.resetRunOutput();
        self.materials.deinit(self.allocator);
        self.display_list.deinit(self.allocator);
        self.scratch_arena.deinit();
        self.gc.deinit();
    }

    // --- Dynamic Stack Operations ---
    /// Pushes onto room reserved beforehand: every frame reserves its compiled stack depth
    /// and every native call NATIVE_STACK_RESERVE (reserveFrame, executeNative), where
    /// running out of memory is an error. A native needing more slots reserves them with
    /// ensureStackCapacity first. Growing here is the fallback for a reservation that
    /// fell short, a bug.
    pub fn push(self: *VM, val: value.Value) void {
        if (self.stack_top >= self.stack.len) {
            self.ensureStackCapacity(self.stack_top + 1) catch @panic("VM stack reservation exceeded and the stack could not grow");
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
        try map.map.put(self.gc.trackingAllocator(), key, val);
    }

    pub fn ensureStackCapacity(self: *VM, required_capacity: usize) !void {
        if (required_capacity <= self.stack.len) return;

        var new_capacity = self.stack.len;
        while (new_capacity < required_capacity) {
            new_capacity *= STACK_GROW_FACTOR;
        }

        const old_ptr = self.stack.ptr;
        self.stack = try self.allocator.realloc(self.stack, new_capacity);

        // If the allocator moved the stack to a new memory address,
        // we MUST patch all open upvalues, or they will point to freed memory
        if (self.stack.ptr != old_ptr) {
            var upvalue = self.open_upvalues;
            while (upvalue) |u| {
                // Calculate the byte offset from the old pointer and apply it to the new pointer
                const offset = @intFromPtr(u.location) - @intFromPtr(old_ptr);
                u.location = @as(*value.Value, @ptrFromInt(@intFromPtr(self.stack.ptr) + offset));
                upvalue = u.next;
            }
        }
    }

    // --- Execution Core ---
    pub fn interpret(self: *VM, execution_chunk: *chunk.Chunk) InterpretResult {
        self.instruction_count = 0; // Reset gas on fresh run
        self.clearUnwindState();
        self.clearLastError();
        self.frames.clearRetainingCapacity();
        // Start small (64 initial frames) and let it grow dynamically
        self.frames.ensureTotalCapacity(self.allocator, 64) catch |err| return self.allocationFailed(err);
        self.stack_top = 0;

        // The dispatch loop indexes constants/caches and follows jumps unchecked
        // for speed, so malformed bytecode must be rejected once, up front.
        if (!self.verifyBytecode(execution_chunk)) return .compile_error;

        const func = self.gc.allocateFunction(self) catch |err| return self.allocationFailed(err);
        func.chunk = execution_chunk;
        func.owns_chunk = false;
        func.upvalue_count = 0;
        func.local_count = execution_chunk.local_count;

        // Protect func from GC during allocateClosure
        self.push(value.Value.initObj(&func.obj));
        const closure = self.gc.allocateClosure(self, func) catch |err| return self.allocationFailed(err);

        // Swap func for closure on stack
        _ = self.pop();
        self.push(value.Value.initObj(&closure.obj));

        // The script closure now roots the chunk's constants for the whole run, so
        // the compile-time registration (see chunk.ChunkRegistry) can be dropped;
        // afterwards the constants are collectable like any other unreferenced value.
        if (execution_chunk.registry) |r| r.untrack(execution_chunk);

        // Pad the top-level script frame for its local variables (slot 0 holds the closure)
        const locals_to_pad = if (func.local_count > 1) func.local_count - 1 else 0;
        self.reserveFrame(func, locals_to_pad) catch |err| return self.allocationFailed(err);
        for (0..locals_to_pad) |_| self.push(value.Value.initNil());

        self.frames.appendAssumeCapacity(.{
            .closure = closure,
            .ip = 0,
            .base_slot = 0, // base_slot 0 is where our closure sits on the stack
        });

        // --- PROFILER: Top-Level Script ---
        if (self.profiler) |p| p.enterFrame("script") catch |err| {
            log.err("Profiler error: {}", .{err});
        };

        const res = self.run();
        self.clearUnwindState();
        return res;
    }

    pub fn run(self: *VM) InterpretResult {
        return self.runUntil(0);
    }

    pub fn runUntil(self: *VM, target_depth: usize) InterpretResult {
        // The scratch arena is recycled when the outermost run ends, even after an unwind.
        // A nested run (a native calling a block through callClosureSync) must not reset
        // it: the native that called it may still be using scratch memory.
        self.run_depth += 1;
        defer {
            self.run_depth -= 1;
            if (self.run_depth == 0) _ = self.scratch_arena.reset(.retain_capacity);
        }

        var previous_line: ?u32 = null; // Track line boundary

        while (self.frames.items.len > target_depth) {

            // Cancellation Token Check (Instant UI / Ctrl+C Interrupt)
            if (self.cancel_token.load(.acquire)) return .runtime_error;

            // Gas Check
            if (self.instruction_limit > 0) {
                self.instruction_count += 1;
                if (self.instruction_count > self.instruction_limit) {
                    self.runtimeError("Execution limit: the run took more than {d} instructions, the budget where this host runs scripts; a loop that never ends, or a model too heavy for it.", .{self.instruction_limit});
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
            const exec_chunk: *chunk.Chunk = @ptrCast(@alignCast(frame.closure.function.chunk.?));

            // --- DEBUGGER: Step Mechanics ---
            if (self.step_mode) {
                if (self.line_index) |li| {
                    const current_offset = exec_chunk.getOffset(frame.ip);
                    const current_line = li.getLine(current_offset);

                    if (previous_line) |prev| {
                        if (current_line != prev) {
                            // We crossed a line boundary! Invoke the REPL.
                            if (self.debugger_step_handler) |handler| {
                                handler(self);
                                // After debugger returns, update tracking so it doesn't loop forever on the same line
                                previous_line = current_line;
                            } else {
                                // Nobody to pause for (a host armed stepping without a handler):
                                // the run goes on, as debugger() does without a host. It used to
                                // end here with a `paused` result no caller could resume.
                                self.step_mode = false;
                            }
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

            const op: chunk.OpCode = @fromBackingInt(instruction);

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
                    const high: usize = exec_chunk.code.items[frame.ip];
                    const low: usize = exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;
                    self.push(exec_chunk.constants.items[(high << 8) | low]);
                },
                .op_get_local => {
                    const slot = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.push(self.getLocal(frame, slot));
                },
                .op_get_local_wide => {
                    const high: usize = exec_chunk.code.items[frame.ip];
                    const low: usize = exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;
                    self.push(self.getLocal(frame, (high << 8) | low));
                },
                .op_set_local => {
                    const slot = exec_chunk.code.items[frame.ip];
                    frame.ip += 1;
                    self.setLocal(frame, slot, self.stack[self.stack_top - 1]);
                },
                .op_set_local_wide => {
                    const high: usize = exec_chunk.code.items[frame.ip];
                    const low: usize = exec_chunk.code.items[frame.ip + 1];
                    frame.ip += 2;
                    self.setLocal(frame, (high << 8) | low, self.stack[self.stack_top - 1]);
                },
                .op_add, .op_subtract, .op_bitwise_and, .op_bitwise_or, .op_bitwise_xor, .op_shift_left, .op_shift_right => {
                    const res = self.executeBinaryArithmetic(op);
                    if (res != .ok) return res;
                },
                .op_multiply, .op_divide, .op_modulo, .op_exponent, .op_less, .op_greater, .op_less_equal, .op_greater_equal => {
                    const res = self.executeNumericBinary(op);
                    if (res != .ok) return res;
                },
                .op_negate => {
                    const a = self.pop();
                    if (!a.isNumber()) {
                        if (self.raiseError(.TypeError, "unary '-' expects a number, got {s}", .{self.typeName(a)}) != .ok) return .runtime_error;
                        continue;
                    }
                    self.push(value.Value.initNumber(-a.asNumber()));
                },
                .op_positive => {
                    const a = self.pop();
                    if (!a.isNumber()) {
                        if (self.raiseError(.TypeError, "unary '+' expects a number, got {s}", .{self.typeName(a)}) != .ok) return .runtime_error;
                        continue;
                    }
                    self.push(a);
                },
                .op_bitwise_not => {
                    const a = self.pop();
                    if (!a.isNumber()) {
                        if (self.raiseError(.TypeError, "unary '~' expects a number, got {s}", .{self.typeName(a)}) != .ok) return .runtime_error;
                        continue;
                    }
                    const int = bitwiseOperand(a.asNumber()) orelse {
                        if (self.raiseError(.RangeError, "Bitwise operand {f} is not a finite 64-bit integer.", .{value.fmtNumber(a.asNumber())}) != .ok) return .runtime_error;
                        continue;
                    };
                    self.push(value.Value.initNumber(@floatFromInt(~int)));
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
                    const name_val = self.readValueOperand(exec_chunk, frame, op == .op_set_member_wide);
                    const val = self.pop();
                    const receiver = self.stack[self.stack_top - 1]; // Peek at namespace (Module/Class)

                    if (receiver.isModule()) {
                        const mod = receiver.asModule();
                        mod.methods.put(self.gc.trackingAllocator(), name_val, val) catch |err| return self.allocationFailed(err);
                    } else if (receiver.isClass()) {
                        const cls = receiver.asClass();
                        cls.class_fields.put(self.gc.trackingAllocator(), name_val, val) catch |err| return self.allocationFailed(err);
                    } else {
                        if (self.raiseError(.TypeError, "Cannot attach member to non-namespace.", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                    self.push(val); // Push the namespace back to maintain stack equilibrium
                },
                .op_get_global, .op_get_global_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_get_global_wide);
                    if (self.lookupGlobal(frame, name_str)) |val| {
                        self.push(val);
                    } else {
                        if (self.raiseError(.NameError, "Undefined variable '{s}'", .{name_str}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_get_index => {
                    const res = self.executeGetIndex();
                    if (res != .ok) return res;
                },
                .op_set_index => {
                    // Peek instead of Pop to keep everything rooted during potential reallocation
                    const val = self.stack[self.stack_top - 1];
                    const index = self.stack[self.stack_top - 2];
                    const target = self.stack[self.stack_top - 3];

                    if (target.isArray() and index.isNumber()) {
                        const arr = target.asArray();
                        if (self.resolveArrayIndex(arr.items.items.len, index)) |idx| {
                            arr.items.items[idx] = val;
                            self.stack_top -= 3; // Safely pop all three
                            self.push(val);
                        } else |_| {
                            if (self.indexError("Array", index, arr.items.items.len) != .ok) return .runtime_error;
                            continue;
                        }
                    } else if (target.isMap()) {
                        const map = target.asMap();
                        self.mapSet(map, index, val) catch return self.raiseError(.OutOfMemoryError, "Map set failed", .{});
                        self.stack_top -= 3; // Safely pop all three
                        self.push(val);
                    } else {
                        if (self.raiseError(.TypeError, "{s} doesn't support index assignment ([]=)", .{self.typeName(target)}) != .ok) return .runtime_error;
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
                    }) catch |err| return self.allocationFailed(err);
                },
                .op_pop_rescue => {
                    _ = self.rescue_frames.pop();
                },
                .op_throw => {
                    const res = self.executeThrow();
                    if (res != .ok) return res;
                },
                .op_break_block => {
                    self.pending_break = .{ .value = self.pop(), .target = self.blockReceiverFrame(frame.closure) };
                    if (self.carryBreak(target_depth)) |res| return res;
                },
                .op_build_array, .op_build_array_wide => {
                    const item_count = self.readOperand(exec_chunk, frame, op == .op_build_array_wide);
                    const arr_obj = self.gc.allocateArray(self) catch |err| return self.allocationFailed(err);
                    const arr_val = value.Value.initObj(&arr_obj.obj);

                    // Root the array BEFORE allocating internal capacity to prevent GC sweeps
                    self.push(arr_val);
                    arr_obj.items.ensureTotalCapacity(self.gc.trackingAllocator(), item_count) catch {
                        return self.raiseError(.OutOfMemoryError, "Failed to build array", .{});
                    };

                    // The elements were pushed before arr_val, so they sit below it
                    const start_idx = self.stack_top - 1 - item_count;

                    // Slice AFTER capacity allocation to guarantee memory addresses are valid
                    arr_obj.items.appendSliceAssumeCapacity(self.stack[start_idx .. start_idx + item_count]);

                    // Pop the protected arr_val, physically shrink the stack to remove the consumed elements,
                    // and push arr_val back to the new top
                    _ = self.pop();
                    self.shrinkStack(start_idx);
                    self.push(arr_val);
                },
                .op_build_map, .op_build_map_wide => {
                    const pair_count = self.readOperand(exec_chunk, frame, op == .op_build_map_wide);
                    const map_obj = self.gc.allocateMap(self) catch |err| return self.allocationFailed(err);
                    const map_val = value.Value.initObj(&map_obj.obj);

                    // Root the map BEFORE allocating internal capacity to prevent GC sweeps
                    self.push(map_val);
                    map_obj.map.ensureTotalCapacity(self.gc.trackingAllocator(), pair_count) catch {
                        return self.raiseError(.OutOfMemoryError, "Failed to build map", .{});
                    };

                    const start_idx = self.stack_top - 1 - (pair_count * 2);
                    var i: usize = 0;
                    while (i < pair_count * 2) : (i += 2) {
                        const key = self.stack[start_idx + i];
                        const val = self.stack[start_idx + i + 1];

                        self.mapSet(map_obj, key, val) catch {
                            return self.raiseError(.OutOfMemoryError, "Failed to insert map key", .{});
                        };
                    }

                    // Pop the protected map_val, physically shrink the stack to remove the consumed pairs,
                    // and push map_val back to the new top
                    _ = self.pop();
                    self.shrinkStack(start_idx);
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
                    const res = self.executeInterpolate(count);
                    if (res != .ok) return res;
                },
                .op_array_push => {
                    // Peek instead of Pop to keep `val` rooted during potential reallocation
                    const val = self.stack[self.stack_top - 1];
                    const arr_val = self.stack[self.stack_top - 2];
                    const arr = arr_val.asArray();
                    arr.items.append(self.gc.trackingAllocator(), val) catch return self.raiseError(.OutOfMemoryError, "Array push failed", .{});
                    // Safely pop only the pushed value; target array stays on top
                    _ = self.pop();
                },
                .op_array_spread => {
                    // Peek instead of Pop to keep `source_val` rooted during potential reallocation
                    const source_val = self.stack[self.stack_top - 1];
                    const target_val = self.stack[self.stack_top - 2];
                    const target_arr = target_val.asArray();

                    if (source_val.isArray()) {
                        const source_arr = source_val.asArray();
                        target_arr.items.ensureTotalCapacity(self.gc.trackingAllocator(), target_arr.items.items.len + source_arr.items.items.len) catch return self.raiseError(.OutOfMemoryError, "Array spread failed", .{});
                        target_arr.items.appendSliceAssumeCapacity(source_arr.items.items);
                    } else {
                        if (self.raiseError(.TypeError, "only an Array can be spread with *", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                    // Safely pop only the spread source array; target array stays on top
                    _ = self.pop();
                },
                .op_map_insert => {
                    // Peek instead of Pop to keep values rooted during potential reallocation
                    const val = self.stack[self.stack_top - 1];
                    const key = self.stack[self.stack_top - 2];
                    const map_val = self.stack[self.stack_top - 3];
                    const map = map_val.asMap();

                    self.mapSet(map, key, val) catch return self.raiseError(.OutOfMemoryError, "Map insert failed", .{});
                    // Safely pop both key and val; target map stays on top
                    _ = self.pop();
                    _ = self.pop();
                },
                .op_map_spread => {
                    // Peek instead of Pop to keep `source_val` rooted during potential reallocation
                    const source_val = self.stack[self.stack_top - 1];
                    const target_val = self.stack[self.stack_top - 2];
                    const target_map = target_val.asMap();

                    if (source_val.isMap()) {
                        const source_map = source_val.asMap();
                        const keys = source_map.map.keys();
                        const values = source_map.map.values();

                        target_map.map.ensureTotalCapacity(self.gc.trackingAllocator(), target_map.map.count() + keys.len) catch return self.raiseError(.OutOfMemoryError, "Map spread failed", .{});

                        for (keys, 0..) |key, i| {
                            self.mapSet(target_map, key, values[i]) catch return self.raiseError(.OutOfMemoryError, "Map spread failed", .{});
                        }
                    } else {
                        if (self.raiseError(.TypeError, "only a Map can be spread with **", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                    // Safely pop only the spread source map; target map stays on top
                    _ = self.pop();
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
                .op_for_next => {
                    const slot = self.readOperand(exec_chunk, frame, true);
                    const exit_offset = self.readJumpOffset(exec_chunk, frame);
                    const taken = self.getLocal(frame, slot + 1).asNumber();
                    // As for a native: a raised error may be rescued, unwinding past this frame.
                    const caller_depth = self.frames.items.len;
                    const throw_seq = self.throw_seq;
                    const more = self.pushForElement(self.getLocal(frame, slot), @intFromFloat(taken)) catch |err| {
                        if (self.alreadyThrown(throw_seq, caller_depth)) |res| {
                            if (res != .ok) return res;
                            continue;
                        }
                        return self.nativeFailed("for", err);
                    };
                    if (more) {
                        self.setLocal(frame, slot + 1, value.Value.initNumber(taken + 1));
                    } else {
                        frame.ip += exit_offset;
                    }
                },
                .op_loop => {
                    // Properly read 3-byte offset
                    const offset = self.readJumpOffset(exec_chunk, frame);
                    frame.ip -= offset; // Jump backwards
                },
                .op_import, .op_import_wide => {
                    if (self.executeImport(frame, exec_chunk, op == .op_import_wide)) |out| return out;
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

                    const match = searchJumpTable(exec_chunk, frame.ip, case_count, test_val);

                    frame.ip += case_count * 6; // Fast-forward past the 6-byte jump table entries
                    const default_offset = self.readJumpOffset(exec_chunk, frame);

                    if (match.matched) {
                        frame.ip += match.jump_offset;
                    } else {
                        frame.ip += default_offset;
                    }
                },
                .op_closure, .op_closure_wide => {
                    const func_idx = self.readOperand(exec_chunk, frame, op == .op_closure_wide);
                    const func_val = exec_chunk.constants.items[func_idx];
                    const func_obj = func_val.asFunction();

                    const closure = self.gc.allocateClosure(self, func_obj) catch |err| return self.allocationFailed(err);
                    const closure_val = value.Value.initObj(&closure.obj);

                    // Push the closure to the stack BEFORE capturing upvalues to ensure GC safety
                    self.push(closure_val);
                    closure.home = homeMethod(frame);
                    closure.home_self = self.frameSelf(frame);
                    closure.home_block = self.frameBlock(frame);

                    // Iterate over the operands to wire up the captured variables
                    for (0..func_obj.upvalue_count) |i| {
                        const is_local = exec_chunk.code.items[frame.ip];
                        frame.ip += 1;
                        // Read 16-bit upvalue index
                        const index = (@as(u16, exec_chunk.code.items[frame.ip]) << 8) | exec_chunk.code.items[frame.ip + 1];
                        frame.ip += 2;

                        if (is_local == 1) {
                            // Capture directly from the parent's stack slot
                            closure.upvalues[i] = self.captureUpvalue(&self.stack[frame.base_slot + index]) catch |err| return self.allocationFailed(err);
                        } else {
                            // Pass down an upvalue that the parent already captured
                            closure.upvalues[i] = frame.closure.upvalues[index];
                        }
                    }
                },
                .op_return => {
                    const result = self.pop();
                    // Constructor intercepts the return and yields `self` instead of the function's result
                    const return_val = if (frame.is_constructor) self.stack[frame.base_slot] else result;
                    self.popFrame();
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

                    if (val.isArray()) {
                        const arr = val.asArray();
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
                    const mod_obj = self.gc.allocateModule(self, name_str_obj) catch |err| return self.allocationFailed(err);
                    self.push(value.Value.initObj(&mod_obj.obj));
                },
                .op_mixin => {
                    const module_val = self.pop();
                    if (!module_val.isModule()) {
                        if (self.raiseError(.TypeError, "include needs a Module, got {s}", .{self.typeName(module_val)}) != .ok) return .runtime_error;
                        continue;
                    }

                    const class_val = self.stack[self.stack_top - 1]; // Peek at class
                    if (!class_val.isClass()) {
                        // `include M` in a module body, or outside any class: it stopped the run
                        // with no message and nothing to rescue.
                        const where = if (class_val.isModule()) "include can't add a module to another module; include it in each class that needs it" else "include is only valid inside a class body";
                        if (self.raiseError(.TypeError, "{s}", .{where}) != .ok) return .runtime_error;
                        continue;
                    }
                    const class_obj = class_val.asClass();

                    class_obj.included_modules.append(self.gc.trackingAllocator(), module_val.asModule()) catch |err| return self.allocationFailed(err);
                    self.method_epoch +%= 1;
                },
                .op_class, .op_class_wide => {
                    const name_str_obj = self.readStringObjectOperand(exec_chunk, frame, op == .op_class_wide);

                    // RE-OPEN the class if it is visible from this scope (a module can reopen
                    // its own classes and builtins, not the importer's classes)
                    if (self.lookupGlobal(frame, name_str_obj.chars)) |existing| {
                        if (existing.isClass()) {
                            self.push(existing);
                            continue;
                        }
                    }

                    // Ensure new classes inherit from Object by default
                    const class_obj = self.gc.allocateClass(self, name_str_obj, self.object_class) catch |err| return self.allocationFailed(err);
                    self.push(value.Value.initObj(&class_obj.obj));
                },
                .op_method, .op_method_wide => {
                    const name_val = self.readValueOperand(exec_chunk, frame, op == .op_method_wide);
                    const method = self.pop(); // The closure
                    const receiver_val = self.stack[self.stack_top - 1]; // Peek at class or module

                    if (receiver_val.isClass()) {
                        receiver_val.asClass().methods.put(self.gc.trackingAllocator(), name_val, method) catch |err| return self.allocationFailed(err);
                        if (method.isClosure()) method.asClosure().home_class = receiver_val.asClass();
                    } else if (receiver_val.isModule()) {
                        receiver_val.asModule().methods.put(self.gc.trackingAllocator(), name_val, method) catch |err| return self.allocationFailed(err);
                    } else return .runtime_error;
                    self.method_epoch +%= 1;
                },
                .op_define_global, .op_define_global_wide => {
                    const name_str = self.readStringOperand(exec_chunk, frame, op == .op_define_global_wide);
                    const val = self.pop();
                    if (frame.closure.function.namespace) |ns| {
                        ns.define(self.allocator, name_str, val) catch |err| return self.allocationFailed(err);
                    } else {
                        self.defineGlobal(name_str, val) catch |err| return self.allocationFailed(err);
                    }
                },
                .op_get_ivar, .op_get_ivar_wide => {
                    // `@x`: this instance's field, nil when unset. It went through
                    // op_get_property, whose method fallback handed back a method named like
                    // the variable: `@v` inside `def v` was the method itself.
                    const name_val = self.readValueOperand(exec_chunk, frame, op == .op_get_ivar_wide);
                    const ic = self.readInlineCache(exec_chunk, frame);
                    const receiver = self.stack[self.stack_top - 1];
                    self.stack[self.stack_top - 1] = if (receiver.isInstance())
                        self.getPropertyCached(receiver.asInstance(), name_val, ic) orelse value.Value.initNil()
                    else if (receiver.isClass())
                        receiver.asClass().class_fields.get(name_val) orelse value.Value.initNil()
                    else
                        value.Value.initNil();
                },
                .op_get_property, .op_get_property_wide => {
                    if (self.executeGetProperty(frame, exec_chunk, op == .op_get_property_wide)) |out| return out;
                },
                .op_set_property, .op_set_property_wide => {
                    const is_wide = op == .op_set_property_wide;
                    const name_val = self.readValueOperand(exec_chunk, frame, is_wide);
                    const ic = self.readInlineCache(exec_chunk, frame);

                    const receiver = self.stack[self.stack_top - 2];
                    const val = self.stack[self.stack_top - 1];

                    if (receiver.isInstance()) {
                        const instance = receiver.asInstance();

                        // --- Property Fast/Slow Path ---
                        self.setInstanceField(instance, name_val, val, ic) catch |err| return self.allocationFailed(err);

                        self.stack[self.stack_top - 2] = val;
                        self.stack_top -= 1;
                        continue;
                    } else if (receiver.isClass()) {
                        const cls = receiver.asClass();
                        cls.class_fields.put(self.gc.trackingAllocator(), name_val, val) catch |err| return self.allocationFailed(err);
                        self.stack[self.stack_top - 2] = val;
                        self.stack_top -= 1;
                        continue;
                    } else if (receiver.isModule()) {
                        const mod = receiver.asModule();
                        mod.methods.put(self.gc.trackingAllocator(), name_val, val) catch |err| return self.allocationFailed(err);
                        self.stack[self.stack_top - 2] = val;
                        self.stack_top -= 1;
                        continue;
                    }

                    if (self.raiseError(.TypeError, "Only instances have properties.", .{}) != .ok) return .runtime_error;
                    continue;
                },
                .op_inherit => {
                    const super_val = self.pop();
                    if (!super_val.isClass()) {
                        // `class A < x` with no class: it stopped the run with no message.
                        if (self.raiseError(.TypeError, "a superclass must be a Class, got {s}", .{self.typeName(super_val)}) != .ok) return .runtime_error;
                        continue;
                    }
                    const sub_val = self.stack[self.stack_top - 1];
                    sub_val.asClass().superclass = super_val.asClass();
                    self.method_epoch +%= 1;
                },
                .op_call => {
                    const res = self.executeCall(frame, exec_chunk);
                    if (self.afterCall(res, target_depth)) |out| return out;
                },
                .op_invoke, .op_invoke_wide => {
                    const res = self.executeInvoke(frame, exec_chunk, op == .op_invoke_wide);
                    if (self.afterCall(res, target_depth)) |out| return out;
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
                    if (self.executeSuperInvoke(frame, exec_chunk, target_depth)) |out| return out;
                },
                .op_yield => {
                    if (self.executeYield(frame, exec_chunk, target_depth)) |out| return out;
                },
                .op_block_given => {
                    self.push(value.Value.initBool(self.frameBlock(frame).isClosure()));
                },
                .op_class_method, .op_class_method_wide => {
                    const name_val = self.readValueOperand(exec_chunk, frame, op == .op_class_method_wide);
                    const method = self.pop();
                    const receiver_val = self.stack[self.stack_top - 1]; // Peek at target

                    if (receiver_val.isClass()) {
                        receiver_val.asClass().class_methods.put(self.gc.trackingAllocator(), name_val, method) catch |err| return self.allocationFailed(err);
                    } else if (receiver_val.isModule()) {
                        receiver_val.asModule().methods.put(self.gc.trackingAllocator(), name_val, method) catch |err| return self.allocationFailed(err);
                    } else {
                        if (self.raiseError(.TypeError, "Can only define singleton methods on classes or modules.", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                    self.method_epoch +%= 1;
                },
                .op_get_class_var, .op_get_class_var_wide => {
                    const name_val = self.readValueOperand(exec_chunk, frame, op == .op_get_class_var_wide);
                    const name_str = name_val.asString().chars;
                    const receiver = self.pop(); // Explicitly pop receiver from stack

                    const class_obj = if (receiver.isInstance()) receiver.asInstance().class else if (receiver.isClass()) receiver.asClass() else null;

                    if (class_obj) |c| {
                        var current: ?*value.ObjClass = c;
                        var found_val: ?value.Value = null;

                        // Search up the hierarchy
                        while (current) |cls| {
                            if (cls.class_fields.get(name_val)) |val| {
                                found_val = val;
                                break;
                            }
                            current = cls.superclass;
                        }

                        if (found_val) |v| {
                            self.push(v);
                        } else {
                            if (self.raiseError(.NameError, "Undefined class variable '{s}'.", .{name_str}) != .ok) return .runtime_error;
                            continue;
                        }
                    } else {
                        if (self.raiseError(.RuntimeError, "Receiver has no class context.", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_set_class_var, .op_set_class_var_wide => {
                    const name_val = self.readValueOperand(exec_chunk, frame, op == .op_set_class_var_wide);
                    const receiver = self.pop(); // Pop explicit receiver
                    const val = self.pop(); // Pop RHS value

                    const class_obj = if (receiver.isInstance()) receiver.asInstance().class else if (receiver.isClass()) receiver.asClass() else null;

                    if (class_obj) |c| {
                        var current: ?*value.ObjClass = c;
                        var target_class: *value.ObjClass = c;

                        // Update the variable if it exists anywhere in the hierarchy
                        var found = false;
                        while (current) |cls| {
                            if (cls.class_fields.contains(name_val)) {
                                target_class = cls;
                                found = true;
                                break;
                            }
                            current = cls.superclass;
                        }

                        // A new variable belongs to the class whose code assigns it (binding it to
                        // the root class leaked it into every unrelated class).
                        if (!found) {
                            target_class = if (homeMethod(frame)) |home| (home.home_class orelse c) else c;
                        }

                        target_class.class_fields.put(self.gc.trackingAllocator(), name_val, val) catch |err| return self.allocationFailed(err);

                        self.push(val); // Yield the assigned value
                    } else {
                        if (self.raiseError(.RuntimeError, "Receiver has no class context.", .{}) != .ok) return .runtime_error;
                        continue;
                    }
                },
                .op_is_instance => {
                    const class_val = self.pop();
                    const thrown_val = self.pop();

                    if (!class_val.isClass()) {
                        if (self.raiseError(.TypeError, "Rescue type must be a Class.", .{}) != .ok) return .runtime_error;
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
                    const name_val = self.readValueOperand(exec_chunk, frame, op == .op_defined_wide);
                    const name_str = name_val.asString().chars;
                    var is_def = false;

                    if (std.mem.startsWith(u8, name_str, "@@")) {
                        // Class Variable Check: Grab `self` and walk the class hierarchy
                        const self_val = self.getLocal(frame, 0);
                        const class_obj = if (self_val.isInstance()) self_val.asInstance().class else if (self_val.isClass()) self_val.asClass() else null;
                        if (class_obj) |c| {
                            var current: ?*value.ObjClass = c;
                            while (current) |cls| {
                                if (cls.class_fields.contains(name_val)) {
                                    is_def = true;
                                    break;
                                }
                                current = cls.superclass;
                            }
                        }
                    } else if (std.mem.startsWith(u8, name_str, "@")) {
                        // An instance variable this instance has been given. The class layout
                        // alone said yes once any instance of the class had set it, and a
                        // block's frame slot 0 (the block) stood in for self.
                        const self_val = self.frameSelf(frame);
                        if (self_val.isInstance()) {
                            const inst = self_val.asInstance();
                            const clean_val = self.allocateString(name_str[1..]) catch |err| return self.allocationFailed(err);
                            if (inst.class.instance_layout.get(clean_val)) |idx| is_def = idx < inst.fields.items.len;
                        }
                    } else {
                        // Global / Native Check (Globals still use string keys)
                        is_def = self.lookupGlobal(frame, name_str) != null;
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
                        if (map_val.isMap()) {
                            const name_val = exec_chunk.constants.items[name_idx];
                            const map = map_val.asMap();

                            // Native O(1) Hash Map extraction
                            if (map.map.get(name_val)) |v| {
                                extracted = v;
                            }
                        }
                    }

                    self.push(extracted);
                },
                .op_cmp => {
                    const b = self.pop();
                    const a = self.pop();

                    if (a.isNumber() and b.isNumber()) {
                        const an = a.asNumber();
                        const bn = b.asNumber();
                        const cmp: f64 = if (an < bn) -1.0 else if (an > bn) 1.0 else 0.0;
                        self.push(value.Value.initNumber(cmp));
                    } else if (a.isString() and b.isString()) {
                        const a_str = a.asString().chars;
                        const b_str = b.asString().chars;
                        const order = std.mem.order(u8, a_str, b_str);
                        const cmp: f64 = switch (order) {
                            .lt => -1.0,
                            .gt => 1.0,
                            .eq => 0.0,
                        };
                        self.push(value.Value.initNumber(cmp));
                    } else {
                        self.push(value.Value.initNil()); // Incompatible types yield nil
                    }
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

        // MUST use trackingAllocator so the GC natively registers these bytes.
        // If it's a duplicate, GC.takeString will safely call trackingAllocator().free to un-track it.
        const heap_chars = try self.gc.trackingAllocator().dupe(u8, chars);
        return try self.allocateStringTakeOwnership(heap_chars);
    }

    /// Takes `chars` even when it fails (see GC.takeString).
    pub fn allocateStringTakeOwnership(self: *VM, chars: []u8) !value.Value {
        // gc.takeString adopts the slice (no second copy) and interns it; nothing allocates
        // after it here, so the value needs no rooting before it is returned.
        const str_obj = try self.gc.takeString(self, chars);
        return value.Value.initObj(&str_obj.obj);
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

    /// Defines the global `name` (which must outlive the VM) as a native. Natives are
    /// never collected, so the value needs no rooting while the global is added.
    pub fn defineNative(self: *VM, name: []const u8, function: value.NativeFn) !void {
        const native_obj = try self.gc.allocateNative(name, function);
        try self.globals.put(self.allocator, name, value.Value.initObj(&native_obj.obj));
    }

    /// `name` (a literal, outliving the VM) as an interned string that is never collected;
    /// the standard library registers its methods and constants under these.
    pub fn staticString(self: *VM, name: []const u8) !value.Value {
        return value.Value.initObj(&(try self.gc.internStatic(self, name)).obj);
    }

    pub inline fn shrinkStack(self: *VM, target_slot: usize) void {
        std.debug.assert(self.stack_top >= target_slot);
        if (self.stack_top > target_slot) {
            self.stack_top = target_slot;
        }
    }

    inline fn popAndRelease(self: *VM, count: usize) void {
        std.debug.assert(self.stack_top >= count);
        self.shrinkStack(self.stack_top - count);
    }

    fn verifyBytecode(self: *VM, c: *const chunk.Chunk) bool {
        verifier.verifyChunk(self.allocator, c) catch |err| {
            self.reportError("Fatal: Bytecode verification failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    /// Import cache insert. Keys are owned copies: the path slice comes from a
    /// constant ObjString that can be swept while the cache entry lives on.
    fn cacheModule(self: *VM, path: []const u8, val: value.Value) !void {
        (try owned_keys.getOrPutOwned(&self.modules, self.allocator, path)).value_ptr.* = val;
    }

    /// Drops the module imported from `path`, so the next import of it runs its new
    /// source (the session, when that file was edited).
    pub fn forgetModule(self: *VM, path: []const u8) void {
        if (self.modules.fetchRemove(path)) |kv| self.allocator.free(kv.key);
    }

    /// Global assignment from bytecode. Like the import cache, new keys are owned
    /// copies: the name comes from a constant ObjString that is swept once its chunk
    /// is freed, while the global lives on into the next run of a reused VM.
    /// `name = val` at the top of the main script. Every assignment of a top-level
    /// variable comes here, so the common case, a name the script defined before, is one
    /// lookup in `globals` and one in `script_defined_globals`; the bookkeeping (the owned
    /// key, the shadowed builtin) is done the first time a name is seen.
    fn defineGlobal(self: *VM, name: []const u8, val: value.Value) !void {
        const gop = try self.globals.getOrPut(self.allocator, name);
        if (!gop.found_existing) {
            errdefer self.globals.removeByPtr(gop.key_ptr);
            const owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned);
            try self.owned_global_keys.ensureUnusedCapacity(self.allocator, 1);
            try self.script_defined_globals.put(self.allocator, owned, {});
            self.owned_global_keys.appendAssumeCapacity(owned);
            gop.key_ptr.* = owned;
        } else if (!self.script_defined_globals.contains(name)) {
            // The main script is shadowing a builtin: keep the original for modules.
            try self.script_defined_globals.ensureUnusedCapacity(self.allocator, 1);
            try self.shadowed_builtins.put(self.allocator, gop.key_ptr.*, gop.value_ptr.*);
            self.script_defined_globals.putAssumeCapacity(gop.key_ptr.*, {});
        }
        gop.value_ptr.* = val;
    }

    /// Resolves a top-level name for code running in `frame`. Main-script code sees
    /// `globals`. Module code sees its own namespace, then builtins, but never the main
    /// script's variables or another module's.
    fn lookupGlobal(self: *VM, frame: *const CallFrame, name: []const u8) ?value.Value {
        const ns = frame.closure.function.namespace orelse return self.globals.get(name);
        if (ns.globals.get(name)) |val| return val;
        return self.builtinGlobal(name);
    }

    /// A top-level name as module code sees it: the builtin, also when the main script
    /// has shadowed it (`cube = 5`), and never the main script's own variables.
    pub fn builtinGlobal(self: *const VM, name: []const u8) ?value.Value {
        if (self.script_defined_globals.contains(name)) return self.shadowed_builtins.get(name);
        return self.globals.get(name);
    }

    fn newModuleNamespace(self: *VM) !*value.Namespace {
        try self.module_namespaces.ensureUnusedCapacity(self.allocator, 1);
        const ns = try self.allocator.create(value.Namespace);
        ns.* = .{};
        self.module_namespaces.appendAssumeCapacity(ns);
        return ns;
    }

    pub inline fn clearUnwindState(self: *VM) void {
        self.unwind_stack.clearRetainingCapacity();
    }

    /// Caps the script heap the GC tracks at `bytes` (null: no cap); an allocation past it
    /// ends the run with a Sandbox Error. The cap existed in the GC but nothing set it.
    pub fn setMemoryLimit(self: *VM, bytes: ?usize) void {
        self.gc.max_memory_limit = bytes;
    }

    pub fn resetStack(self: *VM) void {
        self.shrinkStack(0);
        self.clearUnwindState();
    }

    /// Forgets what a run put on display: the ghosts (display_list owns its handles,
    /// clones taken by ghost(), see materials.zig) and the materials. A session running
    /// a script again and again kept them all, so every viewport export carried every
    /// material ever made and every ghost ever shown.
    pub fn resetRunOutput(self: *VM) void {
        for (self.display_list.items) |h| kernel.destruct(h);
        self.display_list.clearRetainingCapacity();
        self.materials.clearRetainingCapacity();
    }

    /// Destroys every cached result (GC eviction drops only those no geometry still uses).
    pub fn clearDagCache(self: *VM) void {
        var it = self.dag_cache.valueIterator();
        while (it.next()) |handle| kernel.destruct(handle.*);
        self.dag_cache.clearRetainingCapacity();
    }

    /// Raises the GeometryError for one operation given geometry of two engines.
    pub fn requireSameEngine(self: *VM, a: geom.EngineType, b: geom.EngineType) error{RuntimeError}!void {
        if (a == b) return;
        return self.fail(.GeometryError, "can't combine {s} and {s} geometry in one operation", .{ a.scriptName(), b.scriptName() });
    }

    /// Raises NotImplementedError unless `engine` has `feature` (see kernel.Feature).
    pub fn requireFeature(self: *VM, engine: geom.EngineType, feature: kernel.Feature) error{RuntimeError}!void {
        if (kernel.supports(engine, feature)) return;
        return self.fail(.NotImplementedError, error_kind.UNSUPPORTED_FMT, .{ engine.scriptName(), feature.describe() });
    }

    /// For a feature the result can do without (materials): warns, once per run, that
    /// `engine` lacks it, instead of dropping it silently.
    pub fn warnUnsupported(self: *VM, engine: geom.EngineType, feature: kernel.Feature) void {
        if (kernel.supports(engine, feature) or self.warned_features.contains(feature)) return;
        self.warned_features.insert(feature);
        log.warn("the {s} engine can't {s} yet, so this model is built without them; use engine: :manifold to keep them", .{ engine.scriptName(), feature.describe() });
    }

    /// The settings in force (CAD.config / CAD.with_config).
    pub fn config(self: *const VM) EngineConfig {
        return self.dag_builder.settings(self.config_stack.items[self.config_stack.items.len - 1]);
    }

    /// Replaces the settings in force (CAD.config): geometry made from now on uses them.
    pub fn setConfig(self: *VM, settings: EngineConfig) !void {
        const id = try self.dag_builder.internSettings(settings);
        self.config_stack.items[self.config_stack.items.len - 1] = id;
        self.dag_builder.current_settings = id;
    }

    /// Puts `settings` in force until popConfig (CAD.with_config).
    pub fn pushConfig(self: *VM, settings: EngineConfig) !void {
        const id = try self.dag_builder.internSettings(settings);
        try self.config_stack.append(self.allocator, id);
        self.dag_builder.current_settings = id;
    }

    pub fn popConfig(self: *VM) void {
        std.debug.assert(self.config_stack.items.len > 1); // the base settings stay
        _ = self.config_stack.pop();
        self.dag_builder.current_settings = self.config_stack.items[self.config_stack.items.len - 1];
    }

    // --- JIT Materialization ---
    pub fn ensureConcrete(self: *VM, geometry: value.Value) !geom.GeometryHandle {
        std.debug.assert(geometry.isGeometry()); // a CrossSection goes to ensureConcreteCrossSection
        const geom_obj = geometry.asGeometry();
        if (geom_obj.isConcrete()) return geom_obj.cached_handle.?;

        // Do NOT mutate the ObjGeometry (geom_obj.cached_handle = handle)
        // The evaluated handle is now globally owned and managed by `vm.dag_cache`
        return try dag_evaluator.evaluateDAG(self, geom_obj.dag_idx);
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

    pub fn findMethod(self: *VM, class: *value.ObjClass, name: value.Value) ?value.Value {
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

    pub fn findClassMethod(self: *VM, class: *value.ObjClass, name: value.Value) ?value.Value {
        _ = self;
        var current: ?*value.ObjClass = class;
        while (current) |c| {
            if (c.class_methods.get(name)) |method| return method;
            current = c.superclass;
        }
        return null;
    }

    /// Lays out the frame of `closure` over the `provided_args_in` positional arguments
    /// above `base_slot`: pads or trims them to the positional parameters (packing a splat),
    /// then adds the keyword Map slot (when the function declares keywords; `kwargs_opt` is
    /// the call's Map) and the block slot. The Map used to be found by looking at the last
    /// argument, so a Map passed positionally landed in a later parameter's slot.
    inline fn padClosureFrame(self: *VM, closure: *value.ObjClosure, provided_args_in: usize, base_slot: usize, kwargs_opt: ?value.Value, block_val_opt: ?value.Value) !void {
        var provided_args = provided_args_in;
        const expected_args = closure.function.arity - @intFromBool(closure.function.has_kwargs);
        // A splat parameter takes whatever is left, possibly nothing, so its slot is never
        // padded: `def g(*rest)` called with no arguments gets `[]`, not `[nil]`.
        const padded_args = if (closure.function.splat_pos != null) expected_args - 1 else expected_args;

        // Pad missing arguments or trim excess
        if (provided_args < padded_args) {
            const missing = padded_args - provided_args;
            try self.ensureStackCapacity(self.stack_top + missing);
            for (0..missing) |_| self.push(value.Value.initNil());
            provided_args = padded_args;
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
            // An empty splat still takes a slot, shifting the trailing arguments up by one.
            try self.ensureStackCapacity(base_slot + 1 + fixed_arity + 1 + trailing_arity + 3);

            // The caller popped the keyword Map and the block into Zig locals, which the
            // collector can't see: they are rooted here while the Array is allocated, then
            // the Array is rooted while its storage is (the GC swept the block, and `yield`
            // found none).
            if (kwargs_opt) |kwargs| self.push(kwargs);
            if (block_val_opt) |block_val| self.push(block_val);
            const arr_obj = try self.gc.allocateArray(self);
            const arr_val = value.Value.initObj(&arr_obj.obj);
            self.push(arr_val);
            try arr_obj.items.ensureTotalCapacity(self.gc.trackingAllocator(), splat_size);
            _ = self.pop();
            if (block_val_opt != null) _ = self.pop();
            if (kwargs_opt != null) _ = self.pop();

            const start_idx = base_slot + 1 + fixed_arity;
            for (0..splat_size) |i| {
                const item = self.stack[start_idx + i];
                arr_obj.items.appendAssumeCapacity(item);
            }

            if (splat_size != 1 and trailing_arity > 0) {
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

            self.stack[start_idx] = arr_val;
            self.stack_top = start_idx + 1 + trailing_arity;
        }

        // The keyword Map slot, then the implicit block slot
        try self.ensureStackCapacity(self.stack_top + 2);
        if (closure.function.has_kwargs) self.push(kwargs_opt orelse value.Value.initNil());
        if (block_val_opt) |block_val| {
            self.push(block_val);
        } else {
            self.push(value.Value.initNil());
        }

        // Pad Virtual Local Slots perfectly
        const total_locals = closure.function.local_count;
        const current_frame_size = self.stack_top - base_slot;
        const locals_to_pad = if (total_locals > current_frame_size) total_locals - current_frame_size else 0;
        try self.reserveFrame(closure.function, locals_to_pad);
        for (0..locals_to_pad) |_| self.push(value.Value.initNil());
    }

    /// Makes room for a frame of `function` about to start, past its `locals_to_pad`: the
    /// deepest the compiler saw its code push (max_stack_slots), plus NATIVE_STACK_RESERVE
    /// for the natives it calls. With that reserved up front, running out of memory is an
    /// error here instead of a panic in `push`.
    fn reserveFrame(self: *VM, function: *value.ObjFunction, locals_to_pad: usize) !void {
        const exec_chunk: *chunk.Chunk = @ptrCast(@alignCast(function.chunk.?));
        self.ensureStackCapacity(self.stack_top + locals_to_pad + exec_chunk.max_stack_slots + NATIVE_STACK_RESERVE) catch |err| {
            self.runtimeError("Fatal: out of memory growing the VM stack.", .{});
            return err;
        };
    }

    /// `has_block`: the last of the `arg_count` arguments is the call's block (see
    /// chunk.CallFlags); a trailing lambda without it is an ordinary argument.
    /// `has_kwargs`: the argument before the block is the call's keyword Map.
    pub fn dispatchClosure(self: *VM, closure: *value.ObjClosure, arg_count: usize, base_slot: usize, is_constructor: bool, has_block: bool, has_kwargs: bool) InterpretResult {
        if (self.frames.items.len >= self.max_call_frames) {
            self.runtimeError("Call stack overflow: deeper than {d} calls (a recursion that never ends?).", .{self.max_call_frames});
            return .runtime_error;
        }
        self.frames.ensureUnusedCapacity(self.allocator, 1) catch |err| return self.allocationFailed(err);

        var provided_args = arg_count;
        var block_val: ?value.Value = null;
        var kwargs: ?value.Value = null;

        if (has_block) {
            block_val = self.pop();
            provided_args -= 1;
        }
        if (has_kwargs) {
            kwargs = self.pop();
            provided_args -= 1;
        }

        const func = closure.function;
        if (kwargs != null and !func.has_kwargs) {
            return self.raiseError(.ArgumentError, "{s} takes no keyword arguments", .{self.closureName(closure)});
        }
        // A def takes the arguments it declares; a block or lambda is lenient (missing
        // ones are nil, extra ones dropped), as documented.
        if (func.is_method) if (self.arityError(closure, provided_args)) |res| return res;

        // Execute unified padding logic
        self.padClosureFrame(closure, provided_args, base_slot, kwargs, block_val) catch |err| return self.allocationFailed(err);

        if (self.profiler) |p| {
            p.enterFrame(self.closureName(closure)) catch |err| {
                log.err("Profiler error: {}", .{err});
            };
        }

        self.frames.appendAssumeCapacity(.{
            .closure = closure,
            .ip = 0,
            .base_slot = base_slot,
            .is_constructor = is_constructor,
        });
        return .ok;
    }

    pub fn callClosureSync(self: *VM, closure: *value.ObjClosure, args: []const value.Value) !value.Value {
        return self.callClosureWith(closure, value.Value.initObj(&closure.obj), args, false);
    }

    /// Calls a method (`to_s` for display) on `receiver` and runs it to completion.
    pub fn callMethodSync(self: *VM, receiver: value.Value, method: *value.ObjClosure, args: []const value.Value) !value.Value {
        return self.callClosureWith(method, receiver, args, false);
    }

    /// callClosureSync with the frame's slot 0 (`self_val`: the closure itself for a block
    /// or lambda, the receiver for a method) and `has_kwargs`, which says the last of
    /// `args` is the call's keyword Map (a `yield x, key: v`) for the keyword slot.
    fn callClosureWith(self: *VM, closure: *value.ObjClosure, self_val: value.Value, args: []const value.Value, has_kwargs: bool) !value.Value {
        if (self.frames.items.len >= self.max_call_frames) {
            self.runtimeError("Call stack overflow: deeper than {d} calls (a recursion that never ends?).", .{self.max_call_frames});
            return error.RuntimeError;
        }
        try self.frames.ensureUnusedCapacity(self.allocator, 1);

        const target_depth = self.frames.items.len;
        const throw_seq = self.throw_seq;
        const positional = if (has_kwargs) args[0 .. args.len - 1] else args;
        const kwargs: ?value.Value = if (has_kwargs) args[args.len - 1] else null;
        const expected_args = closure.function.arity;

        // Ensure stack capacity for closure, args, padded nils, the keyword Map and the implicit null block
        const total_pushes = 1 + @max(positional.len, expected_args) + 2;
        try self.ensureStackCapacity(self.stack_top + total_pushes);

        const base_slot = self.stack_top; // Record where slot 0 lands exactly

        self.push(self_val);

        for (positional) |arg| self.push(arg);

        // A sync call passes no block; the keyword Map stays rooted in the caller's args
        try self.padClosureFrame(closure, positional.len, base_slot, kwargs, null);

        if (self.profiler) |p| {
            const func_name = if (closure.function.name) |n| n.chars else "block";
            p.enterFrame(func_name) catch |err| {
                log.err("Profiler error: {}", .{err});
            };
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

        // A rescue OUTSIDE this call caught an exception and unwound past us. The stack
        // height can't tell: a handler whose region starts at our base slot leaves exactly
        // one value (the error) there, like a normal return. The throw's target can.
        if (self.unwoundPast(throw_seq, target_depth)) return error.Unwind;

        if (res != .ok) return error.FatalError;

        return self.pop();
    }

    pub fn allocateCrossSection(self: *VM, dag_idx: u32) !value.Value {
        const cs_obj = try self.gc.allocateCrossSection(self, dag_idx);
        return value.Value.initCrossSection(cs_obj);
    }

    // --- Shared Execution Helpers ---
    /// `==`, also behind `contains?` and `case`/`when`: Numbers by value, Arrays, Maps and
    /// Ranges by content (a Map's order doesn't matter), everything else by identity
    /// (Strings and Symbols are interned, so identity is content). Arrays and Maps
    /// compared by identity before, so `[1] == [1]` was false.
    pub fn valuesEqual(self: *VM, a: value.Value, b: value.Value) bool {
        return self.valuesEqualWithin(a, b, MAX_EQUALITY_DEPTH);
    }

    fn valuesEqualWithin(self: *VM, a: value.Value, b: value.Value, depth: usize) bool {
        if (a.isEqual(b)) return true;
        if (!a.isObject() or !b.isObject()) return false;
        // Two structures nesting (or referring to themselves) deeper than this aren't equal.
        if (depth == 0) return false;
        if (a.isArray() and b.isArray()) {
            const xs = a.asArray().items.items;
            const ys = b.asArray().items.items;
            if (xs.len != ys.len) return false;
            for (xs, ys) |x, y| {
                if (!self.valuesEqualWithin(x, y, depth - 1)) return false;
            }
            return true;
        }
        if (a.isMap() and b.isMap()) {
            const xm = a.asMap().map;
            const ym = b.asMap().map;
            if (xm.count() != ym.count()) return false;
            for (xm.keys(), xm.values()) |key, x| {
                const y = ym.get(key) orelse return false;
                if (!self.valuesEqualWithin(x, y, depth - 1)) return false;
            }
            return true;
        }
        if (a.isRange() and b.isRange()) {
            const x = a.asRange();
            const y = b.asRange();
            return x.start == y.start and x.end == y.end and x.step == y.step and x.is_exclusive == y.is_exclusive;
        }
        return false;
    }

    pub fn findMapKey(self: *VM, map: *value.ObjMap, key: value.Value) ?usize {
        _ = self;
        return map.map.getIndex(key);
    }

    /// The i64 a number stands for in a bitwise op (truncated toward zero), or null
    /// when it is NaN, infinite or outside i64.
    fn bitwiseOperand(num: f64) ?i64 {
        if (!std.math.isFinite(num) or num < -I64_FLOAT_BOUND or num >= I64_FLOAT_BOUND) return null;
        return @intFromFloat(num);
    }

    fn executeBinaryArithmetic(self: *VM, op: chunk.OpCode) InterpretResult {
        const b_val = self.pop();
        const a_val = self.pop();
        if (a_val.isNumber() and b_val.isNumber()) {
            const a_num = a_val.asNumber();
            const b_num = b_val.asNumber();
            if (op == .op_add or op == .op_subtract) {
                const res = if (op == .op_add) a_num + b_num else a_num - b_num;
                if (overflowed(a_num, b_num, res)) return self.overflowError(op, a_num, b_num);
                self.push(value.Value.initNumber(res));
                return .ok;
            }

            // @intFromFloat is illegal for NaN/inf/out-of-range operands, so bitwise
            // operands must be checked first; fractions still truncate toward zero.
            const a_int = bitwiseOperand(a_num) orelse
                return self.raiseError(.RangeError, "Bitwise operand {f} is not a finite 64-bit integer.", .{value.fmtNumber(a_num)});
            const b_int = bitwiseOperand(b_num) orelse
                return self.raiseError(.RangeError, "Bitwise operand {f} is not a finite 64-bit integer.", .{value.fmtNumber(b_num)});

            const res: i64 = switch (op) {
                .op_bitwise_and => a_int & b_int,
                .op_bitwise_or => a_int | b_int,
                .op_bitwise_xor => a_int ^ b_int,
                .op_shift_left, .op_shift_right => blk: {
                    if (b_int < 0 or b_int >= BITWISE_INT_BITS) {
                        return self.raiseError(.RangeError, "Shift count {d} is outside 0..{d}.", .{ b_int, BITWISE_INT_BITS - 1 });
                    }
                    const count: std.math.Log2Int(i64) = @intCast(b_int);
                    // `<<` wraps bits shifted out of the top; `>>` is arithmetic (sign-filling)
                    break :blk if (op == .op_shift_left) a_int << count else a_int >> count;
                },
                else => unreachable,
            };

            self.push(value.Value.initNumber(@floatFromInt(res)));
            return .ok;
        } else if (op == .op_add and a_val.isString() and b_val.isString()) {
            const a_str = a_val.asString().chars;
            const b_str = b_val.asString().chars;

            // --- DOD: Stack buffer for string concats <= 1KB ---
            const total_len = a_str.len + b_str.len;
            // SAFETY: Unconditionally initialized by string allocation before any subsequent reads
            var str_val: value.Value = undefined;

            if (total_len <= MAX_STACK_STRING_LEN) {
                var stack_buf: [MAX_STACK_STRING_LEN]u8 = undefined;
                @memcpy(stack_buf[0..a_str.len], a_str);
                @memcpy(stack_buf[a_str.len..total_len], b_str);
                str_val = self.allocateString(stack_buf[0..total_len]) catch |err| return self.allocationFailed(err);
            } else {
                const heap_buf = self.allocator.alloc(u8, total_len) catch |err| return self.allocationFailed(err);
                defer self.allocator.free(heap_buf);
                @memcpy(heap_buf[0..a_str.len], a_str);
                @memcpy(heap_buf[a_str.len..total_len], b_str);
                str_val = self.allocateString(heap_buf) catch |err| return self.allocationFailed(err);
            }

            self.push(str_val);
            return .ok;
        } else if (op == .op_add and a_val.isArray() and b_val.isArray()) {
            self.push(a_val);
            self.push(b_val);

            const a_arr = a_val.asArray();
            const b_arr = b_val.asArray();
            const new_arr = self.gc.allocateArray(self) catch |err| return self.allocationFailed(err);
            const new_val = value.Value.initObj(&new_arr.obj);

            new_arr.items.ensureTotalCapacity(self.gc.trackingAllocator(), a_arr.items.items.len + b_arr.items.items.len) catch |err| return self.allocationFailed(err);
            new_arr.items.appendSliceAssumeCapacity(a_arr.items.items);
            new_arr.items.appendSliceAssumeCapacity(b_arr.items.items);

            // Un-root the old arrays and push the new one
            _ = self.pop(); // Pop b_val
            _ = self.pop(); // Pop a_val
            self.push(new_val);
            return .ok;
        } else if (self.host.binary_handler) |handler| {
            const result = handler(self, op, a_val, b_val) catch |err| {
                if (err == error.UnsupportedOperands) return self.operandError(op, a_val, b_val);
                return self.nativeFailed(operatorSymbol(op), err);
            };

            self.stack.ptr[self.stack_top] = result;
            self.stack_top += 1;
            return .ok;
        } else {
            return self.operandError(op, a_val, b_val);
        }
    }

    inline fn executeNumericBinary(self: *VM, op: chunk.OpCode) InterpretResult {
        const b = self.pop();
        const a = self.pop();
        if (!a.isNumber() or !b.isNumber()) return self.operandError(op, a, b);
        const nums = .{ a.asNumber(), b.asNumber() };
        switch (op) {
            .op_multiply => {
                const res = nums[0] * nums[1];
                if (std.math.isNan(res)) return self.raiseError(.MathError, "Operation resulted in NaN.", .{});
                if (overflowed(nums[0], nums[1], res)) return self.overflowError(op, nums[0], nums[1]);
                self.push(value.Value.initNumber(res));
            },
            .op_divide => {
                if (nums[1] == 0.0) return self.raiseError(.ZeroDivisionError, "Division by zero.", .{});
                const res = nums[0] / nums[1];
                if (std.math.isNan(res)) return self.raiseError(.MathError, "Operation resulted in NaN.", .{});
                if (overflowed(nums[0], nums[1], res)) return self.overflowError(op, nums[0], nums[1]);
                self.push(value.Value.initNumber(res));
            },
            .op_modulo => {
                if (nums[1] == 0.0) return self.raiseError(.ZeroDivisionError, "Modulo by zero.", .{});
                const res = value.flooredMod(nums[0], nums[1]);
                if (std.math.isNan(res)) return self.raiseError(.MathError, "Operation resulted in NaN.", .{});
                self.push(value.Value.initNumber(res));
            },
            .op_exponent => {
                const res = std.math.pow(f64, nums[0], nums[1]);
                if (std.math.isNan(res)) return self.raiseError(.MathError, "Operation resulted in NaN.", .{});
                if (overflowed(nums[0], nums[1], res)) return self.overflowError(op, nums[0], nums[1]);
                self.push(value.Value.initNumber(res));
            },
            .op_less => self.push(value.Value.initBool(nums[0] < nums[1])),
            .op_greater => self.push(value.Value.initBool(nums[0] > nums[1])),
            .op_less_equal => self.push(value.Value.initBool(nums[0] <= nums[1])),
            .op_greater_equal => self.push(value.Value.initBool(nums[0] >= nums[1])),
            else => unreachable,
        }
        return .ok;
    }

    /// Imports a module: from the cache, or read, compiled by the host (Host.compile_module), verified, run and cached.
    /// Null to go on to the next instruction; a result is runUntil's to return.
    fn executeImport(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk, is_wide: bool) ?InterpretResult {
        const path_idx = self.readOperand(exec_chunk, frame, is_wide);
        const path_val = exec_chunk.constants.items[path_idx];
        const path_str = path_val.asString().chars;

        // 1. Check Module Cache
        if (self.modules.get(path_str)) |cached_mod| {
            self.push(cached_mod);
            return null;
        }
        if (self.loading_modules.contains(path_str)) {
            if (self.raiseError(.ImportError, "Circular dependency detected for '{s}'", .{path_str}) != .ok) return .runtime_error;
            return null;
        }

        // 2. Fetch from VFS
        const source = self.vfs.readFile(self.allocator, path_str) catch {
            if (self.raiseError(.ImportError, "Could not read module '{s}'", .{path_str}) != .ok) return .runtime_error;
            return null;
        };
        defer self.allocator.free(source);

        // --- IMPORT DEPTH LIMIT ---
        if (self.import_depth >= MAX_IMPORT_DEPTH) {
            if (self.raiseError(.ImportError, "Maximum import depth of 64 exceeded", .{}) != .ok) return .runtime_error;
            return null;
        }
        self.import_depth += 1;
        defer self.import_depth -= 1;

        // 3. Compile it into its own top-level scope: its variables, defs and
        // classes live there, and only exported names reach the importer.
        const namespace = self.newModuleNamespace() catch |err| return self.allocationFailed(err);
        const compile_module = self.host.compile_module orelse {
            if (self.raiseError(.ImportError, "this host can't compile modules, so '{s}' can't be imported", .{path_str}) != .ok) return .runtime_error;
            return null;
        };
        const caller_depth = self.frames.items.len;
        const throw_seq = self.throw_seq;
        const heap_chunk = compile_module(self, path_str, source, namespace) catch {
            if (self.alreadyThrown(throw_seq, caller_depth)) |res| {
                if (res != .ok) return res;
                return null;
            }
            return .runtime_error;
        };
        // `errdefer` never fires here (this function returns InterpretResult, not an
        // error union), so ownership is tracked explicitly until a function owns the chunk.
        var chunk_owned_by_func = false;
        defer if (!chunk_owned_by_func) {
            heap_chunk.free(self.allocator);
            self.allocator.destroy(heap_chunk);
        };

        if (!self.verifyBytecode(heap_chunk)) {
            if (self.raiseError(.ImportError, "Invalid bytecode for '{s}'", .{path_str}) != .ok) return .runtime_error;
            return null;
        }

        // 5. Setup Closure
        const func = self.gc.allocateFunction(self) catch |err| return self.allocationFailed(err);
        func.chunk = heap_chunk;
        func.owns_chunk = true;
        func.local_count = heap_chunk.local_count;
        func.namespace = namespace;
        chunk_owned_by_func = true; // freed with func by the GC from here on

        // Root func while allocateClosure may collect
        self.push(value.Value.initObj(&func.obj));
        const closure = self.gc.allocateClosure(self, func) catch |err| return self.allocationFailed(err);
        _ = self.pop();

        // --- CIRCULAR DEPENDENCY: the import in progress. (A nil in the cache
        // used to mark it, so a module whose value is nil, one ending in a def or
        // a puts, was "circular" the second time it was imported.)
        self.loading_modules.put(self.allocator, path_str, {}) catch |err| return self.allocationFailed(err);
        defer _ = self.loading_modules.remove(path_str);

        // 6. Execute synchronously
        const import_depth = self.frames.items.len;
        const res = self.callClosureSync(closure, &[_]value.Value{}) catch |err| {
            if (err == error.ExecutionLimitExceeded) return .execution_limit_exceeded;
            if (err == error.Unwind) {
                // Stack unwound by an exception raised inside the module; resume at the handler
                self.restoreAfterUnwind(import_depth);
                return null;
            }
            return .runtime_error;
        };

        // Extract the __exports__ module if built by export statements
        var final_res = res;
        if (namespace.globals.get("__exports__")) |exp_mod| {
            final_res = exp_mod;
            namespace.remove(self.allocator, "__exports__");
        }

        // 7. Cache the actual finalized module and yield result
        self.cacheModule(path_str, final_res) catch |err| return self.allocationFailed(err);
        self.push(final_res);
        return null;
    }

    /// `receiver.name`: an instance field, a reader method called, a module or class member, or a method of a value class.
    /// Null to go on to the next instruction; a result is runUntil's to return.
    inline fn executeGetProperty(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk, is_wide: bool) ?InterpretResult {
        const name_val = self.readValueOperand(exec_chunk, frame, is_wide);
        const name_str = name_val.asString().chars;
        const ic = self.readInlineCache(exec_chunk, frame);
        const receiver = self.stack[self.stack_top - 1];

        if (receiver.isInstance()) {
            const instance = receiver.asInstance();

            // --- 1. Property Fast/Slow Path ---
            if (self.getPropertyCached(instance, name_val, ic)) |prop_val| {
                self.stack[self.stack_top - 1] = prop_val;
                return null;
            }

            // --- 2. Method Fallback: a reader is called (`q.p ||= 6` read the
            // attr_accessor's reader as a value, a truthy method object, and kept it).
            // The site's cache remembers the method, as a call site's does: without
            // it every read walked the class chain and tried the private name.
            if (self.findMethodWithPrivacy(instance.class, name_val, ic).method) |method_val| {
                if (method_val.isNative()) {
                    const res = self.executeNative(method_val.asNative(), 0, self.stack.ptr + self.stack_top, false);
                    if (res != .ok) return res;
                    return null;
                }
                if (!method_val.isClosure()) {
                    if (self.raiseError(.TypeError, "'{s}' is not callable", .{name_str}) != .ok) return .runtime_error;
                    return null;
                }
                const depth = self.frames.items.len;
                const read = self.callMethodSync(receiver, method_val.asClosure(), &.{}) catch |err| {
                    if (err == error.ExecutionLimitExceeded) return .execution_limit_exceeded;
                    if (err == error.Unwind) {
                        self.restoreAfterUnwind(depth);
                        return null;
                    }
                    return .runtime_error;
                };
                self.stack[self.stack_top - 1] = read;
                return null;
            }

            // Gracefully return nil for uninitialized variables instead of crashing
            self.stack[self.stack_top - 1] = value.Value.initNil();
            return null;
        } else if (receiver.isModule()) {
            const mod = receiver.asModule();
            if (mod.methods.get(name_val)) |val| {
                self.stack[self.stack_top - 1] = val;
                return null;
            }
            if (self.raiseError(.NameError, "Undefined module member '{s}'.", .{name_str}) != .ok) return .runtime_error;
            return null;
        } else if (receiver.isClass()) {
            const cls = receiver.asClass();
            if (cls.class_fields.get(name_val)) |val| {
                self.stack[self.stack_top - 1] = val;
                return null;
            }
            if (self.raiseError(.NameError, "Undefined class member '{s}'.", .{name_str}) != .ok) return .runtime_error;
            return null;
        } else if (self.getClass(receiver)) |class| {
            if (self.findMethodWithPrivacy(class, name_val, null).method) |method_val| {
                self.stack[self.stack_top - 1] = method_val;
                return null;
            }
            if (self.raiseError(.NoMethodError, "Method '{s}' not found on receiver.", .{name_str}) != .ok) return .runtime_error;
            return null;
        }

        if (self.raiseError(.TypeError, "Only instances have properties.", .{}) != .ok) return .runtime_error;
        return null;
    }

    /// `super(...)`: the running method of the class above the one that defines it, on the same receiver.
    /// Null to go on to the next instruction; a result is runUntil's to return.
    inline fn executeSuperInvoke(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk, target_depth: usize) ?InterpretResult {
        const raw_count = exec_chunk.code.items[frame.ip];
        const flags: chunk.CallFlags = @bitCast(exec_chunk.code.items[frame.ip + 1]);
        frame.ip += 2;

        const base_slot = self.stack_top - 1 - raw_count;
        const call = self.prepareCallArgs(base_slot, raw_count, flags) catch |err| {
            if (self.callArgsError(err) != .ok) return .runtime_error;
            return null;
        };
        const arg_count = call.count;

        // The method this code belongs to, through blocks (the compiler rejects super
        // outside a def, so it exists).
        const home = homeMethod(frame) orelse return self.raiseError(.TypeError, "super can only be called inside a method", .{});
        const method_name_str = if (home.function.name) |n| n.chars else "";
        const method_name_val = if (home.function.name) |n| value.Value.initObj(&n.obj) else self.allocateString("") catch |err| return self.allocationFailed(err);

        const receiver = self.stack[base_slot];

        if (receiver.isInstance()) {
            const instance = receiver.asInstance();
            // From above the class that defines the running method, not the receiver's
            // class: with C < B < A, B#foo's super on a C found B#foo again, forever.
            const defining = home.home_class orelse instance.class;
            const superclass = defining.superclass orelse {
                return self.raiseError(.RuntimeError, "No superclass exists for receiver.", .{});
            };

            // Use new Privacy Resolution Helper
            const resolved = self.findMethodWithPrivacy(superclass, method_name_val, null);

            if (resolved.method) |m_val| {
                if (m_val.isClosure()) {
                    const res = self.dispatchClosure(m_val.asClosure(), arg_count, base_slot, false, call.has_block, call.has_kwargs);
                    if (res != .ok) return res;
                    return null;
                } else if (m_val.isNative()) {
                    const args_ptr = self.stack.ptr + base_slot + 1;
                    const res = self.executeNative(m_val.asNative(), arg_count, args_ptr, call.has_block);
                    if (self.afterCall(res, target_depth)) |out| return out;
                    return null;
                } else {
                    if (self.raiseError(.RuntimeError, "Superclass method '{s}' is not callable.", .{method_name_str}) != .ok) return .runtime_error;
                    return null;
                }
            }

            if (self.raiseError(.NoMethodError, "Superclass method '{s}' not found.", .{method_name_str}) != .ok) return .runtime_error;
            return null;
        }

        if (self.raiseError(.TypeError, "super can only be called on instances.", .{}) != .ok) return .runtime_error;
        return null;
    }

    /// `yield(...)`: calls the block of the method the code is in.
    /// Null to go on to the next instruction; a result is runUntil's to return.
    inline fn executeYield(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk, target_depth: usize) ?InterpretResult {
        const raw_count = exec_chunk.code.items[frame.ip];
        const flags: chunk.CallFlags = @bitCast(exec_chunk.code.items[frame.ip + 1]);
        frame.ip += 2;
        const yield_call = self.prepareCallArgs(self.stack_top - 1 - raw_count, raw_count, flags) catch |err| {
            if (self.callArgsError(err) != .ok) return .runtime_error;
            return null;
        };
        const yield_arg_count = yield_call.count;

        const block_val = self.frameBlock(frame);
        if (!block_val.isClosure()) {
            if (self.raiseError(.ArgumentError, "No block given to yield.", .{}) != .ok) return .runtime_error;
            return null;
        }

        const block_closure = block_val.asClosure();
        const args_ptr = self.stack.ptr + self.stack_top - yield_arg_count;
        const yield_args = args_ptr[0..yield_arg_count];

        // Safely propagate limits through native yields
        const yield_depth = self.frames.items.len;
        const result = self.callClosureWith(block_closure, value.Value.initObj(&block_closure.obj), yield_args, yield_call.has_kwargs) catch |err| {
            if (err == error.ExecutionLimitExceeded) return .execution_limit_exceeded;
            if (err == error.BlockBreak) {
                self.popAndRelease(yield_arg_count);
                // A block yielded to sits in its method's block slot, so the break
                // found that frame; should the slot have been reassigned, this
                // frame is the one to leave.
                if (self.pending_break.?.target == null) self.pending_break.?.target = self.frames.items.len - 1;
                if (self.carryBreak(target_depth)) |res| return res;
                return null;
            }
            if (err == error.Unwind) {
                // The stack has been forcefully unwound past this frame.
                // Continue the run loop to either execute the rescue handler or terminate natively.
                self.restoreAfterUnwind(yield_depth);
                return null;
            }
            return .runtime_error;
        };

        // Pop yielded args off stack
        self.popAndRelease(yield_arg_count);
        self.push(result);
        return null;
    }

    inline fn executeInvoke(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk, is_wide: bool) InterpretResult {
        const method_name_val = self.readValueOperand(exec_chunk, frame, is_wide);
        const method_name_str = method_name_val.asString().chars;
        const raw_count = exec_chunk.code.items[frame.ip];
        const flags: chunk.CallFlags = @bitCast(exec_chunk.code.items[frame.ip + 1]);
        frame.ip += 2;

        // Prevent usize underflow if stack is corrupted
        std.debug.assert(self.stack_top > raw_count);

        // Read IC
        const ic = self.readInlineCache(exec_chunk, frame);
        const base_slot = self.stack_top - 1 - raw_count;
        const call = self.prepareCallArgs(base_slot, raw_count, flags) catch |err| return self.callArgsError(err);
        const arg_count = call.count;
        const receiver = self.stack[base_slot];
        const args_ptr = self.stack.ptr + base_slot + 1;

        // Resolve Class of Receiver seamlessly
        const class_obj: ?*value.ObjClass = self.getClass(receiver);

        // --- 1. METHOD LOOKUP ---
        var method_val: ?value.Value = null;
        var is_private_call = false;

        if (receiver.isClass()) {
            // A class's own `new` (such as Array.new) comes first; otherwise instantiate it.
            if (std.mem.eql(u8, method_name_str, "new") and receiver.asClass().class_methods.get(method_name_val) == null) {
                return self.constructInstance(receiver.asClass(), arg_count, base_slot, call.has_block, call.has_kwargs);
            }

            const resolved = self.findClassMethodWithPrivacy(receiver.asClass(), method_name_val);
            method_val = resolved.method;
            is_private_call = resolved.is_private;

            // Fallback to Object methods (so Class.respond_to? works)
            if (method_val == null and self.object_class != null) method_val = self.findMethod(self.object_class.?, method_name_val);
        } else if (receiver.isModule()) {
            // Check the module's own methods first
            if (receiver.asModule().methods.get(method_name_val)) |m| {
                method_val = m;
            } else if (self.object_class != null) {
                // Fallback to Object methods for modules
                method_val = self.findMethod(self.object_class.?, method_name_val);
            }
        } else if (class_obj) |c| {
            // A field read written as a call (`p.x`): the cache remembers it is a field, so
            // the hierarchy isn't searched again (it was, on every call).
            self.refreshInlineCache(ic);
            if (receiver.isInstance() and arg_count == 0) {
                if (ic.fieldOffset(c)) |idx| {
                    const instance = receiver.asInstance();
                    self.popAndRelease(1); // Pop receiver
                    self.push(if (idx < instance.fields.items.len) instance.fields.items[idx] else value.Value.initNil());
                    return .ok;
                }
            }
            const resolved = self.findMethodWithPrivacy(c, method_name_val, ic);
            method_val = resolved.method;
            is_private_call = resolved.is_private;
        } else if (self.object_class) |object_class| {
            // Every value is an Object: nil or a lambda still answer `inspect`, `class`, ...
            method_val = self.findMethod(object_class, method_name_val);
        }

        // --- ENFORCE VISIBILITY ---
        if (is_private_call and !self.privateCallAllowed(frame, receiver)) {
            return self.raiseError(.NoMethodError, "private method '{s}' called.", .{method_name_str});
        }

        // Dispatch Method if Found
        if (method_val) |m_val| {
            if (m_val.isNative()) {
                return self.executeNative(m_val.asNative(), arg_count, args_ptr, call.has_block);
            } else if (m_val.isClosure()) {
                return self.dispatchClosure(m_val.asClosure(), arg_count, base_slot, false, call.has_block, call.has_kwargs);
            }
        }

        // --- 2. PROPERTY FALLBACK (Instances only when no method matches) ---
        if (receiver.isInstance() and arg_count == 0) {
            const instance = receiver.asInstance();
            if (instance.class.instance_layout.get(method_name_val)) |idx| {
                ic.remember(instance.class, value.Value.initNil(), idx);

                self.popAndRelease(1); // Pop receiver
                if (idx < instance.fields.items.len) {
                    self.push(instance.fields.items[idx]);
                } else {
                    self.push(value.Value.initNil());
                }
                return .ok;
            }
        }

        // --- `.call()` on a callable value (lambda, block, bound method) ---
        if (std.mem.eql(u8, method_name_str, "call") and (receiver.isClosure() or receiver.isBoundMethod())) {
            return self.callValue(receiver, arg_count, base_slot, call.has_block, call.has_kwargs);
        }

        // Nothing answers it. The host's invoke handler only ever said this, and without one
        // the VM said "No invoke handler registered".
        return self.raiseError(.NoMethodError, "undefined method '{s}' for {s}", .{ method_name_str, self.typeName(receiver) });
    }

    inline fn executeUnpackSplat(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk) InterpretResult {
        const pre_count = exec_chunk.code.items[frame.ip];
        const post_count = exec_chunk.code.items[frame.ip + 1];
        frame.ip += 2;

        const val = self.stack[self.stack_top - 1];

        if (val.isArray()) {
            const arr = val.asArray();
            const total = arr.items.items.len;

            for (0..pre_count) |i| {
                if (i < total) self.push(arr.items.items[i]) else self.push(value.Value.initNil());
            }

            const splat_arr = self.gc.allocateArray(self) catch |err| return self.allocationFailed(err);
            const splat_val = value.Value.initObj(&splat_arr.obj);
            self.push(splat_val);

            if (total > pre_count + post_count) {
                const splat_size = total - pre_count - post_count;
                splat_arr.items.ensureTotalCapacity(self.gc.trackingAllocator(), splat_size) catch return self.raiseError(.OutOfMemoryError, "Splat unpack failed", .{});
                splat_arr.items.appendSliceAssumeCapacity(arr.items.items[pre_count .. pre_count + splat_size]);
            }

            _ = self.pop();
            const base_slot = self.stack_top - pre_count - 1;

            if (pre_count > 0) {
                const src = self.stack[base_slot + 1 .. base_slot + 1 + pre_count];
                const dest = self.stack[base_slot .. base_slot + pre_count];
                std.mem.copyForwards(value.Value, dest, src);
            }
            self.stack_top -= 1;
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
            _ = self.pop();
            if (pre_count > 0) {
                self.push(val);
                for (1..pre_count) |_| self.push(value.Value.initNil());
                const empty_arr = self.gc.allocateArray(self) catch |err| return self.allocationFailed(err);
                self.push(value.Value.initObj(&empty_arr.obj));
                for (0..post_count) |_| self.push(value.Value.initNil());
            } else if (post_count > 0) {
                const empty_arr = self.gc.allocateArray(self) catch |err| return self.allocationFailed(err);
                self.push(value.Value.initObj(&empty_arr.obj));
                for (0..post_count - 1) |_| self.push(value.Value.initNil());
                self.push(val);
            } else {
                const arr_obj = self.gc.allocateArray(self) catch |err| return self.allocationFailed(err);
                self.push(value.Value.initObj(&arr_obj.obj));
                arr_obj.items.append(self.gc.trackingAllocator(), val) catch |err| return self.allocationFailed(err);
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

        const block_val = self.stack[self.stack_top - 1]; // Grab the implicit block early

        // The arguments start at frame.base_slot + 1 and end exactly before the block
        const total_args_passed = (self.stack_top - 1) - (frame.base_slot + 1);

        var splat_size: usize = 0;
        if (total_args_passed > fixed_arity + trailing_arity) {
            splat_size = total_args_passed - fixed_arity - trailing_arity;
        }

        const arr_obj = self.gc.allocateArray(self) catch |err| return self.allocationFailed(err);
        const arr_val = value.Value.initObj(&arr_obj.obj);

        self.push(arr_val);
        arr_obj.items.ensureTotalCapacity(self.gc.trackingAllocator(), splat_size) catch return self.raiseError(.OutOfMemoryError, "Splat pack failed", .{});
        _ = self.pop();

        const start_idx = frame.base_slot + 1 + fixed_arity;
        arr_obj.items.appendSliceAssumeCapacity(self.stack[start_idx .. start_idx + splat_size]);

        if (splat_size != 1) {
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

        self.stack[start_idx] = arr_val;
        self.shrinkStack(start_idx + 1 + trailing_arity);
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
            const range_obj = self.gc.allocateRange(self, start_val.asNumber(), end_val.asNumber(), step_val.asNumber(), is_exclusive) catch |err| return self.allocationFailed(err);
            self.push(value.Value.initObj(&range_obj.obj));
        } else if (start_val.isString() and end_val.isString()) {
            // Re-root the strings to prevent GC sweep
            self.push(start_val);
            self.push(end_val);

            const s_str = start_val.asString().chars;
            const e_str = end_val.asString().chars;

            if (s_str.len == 1 and e_str.len == 1) {
                const arr_obj = self.gc.allocateArray(self) catch |err| return self.allocationFailed(err);
                const arr_val = value.Value.initObj(&arr_obj.obj);
                self.push(arr_val); // Protect from GC while building

                // Wider than a byte: `"\xFF"` as an end would overflow `+ 1`.
                var curr: u16 = s_str[0];
                const limit: u16 = if (is_exclusive) e_str[0] else @as(u16, e_str[0]) + 1;

                while (curr < limit) : (curr += 1) {
                    const char_slice = &[_]u8{@intCast(curr)};
                    const char_str = self.allocateString(char_slice) catch |err| return self.allocationFailed(err);
                    arr_obj.items.append(self.gc.trackingAllocator(), char_str) catch |err| return self.allocationFailed(err);
                }

                // Cleanup the protected values
                _ = self.pop(); // Pop arr_val
                _ = self.pop(); // Pop end_val
                _ = self.pop(); // Pop start_val
                self.push(arr_val);
            } else {
                return self.raiseError(.TypeError, "a String range needs single characters, got \"{s}\"..\"{s}\"", .{ start_val.asString().chars, end_val.asString().chars });
            }
        } else {
            return self.raiseError(.TypeError, "a range needs numbers or single characters, got {s}..{s}", .{ self.typeName(start_val), self.typeName(end_val) });
        }
        return .ok;
    }

    /// target[index], with both on the stack: an element of an Array or a character of a
    /// String (negative indexes count from the end), a Range of them (like Array#slice:
    /// nil when it starts past the end, clamped at the end), or a Map's value (nil when
    /// absent). Strings are indexed by character, as `length` counts them.
    /// Pushes the element of a `for` loop's `iterable` after the `taken` ones and returns
    /// true, or returns false when there are no more. A Range yields the values Range#each
    /// does and a Map its [key, value] pairs; an Array is read live, so it may grow while
    /// the loop runs.
    fn pushForElement(self: *VM, iterable: value.Value, taken: u64) error{ RuntimeError, OutOfMemory }!bool {
        if (iterable.isArray()) {
            const items = iterable.asArray().items.items;
            if (taken >= items.len) return false;
            self.push(items[@intCast(taken)]);
            return true;
        }
        if (iterable.isRange()) {
            const r = iterable.asRange();
            const span: sequence.Span = .{ .start = r.start, .end = r.end, .step = r.step, .is_exclusive = r.is_exclusive };
            if (taken >= try sequence.iterationCount(self, span, "for")) return false;
            self.push(value.Value.initNumber(span.at(taken)));
            return true;
        }
        if (iterable.isMap()) {
            const map = &iterable.asMap().map;
            if (taken >= map.count()) return false;
            const pair = try self.gc.allocateArray(self);
            // Rooted before the items are added: appending may run a collection.
            self.push(value.Value.initObj(&pair.obj));
            const i: usize = @intCast(taken);
            try pair.items.appendSlice(self.gc.trackingAllocator(), &.{ map.keys()[i], map.values()[i] });
            return true;
        }
        return self.fail(.TypeError, "for expects an Array, a Range or a Map, got {s}", .{self.typeName(iterable)});
    }

    fn executeGetIndex(self: *VM) InterpretResult {
        const index = self.stack[self.stack_top - 1];
        const target = self.stack[self.stack_top - 2];

        if (target.isMap()) {
            const found = target.asMap().map.get(index) orelse value.Value.initNil();
            self.stack_top -= 2;
            self.push(found);
            return .ok;
        }
        if (!target.isArray() and !target.isString()) {
            return self.raiseError(.TypeError, "{s} can't be indexed with []", .{self.typeName(target)});
        }

        const is_string = target.isString();
        const kind = if (is_string) "String" else "Array";
        const chars = if (is_string) target.asString().chars else "";
        const len = if (is_string) std.unicode.utf8CountCodepoints(chars) catch chars.len else target.asArray().items.items.len;

        const result: value.Value = if (index.isNumber()) blk: {
            const i = self.resolveArrayIndex(len, index) catch return self.indexError(kind, index, len);
            if (!is_string) break :blk target.asArray().items.items[i];
            const span = charSpan(chars, i, 1);
            break :blk self.allocateString(chars[span.start..span.end]) catch |err| return self.allocationFailed(err);
        } else if (index.isRange()) blk: {
            const range = index.asRange();
            if (range.step != 1.0) return self.raiseError(.ArgumentError, "a stepped Range can't index {s} {s}", .{ if (is_string) "a" else "an", kind });
            const span = rangeSpan(range, len) orelse break :blk value.Value.initNil();
            if (is_string) {
                const bytes = charSpan(chars, span.start, span.end - span.start);
                break :blk self.allocateString(chars[bytes.start..bytes.end]) catch |err| return self.allocationFailed(err);
            }
            // `index` stays on the stack, keeping the Range rooted while the Array is built
            const slice = self.gc.allocateArray(self) catch |err| return self.allocationFailed(err);
            slice.items.appendSlice(self.gc.trackingAllocator(), target.asArray().items.items[span.start..span.end]) catch |err| return self.allocationFailed(err);
            break :blk value.Value.initObj(&slice.obj);
        } else {
            return self.raiseError(.TypeError, "{s} index must be an integer or a Range, got {s}", .{ kind, self.typeName(index) });
        };

        self.stack_top -= 2;
        self.push(result);
        return .ok;
    }

    fn indexError(self: *VM, kind: []const u8, index: value.Value, len: usize) InterpretResult {
        const n = index.asNumber();
        if (std.math.trunc(n) != n) return self.raiseError(.TypeError, "{s} index must be an integer, got {f}", .{ kind, value.fmtNumber(n) });
        return self.raiseError(.IndexError, "{s} index {f} is out of bounds (size {d})", .{ kind, value.fmtNumber(n), len });
    }

    const Span = struct { start: usize, end: usize };

    /// The elements a Range selects from `len` (negative bounds count from the end), or
    /// null when it starts outside 0..len, as Array#slice.
    fn rangeSpan(range: *const value.ObjRange, len: usize) ?Span {
        const size: f64 = @floatFromInt(len);
        var first = @trunc(range.start);
        var last = @trunc(range.end);
        if (first < 0) first += size;
        if (last < 0) last += size;
        if (!std.math.isFinite(first) or first < 0 or first > size) return null;
        const stop = std.math.clamp(if (range.is_exclusive) last else last + 1, first, size);
        return .{ .start = @intFromFloat(first), .end = @intFromFloat(stop) };
    }

    /// Byte offsets of `count` characters of UTF-8 `chars` starting at character `first`
    /// (byte offsets themselves for invalid UTF-8, as `length` then counts bytes).
    fn charSpan(chars: []const u8, first: usize, count: usize) Span {
        const view = std.unicode.Utf8View.init(chars) catch return .{ .start = first, .end = first + count };
        var it = view.iterator();
        var start: usize = chars.len;
        var i: usize = 0;
        while (i <= first + count) : (i += 1) {
            if (i == first) start = it.i;
            if (i == first + count) return .{ .start = start, .end = it.i };
            _ = it.nextCodepointSlice() orelse return .{ .start = start, .end = chars.len };
        }
        unreachable;
    }

    inline fn resolveArrayIndex(self: *VM, arr_len: usize, index_val: value.Value) !usize {
        _ = self;
        const num_idx = index_val.asNumber();

        // Prevent floats like `1.5`, `NaN` or `inf` (trunc(inf) == inf) from succeeding,
        // and keep @intFromFloat below in range: any valid index is at most arr_len.
        if (std.math.isNan(num_idx) or std.math.trunc(num_idx) != num_idx) {
            return error.RuntimeError;
        }
        if (@abs(num_idx) > @as(f64, @floatFromInt(arr_len))) return error.RuntimeError;

        if (num_idx < 0) {
            const offset: usize = @intFromFloat(-num_idx);
            if (offset == 0 or offset > arr_len) return error.RuntimeError;
            return arr_len - offset;
        } else {
            const idx: usize = @intFromFloat(num_idx);
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
                .bbox => return self.bbox_class,
                .range => return self.range_class,
                .closure, .function => return self.proc_class,
                .bound_method, .native => return self.method_class,
                .class => return self.class_class,
                .module => return self.module_class,
                .assembly => return self.assembly_class,
                .workplane => return self.workplane_class,
                else => return null,
            }
        } else if (receiver.isNumber()) {
            return self.number_class;
        } else if (receiver.isBool()) {
            return self.boolean_class;
        } else if (receiver.isNil()) {
            return self.nil_class;
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
        return name_val.asString();
    }

    /// Extracts a String character slice from the bytecode stream
    inline fn readStringOperand(self: *VM, exec_chunk: *chunk.Chunk, frame: *CallFrame, is_wide: bool) []const u8 {
        return self.readStringObjectOperand(exec_chunk, frame, is_wide).chars;
    }

    /// Extracts a direct Value (ObjString/ObjSymbol) from the constants pool
    inline fn readValueOperand(self: *VM, exec_chunk: *chunk.Chunk, frame: *CallFrame, is_wide: bool) value.Value {
        const idx = self.readOperand(exec_chunk, frame, is_wide);
        return exec_chunk.constants.items[idx];
    }

    inline fn readOperand(self: *VM, exec_chunk: *chunk.Chunk, frame: *CallFrame, is_wide: bool) u16 {
        _ = self;
        if (is_wide) {
            std.debug.assert(frame.ip + 2 <= exec_chunk.code.items.len); // Hardened check
            const high: u16 = exec_chunk.code.items[frame.ip];
            const low: u16 = exec_chunk.code.items[frame.ip + 1];
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
        const b3: usize = exec_chunk.code.items[frame.ip];
        const b2: usize = exec_chunk.code.items[frame.ip + 1];
        const b1: usize = exec_chunk.code.items[frame.ip + 2];
        const b0: usize = exec_chunk.code.items[frame.ip + 3];
        frame.ip += 4;
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
    }

    inline fn executeCall(self: *VM, frame: *CallFrame, exec_chunk: *chunk.Chunk) InterpretResult {
        const raw_count = exec_chunk.code.items[frame.ip];
        const flags: chunk.CallFlags = @bitCast(exec_chunk.code.items[frame.ip + 1]);
        frame.ip += 2;

        const base_slot = self.stack_top - 1 - raw_count;
        const call = self.prepareCallArgs(base_slot, raw_count, flags) catch |err| return self.callArgsError(err);
        const callee = self.stack[base_slot];

        // `f(x)` calls a function by name. A lambda, block or bound method is a value
        // (a bare `f` never calls it), so it is called like any method: `f.call(x)`.
        const value_kind: ?[]const u8 = if (callee.isBoundMethod())
            "a bound method"
        else if (callee.isClosure() and callee.asClosure().function.is_lambda)
            "a lambda"
        else
            null;
        if (value_kind) |kind| return self.raiseError(.TypeError, "{s} is called with .call(...), not like a function", .{kind});
        return self.callValue(callee, call.count, base_slot, call.has_block, call.has_kwargs);
    }

    const PreparedCall = struct { count: u8, has_block: bool, has_kwargs: bool };
    const CallArgsError = error{ InvalidBlock, TooManyArguments, OutOfMemory };

    /// Applies a call site's CallFlags to the `arg_count` values above `base_slot`: spreads
    /// a packed positional Array onto the stack, and drops a nil block (`f(&nil)` passes
    /// none). Returns the final argument count and whether its last value is the block.
    fn prepareCallArgs(self: *VM, base_slot: usize, arg_count: u8, flags: chunk.CallFlags) CallArgsError!PreparedCall {
        var count: usize = arg_count;
        var has_block = flags.has_block;
        if (has_block) {
            const block = self.stack[self.stack_top - 1];
            if (block.isNil()) {
                _ = self.pop();
                count -= 1;
                has_block = false;
            } else if (!block.isClosure()) {
                return error.InvalidBlock;
            }
        }
        if (flags.spread) count = try self.spreadPositionals(base_slot, count);
        return .{ .count = @intCast(count), .has_block = has_block, .has_kwargs = flags.has_kwargs };
    }

    /// Replaces the positional Array at `base_slot + 1` with its elements, keeping the
    /// values after it (the keyword Map and/or the block) in order.
    fn spreadPositionals(self: *VM, base_slot: usize, count: usize) CallArgsError!usize {
        const packed_args = self.stack[base_slot + 1].asArray().items.items;
        const trailing_count = count - 1;
        std.debug.assert(trailing_count <= MAX_TRAILING_CALL_VALUES);
        var trailing: [MAX_TRAILING_CALL_VALUES]value.Value = undefined;
        @memcpy(trailing[0..trailing_count], self.stack[base_slot + 2 ..][0..trailing_count]);

        const total = packed_args.len + trailing_count;
        if (total > limits.MAX_ARGS) return error.TooManyArguments;
        try self.ensureStackCapacity(base_slot + 1 + total);
        // Nothing below allocates, so the GC cannot run while the Array is off the stack.
        self.stack_top = base_slot + 1;
        for (packed_args) |arg| self.push(arg);
        for (trailing[0..trailing_count]) |arg| self.push(arg);
        return total;
    }

    fn callArgsError(self: *VM, err: CallArgsError) InterpretResult {
        return switch (err) {
            error.InvalidBlock => self.raiseError(.TypeError, "a block argument (&blk) must be a lambda or a block", .{}),
            error.TooManyArguments => self.raiseError(.ArgumentError, "too many arguments after spreading: a call takes at most {d}", .{limits.MAX_ARGS}),
            error.OutOfMemory => self.raiseError(.OutOfMemoryError, "out of memory spreading call arguments", .{}),
        };
    }

    /// Calls `callee` (a function, lambda, bound method or class) with the `arg_count`
    /// arguments above it on the stack; `has_block`: the last of them is the call's block.
    fn callValue(self: *VM, callee: value.Value, arg_count: u8, base_slot: usize, has_block: bool, has_kwargs: bool) InterpretResult {
        if (callee.isBoundMethod()) {
            const bound = callee.asBoundMethod();
            self.stack.ptr[base_slot] = bound.receiver; // Load the actual receiver into the base slot

            if (bound.method.isClosure()) {
                return self.dispatchClosure(bound.method.asClosure(), arg_count, base_slot, false, has_block, has_kwargs);
            } else if (bound.method.isNative()) {
                // Same error protocol as any native call (a block raising inside it must unwind)
                const args_ptr = self.stack.ptr + base_slot + 1;
                return self.executeNative(bound.method.asNative(), arg_count, args_ptr, has_block);
            }
        } else if (callee.isNative()) {
            const args_ptr = self.stack.ptr + base_slot + 1;
            return self.executeNative(callee.asNative(), arg_count, args_ptr, has_block);
        } else if (callee.isClosure()) {
            return self.dispatchClosure(callee.asClosure(), arg_count, base_slot, false, has_block, has_kwargs);
        } else if (callee.isClass()) {
            // `Klass(args)` is sugar for `Klass.new(args)`
            return self.constructInstance(callee.asClass(), arg_count, base_slot, has_block, has_kwargs);
        } else if (arg_count == 0) {
            // Bare identifier evaluation of a non-callable value: leave value on stack
            return .ok;
        } else {
            // `a = 1; a 2` lands here: a call of what the name holds, as in Ruby a method call.
            return self.raiseError(.TypeError, "a {s} can't be called; only methods, built-ins and classes take arguments", .{self.typeName(callee)});
        }
        return .ok;
    }

    /// Instantiates `class_obj` for a call whose receiver sits at `base_slot` with
    /// `arg_count` arguments above it, running `initialize` (a closure or a native,
    /// e.g. Exception's) if the class has one. Leaves the instance at `base_slot`.
    fn constructInstance(self: *VM, class_obj: *value.ObjClass, arg_count: u8, base_slot: usize, has_block: bool, has_kwargs: bool) InterpretResult {
        if (class_obj.is_value_class) {
            const hint = if (class_obj == self.proc_class) "; KupCAD makes them with lambdas: ->(x) { ... }" else "";
            return self.raiseError(.NoMethodError, "undefined method 'new' for {s}{s}", .{ class_obj.name.chars, hint });
        }
        const instance = self.gc.allocateInstance(self, class_obj) catch |err| return self.allocationFailed(err);
        self.stack.ptr[base_slot] = value.Value.initObj(&instance.obj); // Overwrite class with instance safely

        const init_name_val = self.allocateString("initialize") catch |err| return self.allocationFailed(err);
        const init_method = self.findMethod(class_obj, init_name_val) orelse {
            if (arg_count > 0) return self.raiseError(.ArgumentError, "Expected 0 args for default constructor.", .{});
            return .ok;
        };

        if (init_method.isClosure()) {
            // is_constructor: op_return yields the instance, not initialize's last value
            return self.dispatchClosure(init_method.asClosure(), arg_count, base_slot, true, has_block, has_kwargs);
        }
        if (!init_method.isNative()) return self.raiseError(.TypeError, "'{s}#initialize' is not callable.", .{class_obj.name.chars});

        const native_obj = init_method.asNative();
        const args_ptr = self.stack.ptr + base_slot + 1;
        const caller_depth = self.frames.items.len;
        const throw_seq = self.throw_seq;
        // The native's return value is discarded: a constructor always yields the instance
        _ = native_obj.function(self, .{ .ptr = args_ptr, .count = arg_count, .has_block = has_block, .name = native_obj.name }) catch |err| {
            if (err == error.Unwind) {
                self.restoreAfterUnwind(caller_depth);
                return .ok;
            }
            if (err == error.ExecutionLimitExceeded) return .execution_limit_exceeded;
            if (err == error.FatalError) return .runtime_error;
            if (self.alreadyThrown(throw_seq, caller_depth)) |res| return res;
            return self.nativeFailed(native_obj.name, err);
        };
        self.popAndRelease(arg_count);
        return .ok;
    }

    /// Calls `native_obj` with the `arg_count` arguments at `args_ptr` (the receiver just
    /// below them); `has_block`: the last of them is the call's block.
    inline fn executeNative(self: *VM, native_obj: *value.ObjNative, arg_count: u8, args_ptr: [*]value.Value, has_block: bool) InterpretResult {
        // Natives push GC roots without growing the stack themselves (see NATIVE_STACK_RESERVE).
        self.ensureStackCapacity(self.stack_top + NATIVE_STACK_RESERVE) catch return self.raiseError(.OutOfMemoryError, "{s} ran out of memory", .{native_obj.name});
        // Depth of the calling frame, captured before an unwind can pop it
        const caller_depth = self.frames.items.len;
        const throw_seq = self.throw_seq;

        // --- PROFILER: Native Enter ---
        if (self.profiler) |p| p.enterFrame(native_obj.name) catch |err| {
            log.err("Profiler error: {}", .{err});
        };

        const result = native_obj.function(self, .{ .ptr = args_ptr, .count = arg_count, .has_block = has_block, .name = native_obj.name }) catch |err| {
            if (self.profiler) |p| p.exitFrame() catch |e| {
                log.err("Profiler error: {}", .{e});
            };
            if (err == error.ExecutionLimitExceeded) return .execution_limit_exceeded;
            if (err == error.Unwind) {
                self.restoreAfterUnwind(caller_depth);
                return .ok;
            }
            if (err == error.FatalError) return .runtime_error;
            if (err == error.BlockBreak) {
                if (self.pending_break.?.target != null) {
                    // Aimed at a method below this native (`m { break }` where m yields from
                    // inside `each`): the native is done; the calling frame carries it on.
                    self.popAndRelease(arg_count + 1);
                    return .block_break;
                }
                // A `break` in a block the native didn't iterate (highlight { }, benchmark { }).
                self.pending_break = null;
                return self.raiseError(.ArgumentError, "break can only stop a block given to an iterating method, not {s}'s", .{native_obj.name});
            }
            if (self.alreadyThrown(throw_seq, caller_depth)) |res| return res;
            return self.nativeFailed(native_obj.name, err);
        };

        // --- PROFILER: Native Exit ---
        if (self.profiler) |p| p.exitFrame() catch |err| {
            log.err("Profiler error: {}", .{err});
        };

        self.popAndRelease(arg_count + 1);
        self.stack.ptr[self.stack_top] = result;
        self.stack_top += 1;
        return .ok;
    }

    /// Called when a native (or sync closure call) started at `caller_depth` frames
    /// returned error.Unwind. Re-applies the handler's stack layout, which native
    /// defers may have clobbered, and consumes the entry once the boundary sits in
    /// the frame that owns the rescue handler.
    fn restoreAfterUnwind(self: *VM, caller_depth: usize) void {
        const unwind = self.unwind_stack.getLastOrNull() orelse return;
        self.stack_top = unwind.stack_top;
        self.push(unwind.err_val);
        if (caller_depth <= unwind.frame_count) _ = self.unwind_stack.pop();
    }

    /// True when a throw since `throw_seq` was sampled is being handled at or below
    /// `caller_depth` frames, i.e. it unwound the call made from that depth.
    fn unwoundPast(self: *VM, throw_seq: u64, caller_depth: usize) bool {
        if (self.throw_seq == throw_seq) return false;
        const target = self.last_throw_target orelse return false;
        return target <= caller_depth;
    }

    /// A native failed with an ordinary error after `throw_seq` was sampled. If it
    /// already raised an exception that unwound to (or past) its caller's frame, that
    /// exception stands: resume at its handler, or stop if it was uncaught. A throw that
    /// was rescued deeper, inside the native's own callbacks, does not count.
    fn alreadyThrown(self: *VM, throw_seq: u64, caller_depth: usize) ?InterpretResult {
        if (self.throw_seq == throw_seq) return null;
        const target = self.last_throw_target orelse return .runtime_error;
        if (target > caller_depth) return null;
        self.restoreAfterUnwind(caller_depth);
        return .ok;
    }

    /// Joins the `count` fragments on top of the stack into one String (writeDisplay for
    /// each, so an instance's own to_s is called), which replaces them. Short results are
    /// built on the native stack, longer ones on the heap.
    fn executeInterpolate(self: *VM, count: usize) InterpretResult {
        const start_idx = self.stack_top - count;
        const depth = self.frames.items.len;
        const throw_seq = self.throw_seq;
        var stack_buf: [MAX_STACK_STRING_LEN]u8 = undefined;
        var buffer = std.heap.BufferFirstAllocator.init(&stack_buf, self.allocator);
        var out: std.Io.Writer.Allocating = .init(buffer.allocator());
        defer out.deinit();
        for (self.stack[start_idx..self.stack_top]) |val| {
            self.writeDisplay(val, &out.writer) catch |err| switch (err) {
                // A to_s raised: a rescue has the error (resume there) or the run has failed
                error.Unwind => {
                    self.restoreAfterUnwind(depth);
                    return .ok;
                },
                error.ExecutionLimitExceeded => return .execution_limit_exceeded,
                error.OutOfMemory, error.WriteFailed => return self.raiseError(.OutOfMemoryError, "out of memory building a String", .{}),
                else => return self.alreadyThrown(throw_seq, depth) orelse .runtime_error,
            };
        }
        const merged = self.allocateString(out.written()) catch |err| return self.allocationFailed(err);
        self.popAndRelease(count);
        self.push(merged);
        return .ok;
    }

    /// Writes `val` as `puts` and interpolation show it: an instance whose class defines
    /// `to_s` in the script by what that returns (a String, else a TypeError), everything
    /// else as stringify prints it. The method was ignored: an instance showed as "#<P>".
    pub fn writeDisplay(self: *VM, val: value.Value, writer: *std.Io.Writer) !void {
        if (val.isInstance()) {
            const name = try self.allocateString("to_s");
            if (self.findMethod(val.asInstance().class, name)) |method| if (method.isClosure()) {
                const shown = try self.callMethodSync(val, method.asClosure(), &.{});
                if (!shown.isString()) {
                    return self.fail(.TypeError, "{s}#to_s must return a String, got {s}", .{ val.asInstance().class.name.chars, self.typeName(shown) });
                }
                return writer.writeAll(shown.asString().chars);
            };
        }
        try val.stringify(false, writer);
    }

    /// Leaves the top frame: its upvalues are closed, its slots dropped, and the handlers
    /// it set up forgotten.
    fn popFrame(self: *VM) void {
        if (self.profiler) |p| p.exitFrame() catch |err| {
            log.err("Profiler error: {}", .{err});
        };
        std.debug.assert(self.frames.items.len > 0);
        const top = self.frames.items[self.frames.items.len - 1];
        self.closeUpvalues(&self.stack[top.base_slot]);
        self.shrinkStack(top.base_slot);
        _ = self.frames.pop();
        self.dropStaleRescueFrames();
    }

    /// Forgets the handlers of frames that are gone: a method left through `yield` by its
    /// block's `break` never reaches the `op_pop_rescue` of a `begin` it was inside, and a
    /// later error would have jumped to that handler in whatever frame had its index.
    fn dropStaleRescueFrames(self: *VM) void {
        while (self.rescue_frames.items.len > 0 and self.rescue_frames.items[self.rescue_frames.items.len - 1].frame_count > self.frames.items.len) {
            _ = self.rescue_frames.pop();
        }
    }

    /// The frame of the method a block was given to: `m { break }` leaves m, however m
    /// calls the block (`yield`, also from inside another block, or `each(&blk)`). Null
    /// when a native got the block (`xs.each { break }` leaves each) or m has returned.
    fn blockReceiverFrame(self: *const VM, block: *const value.ObjClosure) ?usize {
        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.frames.items[i];
            if (!f.closure.function.is_method) continue;
            const slot = self.stack[f.base_slot + f.closure.function.arity + 1];
            if (slot.isClosure() and slot.asClosure() == block) return i;
        }
        return null;
    }

    /// Carries `pending_break` out of the top frame and, when it is aimed at a method
    /// frame, out of every frame above that one and the method's own, which gets the value
    /// as its result. Each run loop pops only its own frames: at `target_depth` a native
    /// sits between them, so this returns `.block_break` for the native to return first
    /// (takeBlockBreak, or error.BlockBreak through it) and its caller to carry on
    /// (afterCall). Null: the break has landed, its value is on top, this loop goes on.
    fn carryBreak(self: *VM, target_depth: usize) ?InterpretResult {
        const pending = self.pending_break.?;
        while (true) {
            const leaving = self.frames.items.len - 1;
            self.popFrame();
            // A native's block: the native takes the value as the block's result.
            const target = pending.target orelse return .block_break;
            if (leaving == target) {
                self.pending_break = null;
                self.push(pending.value);
                return if (self.frames.items.len == target_depth) .ok else null;
            }
            if (self.frames.items.len == target_depth) return .block_break;
        }
    }

    /// What the run loop does with a call op's result: `.block_break` means a native let a
    /// block's `break` through, and the break goes on from the calling frame. Null: carry
    /// on with the next instruction.
    fn afterCall(self: *VM, res: InterpretResult, target_depth: usize) ?InterpretResult {
        if (res == .ok) return null;
        if (res != .block_break) return res;
        return self.carryBreak(target_depth);
    }

    /// For a native whose block broke (callClosureSync failed with error.BlockBreak): the
    /// value the native returns, or null when the break is aimed at a method below the
    /// native, which then fails with error.BlockBreak itself so the VM carries it on.
    pub fn takeBlockBreak(self: *VM) ?value.Value {
        const pending = self.pending_break.?;
        if (pending.target != null) return null;
        self.pending_break = null;
        return pending.value;
    }

    pub fn executeThrow(self: *VM) InterpretResult {
        // PEEK instead of POP to protect the thrown error from the GC
        var err_val = self.stack[self.stack_top - 1];

        // `raise Klass` raises Klass.new, as in Ruby: a rescue gets an instance, with a
        // message (the class name) and a backtrace. The class itself was thrown before,
        // so `e.message` on it was a NoMethodError.
        if (err_val.isClass()) {
            const throw_seq = self.throw_seq;
            const depth = self.frames.items.len;
            const res = self.constructInstance(err_val.asClass(), 0, self.stack_top - 1, false, false);
            if (res != .ok) return res;
            if (self.frames.items.len > depth) {
                const init_res = self.runUntil(depth);
                if (init_res != .ok) return init_res;
            }
            // initialize raised, and a rescue took over: nothing is left to throw
            if (self.throw_seq != throw_seq) return .ok;
            err_val = self.stack[self.stack_top - 1];
        }

        // --- Auto-wrap primitives in RuntimeError ---
        // Each allocation below can collect, and Zig locals are not GC roots: every
        // new object goes onto the stack as soon as it exists.
        if (!err_val.isInstance() and !err_val.isClass()) {
            if (self.error_classes.get(.RuntimeError)) |rt_class| {
                if (self.gc.allocateInstance(self, rt_class) catch null) |inst| {
                    const inst_val = value.Value.initObj(&inst.obj);
                    self.push(inst_val);

                    var str_val: ?value.Value = null;

                    // If it's already a string, use it directly!
                    if (err_val.isString()) {
                        str_val = err_val;
                    } else {
                        // Otherwise, stringify the value (a number, an Array, ...). On the heap:
                        // a fixed stack buffer used to truncate a large one.
                        var out: std.Io.Writer.Allocating = .init(self.allocator);
                        defer out.deinit();
                        err_val.stringify(false, &out.writer) catch |err| {
                            self.reportError("Error stringifying a raised value: {}", .{err});
                        };
                        str_val = self.allocateString(out.written()) catch null;
                    }

                    if (str_val) |s_val| {
                        self.push(s_val); // Protect until the instance holds it
                        const msg_key = self.allocateString("message") catch return self.raisingOutOfMemory();
                        self.setInstanceField(inst, msg_key, s_val, null) catch |err| {
                            self.reportError("Error setting exception message: {}", .{err});
                        };
                        _ = self.pop();

                        // --- EAGER BACKTRACE CAPTURE ---
                        if (self.buildBacktrace() catch null) |bt_arr| {
                            self.push(value.Value.initObj(&bt_arr.obj)); // Protect during assignment
                            const bt_key = self.allocateString("backtrace") catch return self.raisingOutOfMemory();
                            self.setInstanceField(inst, bt_key, value.Value.initObj(&bt_arr.obj), null) catch |err| {
                                self.reportError("Error setting exception backtrace: {}", .{err});
                            };
                            _ = self.pop();
                        }

                        // The instance takes over the thrown slot, which keeps it rooted until it is popped
                        _ = self.pop();
                        self.stack[self.stack_top - 1] = inst_val;
                        err_val = inst_val; // Overwrite the thrown value!
                    } else {
                        _ = self.pop(); // No message: drop the instance and throw the payload as-is
                    }
                }
            }
        }

        self.throw_seq +%= 1;
        self.last_throw_target = if (self.rescue_frames.items.len > 0)
            self.rescue_frames.items[self.rescue_frames.items.len - 1].frame_count
        else
            null;

        if (self.rescue_frames.items.len == 0) {
            // Pop only once reporting is done: the key lookups below allocate, and the
            // thrown value must stay rooted in its stack slot until then.
            defer _ = self.pop();

            // We removed the [Uncaught Exception] header
            if (err_val.isString()) {
                const str = err_val.asString().chars;
                self.reportError("RuntimeError: {s}", .{str});
                self.printStacktrace();
            } else if (err_val.isInstance()) {
                const inst = err_val.asInstance();
                var printed = false;

                const msg_key = self.allocateString("message") catch return self.raisingOutOfMemory();

                // Format: ClassName: Message
                if (inst.class.instance_layout.get(msg_key)) |idx| {
                    if (idx < inst.fields.items.len) {
                        const msg_val = inst.fields.items[idx];
                        if (msg_val.isString()) {
                            const str = msg_val.asString().chars;
                            self.reportError("{s}: {s}", .{ inst.class.name.chars, str });
                            printed = true;
                        }
                    }
                }
                if (!printed) self.reportError("{s}", .{inst.class.name.chars});

                // Print First-Class Backtrace seamlessly
                var printed_bt = false;
                const bt_key = self.allocateString("backtrace") catch return self.raisingOutOfMemory();

                if (inst.class.instance_layout.get(bt_key)) |bt_idx| {
                    if (bt_idx < inst.fields.items.len) {
                        const bt_val = inst.fields.items[bt_idx];
                        if (bt_val.isArray()) {
                            const arr_obj = bt_val.asArray();
                            for (arr_obj.items.items) |frame_val| {
                                if (frame_val.isString()) {
                                    const frame_str = frame_val.asString().chars;
                                    self.reportError("{s}", .{frame_str});
                                }
                            }
                            printed_bt = true;
                        }
                    }
                }

                if (!printed_bt) self.printStacktrace();
            } else {
                self.reportError("Unknown error.", .{});
                self.printStacktrace();
            }
            return .runtime_error;
        }

        // Complete the conceptual op_throw; nothing allocates before the handler re-pushes err_val
        _ = self.pop();

        const r_frame = self.rescue_frames.pop().?;
        self.closeUpvalues(&self.stack[r_frame.stack_top]);

        while (self.frames.items.len > r_frame.frame_count) {
            _ = self.frames.pop();
        }

        self.shrinkStack(r_frame.stack_top);
        self.push(err_val);
        self.frames.items[self.frames.items.len - 1].ip = r_frame.handler_ip;

        // --- Save Unwind State for Native FFI Restoration ---
        // Any older entry belongs to an exception whose handler already runs (see UnwindFrame).
        self.clearUnwindState();
        // Handled: what was reported on the way here (e.g. by a native) failed nothing.
        self.clearLastError();
        self.unwind_stack.append(self.allocator, .{
            .err_val = err_val,
            .stack_top = r_frame.stack_top,
            .frame_count = r_frame.frame_count,
        }) catch {
            self.reportError("Fatal: Out of memory during exception unwinding.", .{});
            return .runtime_error;
        };

        return .ok;
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
                    .range => return c == self.range_class,
                    else => return false,
                }
            } else if (test_val.isNumber()) {
                return case_val.asClass() == self.number_class;
            }
            return false;
        } else if (case_val.isRange()) {
            const range = case_val.asRange();
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

    inline fn getPropertyCached(self: *VM, instance: *value.ObjInstance, name: value.Value, ic: *chunk.InlineCache) ?value.Value {
        self.refreshInlineCache(ic);
        var offset: usize = 0;

        if (ic.fieldOffset(instance.class)) |cached| {
            offset = cached;
        } else if (ic.cachedMethod(instance.class) != null) {
            // The site reads a method of this class (a reader): no field to look up.
            return null;
        } else if (instance.class.instance_layout.get(name)) |idx| {
            ic.remember(instance.class, value.Value.initNil(), idx);
            offset = idx;
        } else {
            return null; // Return null so the VM knows to check for methods
        }

        if (offset < instance.fields.items.len) {
            return instance.fields.items[offset];
        } else {
            return value.Value.initNil();
        }
    }

    pub fn setInstanceField(self: *VM, instance: *value.ObjInstance, name: value.Value, val: value.Value, ic: ?*chunk.InlineCache) !void {
        var idx: usize = 0;

        if (ic) |cache| self.refreshInlineCache(cache);
        if (if (ic) |cache| cache.fieldOffset(instance.class) else null) |cached| {
            idx = cached;
        } else {
            if (instance.class.instance_layout.get(name)) |existing_idx| {
                idx = existing_idx;
            } else {
                idx = instance.class.instance_layout.count();
                try instance.class.instance_layout.put(self.gc.trackingAllocator(), name, idx);
            }
            if (ic) |cache| cache.remember(instance.class, value.Value.initNil(), idx);
        }

        // Ensure the instance's flat array is large enough
        if (idx >= instance.fields.items.len) {
            const old_len = instance.fields.items.len;
            try instance.fields.resize(self.gc.trackingAllocator(), idx + 1);
            for (old_len..idx) |i| instance.fields.items[i] = value.Value.initNil();
        }

        instance.fields.items[idx] = val;
    }

    /// Numbers are 64-bit floats, so a result too large for one (beyond ~1.8e308) would be
    /// Infinity. Like Crystal's OverflowError, that is an error when the operands were
    /// finite: an infinite length is never a usable value in a model.
    fn overflowed(a: f64, b: f64, res: f64) bool {
        return std.math.isInf(res) and std.math.isFinite(a) and std.math.isFinite(b);
    }

    fn overflowError(self: *VM, op: chunk.OpCode, a: f64, b: f64) InterpretResult {
        return self.raiseError(.RangeError, "{f} {s} {f} overflows: the result is beyond the largest number ({e:.1})", .{ value.fmtNumber(a), operatorSymbol(op), value.fmtNumber(b), std.math.floatMax(f64) });
    }

    /// The TypeError for an operator applied to values it doesn't support.
    fn operandError(self: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) InterpretResult {
        return self.raiseError(.TypeError, "'{s}' can't combine {s} and {s}", .{ operatorSymbol(op), self.typeName(a), self.typeName(b) });
    }

    fn operatorSymbol(op: chunk.OpCode) []const u8 {
        return switch (op) {
            .op_add => "+",
            .op_subtract => "-",
            .op_multiply => "*",
            .op_divide => "/",
            .op_modulo => "%",
            .op_exponent => "**",
            .op_less => "<",
            .op_greater => ">",
            .op_less_equal => "<=",
            .op_greater_equal => ">=",
            .op_bitwise_and => "&",
            .op_bitwise_or => "|",
            .op_bitwise_xor => "^",
            .op_shift_left => "<<",
            .op_shift_right => ">>",
            else => @tagName(op),
        };
    }

    /// The script-facing name of a value's type, for error messages.
    pub fn typeName(self: *VM, val: value.Value) []const u8 {
        if (val.isNil()) return "nil";
        if (self.getClass(val)) |class| return class.name.chars;
        if (val.isObject()) return switch (val.asObj().obj_type) {
            .closure, .function, .native, .bound_method => "Proc",
            .class => "Class",
            .module => "Module",
            .workplane => "Workplane",
            .assembly => "Assembly",
            else => "Object",
        };
        return "Object";
    }

    /// A native failed without raising an error of its own (out of memory, or a bug in
    /// it): the error names the native and the failure. These used to be the generic
    /// "Native Execution Error" / "CAD Kernel / Method Error".
    fn nativeFailed(self: *VM, name: []const u8, err: anyerror) InterpretResult {
        if (err == error.OutOfMemory) return self.raiseError(.OutOfMemoryError, "{s} ran out of memory", .{name});
        return self.raiseError(.RuntimeError, "{s} failed ({s})", .{ name, @errorName(err) });
    }

    fn findMethodInternal(
        self: *VM,
        class: *value.ObjClass,
        name: value.Value,
        ic: ?*chunk.InlineCache,
        target: LookupTarget,
    ) MethodLookupResult {
        const method_val = switch (target) {
            .instance => if (ic) |cache| self.findMethodCached(class, name, cache) else self.findMethod(class, name),
            .class => self.findClassMethod(class, name),
        };
        if (method_val) |m| return .{ .method = m, .is_private = false };

        // A private method is stored under "@private:<name>". That key was interned when the
        // method was defined, so a name that isn't interned names no private method: looking
        // it up allocates nothing (interning it on every miss made garbage on every field
        // read and every NoMethodError).
        var name_buf: [256]u8 = undefined;
        if (name.isString()) {
            if (std.fmt.bufPrint(&name_buf, "@private:{s}", .{name.asString().chars})) |priv_name| {
                if (self.strings.get(priv_name)) |priv_str| {
                    const priv_val = value.Value.initObj(&priv_str.obj);
                    const priv_method = switch (target) {
                        .instance => self.findMethod(class, priv_val),
                        .class => self.findClassMethod(class, priv_val),
                    };
                    if (priv_method) |m| return .{ .method = m, .is_private = true };
                }
            } else |_| {}
        }

        return .{ .method = null, .is_private = false };
    }

    pub fn findMethodWithPrivacy(self: *VM, class: *value.ObjClass, name: value.Value, ic: ?*chunk.InlineCache) MethodLookupResult {
        return self.findMethodInternal(class, name, ic, .instance);
    }

    pub fn findClassMethodWithPrivacy(self: *VM, class: *value.ObjClass, name: value.Value) MethodLookupResult {
        return self.findMethodInternal(class, name, null, .class);
    }

    /// What a closure is called in messages and the profiler.
    fn closureName(self: *const VM, closure: *const value.ObjClosure) []const u8 {
        _ = self;
        return if (closure.function.name) |n| n.chars else "block";
    }

    /// A def called with the wrong number of positional arguments: the ArgumentError, or
    /// null when the count fits. `def f(a, b = 1, *rest)` takes at least 1.
    fn arityError(self: *VM, closure: *const value.ObjClosure, provided: usize) ?InterpretResult {
        const func = closure.function;
        const max: usize = func.arity - @intFromBool(func.has_kwargs);
        const min: usize = func.min_args;
        if (provided >= min and (func.splat_pos != null or provided <= max)) return null;
        const name = self.closureName(closure);
        if (func.splat_pos != null) return self.raiseError(.ArgumentError, "{s} takes at least {d} argument{s}, got {d}", .{ name, min, plural(min), provided });
        if (min == max) return self.raiseError(.ArgumentError, "{s} takes {d} argument{s}, got {d}", .{ name, min, plural(min), provided });
        return self.raiseError(.ArgumentError, "{s} takes {d} to {d} arguments, got {d}", .{ name, min, max, provided });
    }

    fn plural(count: usize) []const u8 {
        return if (count == 1) "" else "s";
    }

    /// The method a frame's code is part of: the frame's own closure in a method, the
    /// method a block or lambda was written in, null for top-level code.
    fn homeMethod(frame: *const CallFrame) ?*value.ObjClosure {
        const closure = frame.closure;
        if (closure.function.is_method) return closure;
        if (closure.function.is_lambda) return closure.home;
        return null;
    }

    /// `self` as the code in `frame` sees it: a method's receiver, also from a block in it.
    fn frameSelf(self: *const VM, frame: *const CallFrame) value.Value {
        if (frame.closure.function.is_lambda) return frame.closure.home_self;
        return self.stack[frame.base_slot];
    }

    /// The block a `yield` in `frame` calls: the method's own, also from a block in it.
    fn frameBlock(self: *const VM, frame: *const CallFrame) value.Value {
        const closure = frame.closure;
        if (closure.function.is_method) return self.stack[frame.base_slot + closure.function.arity + 1];
        if (closure.function.is_lambda) return closure.home_block;
        return value.Value.initNil();
    }

    /// A private method may be called on `self`, or on any instance of the class the
    /// running method was defined in (or a subclass), through blocks as well.
    fn privateCallAllowed(self: *VM, frame: *const CallFrame, receiver: value.Value) bool {
        if (self.valuesEqual(receiver, self.frameSelf(frame))) return true;
        const home = homeMethod(frame) orelse return false;
        const home_class = home.home_class orelse return false;
        const receiver_class = self.getClass(receiver) orelse return false;
        return isSubclassOf(receiver_class, home_class);
    }

    pub fn isSubclassOf(class: *value.ObjClass, superclass: *value.ObjClass) bool {
        var current: ?*value.ObjClass = class;
        while (current) |c| {
            if (c == superclass) return true;
            current = c.superclass;
        }
        return false;
    }

    inline fn searchJumpTable(
        exec_chunk: *chunk.Chunk,
        table_start: usize,
        case_count: usize,
        test_val: value.Value,
    ) SwitchMatch {
        const test_type: u8 = if (test_val.isNumber()) 0 else if (test_val.isString()) 1 else 2;
        if (test_type >= 2) return .{ .matched = false, .jump_offset = 0 };

        var low: usize = 0;
        var high: usize = case_count;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const idx = table_start + (mid * 6);

            const const_high: u16 = exec_chunk.code.items[idx];
            const const_low: u16 = exec_chunk.code.items[idx + 1];
            const const_idx = (const_high << 8) | const_low;
            const case_val = exec_chunk.constants.items[const_idx];

            const case_type: u8 = if (case_val.isNumber()) 0 else 1;

            if (test_type < case_type) {
                high = mid;
            } else if (test_type > case_type) {
                low = mid + 1;
            } else {
                if (test_type == 0) {
                    const tn = test_val.asNumber();
                    const cn = case_val.asNumber();
                    if (tn < cn) {
                        high = mid;
                    } else if (tn > cn) {
                        low = mid + 1;
                    } else {
                        const offset = (@as(usize, exec_chunk.code.items[idx + 2]) << 24) |
                            (@as(usize, exec_chunk.code.items[idx + 3]) << 16) |
                            (@as(usize, exec_chunk.code.items[idx + 4]) << 8) |
                            @as(usize, exec_chunk.code.items[idx + 5]);
                        return .{ .matched = true, .jump_offset = offset };
                    }
                } else {
                    const ts = test_val.asString().chars;
                    const cs = case_val.asString().chars;
                    const order = std.mem.order(u8, ts, cs);
                    if (order == .lt) {
                        high = mid;
                    } else if (order == .gt) {
                        low = mid + 1;
                    } else {
                        const offset = (@as(usize, exec_chunk.code.items[idx + 2]) << 24) |
                            (@as(usize, exec_chunk.code.items[idx + 3]) << 16) |
                            (@as(usize, exec_chunk.code.items[idx + 4]) << 8) |
                            @as(usize, exec_chunk.code.items[idx + 5]);
                        return .{ .matched = true, .jump_offset = offset };
                    }
                }
            }
        }

        return .{ .matched = false, .jump_offset = 0 };
    }

    /// Raises a rescuable exception of `kind` whose message is `fmt` formatted with `args`.
    /// The class name is not part of the message (it's printed from the class for uncaught
    /// errors), so `fmt` must not start with a kind prefix or end in a newline; both are
    /// rejected at compile time.
    /// Raises `kind` (raiseError) and gives the error a native returns once it has: what
    /// `_ = vm.raiseError(...); return error.RuntimeError;` spelled out at every site.
    pub fn fail(self: *VM, comptime kind: ErrorKind, comptime fmt: []const u8, args: anytype) error{RuntimeError} {
        _ = self.raiseError(kind, fmt, args);
        return error.RuntimeError;
    }

    pub fn raiseError(self: *VM, comptime kind: ErrorKind, comptime fmt: []const u8, args: anytype) InterpretResult {
        comptime {
            checkMessageLayout(fmt);
            for (std.meta.fieldNames(ErrorKind)) |name| {
                if (std.mem.startsWith(u8, fmt, name ++ ":")) @compileError("drop the '" ++ name ++ ":' prefix and pass ." ++ name ++ ": \"" ++ fmt ++ "\"");
            }
        }
        const msg = self.fmtScratch(fmt, args) catch "Out of memory while formatting an error message";

        if (self.error_classes.get(kind)) |class| {
            if (self.gc.allocateInstance(self, class) catch null) |inst| {
                // Root the newly allocated instance IMMEDIATELY
                self.push(value.Value.initObj(&inst.obj));

                if (self.allocateString(msg) catch null) |str_val| {
                    self.push(str_val); // Protect until the instance holds it
                    const msg_key = self.allocateString("message") catch return self.raisingOutOfMemory();
                    self.setInstanceField(inst, msg_key, str_val, null) catch |err| {
                        self.reportError("Error setting exception message: {}", .{err});
                    };
                    _ = self.pop();

                    // --- EAGER BACKTRACE CAPTURE ---
                    if (self.buildBacktrace() catch null) |bt_arr| {
                        self.push(value.Value.initObj(&bt_arr.obj)); // Protect during assignment
                        const bt_key = self.allocateString("backtrace") catch return self.raisingOutOfMemory();
                        self.setInstanceField(inst, bt_key, value.Value.initObj(&bt_arr.obj), null) catch |err| {
                            self.reportError("Error setting exception backtrace: {}", .{err});
                        };
                        _ = self.pop();
                    }

                    // inst is already safely on the top of the stack, call executeThrow to bubble it
                    return self.executeThrow();
                }

                // Cleanup if string alloc failed
                _ = self.pop();
            }
        }
        // Fallback to string if the standard library isn't loaded yet
        if (self.allocateString(msg) catch null) |err_val| {
            self.push(err_val);
            return self.executeThrow();
        } else {
            self.runtimeError("Fatal: out of memory while raising an error.", .{});
            return .runtime_error;
        }
    }

    /// An allocation the run needed failed: raises an OutOfMemoryError the script may rescue,
    /// naming the memory limit when one is set (it refused the allocation, or the system ran
    /// out first). Such a run used to stop with no message at all. `err` can only be
    /// OutOfMemory, so a call that fails in other ways doesn't compile against it.
    fn allocationFailed(self: *VM, err: error{OutOfMemory}) InterpretResult {
        switch (err) {
            error.OutOfMemory => {},
        }
        if (self.gc.max_memory_limit) |limit| return self.raiseError(.OutOfMemoryError, "the script exceeded its memory limit of {d} bytes", .{limit});
        return self.raiseError(.OutOfMemoryError, "out of memory", .{});
    }

    /// The same while an error is being raised or reported, where raising one would recurse.
    fn raisingOutOfMemory(self: *VM) InterpretResult {
        self.runtimeError("Fatal: out of memory while raising an error.", .{});
        return .runtime_error;
    }

    pub fn runtimeError(self: *VM, comptime fmt: []const u8, args: anytype) void {
        self.reportError(fmt, args);
        self.printStacktrace(); // Append the exact line and column
    }

    /// The message layout every error the VM reports keeps: the logger and the embedders
    /// lay it out, so a message has no newlines at its ends (reportError's had, and printed
    /// blank lines), and no "Runtime Error:" prefix of its own.
    fn checkMessageLayout(comptime fmt: []const u8) void {
        if (fmt.len > 0 and fmt[fmt.len - 1] == '\n') @compileError("error messages must not end in a newline: \"" ++ fmt ++ "\"");
        if (fmt.len > 0 and fmt[0] == '\n') @compileError("error messages must not start with a newline: \"" ++ fmt ++ "\"");
        if (std.mem.startsWith(u8, fmt, "Runtime Error:")) @compileError("drop the 'Runtime Error:' prefix from \"" ++ fmt ++ "\"");
    }

    pub fn reportError(self: *VM, comptime fmt: []const u8, args: anytype) void {
        comptime checkMessageLayout(fmt);
        self.recordLastError(fmt, args);
        if (self.mute_errors) return;

        log.err(fmt, args);
    }

    /// Only the first report is kept: later ones are its fallout, such as backtrace lines
    /// or the generic "Native Execution Error" raised after a native reported the cause.
    fn recordLastError(self: *VM, comptime fmt: []const u8, args: anytype) void {
        if (self.last_error != null) return;
        const full = self.fmtScratch(fmt, args) catch return;
        // Formats and messages carry newlines that only lay out stderr. A failed copy just
        // loses the message.
        self.last_error = self.allocator.dupe(u8, std.mem.trim(u8, full, &std.ascii.whitespace)) catch null;
    }

    pub fn clearLastError(self: *VM) void {
        if (self.last_error) |msg| self.allocator.free(msg);
        self.last_error = null;
    }

    /// The backtrace lines of the current frames, innermost first, formatted into a reused
    /// buffer (valid until the next call to `next`). A deep recursion has up to
    /// max_call_frames frames, so past MAX_BACKTRACE_FRAMES only the innermost and outermost
    /// halves are listed, around one line counting the frames left out.
    const BacktraceLines = struct {
        vm: *VM,
        /// Frames not listed yet, counted from the innermost (the top of `vm.frames`).
        remaining: usize,
        listed: usize = 0,
        buf: [MAX_TRACE_LINE_LEN]u8 = undefined,

        fn init(vm: *VM) BacktraceLines {
            return .{ .vm = vm, .remaining = vm.frames.items.len };
        }

        fn next(self: *BacktraceLines) ?[]const u8 {
            if (self.remaining == 0) return null;
            const total = self.vm.frames.items.len;
            if (total > MAX_BACKTRACE_FRAMES and self.listed == MAX_BACKTRACE_FRAMES / 2) {
                const omitted = total - MAX_BACKTRACE_FRAMES;
                self.remaining -= omitted;
                self.listed += 1;
                return std.fmt.bufPrint(&self.buf, "    ... {d} frames omitted ...", .{omitted}) catch "    ...";
            }
            self.remaining -= 1;
            self.listed += 1;
            const frame = &self.vm.frames.items[self.remaining];
            const exec_chunk: *chunk.Chunk = @ptrCast(@alignCast(frame.closure.function.chunk.?));
            const source_offset = exec_chunk.getOffset(if (frame.ip > 0) frame.ip - 1 else 0);
            const func_name = if (frame.closure.function.name) |n| n.chars else "script";
            const line = if (self.vm.line_index) |li|
                std.fmt.bufPrint(&self.buf, "    from script:{d}:{d}:in '{s}'", .{ li.getLine(source_offset) + 1, li.getUtf8Column(source_offset) + 1, func_name })
            else
                std.fmt.bufPrint(&self.buf, "    from script:offset {d}:in '{s}'", .{ source_offset, func_name });
            return line catch "    from unknown";
        }
    };

    fn printStacktrace(self: *VM) void {
        var lines = BacktraceLines.init(self);
        while (lines.next()) |line| self.reportError("{s}", .{line});
    }

    // --- First-Class Error Backtraces ---
    pub fn buildBacktrace(self: *VM) !*value.ObjArray {
        const arr_obj = try self.gc.allocateArray(self);
        self.push(value.Value.initObj(&arr_obj.obj)); // Protect array from GC
        defer _ = self.pop();

        var lines = BacktraceLines.init(self);
        while (lines.next()) |line| {
            const str_val = try self.allocateString(line);
            try arr_obj.items.append(self.gc.trackingAllocator(), str_val);
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
        const ic_high: u16 = exec_chunk.code.items[frame.ip];
        const ic_low: u16 = exec_chunk.code.items[frame.ip + 1];
        frame.ip += 2;
        const ic_idx = (ic_high << 8) | ic_low;
        return &exec_chunk.inline_caches.items[ic_idx];
    }

    /// Empties `ic` if a method table changed since it was filled.
    inline fn refreshInlineCache(self: *const VM, ic: *chunk.InlineCache) void {
        if (ic.epoch != self.method_epoch) ic.* = .{ .epoch = self.method_epoch };
    }

    inline fn findMethodCached(self: *VM, class: *value.ObjClass, name: value.Value, ic: *chunk.InlineCache) ?value.Value {
        self.refreshInlineCache(ic);
        if (ic.cachedMethod(class)) |cached| return cached;

        // Slow Path (Traverse inheritance hierarchy)
        if (self.findMethod(class, name)) |method_val| {
            ic.remember(class, method_val, 0);
            return method_val;
        }
        return null;
    }

    // --- String Formatting Utility ---
    pub fn fmtScratch(self: *VM, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.scratch_arena.allocator(), fmt, args);
    }
};
