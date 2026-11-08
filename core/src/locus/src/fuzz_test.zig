//! Fuzzing Locus, as KupCAD's language is fuzzed (`std.testing.fuzz`, `zig build fuzz
//! -Dfuzz-target=locus --fuzz=<runs>`, nightly in CI; a plain test run replays the seeds):
//! the body JSON reader on any bytes, and the 2D kernel on generated sketches, rings of
//! points on a coarse grid (so coincident vertices, collinear overlaps and touching corners
//! come up often) put through chains of its operations. Every result is a sheet the checker
//! passes or a clean error, nothing leaks, the area identities of the booleans hold, the
//! triangulation's area is the sheet's, and no run can hang: the counts bound every loop.
//! A failing chain is printed as its rings and operations, so it can become a parity case.

const std = @import("std");
const testing = std.testing;
const Smith = testing.Smith;
const vec = @import("math/vec.zig");
const tolerance = @import("tolerance.zig");
const diagnostics = @import("diagnostics.zig");
const Body = @import("topology/body.zig").Body;
const check = @import("topology/check.zig");
const primitives = @import("construct/primitives.zig");
const body_json = @import("io/body_json.zig");
const boolean = @import("sketch/boolean.zig");
const offset = @import("sketch/offset.zig");
const query = @import("sketch/query.zig");
const hull = @import("sketch/hull.zig");
const mass = @import("measure/mass.zig");
const tessellate = @import("mesh/tessellate.zig");
const edges = @import("mesh/edges.zig");
const Vec2 = vec.Vec2;
const Diagnostics = diagnostics.Diagnostics;

const tol = tolerance.Tolerance.fromZone(1e-5);
/// Bytes the JSON reader is given at most: the seeds are a few kilobytes.
const MAX_JSON_BYTES = 64 * 1024;
/// The grid the rings' points lie on: integers in [0, GRID], so points coincide often.
const GRID: i32 = 6;
const MAX_RINGS = 3;
const MIN_POINTS = 3;
const MAX_POINTS = 8;
const MAX_OPS = 4;
/// Offsets in steps of OFFSET_STEP up to ±OFFSET_STEPS steps, or, one chain in
/// EXTREME_ONE_IN, a value a script would never write (a parameter sweep inside the
/// chains, beside sketch/parameters_test.zig's table on fixed sheets).
const OFFSET_STEP: f64 = 0.5;
const OFFSET_STEPS: i32 = 3;
const EXTREME_ONE_IN: u8 = 16;
const EXTREMES = [_]f64{ -std.math.inf(f64), std.math.inf(f64), std.math.nan(f64), std.math.floatMax(f64), std.math.floatTrueMin(f64), -1e15, -1e-15, 1e-15, 1e15, 1e-5, 2e-5 };
/// How close an identity of areas must hold, relative to the larger area.
const AREA_CLOSE = 1e-9;
/// How close the booleans' identities must hold beyond the welding: the overlay welds
/// vertices and arcs within the zone, which moves a boundary by up to the zone, so a
/// result's area may differ from its operands' own by the zone times their perimeters
/// (`weldingSlack`); this is the rounding on top.
const IDENTITY_CLOSE = 1e-9;
/// Generated chains a plain test run checks, each from a seeded stream of bytes.
const PLAIN_RUN_CHAINS = 200;
const PLAIN_RUN_BYTES = 256;

// The name is `-Dfuzz-target`'s filter in build.zig: renaming it means changing that.
test "fuzz: the body JSON reader takes any input" {
    const buf = try testing.allocator.create([MAX_JSON_BYTES]u8);
    defer testing.allocator.destroy(buf);
    var seeds = try jsonSeeds(testing.allocator);
    defer freeSeeds(testing.allocator, &seeds);
    try testing.fuzz(buf, readJson, .{ .corpus = seeds.items });
}

