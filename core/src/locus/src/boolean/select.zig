//! The boolean's fourth phase (docs/architecture.md §7.4 step 5, KNOWLEDGE §7; Mäntylä's
//! selection, Stroud p.137, SolveSpace's `KeepRegion`): which fragments make the result,
//! by the operation, the operand a fragment is of and its class. Of two coincident
//! fragments (one plane, `on_same` or `on_opposite`) the first operand's alone is ever
//! kept, so a face both operands have is made once:
//!
//! | class        | union      | difference          | intersection |
//! |--------------|------------|---------------------|--------------|
//! | `a` outside  | keep       | keep                | drop         |
//! | `a` inside   | drop       | drop                | keep         |
//! | `a` on_same  | keep       | drop                | keep         |
//! | `a` opposite | drop       | keep                | drop         |
//! | `b` outside  | keep       | drop                | drop         |
//! | `b` inside   | drop       | keep, turned inward | keep         |
//! | `b` on_*     | drop       | drop                | drop         |

const std = @import("std");
const classify = @import("classify.zig");
const imprint = @import("imprint.zig");
const Class = classify.Class;

pub const Op = enum { @"union", difference, intersection };

pub const Keep = enum {
    drop,
    keep,
    /// Kept facing the other way: `b`'s inside of a difference bounds the cut.
    flip,
};

/// What becomes of a fragment of `operand` (0: `a`, 1: `b`) of class `class` in `op`.
pub fn keep(op: Op, operand: u1, class: Class) Keep {
    if (operand == 0) return switch (op) {
        .@"union" => if (class == .outside or class == .on_same) .keep else .drop,
        .difference => if (class == .outside or class == .on_opposite) .keep else .drop,
        .intersection => if (class == .inside or class == .on_same) .keep else .drop,
    };
    return switch (op) {
        .@"union" => if (class == .outside) .keep else .drop,
        .difference => if (class == .inside) .flip else .drop,
        .intersection => if (class == .inside) .keep else .drop,
    };
}

/// Each fragment's fate, by index; owned by `allocator`.
pub fn run(allocator: std.mem.Allocator, op: Op, fragments: *const imprint.Fragments, classes: []const classify.Classified) error{OutOfMemory}![]Keep {
    const out = try allocator.alloc(Keep, classes.len);
    for (fragments.items.items, classes, out) |fragment, c, *k| k.* = keep(op, fragment.operand, c.class);
    return out;
}
