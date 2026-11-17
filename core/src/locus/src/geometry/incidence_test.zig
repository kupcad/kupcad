const std = @import("std");
const canonical = @import("canonical.zig");
const incidence = @import("incidence.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Decider = incidence.Decider;
const Verdict = incidence.Verdict;
const holds = incidence.holds;

test "incidence: within, beyond and at the reach" {
    const tol = Tolerance.fromZone(1e-5);
    const d: Decider = .{ .tol = tol, .scale = 10 };
    try std.testing.expectEqual(Verdict.same, d.onPlane(-2.4e-5, 5e-6));
    try std.testing.expectEqual(Verdict.apart, d.onPlane(2.6e-5, 5e-6));
    try std.testing.expect(d.onPlane(2.5e-5 + 1e-13, 5e-6) == .at_tolerance);
    try std.testing.expect(d.merged(4e-5, 1e-5, 1e-5) == .at_tolerance);
    try std.testing.expectEqual(Verdict.apart, d.onCurve(2.1e-5, 0));
    try std.testing.expect(holds(d.onCurve(2e-5, 0)) and !holds(.apart));
    // The band holds every decision's
    try std.testing.expect(d.band() >= canonical.Comparison.distance(0, 4e-5, 10).band);
}

test "incidence: two parts decided together, at the tolerance only where the outcome hangs on it" {
    const at: Verdict = .{ .at_tolerance = canonical.Comparison.distance(2e-5, 2e-5, 1) };
    const parts = [_]Verdict{ .same, .apart, at };
    for (parts) |x| for (parts) |y| {
        const or_ = canonical.either(x, y);
        const and_ = canonical.both(x, y);
        // Whichever part is asked first
        try std.testing.expectEqual(std.meta.activeTag(or_), std.meta.activeTag(canonical.either(y, x)));
        try std.testing.expectEqual(std.meta.activeTag(and_), std.meta.activeTag(canonical.both(y, x)));
        // A part that is the same settles "either", one apart settles "both", whatever
        // the other; otherwise a part at the tolerance leaves the outcome open
        if (x == .same or y == .same) try std.testing.expect(or_ == .same) else if (x == .apart and y == .apart) try std.testing.expect(or_ == .apart) else try std.testing.expect(or_ == .at_tolerance);
        if (x == .apart or y == .apart) try std.testing.expect(and_ == .apart) else if (x == .same and y == .same) try std.testing.expect(and_ == .same) else try std.testing.expect(and_ == .at_tolerance);
    };
}
