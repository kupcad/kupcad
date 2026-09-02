const std = @import("std");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const limits = @import("../vm/limits.zig");
const Compiler = @import("compiler.zig").Compiler;
const CompileError = @import("compiler.zig").CompileError;

pub fn simulatePush(self: *Compiler, count: usize) void {
    self.current_stack_depth += count;
    if (self.current_stack_depth > self.max_stack_depth) {
        self.max_stack_depth = self.current_stack_depth;
    }
}

pub fn simulatePop(self: *Compiler, count: usize) void {
    std.debug.assert(self.current_stack_depth >= count);
    self.current_stack_depth -= count;
}

pub fn emitInlineCacheIndex(self: *Compiler) CompileError!void {
    const ic_idx = self.current_chunk.addInlineCache(self.allocator) catch return error.OutOfMemory;
    try self.emitByte(@intCast((ic_idx >> 8) & 0xff));
    try self.emitByte(@intCast(ic_idx & 0xff));
}

pub fn emitByte(self: *Compiler, byte: u8) CompileError!void {
    self.current_chunk.write(self.allocator, byte, self.current_source_offset) catch return error.OutOfMemory;
}

pub fn emitOp(self: *Compiler, op: chunk.OpCode) CompileError!void {
    try self.emitByte(@intFromEnum(op));

    // Automatically apply static stack effects
    if (getStaticStackEffect(op)) |effect| {
        if (effect > 0) {
            self.simulatePush(@intCast(effect));
        } else if (effect < 0) {
            self.simulatePop(@intCast(-effect));
        }
    }
}

pub fn makeConstant(self: *Compiler, val: value.Value) CompileError!usize {
    // Linear scan over constants to reuse existing matching values
    for (self.current_chunk.constants.items, 0..) |existing, i| {
        if (self.vm.valuesEqual(existing, val)) return i;
    }

    const index = self.current_chunk.addConstant(self.allocator, val) catch return error.OutOfMemory;
    if (index > limits.MAX_CONSTANTS) return error.TooManyConstants;
    return index;
}

pub fn emitConstant(self: *Compiler, val: value.Value) CompileError!void {
    const index = try self.makeConstant(val);
    try self.emitOpWithOperand(.op_constant, .op_constant_wide, index);
}

pub fn emitJump(self: *Compiler, op: chunk.OpCode) CompileError!usize {
    try self.emitOp(op);
    // Write 4 bytes for a 32-bit jump offset
    try self.emitByte(0xff);
    try self.emitByte(0xff);
    try self.emitByte(0xff);
    try self.emitByte(0xff);
    return self.current_chunk.code.items.len - 4;
}

pub fn patchJump(self: *Compiler, offset: usize) void {
    const jump = self.current_chunk.code.items.len - offset - 4;
    std.debug.assert(jump <= 0xFFFFFFFF); // Assert it fits in 32 bits
    self.writeJumpOffset(offset, jump);
}

pub fn emitLoop(self: *Compiler, loop_start: usize) CompileError!void {
    try self.emitOp(.op_loop);
    const jump = self.current_chunk.code.items.len - loop_start + 4;
    std.debug.assert(jump <= 0xFFFFFFFF);
    try self.emitByte(@intCast((jump >> 24) & 0xff));
    try self.emitByte(@intCast((jump >> 16) & 0xff));
    try self.emitByte(@intCast((jump >> 8) & 0xff));
    try self.emitByte(@intCast(jump & 0xff));
}

pub fn makeMethodNameConstant(self: *Compiler, name: []const u8, is_private: bool) CompileError!usize {
    if (is_private) {
        var name_buf: [256]u8 = undefined;
        const mangled_name = std.fmt.bufPrint(&name_buf, "@private:{s}", .{name}) catch return error.OutOfMemory;
        return self.makeStringConstant(mangled_name);
    }
    return self.makeStringConstant(name);
}

pub fn makeStringConstant(self: *Compiler, text: []const u8) CompileError!usize {
    const str_val = try self.vm.allocateString(text);
    self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
    self.vm.push(str_val);
    const idx = try self.makeConstant(str_val);
    _ = self.vm.pop();
    return idx;
}

pub fn makeSymbolConstant(self: *Compiler, text: []const u8) CompileError!usize {
    const sym_val = try self.vm.allocateSymbol(text);
    self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
    self.vm.push(sym_val);
    const idx = try self.makeConstant(sym_val);
    _ = self.vm.pop();
    return idx;
}

