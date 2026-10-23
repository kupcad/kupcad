//! The methods that make a solid from a sketch: `extrude`, `revolve`, `helix`, `loft` and
//! `sweep`,
//! each checking its arguments and adding a DAG node. Exported through methods.zig. A
//! sweep that turns the profile (a revolve, a twist) gets its share of the segments a full
//! turn gets at the profile's farthest point from the axis, as OpenSCAD's rotate_extrude
//! and linear_extrude do (`segments:` is per full turn; `slices:` the count itself).

const std = @import("std");
const arguments = @import("../arguments.zig");
const sig = @import("../method_signatures.zig");
const kernel = @import("../../kernel/kernel.zig");
const value = @import("../../core/value.zig");
const turnShare = @import("../../core/engine_config.zig").turnShare;
const error_kind = @import("../../vm/error_kind.zig");
const VM = @import("../../vm/vm.zig").VM;
const path_mod = @import("../../core/path.zig");
const vec3 = @import("../../core/vec3.zig");
const limits = @import("../../core/limits.zig");

/// The axis a sweep turns the profile about: revolve's y, a twist's z.
const Axis = enum { y, z };

/// A turn (radians) this small at a path's joint is none: no corner to fill.
const STRAIGHT_TURN = 1e-9;
/// A direction this close to straight up or down (its z) starts a sweep's profile with its
/// y along y, as up can't be across it.
const VERTICAL_SLACK = 1e-9;

