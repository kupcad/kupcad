const util = @import("util.zig");
const sig = @import("../method_signatures.zig");
const kernel = @import("../../kernel/kernel.zig");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;

pub fn meshExtrude(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return util.notDefinedFor(vm, "extrude", receiver);

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
    const pos = util.positionalArgs(args);
    var base = ExtrudeOpts{};
    if (pos.len > 0) base.h = try util.requireNumber(vm, pos[0], "extrude", "h");
    var opts = (try util.parseKwargsOver(ExtrudeOpts, base, sig.EXTRUDE.keywords, vm, args, "extrude")).opts;
    if (opts.scale) |s| {
        opts.scale_x = s;
        opts.scale_y = s;
    }

    try util.requireSegmentCount(vm, opts.slices, "slices");

    var new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, opts.h, opts.slices, opts.twist, opts.scale_x, opts.scale_y);

    if (opts.center) {
        new_idx = try vm.dag_builder.addTranslate(new_idx, 0.0, 0.0, -opts.h / 2.0);
    }
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshRevolve(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return util.notDefinedFor(vm, "revolve", receiver);
    const RevolveOpts = struct { deg: f64 = 360.0, segments: i32 = 0 };
    const pos = util.positionalArgs(args);
    var base = RevolveOpts{};
    if (pos.len > 0) base.deg = try util.requireNumber(vm, pos[0], "revolve", "deg");
    const opts = (try util.parseKwargsOver(RevolveOpts, base, sig.REVOLVE.keywords, vm, args, "revolve")).opts;
    try util.requireSegmentCount(vm, opts.segments, "segments");

    // The profile spins about the Y axis, so its radius is its farthest x. It used to be
    // assumed 10 mm, whatever the profile's size. Resolved now, under the active config.
    const segments = if (opts.segments > 0) opts.segments else blk: {
        const profile = try vm.ensureConcreteCrossSection(receiver);
        if (!kernel.supports(profile.engine, .sketch_measure)) {
            _ = vm.raiseError(.NotImplementedError, "the {s} engine can't measure the profile to choose revolve's segments yet; pass segments:", .{profile.engine.scriptName()});
            return error.RuntimeError;
        }
        const bounds = kernel.crossSectionBounds(profile);
        break :blk util.autoSegments(vm, @max(@abs(bounds.min[0]), @abs(bounds.max[0])));
    };

    const new_idx = try vm.dag_builder.addRevolve(receiver.asCrossSection().dag_idx, segments, opts.deg);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshHelix(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return util.notDefinedFor(vm, "helix", receiver);

    const HelixOpts = struct { h: f64 = 10.0, twist: f64 = 360.0, slices: i32 = 64 };
    const pos = util.positionalArgs(args);
    var base = HelixOpts{};
    if (pos.len > 0) base.h = try util.requireNumber(vm, pos[0], "helix", "h");
    if (pos.len > 1) base.twist = try util.requireNumber(vm, pos[1], "helix", "twist");
    if (pos.len > 2) base.slices = try util.checkedInt(i32, vm, try util.requireNumber(vm, pos[2], "helix", "slices"), "slices");
    const opts = (try util.parseKwargsOver(HelixOpts, base, sig.HELIX.keywords, vm, args, "helix")).opts;

    try util.requireSegmentCount(vm, opts.slices, "slices");

    // Re-use DAG's extrude with twist applied natively
    const new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, opts.h, opts.slices, opts.twist, 1.0, 1.0);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshLoft(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return util.notDefinedFor(vm, "loft", receiver);
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
