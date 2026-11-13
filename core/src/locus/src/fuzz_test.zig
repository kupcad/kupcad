//! Fuzzing Locus, as KupCAD's language is fuzzed (`std.testing.fuzz`, `zig build fuzz
//! -Dfuzz-target=locus --fuzz=<runs>`, nightly in CI; a plain test run replays the seeds):
//! the body JSON reader on any bytes, and the 2D kernel on generated sketches, rings of
//! points on a coarse grid (so coincident vertices, collinear overlaps and touching corners
//! come up often) put through chains of its operations. Every result is a sheet the checker
//! passes or a clean error, nothing leaks, the area identities of the booleans hold, the
//! triangulation's area is the sheet's, and no run can hang: the counts bound every loop.
//! A failing chain is printed as its rings and operations, so it can become a parity case.
//! And booleans of solids (M4, `-Dfuzz-target=locus_solids`): boxes and hulls of grid
//! points, placed by turns, scales and half-steps (an extreme one time in sixteen), put
//! through chains of booleans and cuts by planes; every result through the checker, the
//! overlap rules and its report, the volume identities holding. A fuzz worker writes each
//! run's draws down as it draws them and runs a watchdog: a run that panics or passes its
//! wall-clock bound (`RUN_BUDGET_S`) leaves its `replay:` line for `zig build fuzz-run`.

const std = @import("std");
const builtin = @import("builtin");
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
const overlay_mod = @import("sketch/overlay.zig");
const predicates = @import("math/predicates.zig");
const trig = @import("math/trig.zig");
const test_bodies = @import("construct/test_bodies.zig");
const overlap = @import("sketch/overlap.zig");
const solid_overlap = @import("query/overlap.zig");
const mass = @import("measure/mass.zig");
const tessellate = @import("mesh/tessellate.zig");
const validate = @import("mesh/validate.zig");
const condition = @import("topology/condition.zig");
const sweep = @import("construct/sweep.zig");
const transform = @import("construct/transform.zig");
const section = @import("boolean/section.zig");
const Affine = @import("math/mat.zig").Affine;
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
/// Where between its ends a fuzz solid is sliced off the grid, and how many points of the
/// turned solid's section are checked against the solid.
const SLICE_AT = 0.37;
const SLICE_POINTS = 16;
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
/// The directory a fuzz worker writes each run's draws in (`DrawLog`), from the build's
/// `-Dfuzz-draws`; empty, none are written.
const FUZZ_DRAWS_DIR: []const u8 = @import("test_paths").fuzz_draws;
/// A draws file's name, before its kind and `.txt` (core's scripts/fuzz_run.zig reads
/// `draws-*.txt` after a crash).
const DRAWS_FILE_PREFIX = "draws-";
/// The wall-clock bound on one fuzz run (M4's fuzz harness): a run past it is a hang, its
/// worker stopped with the run's draws written down. Runs take milliseconds (an
/// arrangement) to a few seconds (a chain of booleans of solids, Debug, a slow runner):
/// a run forty times the slowest seen does not end.
const RUN_BUDGET_S: u32 = 120;
/// How often the watchdog looks at the run under way.
const WATCHDOG_PERIOD_MS: i64 = 500;
/// Generated chains a plain test run checks, each from a seeded stream of bytes.
const PLAIN_RUN_CHAINS = 200;
const PLAIN_RUN_SEED = 0x2d_c4a1;
/// Curves the chord target's plain run checks.
const PLAIN_RUN_CURVES = 2000;
/// How many of the plain run's chains must reach their checks: the invariants are tested
/// on the chains that run, so a share of refusals above this would test less than the
/// run count says (the thesis's strict model, research/li-chen-egc.md §4). The run drew
/// its chains from a Smith over random bytes until 2026-11-11, which takes each value as
/// a little-endian u64 and falls back to the range's least when it is out of it, as
/// random bytes always are: every ring was all zeros and no chain ever reached a check.
const PLAIN_RUN_CHECKED_AT_LEAST = PLAIN_RUN_CHAINS / 2;
/// Arrangements the overlay target's plain run checks.
const PLAIN_RUN_ARRANGEMENTS = 300;
/// The overlay target's arrangements: up to this many inputs of up to this many rings,
/// points on a grid of `FINE_SCALE` steps a unit over [0, FINE_GRID / FINE_SCALE], circles
/// of these radii about its points, one point in `NUDGE_ONE_IN` a rounding off it.
const MAX_INPUTS = 3;
const MAX_INPUT_RINGS = 2;
const FINE_GRID: i32 = 24;
const FINE_SCALE: f64 = 4;
const RADII = [_]f64{ 0.25, 0.5, 1, 1.5, 2, 3 };
const NUDGE_ONE_IN: u8 = 8;
/// Where the label check probes a face: this share of its outer cycle's longest piece in
/// from the piece's middle, and never nearer it than this many zones (a piece shorter is
/// not probed).
const LABEL_PROBE_SHARE = 1e-3;
const LABEL_PROBE_MIN = 50;
/// How many zones a probe must keep from every edge of its face.
const LABEL_PROBE_CLEAR = 10;
/// How closely each input's winding over the faces holds to its own area beyond the
/// welding (the zone along its perimeter, twice: its own ends moved, and an arc piece
/// within the zone of its chord taken as the chord).
const WINDING_CLOSE = 1e-9;

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
    var recording: Recording(*Smith) = .init(smith, .chords, try fuzzRun(.chords));
    defer recording.deinit();
    errdefer recording.report("chords");
    try checkFreeFormChords(&recording);
}