pub fn meshExtrude(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return arguments.notDefinedFor(vm, "extrude", receiver);

    const ExtrudeOpts = struct {
        h: f64 = 1.0,
        slices: i32 = 0,
        twist: f64 = 0.0,
        scale_x: f64 = 1.0,
        scale_y: f64 = 1.0,
        scale: ?f64 = null,
        center: bool = false,
    };

    // NaN/inf sweep parameters propagate into every generated vertex: requireNumber
    // and parseKwargs reject them along with non-numbers.
    const pos = arguments.positionalArgs(args);
    var base = ExtrudeOpts{};
    if (pos.len > 0) base.h = try arguments.requireNumber(vm, pos[0], "extrude", "h");
    var opts = (try arguments.parseKwargsOver(ExtrudeOpts, base, sig.EXTRUDE.keywords, vm, args, "extrude")).opts;
    if (opts.scale) |s| {
        opts.scale_x = s;
        opts.scale_y = s;
    }

    try arguments.requireSegmentCount(vm, opts.slices, "slices");
    const slices = try twistSlices(vm, receiver, opts.slices, opts.twist);

    var new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, opts.h, slices, opts.twist, opts.scale_x, opts.scale_y);

    if (opts.center) {
        new_idx = try vm.dag_builder.addTranslate(new_idx, 0.0, 0.0, -opts.h / 2.0);
    }
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshRevolve(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return arguments.notDefinedFor(vm, "revolve", receiver);
    const RevolveOpts = struct { deg: f64 = 360.0, angle: ?f64 = null, segments: i32 = 0 };
    const pos = arguments.positionalArgs(args);
    var base = RevolveOpts{};
    if (pos.len > 0) base.deg = try arguments.requireNumber(vm, pos[0], "revolve", "deg");
    try arguments.requireOneOf(vm, args, &.{ "deg", "angle" }, "revolve");
    var opts = (try arguments.parseKwargsOver(RevolveOpts, base, sig.REVOLVE.keywords, vm, args, "revolve")).opts;
    // angle: is deg: by the name repeat_polar's and rotate's angles have
    if (opts.angle) |angle| opts.deg = angle;
    try arguments.requireSegmentCount(vm, opts.segments, "segments");

    // A full turn's segments, the script's or the resolution's at the profile's farthest
    // x (it used to be assumed 10 mm, whatever the profile's size), and the sweep its
    // share: the kernel divides the sweep itself into the count it is given. A sweep past
    // a full turn is a full turn.
    const per_turn = if (opts.segments > 0) opts.segments else try perTurnAbout(vm, receiver, .y, &.{.revolve}) orelse
        return vm.fail(.ValueError, "revolve: an empty sketch has no profile", .{});
    const segments: i32 = @intCast(turnShare(@intCast(per_turn), @min(@abs(opts.deg), 360.0) / 360.0));

    const new_idx = try vm.dag_builder.addRevolve(receiver.asCrossSection().dag_idx, segments, opts.deg);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshHelix(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return arguments.notDefinedFor(vm, "helix", receiver);

    const HelixOpts = struct { h: f64 = 10.0, twist: f64 = 360.0, pitch: ?f64 = null, turns: ?f64 = null, slices: i32 = 0 };
    const pos = arguments.positionalArgs(args);
    var base = HelixOpts{};
    if (pos.len > 0) base.h = try arguments.requireNumber(vm, pos[0], "helix", "h");
    if (pos.len > 1) base.twist = try arguments.requireNumber(vm, pos[1], "helix", "twist");
    if (pos.len > 2) base.slices = try arguments.checkedInt(i32, vm, try arguments.requireNumber(vm, pos[2], "helix", "slices"), "slices");
    inline for (.{ &.{ "twist", "pitch" }, &.{ "twist", "turns" }, &.{ "pitch", "turns" } }) |pair| try arguments.requireOneOf(vm, args, pair, "helix");
    var opts = (try arguments.parseKwargsOver(HelixOpts, base, sig.HELIX.keywords, vm, args, "helix")).opts;
    if ((opts.pitch != null or opts.turns != null) and pos.len > 1) return vm.fail(.ArgumentError, "helix takes its twist positionally or as pitch: or turns:, not both", .{});
    // How far it rises per turn, or how many turns it makes over h: the twist they mean
    if (opts.pitch) |pitch| {
        try arguments.requirePositive(vm, pitch, "helix", "pitch");
        opts.twist = opts.h / pitch * 360.0;
    }
    if (opts.turns) |turns| {
        try arguments.requireFinite(vm, turns, "helix", "turns");
        opts.twist = turns * 360.0;
    }

    try arguments.requireSegmentCount(vm, opts.slices, "slices");
    const slices = try twistSlices(vm, receiver, opts.slices, opts.twist);

    // Re-use DAG's extrude with twist applied natively
    const new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, opts.h, slices, opts.twist, 1.0, 1.0);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// `profile.sweep(path, segments:)`: the Solid the Sketch sweeps out along `path`, a Path
/// or an Array of points ([x, y] or [x, y, z]: a polyline in space, such as a helix's
/// points), with the profile's origin on it, its x across it and its y up. A line extrudes
/// the profile along it, a Path's arc revolves it about the arc's centre, and where the
/// path turns at a corner the profile turns about the corner's bend on its outer side,
/// filling the gap round, as a stroke's joints are; the pieces are united. The profile
/// starts with its y up (z) as far as the path's first direction allows (along y for a path
/// that starts straight up or down) and its x to the path's left, and each corner turns it
/// by the corner's own turn, so it doesn't twist about the path. A closed path (its end on
/// its start) has a corner there too. `segments:` is per full turn, as revolve's, the
/// resolution's at the farthest the profile reaches from the turn's axis without.
pub fn meshSweep(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return arguments.notDefinedFor(vm, "sweep", receiver);
    const Opts = struct { path: ?value.Value = null, segments: i32 = 0 };
    const pos = arguments.positionalArgs(args);
    const opts = (try arguments.parseKwargsOver(Opts, .{ .path = if (pos.len > 0) pos[0] else null }, sig.SWEEP.keywords, vm, args, "sweep")).opts;
    const path_val = opts.path orelse return vm.fail(.ArgumentError, "sweep needs the Path to sweep along: sweep(path)", .{});
    if (!path_val.isPath() and !path_val.isArray()) return vm.fail(.TypeError, "sweep expects a Path or an Array of points to sweep along, got {s}", .{arguments.typeName(vm, path_val)});
    try arguments.requireSegmentCount(vm, opts.segments, "segments");

    // The profile's outline, measured now: how far it reaches each way decides an arc's
    // reach and a corner's outer side
    const profile = try vm.ensureConcreteCrossSection(receiver);
    for ([_]kernel.Feature{ .extrude, .revolve, .sketch_contours }) |op| try vm.requireFeature(profile.engine, op);
    const outline = kernel.crossSectionContours(vm.allocator, profile) orelse return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"the profile's outline"});
    defer outline.deinit(vm.allocator);
    if (outline.points.len == 0) return vm.fail(.ValueError, "sweep: an empty sketch has no profile", .{});
    const sweep = Sweep{ .vm = vm, .profile = receiver.asCrossSection().dag_idx, .points = outline.points, .per_turn = opts.segments };

    var pieces: std.ArrayList(u32) = .empty;
    defer pieces.deinit(vm.allocator);
    if (path_val.isPath()) try sweep.alongPath(&pieces, path_val.asPath()) else try sweep.alongPoints(&pieces, path_val.asArray().items.items);
    return try vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addBalancedChain(.union_op, pieces.items) });
}

