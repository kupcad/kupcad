//! The Path natives: `line`, `polyline` and `arc` make one, `+` joins two where one ends
//! and the next starts, and a Path moves (translate, rotate, scale, mirror), closes into a
//! Sketch (`close`), takes a width (`stroke`), and carries a name and a material for a
//! drawing. A Path is open 2D geometry (core/path.zig) with no kernel form of its own: its
//! segments are exact, and only a closed or stroked one is drawn by the kernel.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const HandleScope = @import("../vm/scope.zig").HandleScope;
const util = @import("methods/util.zig");
const path_mod = @import("../core/path.zig");
const affine2 = @import("../core/affine2.zig");
const turnShare = @import("../core/engine_config.zig").turnShare;
const Signature = @import("signature.zig").Signature;

pub const LINE = Signature{ .positional = &.{ "from", "to" } };
pub const POLYLINE = Signature{ .positional = &.{"points"} };
pub const ARC = Signature{ .keywords = &.{ "center", "r", "radius", "start", "sweep", "to", "ccw", "large" } };
pub const STROKE = Signature{ .positional = &.{"width"}, .keywords = &.{ "width", "cap", "segments" }, .solid_sizes = &.{"width"} };

/// The fewest points a polyline takes: a line.
const MIN_POLYLINE_POINTS = 2;

/// The ends of a stroke, and its joins: round (a half circle), flat at the end (butt) or
/// flat half a width past it (square).
const Cap = enum { round, butt, square };

/// `line(from, to)`: a straight path.
pub fn nativeLine(vm: *VM, args: []const value.Value) !value.Value {
    const pos = (try util.parseKwargsSubset(struct {}, LINE.keywords, vm, args, "line")).positional;
    if (pos.len != 2) return vm.fail(.ArgumentError, "line expects two points, [x, y] each, got {d} argument{s}", .{ pos.len, if (pos.len == 1) "" else "s" });
    const from = try util.parsePoint(2, vm, pos[0], "line", 0);
    const to = try util.parsePoint(2, vm, pos[1], "line", 1);
    if (from[0] == to[0] and from[1] == to[1]) return vm.fail(.ValueError, "line expects two different points, got [{f}, {f}] twice", .{ value.fmtNumber(from[0]), value.fmtNumber(from[1]) });
    return vm.allocatePath(from, &.{.{ .to = to }}, null, null);
}

/// `polyline(points)`: straight segments through the points, in order.
pub fn nativePolyline(vm: *VM, args: []const value.Value) !value.Value {
    const pos = (try util.parseKwargsSubset(struct {}, POLYLINE.keywords, vm, args, "polyline")).positional;
    if (pos.len != 1) return vm.fail(.ArgumentError, "polyline expects an Array of [x, y] points", .{});
    const items = try util.requireArray(vm, pos[0], "polyline", "points");
    if (items.len < MIN_POLYLINE_POINTS) return vm.fail(.ValueError, "polyline needs at least {d} points, got {d}", .{ MIN_POLYLINE_POINTS, items.len });
    const segments = try vm.allocator.alloc(path_mod.Segment, items.len - 1);
    defer vm.allocator.free(segments);
    var from = try util.parsePoint(2, vm, items[0], "polyline", 0);
    const start = from;
    for (items[1..], segments, 1..) |item, *segment, i| {
        const to = try util.parsePoint(2, vm, item, "polyline", i);
        if (to[0] == from[0] and to[1] == from[1]) return vm.fail(.ValueError, "polyline point {d} repeats the one before it, [{f}, {f}]", .{ i, value.fmtNumber(to[0]), value.fmtNumber(to[1]) });
        segment.* = .{ .to = to };
        from = to;
    }
    return vm.allocatePath(start, segments, null, null);
}

