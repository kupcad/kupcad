//! Names for a drawing's shapes as a format writes them, each one different: a format's
//! own spelling of a script's name (an SVG id, a DXF layer) can make two names one (`a:b`
//! and `a/b` are both `a_b`), and two shapes can share a name. The later one gets a number,
//! as the parts list numbers a name used again (parts.numberedName: `a_b_2`).

const std = @import("std");
const numberedName = @import("../parts.zig").numberedName;

pub const UniqueNames = struct {
    /// Owns the names given out.
    arena: std.mem.Allocator,
    taken: std.StringHashMapUnmanaged(void) = .empty,

    /// `name`, or the first of `name_2`, `name_3`, ... not taken yet; taken from now on.
    pub fn take(self: *UniqueNames, name: []const u8) ![]const u8 {
        var number: usize = 1;
        while (true) : (number += 1) {
            const candidate = try numberedName(self.arena, name, number);
            const entry = try self.taken.getOrPut(self.arena, candidate);
            if (!entry.found_existing) return candidate;
        }
    }
};
