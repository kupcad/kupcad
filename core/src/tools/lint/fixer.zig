//! Applies lint fixes to source text, for `kupcad check --fix`.

const std = @import("std");
const linter = @import("linter.zig");

/// `source` with the safe fixes of `diagnostics` applied, or null if there are none. A fix
/// whose edits overlap one already taken waits for the next pass (`api.fixCode` repeats),
/// so no two fixes ever edit the same bytes. Caller owns the result.
pub fn applySafeFixes(allocator: std.mem.Allocator, source: []const u8, diagnostics: []const linter.LinterDiagnostic) !?Applied {
    var taken: std.ArrayList(linter.Edit) = .empty;
    defer taken.deinit(allocator);
    var fixes: usize = 0;
    for (diagnostics) |d| {
        const fix = d.fix orelse continue;
        if (!fix.safe or overlapsAny(fix.edits, taken.items)) continue;
        try taken.appendSlice(allocator, fix.edits);
        fixes += 1;
    }
    if (fixes == 0) return null;

    std.mem.sort(linter.Edit, taken.items, {}, struct {
        fn before(_: void, a: linter.Edit, b: linter.Edit) bool {
            return a.offset < b.offset;
        }
    }.before);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var copied: usize = 0;
    for (taken.items) |e| {
        try out.appendSlice(allocator, source[copied..e.offset]);
        try out.appendSlice(allocator, e.replacement);
        copied = e.offset + e.length;
    }
    try out.appendSlice(allocator, source[copied..]);
    return .{ .source = try out.toOwnedSlice(allocator), .fixes = fixes };
}

pub const Applied = struct {
    source: []u8,
    /// How many findings it resolved.
    fixes: usize,
};

fn overlapsAny(edits: []const linter.Edit, taken: []const linter.Edit) bool {
    for (edits) |a| {
        for (taken) |b| {
            if (a.offset < b.offset + b.length and b.offset < a.offset + a.length) return true;
            // Two insertions at one place would land in an order nobody chose.
            if (a.offset == b.offset) return true;
        }
    }
    return false;
}