/// The JSON of a few bodies, as the fuzzer's seeds.
fn jsonSeeds(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var seeds: std.ArrayList([]const u8) = .empty;
    errdefer freeSeeds(allocator, &seeds);
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var box = try primitives.box(allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    try seeds.append(allocator, try body_json.dump(allocator, &box));
    var cyl = try primitives.cylinder(allocator, tol, 2, 5, true, &diag);
    defer cyl.deinit();
    try seeds.append(allocator, try body_json.dump(allocator, &cyl));
    var disc = try primitives.circle(allocator, tol, 2, &diag);
    defer disc.deinit();
    try seeds.append(allocator, try body_json.dump(allocator, &disc));
    return seeds;
}

fn freeSeeds(allocator: std.mem.Allocator, seeds: *std.ArrayList([]const u8)) void {
    for (seeds.items) |s| allocator.free(s);
    seeds.deinit(allocator);
}

fn readJson(buf: *[MAX_JSON_BYTES]u8, smith: *Smith) anyerror!void {
    const text = buf[0..smith.slice(buf)];
    var body = body_json.load(testing.allocator, text) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return, // a clean refusal of what isn't a body
    };
    defer body.deinit();
    // What loads is a body the checker can grade, never one that trips it
    var report = try check.run(testing.allocator, &body, .global);
    report.deinit(testing.allocator);
}

// The name is `-Dfuzz-target`'s filter in build.zig: renaming it means changing that.
test "fuzz: the 2D kernel takes any generated sketch chain" {
    try testing.fuzz({}, sketchChain, .{});
}

fn sketchChain(_: void, smith: *Smith) anyerror!void {
    try runChain(smith);
}

test "Fuzz chains: generated sketch chains run clean on a plain test run" {
    var bytes: [PLAIN_RUN_BYTES]u8 = undefined;
    for (0..PLAIN_RUN_CHAINS) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(&bytes);
        var smith: Smith = .{ .in = &bytes };
        try runChain(&smith);
    }
}

/// What a chain did, for the report of a failure.
const Log = struct {
    text: std.ArrayList(u8) = .empty,

    fn add(self: *Log, comptime fmt: []const u8, args: anytype) !void {
        try self.text.print(testing.allocator, fmt, args);
    }
};

const Op = enum { boolean, offset, hull, queries };

fn runChain(smith: *Smith) !void {
    var log: Log = .{};
    defer log.text.deinit(testing.allocator);
    errdefer std.debug.print("the chain that failed:\n{s}", .{log.text.items});
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var current = (try sheet(smith, &log, &diag)) orelse return;
    defer current.deinit();
    try expectSound(&current, &diag);

    const ops = smith.valueRangeAtMost(u8, 0, MAX_OPS);
    for (0..ops) |_| {
        switch (pick(Op, smith)) {
            .boolean => {
                var other = (try sheet(smith, &log, &diag)) orelse continue;
                defer other.deinit();
                const op = pick(boolean.Op, smith);
                try log.add("  {s}\n", .{@tagName(op)});
                try expectAreaIdentities(&current, &other, &diag);
                var result = boolean.boolean(testing.allocator, &.{ &current, &other }, op, .{}, &diag) catch |err| return clean(err);
                errdefer result.deinit();
                try expectSound(&result, &diag);
                current.deinit();
                current = result;
            },
            .offset => {
                const extreme = smith.valueRangeAtMost(u8, 1, EXTREME_ONE_IN) == 1;
                const delta = if (extreme) EXTREMES[smith.index(EXTREMES.len)] else @as(f64, @floatFromInt(smith.valueRangeAtMost(i32, -OFFSET_STEPS, OFFSET_STEPS))) * OFFSET_STEP;
                const join = pick(offset.Join, smith);
                const limit: f64 = if (extreme) EXTREMES[smith.index(EXTREMES.len)] else @floatFromInt(smith.valueRangeAtMost(u8, 2, 4));
                try log.add("  offset {d} {s} miter {d}\n", .{ delta, @tagName(join), limit });
                var result = offset.offset(testing.allocator, &current, delta, join, limit, .{}, &diag) catch |err| return clean(err);
                errdefer result.deinit();
                try expectSound(&result, &diag);
                // Shrunk, the sheet holds its result; grown, the result holds the sheet
                if (delta < 0) try expectWithin(&result, &current, &diag) else try expectWithin(&current, &result, &diag);
                current.deinit();
                current = result;
            },
            .hull => {
                try log.add("  hull\n", .{});
                var result = hull.hull(testing.allocator, &.{&current}, .{}, &diag) catch |err| return clean(err);
                errdefer result.deinit();
                try expectSound(&result, &diag);
                // A hull holds its own vertices and is convex
                try testing.expect(try query.isConvex(&result, &diag));
                current.deinit();
                current = result;
            },
            .queries => {
                const p: Vec2 = .{ @floatFromInt(smith.valueRangeAtMost(i32, 0, GRID)), @floatFromInt(smith.valueRangeAtMost(i32, 0, GRID)) };
                try log.add("  queries at ({d}, {d})\n", .{ p[0], p[1] });
                _ = try query.contains(&current, p, tol.zone, &diag);
                _ = try query.isConvex(&current, &diag);
                var contours = try query.contours(testing.allocator, &current, .{}, &diag);
                defer contours.deinit(testing.allocator);
                // One contour per loop; none for the empty sheet
                try testing.expectEqual(current.counts().loops, contours.count());
            },
        }
    }
}

