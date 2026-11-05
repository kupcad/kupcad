//! How the exports number a name used again: `numberedName` ("lid_2"), which the parts
//! list (parts.zig) and `kupcad build --split` use, and `UniqueNames`, the names of a
//! drawing's shapes as a format writes them, each one different: a format's own spelling
//! of a script's name (an SVG id, a DXF layer) can make two names one (`a:b` and `a/b` are
//! both `a_b`), and two shapes can share a name. The later one gets a number (`a_b_2`).

const std = @import("std");

/// What joins a name and its number.
pub const NAME_NUMBER_SEPARATOR = "_";

/// `name` with `number` after it ("lid_2"), or the name itself for the first. Caller owns it.
pub fn numberedName(allocator: std.mem.Allocator, name: []const u8, number: usize) ![]u8 {
    return if (number == 1) allocator.dupe(u8, name) else allocator.print("{s}" ++ NAME_NUMBER_SEPARATOR ++ "{d}", .{ name, number });
}

pub const UniqueNames = struct {
    /// Owns the names given out.
    arena: std.mem.Allocator,
    taken: std.StringHashMapUnmanaged(void) = .empty,
    /// The number each name was last given out with: the next one is tried from there.
    /// Trying from 1 each time, a candidate allocated per number, made n shapes of one name
    /// quadratic (8000 took 32 s and 410 MB).
    numbers: std.StringHashMapUnmanaged(usize) = .empty,
    /// Where a candidate is spelt out before it is known to be free.
    candidate: std.ArrayList(u8) = .empty,

    /// `name`, or the first of `name_2`, `name_3`, ... not taken yet; taken from now on.
    pub fn take(self: *UniqueNames, name: []const u8) ![]const u8 {
        const last = try self.numbers.getOrPut(self.arena, name);
        if (!last.found_existing) {
            last.key_ptr.* = try self.arena.dupe(u8, name);
            last.value_ptr.* = 0;
        }
        var number = last.value_ptr.*;
        while (true) {
            number += 1;
            self.candidate.clearRetainingCapacity();
            try self.candidate.appendSlice(self.arena, name);
            if (number > 1) try self.candidate.print(self.arena, NAME_NUMBER_SEPARATOR ++ "{d}", .{number});
            if (!self.taken.contains(self.candidate.items)) break;
        }
        last.value_ptr.* = number;
        const kept = try self.arena.dupe(u8, self.candidate.items);
        try self.taken.put(self.arena, kept, {});
        return kept;
    }
};
