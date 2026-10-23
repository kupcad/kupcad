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
const DAGBuilder = @import("../../vm/dag.zig").DAGBuilder;

/// The axis a sweep turns the profile about: revolve's y, a twist's z.
const Axis = enum { y, z };

/// A turn (radians) this small at a path's joint is none: no corner to fill.
const STRAIGHT_TURN = 1e-9;

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

/// `profile.sweep(path, segments:)`: the Solid the Sketch sweeps out along the Path,
/// standing on it: the profile's origin on the path, its x across it (to its left), its y
/// up (z). A line extrudes the profile along it, an arc revolves it about the arc's centre,
/// and where the path turns at a corner the profile turns about the corner on its outer
/// side, filling the gap round, as a stroke's joints are; the pieces are united. A closed
/// path (its end on its start) has a corner there too. `segments:` is per full turn, as
/// revolve's, the resolution's at the farthest the profile reaches from the centre without.
pub fn meshSweep(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return arguments.notDefinedFor(vm, "sweep", receiver);
    const Opts = struct { path: ?value.Value = null, segments: i32 = 0 };
    const pos = arguments.positionalArgs(args);
    const opts = (try arguments.parseKwargsOver(Opts, .{ .path = if (pos.len > 0) pos[0] else null }, sig.SWEEP.keywords, vm, args, "sweep")).opts;
    const path_val = opts.path orelse return vm.fail(.ArgumentError, "sweep needs the Path to sweep along: sweep(path)", .{});
    if (!path_val.isPath()) return vm.fail(.TypeError, "sweep expects a Path to sweep along, got {s}", .{arguments.typeName(vm, path_val)});
    try arguments.requireSegmentCount(vm, opts.segments, "segments");
    const p = path_val.asPath();

    // How far the profile reaches to the path's left (+x) and right (-x), measured now
    const profile = try vm.ensureConcreteCrossSection(receiver);
    for ([_]kernel.Feature{ .extrude, .revolve, .sketch_measure }) |op| try vm.requireFeature(profile.engine, op);
    const bounds = kernel.crossSectionBounds(profile) orelse return vm.fail(.ValueError, "sweep: an empty sketch has no profile", .{});
    const sweep = Sweep{ .vm = vm, .profile = receiver.asCrossSection().dag_idx, .left = bounds.max[0], .right = -bounds.min[0], .per_turn = opts.segments };

    var pieces: std.ArrayList(u32) = .empty;
    defer pieces.deinit(vm.allocator);
    const end = p.end();
    const closed = std.math.hypot(end[0] - p.start[0], end[1] - p.start[1]) <= vm.config().tolerance;
    var from = p.start;
    for (p.segments, 0..) |segment, k| {
        if (segment.cubic != null) return vm.fail(.ValueError, "sweep follows lines and arcs, and segment {d} of the path is a curve", .{k});
        try pieces.append(vm.allocator, if (segment.arc) |arc| try sweep.arcPiece(from, segment, arc, k) else try sweep.linePiece(from, segment.to));
        const next = if (k + 1 < p.segments.len) p.segments[k + 1] else if (closed) p.segments[0] else null;
        if (next) |n| {
            if (try sweep.cornerPiece(segment.to, path_mod.endTangent(from, &.{segment}).?, path_mod.startTangent(segment.to, n))) |corner| try pieces.append(vm.allocator, corner);
        }
        from = segment.to;
    }
    return try vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addBalancedChain(.union_op, pieces.items) });
}

