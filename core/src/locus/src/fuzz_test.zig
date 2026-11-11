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
const sweep = @import("construct/sweep.zig");
const solid_query = struct {
    const FaceIndex = @import("query/index.zig").FaceIndex;
    const raycast = @import("query/raycast.zig");
    const point_in_body = @import("query/point_in_body.zig");
};
const edges = @import("mesh/edges.zig");
const chords = @import("mesh/chords.zig");
const curves = @import("geometry/curves.zig");
const Vec2 = vec.Vec2;
const Diagnostics = diagnostics.Diagnostics;

const tol = tolerance.Tolerance.fromZone(1e-5);
/// Bytes the JSON reader is given at most: the seeds are a few kilobytes.
const MAX_JSON_BYTES = 64 * 1024;
/// The grid the rings' points lie on: integers in [0, GRID], so points coincide often.
const GRID: i32 = 6;
/// One ring edge in this many is an arc, bulging a share of its half-chord to either side
/// (so arcs are tangent to, cross and nest in one another and the lines often).
const ARC_ONE_IN = 4;
const BULGES = [_]f64{ -1, -0.5, 0.5, 1 };
const MAX_RINGS = 3;
const MIN_POINTS = 3;
const MAX_POINTS = 8;
const MAX_OPS = 4;
/// Rays of each kind (vertical, horizontal) cast at every extruded fuzz solid.
const QUERY_RAYS = 4;
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
const PLAIN_RUN_SEED = 0x2d_c4a1;
/// How many of the plain run's chains must reach their checks: the invariants are tested
/// on the chains that run, so a share of refusals above this would test less than the
/// run count says (the thesis's strict model, research/li-chen-egc.md §4). The run drew
/// its chains from a Smith over random bytes until 2026-11-11, which takes each value as
/// a little-endian u64 and falls back to the range's least when it is out of it, as
/// random bytes always are: every ring was all zeros and no chain ever reached a check.
const PLAIN_RUN_CHECKED_AT_LEAST = PLAIN_RUN_CHAINS / 2;

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
test "fuzz: a free-form edge's chords are certified or refused" {
    try testing.fuzz({}, freeFormChords, .{});
}

/// Evaluations per span when a chord's certificate is checked against the curve.
const DENSE_CHECK = 32;
/// Rounding slack on the bow budget, relative to the chord.
const BOW_SLACK = 1e-9;

/// An ellipse or a NURBS curve the Smith shapes (sizes across the decades, a range,
/// degree and control points with weights, a resolution), cut by `chords.sampleParams`:
/// a clean refusal (a cusp, a loop the budget cannot hold), or spans each of which the
/// curve, evaluated densely, keeps within the budget the enclosure certified.
fn freeFormChords(_: void, smith: *Smith) anyerror!void {
    const resolution: tolerance.Resolution = if (smith.valueRangeAtMost(u8, 0, 1) == 0) .{} else .{ .segments = smith.valueRangeAtMost(u32, 3, 360) };
    var points: [10]vec.Vec4 = undefined;
    var knots: [24]f64 = undefined;
    var curve: curves.Curve = undefined;
    var t0: f64 = undefined;
    var t1: f64 = undefined;
    if (smith.valueRangeAtMost(u8, 0, 1) == 0) {
        const x = vec.normalized(.{ decade(smith), decade(smith), decade(smith) }) orelse vec.X3;
        curve = .{ .ellipse = .{ .c = .{ decade(smith), decade(smith), decade(smith) }, .x = x, .y = vec.perpendicular(x), .a = @abs(decade(smith)), .b = @abs(decade(smith)) } };
        if (!(curve.ellipse.a > 0 and curve.ellipse.b > 0)) return;
        t0 = @as(f64, @floatFromInt(smith.valueRangeAtMost(i32, -720, 720))) * std.math.pi / 360.0;
        t1 = t0 + @as(f64, @floatFromInt(smith.valueRangeAtMost(u32, 1, 1440))) * std.math.pi / 360.0;
    } else {
        const degree: u8 = smith.valueRangeAtMost(u8, 1, 5);
        const count: usize = degree + 1 + smith.valueRangeAtMost(u8, 0, 4);
        for (points[0..count]) |*q| q.* = .{ decade(smith), decade(smith), decade(smith), @abs(decade(smith)) };
        for (points[0..count]) |q| if (!(q[3] > 0)) return;
        const m = count + degree + 1;
        for (0..m) |i| knots[i] = if (i <= degree) 0 else if (i >= count) 1 else @as(f64, @floatFromInt(i - degree)) / @as(f64, @floatFromInt(count - degree));
        curve = .{ .nurbs = .{ .degree = degree, .knots = knots[0..m], .points = points[0..count] } };
        if (!curve.nurbs.isValid()) return;
        t0 = @as(f64, @floatFromInt(smith.valueRangeAtMost(u32, 0, 99))) / 100.0;
        t1 = t0 + @as(f64, @floatFromInt(smith.valueRangeAtMost(u32, 1, 100))) / 100.0;
        if (t1 > 1) t1 = 1;
        if (!(t1 > t0)) return;
    }
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var out: std.ArrayList(f64) = .empty;
    defer out.deinit(testing.allocator);
    chords.sampleParams(testing.allocator, curve, t0, t1, resolution, &out, &diag, .none) catch |err| {
        if (err == error.OutOfMemory) return err;
        try testing.expectEqual(error.LimitExceeded, err);
        return;
    };
    var a = t0;
    for (0..out.items.len + 1) |k| {
        const b = if (k < out.items.len) out.items[k] else t1;
        try testing.expect(b > a);
        const pa = curve.eval(a);
        const pb = curve.eval(b);
        const chord = vec.sub(pb, pa);
        const length = vec.length(chord);
        if (!(length > 0)) return error.ZeroChord;
        const dir = vec.scale(chord, 1.0 / length);
        const budget = resolution.chordBow(length) + BOW_SLACK * length;
        for (0..DENSE_CHECK + 1) |i| {
            const t = a + (b - a) * @as(f64, @floatFromInt(i)) / DENSE_CHECK;
            const d = vec.sub(curve.eval(t), pa);
            const along = vec.dot(d, dir);
            const across = vec.length(vec.sub(d, vec.scale(dir, along)));
            try testing.expect(across <= budget);
            try testing.expect(along >= -budget and along <= length + budget);
        }
        a = b;
    }
}