fn checkFreeFormChords(smith: anytype) anyerror!void {
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
fn decade(smith: anytype) f64 {
    const mantissa = @as(f64, @floatFromInt(smith.valueRangeAtMost(u32, 0, 999))) / 100.0;
    const exponent = smith.valueRangeAtMost(i32, -3, 3);
    const sign: f64 = if (smith.valueRangeAtMost(u8, 0, 1) == 0) 1 else -1;
    return sign * mantissa * std.math.pow(f64, 10, @floatFromInt(exponent));
}

test "fuzz: the 2D kernel takes any generated sketch chain" {
    try testing.fuzz({}, sketchChain, .{});
}

fn sketchChain(_: void, smith: *Smith) anyerror!void {
    var recording: Recording(*Smith) = .init(smith, .chain, try fuzzRun(.chain));
    defer recording.deinit();
    errdefer recording.report("chain");
    _ = try runChain(&recording);
}

test "Fuzz chains: generated sketch chains run clean on a plain test run, most of them checked" {
    var prng = std.Random.DefaultPrng.init(PLAIN_RUN_SEED);
    var source = RandomSource{ .random = prng.random() };
    var checked: usize = 0;
    for (0..PLAIN_RUN_CHAINS) |_| {
        var recording: Recording(*RandomSource) = .{ .inner = &source };
        defer recording.deinit();
        errdefer recording.report("chain");
        checked += @intFromBool(try runChain(&recording) == .checked);
    }
    try testing.expect(checked >= PLAIN_RUN_CHECKED_AT_LEAST);
}

/// A source of draws (the fuzzer's Smith, or `RandomSource`) that keeps every value it
/// gives, so a failing run prints them as a `replay:` line: the run's every choice, which
/// `ScriptedSource` plays back exactly. Zig 0.17 saves the fuzzer's failing input as bytes
/// that do not replay through the Smith on a plain run; this line does, from a CI log.
/// With a `log`, each draw is also written down as it is drawn, so a run that panics
/// (no `errdefer` runs then) leaves its line in the log's file.
fn Recording(comptime Inner: type) type {
    return struct {
        inner: Inner,
        draws: std.ArrayList(i64) = .empty,
        log: ?*DrawLog = null,
        watched: bool = false,

        const Self = @This();

        /// A recording of `inner`'s draws for a run of `kind`, written down as they are
        /// drawn into `run.log`'s file when there is one (it starts the run's line), and
        /// timed by the watchdog when `run.watched`.
        fn init(inner: Inner, kind: ReplayKind, run: FuzzRun) Self {
            if (run.log) |l| l.start(kind);
            if (run.watched) fuzz_watch.begin();
            return .{ .inner = inner, .log = run.log, .watched = run.watched };
        }

        fn valueRangeAtMost(self: *Self, comptime T: type, at_least: T, at_most: T) T {
            const v = self.inner.valueRangeAtMost(T, at_least, at_most);
            self.keep(@intCast(v));
            return v;
        }

        fn index(self: *Self, len: usize) usize {
            const i = self.inner.index(len);
            self.keep(@intCast(i));
            return i;
        }

        fn keep(self: *Self, v: i64) void {
            self.draws.append(testing.allocator, v) catch @panic("out of memory keeping a fuzz run's draws");
            if (self.log) |l| l.add(v);
        }

        /// The run is over, whether it passed or returned an error (whose line `report`
        /// printed): its log's file is cleared, and only a run that panicked leaves one.
        fn deinit(self: *Self) void {
            if (self.watched) fuzz_watch.end();
            if (self.log) |l| l.clear();
            self.draws.deinit(testing.allocator);
        }

        /// Prints the run's draws as one `replay:` line of `kind` (a line of a file given
        /// to `zig build test -Dfuzz-replay=FILE` in core/src/locus).
        fn report(self: *const Self, kind: []const u8) void {
            std.debug.print("replay: {s}", .{kind});
            for (self.draws.items) |v| std.debug.print(" {d}", .{v});
            std.debug.print("\n", .{});
        }
    };
}

/// The draws of a `replay:` line, given back in order, each clamped to the range asked
/// (a line edited by hand stays a valid run); past its end, each range's least, as the
/// Smith gives when its bytes run out.
const ScriptedSource = struct {
    draws: []const i64,
    at: usize = 0,

    fn next(self: *ScriptedSource) ?i64 {
        if (self.at >= self.draws.len) return null;
        defer self.at += 1;
        return self.draws[self.at];
    }

    fn valueRangeAtMost(self: *ScriptedSource, comptime T: type, at_least: T, at_most: T) T {
        const v = self.next() orelse return at_least;
        return @intCast(std.math.clamp(v, @as(i64, at_least), @as(i64, at_most)));
    }

    fn index(self: *ScriptedSource, len: usize) usize {
        const v = self.next() orelse return 0;
        return @intCast(std.math.clamp(v, 0, @as(i64, @intCast(len)) - 1));
    }
};

/// A file a fuzz worker writes a run's `replay:` line into as the run draws, one write per
/// draw (a panic can come in any call between two draws, and ends the worker before any
/// buffer or `errdefer` is flushed), cleared when the run ends; `draws-<kind>.txt` in its
/// directory. Zig 0.17 lets a test install no panic handler, so this is how the line of a
/// run that panicked outlives it: `zig build fuzz-run` prints the files it finds not empty.
const DrawLog = struct {
    io: std.Io,
    file: std.Io.File,
    /// Where the next draw goes: the length of the line so far.
    at: u64 = 0,

    fn open(io: std.Io, dir: std.Io.Dir, kind: ReplayKind) !DrawLog {
        var name: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, DRAWS_FILE_PREFIX ++ "{t}.txt", .{kind});
        return .{ .io = io, .file = try dir.createFile(io, path, .{ .truncate = true }) };
    }

    fn close(self: *DrawLog) void {
        self.file.close(self.io);
    }

    /// A new run's line, `replay: <kind>`, the last run's gone.
    fn start(self: *DrawLog, kind: ReplayKind) void {
        self.clear();
        var buf: [32]u8 = undefined;
        self.write(std.fmt.bufPrint(&buf, "replay: {t}", .{kind}) catch unreachable);
    }

    fn add(self: *DrawLog, v: i64) void {
        var buf: [24]u8 = undefined;
        self.write(std.fmt.bufPrint(&buf, " {d}", .{v}) catch unreachable);
    }

    fn clear(self: *DrawLog) void {
        self.file.setLength(self.io, 0) catch |err| std.debug.panic("clearing the fuzz draws file: {t}", .{err});
        self.at = 0;
    }

    fn write(self: *DrawLog, bytes: []const u8) void {
        self.file.writePositionalAll(self.io, bytes, self.at) catch |err| std.debug.panic("writing the fuzz draws file: {t}", .{err});
        self.at += bytes.len;
    }
};

/// What a fuzz worker gives each run: its target's draws file, and the watchdog's bound.
const FuzzRun = struct {
    log: ?*DrawLog = null,
    watched: bool = false,
};

/// A fuzz target's run as the worker keeps it: its draws file (opened the first time the
/// worker runs one) and the watchdog (started then). Nothing on a plain run.
fn fuzzRun(kind: ReplayKind) !FuzzRun {
    if (comptime !builtin.fuzz) return .{};
    try fuzz_watch.start();
    return .{ .log = try fuzzDrawLog(kind), .watched = true };
}

/// The wall-clock bound on a run, as a clock-free rule: the start of the run under way,
/// and whether a time is past its budget. One writer (the run) and one reader (the
/// watchdog's thread).
const Watchdog = struct {
    /// The start of the run under way, in milliseconds since the watchdog's own start (a
    /// `u32`, which every target's atomics take: 49 days, longer than any session), or
    /// `IDLE` between runs.
    started: std.atomic.Value(u32) = .init(IDLE),

    const IDLE: u32 = std.math.maxInt(u32);

    fn begin(self: *Watchdog, now: u32) void {
        self.started.store(now, .release);
    }

    fn end(self: *Watchdog) void {
        self.started.store(IDLE, .release);
    }

    /// Whether the run under way at `now` began more than `budget` before it.
    fn expired(self: *const Watchdog, now: u32, budget: u32) bool {
        const at = self.started.load(.acquire);
        return at != IDLE and now -| at > budget;
    }
};

/// The fuzz worker's watchdog: a thread of its own, on an `Io` of its own (the test
/// runner's is made afresh for every run), which looks at the run under way every
/// `WATCHDOG_PERIOD_MS` and, past `RUN_BUDGET_S`, stops the worker with a panic: the run's
/// draws are in its draws file, which `zig build fuzz-run` prints (a hang is a find, as a
/// crash is; Zig 0.17's fuzzer has no time limit of its own). Fuzzing alone starts it.
const fuzz_watch = struct {
    var watchdog: Watchdog = .{};
    var threaded: std.Io.Threaded = undefined;
    var thread: ?std.Thread = null;
    /// When the watchdog started, on the awake clock: its times count from here.
    var epoch: std.Io.Timestamp = undefined;

    fn start() !void {
        if (thread != null) return;
        threaded = .init(std.mem.Allocator.failing, .{});
        epoch = std.Io.Clock.awake.now(threaded.io());
        thread = try std.Thread.spawn(.{}, watch, .{});
    }

    /// Milliseconds since the watchdog started.
    fn now() u32 {
        const elapsed = epoch.durationTo(std.Io.Clock.awake.now(threaded.io()));
        return @intCast(@divTrunc(elapsed.nanoseconds, std.time.ns_per_ms));
    }

    fn begin() void {
        watchdog.begin(now());
    }

    fn end() void {
        watchdog.end();
    }

    fn watch() void {
        const period: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(WATCHDOG_PERIOD_MS), .clock = .awake };
        while (true) {
            period.sleep(threaded.io()) catch {};
            if (watchdog.expired(now(), RUN_BUDGET_S * std.time.ms_per_s)) {
                std.debug.print("fuzz: a run went past its wall-clock bound of {d} s, a hang: its draws are its draws file's line\n", .{RUN_BUDGET_S});
                @panic("a fuzz run went past its wall-clock bound");
            }
        }
    }
};

/// The draws file of a fuzz target's runs, opened the first time the worker runs one;
/// null on a plain run, or with no `-Dfuzz-draws`.
fn fuzzDrawLog(kind: ReplayKind) !?*DrawLog {
    if (comptime !builtin.fuzz or FUZZ_DRAWS_DIR.len == 0) return null;
    const State = struct {
        var logs: [std.enums.values(ReplayKind).len]?DrawLog = @splat(null);
    };
    const slot = &State.logs[@intFromEnum(kind)];
    if (slot.* == null) {
        const io = testing.io;
        try std.Io.Dir.cwd().createDirPath(io, FUZZ_DRAWS_DIR);
        var dir = try std.Io.Dir.cwd().openDir(io, FUZZ_DRAWS_DIR, .{});
        defer dir.close(io);
        slot.* = try DrawLog.open(io, dir, kind);
    }
    return &slot.*.?;
}

/// What a `replay:` line runs: its kind's target on its draws.
const ReplayKind = enum { chain, chords, overlay, solids };

/// Runs one `replay:` line, after the `replay:`; `error.InvalidReplay` when it is not one.
fn replayLine(line: []const u8) !void {
    var words = std.mem.tokenizeAny(u8, line, " \t\r");
    const kind = std.meta.stringToEnum(ReplayKind, words.next() orelse return error.InvalidReplay) orelse return error.InvalidReplay;
    var draws: std.ArrayList(i64) = .empty;
    defer draws.deinit(testing.allocator);
    while (words.next()) |w| try draws.append(testing.allocator, std.fmt.parseInt(i64, w, 10) catch return error.InvalidReplay);
    var source: ScriptedSource = .{ .draws = draws.items };
    switch (kind) {
        .chain => _ = try runChain(&source),
        .chords => try checkFreeFormChords(&source),
        .overlay => _ = try runArrangement(&source),
        .solids => _ = try runSolids(&source),
    }
}