/// The profile's directions in space: its x along `u`, its y along `v`, swept along u × v.
const Frame = struct {
    u: [3]f64,
    v: [3]f64,

    /// The frame for a path leaving along `t` (a unit vector): `v` as near up (z) as `t`
    /// allows, or y for a path straight up or down, and `u` to the path's left.
    fn along(t: [3]f64) Frame {
        const up: [3]f64 = if (@abs(t[2]) > 1 - VERTICAL_SLACK) .{ 0, 1, 0 } else .{ 0, 0, 1 };
        const v = vec3.normalize(vec3.sub(up, vec3.scale(t, vec3.dot(up, t))));
        return .{ .u = vec3.cross(v, t), .v = v };
    }

    /// The frame turned `angle` radians about the unit `axis` (Rodrigues' rotation).
    fn turned(self: Frame, axis: [3]f64, angle: f64) Frame {
        return .{ .u = rotated(self.u, axis, angle), .v = rotated(self.v, axis, angle) };
    }
};

fn rotated(w: [3]f64, axis: [3]f64, angle: f64) [3]f64 {
    const c = @cos(angle);
    const s = @sin(angle);
    return vec3.add(vec3.add(vec3.scale(w, c), vec3.scale(vec3.cross(axis, w), s)), vec3.scale(axis, vec3.dot(axis, w) * (1 - c)));
}

/// A point of the XY plane in space.
fn flat(p: [2]f64) [3]f64 {
    return .{ p[0], p[1], 0 };
}

