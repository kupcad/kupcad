const std = @import("std");
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
        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
        pos_count -= 1;
        opts = util.parseKwargs(ExtrudeOpts, map);
        if (opts.scale) |s| {
            opts.scale_x = s;
            opts.scale_y = s;
        }
    }

    if (pos_count > 0) {
        if (!args[0].isNumber()) return error.RuntimeError;
        opts.h = args[0].asNumber();
    }

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

    if (args.len > 0 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
        pos_count -= 1;
        var it = map.map.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                const k_str = if (k.asObj().obj_type == .string)
                    @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                else
                    @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

                if (std.mem.eql(u8, k_str, "deg") and entry.value_ptr.*.isNumber()) degrees = entry.value_ptr.*.asNumber();
            }
        }
    }

    if (pos_count > 0) {
        if (!args[0].isNumber()) return error.RuntimeError;
        degrees = args[0].asNumber();
    }

    // Pull the active configuration and calculate segments
    const config = vm.config_stack.items[vm.config_stack.items.len - 1];

    // For a 2D cross-section, if fixed_segments isn't set, we use a safe baseline radius
    // (e.g., 10.0mm) to generate a smooth default resolution via the new getSegments solver.
    const segments: i32 = if (config.manifold.fixed_segments > 0)
        @intCast(config.manifold.fixed_segments)
    else
        @intCast(config.manifold.getSegments(10.0));

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
        opts = util.parseKwargs(HelixOpts, map);
    }

    if (pos_count > 0 and args[0].isNumber()) opts.h = args[0].asNumber();
    if (pos_count > 1 and args[1].isNumber()) opts.twist = args[1].asNumber();

    // Re-use DAG's extrude with twist applied natively
    const new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, opts.h, opts.slices, opts.twist, 1.0, 1.0);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshLoft(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    if (args.len < 2 or !args[0].isCrossSection() or !args[1].isNumber()) {
        vm.reportError("ArgumentError: loft requires a target CrossSection and a z-height.\n", .{});
        return error.RuntimeError;
    }

    const cs_top = args[0].asCrossSection();
    const height = args[1].asNumber();

    const dag_idx = try vm.dag_builder.addLoft(receiver.asCrossSection().dag_idx, cs_top.dag_idx, height);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}
