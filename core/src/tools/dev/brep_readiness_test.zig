const std = @import("std");
const testing = std.testing;
const readiness = @import("brep_readiness.zig");

test "B-Rep readiness: a script that builds, one the engine refuses naming what it lacks, one that doesn't parse" {
    var builds = try readiness.check(testing.allocator, testing.io, "cube(1)", .none);
    defer builds.deinit(testing.allocator);
    try testing.expectEqual(.builds, std.meta.activeTag(builds));

    var refused = try readiness.check(testing.allocator, testing.io, "cube(1) + cube(2)", .none);
    defer refused.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, refused.refused, "brep engine can't") != null);
    try testing.expect(std.mem.indexOf(u8, refused.refused, "combine solids") != null);

    var broken = try readiness.check(testing.allocator, testing.io, "cube(", .none);
    defer broken.deinit(testing.allocator);
    try testing.expectEqual(.refused, std.meta.activeTag(broken));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try readiness.writeReport(&out.writer, &.{
        .{ .path = "a.kup", .outcome = builds },
        .{ .path = "b.kup", .outcome = .{ .refused = @constCast("NotImplementedError: x") } },
        .{ .path = "c.kup", .outcome = .{ .failed = error.OutOfMemory } },
    });
    try testing.expectEqualStrings(
        \\a.kup: builds
        \\b.kup: NotImplementedError: x
        \\c.kup: failed (OutOfMemory)
        \\1 of 3 scripts build on the B-Rep engine
        \\
    , out.written());
}