/// The pieces of a sweep: the profile (a graph node) and its outline's points, which say
/// how far it reaches each way.
const Sweep = struct {
    vm: *VM,
    profile: u32,
    points: []const [2]f64,
    /// Segments a full turn, or 0 for the resolution's
    per_turn: i32,

    /// Along a Path in the XY plane: its lines and corners as along points, its arcs exact.
    fn alongPath(self: Sweep, pieces: *std.ArrayList(u32), p: *const value.ObjPath) !void {
        const end = p.end();
        const closed = std.math.hypot(end[0] - p.start[0], end[1] - p.start[1]) <= self.vm.config().tolerance;
        var from = p.start;
        for (p.segments, 0..) |segment, k| {
            if (segment.cubic != null) return self.vm.fail(.ValueError, "sweep follows lines and arcs, and segment {d} of the path is a curve", .{k});
            const t_in = flat(path_mod.startTangent(from, segment));
            try pieces.append(self.vm.allocator, if (segment.arc) |arc| try self.arcPiece(from, segment, arc, k) else try self.linePiece(flat(from), flat(segment.to), Frame.along(t_in)));
            const next = if (k + 1 < p.segments.len) p.segments[k + 1] else if (closed) p.segments[0] else null;
            if (next) |n| {
                // In the plane, the profile stands up from the path at every point
                const t1 = flat(path_mod.endTangent(from, &.{segment}).?);
                const turn = try self.corner(flat(segment.to), t1, flat(path_mod.startTangent(segment.to, n)), Frame.along(t1));
                if (turn.piece) |c| try pieces.append(self.vm.allocator, c);
            }
            from = segment.to;
        }
    }

    /// Along a polyline of points in space, the profile's frame carried through each
    /// corner by its turn.
    fn alongPoints(self: Sweep, pieces: *std.ArrayList(u32), items: []const value.Value) !void {
        const vm = self.vm;
        if (items.len < 2) return vm.fail(.ValueError, "sweep needs at least 2 points to follow, got {d}", .{items.len});
        if (items.len > limits.MAX_SWEEP_POINTS) return vm.fail(.ValueError, "sweep follows at most {d} points, got {d}", .{ limits.MAX_SWEEP_POINTS, items.len });
        const points = try vm.allocator.alloc([3]f64, items.len);
        defer vm.allocator.free(points);
        for (items, points, 0..) |item, *point, i| {
            point.* = try arguments.parseNumberArray(3, vm, item, .{ .method = "sweep", .name = "point", .row = i }, 2, 0.0);
            if (i > 0 and std.meta.eql(point.*, points[i - 1])) {
                return vm.fail(.ValueError, "sweep point {d} repeats the one before it, [{f}, {f}, {f}]", .{ i, value.fmtNumber(point[0]), value.fmtNumber(point[1]), value.fmtNumber(point[2]) });
            }
        }
        const segments = points.len - 1;
        const closed = segments >= 2 and std.math.sqrt(distanceSq(points[segments], points[0])) <= vm.config().tolerance;
        var frame = Frame.along(direction(points[0], points[1]));
        for (0..segments) |k| {
            try pieces.append(vm.allocator, try self.linePiece(points[k], points[k + 1], frame));
            if (k + 1 == segments and !closed) break;
            const next = (k + 1) % segments;
            const turn = try self.corner(points[k + 1], direction(points[k], points[k + 1]), direction(points[next], points[next + 1]), frame);
            if (turn.piece) |c| try pieces.append(vm.allocator, c);
            frame = turn.frame;
        }
    }

    /// The most the profile reaches along its own direction (`dx`, `dy`): the greatest
    /// x dx + y dy of its outline's points.
    fn reach(self: Sweep, dx: f64, dy: f64) f64 {
        var most = -std.math.inf(f64);
        for (self.points) |p| most = @max(most, p[0] * dx + p[1] * dy);
        return most;
    }

    /// The profile extruded from `a` to `b`: its x along the frame's u, its y along v,
    /// its extrusion along the line.
    fn linePiece(self: Sweep, a: [3]f64, b: [3]f64, frame: Frame) !u32 {
        const len = std.math.sqrt(distanceSq(a, b));
        const t = direction(a, b);
        const dag = &self.vm.dag_builder;
        const solid = try dag.addExtrude(self.profile, len, 0, 0, 1, 1);
        const u = frame.u;
        const v = frame.v;
        return dag.addTransformMatrix(solid, .{ u[0], u[1], u[2], v[0], v[1], v[2], t[0], t[1], t[2], a[0], a[1], a[2] });
    }

    /// The profile revolved about the arc's centre, through its sweep: at the radius less
    /// its x on a counter-clockwise arc (the left is inward), plus it on a clockwise one.
    fn arcPiece(self: Sweep, from: [2]f64, segment: path_mod.Segment, arc: path_mod.Arc, k: usize) !u32 {
        const left = self.reach(1, 0);
        const right = self.reach(-1, 0);
        const inward = if (segment.ccw) left else right;
        if (inward >= arc.radius) {
            return self.vm.fail(.ValueError, "sweep: the profile reaches {f} to the path's {s}, as far as the centre of segment {d}'s arc of radius {f} or past it, where it would cross itself", .{ value.fmtNumber(inward), if (segment.ccw) "left" else "right", k, value.fmtNumber(arc.radius) });
        }
        const dag = &self.vm.dag_builder;
        const placed = try dag.addCrossSectionTransform(self.profile, if (segment.ccw) .{ -1, 0, 0, 1, arc.radius, 0 } else .{ 1, 0, 0, 1, arc.radius, 0 });
        const degrees = segment.angle * 180 / std.math.pi;
        const solid = try dag.addRevolve(placed, try self.segmentsFor(arc.radius + @max(left, right), degrees), degrees);
        // Revolved counter-clockwise from +x: turned to the arc's start, or for a clockwise
        // arc, to its end, from which it runs counter-clockwise back to the start
        const start = std.math.atan2(from[1] - arc.center[1], from[0] - arc.center[0]);
        const angle = if (segment.ccw) start else start - segment.angle;
        const c = @cos(angle);
        const s = @sin(angle);
        return dag.addTransformMatrix(solid, .{ c, s, 0, -s, c, 0, 0, 0, 1, arc.center[0], arc.center[1], 0 });
    }

    /// The corner at `p` where the path, coming in along `t1` with the profile in `frame`,
    /// leaves along `t2`: the profile's outer side turned about the bend's axis through `p`
    /// by the turn (no piece where the path goes on straight or the profile has no outer
    /// side), and the frame turned with it. A path that doubles back turns about the
    /// profile's y.
    fn corner(self: Sweep, p: [3]f64, t1: [3]f64, t2: [3]f64, frame: Frame) !struct { piece: ?u32, frame: Frame } {
        const bend = vec3.cross(t1, t2);
        const sin = std.math.sqrt(vec3.dot(bend, bend));
        const angle = std.math.atan2(sin, vec3.dot(t1, t2));
        if (angle <= STRAIGHT_TURN) return .{ .piece = null, .frame = frame };
        const axis = if (sin > STRAIGHT_TURN) vec3.scale(bend, 1 / sin) else frame.v;
        // Away from the bend's inside, in its plane: where the gap opens
        const outer = vec3.scale(vec3.cross(axis, t1), -1);
        const turned = frame.turned(axis, angle);
        // The profile's coordinates along the outer direction and the axis
        const r = [2]f64{ vec3.dot(frame.u, outer), vec3.dot(frame.v, outer) };
        const h = [2]f64{ vec3.dot(frame.u, axis), vec3.dot(frame.v, axis) };
        const reach_out = self.reach(r[0], r[1]);
        if (!(reach_out > 0)) return .{ .piece = null, .frame = turned };
        const dag = &self.vm.dag_builder;
        // The kernel's revolve keeps the profile's positive x: its outer side's
        const facing = try dag.addCrossSectionTransform(self.profile, .{ r[0], h[0], r[1], h[1], 0, 0 });
        const degrees = angle * 180 / std.math.pi;
        const solid = try dag.addRevolve(facing, try self.segmentsFor(reach_out, degrees), degrees);
        // The revolve's x out, its y along the way in (where its turn heads), its z the axis
        const piece = try dag.addTransformMatrix(solid, .{ outer[0], outer[1], outer[2], t1[0], t1[1], t1[2], axis[0], axis[1], axis[2], p[0], p[1], p[2] });
        return .{ .piece = piece, .frame = turned };
    }

    /// The segments a revolve through `degrees` gets at `radius`: its share of a full turn's.
    fn segmentsFor(self: Sweep, radius: f64, degrees: f64) !i32 {
        const per_turn = if (self.per_turn > 0) self.per_turn else arguments.autoSegments(self.vm, radius);
        return @intCast(turnShare(@intCast(per_turn), degrees / 360.0));
    }
};

