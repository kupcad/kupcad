//! The methods that make a solid from a sketch: `extrude`, `revolve`, `helix` and `loft`,
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

/// The axis a sweep turns the profile about: revolve's y, a twist's z.
const Axis = enum { y, z };

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
    const RevolveOpts = struct { deg: f64 = 360.0, segments: i32 = 0 };
    const pos = arguments.positionalArgs(args);
    var base = RevolveOpts{};
    if (pos.len > 0) base.deg = try arguments.requireNumber(vm, pos[0], "revolve", "deg");
    const opts = (try arguments.parseKwargsOver(RevolveOpts, base, sig.REVOLVE.keywords, vm, args, "revolve")).opts;
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

    const HelixOpts = struct { h: f64 = 10.0, twist: f64 = 360.0, slices: i32 = 0 };
    const pos = arguments.positionalArgs(args);
    var base = HelixOpts{};
    if (pos.len > 0) base.h = try arguments.requireNumber(vm, pos[0], "helix", "h");
    if (pos.len > 1) base.twist = try arguments.requireNumber(vm, pos[1], "helix", "twist");
    if (pos.len > 2) base.slices = try arguments.checkedInt(i32, vm, try arguments.requireNumber(vm, pos[2], "helix", "slices"), "slices");
    const opts = (try arguments.parseKwargsOver(HelixOpts, base, sig.HELIX.keywords, vm, args, "helix")).opts;

    try arguments.requireSegmentCount(vm, opts.slices, "slices");
    const slices = try twistSlices(vm, receiver, opts.slices, opts.twist);

    // Re-use DAG's extrude with twist applied natively
    const new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, opts.h, slices, opts.twist, 1.0, 1.0);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
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