pub fn emitOpWithOperand(self: *Compiler, short_op: chunk.OpCode, wide_op: chunk.OpCode, operand: usize) CompileError!void {
    if (short_op == .op_get_local or short_op == .op_set_local) {
        if (operand > self.max_local_slot) self.max_local_slot = operand;
    }

    if (operand <= limits.MAX_SHORT_CONSTANTS) {
        try self.emitOp(short_op);
        try self.emitByte(@intCast(operand));
    } else {
        try self.emitOp(wide_op);
        try self.emitByte(@intCast((operand >> 8) & 0xff)); // High byte
        try self.emitByte(@intCast(operand & 0xff)); // Low byte
    }
}

pub fn writeJumpOffset(self: *Compiler, target_index: usize, offset: usize) void {
    // Prevent silent out-of-bounds overwrites in the bytecode array
    std.debug.assert(target_index + 3 < self.current_chunk.code.items.len);

    self.current_chunk.code.items[target_index] = @intCast((offset >> 24) & 0xFF);
    self.current_chunk.code.items[target_index + 1] = @intCast((offset >> 16) & 0xFF);
    self.current_chunk.code.items[target_index + 2] = @intCast((offset >> 8) & 0xFF);
    self.current_chunk.code.items[target_index + 3] = @intCast(offset & 0xFF);
}

/// Returns the net stack effect of an OpCode.
/// Returns `null` if the effect is dynamic (e.g., depends on call arity or operand length).
pub fn getStaticStackEffect(op: chunk.OpCode) ?i32 {
    return switch (op) {
        // --- Pushes 1 (Net: +1) ---
        // These operations introduce a new value onto the top of the stack.
        .op_nil, .op_true, .op_false, .op_get_local, .op_get_local_wide, .op_get_global, .op_get_global_wide, .op_constant, .op_constant_wide, .op_closure, .op_closure_wide, .op_get_upvalue, .op_dup, .op_import, .op_import_wide, .op_block_given, .op_defined, .op_defined_wide, .op_module, .op_module_wide, .op_extract_kwarg, .op_extract_kwarg_wide, .op_class, .op_class_wide => 1,

        // --- Pops 1 (Net: -1) ---
        // These operations consume exactly one value from the stack without pushing anything back.
        .op_pop, .op_return, .op_close_upvalue, .op_throw, .op_array_push, .op_array_spread, .op_map_spread, .op_switch, .op_switch_wide, .op_inherit, .op_class_method, .op_class_method_wide, .op_mixin, .op_method, .op_method_wide, .op_define_global, .op_define_global_wide, .op_bitwise_and, .op_break_block => -1,

        // --- Pops 2 (Net: -2) ---
        // Consumes two values (e.g. key and value) without replacing them.
        .op_map_insert => -2,

        // --- Pops 2, Pushes 1 (Net: -1) ---
        // Binary operations that consume a left and right operand, and yield a single result.
        .op_add, .op_subtract, .op_multiply, .op_divide, .op_modulo, .op_exponent, .op_less, .op_greater, .op_equal, .op_case_equal, .op_is_instance, .op_get_index, .op_set_property, .op_set_property_wide, .op_set_class_var, .op_set_class_var_wide, .op_cmp => -1,

        // --- Pops 3, Pushes 1 (Net: -2) ---
        // Consumes a target, an index, and a value, yielding the assigned value back.
        .op_set_index => -2,

        // --- Pops 1, Pushes 1 (Net: 0) ---
        // Unary modifiers that consume a value and replace it with a mutated version.
        // op_set_member pops a class, peeks at the namespace, attaches it, and pushes the class back.
        .op_negate, .op_not, .op_is_nil, .op_set_member, .op_set_member_wide => 0,

        // --- Pushes 2 (Net: +2) ---
        // Duplicates the top two values on the stack.
        .op_dup_two => 2,

        // --- Doesn't pop or push (Net: 0) ---
        // Pure side-effects or control flow jumps that leave the stack exactly as they found it.
        .op_set_local, .op_set_local_wide, .op_jump_if_not_nil, .op_jump_if_false, .op_jump_if_nil, .op_jump, .op_loop, .op_setup_rescue, .op_pop_rescue, .op_get_class_var, .op_get_class_var_wide, .op_set_upvalue => 0,

        // --- Dynamic Ops (Requires manual tracking) ---
        // These operations consume a variable number of arguments based on bytecode operands.
        .op_call, .op_invoke, .op_invoke_wide, .op_super_invoke, .op_build_array, .op_build_array_wide, .op_build_map, .op_build_map_wide, .op_unpack, .op_unpack_splat, .op_pack_splat, .op_interpolate, .op_yield, .op_build_range => null,

        else => 0, // Fallback for any implicitly balanced ops
    };
}
