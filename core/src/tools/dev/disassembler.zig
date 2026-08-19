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
    const op: chunk.OpCode = @enumFromInt(instruction);

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
        .op_negate,
        .op_not,
        .op_equal,
        .op_greater,
        .op_less,
        .op_close_upvalue,
        .op_get_index,
        .op_set_index,
        .op_inherit,
        .op_block_given,
        .op_mixin,
        .op_is_nil,
        .op_case_equal,
        => {
            return simpleInstruction(@tagName(op), offset, writer);
        },
        .op_constant, .op_get_global, .op_define_global, .op_set_global, .op_class, .op_method, .op_get_property, .op_set_property, .op_import, .op_class_method, .op_get_class_var, .op_set_class_var, .op_module, .op_defined => {
            return constantInstruction(@tagName(op), c, offset, false, writer);
        },
        .op_constant_wide, .op_get_global_wide, .op_define_global_wide, .op_set_global_wide, .op_class_wide, .op_method_wide, .op_get_property_wide, .op_set_property_wide, .op_import_wide, .op_class_method_wide, .op_get_class_var_wide, .op_set_class_var_wide, .op_module_wide, .op_defined_wide => {
            return constantInstruction(@tagName(op), c, offset, true, writer);
        },
        .op_call, .op_unpack, .op_get_upvalue, .op_set_upvalue, .op_build_range, .op_interpolate, .op_super_invoke, .op_yield => {
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
            return invokeInstruction(@tagName(op), c, offset, false, writer);
        },
        .op_invoke_wide => {
            return invokeInstruction(@tagName(op), c, offset, true, writer);
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
            try c.constants.items[constant].stringify(true, writer);
            try writer.writeAll("\n");

            const func_val = c.constants.items[constant];
            const func_obj = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", func_val.asObj())));

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

fn simpleInstruction(name: []const u8, offset: usize, writer: anytype) !usize {
    try writer.print("{s}\n", .{name});
    return offset + 1;
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
    var jump: usize = @as(usize, c.code.items[offset + 1]) << 16;
    jump |= @as(usize, c.code.items[offset + 2]) << 8;
    jump |= c.code.items[offset + 3];

    const target = if (sign == 1) offset + 4 + jump else offset + 4 - jump;

    try writer.print("{s: <16} {d: >4} -> {d}\n", .{ name, offset, target });
    return offset + 4;
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
    try c.constants.items[constant].stringify(true, writer);
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

    try writer.print("{s: <16} ({d} args) {d: >4} '", .{ name, arg_count, constant });
    try c.constants.items[constant].stringify(true, writer);
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

    for (0..case_count) |i| {
        // Read the full 5-byte jump layout [const_h, const_l, jump_h, jump_m, jump_l]
        const const_idx = (@as(u16, c.code.items[current_offset]) << 8) | c.code.items[current_offset + 1];
        const jump_offset = (@as(usize, c.code.items[current_offset + 2]) << 16) | (@as(usize, c.code.items[current_offset + 3]) << 8) | c.code.items[current_offset + 4];
        try writer.print("{s:<20} case {d}: const[{d}] jump +{d} -> {d}\n", .{ "", i, const_idx, jump_offset, current_offset + 5 + jump_offset });
        current_offset += 5;
    }

    const default_jump = (@as(usize, c.code.items[current_offset]) << 16) | (@as(usize, c.code.items[current_offset + 1]) << 8) | c.code.items[current_offset + 2];
    try writer.print("{s:<20} default: jump +{d} -> {d}\n", .{ "", default_jump, current_offset + 3 + default_jump });

    return current_offset + 3;
}
