const std = @import("std");
const chunk = @import("../../vm/chunk.zig");
const value = @import("../../core/value.zig");

pub fn disassembleChunk(allocator: std.mem.Allocator, c: *const chunk.Chunk, name: []const u8, writer: anytype) !void {
    _ = allocator;
    try writer.print("== {s} ==\n", .{name});

    var offset: usize = 0;

    while (offset < c.code.items.len) {
        // Zero-padded, right-aligned, width 4
        try writer.print("{d:0>4} ", .{offset});
        offset = try disassembleInstruction(c, offset, writer);
    }
}

pub fn disassembleInstruction(c: *const chunk.Chunk, offset: usize, writer: anytype) !usize {
    const instruction = c.code.items[offset];
    const op: chunk.OpCode = @fromBackingInt(instruction);

    switch (op) {
        .op_return,
        .op_nil,
        .op_true,
        .op_false,
        .op_pop,
        .op_dup,
        .op_dup_two,
        .op_array_push,
        .op_array_spread,
        .op_map_insert,
        .op_map_spread,
        .op_pop_rescue,
        .op_throw,
        .op_is_instance,
        .op_add,
        .op_subtract,
        .op_multiply,
        .op_divide,
        .op_modulo,
        .op_exponent,
        .op_bitwise_and,
        .op_bitwise_or,
        .op_bitwise_xor,
        .op_shift_left,
        .op_shift_right,
        .op_negate,
        .op_not,
        .op_equal,
        .op_greater,
        .op_less,
        .op_less_equal,
        .op_greater_equal,
        .op_cmp,
        .op_close_upvalue,
        .op_get_index,
        .op_set_index,
        .op_inherit,
        .op_block_given,
        .op_mixin,
        .op_is_nil,
        .op_case_equal,
        .op_break_block,
        => {
            return simpleInstruction(@tagName(op), offset, writer);
        },
        // Property ops carry a trailing 16-bit inline-cache index after the constant
        .op_get_property, .op_set_property, .op_get_ivar => {
            const next = try constantInstruction(@tagName(op), c, offset, false, writer);
            return inlineCacheOperand(c, next, writer);
        },
        .op_get_property_wide, .op_set_property_wide, .op_get_ivar_wide => {
            const next = try constantInstruction(@tagName(op), c, offset, true, writer);
            return inlineCacheOperand(c, next, writer);
        },
        .op_constant, .op_get_global, .op_define_global, .op_set_global, .op_class, .op_method, .op_import, .op_class_method, .op_get_class_var, .op_set_class_var, .op_module, .op_set_member, .op_defined => {
            return constantInstruction(@tagName(op), c, offset, false, writer);
        },
        .op_constant_wide, .op_get_global_wide, .op_define_global_wide, .op_set_global_wide, .op_class_wide, .op_method_wide, .op_import_wide, .op_class_method_wide, .op_get_class_var_wide, .op_set_class_var_wide, .op_module_wide, .op_set_member_wide, .op_defined_wide => {
            return constantInstruction(@tagName(op), c, offset, true, writer);
        },
        .op_call, .op_super_invoke, .op_yield => return callInstruction(@tagName(op), c, offset, writer),
        .op_unpack, .op_get_upvalue, .op_set_upvalue, .op_build_range, .op_interpolate => {
            return byteInstruction(@tagName(op), c, offset, writer);
        },
        .op_build_array, .op_build_map, .op_get_local, .op_set_local => {
            return byteInstruction(@tagName(op), c, offset, writer);
        },
        .op_build_array_wide, .op_build_map_wide, .op_get_local_wide, .op_set_local_wide => {
            return wideOperandInstruction(@tagName(op), c, offset, writer);
        },
        .op_unpack_splat, .op_pack_splat => {
            return twoByteInstruction(@tagName(op), c, offset, writer);
        },
        .op_for_next => {
            const slot = (@as(u16, c.code.items[offset + 1]) << 8) | c.code.items[offset + 2];
            const exit = offset + 7 + readJump(c, offset + 3);
            try writer.print("{s: <16} slot:{d} {d: >4} -> {d}\n", .{ @tagName(op), slot, offset, exit });
            return offset + 7;
        },
        .op_jump, .op_jump_if_false, .op_jump_if_nil, .op_jump_if_not_nil, .op_setup_rescue, .op_loop => {
            return jumpInstruction(@tagName(op), if (op == .op_loop) -1 else 1, c, offset, writer);
        },
        .op_extract_kwarg => {
            const map_slot = c.code.items[offset + 1];
            const name_idx = c.code.items[offset + 2];
            try writer.print("{s: <16} slot:{d} const:{d}\n", .{ @tagName(op), map_slot, name_idx });
            return offset + 3;
        },
        .op_extract_kwarg_wide => {
            const map_slot = c.code.items[offset + 1];
            const name_idx = (@as(u16, c.code.items[offset + 2]) << 8) | c.code.items[offset + 3];
            try writer.print("{s: <16} slot:{d} const:{d}\n", .{ @tagName(op), map_slot, name_idx });
            return offset + 4;
        },
        .op_invoke => {
            const next = try invokeInstruction(@tagName(op), c, offset, false, writer);
            return inlineCacheOperand(c, next, writer);
        },
        .op_invoke_wide => {
            const next = try invokeInstruction(@tagName(op), c, offset, true, writer);
            return inlineCacheOperand(c, next, writer);
        },
        .op_switch => return switchInstruction(@tagName(op), c, offset, false, writer),
        .op_switch_wide => return switchInstruction(@tagName(op), c, offset, true, writer),
        .op_closure, .op_closure_wide => {
            var new_offset = offset + 1;
            var constant: u16 = 0;
            if (op == .op_closure_wide) {
                constant = (@as(u16, c.code.items[new_offset]) << 8) | c.code.items[new_offset + 1];
                new_offset += 2;
            } else {
                constant = c.code.items[new_offset];
                new_offset += 1;
            }

            // Space-padded left-aligned string, space-padded right-aligned integer
            try writer.print("{s: <16} {d: >4} ", .{ @tagName(op), constant });
            if (constant >= c.constants.items.len) {
                try writer.writeAll("<invalid constant>\n");
                return new_offset;
            }
            try c.constants.items[constant].stringify(true, writer);
            try writer.writeAll("\n");

            const func_val = c.constants.items[constant];
            const func_obj: *value.ObjFunction = @alignCast(@fieldParentPtr("obj", func_val.asObj()));

            for (0..func_obj.upvalue_count) |_| {
                const is_local = c.code.items[new_offset];
                new_offset += 1;
                // Read 16-bit upvalue index
                const index = (@as(u16, c.code.items[new_offset]) << 8) | c.code.items[new_offset + 1];
                new_offset += 2;

                const upval_type = if (is_local == 1) "local" else "upvalue";
                try writer.print("{d:0>4}      |                     {s} {d}\n", .{ new_offset - 3, upval_type, index });
            }

            return new_offset;
        },
    }
}

