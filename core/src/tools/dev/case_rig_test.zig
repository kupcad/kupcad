//! The case rig (cases.zig, case_rig.zig): every case on the B-Rep engine passes or is
//! refused by design, every case with a chordal bound passes on the mesh engine, the
//! verdicts come out as they should, and the ladder report reads as documented.

const std = @import("std");
const testing = std.testing;
const cases = @import("cases.zig");
const rig = @import("case_rig.zig");
const geom = @import("../../core/geometry_handle.zig");
const mesh_compare = @import("../../kernel/mesh_compare.zig");

/// Any case takes well under this on either engine; a run past it is a hang.
const TIME_LIMIT_MS = 60_000;

test "case rig: on the B-Rep engine every case passes or is refused by design, but for the known frontier" {
    const results = try rig.runAll(testing.allocator, testing.io, .brep_native, TIME_LIMIT_MS);
    defer rig.freeResults(testing.allocator, results);
    var wrong: usize = 0;
    for (results) |r| {
        const known = for (cases.KNOWN_FRONTIER) |k| {
            if (std.mem.eql(u8, k.name, r.case.name)) break true;
        } else false;
        switch (r.outcome.verdict) {
            .pass => if (known) {
                wrong += 1;
                std.debug.print("{s} passes: take it off KNOWN_FRONTIER\n", .{r.case.name});
            },
            .refused => try testing.expectEqual(.refused, std.meta.activeTag(r.case.expect)),
            .fail, .crash, .hang => if (!known) {
                wrong += 1;
                std.debug.print("{s} ({s}): {s}: {s}\n", .{ r.case.name, r.case.script, r.outcome.verdict.label(), r.outcome.message orelse "" });
            },
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "case rig: on the mesh engine every case with a chordal bound passes" {
    for (&cases.CASES) |*case| {
        if (case.mesh_bound == null) continue;
        var outcome = try rig.run(testing.allocator, testing.io, case, .manifold, TIME_LIMIT_MS);
        defer outcome.deinit(testing.allocator);
        errdefer std.debug.print("{s} ({s}): {s}: {s}\n", .{ case.name, case.script, outcome.verdict.label(), outcome.message orelse "" });
        try testing.expectEqual(.pass, outcome.verdict);
    }
}

test "case rig: every case has a name of its own and an answer that is not a kernel's" {
    for (&cases.CASES, 0..) |*case, i| {
        try testing.expect(case.name.len > 0 and case.what.len > 0 and case.method.len > 0 and case.from.len > 0);
        for (cases.CASES[0..i]) |earlier| try testing.expect(!std.mem.eql(u8, earlier.name, case.name));
        switch (case.expect) {
            .measures => |m| try testing.expect(m.empty == (m.volume == 0)),
            .refused => try testing.expectEqual(@as(?f64, null), case.mesh_bound),
        }
    }
}

test "case rig: a wrong answer fails, a missing refusal fails, a refusal by design is counted apart, and a slow run hangs" {
    const wrong = cases.Case{ .tier = .primitives, .name = "wrong cube", .script = "cube(2)", .what = "", .method = "a wrong answer", .source = .analytic, .from = "this test", .expect = .{ .measures = .{ .volume = 9 } }, .mesh_bound = cases.EXACT };
    var failed = try rig.run(testing.allocator, testing.io, &wrong, .brep_native, TIME_LIMIT_MS);
    defer failed.deinit(testing.allocator);
    try testing.expectEqual(.fail, failed.verdict);
    try testing.expect(std.mem.indexOf(u8, failed.message.?, "volume 8, expected 9") != null);

    const landed = cases.Case{ .tier = .primitives, .name = "landed", .script = "cube(2)", .what = "", .method = "", .source = .analytic, .from = "this test", .expect = .{ .refused = .{ .feature = .boolean, .until = "M9" } }, .mesh_bound = null };
    var built = try rig.run(testing.allocator, testing.io, &landed, .brep_native, TIME_LIMIT_MS);
    defer built.deinit(testing.allocator);
    try testing.expectEqual(.fail, built.verdict);
    try testing.expect(std.mem.indexOf(u8, built.message.?, "wants its closed form") != null);

    const refused = cases.Case{ .tier = .booleans, .name = "refused", .script = "cube(2) + sphere(r: 1)", .what = "", .method = "", .source = .analytic, .from = "this test", .expect = .{ .refused = .{ .feature = .curved_boolean, .until = "M5" } }, .mesh_bound = null };
    var apart = try rig.run(testing.allocator, testing.io, &refused, .brep_native, TIME_LIMIT_MS);
    defer apart.deinit(testing.allocator);
    errdefer std.debug.print("refused sample: {s}\n", .{apart.message orelse ""});
    try testing.expectEqual(.refused, apart.verdict);
    try testing.expect(std.mem.indexOf(u8, apart.message.?, "until M5") != null);

    const slow = cases.Case{ .tier = .primitives, .name = "slow", .script = "begin\n  n = 0\n  while true\n    n += 1\n  end\nend", .what = "", .method = "", .source = .analytic, .from = "this test", .expect = .{ .measures = .{ .volume = 1 } }, .mesh_bound = null };
    var hung = try rig.run(testing.allocator, testing.io, &slow, .brep_native, 50);
    defer hung.deinit(testing.allocator);
    errdefer std.debug.print("slow sample: {s}\n", .{hung.message orelse ""});
    try testing.expectEqual(.hang, hung.verdict);
}

test "case rig: the ladder report lists each tier's counts and frontier" {
    const a = cases.CASES[0];
    var b = cases.CASES[1];
    b.name = "a box that fails";
    var c = cases.CASES[6];
    c.tier = .booleans;
    const results = [_]rig.Result{
        .{ .case = &a, .outcome = .{ .verdict = .pass } },
        .{ .case = &b, .outcome = .{ .verdict = .fail, .message = @constCast("volume 5, expected 6") } },
        .{ .case = &c, .outcome = .{ .verdict = .refused, .message = @constCast("until M4: can't") } },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try rig.writeLadder(&out.writer, "B-Rep", &results);
    try testing.expectEqualStrings(
        \\Ladder on the B-Rep engine, 3 cases:
        \\  01 primitives: 1 pass, 1 fail; frontier: a box that fails (fail: volume 5, expected 6)
        \\  02 booleans: 1 refused by design
        \\  all: 1 pass, 1 fail, 1 refused by design; frontier: 01 primitives, a box that fails
        \\
    , out.written());
}

/// Both engines cut every circle into this many segments when their meshes are compared.
const COMPARE_PRELUDE = "CAD.config(resolution: {segments: 64})\n";

/// The kernel's mesh as the comparison reads it: its positions in doubles (owned) and its
/// triangles.
fn comparable(allocator: std.mem.Allocator, mesh: geom.Mesh) !struct { points: [][3]f64, triangles: []const [3]u32 } {
    const n = mesh.vert_props.len / mesh.num_prop;
    const points = try allocator.alloc([3]f64, n);
    for (points, 0..) |*p, i| {
        for (0..3) |k| p[k] = mesh.vert_props[i * mesh.num_prop + k];
    }
    return .{ .points = points, .triangles = std.mem.bytesAsSlice([3]u32, std.mem.sliceAsBytes(mesh.tri_verts)) };
}

test "case rig: on every case both engines build, their meshes lie within a chord of each other, the volume between them a thin shell" {
    // Both cut every circle into 64 segments, so each mesh lies within the sagitta
    // r (1 − cos(π/64)) of the exact solid, r at most half the box's diagonal D: the two
    // within D (1 − cos(π/64)) of each other, and what only one holds within a shell of
    // that thickness on either side of the surface
    const chord = 1 - @cos(std.math.pi / 64.0);
    var compared: usize = 0;
    for (&cases.CASES) |*case| {
        if (case.mesh_bound == null) continue;
        errdefer std.debug.print("case: {s} ({s})\n", .{ case.name, case.script });
        var outcomes: [2]rig.Outcome = undefined;
        var made: usize = 0;
        defer for (outcomes[0..made]) |*o| o.deinit(testing.allocator);
        for ([_]geom.EngineType{ .brep_native, .manifold }, &outcomes) |engine, *o| {
            o.* = try rig.runWith(testing.allocator, testing.io, case, engine, .{ .time_limit_ms = TIME_LIMIT_MS, .prelude = COMPARE_PRELUDE, .keep_mesh = true });
            made += 1;
            try testing.expectEqual(.pass, o.verdict);
        }
        // An empty result has no mesh on either
        if (case.expect.measures.empty) {
            try testing.expect(outcomes[0].mesh == null and outcomes[1].mesh == null);
            continue;
        }
        const a = try comparable(testing.allocator, outcomes[0].mesh.?);
        defer testing.allocator.free(a.points);
        const b = try comparable(testing.allocator, outcomes[1].mesh.?);
        defer testing.allocator.free(b.points);
        var lo: [3]f64 = @splat(std.math.inf(f64));
        var hi: [3]f64 = @splat(-std.math.inf(f64));
        for (a.points) |p| for (0..3) |k| {
            lo[k] = @min(lo[k], p[k]);
            hi[k] = @max(hi[k], p[k]);
        };
        var diagonal: f64 = 0;
        for (0..3) |k| diagonal += (hi[k] - lo[k]) * (hi[k] - lo[k]);
        diagonal = @sqrt(diagonal);
        var area: f64 = 0;
        for (a.triangles) |t| area += triangleArea(a.points[t[0]], a.points[t[1]], a.points[t[2]]);
        const c = try mesh_compare.compare(testing.allocator, .{ .points = a.points, .triangles = a.triangles }, .{ .points = b.points, .triangles = b.triangles }, .{ .spacing = diagonal / SAMPLES_ACROSS });
        errdefer std.debug.print("distance {d} (bound {d}), only one {d} (bound {d})\n", .{ c.distance(), diagonal * chord, c.only_one, 2 * diagonal * chord * area });
        try testing.expect(c.distance() <= diagonal * chord);
        try testing.expect(c.only_one <= 2 * diagonal * chord * area);
        compared += 1;
    }
    try testing.expect(compared >= 30);
}

/// Samples along a mesh's box's diagonal, at the most, in the comparison.
const SAMPLES_ACROSS = 50;

fn triangleArea(a: [3]f64, b: [3]f64, c: [3]f64) f64 {
    const u: [3]f64 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v: [3]f64 = .{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    const n: [3]f64 = .{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
    return @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]) / 2;
}