/// One value of an enum, the Smith's choice.
fn pick(comptime T: type, smith: *Smith) T {
    const values = std.enums.values(T);
    return values[smith.index(values.len)];
}

/// A clean error: the operation refused, saying what; never a crash. Out of memory is
/// the test harness's own.
fn clean(err: anyerror) anyerror!void {
    if (err == error.OutOfMemory) return err;
}

/// A sheet from rings of grid points by the even-odd rule, or null when the rings make no
/// region (a clean refusal). The rings are logged.
fn sheet(smith: *Smith, log: *Log, diag: *Diagnostics) !?Body {
    const ring_count = smith.valueRangeAtMost(u8, 1, MAX_RINGS);
    var points: [MAX_RINGS * MAX_POINTS]Vec2 = undefined;
    var rings: [MAX_RINGS][]const Vec2 = undefined;
    var used: usize = 0;
    try log.add("sheet of {d} rings:", .{ring_count});
    for (0..ring_count) |r| {
        const n = smith.valueRangeAtMost(u8, MIN_POINTS, MAX_POINTS);
        for (0..n) |k| {
            points[used + k] = .{ @floatFromInt(smith.valueRangeAtMost(i32, 0, GRID)), @floatFromInt(smith.valueRangeAtMost(i32, 0, GRID)) };
            try log.add(" ({d}, {d})", .{ points[used + k][0], points[used + k][1] });
        }
        rings[r] = points[used .. used + n];
        used += n;
        try log.add(";", .{});
    }
    try log.add("\n", .{});
    return primitives.polygonsEvenOdd(testing.allocator, tol, rings[0..ring_count], diag) catch |err| {
        try clean(err);
        return null;
    };
}

/// The sheet passes every rule of the checker, and has an area unless it is the empty
/// sheet (a boolean's empty result).
fn expectSound(body: *const Body, diag: *Diagnostics) !void {
    var report = try check.run(testing.allocator, body, .global);
    defer report.deinit(testing.allocator);
    if (!report.ok()) {
        std.debug.print("the checker: {f}\n", .{report.first().?});
        return error.ResultNotValid;
    }
    const m = try mass.mass(body, .{}, diag);
    if (body.counts().faces == 0) {
        try testing.expectEqual(@as(f64, 0), m.area);
        return;
    }
    try testing.expect(m.area > 0);
    // Its triangulation covers its outline polygon exactly, and that polygon is within
    // the chords' sagitta areas of the exact area
    var mesh = try tessellate.tessellate(testing.allocator, body, .{}, .{}, diag);
    defer mesh.deinit(testing.allocator);
    var covered: f64 = 0;
    for (mesh.triangles) |t| {
        const a = mesh.positions[t[0]];
        const b = mesh.positions[t[1]];
        const c = mesh.positions[t[2]];
        covered += vec.cross(vec.sub(b, a), vec.sub(c, a))[2] / 2;
    }
    var outline = try query.contours(testing.allocator, body, .{}, diag);
    defer outline.deinit(testing.allocator);
    var polygon_area: f64 = 0;
    var perimeter: f64 = 0;
    for (0..outline.count()) |i| {
        const contour = outline.contour(i);
        polygon_area += primitives.signedArea(contour) / 2;
        for (contour, 0..) |p, k| perimeter += vec.distance2(p, contour[(k + 1) % contour.len]);
    }
    // The mesh may have refined an arc's chords where they would cross a neighbour, so it
    // is held to the exact area within the chords' bound, as the outline is; and a
    // vertex sits within the zone of its edges' curves (welded), which moves the outline
    // by up to the zone along the perimeter
    const bound = try chordBound(body, diag) + tol.zone * perimeter + AREA_CLOSE * @max(m.area, 1);
    errdefer {
        std.debug.print("exact {d} covered {d} outline {d} bound {d}; faces:", .{ m.area, covered, polygon_area, bound });
        for (mesh.faces) |range| std.debug.print(" {s}", .{@tagName(range.status)});
        std.debug.print("\n{f}\n", .{diag});
    }
    try testing.expect(@abs(m.area - covered) <= bound);
    try testing.expect(@abs(m.area - polygon_area) <= bound);
    for (mesh.faces) |range| try testing.expectEqual(tessellate.Status.ok, range.status);
}