/// Reads a 32-bit big-endian jump offset, matching the VM's readJumpOffset.
fn readJump(c: *const chunk.Chunk, at: usize) usize {
    return (@as(usize, c.code.items[at]) << 24) |
        (@as(usize, c.code.items[at + 1]) << 16) |
        (@as(usize, c.code.items[at + 2]) << 8) |
        c.code.items[at + 3];
}

fn inlineCacheOperand(c: *const chunk.Chunk, offset: usize, writer: anytype) !usize {
    const ic_idx = (@as(u16, c.code.items[offset]) << 8) | c.code.items[offset + 1];
    try writer.print("{s: <21}| ic {d}\n", .{ "", ic_idx });
    return offset + 2;
}

fn printConstant(c: *const chunk.Chunk, index: u16, writer: anytype) !void {
    // Never trust operands blindly: this tool is used to inspect broken bytecode
    if (index >= c.constants.items.len) {
        try writer.writeAll("<invalid constant>");
        return;
    }
    try c.constants.items[index].stringify(true, writer);
}

fn simpleInstruction(name: []const u8, offset: usize, writer: anytype) !usize {
    try writer.print("{s}\n", .{name});
    return offset + 1;
}

/// op_call, op_super_invoke, op_yield: an argument count and its CallFlags.
fn callInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, writer: anytype) !usize {
    const arg_count = c.code.items[offset + 1];
    const flags: chunk.CallFlags = @bitCast(c.code.items[offset + 2]);
    try writer.print("{s: <16} ({d} args{s}{s})\n", .{ name, arg_count, blockNote(flags), spreadNote(flags) });
    return offset + 3;
}

