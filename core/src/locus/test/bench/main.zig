//! The benchmarks (docs/architecture.md §12): fixed inputs, timed, each against a budget
//! set from the first measurements (ReleaseFast on an Apple M-series laptop, 2026-11-06)
//! with a 20% margin; `zig build bench` fails on a regression past it. The §12 cases that
//! need booleans, tessellation and ray casts join as M3–M5 land; the constructions, the
//! hull, the BVH, STEP export, the JSON dump and compaction are timed, and since M4 the
//! degeneracy corpus's boolean cases of size.

const std = @import("std");
const locus = @import("locus");

/// How much slower than its budget a case may run before the step fails.
const MARGIN: f64 = 1.2;

const Case = struct {
    name: []const u8,
    run: *const fn (std.mem.Allocator) anyerror!void,
    /// The budget in milliseconds, from the first measurement times the margin.
    budget_ms: f64,
    /// Repetitions, so a fast case is timed over enough work.
    repeat: u32 = 1,
};

const CASES = [_]Case{
    .{ .name = "box ×1000", .run = boxCase, .budget_ms = 40, .repeat = 1 },
    .{ .name = "cylinder ×1000", .run = cylinders, .budget_ms = 30, .repeat = 1 },
    .{ .name = "hull of 10,000 points", .run = hullOfPoints, .budget_ms = 20, .repeat = 1 },
    .{ .name = "polyhedron of 2,000 faces", .run = bigPolyhedron, .budget_ms = 10, .repeat = 1 },
    .{ .name = "BVH: 10,000 boxes built and 10,000 queries", .run = bvhCase, .budget_ms = 5, .repeat = 1 },
    .{ .name = "STEP of a 2,000-face polyhedron", .run = stepCase, .budget_ms = 25, .repeat = 1 },
    .{ .name = "JSON dump and hash of a 2,000-face polyhedron", .run = jsonCase, .budget_ms = 35, .repeat = 1 },
    .{ .name = "compact of 1,000,000 entities", .run = compactCase, .budget_ms = 10, .repeat = 1 },
    // The degeneracy corpus's two timed classes (research/solidcraft.md §1, tier 02: truck
    // grew 4–9× per doubling of pegs), measured 2026-11-13: the prisms 390 ms (1300 before
    // in_face's crossing count for planar faces), the pegs 480 ms, a chain of 64 steps each
    // rebuilding the whole (General Fuse, D17, is the planned route for such batches)
    .{ .name = "union of two 1000-sided prisms", .run = prismsCase, .budget_ms = 400, .repeat = 1 },
    .{ .name = "64 pegs joined to a plate", .run = pegsCase, .budget_ms = 500, .repeat = 1 },
};

const tol = locus.Tolerance.fromZone(1e-5);

fn boxCase(allocator: std.mem.Allocator) !void {
    var diag = locus.Diagnostics.init(allocator);
    defer diag.deinit();
    for (0..1000) |i| {
        var b = try locus.construct.primitives.box(allocator, tol, 1 + @as(f64, @floatFromInt(i % 7)), 2, 3, true, &diag);
        b.deinit();
    }
}

fn cylinders(allocator: std.mem.Allocator) !void {
    var diag = locus.Diagnostics.init(allocator);
    defer diag.deinit();
    for (0..1000) |i| {
        var b = try locus.construct.primitives.cylinder(allocator, tol, 1 + @as(f64, @floatFromInt(i % 7)), 5, false, &diag);
        b.deinit();
    }
}

fn spherePoints(allocator: std.mem.Allocator, n: usize) ![]locus.math.vec.Vec3 {
    const pts = try allocator.alloc(locus.math.vec.Vec3, n);
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (pts) |*p| {
        const u = random.float(f64) * 2 * std.math.pi;
        const v = random.float(f64) * 2 - 1;
        const r = 10 * (0.5 + 0.5 * random.float(f64));
        p.* = .{ r * @sqrt(1 - v * v) * @cos(u), r * @sqrt(1 - v * v) * @sin(u), r * v };
    }
    return pts;
}

fn hullOfPoints(allocator: std.mem.Allocator) !void {
    const pts = try spherePoints(allocator, 10_000);
    defer allocator.free(pts);
    var diag = locus.Diagnostics.init(allocator);
    defer diag.deinit();
    var b = try locus.construct.hull.hull(allocator, tol, pts, &diag);
    b.deinit();
}

/// A closed triangulated sphere of about `faces` triangles, by latitude bands.
fn polyhedronOf(allocator: std.mem.Allocator, bands: usize) !locus.Body {
    const around = bands * 2;
    var pts = std.ArrayList([3]f64).empty;
    defer pts.deinit(allocator);
    var tris = std.ArrayList([3]u32).empty;
    defer tris.deinit(allocator);
    try pts.append(allocator, .{ 0, 0, 10 });
    for (1..bands) |i| {
        const phi = std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(bands));
        for (0..around) |j| {
            const theta = 2 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(around));
            try pts.append(allocator, .{ 10 * @sin(phi) * @cos(theta), 10 * @sin(phi) * @sin(theta), 10 * @cos(phi) });
        }
    }
    try pts.append(allocator, .{ 0, 0, -10 });
    const last: u32 = @intCast(pts.items.len - 1);
    const ring = struct {
        fn at(band: usize, j: usize, n: usize) u32 {
            return @intCast(1 + (band - 1) * n + (j % n));
        }
    }.at;
    for (0..around) |j| try tris.append(allocator, .{ 0, ring(1, j, around), ring(1, j + 1, around) });
    for (1..bands - 1) |i| {
        for (0..around) |j| {
            try tris.append(allocator, .{ ring(i, j, around), ring(i + 1, j, around), ring(i + 1, j + 1, around) });
            try tris.append(allocator, .{ ring(i, j, around), ring(i + 1, j + 1, around), ring(i, j + 1, around) });
        }
    }
    for (0..around) |j| try tris.append(allocator, .{ last, ring(bands - 1, j + 1, around), ring(bands - 1, j, around) });
    var diag = locus.Diagnostics.init(allocator);
    defer diag.deinit();
    return locus.construct.primitives.polyhedron(allocator, tol, pts.items, tris.items, &diag);
}

