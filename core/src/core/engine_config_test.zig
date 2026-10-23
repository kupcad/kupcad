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

test "turnShare: a sweep gets its share of a full turn's segments, rounded up, at least one" {
    const cases = [_]struct { per_turn: u32, turns: f64, expected: u32 }{
        .{ .per_turn = 32, .turns = 0.25, .expected = 8 },
        .{ .per_turn = 32, .turns = (std.math.pi / 2.0) / (2.0 * std.math.pi), .expected = 8 }, // an arc's, from radians
        .{ .per_turn = 30, .turns = 120.0 / 360.0, .expected = 10 }, // a ratio rounded a bit off a whole share
        .{ .per_turn = 30, .turns = 0.34, .expected = 11 }, // 10.2, rounded up
        .{ .per_turn = 30, .turns = 10, .expected = 300 }, // a helix's ten turns
        .{ .per_turn = 30, .turns = -0.5, .expected = 15 }, // either way round
        .{ .per_turn = 30, .turns = 1e-12, .expected = 1 },
        .{ .per_turn = 30, .turns = 0, .expected = 1 },
        .{ .per_turn = 2048, .turns = 100, .expected = limits.MAX_SEGMENTS },
    };
    for (cases) |case| {
        errdefer std.debug.print("{d} per turn, {d} turns\n", .{ case.per_turn, case.turns });
        try testing.expectEqual(case.expected, engine_config.turnShare(case.per_turn, case.turns));
    }
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

test "EngineConfig: chordError is how far a circle at this resolution strays from round" {
    // 16 segments for a radius-5 circle at the default resolution (by length: 2π·5 / 2).
    try testing.expectApproxEqAbs(5.0 * (1.0 - @cos(std.math.pi / 16.0)), (EngineConfig{}).chordError(5), 1e-12);
    // A square's corners stray 1 - cos 45° of the radius.
    try testing.expectApproxEqAbs(1.0 - @sqrt(0.5), (EngineConfig{ .resolution = .{ .segments = 4 } }).chordError(1), 1e-12);
}