/// The area the chords of the body's arcs can miss: each arc's segments times the
/// sagitta area of one segment of its circle's grid, `½ r² (θ − sin θ)`.
fn chordBound(body: *const Body, diag: *Diagnostics) !f64 {
    const resolution: tolerance.Resolution = .{};
    var edge_points = try edges.discretize(testing.allocator, body, resolution, diag);
    defer edge_points.deinit(testing.allocator);
    var bound: f64 = 0;
    for (body.edges.items, 0..) |e, i| {
        if (e.flags.tombstone) continue;
        const circle = switch (body.geometry.curve(e.curve)) {
            .circle => |c| c,
            else => continue,
        };
        const theta = 2 * std.math.pi / @as(f64, @floatFromInt(resolution.segmentsFor(circle.r)));
        const segments: f64 = @floatFromInt(edge_points.of(.of(i)).len - 1);
        bound += segments * 0.5 * circle.r * circle.r * (theta - @sin(theta));
    }
    return bound;
}

/// `inner` lies within `outer`: A(inner ∩ outer) = A(inner) (a refusal of the
/// intersection is a clean error, not a failure).
fn expectWithin(inner: *const Body, outer: *const Body, diag: *Diagnostics) !void {
    var both = boolean.boolean(testing.allocator, &.{ inner, outer }, .intersection, .{}, diag) catch |err| {
        try clean(err);
        return;
    };
    defer both.deinit();
    const a_inner = (try mass.mass(inner, .{}, diag)).area;
    const a_both = (try mass.mass(&both, .{}, diag)).area;
    try testing.expectApproxEqAbs(a_inner, a_both, try weldingSlack(inner, diag) + try weldingSlack(outer, diag) + IDENTITY_CLOSE * @max(a_inner, 1));
}

/// How much a sheet's area may move when an overlay welds its vertices and arcs: the zone
/// along its perimeter (chorded at the default resolution, a fair measure of it).
fn weldingSlack(body: *const Body, diag: *Diagnostics) !f64 {
    var outline = try query.contours(testing.allocator, body, .{}, diag);
    defer outline.deinit(testing.allocator);
    var perimeter: f64 = 0;
    for (0..outline.count()) |i| {
        const contour = outline.contour(i);
        for (contour, 0..) |p, k| perimeter += vec.distance2(p, contour[(k + 1) % contour.len]);
    }
    return tol.zone * perimeter;
}

/// A(P ∪ Q) + A(P ∩ Q) = A(P) + A(Q) and A(P − Q) = A(P) − A(P ∩ Q), where every one of the
/// four booleans has a result (a refusal of any of them is a clean error, not a failure).
fn expectAreaIdentities(p: *const Body, q: *const Body, diag: *Diagnostics) !void {
    const ap = (try mass.mass(p, .{}, diag)).area;
    const aq = (try mass.mass(q, .{}, diag)).area;
    var results: [3]?Body = .{ null, null, null };
    defer for (&results) |*r| if (r.*) |*b| b.deinit();
    const ops = [_]boolean.Op{ .@"union", .intersection, .difference };
    var areas: [3]f64 = undefined;
    for (ops, 0..) |op, i| {
        results[i] = boolean.boolean(testing.allocator, &.{ p, q }, op, .{}, diag) catch |err| {
            try clean(err);
            return;
        };
        areas[i] = (try mass.mass(&results[i].?, .{}, diag)).area;
    }
    const slack = try weldingSlack(p, diag) + try weldingSlack(q, diag) + IDENTITY_CLOSE * @max(ap + aq, 1);
    try testing.expectApproxEqAbs(ap + aq, areas[0] + areas[1], slack);
    try testing.expectApproxEqAbs(ap - areas[1], areas[2], slack);
}
