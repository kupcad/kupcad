const std = @import("std");
const testing = std.testing;
const vec = @import("vec.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;

test "vec: vec.cross products follow the right hand, vec.normalized refuses zero" {
    try testing.expectEqual(vec.Z3, vec.cross(vec.X3, vec.Y3));
    try testing.expectEqual(vec.X3, vec.cross(vec.Y3, vec.Z3));
    try testing.expectEqual(vec.Y3, vec.cross(vec.Z3, vec.X3));
    try testing.expectEqual(@as(?Vec3, null), vec.normalized(vec.ZERO3));
    try testing.expectEqual(@as(?Vec3, null), vec.normalized(.{ std.math.nan(f64), 0, 0 }));
    try testing.expectEqual(@as(?Vec3, Vec3{ 0, 1, 0 }), vec.normalized(.{ 0, 5, 0 }));
    try testing.expectEqual(@as(f64, 1), vec.cross2(.{ 1, 0 }, .{ 0, 1 }));
    try testing.expectEqual(Vec2{ -1, 0 }, vec.perp2(.{ 0, 1 }));
}

test "vec: vec.perpendicular is unit, orthogonal, and the same for the same direction" {
    const dirs = [_]Vec3{ vec.X3, vec.Y3, vec.Z3, .{ 0.6, 0.8, 0 }, .{ 0, 0.6, -0.8 }, vec.normalized(.{ 1, 1, 1 }).? };
    for (dirs) |n| {
        const p = vec.perpendicular(n);
        try testing.expectApproxEqAbs(@as(f64, 1), vec.length(p), 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(p, n), 1e-15);
        try testing.expectEqual(p, vec.perpendicular(n));
    }
    try testing.expectEqual(vec.Y3, vec.perpendicular(vec.X3));
    try testing.expectEqual(vec.X3, vec.perpendicular(vec.Z3));
}

test "vec: homogeneous points weigh and project back" {
    const p = Vec3{ 1, 2, 3 };
    try testing.expectEqual(Vec4{ 2, 4, 6, 2 }, vec.weighted(p, 2));
    try testing.expectEqual(p, vec.project4(vec.weighted(p, 2)));
}