test "Fuzz replay: the finds given with -Dfuzz-replay=FILE run clean" {
    // Each `replay:` line of the file (a failing run's, copied from a log) runs its target
    // on its draws; a find not yet fixed fails here, a fixed one is its regression test
    const text: []const u8 = @import("test_paths").fuzz_replay;
    if (text.len == 0) return error.SkipZigTest;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var ran: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const at = std.mem.indexOf(u8, line, "replay:") orelse continue;
        errdefer std.debug.print("the replay that failed: {s}\n", .{line});
        try replayLine(line[at + "replay:".len ..]);
        ran += 1;
    }
    try testing.expect(ran > 0);
}

test "Fuzz replay: a recorded run plays back draw for draw, a chain, a curve, an arrangement and a solid chain" {
    var prng = std.Random.DefaultPrng.init(PLAIN_RUN_SEED ^ 0x7e91);
    var source = RandomSource{ .random = prng.random() };
    for (std.enums.values(ReplayKind)) |kind| {
        for (0..8) |_| {
            var first: Recording(*RandomSource) = .{ .inner = &source };
            defer first.deinit();
            switch (kind) {
                .chain => _ = try runChain(&first),
                .chords => try checkFreeFormChords(&first),
                .overlay => _ = try runArrangement(&first),
                .solids => _ = try runSolids(&first),
            }
            var scripted: ScriptedSource = .{ .draws = first.draws.items };
            var again: Recording(*ScriptedSource) = .{ .inner = &scripted };
            defer again.deinit();
            switch (kind) {
                .chain => _ = try runChain(&again),
                .chords => try checkFreeFormChords(&again),
                .overlay => _ = try runArrangement(&again),
                .solids => _ = try runSolids(&again),
            }
            try testing.expectEqualSlices(i64, first.draws.items, again.draws.items);
        }
    }
    // A line read as the test reads a file's
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(testing.allocator);
    var recorded: Recording(*RandomSource) = .{ .inner = &source };
    defer recorded.deinit();
    _ = try runChain(&recorded);
    try line.appendSlice(testing.allocator, "chain");
    for (recorded.draws.items) |v| try line.print(testing.allocator, " {d}", .{v});
    try replayLine(line.items);
    try testing.expectError(error.InvalidReplay, replayLine("ball 1 2 3"));
    try testing.expectError(error.InvalidReplay, replayLine("chain 1 x"));
}

test "fuzz: the overlay labels any generated arrangement by each input's own area" {
    try testing.fuzz({}, overlayArrangement, .{});
}

fn overlayArrangement(_: void, smith: *Smith) anyerror!void {
    var recording: Recording(*Smith) = .init(smith, .overlay, try fuzzRun(.overlay));
    defer recording.deinit();
    errdefer recording.report("overlay");
    _ = try runArrangement(&recording);
}

test "Fuzz watchdog: a run past its budget has expired, one within it or ended has not" {
    var w: Watchdog = .{};
    const budget: u32 = RUN_BUDGET_S * std.time.ms_per_s;
    // Between runs nothing expires, however late
    try testing.expect(!w.expired(std.math.maxInt(u32) - 1, budget));
    w.begin(1_000);
    try testing.expect(!w.expired(1_000, budget));
    try testing.expect(!w.expired(1_000 + budget, budget));
    try testing.expect(w.expired(1_000 + budget + 1, budget));
    // The run ended: the next one's clock starts afresh
    w.end();
    try testing.expect(!w.expired(1_000 + 2 * budget, budget));
    w.begin(5 * budget);
    try testing.expect(!w.expired(5 * budget + 1, budget));
}

