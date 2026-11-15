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