fn blockNote(flags: chunk.CallFlags) []const u8 {
    return if (flags.has_block) ", block" else "";
}

fn spreadNote(flags: chunk.CallFlags) []const u8 {
    return if (flags.spread) ", spread" else "";
}

fn byteInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, writer: anytype) !usize {
    const slot = c.code.items[offset + 1];
    try writer.print("{s: <16} {d: >4}\n", .{ name, slot });
    return offset + 2;
}

fn wideOperandInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, writer: anytype) !usize {
    const operand = (@as(u16, c.code.items[offset + 1]) << 8) | c.code.items[offset + 2];
    try writer.print("{s: <16} {d: >4}\n", .{ name, operand });
    return offset + 3;
}

fn twoByteInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, writer: anytype) !usize {
    const slot1 = c.code.items[offset + 1];
    const slot2 = c.code.items[offset + 2];
    try writer.print("{s: <16} {d: >4} {d: >4}\n", .{ name, slot1, slot2 });
    return offset + 3;
}

fn jumpInstruction(name: []const u8, sign: i32, c: *const chunk.Chunk, offset: usize, writer: anytype) !usize {
    const jump = readJump(c, offset + 1);
    const next = offset + 5;
    const target: isize = if (sign == 1) @as(isize, @intCast(next + jump)) else @as(isize, @intCast(next)) - @as(isize, @intCast(jump));

    try writer.print("{s: <16} {d: >4} -> {d}\n", .{ name, offset, target });
    return next;
}

fn constantInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, is_wide: bool, writer: anytype) !usize {
    var constant: u16 = 0;
    var new_offset = offset + 1;
    if (is_wide) {
        constant = (@as(u16, c.code.items[new_offset]) << 8) | c.code.items[new_offset + 1];
        new_offset += 2;
    } else {
        constant = c.code.items[new_offset];
        new_offset += 1;
    }

    try writer.print("{s: <16} {d: >4} '", .{ name, constant });
    try printConstant(c, constant, writer);
    try writer.writeAll("'\n");
    return new_offset;
}

fn invokeInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, is_wide: bool, writer: anytype) !usize {
    var constant: u16 = 0;
    var arg_count: u8 = 0;
    var new_offset = offset + 1;

    if (is_wide) {
        constant = (@as(u16, c.code.items[new_offset]) << 8) | c.code.items[new_offset + 1];
        arg_count = c.code.items[new_offset + 2];
        new_offset += 3;
    } else {
        constant = c.code.items[new_offset];
        arg_count = c.code.items[new_offset + 1];
        new_offset += 2;
    }
    const flags: chunk.CallFlags = @bitCast(c.code.items[new_offset]);
    new_offset += 1;

    try writer.print("{s: <16} ({d} args{s}{s}) {d: >4} '", .{ name, arg_count, blockNote(flags), spreadNote(flags), constant });
    try printConstant(c, constant, writer);
    try writer.writeAll("'\n");
    return new_offset;
}

fn switchInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, is_wide: bool, writer: anytype) !usize {
    var case_count: u16 = 0;
    var current_offset = offset + 1;

    if (is_wide) {
        case_count = (@as(u16, c.code.items[current_offset]) << 8) | c.code.items[current_offset + 1];
        current_offset += 2;
    } else {
        case_count = c.code.items[current_offset];
        current_offset += 1;
    }

    try writer.print("{s:<16} {d} cases\n", .{ name, case_count });

    // Offsets are relative to the byte after the default jump, as in the VM
    const jump_base = current_offset + @as(usize, case_count) * 6 + 4;
    for (0..case_count) |i| {
        // Entry layout: [const_hi, const_lo, jump_b3, jump_b2, jump_b1, jump_b0]
        const const_idx = (@as(u16, c.code.items[current_offset]) << 8) | c.code.items[current_offset + 1];
        const jump_offset = readJump(c, current_offset + 2);
        try writer.print("{s:<20} case {d}: const[{d}] jump +{d} -> {d}\n", .{ "", i, const_idx, jump_offset, jump_base + jump_offset });
        current_offset += 6;
    }

    const default_jump = readJump(c, current_offset);
    try writer.print("{s:<20} default: jump +{d} -> {d}\n", .{ "", default_jump, jump_base + default_jump });

    return current_offset + 4;
}