fn distanceSq(a: [3]f64, b: [3]f64) f64 {
    const d = vec3.sub(b, a);
    return vec3.dot(d, d);
}

/// The unit vector from `a` to `b`, two different points.
fn direction(a: [3]f64, b: [3]f64) [3]f64 {
    return vec3.normalize(vec3.sub(b, a));
}

/// The slices a twist of `twist_degrees` is cut into: the script's `slices`, or with none
/// (0), the twist's share of a full turn at the profile's farthest point from the z axis.
/// An untwisted extrusion needs none between its ends, and an empty profile has nothing
/// to cut.
fn twistSlices(vm: *VM, receiver: value.Value, slices: i32, twist_degrees: f64) !i32 {
    if (slices > 0 or twist_degrees == 0) return slices;
    const per_turn = try perTurnAbout(vm, receiver, .z, &.{ .extrude, .extrude_twist }) orelse return slices;
    return @intCast(turnShare(@intCast(per_turn), twist_degrees / 360.0));
}

/// The segments the active resolution gives a full turn about `axis` at the profile's
/// farthest point from it, or null for an empty profile. Measured now: the profile is
/// built here, on an engine that can do the sweep (`ops`, in the order the evaluator
/// checks them) and trace its outline.
fn perTurnAbout(vm: *VM, receiver: value.Value, axis: Axis, ops: []const kernel.Feature) !?i32 {
    const profile = try vm.ensureConcreteCrossSection(receiver);
    for (ops) |op| try vm.requireFeature(profile.engine, op);
    try vm.requireFeature(profile.engine, .sketch_contours);
    const contours = kernel.crossSectionContours(vm.allocator, profile) orelse return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"the profile's outline"});
    defer contours.deinit(vm.allocator);
    if (contours.points.len == 0) return null;
    var radius: f64 = 0;
    for (contours.points) |p| radius = @max(radius, switch (axis) {
        .y => @abs(p[0]),
        .z => std.math.hypot(p[0], p[1]),
    });
    return arguments.autoSegments(vm, radius);
}