/// A number the Smith picks across the decades 1e-3 to 1e3, either sign.
fn decade(smith: *Smith) f64 {
    const mantissa = @as(f64, @floatFromInt(smith.valueRangeAtMost(u32, 0, 999))) / 100.0;
    const exponent = smith.valueRangeAtMost(i32, -3, 3);
    const sign: f64 = if (smith.valueRangeAtMost(u8, 0, 1) == 0) 1 else -1;
    return sign * mantissa * std.math.pow(f64, 10, @floatFromInt(exponent));
}

test "fuzz: the 2D kernel takes any generated sketch chain" {
    try testing.fuzz({}, sketchChain, .{});
}

fn sketchChain(_: void, smith: *Smith) anyerror!void {
    _ = try runChain(smith);
}

test "Fuzz chains: generated sketch chains run clean on a plain test run, most of them checked" {
    var prng = std.Random.DefaultPrng.init(PLAIN_RUN_SEED);
    var source = RandomSource{ .random = prng.random() };
    var checked: usize = 0;
    for (0..PLAIN_RUN_CHAINS) |_| checked += @intFromBool(try runChain(&source) == .checked);
    try testing.expect(checked >= PLAIN_RUN_CHECKED_AT_LEAST);
}

/// The Smith's two draws the chains use, from a random generator: what the plain run
/// drives the chains with (the fuzzer drives them with its Smith).
const RandomSource = struct {
    random: std.Random,

    fn valueRangeAtMost(self: *RandomSource, comptime T: type, at_least: T, at_most: T) T {
        return self.random.intRangeAtMost(T, at_least, at_most);
    }

    fn index(self: *RandomSource, len: usize) usize {
        return self.random.uintLessThan(usize, len);
    }
};

/// What a chain did, for the report of a failure.
const Log = struct {
    text: std.ArrayList(u8) = .empty,

    fn add(self: *Log, comptime fmt: []const u8, args: anytype) !void {
        try self.text.print(testing.allocator, fmt, args);
    }
};

const Op = enum { boolean, offset, hull, extrude, queries };

