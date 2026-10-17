//! Bytecode: the `OpCode` set and its `CallFlags`, `Chunk` (code, constants, source offsets
//! and inline caches), the `InlineCache` of a property or invoke site, and the
//! `ChunkRegistry` that keeps a chunk's constants alive while it is compiled.

const std = @import("std");
const value = @import("../core/value.zig");

/// The byte after the argument count of op_call, op_invoke(_wide), op_super_invoke and
/// op_yield, saying how the call site passed its arguments.
pub const CallFlags = packed struct(u8) {
    /// The last argument is the call's block (`do ... end`, `{ ... }` or `&blk`). Without
    /// it a trailing lambda is an ordinary argument, never mistaken for the block.
    has_block: bool = false,
    /// The positional arguments arrive packed in one Array (the call used `*splat`) and
    /// are spread onto the stack before dispatch.
    spread: bool = false,
    /// The last argument before the block is the call's keyword Map (`f(x, key: 1)`).
    /// Without it a trailing Map is an ordinary argument, never mistaken for keywords.
    has_kwargs: bool = false,
    _: u5 = 0,
};

/// The Virtual Machine Instruction Set
pub const OpCode = enum(u8) {
    // Constants & Literals
    op_constant,
    op_constant_wide,
    op_nil,
    op_true,
    op_false,

    // Data Structures
    op_build_array,
    op_build_array_wide,
    op_array_push,
    op_array_spread,
    op_build_map,
    op_build_map_wide,
    op_map_insert,
    op_map_spread,
    op_build_range,
    op_interpolate,
    op_get_index,
    op_set_index,

    // Closures & Upvalues
    op_closure,
    op_closure_wide,
    op_get_upvalue,
    op_set_upvalue,
    op_close_upvalue,

    // Object Orientation
    op_class,
    op_class_wide,
    op_get_property,
    op_get_property_wide,
    /// `@x` read: the instance's own field, nil when unset, never a method of that name
    /// (op_get_property's method fallback). Same operands as op_get_property.
    op_get_ivar,
    op_get_ivar_wide,
    op_set_property,
    op_set_property_wide,
    op_class_method,
    op_class_method_wide,
    op_get_class_var,
    op_get_class_var_wide,
    op_set_class_var,
    op_set_class_var_wide,
    op_module,
    op_module_wide,
    op_set_member,
    op_set_member_wide,
    op_mixin,
    op_method,
    op_method_wide,
    op_unpack,
    op_unpack_splat,
    op_pack_splat,
    op_defined,
    op_defined_wide,
    op_extract_kwarg,
    op_extract_kwarg_wide,
    op_is_instance,
    op_is_nil,

    // Stack Operations
    op_pop,
    op_dup,
    op_dup_two,

    // Variables
    op_get_local,
    op_get_local_wide,
    op_set_local,
    op_set_local_wide,
    op_get_global,
    op_get_global_wide,
    op_define_global,
    op_define_global_wide,

    // Math
    op_add,
    op_subtract,
    op_multiply,
    op_divide,
    op_modulo,
    op_exponent,
    op_bitwise_and,
    op_bitwise_or,
    op_bitwise_xor,
    op_shift_left,
    op_shift_right,
    op_negate,
    /// Unary `+`: the number itself (a TypeError for anything else).
    op_positive,
    /// Unary `~`: the bitwise complement of the number's i64, as the binary bitwise ops read it.
    op_bitwise_not,

    // Logical
    op_not,
    op_equal,
    op_case_equal,
    op_greater,
    op_less,
    /// `<=` and `>=` of their own: as `not >` and `not <` they were true against NaN.
    op_less_equal,
    op_greater_equal,
    op_cmp,

    // Control Flow
    op_jump,
    op_jump_if_false,
    op_jump_if_nil,
    op_jump_if_not_nil,
    op_switch,
    op_switch_wide,
    op_loop,
    /// One step of a `for` loop: u16 slot, then a 4-byte exit offset. The loop keeps its
    /// iterable in local `slot` and how many elements it has taken in `slot + 1`; this
    /// pushes the next element and counts it, or jumps forward by the offset when none is left.
    op_for_next,
    op_break_block,

    // Exception Handling
    op_setup_rescue,
    op_pop_rescue,
    op_throw,

    // Functions & Builtins
    op_call,
    op_invoke,
    op_invoke_wide,
    op_super_invoke,
    op_import,
    op_import_wide,
    op_inherit,
    op_yield,
    op_block_given,
    op_return,
};