/// `profile.loft(target, height)`: the Solid from the profile at z = 0 to `target` at
/// `height`; `profile.loft([s1, s2, ...], [h1, h2, ...])` through each section at its
/// height above the base (rising), a loft from each to the next. Convex profiles' loft is
/// their hull; a concave one's the ruled surface between them (core/loft.zig).
pub fn meshLoft(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return arguments.notDefinedFor(vm, "loft", receiver);
    if (args.len < 2) {
        return vm.fail(.ArgumentError, "loft requires a target CrossSection and a z-height", .{});
    }
    const base = receiver.asCrossSection().dag_idx;
    if (args[0].isArray()) return loftThrough(vm, base, args[0].asArray().items.items, args[1]);
    if (!args[0].isCrossSection()) {
        return vm.fail(.TypeError, "loft expects a CrossSection for the target, got {s}", .{arguments.typeName(vm, args[0])});
    }

    const cs_top = args[0].asCrossSection();
    const height = try arguments.requireNumber(vm, args[1], "loft", "height");

    const dag_idx = try vm.dag_builder.addLoft(base, cs_top.dag_idx, height);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

/// The loft from `base` through `sections`, each at its height of `heights_val` (an
/// Array of as many, rising from the base): the lofts from each section to the next,
/// united.
fn loftThrough(vm: *VM, base: u32, sections: []const value.Value, heights_val: value.Value) !value.Value {
    const heights = try arguments.requireArray(vm, heights_val, "loft", "heights");
    if (sections.len == 0 or heights.len != sections.len) {
        return vm.fail(.ArgumentError, "loft takes its sections as an Array and their heights as an Array of as many, got {d} section{s} and {d} height{s}", .{ sections.len, if (sections.len == 1) "" else "s", heights.len, if (heights.len == 1) "" else "s" });
    }
    const dag = &vm.dag_builder;
    var pieces: std.ArrayList(u32) = .empty;
    defer pieces.deinit(vm.allocator);
    var from = base;
    var z: f64 = 0;
    for (sections, heights, 0..) |section, height_val, i| {
        if (!section.isCrossSection()) return vm.fail(.TypeError, "loft expects a CrossSection at index {d} of the sections, got {s}", .{ i, arguments.typeName(vm, section) });
        const height = try arguments.requireNumber(vm, height_val, "loft", "a height");
        if (!(height > z)) return vm.fail(.ValueError, "loft's heights rise from the base: height {d} is {f}, not above {f}", .{ i, value.fmtNumber(height), value.fmtNumber(z) });
        const step = try dag.addLoft(from, section.asCrossSection().dag_idx, height - z);
        try pieces.append(vm.allocator, if (z == 0) step else try dag.addTranslate(step, 0, 0, z));
        from = section.asCrossSection().dag_idx;
        z = height;
    }
    return try vm.allocateGeometry(.{ .symbolic = try dag.addBalancedChain(.union_op, pieces.items) });
}