test "Fuzz replay: a run's draws are written down as drawn; a run that never ended leaves its line" {
    // The file under a fuzz worker that panicked holds the run's `replay:` line, which
    // `zig build fuzz-run` prints: the same line `report` prints, and one that replays.
    // Under wasmtime the tests touch no file system
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try DrawLog.open(io, tmp.dir, .solids);
    defer log.close();
    var prng = std.Random.DefaultPrng.init(PLAIN_RUN_SEED ^ 0xd2a5);
    var source = RandomSource{ .random = prng.random() };
    for (0..3) |_| {
        var recording: Recording(*RandomSource) = .init(&source, .solids, .{ .log = &log });
        var ended = false;
        defer if (!ended) recording.deinit();
        _ = try runSolids(&recording);
        // As a panic in the run's last call would leave it
        const text = try tmp.dir.readFileAlloc(io, DRAWS_FILE_PREFIX ++ "solids.txt", testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(text);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(testing.allocator);
        try expected.appendSlice(testing.allocator, "replay: solids");
        for (recording.draws.items) |v| try expected.print(testing.allocator, " {d}", .{v});
        try testing.expectEqualStrings(expected.items, text);
        try replayLine(text["replay:".len..]);
        // The run ended: its line is gone, and the next one starts afresh
        recording.deinit();
        ended = true;
        const after = try tmp.dir.readFileAlloc(io, DRAWS_FILE_PREFIX ++ "solids.txt", testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(after);
        try testing.expectEqual(@as(usize, 0), after.len);
    }
}

test "Fuzz overlay: generated arrangements label by their inputs' areas on a plain test run" {
    var prng = std.Random.DefaultPrng.init(PLAIN_RUN_SEED ^ 0x0e71a7);
    var source = RandomSource{ .random = prng.random() };
    var checked: usize = 0;
    for (0..PLAIN_RUN_ARRANGEMENTS) |_| {
        var recording: Recording(*RandomSource) = .{ .inner = &source };
        defer recording.deinit();
        errdefer recording.report("overlay");
        checked += @intFromBool(try runArrangement(&recording) == .checked);
    }
    try testing.expect(checked >= PLAIN_RUN_ARRANGEMENTS / 2);
}

/// One generated arrangement, fed to the overlay as it is (no sheet built first), dense in
/// near-tangent arcs: up to `MAX_INPUTS` inputs of up to `MAX_INPUT_RINGS` closed rings,
/// each a polygon of fine-grid points with some edges arcs (a bulge as the chains draw
/// them) or a circle about a grid point of one of `RADII` (tangent to grid lines and to
/// other circles), one point in `NUDGE_ONE_IN` a rounding off its grid point. Then the
/// arrangement is planar (`expectPlanar`: Euler, labels across every edge), and for each
/// input k the faces' windings weigh their areas to its own: the sum of winding_k × area
/// over the faces is the signed area its edges enclose (Green's theorem on the edges as
/// given), within the welding. A misnested cycle breaks that, by its own area.
fn runArrangement(source: anytype) !Outcome {
    var o = overlay_mod.Overlay.init(testing.allocator, tol);
    defer o.deinit();
    const n_inputs = source.valueRangeAtMost(u8, 1, MAX_INPUTS);
    var own_area: [MAX_INPUTS]f64 = @splat(0);
    var perimeter: [MAX_INPUTS]f64 = @splat(0);
    var given: [MAX_INPUTS]std.ArrayList(overlay_mod.InputEdge) = @splat(.empty);
    defer for (&given) |*g| g.deinit(testing.allocator);
    for (0..n_inputs) |k| {
        _ = o.addInput() catch |err| return clean(err);
        const rings = source.valueRangeAtMost(u8, 1, MAX_INPUT_RINGS);
        for (0..rings) |_| {
            var ring: [MAX_POINTS]overlay_mod.InputEdge = undefined;
            const n = try arrangementRing(source, &ring);
            for (ring[0..n]) |e| {
                o.addEdge(e) catch |err| return clean(err);
                try given[k].append(testing.allocator, e);
                own_area[k] += greenTerm(e) / 2;
                perimeter[k] += edgeLength(e);
            }
        }
    }
    // A failure shows its arrangement, as a chain shows itself
    errdefer {
        std.debug.print("the arrangement that failed:\n", .{});
        for (given[0..n_inputs], 0..) |g, k| {
            std.debug.print("  input {d}:\n", .{k});
            for (g.items) |e| {
                std.debug.print("    ({d}, {d}) -> ({d}, {d})", .{ e.a[0], e.a[1], e.b[0], e.b[1] });
                if (e.arc) |arc| std.debug.print(" arc about ({d}, {d}) r {d} {s}", .{ arc.c[0], arc.c[1], arc.r, if (arc.ccw) "ccw" else "cw" });
                std.debug.print("\n", .{});
            }
        }
    }
    o.run() catch |err| return clean(err);
    try expectWeighed(&o, own_area[0..n_inputs], perimeter[0..n_inputs]);
    var inputs: [MAX_INPUTS][]const overlay_mod.InputEdge = undefined;
    for (given[0..n_inputs], inputs[0..n_inputs]) |g, *i| i.* = g.items;
    try expectLabels(&o, inputs[0..n_inputs]);
    return .checked;
}

/// The overlay's labels against a count of their own: at a point inside each face (just
/// left of the middle of its outer cycle's longest piece, kept when the face's own cycles
/// cross a ray from it an odd number of times, so it is inside the face and off every
/// other edge by more than the welding), each input's edges as given cross the ray an odd
/// number of times exactly when the face's winding of that input is odd. A cycle nested in
/// the wrong face has its region labelled from that face: the count disagrees there. (The
/// areas' identity, `expectWeighed`, cannot see it: the misnested cycle's area moves into
/// the face it was wrongly left out of, by the winding it lost.) Every crossing is the
/// exact one (`overlay.arcCrossings`, `orient2d`).
fn expectLabels(o: *const overlay_mod.Overlay, inputs: []const []const overlay_mod.InputEdge) !void {
    var face_edges: std.ArrayList(overlay_mod.InputEdge) = .empty;
    defer face_edges.deinit(testing.allocator);
    for (o.faces.items, 0..) |f, fi| {
        // The face's cycles as edges, and its outer cycle's longest piece
        face_edges.clearRetainingCapacity();
        var longest: ?overlay_mod.InputEdge = null;
        var longest_length: f64 = 0;
        for (o.halvesOf(f.outer)) |h| {
            const e = halfEdge(o, h);
            try face_edges.append(testing.allocator, e);
            const length = edgeLength(e);
            if (length > longest_length) {
                longest_length = length;
                longest = e;
            }
        }
        for (o.holesOf(@intCast(fi))) |hole| for (o.halvesOf(hole)) |h| try face_edges.append(testing.allocator, halfEdge(o, h));
        const along = longest orelse continue;
        if (longest_length < LABEL_PROBE_MIN * tol.zone) continue;
        const p = leftOfMiddle(along, @max(LABEL_PROBE_SHARE * longest_length, LABEL_PROBE_MIN * tol.zone));
        if (!crossesOddly(face_edges.items, p)) continue;
        // Off every edge of the face by more than the welding moved any (a thin face's other
        // side can be nearer than its longest piece)
        var clear = true;
        for (face_edges.items) |e| clear = clear and distanceTo(e, p) > LABEL_PROBE_CLEAR * tol.zone;
        if (!clear) continue;
        for (inputs, 0..) |edges_k, k| {
            errdefer std.debug.print("face {d} at ({d}, {d}): input {d} labelled {d}\n", .{ fi, p[0], p[1], k, o.windingOf(@intCast(fi), @intCast(k)) });
            try testing.expectEqual(@mod(o.windingOf(@intCast(fi), @intCast(k)), 2) == 1, crossesOddly(edges_k, p));
        }
    }
}

/// The distance from `p` to edge `e`: to the nearest point of its line segment or its arc
/// (by the arc's turn about its centre, else its nearer end).
fn distanceTo(e: overlay_mod.InputEdge, p: Vec2) f64 {
    if (e.arc) |arc| {
        const to_ends = @min(vec.distance2(p, e.a), vec.distance2(p, e.b));
        const turn = overlay_mod.arcSweep(e.a, e.b, arc);
        const start = trig.atan2(e.a[1] - arc.c[1], e.a[0] - arc.c[0]);
        const at = trig.atan2(p[1] - arc.c[1], p[0] - arc.c[0]);
        const along = @mod(if (arc.ccw) at - start else start - at, 2 * std.math.pi);
        if (along > turn) return to_ends;
        return @min(to_ends, @abs(vec.distance2(p, arc.c) - arc.r));
    }
    const d = vec.sub2(e.b, e.a);
    const length_sq = vec.dot2(d, d);
    if (length_sq == 0) return vec.distance2(p, e.a);
    const t = std.math.clamp(vec.dot2(vec.sub2(p, e.a), d) / length_sq, 0, 1);
    return vec.distance2(p, vec.add2(e.a, vec.scale2(d, t)));
}

/// Half-edge `h` of the overlay as an edge from its origin to its target.
fn halfEdge(o: *const overlay_mod.Overlay, h: u32) overlay_mod.InputEdge {
    return .{ .a = o.point(o.origin(h)), .b = o.point(o.target(h)), .arc = o.arcOf(h) };
}

/// A point `d` to the left of the middle of edge `e`: its region's side.
fn leftOfMiddle(e: overlay_mod.InputEdge, d: f64) Vec2 {
    if (e.arc) |arc| {
        const start = trig.atan2(e.a[1] - arc.c[1], e.a[0] - arc.c[0]);
        const half = overlay_mod.arcSweep(e.a, e.b, arc) / 2;
        const angle = if (arc.ccw) start + half else start - half;
        const radial: Vec2 = .{ @cos(angle), @sin(angle) };
        // Left of a counter-clockwise arc is toward its centre
        const r = if (arc.ccw) arc.r - d else arc.r + d;
        return vec.add2(arc.c, vec.scale2(radial, r));
    }
    const mid = vec.scale2(vec.add2(e.a, e.b), 0.5);
    const dir = vec.normalized2(vec.sub2(e.b, e.a)) orelse return mid;
    return vec.add2(mid, vec.scale2(vec.perp2(dir), d));
}

/// Whether the ray from `p` to +x crosses `edges` an odd number of times, each crossing
/// told exactly: an arc by its y-monotone pieces (`overlay.arcCrossings`), a line by the
/// half-open rule and `orient2d`.
fn crossesOddly(cycle_edges: []const overlay_mod.InputEdge, p: Vec2) bool {
    var odd = false;
    for (cycle_edges) |e| {
        if (e.arc) |arc| {
            if (overlay_mod.arcCrossings(e.a, e.b, arc, p)) odd = !odd;
            continue;
        }
        if ((e.a[1] > p[1]) == (e.b[1] > p[1])) continue;
        const side = predicates.orient2d(e.a, e.b, p);
        if ((side > 0) == (e.b[1] > e.a[1])) odd = !odd;
    }
    return odd;
}

/// The overlay's oracle: the arrangement is planar (`expectPlanar`), and for each input k
/// the sum over faces of winding_k × area is `own_area[k]`, the signed area its edges
/// enclose, within the welding along its `perimeter[k]`.
fn expectWeighed(o: *const overlay_mod.Overlay, own_area: []const f64, perimeter: []const f64) !void {
    try @import("sketch/overlay_test.zig").expectPlanar(o);
    for (own_area, perimeter, 0..) |own, length, k| {
        var weighed: f64 = 0;
        for (o.faces.items, 0..) |f, fi| {
            var area = o.cycles.items[f.outer].area;
            for (o.holesOf(@intCast(fi))) |h| area += o.cycles.items[h].area;
            weighed += @as(f64, @floatFromInt(o.windingOf(@intCast(fi), @intCast(k)))) * area;
        }
        errdefer std.debug.print("input {d}: its area {d}, the faces' windings weigh {d}\n", .{ k, own, weighed });
        try testing.expectApproxEqAbs(own, weighed, 2 * tol.zone * length + WINDING_CLOSE * @max(@abs(own), 1));
    }
}

test "Fuzz overlay: the oracle on a nesting find of 2026-11-12, two arcs meeting a rounding above the ray" {
    // overlay_test.zig's case: a region whose dents meet at a vertex a rounding above
    // y = −0.5, a sliver touching it there, and a second input whose leftmost vertex lies
    // at y = −0.5. With its outside nested in the plane, the second input's face was
    // labelled outside the first's region, where a point inside it counts the first
    // input's edges once. (The other nesting find of that day, a lens beside two arcs'
    // lowest point, went wrong in the sketch builder's nesting of its boundary, after the
    // overlay: the sheet overlap rule sees that one.)
    var o = overlay_mod.Overlay.init(testing.allocator, tol);
    defer o.deinit();
    const r = 2.1213203435596424;
    const v: Vec2 = .{ 3.3708286933869704, -0.4999999999999998 };
    const inputs = [2][]const overlay_mod.InputEdge{
        &.{
            .{ .a = v, .b = .{ 3.566037735849056, -1.0188679245283017 }, .arc = .{ .c = .{ 1.5, -1.5 }, .r = r, .ccw = false } },
            .{ .a = .{ 3.566037735849056, -1.0188679245283017 }, .b = .{ 7, -1.5 } },
            .{ .a = .{ 7, -1.5 }, .b = .{ 7, 1 } },
            .{ .a = .{ 7, 1 }, .b = .{ 3.6213203435596424, 0.5 } },
            .{ .a = .{ 3.6213203435596424, 0.5 }, .b = v, .arc = .{ .c = .{ 1.5, 0.5 }, .r = r, .ccw = false } },
            .{ .a = v, .b = .{ 3, 0 }, .arc = .{ .c = .{ 1.5, -1.5 }, .r = r, .ccw = true } },
            .{ .a = .{ 3, 0 }, .b = .{ 3.2926829268292686, -0.6341463414634141 } },
            .{ .a = .{ 3.2926829268292686, -0.6341463414634141 }, .b = v, .arc = .{ .c = .{ 1.5, 0.5 }, .r = r, .ccw = true } },
        },
        &.{
            .{ .a = .{ 4, -0.5 }, .b = .{ 5, -0.8 } },
            .{ .a = .{ 5, -0.8 }, .b = .{ 6, -0.5 } },
            .{ .a = .{ 6, -0.5 }, .b = .{ 5, 0 } },
            .{ .a = .{ 5, 0 }, .b = .{ 4, -0.5 } },
        },
    };
    var own_area: [2]f64 = @splat(0);
    var perimeter: [2]f64 = @splat(0);
    for (inputs, 0..) |edges_k, k| {
        _ = try o.addInput();
        for (edges_k) |e| {
            try o.addEdge(e);
            own_area[k] += greenTerm(e) / 2;
            perimeter[k] += edgeLength(e);
        }
    }
    try o.run();
    try expectWeighed(&o, &own_area, &perimeter);
    try expectLabels(&o, &inputs);
}

/// One closed ring of an arrangement into `out`: a circle as two or four arcs about a fine-
/// grid point, or a polygon of fine-grid points whose edges are lines or, one in
/// `ARC_ONE_IN`, arcs; zero-length edges left out. Returns how many edges.
fn arrangementRing(source: anytype, out: *[MAX_POINTS]overlay_mod.InputEdge) !usize {
    if (source.valueRangeAtMost(u8, 0, 2) == 0) {
        const c = finePoint(source);
        const r = RADII[source.index(RADII.len)];
        const quarters: usize = if (source.valueRangeAtMost(u8, 0, 1) == 0) 2 else 4;
        const ccw = source.valueRangeAtMost(u8, 0, 1) == 1;
        var at: [4]Vec2 = undefined;
        for (0..quarters) |i| {
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(quarters));
            at[i] = .{ c[0] + r * @cos(angle), c[1] + r * @sin(angle) };
        }
        for (0..quarters) |i| {
            const from = if (ccw) i else quarters - i;
            const to = if (ccw) i + 1 else quarters - i - 1;
            out[i] = .{ .a = at[from % quarters], .b = at[to % quarters], .arc = .{ .c = c, .r = r, .ccw = ccw } };
        }
        return quarters;
    }
    const n = source.valueRangeAtMost(u8, MIN_POINTS, MAX_POINTS);
    var points: [MAX_POINTS]Vec2 = undefined;
    for (points[0..n]) |*p| p.* = finePoint(source);
    var made: usize = 0;
    for (0..n) |i| {
        const a = points[i];
        const b = points[(i + 1) % n];
        const arc = source.valueRangeAtMost(u8, 1, ARC_ONE_IN) == 1;
        const bulge = BULGES[source.index(BULGES.len)];
        const ccw = source.valueRangeAtMost(u8, 0, 1) == 1;
        if (a[0] == b[0] and a[1] == b[1]) continue;
        out[made] = .{ .a = a, .b = b };
        if (arc) {
            const half = vec.scale2(vec.sub2(b, a), 0.5);
            const c = vec.add2(vec.add2(a, half), vec.scale2(vec.perp2(half), bulge));
            out[made].arc = .{ .c = c, .r = vec.distance2(a, c), .ccw = ccw };
        }
        made += 1;
    }
    return made;
}

/// A point of the fine grid, one in `NUDGE_ONE_IN` moved a rounding off it in x.
fn finePoint(source: anytype) Vec2 {
    var p: Vec2 = .{ @as(f64, @floatFromInt(source.valueRangeAtMost(i32, 0, FINE_GRID))) / FINE_SCALE, @as(f64, @floatFromInt(source.valueRangeAtMost(i32, 0, FINE_GRID))) / FINE_SCALE };
    if (source.valueRangeAtMost(u8, 1, NUDGE_ONE_IN) == 1) p[0] = std.math.nextAfter(f64, p[0], std.math.inf(f64));
    return p;
}

/// Twice the edge's share of the area its cycles enclose (the overlay's `areaTerm` on an
/// input edge): the chord's cross product, plus an arc's segment by its turn.
fn greenTerm(e: overlay_mod.InputEdge) f64 {
    var twice = e.a[0] * e.b[1] - e.b[0] * e.a[1];
    if (e.arc) |arc| {
        const theta = overlay_mod.arcSweep(e.a, e.b, arc);
        const segment = arc.r * arc.r * (theta - @sin(theta));
        twice += if (arc.ccw) segment else -segment;
    }
    return twice;
}

fn edgeLength(e: overlay_mod.InputEdge) f64 {
    if (e.arc) |arc| return arc.r * overlay_mod.arcSweep(e.a, e.b, arc);
    return vec.distance2(e.a, e.b);
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

/// The sheet passes every rule of the checker and the overlap rule (sketch/overlap.zig),
/// and has an area unless it is the empty sheet (a boolean's empty result).
fn expectSound(body: *const Body, diag: *Diagnostics) !void {
    var report = try check.run(testing.allocator, body, .global);
    defer report.deinit(testing.allocator);
    if (!report.ok()) {
        std.debug.print("the checker: {f}\n", .{report.first().?});
        return error.ResultNotValid;
    }
    // No two faces over one region (the rule the checker cannot run: it needs the overlay)
    overlap.check(testing.allocator, body, diag) catch |err| {
        std.debug.print("the overlap rule: {f}\n", .{diag});
        return err;
    };
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

/// The sheet extruded by `height` is a solid that passes the checker and the overlap rules
/// (query/overlap.zig), whose mesh is closed (every directed edge
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
    // Its faces meet only on their boundaries and its solids lie apart (the planar pairs:
    // curved ones are M5's)
    solid_overlap.check(testing.allocator, &solid, .{}, diag) catch |err| {
        std.debug.print("the overlap rules on the extrusion: {f}\n", .{diag});
        return err;
    };
    var mesh = try tessellate.tessellate(testing.allocator, &solid, .{}, .{}, diag);
    defer mesh.deinit(testing.allocator);
    errdefer {
        std.debug.print("the solid's mesh: {d} vertices, {d} triangles; faces:", .{ mesh.positions.len, mesh.triangles.len });
        for (mesh.faces) |range| std.debug.print(" {s}", .{@tagName(range.status)});
        std.debug.print("\n{f}\n", .{diag});
    }
    for (mesh.faces) |range| try testing.expectEqual(tessellate.Status.ok, range.status);
    // Graded in the checker's words (mesh/validate.zig) against the solid's shells: every
    // shell closed; a body that does not touch itself (no singular vertex) has a closed
    // mesh with no singular vertex; one that does (regions of the sheet touching at a
    // corner make solids touching along an edge: two edges of the body, one pair of mesh
    // vertices used four times) shows it in its mesh, as a singular vertex or an
    // irregular edge; and every mesh is watertight, each directed side matched by as many
    // reverses, with nothing degenerate
    const verdict = try validate.grade(testing.allocator, mesh.triangles, mesh.positions.len);
    try testing.expectEqual(@as(u32, 0), verdict.degenerate_triangles);
    var body_singular = false;
    for (report.shells.items) |sg| {
        try testing.expectEqual(condition.Condition.closed, sg.grade.condition);
        body_singular = body_singular or sg.grade.singular_vertices > 0;
    }
    errdefer std.debug.print("mesh {s}, {d} singular; body singular {}\n", .{ verdict.grade.condition.word(), verdict.grade.singular_vertices, body_singular });
    // A sliver no resolution the tessellator uses resolves (a face still reporting a
    // pruned spike) encloses nothing in the mesh: its sides may coincide there
    var sliver = false;
    for (mesh.faces) |range| sliver = sliver or range.spikes_pruned;
    if (sliver) {
        // Watertight still, checked below
    } else if (body_singular) {
        try testing.expect(verdict.grade.singular_vertices > 0 or verdict.grade.condition == .irregular);
    } else {
        try testing.expect(verdict.grade.isManifoldClosed());
    }
    var sides: std.AutoHashMapUnmanaged([2]u32, i32) = .empty;
    defer sides.deinit(testing.allocator);
    for (mesh.triangles) |t| for (0..3) |k| {
        const a = t[k];
        const b = t[(k + 1) % 3];
        const entry = try sides.getOrPut(testing.allocator, .{ @min(a, b), @max(a, b) });
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += if (a < b) 1 else -1;
    };
    var balance = sides.valueIterator();
    while (balance.next()) |count| try testing.expectEqual(@as(i32, 0), count.*);
    var volume: f64 = 0;
    for (mesh.triangles) |t| {
        const a = mesh.positions[t[0]];
        const b = mesh.positions[t[1]];
        const c = mesh.positions[t[2]];
        try testing.expect(vec.lengthSq(vec.cross(vec.sub(b, a), vec.sub(c, a))) > 0);
        volume += vec.dot(a, vec.cross(b, c)) / 6;
    }
    // The exact volume within the chords' share (the mesh may have refined an arc's
    // chords where they would cross a neighbour, so it is held to the base grid's bound)
    // and the welded vertices' slack, as the sheet's area is (expectSound)
    const exact = (try mass.mass(&solid, .{}, diag)).volume;
    const bound = (try chordBound(sheet_body, diag) + try weldingSlack(sheet_body, diag) + AREA_CLOSE * @max(exact / height, 1)) * height;
    try testing.expectApproxEqAbs(exact, volume, bound);
    try expectQueries(&solid, height, diag);
    try expectSlices(&solid, sheet_body, height, diag);
}

/// The extruded solid's plane sections: at its bottom (the solid just above the plane) and
/// at a height off the grid, the sheet itself, each within the other; at its top, nothing;
/// and the solid turned a right angle about x (its sides lying, its arcs' cylinders cut in
/// lines) at a height off the grid, whose section holds a point exactly when the solid
/// holds the point at that height (off the boundary). A refusal of a section is clean.
fn expectSlices(solid: *const Body, sheet_body: *const Body, height: f64, diag: *Diagnostics) !void {
    const a_sheet = (try mass.mass(sheet_body, .{}, diag)).area;
    for ([_]f64{ 0, height * SLICE_AT, height }) |z| {
        var cut = section.slice(testing.allocator, solid, z, .{}, diag) catch |err| {
            _ = try clean(err);
            continue;
        };
        defer cut.deinit();
        errdefer std.debug.print("the section at {d}\n", .{z});
        try expectSound(&cut, diag);
        if (z == height) {
            try testing.expectEqual(@as(usize, 0), cut.counts().faces);
            continue;
        }
        const a_cut = (try mass.mass(&cut, .{}, diag)).area;
        try testing.expectApproxEqAbs(a_sheet, a_cut, try weldingSlack(sheet_body, diag) + AREA_CLOSE * @max(a_sheet, 1));
        try expectWithin(&cut, sheet_body, diag);
        try expectWithin(sheet_body, &cut, diag);
    }
    var lying = transform.transform(testing.allocator, solid, &Affine.rotate(vec.X3, std.math.pi / 2.0), .{}, diag) catch |err| {
        _ = try clean(err);
        return;
    };
    defer lying.deinit();
    var index = try solid_query.FaceIndex.build(testing.allocator, &lying, diag);
    defer index.deinit(testing.allocator);
    const box = index.box;
    const span = box.size();
    const z = box.min[2] + SLICE_AT * span[2];
    var cut = section.slice(testing.allocator, &lying, z, .{}, diag) catch |err| {
        _ = try clean(err);
        return;
    };
    defer cut.deinit();
    errdefer std.debug.print("the section of the solid turned about x at {d}\n", .{z});
    try expectSound(&cut, diag);
    for (0..SLICE_POINTS) |i| {
        const k: f64 = @floatFromInt(i);
        const p: Vec2 = .{ box.min[0] + @mod(k * 0.618 + 0.21, 1) * span[0], box.min[1] + @mod(k * 0.382 + 0.13, 1) * span[1] };
        const place = solid_query.point_in_body.classify(testing.allocator, &lying, &index, .{ p[0], p[1], z }, .{}, diag) catch |err| {
            _ = try clean(err);
            continue;
        };
        if (place == .boundary) continue;
        errdefer std.debug.print("at ({d}, {d}) the solid says {s}\n", .{ p[0], p[1], @tagName(place) });
        try testing.expectEqual(place == .inside, try query.contains(&cut, p, 0, diag));
    }
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

test "Fuzz chords: generated free-form curves on a plain test run are certified or refused, the 2026-11-12 find included" {
    // A rational cubic whose weights run from 2.8e-3 to 4.6e3: its hull certified a span
    // 6e-12 short of where the curve reached, by rounding; the certificate now leaves room
    // for the curve's own rounding, so such a curve's edge is refused
    const knots = [_]f64{ 0, 0, 0, 0, 0.2, 0.4, 0.6, 0.8, 1, 1, 1, 1 };
    const points = [_]vec.Vec4{
        .{ -3.4e-2, 5.33e3, -5.8e3, 42.4 },  .{ 1.81, -0.978, -6.02e-2, 2.86e3 },   .{ 8.4e-3, -9.74e3, -4.2e3, 0.683 },
        .{ -6.45e-3, -0.216, 5.36e-2, 3.98e-2 }, .{ 0.993, 0.291, 4.94e-2, 7.45e-3 }, .{ -8.53, -6.83, -268, 4.57e3 },
        .{ -4.17e-3, 21.3, 5.48, 2.81e-3 },  .{ -0.451, 0.936, 51.2, 0.903 },
    };
    const curve: curves.Curve = .{ .nurbs = .{ .degree = 3, .knots = &knots, .points = &points } };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var out: std.ArrayList(f64) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.LimitExceeded, chords.sampleParams(testing.allocator, curve, 0.13, 1, .{ .segments = 179 }, &out, &diag, .none));
    // And many generated curves, each certified to the dense check or refused
    var prng = std.Random.DefaultPrng.init(PLAIN_RUN_SEED);
    var source: RandomSource = .{ .random = prng.random() };
    for (0..PLAIN_RUN_CURVES) |_| try checkFreeFormChords(&source);
}

// --- booleans of solids (M4) ---

/// The coarse grid solids are placed on: integers in [0, SOLID_GRID], so faces coincide,
/// edges overlap and corners touch often (research/solidcraft.md §1).
const SOLID_GRID: i32 = 4;
/// Steps of a solid chain at most; a step is a boolean (all three, for the identities) or
/// a cut by a plane.
const MAX_SOLID_OPS = 3;
/// A hull's points, at least and at most.
const MIN_HULL_POINTS = 4;
const MAX_HULL_POINTS = 8;
/// A chain stops once its solid has this many faces: the work of every step is bounded.
const SOLID_FACES_AT_MOST = 300;
/// The turns a placement takes (radians): the grid's own, half of one, and one off it.
const TURNS = [_]f64{ std.math.pi / 2.0, std.math.pi, std.math.pi / 4.0, 0.3 };
const TURN_AXES = [_]vec.Vec3{ vec.X3, vec.Y3, vec.Z3, .{ 1, 2, 3 } };
/// A scale per axis.
const SCALES = [_]f64{ 0.5, 1, 2 };
/// Chains of a plain test run, and how many must reach their checks.
const PLAIN_RUN_SOLIDS = 40;

const solid_boolean = struct {
    const pipeline = @import("boolean/pipeline.zig");
    const trim = @import("boolean/trim.zig");
    const tests = @import("boolean/pipeline_test.zig");
};
const solid_hull = @import("construct/hull.zig");

test "fuzz: booleans of solids take any generated chain" {
    try testing.fuzz({}, solidChain, .{});
}

fn solidChain(_: void, smith: *Smith) anyerror!void {
    var recording: Recording(*Smith) = .init(smith, .solids, try fuzzRun(.solids));
    defer recording.deinit();
    errdefer recording.report("solids");
    _ = try runSolids(&recording);
}

test "Fuzz solids: generated chains of booleans of solids run clean on a plain test run, most of them checked" {
    var prng = std.Random.DefaultPrng.init(PLAIN_RUN_SEED ^ 0x5011d5);
    var source = RandomSource{ .random = prng.random() };
    var checked: usize = 0;
    for (0..PLAIN_RUN_SOLIDS) |_| {
        var recording: Recording(*RandomSource) = .{ .inner = &source };
        defer recording.deinit();
        errdefer recording.report("solids");
        checked += @intFromBool(try runSolids(&recording) == .checked);
    }
    try testing.expect(checked >= PLAIN_RUN_SOLIDS / 2);
}

test "Fuzz finds: the finds of 2026-11-13 replay clean, the local sessions' and the nightly's" {
    const finds = [_][]const u8{
        // a cut's corner on the face it was cut from, the cut open elsewhere: a pinch at a point, refused
        "solids 0 0 4 0 3 1 3 3 2 -1 1 2 14 1 1 1 7 3 3 2 1 2 4 2 1 4 2 2 0 0 1 4 1 1 2 0 2 2 2 1 1 0 2 8 1",
        // a sliver one intersection tolerance thick crossed by a face: the paves decide the boundary, a sample on the other's face gives way
        "solids 0 0 1 3 4 1 2 3 3 2 2 0 1 0 4 3 2 1 8 1 1 1 2 3 3 3 4 2 1 4 0 1 4 2 2 3 2 2 1 0 3 1 1 1 3 -1 0 2 1 1 10 0",
        // a contact along a line across two coplanar faces of a hull: an edge with a copy is never removed
        "solids 0 1 2 1 3 2 4 0 0 1 3 -1 -2 2 14 1 1 1 5 1 4 1 4 0 4 0 4 2 1 3 2 1 3 4 1 2 0 -1 0 3 0",
        // a pinched difference reaching simplification: the assembly checked structurally first, no panic
        "solids 1 5 1 0 2 2 1 4 0 2 0 2 3 4 4 1 1 0 2 0 0 1 2 1 1 -2 -2 1 2 6 2 1 1 4 0 3 1 3 4 4 0 1 4 1 0 0 0 0 0 3 1 2 -1 8 0",
        // an edge passing an edge within the tolerance, crossing its face at a shallow angle: an edge meets a plane once
        "solids 0 3 4 3 4 0 1 2 0 2 0 0 2 -2 -1 16 3 1 1 7 4 3 4 4 4 4 1 4 3 0 1 0 3 3 4 0 4 0 0 4 0 1 3 -2 -1 0 1 0 10 0 1 1 4 1 1 4 0 3 0 0 2 1 4 2 2 0 1 3 2 -2 1 -1 3 1 3 0 3 4 1 3 2 3 0 1 1 0 0 0 2 0 1 -2 3 1",
        // vertices exactly the intersection tolerance apart, merged: the ball past the zone by rounding, refused at the merge
        "solids 0 2 3 1 2 0 4 3 2 -1 -1 -1 6 2 1 1 7 1 1 3 4 0 1 0 0 4 0 1 0 4 0 3 3 3 1 0 0 4 2 2 -1 -1 2 1 2 10 1 3 1 7 2 2 4 1 0 4 0 0 4 4 2 4 2 2 1 0 1 2 4 0 0 0 2 0 0 0 1 1 2 1 1 2 1",
        // a lone slit's spur removed, its near vertex left a loop of one vertex; the containment table then sewed it
        "solids 0 1 4 1 4 1 2 3 2 -1 -2 0 12 3 3 0 0 3 0 2 3 4 2 3 2 2 -1 2 1 1 0 2 4 1 2 0 4 2 3 2 2 -1 10 0 1 0 2 3 2 3 3 4 2 3 -1 -2 2 2 1",
        // The nightly's (run 43339802911): a box's corner at a hull triangle's centroid, the face's only sample, unclassified
        "solids 0 3 4 1 3 2 3 2 2 -1 -1 -2 3 3 2 1 5 1 4 3 1 2 1 4 4 2 1 0 3 1 4 1 1 2 -1 2 2 15 0 1 0 1 2 2 4 3 4 2 0 2 1 1 -1 -2 -2 11 0",
        "solids 1 7 2 0 3 0 3 0 1 2 3 4 2 0 1 4 3 2 1 4 3 4 0 1 1 -1 1 1 13 3 2 1 5 1 0 1 3 2 1 0 0 2 4 1 1 1 4 1 0 2 3 2 0 0 1 13 1 3 1 8 2 0 4 1 3 0 4 3 4 3 4 1 4 1 1 0 1 0 3 2 4 1 0 0 3 1 -1 -1 -2 14 2 3 1 4 3 3 2 4 3 0 1 1 1 1 4 2 1 1 0 2 -1 2 2",
        // The nightly's: a circle's leftmost vertex level with an arc's lowest point, the arc's west piece ending straight above it
        "overlay 1 2 0 8 4 8 0 1 1 1 8 13 12 1 3 18 1 19 14 5 20 23 6 0 17 8 1 20 1 11 14 7 1 24 2 3 2 1 3 2 0 2 2 0 2 3 1 2 0 1 3 2 1 1 3 0 4 2 0",
        // The nightly's (run 43411851511, locus_solids and locus): a meet's piece reaching a crossing outside one face
        "solids 0 2 4 0 3 3 4 2 2 0 -2 -1 10 3 3 0 1 3 2 4 2 4 3 2 0 2 0 2 0 2 1 8 1 1 0 0 3 0 2 2 1 2 3 0 4 0 2 0 2 0 1 0 1 2 4 2 3 3 0 2 0 1 0 9 2",
        "solids 1 8 2 1 3 3 2 1 3 4 1 0 4 4 4 1 2 3 1 1 0 1 3 2 0 4 2 2 1 -2 -1 2 3 1 1 8 3 1 1 1 1 2 2 3 0 1 2 4 1 0 0 3 3 3 1 3 4 4 1 1 1 3 -2 1 -2 16 0 2 0 0 1 1 3 2 3 3 2 0 2 -1 1 0 4 0",
        // The nightly's (run 43413453969): a vertex the intersection tolerance off a face, its edge crossing the plane exactly further in
        "solids 0 1 2 1 3 2 4 0 3 2 1 -2 0 -1 3 3 3 1 7 0 4 1 3 1 2 1 1 0 1 2 0 1 1 4 2 1 2 1 0 3 1 1 1 2 0 1 0 10 1 1 0 0 3 1 2 2 3 3 1 2 -1 2 11 1",
        // The nightly's (run 43417538617): a hull moved by the tolerance exactly, refused at it (locus_solids); a box's edge's end on a face (locus)
        "solids 1 5 4 4 2 4 4 1 3 1 2 0 1 4 3 1 2 2 0 0 2 2 -1 -2 -2 8 2 1 1 6 3 3 4 0 1 2 3 1 3 3 1 1 2 2 3 1 4 0 2 2 -1 0 0 1 0 10 0 1 0 1 3 0 2 1 3 1 3 0 2 2 12 2",
        "solids 0 1 3 1 3 0 4 1 2 2 0 1 9 3 1 1 8 0 2 2 4 0 3 0 2 2 3 1 3 1 2 0 0 3 3 1 2 1 4 4 3 2 2 0 0 2 11 0 3 1 5 0 2 3 0 1 4 3 1 0 4 1 2 0 2 0 0 2 1 1 2 1 2 1 1 9 0",
    };
    for (finds) |line| {
        errdefer std.debug.print("the replay that failed: {s}\n", .{line});
        try replayLine(line);
    }
}

/// One generated chain of booleans of solids (architecture §9.2's M4 fuzz): a solid, then up
/// to `MAX_SOLID_OPS` steps, each a boolean with another solid or a cut by a plane. A
/// boolean step makes all three of the pair: each through the checker at level 2, the
/// overlap rules and its report (`pipeline_test.expectReportFits`), and the volume
/// identities, V(A ∪ B) + V(A ∩ B) = V(A) + V(B) and V(A − B) = V(A) − V(A ∩ B), exactly but
/// for a slab of faces closer than the intersection tolerance (one plane to the boolean); the
/// chain goes on with one of them. A cut's two sides make the whole. A refusal by design (a
/// pinch, an edge too short to split, an argument out of range) is clean; the general path
/// failing on valid planar operands (`NotValid`, `IntersectionFailed`) is a find.
fn runSolids(source: anytype) !Outcome {
    var log: Log = .{};
    defer log.text.deinit(testing.allocator);
    errdefer std.debug.print("the solid chain that failed:\n{s}", .{log.text.items});
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    errdefer std.debug.print("the findings: {f}\n", .{diag});
    var current = (try generatedSolid(source, &log, &diag)) orelse return .refused;
    defer current.deinit();
    try expectSolid(&current, &diag);

    const ops = source.valueRangeAtMost(u8, 1, MAX_SOLID_OPS);
    for (0..ops) |_| {
        if (current.counts().faces > SOLID_FACES_AT_MOST) break;
        if (source.valueRangeAtMost(u8, 0, 3) == 0) {
            // A cut by a plane, the normal on the grid's directions
            var normal: vec.Vec3 = undefined;
            for (&normal) |*c| c.* = @floatFromInt(source.valueRangeAtMost(i32, -1, 1));
            if (normal[0] == 0 and normal[1] == 0 and normal[2] == 0) normal = vec.Z3;
            const extreme = source.valueRangeAtMost(u8, 1, EXTREME_ONE_IN) == 1;
            const at = if (extreme) EXTREMES[source.index(EXTREMES.len)] else @as(f64, @floatFromInt(source.valueRangeAtMost(i32, -2, 2 * SOLID_GRID))) * 0.5;
            try log.add("  trim by {d} {d} {d} at {d}\n", .{ normal[0], normal[1], normal[2], at });
            var front = solid_boolean.trim.trimByPlane(testing.allocator, &current, normal, at, .{}, &diag, null) catch |err| return cleanSolid(err);
            defer front.deinit();
            var back = solid_boolean.trim.trimByPlane(testing.allocator, &current, vec.neg(normal), -at, .{}, &diag, null) catch |err| return cleanSolid(err);
            defer back.deinit();
            try expectSolid(&front, &diag);
            try expectSolid(&back, &diag);
            const whole = try mass.mass(&current, .{}, &diag);
            try testing.expectApproxEqAbs(whole.volume, try solidVolume(&front, &diag) + try solidVolume(&back, &diag), IDENTITY_CLOSE * @max(whole.volume, 1) + tol.xsect * whole.area);
            continue;
        }
        var other = (try generatedSolid(source, &log, &diag)) orelse continue;
        defer other.deinit();
        try expectSolid(&other, &diag);
        const op = pick(solid_boolean.pipeline.Op, source);
        try log.add("  {s}\n", .{@tagName(op)});
        var results: [3]Body = undefined;
        var made: usize = 0;
        defer for (results[0..made]) |*r| r.deinit();
        for ([_]solid_boolean.pipeline.Op{ .@"union", .intersection, .difference }) |each| {
            var report = solid_boolean.pipeline.Report.init(testing.allocator);
            defer report.deinit();
            results[made] = solid_boolean.pipeline.boolean(testing.allocator, &current, &other, each, .{}, &diag, &report) catch |err| return cleanSolid(err);
            made += 1;
            try expectSolid(&results[made - 1], &diag);
            try solid_boolean.tests.expectReportFits(&report, &current, &other, &results[made - 1], each);
        }
        const ma = try mass.mass(&current, .{}, &diag);
        const mb = try mass.mass(&other, .{}, &diag);
        const va = ma.volume;
        const vb = mb.volume;
        const vu = try solidVolume(&results[0], &diag);
        const vi = try solidVolume(&results[1], &diag);
        const vd = try solidVolume(&results[2], &diag);
        // Faces closer than the intersection tolerance are one plane: the slab between them,
        // at most the tolerance times the smaller operand's area, may count either way
        const close = IDENTITY_CLOSE * @max(va + vb, 1) + tol.xsect * @min(ma.area, mb.area);
        errdefer std.debug.print("volumes: a {d}, b {d}, union {d}, intersection {d}, difference {d}\n", .{ va, vb, vu, vi, vd });
        try testing.expectApproxEqAbs(va + vb, vu + vi, close);
        try testing.expectApproxEqAbs(va - vi, vd, close);
        const keep: usize = switch (op) {
            .@"union" => 0,
            .intersection => 1,
            .difference => 2,
        };
        current.deinit();
        current = results[keep];
        // The kept result is the chain's now; the others are freed
        results[keep] = results[made - 1];
        made -= 1;
    }
    return .checked;
}

/// A refusal by design is clean; the general path failing on valid planar operands is a
/// find, and out of memory is the harness's own.
fn cleanSolid(err: anyerror) anyerror!Outcome {
    return switch (err) {
        error.OutOfMemory, error.NotValid, error.IntersectionFailed => err,
        else => .refused,
    };
}

/// A box or the hull of grid points, placed: sometimes turned about an axis through the
/// grid's middle, sometimes scaled per axis, moved by half-steps; one time in
/// `EXTREME_ONE_IN` a placement takes a value a script would never write. Null for a clean
/// refusal (a hull of points in a plane, an extreme placement refused).
fn generatedSolid(source: anytype, log: *Log, diag: *Diagnostics) !?Body {
    var shape: Body = undefined;
    if (source.valueRangeAtMost(u8, 0, 1) == 0) {
        var lo: vec.Vec3 = undefined;
        var hi: vec.Vec3 = undefined;
        for (0..3) |k| {
            const a = source.valueRangeAtMost(i32, 0, SOLID_GRID - 1);
            lo[k] = @floatFromInt(a);
            hi[k] = @floatFromInt(source.valueRangeAtMost(i32, a + 1, SOLID_GRID));
        }
        try log.add("box ({d}, {d}, {d}) to ({d}, {d}, {d})", .{ lo[0], lo[1], lo[2], hi[0], hi[1], hi[2] });
        var unit = primitives.box(testing.allocator, tol, hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], false, diag) catch |err| return refusedSolid(err);
        defer unit.deinit();
        shape = transform.transform(testing.allocator, &unit, &Affine.translate(lo), .{}, diag) catch |err| return refusedSolid(err);
    } else {
        var points: [MAX_HULL_POINTS]vec.Vec3 = undefined;
        const n = source.valueRangeAtMost(u8, MIN_HULL_POINTS, MAX_HULL_POINTS);
        try log.add("hull of", .{});
        for (points[0..n]) |*p| {
            for (p) |*c| c.* = @floatFromInt(source.valueRangeAtMost(i32, 0, SOLID_GRID));
            try log.add(" ({d}, {d}, {d})", .{ p[0], p[1], p[2] });
        }
        shape = solid_hull.hull(testing.allocator, tol, points[0..n], diag) catch |err| {
            try log.add(": refused\n", .{});
            return refusedSolid(err);
        };
    }
    defer shape.deinit();
    // The placement
    const middle: vec.Vec3 = @splat(@as(f64, @floatFromInt(SOLID_GRID)) / 2);
    var place = Affine.translate(vec.ZERO3);
    if (source.valueRangeAtMost(u8, 0, 3) == 0) {
        const axis = vec.normalized(TURN_AXES[source.index(TURN_AXES.len)]).?;
        const angle = TURNS[source.index(TURNS.len)];
        try log.add(", turned {d} about ({d}, {d}, {d})", .{ angle, axis[0], axis[1], axis[2] });
        place = Affine.rotateAbout(middle, axis, angle).compose(&place);
    }
    if (source.valueRangeAtMost(u8, 0, 3) == 0) {
        var by: vec.Vec3 = undefined;
        for (&by) |*c| c.* = SCALES[source.index(SCALES.len)];
        try log.add(", scaled ({d}, {d}, {d})", .{ by[0], by[1], by[2] });
        place = Affine.scaleBy(by).compose(&place);
    }
    var move: vec.Vec3 = undefined;
    for (&move) |*c| c.* = @as(f64, @floatFromInt(source.valueRangeAtMost(i32, -2, 2))) * 0.5;
    if (source.valueRangeAtMost(u8, 1, EXTREME_ONE_IN) == 1) move[source.index(3)] = EXTREMES[source.index(EXTREMES.len)];
    try log.add(", moved ({d}, {d}, {d})\n", .{ move[0], move[1], move[2] });
    place = Affine.translate(move).compose(&place);
    const placed = transform.transform(testing.allocator, &shape, &place, .{}, diag) catch |err| return refusedSolid(err);
    return placed;
}

fn refusedSolid(err: anyerror) anyerror!?Body {
    if (err == error.OutOfMemory) return err;
    return null;
}

/// A solid passes every rule of the checker and the overlap rules.
fn expectSolid(body: *const Body, diag: *Diagnostics) !void {
    var report = try check.run(testing.allocator, body, .global);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        std.debug.print("the checker: {f}\n", .{f});
        return error.ResultNotValid;
    }
    solid_overlap.check(testing.allocator, body, .{}, diag) catch |err| {
        // The rule that failed, before the warnings the result carries
        if (diag.first()) |f| std.debug.print("the overlap rules: {f}\n", .{f});
        return err;
    };
}

fn solidVolume(body: *const Body, diag: *Diagnostics) !f64 {
    return (try mass.mass(body, .{}, diag)).volume;
}