/// `arc(center:, r:, start:, sweep:)`: the arc of a circle from `start` degrees through
/// `sweep` degrees, counter-clockwise when positive; or `arc(r:, start: [x, y], to: [x, y])`:
/// the arc of radius `r` between two points, the short way round counter-clockwise unless
/// `large:` or `ccw: false` say otherwise. (`end` and `from` are keywords of the language,
/// so an arc can't be given them.)
pub fn nativeArc(vm: *VM, args: []const value.Value) !value.Value {
    const Opts = struct {
        center: ?value.Value = null,
        r: ?f64 = null,
        radius: ?f64 = null,
        start: ?value.Value = null,
        sweep: ?f64 = null,
        to: ?value.Value = null,
        ccw: bool = true,
        large: bool = false,
    };
    try util.requireOneOf(vm, args, &.{ "r", "radius" }, "arc");
    // ARC has no positional names, so the parse refuses a positional argument
    const opts = (try util.parseKwargsSubset(Opts, ARC.keywords, vm, args, "arc")).opts;
    const radius = opts.r orelse opts.radius orelse return vm.fail(.ArgumentError, "arc needs a radius (r:)", .{});
    try util.requirePositive(vm, radius, "arc", "r");
    const start_val = opts.start orelse return vm.fail(.ArgumentError, "arc needs start:, an angle in degrees with center: and sweep:, or a point with to:", .{});

    if (opts.center) |center_val| {
        if (opts.to != null) return vm.fail(.ArgumentError, "arc takes center: with start: and sweep:, or start: and to:, not both", .{});
        const center = try util.parsePoint(2, vm, center_val, "arc", 0);
        const start = try util.requireNumber(vm, start_val, "arc", "start (degrees)");
        const sweep = opts.sweep orelse return vm.fail(.ArgumentError, "arc with center: needs sweep: (degrees, counter-clockwise when positive)", .{});
        try util.requireFinite(vm, sweep, "arc", "sweep");
        if (sweep == 0) return vm.fail(.ValueError, "arc expects a sweep other than 0", .{});
        if (@abs(sweep) > 360) return vm.fail(.ValueError, "arc sweeps at most a full turn, got {f} degrees", .{value.fmtNumber(@abs(sweep))});
        const segment = path_mod.arcByAngles(center, radius, start, start + sweep);
        return vm.allocatePath(path_mod.pointAt(segment.arc.?, start), &.{segment}, null, null);
    }
    const to_val = opts.to orelse return vm.fail(.ArgumentError, "arc needs center: with start: and sweep:, or start: and to:", .{});
    if (opts.sweep != null) return vm.fail(.ArgumentError, "arc takes center: with start: and sweep:, or start: and to:, not both", .{});
    const from = try util.parsePoint(2, vm, start_val, "arc", 0);
    const to = try util.parsePoint(2, vm, to_val, "arc", 1);
    const segment = path_mod.arcThrough(from, to, radius, opts.ccw, opts.large) orelse {
        return vm.fail(.ValueError, "arc of radius {f} can't reach from [{f}, {f}] to [{f}, {f}]: the points are {f} apart, more than twice the radius, or the same point", .{ value.fmtNumber(radius), value.fmtNumber(from[0]), value.fmtNumber(from[1]), value.fmtNumber(to[0]), value.fmtNumber(to[1]), value.fmtNumber(std.math.hypot(to[0] - from[0], to[1] - from[1])) });
    };
    return vm.allocatePath(from, &.{segment}, null, null);
}

/// `a + b`: the path on from `a`'s end along `b`, which must start there (within the
/// tolerance); `a`'s name and material are the result's.
pub fn join(vm: *VM, a: value.Value, b: value.Value) !value.Value {
    const first = a.asPath();
    const second = b.asPath();
    const end = first.end();
    const tolerance = vm.config().tolerance;
    if (@abs(end[0] - second.start[0]) > tolerance or @abs(end[1] - second.start[1]) > tolerance) {
        return vm.fail(.ValueError, "'+' joins paths where one ends and the next starts: the first ends at [{f}, {f}], the second starts at [{f}, {f}]", .{ value.fmtNumber(end[0]), value.fmtNumber(end[1]), value.fmtNumber(second.start[0]), value.fmtNumber(second.start[1]) });
    }
    const segments = try vm.allocator.alloc(path_mod.Segment, first.segments.len + second.segments.len);
    defer vm.allocator.free(segments);
    @memcpy(segments[0..first.segments.len], first.segments);
    @memcpy(segments[first.segments.len..], second.segments);
    // The second's segments start where the first ends, to the bit
    if (second.segments.len > 0 and first.segments.len > 0) segments[first.segments.len - 1].to = second.start;
    return vm.allocatePath(first.start, segments, first.name, first.material_id);
}

// --- Moves ---