/// Where one op_get_global or op_define_global site found its variable: the slot in the
/// table the name resolved to there (VM.globalSlot), good while the VM's global generation
/// is still `generation`. Every global read used to hash the name; in a loop of top-level
/// code that made it twice as slow as the same loop on locals.
pub const GlobalCache = struct {
    /// 0 until filled: the VM's generations start at 1.
    generation: usize = 0,
    slot: *value.Value = undefined,
};

/// A 2-way polymorphic inline cache at one property or invoke site: per class, the method
/// found (`cached_val`), or the field offset when the name is a field (`cached_val` nil).
/// Valid for `VM.method_epoch` as of `epoch`: defining, redefining or mixing in a method
/// anywhere bumps the epoch, so no site keeps calling a method that was replaced (it did,
/// and after a collection it called freed memory). The GC traces the entries.
pub const InlineCache = struct {
    epoch: u32 = 0,

    cached_class_1: ?*value.ObjClass = null,
    cached_val_1: value.Value = value.Value.initNil(),
    offset_1: usize = 0,

    cached_class_2: ?*value.ObjClass = null,
    cached_val_2: value.Value = value.Value.initNil(),
    offset_2: usize = 0,

    /// The field offset cached for `class` at this site, if the name is one of its fields.
    pub fn fieldOffset(self: *const InlineCache, class: *value.ObjClass) ?usize {
        if (self.cached_class_1 == class and self.cached_val_1.isNil()) return self.offset_1;
        if (self.cached_class_2 == class and self.cached_val_2.isNil()) return self.offset_2;
        return null;
    }

    /// The method cached for `class` at this site, if the name is one of its methods.
    pub fn cachedMethod(self: *const InlineCache, class: *value.ObjClass) ?value.Value {
        if (self.cached_class_1 == class and !self.cached_val_1.isNil()) return self.cached_val_1;
        if (self.cached_class_2 == class and !self.cached_val_2.isNil()) return self.cached_val_2;
        return null;
    }

    /// Records that `name` is `class`'s field at `offset` (or its method `method`) here.
    pub fn remember(self: *InlineCache, class: *value.ObjClass, method: value.Value, offset: usize) void {
        if (self.cached_class_1 == null or self.cached_class_1 == class) {
            self.cached_class_1 = class;
            self.cached_val_1 = method;
            self.offset_1 = offset;
        } else {
            self.cached_class_2 = class;
            self.cached_val_2 = method;
            self.offset_2 = offset;
        }
    }
};

pub const DebugSpan = struct {
    ip: u32,
    source_offset: u32,
};

/// Set of live chunks whose constant pools are GC roots.
///
/// A chunk under compilation is not reachable from any ObjFunction yet (the
/// top-level chunk only gets wrapped in interpret(), an imported module's chunk
/// only after compile() returns), so constants copied into it would otherwise be
/// swept by a GC triggered mid-compile. Chunks register themselves on the first
/// heap constant and unregister in Chunk.free, so the registry never holds a
/// dangling chunk pointer.
pub const ChunkRegistry = struct {
    chunks: std.ArrayListUnmanaged(*Chunk) = .empty,

    pub fn track(self: *ChunkRegistry, allocator: std.mem.Allocator, c: *Chunk) !void {
        if (c.registry != null) return;
        try self.chunks.append(allocator, c);
        c.registry = self;
        c.registry_index = self.chunks.items.len - 1;
    }

    pub fn untrack(self: *ChunkRegistry, c: *Chunk) void {
        const idx = c.registry_index;
        std.debug.assert(idx < self.chunks.items.len and self.chunks.items[idx] == c);
        _ = self.chunks.swapRemove(idx);
        if (idx < self.chunks.items.len) self.chunks.items[idx].registry_index = idx;
        c.registry = null;
        c.registry_index = 0;
    }

    /// Detaches every still-registered chunk (e.g. a stack chunk freed after
    /// its VM) so a later Chunk.free does not touch the destroyed registry.
    pub fn deinit(self: *ChunkRegistry, allocator: std.mem.Allocator) void {
        for (self.chunks.items) |c| {
            c.registry = null;
            c.registry_index = 0;
        }
        self.chunks.deinit(allocator);
    }
};

