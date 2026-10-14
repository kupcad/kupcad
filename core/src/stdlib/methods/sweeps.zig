const util = @import("util.zig");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;

pub fn meshExtrude(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;

    const ExtrudeOpts = struct {
        h: f64 = 1.0,
        slices: i32 = 0,
        twist: f64 = 0.0,
        scale_x: f64 = 1.0,
        scale_y: f64 = 1.0,
        scale: ?f64 = null,
        center: bool = false,
    };

    const parsed = try util.parseKwargs(ExtrudeOpts, vm, args, "extrude");
    var opts = parsed.opts;
    if (opts.scale) |s| {
        opts.scale_x = s;
        opts.scale_y = s;
    }

    // NaN/inf sweep parameters propagate into every generated vertex: requireNumber
    // and parseKwargs reject them along with non-numbers.
    if (parsed.positional.len > 0) opts.h = try util.requireNumber(vm, args[0], "extrude", "h");

    try util.requireSegmentCount(vm, opts.slices, "slices");

    var new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, opts.h, opts.slices, opts.twist, opts.scale_x, opts.scale_y);

    if (opts.center) {
        new_idx = try vm.dag_builder.addTranslate(new_idx, 0.0, 0.0, -opts.h / 2.0);
    }
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// The profile's distance from the axis is not known before evaluation, so revolve
/// resolves its segment count (when the config has no fixed count) for a typical radius.
const REVOLVE_BASELINE_RADIUS = 10.0;

pub fn meshRevolve(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    const parsed = try util.parseKwargs(struct { deg: f64 = 360.0 }, vm, args, "revolve");
    var degrees = parsed.opts.deg;
    if (parsed.positional.len > 0) degrees = try util.requireNumber(vm, args[0], "revolve", "deg");

    const segments = util.autoSegments(vm, REVOLVE_BASELINE_RADIUS);

    const new_idx = try vm.dag_builder.addRevolve(receiver.asCrossSection().dag_idx, segments, degrees);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshHelix(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;

    const HelixOpts = struct { h: f64 = 10.0, twist: f64 = 360.0, slices: i32 = 64 };
    const parsed = try util.parseKwargs(HelixOpts, vm, args, "helix");
    var opts = parsed.opts;

    if (parsed.positional.len > 0) opts.h = try util.requireNumber(vm, args[0], "helix", "h");
    if (parsed.positional.len > 1) opts.twist = try util.requireNumber(vm, args[1], "helix", "twist");

    try util.requireSegmentCount(vm, opts.slices, "slices");

    // Re-use DAG's extrude with twist applied natively
    const new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, opts.h, opts.slices, opts.twist, 1.0, 1.0);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshLoft(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    if (args.len < 2) {
        _ = vm.raiseError(.ArgumentError, "loft requires a target CrossSection and a z-height", .{});
        return error.RuntimeError;
    }
    if (!args[0].isCrossSection()) {
        _ = vm.raiseError(.TypeError, "loft expects a CrossSection for the target, got {s}", .{util.typeName(vm, args[0])});
        return error.RuntimeError;
    }

    const cs_top = args[0].asCrossSection();
    const height = try util.requireNumber(vm, args[1], "loft", "height");

    const dag_idx = try vm.dag_builder.addLoft(receiver.asCrossSection().dag_idx, cs_top.dag_idx, height);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}
