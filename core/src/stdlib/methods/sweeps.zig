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

    var opts = ExtrudeOpts{};
    var pos_count = args.len;

    if (args.len > 0 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        const map: *value.ObjMap = @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj()));
        pos_count -= 1;
        opts = try util.parseKwargs(ExtrudeOpts, vm, map, "extrude");
        if (opts.scale) |s| {
            opts.scale_x = s;
            opts.scale_y = s;
        }
    }

    // NaN/inf sweep parameters propagate into every generated vertex: requireNumber
    // and parseKwargs reject them along with non-numbers.
    if (pos_count > 0) opts.h = try util.requireNumber(vm, args[0], "extrude", "h");

    try util.requireSegmentCount(vm, opts.slices, "slices");

    var new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, opts.h, opts.slices, opts.twist, opts.scale_x, opts.scale_y);

    if (opts.center) {
        new_idx = try vm.dag_builder.addTranslate(new_idx, 0.0, 0.0, -opts.h / 2.0);
    }
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshRevolve(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    var degrees: f64 = 360.0;
    var pos_count = args.len;

    if (util.trailingKwargs(args)) |map| {
        pos_count -= 1;
        if (util.getKey(map, "deg")) |v| degrees = try util.requireNumber(vm, v, "revolve", "deg");
    }

    if (pos_count > 0) degrees = try util.requireNumber(vm, args[0], "revolve", "deg");

    // Pull the active configuration and calculate segments
    const config = vm.config_stack.items[vm.config_stack.items.len - 1];

    // For a 2D cross-section, if fixed_segments isn't set, we use a safe baseline radius
    // (e.g., 10.0mm) to generate a smooth default resolution via the new getSegments solver.
    const segments: i32 = util.clampSegments(config.manifold.getSegments(10.0));

    const new_idx = try vm.dag_builder.addRevolve(receiver.asCrossSection().dag_idx, segments, degrees);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshHelix(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;

    const HelixOpts = struct { h: f64 = 10.0, twist: f64 = 360.0, slices: i32 = 64 };
    var opts = HelixOpts{};
    var pos_count = args.len;

    if (args.len > 0 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        const map = args[args.len - 1].asMap();
        pos_count -= 1;
        opts = try util.parseKwargs(HelixOpts, vm, map, "helix");
    }

    if (pos_count > 0) opts.h = try util.requireNumber(vm, args[0], "helix", "h");
    if (pos_count > 1) opts.twist = try util.requireNumber(vm, args[1], "helix", "twist");

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
