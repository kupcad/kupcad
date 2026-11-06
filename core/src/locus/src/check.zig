//! The root of `zig build check`: a library that references everything the module exports,
//! so that compiling it for a target (wasm32-freestanding, which has no test runner) proves
//! every public declaration builds there. `legacy` is left out: it reads files and goes
//! with M0.

const std = @import("std");
const locus = @import("locus");

comptime {
    for (std.meta.declarations(locus)) |name| {
        if (!std.mem.eql(u8, name, "legacy")) refAll(@field(locus, name));
    }
}

/// References `value` and, when it is a namespace, every declaration in it.
fn refAll(comptime value: anytype) void {
    if (@TypeOf(value) == type) {
        switch (@typeInfo(value)) {
            .@"struct", .@"enum", .@"union", .@"opaque" => for (std.meta.declarations(value)) |name| refAll(@field(value, name)),
            else => {},
        }
    } else {
        _ = &value;
    }
}

export fn locus_check() void {}
