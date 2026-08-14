const std = @import("std");
const chunk = @import("../../vm/chunk.zig");
const value = @import("../../core/value.zig");

pub fn disassembleChunk(allocator: std.mem.Allocator, c: *const chunk.Chunk, name: []const u8, writer: *std.Io.Writer) !void {
    _ = allocator;
    try writer.print("== {s} ==\n", .{name});

    var offset: usize = 0;

    while (offset < c.code.items.len) {
        // Zero-padded, right-aligned, width 4
        try writer.print("{d:0>4} ", .{offset});
        offset = try disassembleInstruction(c, offset, writer);
    }
}

pub fn disassembleInstruction(c: *const chunk.Chunk, offset: usize, writer: *std.Io.Writer) !usize {
    const instruction = c.code.items[offset];
    const op: chunk.OpCode = @enumFromInt(instruction);

    switch (op) {
        .op_return,
        .op_nil,
        .op_true,
        .op_false,
        .op_pop,
        .op_dup,
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
        .op_negate,
        .op_not,
        .op_equal,
        .op_greater,
        .op_less,
        .op_close_upvalue,
        .op_get_index,
        .op_set_index,
        .op_inherit,
        => {
            return simpleInstruction(@tagName(op), offset, writer);
        },
        .op_constant, .op_get_global, .op_define_global, .op_set_global, .op_class, .op_method, .op_get_property, .op_set_property, .op_import => {
            return constantInstruction(@tagName(op), c, offset, writer);
        },
        .op_get_local, .op_set_local, .op_call, .op_build_array, .op_build_map, .op_unpack, .op_get_upvalue, .op_set_upvalue, .op_build_range, .op_interpolate, .op_super_invoke, .op_yield => {
            return byteInstruction(@tagName(op), c, offset, writer);
        },
        .op_jump, .op_jump_if_false, .op_jump_if_nil, .op_setup_rescue, .op_loop => {
            return jumpInstruction(@tagName(op), if (op == .op_loop) -1 else 1, c, offset, writer);
        },
        .op_invoke => {
            return invokeInstruction(@tagName(op), c, offset, writer);
        },
        .op_switch => return switchInstruction(@tagName(op), c, offset, writer),
        .op_closure => {
            var new_offset = offset + 1;
            const constant = c.code.items[new_offset];
            new_offset += 1;

            // Space-padded left-aligned string, space-padded right-aligned integer
            try writer.print("{s: <16} {d: >4} ", .{ @tagName(op), constant });
            try c.constants.items[constant].stringify(true, writer);
            try writer.writeAll("\n");

            const func_val = c.constants.items[constant];
            const func_obj = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", func_val.asObj())));
            for (0..func_obj.upvalue_count) |_| {
                const is_local = c.code.items[new_offset];
                new_offset += 1;
                const index = c.code.items[new_offset];
                new_offset += 1;

                const upval_type = if (is_local == 1) "local" else "upvalue";
                try writer.print("{d:0>4}      |                     {s} {d}\n", .{ new_offset - 2, upval_type, index });
            }
            return new_offset;
        },
    }
}

fn simpleInstruction(name: []const u8, offset: usize, writer: *std.Io.Writer) !usize {
    try writer.print("{s}\n", .{name});
    return offset + 1;
}

fn byteInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, writer: *std.Io.Writer) !usize {
    const slot = c.code.items[offset + 1];
    try writer.print("{s: <16} {d: >4}\n", .{ name, slot });
    return offset + 2;
}

fn jumpInstruction(name: []const u8, sign: i32, c: *const chunk.Chunk, offset: usize, writer: *std.Io.Writer) !usize {
    var jump: u16 = @as(u16, c.code.items[offset + 1]) << 8;
    jump |= c.code.items[offset + 2];
    const jump_usize = @as(usize, jump);
    const target = if (sign == 1) offset + 3 + jump_usize else offset + 3 - jump_usize;

    try writer.print("{s: <16} {d: >4} -> {d}\n", .{ name, offset, target });
    return offset + 3;
}

fn constantInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, writer: *std.Io.Writer) !usize {
    const constant = c.code.items[offset + 1];
    try writer.print("{s: <16} {d: >4} '", .{ name, constant });
    try c.constants.items[constant].stringify(true, writer);
    try writer.writeAll("'\n");
    return offset + 2;
}

fn invokeInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, writer: *std.Io.Writer) !usize {
    const constant = c.code.items[offset + 1];
    const arg_count = c.code.items[offset + 2];
    try writer.print("{s: <16} ({d} args) {d: >4} '", .{ name, arg_count, constant });
    try c.constants.items[constant].stringify(true, writer);
    try writer.writeAll("'\n");
    return offset + 3;
}

fn switchInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, writer: anytype) !usize {
    const case_count = c.code.items[offset + 1];
    try writer.print("{s:<16} {d} cases\n", .{ name, case_count });

    var current_offset = offset + 2;
    for (0..case_count) |i| {
        const const_idx = c.code.items[current_offset];
        const jump_offset = (@as(u16, c.code.items[current_offset + 1]) << 8) | c.code.items[current_offset + 2];
        try writer.print("{s:<20} case {d}: const[{d}] jump +{d} -> {d}\n", .{ "", i, const_idx, jump_offset, current_offset + 3 + jump_offset });
        current_offset += 3;
    }

    const default_jump = (@as(u16, c.code.items[current_offset]) << 8) | c.code.items[current_offset + 1];
    try writer.print("{s:<20} default: jump +{d} -> {d}\n", .{ "", default_jump, current_offset + 2 + default_jump });

    return current_offset + 2;
}
