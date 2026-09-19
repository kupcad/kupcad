const std = @import("std");

pub const MathEnv = struct {
    vertex_tolerance: f64 = 1e-5,
    angular_tolerance: f64 = 1e-4,
    parametric_tolerance: f64 = 1e-5,

    pub fn isCoincident(self: MathEnv, a: [3]f64, b: [3]f64) bool {
        const dx = a[0] - b[0];
        const dy = a[1] - b[1];
        const dz = a[2] - b[2];
        return (dx * dx + dy * dy + dz * dz) <= (self.vertex_tolerance * self.vertex_tolerance);
    }

    pub fn isCoincident2D(self: MathEnv, a: [2]f64, b: [2]f64) bool {
        const dx = a[0] - b[0];
        const dy = a[1] - b[1];
        return (dx * dx + dy * dy) <= (self.parametric_tolerance * self.parametric_tolerance);
    }
};