/// The pieces of a sweep: the profile (a graph node) and how far it reaches to either
/// side of the path.
const Sweep = struct {
    vm: *VM,
    profile: u32,
    left: f64,
    right: f64,
    /// Segments a full turn, or 0 for the resolution's
    per_turn: i32,

    /// The profile extruded from `a` to `b`: its x along the line's left, its y along z,
    /// its extrusion along the line.
    fn linePiece(self: Sweep, a: [2]f64, b: [2]f64) !u32 {
        const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
        const t = [2]f64{ (b[0] - a[0]) / len, (b[1] - a[1]) / len };
        const dag = &self.vm.dag_builder;
        const solid = try dag.addExtrude(self.profile, len, 0, 0, 1, 1);
        return dag.addTransformMatrix(solid, .{ -t[1], t[0], 0, 0, 0, 1, t[0], t[1], 0, a[0], a[1], 0 });
    }

    /// The profile revolved about the arc's centre, through its sweep: at the radius less
    /// its x on a counter-clockwise arc (the left is inward), plus it on a clockwise one.
    fn arcPiece(self: Sweep, from: [2]f64, segment: path_mod.Segment, arc: path_mod.Arc, k: usize) !u32 {
        const inward = if (segment.ccw) self.left else self.right;
        if (inward >= arc.radius) {
            return self.vm.fail(.ValueError, "sweep: the profile reaches {f} to the path's {s}, as far as the centre of segment {d}'s arc of radius {f} or past it, where it would cross itself", .{ value.fmtNumber(inward), if (segment.ccw) "left" else "right", k, value.fmtNumber(arc.radius) });
        }
        const dag = &self.vm.dag_builder;
        const placed = try dag.addCrossSectionTransform(self.profile, if (segment.ccw) .{ -1, 0, 0, 1, arc.radius, 0 } else .{ 1, 0, 0, 1, arc.radius, 0 });
        const degrees = segment.angle * 180 / std.math.pi;
        const solid = try dag.addRevolve(placed, try self.segmentsFor(arc.radius + @max(self.left, self.right), degrees), degrees);
        // Revolved counter-clockwise from +x: turned to the arc's start, or for a clockwise
        // arc, to its end, from which it runs counter-clockwise back to the start
        const start = std.math.atan2(from[1] - arc.center[1], from[0] - arc.center[0]);
        return placedAbout(dag, solid, if (segment.ccw) start else start - segment.angle, arc.center);
    }

    /// The corner where the path, coming in along `t1`, leaves along `t2` at `p`: the
    /// profile's outer side (its right on a left turn) turned about the corner through the
    /// turn; null where the path goes on straight or the profile has no outer side.
    fn cornerPiece(self: Sweep, p: [2]f64, t1: [2]f64, t2: [2]f64) !?u32 {
        const turn = std.math.atan2(t1[0] * t2[1] - t1[1] * t2[0], t1[0] * t2[0] + t1[1] * t2[1]);
        if (@abs(turn) <= STRAIGHT_TURN) return null;
        const left_turn = turn > 0;
        const outer = if (left_turn) self.right else self.left;
        if (!(outer > 0)) return null;
        const dag = &self.vm.dag_builder;
        // The kernel's revolve keeps the profile's positive x: the outer side's
        const outward = if (left_turn) try dag.addCrossSectionTransform(self.profile, .{ -1, 0, 0, 1, 0, 0 }) else self.profile;
        const degrees = @abs(turn) * 180 / std.math.pi;
        const solid = try dag.addRevolve(outward, try self.segmentsFor(outer, degrees), degrees);
        // From the outer side of the way in (a left turn's right of t1) round to the way
        // out's; a right turn's runs from t2's left back to t1's
        const from_dir: [2]f64 = if (left_turn) .{ t1[1], -t1[0] } else .{ -t2[1], t2[0] };
        return try placedAbout(dag, solid, std.math.atan2(from_dir[1], from_dir[0]), p);
    }

    /// The segments a revolve through `degrees` gets at `radius`: its share of a full turn's.
    fn segmentsFor(self: Sweep, radius: f64, degrees: f64) !i32 {
        const per_turn = if (self.per_turn > 0) self.per_turn else arguments.autoSegments(self.vm, radius);
        return @intCast(turnShare(@intCast(per_turn), degrees / 360.0));
    }
};

/// `solid` turned `angle` radians about z and moved to `center`.
fn placedAbout(dag: *DAGBuilder, solid: u32, angle: f64, center: [2]f64) !u32 {
    const c = @cos(angle);
    const s = @sin(angle);
    return dag.addTransformMatrix(solid, .{ c, s, 0, -s, c, 0, 0, 0, 1, center[0], center[1], 0 });
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

pub fn meshLoft(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return arguments.notDefinedFor(vm, "loft", receiver);
    if (args.len < 2) {
        return vm.fail(.ArgumentError, "loft requires a target CrossSection and a z-height", .{});
    }
    if (!args[0].isCrossSection()) {
        return vm.fail(.TypeError, "loft expects a CrossSection for the target, got {s}", .{arguments.typeName(vm, args[0])});
    }

    const cs_top = args[0].asCrossSection();
    const height = try arguments.requireNumber(vm, args[1], "loft", "height");

    const dag_idx = try vm.dag_builder.addLoft(receiver.asCrossSection().dag_idx, cs_top.dag_idx, height);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}
