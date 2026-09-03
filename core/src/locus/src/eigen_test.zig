const std = @import("std");
const eigen = @import("eigen.zig");
const math = @import("math.zig");

test "Eigen: Robust 2D Orientation" {
    const a = math.Vec2{ 0.0, 0.0 };
    const b = math.Vec2{ 10.0, 0.0 };

    // C is above the line AB (Counter-Clockwise)
    try std.testing.expect(eigen.orient2D(a, b, .{ 5.0, 5.0 }) > 0.0);

    // C is below the line AB (Clockwise)
    try std.testing.expect(eigen.orient2D(a, b, .{ 5.0, -5.0 }) < 0.0);

    // C is exactly on the line AB (Collinear)
    try std.testing.expectApproxEqAbs(0.0, eigen.orient2D(a, b, .{ 5.0, 0.0 }), 1e-9);
}

test "Eigen: Robust In-Circle Evaluation" {
    // A Right Triangle circumcircle. Center is (5, 5), Radius is 5.
    const a = math.Vec2{ 0.0, 0.0 };
    const b = math.Vec2{ 10.0, 0.0 };
    const c = math.Vec2{ 10.0, 10.0 };

    // Point clearly inside the circle
    try std.testing.expect(eigen.inCircle(a, b, c, .{ 5.0, 5.0 }) > 0.0);

    // Point clearly outside the circle
    try std.testing.expect(eigen.inCircle(a, b, c, .{ 20.0, 20.0 }) < 0.0);

    // Point exactly on the boundary of the circle (0, 10)
    try std.testing.expectApproxEqAbs(0.0, eigen.inCircle(a, b, c, .{ 0.0, 10.0 }), 1e-9);
}

test "Eigen: PCA Normal Generation" {
    // Generate a point cloud representing a tilted flat plane
    const pts = [_]math.Vec3{
        .{ 0.0, 0.0, 0.0 },
        .{ 10.0, 0.0, 10.0 },
        .{ 0.0, 10.0, 0.0 },
        .{ 10.0, 10.0, 10.0 },
    };

    const normal = eigen.pcaNormal(&pts);
    // The expected normal should be orthogonal to the plane.
    // For a plane rising on X=Z, the normal should be roughly [-0.707, 0, 0.707]
    try std.testing.expectApproxEqAbs(0.0, normal[1], 1e-5);
    try std.testing.expect(normal[0] != 0.0);
    try std.testing.expect(normal[2] != 0.0);
}
