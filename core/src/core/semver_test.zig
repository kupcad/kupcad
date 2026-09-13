const std = @import("std");
const testing = std.testing;
const semver = @import("semver.zig");

test "SemVer: Parses valid version strings" {
    const v1 = try semver.Version.parse("1.2.3");
    try testing.expectEqual(@as(u64, 1), v1.major);
    try testing.expectEqual(@as(u64, 2), v1.minor);
    try testing.expectEqual(@as(u64, 3), v1.patch);

    const v2 = try semver.Version.parse("v2.0");
    try testing.expectEqual(@as(u64, 2), v2.major);
    try testing.expectEqual(@as(u64, 0), v2.minor);
    try testing.expectEqual(@as(u64, 0), v2.patch);
}

test "SemVer: Exact Constraints (=)" {
    const c = try semver.Constraint.parse("=1.5.0");
    try testing.expect(c.satisfies(try semver.Version.parse("1.5.0")));
    try testing.expect(!c.satisfies(try semver.Version.parse("1.5.1")));
}

test "SemVer: Caret Constraints (^)" {
    const c1 = try semver.Constraint.parse("^1.2.3");
    try testing.expect(c1.satisfies(try semver.Version.parse("1.2.3")));
    try testing.expect(c1.satisfies(try semver.Version.parse("1.5.0")));
    try testing.expect(c1.satisfies(try semver.Version.parse("1.9.9")));
    try testing.expect(!c1.satisfies(try semver.Version.parse("2.0.0"))); // Major bump invalid
    try testing.expect(!c1.satisfies(try semver.Version.parse("1.2.2"))); // Older version invalid

    // Caret behavior for pre-1.0 APIs
    const c2 = try semver.Constraint.parse("^0.2.3");
    try testing.expect(c2.satisfies(try semver.Version.parse("0.2.3")));
    try testing.expect(c2.satisfies(try semver.Version.parse("0.2.9")));
    try testing.expect(!c2.satisfies(try semver.Version.parse("0.3.0"))); // Minor bump invalid pre-1.0
}

test "SemVer: Tilde Constraints (~)" {
    const c = try semver.Constraint.parse("~1.2.3");
    try testing.expect(c.satisfies(try semver.Version.parse("1.2.3")));
    try testing.expect(c.satisfies(try semver.Version.parse("1.2.9")));
    try testing.expect(!c.satisfies(try semver.Version.parse("1.3.0"))); // Minor bump invalid
}
