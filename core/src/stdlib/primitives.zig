const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const text_mod = @import("../core/text.zig");

const ArgParseCtx = struct {
    pos_count: usize,
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

// --- Helpers ---

fn parseArgs(args: []const value.Value) ArgParseCtx {
    const arg_count = args.len;
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

/// Ensures a value is strictly greater than zero (e.g., lengths, widths, radiuses).
fn requirePositive(vm: *VM, val: f64, name: []const u8) !void {
    if (val <= 0.0) {
        vm.reportError("ValueError: '{s}' must be strictly greater than zero, got {d}.\n", .{ name, val });
        return error.RuntimeError;
    }
}

/// Ensures a value is zero or greater (e.g., corner radiuses, chamfers).
fn requireNonNegative(vm: *VM, val: f64, name: []const u8) !void {
    if (val < 0.0) {
        vm.reportError("ValueError: '{s}' cannot be negative, got {d}.\n", .{ name, val });
        return error.RuntimeError;
    }
}

// --- Methods ---

pub fn nativeCube(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) {
        opts.x = args[0].asNumber();
        opts.y = opts.x;
        opts.z = opts.x;
    }
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.y = args[1].asNumber();
    if (parsed.pos_count > 2 and args[2].isNumber()) opts.z = args[2].asNumber();
    if (parsed.pos_count > 3 and args[3].isBool()) opts.center = args[3].asBool();

    // Validate
    try requirePositive(vm, opts.x, "x");
    try requirePositive(vm, opts.y, "y");
    try requirePositive(vm, opts.z, "z");

    const dag_idx = try vm.dag_builder.addCube(opts.x, opts.y, opts.z, opts.center);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeCylinder(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) opts.r = args[0].asNumber();
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.h = args[1].asNumber();
    if (parsed.pos_count > 2 and args[2].isBool()) opts.center = args[2].asBool();

    // Validate
    try requirePositive(vm, opts.r, "radius");
    try requirePositive(vm, opts.h, "height");

    const dag_idx = try vm.dag_builder.addCylinder(opts.r, opts.h, opts.center);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeSphere(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) opts.r = args[0].asNumber();

    // Validate
    try requirePositive(vm, opts.r, "radius");

    const dag_idx = try vm.dag_builder.addSphere(opts.r);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeSquare(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) {
        opts.x = args[0].asNumber();
        opts.y = opts.x;
    }
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.y = args[1].asNumber();
    if (parsed.pos_count > 2 and args[2].isBool()) opts.center = args[2].asBool();

    // Validate
    try requirePositive(vm, opts.x, "x");
    try requirePositive(vm, opts.y, "y");

    const dag_idx = try vm.dag_builder.addSquare(opts.x, opts.y, opts.center);
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativeCircle(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = extractGeomOptions(parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) opts.r = args[0].asNumber();

    // Validate
    try requirePositive(vm, opts.r, "radius");
    try requireNonNegative(vm, @as(f64, @floatFromInt(opts.segments)), "segments");

    const dag_idx = try vm.dag_builder.addCircle(opts.r, opts.segments);
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativePolygon(vm: *VM, args: []const value.Value) !value.Value {
    if (args.len < 1 or !args[0].isArray()) return error.RuntimeError;
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

pub fn nativePolyhedron(vm: *VM, args: []const value.Value) !value.Value {
    if (args.len < 2 or !args[0].isArray() or !args[1].isArray()) {
        vm.reportError("ArgumentError: polyhedron expects points Array and faces Array.\n", .{});
        return error.RuntimeError;
    }
    const pts_val = args[0].asArray().items.items;
    const faces_val = args[1].asArray().items.items;

    // Unbox Points
    var pts = try vm.allocator.alloc([3]f64, pts_val.len);
    defer vm.allocator.free(pts);
    for (pts_val, 0..) |p, i| {
        if (!p.isArray()) return error.RuntimeError;
        const p_arr = p.asArray().items.items;
        pts[i][0] = if (p_arr.len > 0 and p_arr[0].isNumber()) p_arr[0].asNumber() else 0.0;
        pts[i][1] = if (p_arr.len > 1 and p_arr[1].isNumber()) p_arr[1].asNumber() else 0.0;
        pts[i][2] = if (p_arr.len > 2 and p_arr[2].isNumber()) p_arr[2].asNumber() else 0.0;
    }

    // Unbox Faces (Enforcing Triangles for MVP)
    var faces = try vm.allocator.alloc([3]u32, faces_val.len);
    defer vm.allocator.free(faces);
    for (faces_val, 0..) |f, i| {
        if (!f.isArray()) return error.RuntimeError;
        const f_arr = f.asArray().items.items;
        faces[i][0] = if (f_arr.len > 0 and f_arr[0].isNumber()) @intFromFloat(f_arr[0].asNumber()) else 0;
        faces[i][1] = if (f_arr.len > 1 and f_arr[1].isNumber()) @intFromFloat(f_arr[1].asNumber()) else 0;
        faces[i][2] = if (f_arr.len > 2 and f_arr[2].isNumber()) @intFromFloat(f_arr[2].asNumber()) else 0;
    }

    const dag_idx = try vm.dag_builder.addPolyhedron(pts, faces);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeText(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    if (parsed.pos_count == 0 or !args[0].isString()) {
        vm.reportError("ArgumentError: text() expects a String as its first argument.\n", .{});
        return error.RuntimeError;
    }
    const text_str = args[0].asString().chars;

    // Default configuration
    var size: f64 = 10.0; // 10mm tall
    var font_name: []const u8 = "sans";
    var tolerance: f64 = 0.1;

    // Positional override for size: text("Hello", 20)
    if (parsed.pos_count > 1 and args[1].isNumber()) size = args[1].asNumber();

    // Keyword overrides: text("Hello", size: 20, font: :mono, tolerance: 0.05)
    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", kw.asObj())));

            if (vm.findMapKeyByString(map, "size")) |idx| {
                if (map.values.items[idx].isNumber()) size = map.values.items[idx].asNumber();
            }
            if (vm.findMapKeyByString(map, "font")) |idx| {
                const f_val = map.values.items[idx];
                if (f_val.isString()) font_name = f_val.asString().chars;
                if (f_val.isSymbol()) font_name = f_val.asSymbol().chars;
            }
            if (vm.findMapKeyByString(map, "tolerance")) |idx| {
                if (map.values.items[idx].isNumber()) tolerance = map.values.items[idx].asNumber();
            }
        }
    }

    // Validate
    try requirePositive(vm, size, "size");
    try requirePositive(vm, tolerance, "tolerance");

    // Load Font
    const face = text_mod.getFaceByName(font_name) catch {
        vm.reportError("RuntimeError: Failed to load font '{s}'.\n", .{font_name});
        return error.RuntimeError;
    };

    // Extract Polygons
    var polygons = text_mod.extractText(vm.allocator, &face, text_str, size, tolerance) catch {
        vm.reportError("RuntimeError: Failed to extract text contours.\n", .{});
        return error.RuntimeError;
    };
    defer polygons.deinit(vm.allocator);

    // Convert the extracted contours to the format expected by the kernel
    var contours = try vm.allocator.alloc([]const [2]f64, polygons.contours.items.len);
    defer vm.allocator.free(contours);
    for (polygons.contours.items, 0..) |c, i| {
        contours[i] = c.items;
    }

    // Build the DAG Node
    const dag_idx = try vm.dag_builder.addPolygonsEvenOdd(contours);
    return try vm.allocateCrossSection(dag_idx);
}
