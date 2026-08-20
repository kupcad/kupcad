const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

const ArgParseCtx = struct {
    pos_count: u8,
    kwargs: ?value.Value,
};

const GeomOptions = struct {
    x: f64 = 1.0,
    y: f64 = 1.0,
    z: f64 = 1.0,
    r: f64 = 1.0,
    h: f64 = 1.0,
    segments: i32 = 0,
    center: bool = false,
};

fn parseArgs(arg_count: u8, args: [*]value.Value) ArgParseCtx {
    if (arg_count > 0 and args[arg_count - 1].isObject() and args[arg_count - 1].asObj().obj_type == .map) {
        return .{ .pos_count = arg_count - 1, .kwargs = args[arg_count - 1] };
    }
    return .{ .pos_count = arg_count, .kwargs = null };
}

fn extractGeomOptions(parsed: ArgParseCtx) GeomOptions {
    var opts = GeomOptions{};

    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", kw.asObj())));

            for (map.keys.items, 0..) |k, i| {
                // Ensure the key is a String or Symbol before trying to read it
                if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                    const k_str = if (k.asObj().obj_type == .string)
                        @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                    else
                        @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

                    const v = map.values.items[i];

                    if (std.mem.eql(u8, k_str, "size")) {
                        if (v.isNumber()) {
                            opts.x = v.asNumber();
                            opts.y = opts.x;
                            opts.z = opts.x;
                        }
                    } else if (std.mem.eql(u8, k_str, "x")) {
                        if (v.isNumber()) opts.x = v.asNumber();
                    } else if (std.mem.eql(u8, k_str, "y")) {
                        if (v.isNumber()) opts.y = v.asNumber();
                    } else if (std.mem.eql(u8, k_str, "z")) {
                        if (v.isNumber()) opts.z = v.asNumber();
                    } else if (std.mem.eql(u8, k_str, "r")) {
                        if (v.isNumber()) opts.r = v.asNumber();
                    } else if (std.mem.eql(u8, k_str, "d")) {
                        if (v.isNumber()) opts.r = v.asNumber() / 2.0;
                    } else if (std.mem.eql(u8, k_str, "h")) {
                        if (v.isNumber()) opts.h = v.asNumber();
                    } else if (std.mem.eql(u8, k_str, "segments")) {
                        if (v.isNumber()) opts.segments = @intFromFloat(v.asNumber());
                    } else if (std.mem.eql(u8, k_str, "center")) {
                        if (v.isBool()) opts.center = v.asBool();
                    }
                }
            }
        }
    }

    return opts;
}

pub fn nativeCube(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const parsed = parseArgs(arg_count, args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) {
        opts.x = args[0].asNumber();
        opts.y = opts.x;
        opts.z = opts.x;
    }
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.y = args[1].asNumber();
    if (parsed.pos_count > 2 and args[2].isNumber()) opts.z = args[2].asNumber();
    if (parsed.pos_count > 3 and args[3].isBool()) opts.center = args[3].asBool();

    const dag_idx = try vm.dag_builder.addCube(opts.x, opts.y, opts.z, opts.center);
    const geom_obj = try vm.gc.allocateGeometry(.{ .symbolic = dag_idx });
    return value.Value.initGeometry(geom_obj);
}

pub fn nativeCylinder(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const parsed = parseArgs(arg_count, args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) opts.r = args[0].asNumber();
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.h = args[1].asNumber();
    if (parsed.pos_count > 2 and args[2].isBool()) opts.center = args[2].asBool();

    const dag_idx = try vm.dag_builder.addCylinder(opts.r, opts.h, opts.center);
    const geom_obj = try vm.gc.allocateGeometry(.{ .symbolic = dag_idx });
    return value.Value.initGeometry(geom_obj);
}

pub fn nativeSphere(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const parsed = parseArgs(arg_count, args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) opts.r = args[0].asNumber();

    const dag_idx = try vm.dag_builder.addSphere(opts.r);
    const geom_obj = try vm.gc.allocateGeometry(.{ .symbolic = dag_idx });
    return value.Value.initGeometry(geom_obj);
}

pub fn nativeSquare(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const parsed = parseArgs(arg_count, args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) {
        opts.x = args[0].asNumber();
        opts.y = opts.x;
    }
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.y = args[1].asNumber();
    if (parsed.pos_count > 2 and args[2].isBool()) opts.center = args[2].asBool();

    const dag_idx = try vm.dag_builder.addSquare(opts.x, opts.y, opts.center);
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativeCircle(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    const parsed = parseArgs(arg_count, args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) opts.r = args[0].asNumber();

    const dag_idx = try vm.dag_builder.addCircle(opts.r, opts.segments);
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativePolygon(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count < 1 or !args[0].isArray()) return error.RuntimeError;

    const pt_arr = args[0].asArray().items.items;
    var pts = try vm.allocator.alloc([2]f64, pt_arr.len);
    defer vm.allocator.free(pts);

    for (pt_arr, 0..) |val, i| {
        if (!val.isArray()) return error.RuntimeError;
        const inner = val.asArray().items.items;
        pts[i][0] = if (inner.len > 0 and inner[0].isNumber()) inner[0].asNumber() else 0.0;
        pts[i][1] = if (inner.len > 1 and inner[1].isNumber()) inner[1].asNumber() else 0.0;
    }

    const dag_idx = try vm.dag_builder.addPolygon(pts);
    return try vm.allocateCrossSection(dag_idx);
}