pub const Chunk = struct {
    code: std.ArrayListUnmanaged(u8),
    inline_caches: std.ArrayListUnmanaged(InlineCache),
    global_caches: std.ArrayListUnmanaged(GlobalCache) = .empty,
    debug_spans: std.ArrayListUnmanaged(DebugSpan),
    constants: value.ValueArray,
    max_stack_slots: usize,
    local_count: usize,
    local_names: std.ArrayListUnmanaged([]const u8), // For REPL introspection
    // GC root registration (see ChunkRegistry). A registered chunk must not be
    // moved by value, since the registry stores its address.
    registry: ?*ChunkRegistry = null,
    registry_index: usize = 0,

    pub fn init() Chunk {
        return .{
            .code = .empty,
            .inline_caches = .empty,
            .debug_spans = .empty,
            .constants = .empty,
            .max_stack_slots = 0,
            .local_count = 0,
            .local_names = .empty,
        };
    }

    /// Writes a single byte (either an OpCode or an Operand)
    pub fn write(self: *Chunk, allocator: std.mem.Allocator, byte: u8, source_offset: u32) !void {
        try self.code.append(allocator, byte);
        // Highly compressed RLE: Only append if the offset changed!
        if (self.debug_spans.items.len == 0 or self.debug_spans.items[self.debug_spans.items.len - 1].source_offset != source_offset) {
            try self.debug_spans.append(allocator, .{ .ip = @intCast(self.code.items.len - 1), .source_offset = source_offset });
        }
    }

    /// Convenience wrapper to write an OpCode enum
    pub fn writeOp(self: *Chunk, allocator: std.mem.Allocator, op: OpCode, source_offset: u32) !void {
        try self.write(allocator, @backingInt(op), source_offset);
    }

    /// Adds a Value to the constant pool and returns its 0-based index
    pub fn addConstant(self: *Chunk, allocator: std.mem.Allocator, val: value.Value) !usize {
        try self.constants.append(allocator, val);
        return self.constants.items.len - 1; // Return usize
    }

    /// O(log N) binary search for lightning-fast stack traces
    pub fn getOffset(self: *const Chunk, target_ip: usize) u32 {
        const spans = self.debug_spans.items;
        if (spans.len == 0) return 0;

        var left: usize = 0;
        var right: usize = spans.len - 1;
        var result_offset: u32 = 0;

        while (left <= right) {
            const mid = left + (right - left) / 2;
            const span = spans[mid];

            if (span.ip <= target_ip) {
                // This span is valid, but there might be a closer one to the right
                result_offset = span.source_offset;
                left = mid + 1;
            } else {
                // This span is too far ahead, search the left half
                if (mid == 0) break; // Prevent usize underflow
                right = mid - 1;
            }
        }

        return result_offset;
    }

    pub fn addInlineCache(self: *Chunk, allocator: std.mem.Allocator) !usize {
        const idx = self.inline_caches.items.len;
        try self.inline_caches.append(allocator, InlineCache{});
        return idx;
    }

    pub fn addGlobalCache(self: *Chunk, allocator: std.mem.Allocator) !usize {
        const idx = self.global_caches.items.len;
        try self.global_caches.append(allocator, .{});
        return idx;
    }

    pub fn free(self: *Chunk, allocator: std.mem.Allocator) void {
        if (self.registry) |r| r.untrack(self);
        self.code.deinit(allocator);
        self.inline_caches.deinit(allocator);
        self.global_caches.deinit(allocator);
        self.debug_spans.deinit(allocator);
        self.constants.deinit(allocator);
        self.local_names.deinit(allocator);
        self.* = init();
    }
};
