//! Prints a bytecode chunk as readable text, one instruction per line with its offset,
//! operands and constants: `disassembleChunk` for a whole chunk, `disassembleInstruction`
//! for one. Used by `kupcad dev disasm`.

const std = @import("std");
const chunk = @import("../../vm/chunk.zig");

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
    const op: chunk.OpCode = @fromBackingInt(c.code.items[offset]);
    const name = @tagName(op);
    switch (chunk.operandsOf(op)) {
        .none => return simpleInstruction(name, offset, writer),
        .constant, .constant_wide => |layout| return constantInstruction(name, c, offset, layout == .constant_wide, writer),
        .local, .upvalue, .count => return byteInstruction(name, c, offset, writer),
        .local_wide, .count_wide => return wideOperandInstruction(name, c, offset, writer),
        .count_pair => return twoByteInstruction(name, c, offset, writer),
        .call => return callInstruction(name, c, offset, writer),
        .kwarg, .kwarg_wide => |layout| {
            const map_slot = c.code.items[offset + 1];
            const name_idx: u16 = if (layout == .kwarg_wide) chunk.readU16(c.code.items, offset + 2) else c.code.items[offset + 2];
            try writer.print("{s: <16} slot:{d} const:{d}\n", .{ name, map_slot, name_idx });
            return offset + if (layout == .kwarg_wide) @as(usize, 4) else 3;
        },
        // A name, then the cache it is looked up through
        .global, .global_wide => |layout| return cacheOperand("global cache", try constantInstruction(name, c, offset, layout == .global_wide, writer), c, writer),
        .property, .property_wide => |layout| return cacheOperand("ic", try constantInstruction(name, c, offset, layout == .property_wide, writer), c, writer),
        .invoke, .invoke_wide => |layout| return cacheOperand("ic", try invokeInstruction(name, c, offset, layout == .invoke_wide, writer), c, writer),
        .for_next => {
            const slot = chunk.readU16(c.code.items, offset + 1);
            const exit = offset + 7 + chunk.readU32(c.code.items, offset + 3);
            try writer.print("{s: <16} slot:{d} {d: >4} -> {d}\n", .{ name, slot, offset, exit });
            return offset + 7;
        },
        .jump, .loop => |layout| return jumpInstruction(name, if (layout == .loop) -1 else 1, c, offset, writer),
        .switch_table, .switch_table_wide => |layout| return switchInstruction(name, c, offset, layout == .switch_table_wide, writer),
        .closure, .closure_wide => |layout| {
            var new_offset = offset + 1;
            var constant: u16 = 0;
            if (layout == .closure_wide) {
                constant = chunk.readU16(c.code.items, new_offset);
                new_offset += 2;
            } else {
                constant = c.code.items[new_offset];
                new_offset += 1;
            }

            // Space-padded left-aligned string, space-padded right-aligned integer
            try writer.print("{s: <16} {d: >4} ", .{ name, constant });
            if (constant >= c.constants.items.len) {
                try writer.writeAll("<invalid constant>\n");
                return new_offset;
            }
            try c.constants.items[constant].stringify(true, writer);
            try writer.writeAll("\n");

            const func_val = c.constants.items[constant];
            const func_obj = func_val.asFunction();

            for (0..func_obj.upvalue_count) |_| {
                const is_local = c.code.items[new_offset];
                new_offset += 1;
                // Read 16-bit upvalue index
                const index = chunk.readU16(c.code.items, new_offset);
                new_offset += 2;

                const upval_type = if (is_local == 1) "local" else "upvalue";
                try writer.print("{d:0>4}      |                     {s} {d}\n", .{ new_offset - 3, upval_type, index });
            }

            return new_offset;
        },
    }
}

/// The 16-bit cache index after an instruction's constant (`label`: "ic" or "global cache").
fn cacheOperand(label: []const u8, offset: usize, c: *const chunk.Chunk, writer: anytype) !usize {
    const idx = chunk.readU16(c.code.items, offset);
    try writer.print("{s: <21}| {s} {d}\n", .{ "", label, idx });
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
    const operand = chunk.readU16(c.code.items, offset + 1);
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
    const jump = chunk.readU32(c.code.items, offset + 1);
    const next = offset + 5;
    const target: isize = if (sign == 1) @as(isize, @intCast(next + jump)) else @as(isize, @intCast(next)) - @as(isize, @intCast(jump));

    try writer.print("{s: <16} {d: >4} -> {d}\n", .{ name, offset, target });
    return next;
}

fn constantInstruction(name: []const u8, c: *const chunk.Chunk, offset: usize, is_wide: bool, writer: anytype) !usize {
    var constant: u16 = 0;
    var new_offset = offset + 1;
    if (is_wide) {
        constant = chunk.readU16(c.code.items, new_offset);
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
        constant = chunk.readU16(c.code.items, new_offset);
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
        case_count = chunk.readU16(c.code.items, current_offset);
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
        const const_idx = chunk.readU16(c.code.items, current_offset);
        const jump_offset = chunk.readU32(c.code.items, current_offset + 2);
        try writer.print("{s:<20} case {d}: const[{d}] jump +{d} -> {d}\n", .{ "", i, const_idx, jump_offset, jump_base + jump_offset });
        current_offset += 6;
    }

    const default_jump = chunk.readU32(c.code.items, current_offset);
    try writer.print("{s:<20} default: jump +{d} -> {d}\n", .{ "", default_jump, jump_base + default_jump });

    return current_offset + 4;
}
