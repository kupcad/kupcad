//! Whether a sheet's faces overlap (docs/architecture.md §9.1, level 2): the rule M0 left
//! to an intersector, for sheets now. Each face of a sheet is valid on its own, and two
//! faces in shells of their own over one region pass every rule of the checker (the
//! fuzzer's lens of 2026-11-12: a face over the face around it); the sheet overlaid with
//! itself (§7.3) winds once about every region of it, or not at all, and an overlap is a
//! region it winds about twice (or a face facing the other way, the other sign). The rule
//! needs the overlay, which the checker may not import (§4, the checker imports no
//! operation), so it lives beside the overlay and runs where sheets are graded: the
//! fuzzer's chains, the sketch tests, and a sheet taken from outside the kernel before
//! any operation or the mesher reads it (the kernel's own sheets are the overlay's).
//!
//! The same overlay finds where the sheet meets itself: its edges meet only at its
//! vertices, so every point the overlay makes past the sheet's own (a crossing, or a touch
//! within the zone, of two of its edges or one with itself) is a fault, the face's rings
//! not simple, as the mesher names it. OCCT's `BOPAlgo_CheckerSI` is its intersector run
//! on one shape; this is the overlay's decisions (coincidence first, D27's band) asked of
//! one sheet, never a second measure of nearness (Leo, 2026-11-16: two circles touching
//! with no vertex there passed the checker, and the mesher was the first to refuse).

const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const body_mod = @import("../topology/body.zig");
const overlay_mod = @import("overlay.zig");
const boolean = @import("boolean.zig");
const Body = body_mod.Body;
const Overlay = overlay_mod.Overlay;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// Fails with `faces_overlap` (`error.NotValid`) when two faces of `sheet` lie over one
/// region, or faces face opposite ways, the measured value the winding found there; then
/// with `not_simple` when its edges meet anywhere but at its vertices, the measured value
/// how many points they meet at.
pub fn check(allocator: std.mem.Allocator, sheet: *const Body, diag: *Diagnostics) Error!void {
    if (sheet.kind != .sheet) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "the body: a sheet" });
    if (sheet.isEmpty()) return;
    var o = Overlay.init(allocator, sheet.tol);
    defer o.deinit();
    _ = o.addInput() catch |e| return boolean.mapError(diag, e);
    try boolean.addSheet(&o, sheet, diag);
    // The sheet's vertices, welded: any point past them is one the cutting made
    const own = o.points.items.len;
    o.run() catch |e| return boolean.mapError(diag, e);
    // Every region wound by one sign, once
    var sign: i32 = 0;
    for (0..o.faces.items.len) |f| {
        const w = o.windingOf(@intCast(f), 0);
        if (w == 0) continue;
        if (sign == 0) sign = std.math.sign(w);
        if (w != sign) return diag.fail(error.NotValid, .{ .code = .faces_overlap, .entity = .{ .kind = .body }, .label = "a region of the sheet", .measured = @floatFromInt(w), .threshold = @floatFromInt(sign) });
    }
    // Its edges meeting only at its vertices
    const made = o.points.items.len - own;
    if (made > 0) return diag.fail(error.NotValid, .{ .code = .not_simple, .entity = .{ .kind = .body }, .label = "the sheet, two of whose edges meet away from its vertices (the measured value: the points they meet at),", .measured = @floatFromInt(made), .threshold = 0 });
}
