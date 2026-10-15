const std = @import("std");
const testing = std.testing;
const engine_config = @import("engine_config.zig");
const limits = @import("limits.zig");

const EngineConfig = engine_config.EngineConfig;
const Resolution = engine_config.Resolution;

test "Resolution: a fixed count wins, otherwise the finer of angle and length rules" {
    const defaults: Resolution = .{}; // 12 degrees, 2 units
    // Small circles are limited by edge length: 2πr / 2.
    try testing.expectEqual(@as(u32, 7), defaults.segmentsFor(2)); // ceil(6.28)
    // Large ones by angle: 360 / 12.
    try testing.expectEqual(@as(u32, 30), defaults.segmentsFor(100));
    // Never fewer than 5, however small the circle.
    try testing.expectEqual(@as(u32, 5), defaults.segmentsFor(0.01));
    // A degenerate radius gets the floor rather than a NaN count.
    try testing.expectEqual(@as(u32, 5), defaults.segmentsFor(0));
    try testing.expectEqual(@as(u32, 5), defaults.segmentsFor(std.math.nan(f64)));

    const fixed: Resolution = .{ .segments = 6 };
    try testing.expectEqual(@as(u32, 6), fixed.segmentsFor(0.01));
    try testing.expectEqual(@as(u32, 6), fixed.segmentsFor(1000));
}

test "EngineConfig: automatic counts stay within MAX_SEGMENTS" {
    const fine: EngineConfig = .{ .resolution = .{ .min_angle = 1e-9, .min_length = 1e-9 } };
    try testing.expectEqual(@as(u32, limits.MAX_SEGMENTS), fine.segmentsFor(1e6));
}

test "EngineConfig: problem names the first setting the kernels can't use" {
    try testing.expectEqual(@as(?[]const u8, null), (EngineConfig{}).problem());
    const cases = [_]struct { config: EngineConfig, expected: []const u8 }{
        .{ .config = .{ .tolerance = 0 }, .expected = "tolerance must be a positive number" },
        .{ .config = .{ .tolerance = std.math.inf(f64) }, .expected = "tolerance must be a positive number" },
        .{ .config = .{ .resolution = .{ .segments = 2 } }, .expected = "resolution segments must be 0 (automatic) or 3 to 2048" },
        .{ .config = .{ .resolution = .{ .segments = 2049 } }, .expected = "resolution segments must be 0 (automatic) or 3 to 2048" },
        .{ .config = .{ .resolution = .{ .min_angle = 181 } }, .expected = "resolution min_angle must be above 0 and at most 180 degrees" },
        .{ .config = .{ .resolution = .{ .min_length = 0 } }, .expected = "resolution min_length must be a positive number" },
        .{ .config = .{ .max_vertices = 0 }, .expected = "max_vertices must be at least 1" },
        .{ .config = .{ .brep = .{ .max_newton_trials = 0 } }, .expected = "brep max_newton_trials must be 1 to 1000" },
        .{ .config = .{ .brep = .{ .max_marching_steps = 100_001 } }, .expected = "brep max_marching_steps must be 1 to 100000" },
    };
    for (cases) |case| try testing.expectEqualStrings(case.expected, case.config.problem().?);
    try testing.expectEqual(@as(?[]const u8, null), (EngineConfig{ .resolution = .{ .segments = 3 } }).problem());
}

test "EngineConfig: resultHash changes with every setting that changes a result" {
    const base = (EngineConfig{}).resultHash();
    const changed = [_]EngineConfig{
        .{ .engine = .brep_native },
        .{ .tolerance = 1e-3 },
        .{ .resolution = .{ .segments = 8 } },
        .{ .resolution = .{ .min_angle = 6 } },
        .{ .resolution = .{ .min_length = 1 } },
        .{ .manifold = .{ .simplify_coplanar = true } },
        .{ .brep = .{ .max_newton_trials = 10 } },
        .{ .brep = .{ .max_marching_steps = 10 } },
    };
    for (changed) |config| try testing.expect(config.resultHash() != base);
    // The vertex budget decides whether an operation may run, not what it builds.
    try testing.expectEqual(base, (EngineConfig{ .max_vertices = 10 }).resultHash());
}