fn bigPolyhedron(allocator: std.mem.Allocator) !void {
    var b = try polyhedronOf(allocator, 32);
    b.deinit();
}

fn bvhCase(allocator: std.mem.Allocator) !void {
    const n = 10_000;
    const boxes = try allocator.alloc(locus.geometry.types.Box3, n);
    defer allocator.free(boxes);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (boxes) |*b| {
        const c = [3]f64{ random.float(f64) * 100, random.float(f64) * 100, random.float(f64) * 100 };
        b.* = .{ .min = .{ c[0] - 1, c[1] - 1, c[2] - 1 }, .max = .{ c[0] + 1, c[1] + 1, c[2] + 1 } };
    }
    var tree = try locus.spatial.bvh.Bvh.build(allocator, boxes);
    defer tree.deinit(allocator);
    const Count = struct {
        n: usize = 0,
        fn visit(self: *@This(), _: u32) bool {
            self.n += 1;
            return true;
        }
    };
    var count = Count{};
    for (boxes) |b| tree.query(b, &count, Count.visit);
    std.mem.doNotOptimizeAway(count.n);
}

fn stepCase(allocator: std.mem.Allocator) !void {
    var b = try polyhedronOf(allocator, 32);
    defer b.deinit();
    const text = try locus.io.step_write.write(allocator, &.{&b});
    allocator.free(text);
}

fn jsonCase(allocator: std.mem.Allocator) !void {
    var b = try polyhedronOf(allocator, 32);
    defer b.deinit();
    const text = try locus.io.body_json.dump(allocator, &b);
    allocator.free(text);
    std.mem.doNotOptimizeAway(try locus.io.body_json.hash(allocator, &b));
}

fn compactCase(allocator: std.mem.Allocator) !void {
    // A body of a million vertices, half tombstoned, compacted
    var b = locus.Body.init(allocator, tol);
    defer b.deinit();
    const p = try b.geometry.addPoint(allocator, .{ 0, 0, 0 });
    for (0..1_000_000) |i| _ = try b.addVertex(.{ .point = p, .tombstone = i % 2 == 0 });
    var remap = try b.compact();
    remap.deinit(allocator);
}

/// A regular prism of `n` sides of circumradius `r` about `(cx, 0)`, 5 high.
fn prism(allocator: std.mem.Allocator, n: usize, r: f64, cx: f64) !locus.Body {
    var diag = locus.Diagnostics.init(allocator);
    defer diag.deinit();
    const points = try allocator.alloc(locus.math.vec.Vec2, n);
    defer allocator.free(points);
    for (points, 0..) |*p, k| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        p.* = .{ cx + r * @cos(t), r * @sin(t) };
    }
    var sheet = try locus.construct.primitives.polygon(allocator, tol, points, &diag);
    defer sheet.deinit();
    return locus.construct.sweep.extrude(allocator, &sheet, .{ 0, 0, 5 }, .{}, &diag);
}

fn prismsCase(allocator: std.mem.Allocator) !void {
    var p = try prism(allocator, 1000, 10, 0);
    defer p.deinit();
    var q = try prism(allocator, 1000, 10, 5);
    defer q.deinit();
    var diag = locus.Diagnostics.init(allocator);
    defer diag.deinit();
    var u = try locus.boolean.pipeline.boolean(allocator, &p, &q, .@"union", .{}, &diag, null);
    u.deinit();
}

fn pegsCase(allocator: std.mem.Allocator) !void {
    var diag = locus.Diagnostics.init(allocator);
    defer diag.deinit();
    const P = locus.construct.primitives;
    const T = locus.construct.transform;
    var plate = try P.box(allocator, tol, 16, 16, 1, false, &diag);
    defer plate.deinit();
    var pegs: [64]locus.Body = undefined;
    var made: usize = 0;
    defer for (pegs[0..made]) |*g| g.deinit();
    var operands: [65]*const locus.Body = undefined;
    operands[0] = &plate;
    for (0..8) |i| for (0..8) |j| {
        var unit = try P.box(allocator, tol, 1, 1, 2, false, &diag);
        defer unit.deinit();
        const at: locus.math.vec.Vec3 = .{ @as(f64, @floatFromInt(2 * i)) + 0.5, @as(f64, @floatFromInt(2 * j)) + 0.5, 1 };
        pegs[made] = try T.transform(allocator, &unit, &locus.math.mat.Affine.translate(at), .{}, &diag);
        operands[made + 1] = &pegs[made];
        made += 1;
    };
    var studded = try locus.boolean.pipeline.chain(allocator, &operands, .@"union", .{}, &diag, null);
    studded.deinit();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var failed = false;
    for (CASES) |case| {
        const started = std.Io.Timestamp.now(io, .awake);
        for (0..case.repeat) |_| try case.run(allocator);
        const ms = @as(f64, @floatFromInt(started.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / 1e6;
        const over = ms > case.budget_ms * MARGIN;
        std.debug.print("{s:<48} {d:>9.2} ms  budget {d:>7.1} ms{s}\n", .{ case.name, ms, case.budget_ms, if (over) "  REGRESSION" else "" });
        failed = failed or over;
    }
    if (failed) return error.BenchmarkRegression;
}