/// The path as `matrix` places it; an uneven scale can't keep an arc, so it is refused.
fn transformed(vm: *VM, receiver: value.Value, matrix: [6]f64, comptime method: []const u8) !value.Value {
    const p = receiver.asPath();
    if (affine2.similarityScale(matrix) == null) {
        for (p.segments) |segment| {
            if (segment.arc != null) return vm.fail(.ValueError, method ++ " can't scale a Path's arcs unevenly (an arc stays an arc): scale it the same in x and y, or close or stroke it first", .{});
        }
    }
    const segments = try vm.allocator.alloc(path_mod.Segment, p.segments.len);
    defer vm.allocator.free(segments);
    for (p.segments, segments) |segment, *out| out.* = segment.transformed(matrix);
    return vm.allocatePath(affine2.apply(matrix, p.start), segments, p.name, p.material_id);
}

pub fn pathTranslate(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(vm, args, 0.0, "translate");
    if (vec[2] != 0.0) return vm.fail(.ValueError, "a Path can only translate in x and y (it lies in the XY plane), got z {f}", .{value.fmtNumber(vec[2])});
    return transformed(vm, receiver, affine2.translation(vec[0], vec[1]), "translate");
}

/// `rotate(a)` in degrees about z, as a Sketch's.
pub fn pathRotate(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    var vec = try util.parseVec3(vm, args, 0.0, "rotate");
    if (util.singleNumber(args)) {
        const angle = vec[0]; // (written straight into `vec`, the aggregate read a cleared x)
        vec = .{ 0.0, 0.0, angle };
    }
    if (vec[0] != 0.0 or vec[1] != 0.0) return vm.fail(.ValueError, "a Path can only rotate about z (it lies in the XY plane), got x {f} and y {f}", .{ value.fmtNumber(vec[0]), value.fmtNumber(vec[1]) });
    return transformed(vm, receiver, affine2.rotation(vec[2]), "rotate");
}

pub fn pathScale(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    var vec = try util.parseVec3(vm, args, 1.0, "scale");
    if (util.singleNumber(args)) vec = @splat(vec[0]);
    for (vec[0..2]) |f| {
        if (!(@abs(f) >= std.math.floatMin(f64))) return vm.fail(.ValueError, "scale factors must be non-zero, got [{f}, {f}]", .{ value.fmtNumber(vec[0]), value.fmtNumber(vec[1]) });
    }
    return transformed(vm, receiver, affine2.scaling(vec[0], vec[1]), "scale");
}

/// `mirror(nx, ny)`: across the line through the origin with that normal, as a Sketch's.
pub fn pathMirror(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(vm, args, 0.0, "mirror");
    try util.requireNonZeroVector(vm, vec, "mirror", "plane normal");
    if (vec[2] != 0.0) return vm.fail(.ValueError, "a Path can only mirror across a line in the XY plane, got a normal with z {f}", .{value.fmtNumber(vec[2])});
    return transformed(vm, receiver, affine2.reflection(vec[0], vec[1]), "mirror");
}

// --- Into a Sketch ---

/// The chords each segment is drawn with under the active resolution (0 for a line): an
/// arc gets its circle's share.
fn chordsOf(vm: *VM, segments: []const path_mod.Segment) ![]u32 {
    const chords = try vm.allocator.alloc(u32, segments.len);
    for (segments, chords) |segment, *count| {
        count.* = if (segment.arc) |arc| turnShare(@intCast(util.autoSegments(vm, arc.radius)), segment.angle / (2 * std.math.pi)) else 0;
    }
    return chords;
}

/// `close`: the Sketch the path encloses, its end joined straight back to its start; its
/// arcs stay known to a drawing.
pub fn pathClose(vm: *VM, receiver: value.Value) !value.Value {
    const p = receiver.asPath();
    if (p.segments.len < 2) return vm.fail(.ValueError, "close needs a Path of at least 2 segments to enclose anything, got {d}", .{p.segments.len});
    const chords = try chordsOf(vm, p.segments);
    defer vm.allocator.free(chords);
    return vm.allocateCrossSection(try vm.dag_builder.addClosedPath(p.start, p.segments, chords));
}