fn runChain(smith: anytype) !Outcome {
    var log: Log = .{};
    defer log.text.deinit(testing.allocator);
    errdefer std.debug.print("the chain that failed:\n{s}", .{log.text.items});
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var current = (try sheet(smith, &log, &diag)) orelse return .refused;
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
            .extrude => {
                const height: f64 = @floatFromInt(smith.valueRangeAtMost(u8, 1, GRID));
                try log.add("  extrude {d}\n", .{height});
                try expectSolidMesh(&current, height, &diag);
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
    return .checked;
}

/// One value of an enum, the Smith's choice.
fn pick(comptime T: type, smith: anytype) T {
    const values = std.enums.values(T);
    return values[smith.index(values.len)];
}

/// A clean error: the operation refused, saying what; never a crash. Out of memory is
/// the test harness's own.
fn clean(err: anyerror) anyerror!Outcome {
    if (err == error.OutOfMemory) return err;
    return .refused;
}

/// What a chain did: ran to its checks, or was refused somewhere on the way (a clean
/// error, which is no failure but checks nothing further).
const Outcome = enum { checked, refused };

/// A sheet from rings of grid points, some of their edges arcs, by the even-odd rule, or
/// null when the rings make no region (a clean refusal). The rings are logged, an arc as
/// its bulge after the point it leaves (`~0.5` or `~-1`, clockwise with a trailing `c`).
fn sheet(smith: anytype, log: *Log, diag: *Diagnostics) !?Body {
    const ring_count = smith.valueRangeAtMost(u8, 1, MAX_RINGS);
    var points: [MAX_POINTS]Vec2 = undefined;
    var ring_edges: [MAX_RINGS * MAX_POINTS]primitives.OutlineEdge = undefined;
    var rings: [MAX_RINGS][]const primitives.OutlineEdge = undefined;
    var used: usize = 0;
    try log.add("sheet of {d} rings:", .{ring_count});
    for (0..ring_count) |r| {
        const n = smith.valueRangeAtMost(u8, MIN_POINTS, MAX_POINTS);
        for (0..n) |k| {
            points[k] = .{ @floatFromInt(smith.valueRangeAtMost(i32, 0, GRID)), @floatFromInt(smith.valueRangeAtMost(i32, 0, GRID)) };
        }
        for (0..n) |k| {
            const a = points[k];
            const b = points[(k + 1) % n];
            var edge: primitives.OutlineEdge = .{ .a = a, .b = b };
            try log.add(" ({d}, {d})", .{ a[0], a[1] });
            if (smith.valueRangeAtMost(u8, 1, ARC_ONE_IN) == 1 and (a[0] != b[0] or a[1] != b[1])) {
                // The circle through both ends whose centre is a share of the half-chord
                // off the chord's middle, to the left when the bulge is positive
                const bulge = BULGES[smith.index(BULGES.len)];
                const ccw = smith.valueRangeAtMost(u8, 0, 1) == 1;
                const half = vec.scale2(vec.sub2(b, a), 0.5);
                const c = vec.add2(vec.add2(a, half), vec.scale2(vec.perp2(half), bulge));
                edge.arc = .{ .c = c, .r = vec.distance2(a, c), .ccw = ccw };
                try log.add("~{d}{s}", .{ bulge, if (ccw) "" else "c" });
            }
            ring_edges[used + k] = edge;
        }
        rings[r] = ring_edges[used .. used + n];
        used += n;
        try log.add(";", .{});
    }
    try log.add("\n", .{});
    return primitives.outlines(testing.allocator, tol, rings[0..ring_count], diag) catch |err| {
        _ = try clean(err);
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

/// The sheet extruded by `height` is a solid whose mesh is closed (every directed edge
/// once each way), has no degenerate triangle, every face meshed, and whose volume is the
/// exact one within the chords' share (the sides' quads run between the caps' chords); a
/// refusal of the extrusion is clean.
fn expectSolidMesh(sheet_body: *const Body, height: f64, diag: *Diagnostics) !void {
    var solid = sweep.extrude(testing.allocator, sheet_body, .{ 0, 0, height }, .{}, diag) catch |err| {
        _ = try clean(err);
        return;
    };
    defer solid.deinit();
    var report = try check.run(testing.allocator, &solid, .global);
    defer report.deinit(testing.allocator);
    if (!report.ok()) {
        std.debug.print("the checker on the extrusion: {f}\n", .{report.first().?});
        return error.ResultNotValid;
    }
    var mesh = try tessellate.tessellate(testing.allocator, &solid, .{}, .{}, diag);
    defer mesh.deinit(testing.allocator);
    errdefer {
        std.debug.print("the solid's mesh: {d} vertices, {d} triangles; faces:", .{ mesh.positions.len, mesh.triangles.len });
        for (mesh.faces) |range| std.debug.print(" {s}", .{@tagName(range.status)});
        std.debug.print("\n{f}\n", .{diag});
    }
    for (mesh.faces) |range| try testing.expectEqual(tessellate.Status.ok, range.status);
    var directed: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    defer directed.deinit(testing.allocator);
    var volume: f64 = 0;
    for (mesh.triangles) |t| {
        try testing.expect(t[0] != t[1] and t[1] != t[2] and t[0] != t[2]);
        const a = mesh.positions[t[0]];
        const b = mesh.positions[t[1]];
        const c = mesh.positions[t[2]];
        try testing.expect(vec.lengthSq(vec.cross(vec.sub(b, a), vec.sub(c, a))) > 0);
        volume += vec.dot(a, vec.cross(b, c)) / 6;
        for (0..3) |i| {
            const entry = try directed.getOrPut(testing.allocator, .{ t[i], t[(i + 1) % 3] });
            try testing.expect(!entry.found_existing);
        }
    }
    var it = directed.keyIterator();
    while (it.next()) |edge| try testing.expect(directed.contains(.{ edge[1], edge[0] }));
    // The exact volume within the chords' share (the mesh may have refined an arc's
    // chords where they would cross a neighbour, so it is held to the base grid's bound)
    // and the welded vertices' slack, as the sheet's area is (expectSound)
    const exact = (try mass.mass(&solid, .{}, diag)).volume;
    const bound = (try chordBound(sheet_body, diag) + try weldingSlack(sheet_body, diag) + AREA_CLOSE * @max(exact / height, 1)) * height;
    try testing.expectApproxEqAbs(exact, volume, bound);
    try expectQueries(&solid, height, diag);
}

/// Rays across the solid (vertical ones over a skewed grid, horizontal ones at mid
/// height), each from outside: their crossings, in order, keep the running count of
/// entries less exits at 0 or 1 and end at 0 (a manifold solid is entered before it is
/// left), and at the ray's midpoint the count is the midpoint's containment (when the
/// midpoint is off the boundary); a refusal of a classification is clean.
fn expectQueries(solid: *const Body, height: f64, diag: *Diagnostics) !void {
    var index = try solid_query.FaceIndex.build(testing.allocator, solid, diag);
    defer index.deinit(testing.allocator);
    // Over the solid's own box (a hull's or an offset's arcs reach past the grid), from
    // outside it to outside it
    const box = index.box;
    const span = box.size();
    var rays: [2 * QUERY_RAYS]struct { o: vec.Vec3, e: vec.Vec3 } = undefined;
    for (0..QUERY_RAYS) |i| {
        const k: f64 = @floatFromInt(i);
        const x = box.min[0] + (k + 0.37) / QUERY_RAYS * span[0];
        const y = box.min[1] + (k * 0.61 + 0.29) / QUERY_RAYS * span[1];
        rays[i] = .{ .o = .{ x, y, -1 }, .e = .{ x, y, height + 1 } };
        rays[QUERY_RAYS + i] = .{ .o = .{ box.min[0] - 1, y, height * 0.43 }, .e = .{ box.max[0] + 1, y + 0.17, height * 0.43 } };
    }
    for (rays) |ray| {
        const hits = solid_query.raycast.cast(testing.allocator, solid, &index, ray.o, ray.e, .{}, diag) catch |err| {
            _ = try clean(err);
            continue;
        };
        defer testing.allocator.free(hits);
        errdefer {
            std.debug.print("ray {any} → {any}:", .{ ray.o, ray.e });
            for (hits) |h| std.debug.print(" ({d}, {d})", .{ h.t, h.crossing });
            std.debug.print("\n", .{});
        }
        const mid_t = vec.distance(ray.o, ray.e) / 2;
        var count: i32 = 0;
        var at_mid: ?i32 = null;
        for (hits) |h| {
            if (at_mid == null and h.t > mid_t) at_mid = count;
            count += h.crossing;
            try testing.expect(count == 0 or count == 1);
        }
        try testing.expectEqual(@as(i32, 0), count);
        const mid = vec.lerp(ray.o, ray.e, 0.5);
        const place = solid_query.point_in_body.classify(testing.allocator, solid, &index, mid, .{}, diag) catch |err| {
            _ = try clean(err);
            continue;
        };
        if (place == .boundary) continue;
        try testing.expectEqual(@as(i32, @intFromBool(place == .inside)), at_mid orelse 0);
    }
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
        _ = try clean(err);
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
            _ = try clean(err);
            return;
        };
        areas[i] = (try mass.mass(&results[i].?, .{}, diag)).area;
    }
    const slack = try weldingSlack(p, diag) + try weldingSlack(q, diag) + IDENTITY_CLOSE * @max(ap + aq, 1);
    try testing.expectApproxEqAbs(ap + aq, areas[0] + areas[1], slack);
    try testing.expectApproxEqAbs(ap - areas[1], areas[2], slack);
}