/// `stroke(width, cap:, segments:)`: the Sketch of the path given a width, `cap:` its
/// ends (`:round`, the default, `:butt` or `:square`); the joins between segments are
/// round, drawn with `segments:` or the resolution's count. Built from what the kernel
/// has: a rectangle per chord and a circle per joint, united.
pub fn pathStroke(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const Opts = struct { width: f64 = 1.0, cap: Cap = .round, segments: i32 = 0 };
    const pos = util.positionalArgs(args);
    var base = Opts{};
    if (pos.len > 0) base.width = try util.requireNumber(vm, pos[0], "stroke", "width");
    const opts = (try util.parseKwargsOver(Opts, base, STROKE.keywords, vm, args, "stroke")).opts;
    try util.requirePositive(vm, opts.width, "stroke", "width");
    try util.requireSegmentCount(vm, opts.segments, "segments");
    const half = opts.width / 2.0;

    const p = receiver.asPath();
    const chords = try chordsOf(vm, p.segments);
    defer vm.allocator.free(chords);
    var spine: std.ArrayList([2]f64) = .empty;
    defer spine.deinit(vm.allocator);
    try path_mod.appendPoints(vm.allocator, &spine, p.start, p.segments, chords, null);

    var pieces: std.ArrayList(u32) = .empty;
    defer pieces.deinit(vm.allocator);
    const b = &vm.dag_builder;
    const cap_segments = if (opts.segments > 0) opts.segments else util.autoSegments(vm, half);
    for (spine.items[0 .. spine.items.len - 1], spine.items[1..], 0..) |a, c, i| {
        // The rectangle around the chord, extended past a square-capped end
        var from = a;
        var to = c;
        const dx = c[0] - a[0];
        const dy = c[1] - a[1];
        const len = std.math.hypot(dx, dy);
        const ux = dx / len;
        const uy = dy / len;
        if (opts.cap == .square and i == 0) from = .{ a[0] - ux * half, a[1] - uy * half };
        if (opts.cap == .square and i == spine.items.len - 2) to = .{ c[0] + ux * half, c[1] + uy * half };
        const nx = -uy * half;
        const ny = ux * half;
        var corners = [4][2]f64{ .{ from[0] + nx, from[1] + ny }, .{ from[0] - nx, from[1] - ny }, .{ to[0] - nx, to[1] - ny }, .{ to[0] + nx, to[1] + ny } };
        try pieces.append(vm.allocator, try b.addPolygon(&corners));
        // A round joint at every inner vertex, and at the ends of a round-capped path
        const inner = i + 1 < spine.items.len - 1;
        if (inner or opts.cap == .round) try pieces.append(vm.allocator, try circleAt(b, c, half, cap_segments));
    }
    if (opts.cap == .round) try pieces.append(vm.allocator, try circleAt(b, spine.items[0], half, cap_segments));
    return vm.allocateCrossSection(try b.addBalancedChain(.cs_union_op, pieces.items));
}

fn circleAt(b: *@import("../vm/dag.zig").DAGBuilder, center: [2]f64, radius: f64, segments: i32) !u32 {
    const circle = try b.addCircle(radius, segments);
    return b.addCrossSectionTransform(circle, .{ 1, 0, 0, 1, center[0], center[1] });
}

// --- Labels ---

/// `named(name)`: the name a drawing gives it.
pub fn pathNamed(vm: *VM, receiver: value.Value, name: []const u8) !value.Value {
    if (std.mem.trim(u8, name, &std.ascii.whitespace).len == 0) return vm.fail(.ValueError, "named expects a name, got \"{s}\"", .{name});
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const name_obj = try vm.gc.allocateString(vm, name);
    vm.push(value.Value.initObj(&name_obj.obj));
    const p = receiver.asPath();
    return vm.allocatePath(p.start, p.segments, name_obj, p.material_id);
}

/// The path with material `material_id` (materials.zig made it).
pub fn withMaterial(vm: *VM, receiver: value.Value, material_id: u32) !value.Value {
    const p = receiver.asPath();
    return vm.allocatePath(p.start, p.segments, p.name, material_id);
}

// --- Measures ---

/// `start` and `end`: the path's ends as [x, y].
pub fn pathStart(vm: *VM, receiver: value.Value) !value.Value {
    return pointArray(vm, receiver.asPath().start);
}

pub fn pathEnd(vm: *VM, receiver: value.Value) !value.Value {
    return pointArray(vm, receiver.asPath().end());
}

fn pointArray(vm: *VM, p: [2]f64) !value.Value {
    const arr = try vm.gc.allocateArray(vm);
    const val = value.Value.initObj(&arr.obj);
    vm.push(val);
    defer _ = vm.pop();
    try arr.items.append(vm.gc.trackingAllocator(), value.Value.initNumber(p[0]));
    try arr.items.append(vm.gc.trackingAllocator(), value.Value.initNumber(p[1]));
    return val;
}

/// `length`: along the path, in mm.
pub fn pathLength(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    const p = receiver.asPath();
    var total: f64 = 0;
    var from = p.start;
    for (p.segments) |segment| {
        total += segment.length(from);
        from = segment.to;
    }
    return value.Value.initNumber(total);
}
