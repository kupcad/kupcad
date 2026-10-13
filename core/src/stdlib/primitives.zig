const std = @import("std");
const value = @import("../core/value.zig");
const util = @import("methods/util.zig");
const VM = @import("../vm/vm.zig").VM;
const text_mod = @import("../core/text.zig");
const limits = @import("../core/limits.zig");

/// Smallest allowed text() flattening tolerance relative to the glyph size.
const MIN_TEXT_TOLERANCE_RATIO: f64 = 1e-4;

const ArgParseCtx = struct {
    pos_count: usize,
    kwargs: ?value.Value,
};

const GeomOptions = struct {
    x: f64 = 1.0,
    y: f64 = 1.0,
    z: f64 = 1.0,
    r: f64 = 1.0,
    r1: ?f64 = null,
    r2: ?f64 = null,
    h: f64 = 1.0,
    round_r: ?f64 = null,
    chamfer: ?f64 = null,
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

fn extractGeomOptions(vm: *VM, parsed: ArgParseCtx) !GeomOptions {
    var opts = GeomOptions{};

    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map = kw.asMap();
            opts = try util.parseKwargs(GeomOptions, vm, map);

            if (util.getKey(map, "size")) |v| {
                if (v.isNumber()) {
                    opts.x = v.asNumber();
                    opts.y = opts.x;
                    opts.z = opts.x;
                }
            }
            if (util.getKey(map, "d")) |v| {
                if (v.isNumber()) opts.r = v.asNumber() / 2.0;
            }
            if (util.getKey(map, "d1")) |v| {
                if (v.isNumber()) opts.r1 = v.asNumber() / 2.0;
            }
            if (util.getKey(map, "d2")) |v| {
                if (v.isNumber()) opts.r2 = v.asNumber() / 2.0;
            }
            if (util.getKey(map, "radius")) |v| {
                if (v.isNumber()) opts.r = v.asNumber();
            }
        }
    }
    try util.requireSegmentCount(vm, opts.segments, "segments");
    return opts;
}

// NaN compares false against everything, so `val <= 0` alone lets NaN through;
// infinities are rejected too since no kernel can tessellate them.
fn requirePositive(vm: *VM, val: f64, name: []const u8) !void {
    if (!std.math.isFinite(val) or val <= 0.0) {
        vm.reportError("ValueError: '{s}' must be a finite number greater than zero, got {d}.\n", .{ name, val });
        return error.RuntimeError;
    }
}

/// Validates a user-supplied index into an array of length `len`.
fn checkedIndex(vm: *VM, raw: f64, len: usize, what: []const u8) !usize {
    if (!std.math.isFinite(raw) or raw < 0.0 or @trunc(raw) != raw or raw >= @as(f64, @floatFromInt(len)) or raw > std.math.maxInt(u32)) {
        vm.reportError("ValueError: {s} index {d} is out of range (0..{d}).\n", .{ what, raw, len });
        return error.RuntimeError;
    }
    return @intFromFloat(raw);
}

// --- Filleting Math Helpers ---

/// Generates points along a circular arc and pushes them to the polygon list
fn pushArc(allocator: std.mem.Allocator, pts: *std.ArrayListUnmanaged([2]f64), cx: f64, cy: f64, r: f64, start_ang: f64, end_ang: f64, segments: usize) !void {
    const step = (end_ang - start_ang) / @as(f64, @floatFromInt(segments));
    for (0..segments + 1) |i| {
        const ang = start_ang + @as(f64, @floatFromInt(i)) * step;
        try pts.append(allocator, .{ cx + r * @cos(ang), cy + r * @sin(ang) });
    }
}

/// Helper to generate a 2D rounded or chamfered rectangle
fn buildRoundedRect(vm: *VM, x: f64, y: f64, center: bool, round_r: ?f64, chamfer: ?f64, segs: i32) !u32 {
    var pts = std.ArrayListUnmanaged([2]f64).empty;
    // Temporary structures map to scratch_arena instead of standard allocator
    const alloc = vm.scratch_arena.allocator();
    defer pts.deinit(alloc);

    const hw = x / 2.0;
    const hh = y / 2.0;
    const cx = if (center) 0.0 else hw;
    const cy = if (center) 0.0 else hh;

    const active_config = vm.config_stack.items[vm.config_stack.items.len - 1];

    if (round_r) |r| {
        const safe_r = @min(r, @min(hw, hh));
        // Calculate segments per 90-degree arc (minimum 4, or inherited from user's global segments)
        const total_segs: i32 = if (segs > 0) segs else util.clampSegments(active_config.manifold.getSegments(safe_r));
        const arc_segs = @max(1, @as(usize, @intCast(total_segs)) / 4);
        // Build corners Counter-Clockwise
        try pushArc(alloc, &pts, cx + hw - safe_r, cy - hh + safe_r, safe_r, -std.math.pi / 2.0, 0.0, arc_segs); // Bottom-Right
        try pushArc(alloc, &pts, cx + hw - safe_r, cy + hh - safe_r, safe_r, 0.0, std.math.pi / 2.0, arc_segs); // Top-Right
        try pushArc(alloc, &pts, cx - hw + safe_r, cy + hh - safe_r, safe_r, std.math.pi / 2.0, std.math.pi, arc_segs); // Top-Left
        try pushArc(alloc, &pts, cx - hw + safe_r, cy - hh + safe_r, safe_r, std.math.pi, std.math.pi * 1.5, arc_segs); // Bottom-Left
    } else if (chamfer) |c| {
        const safe_c = @min(c, @min(hw, hh));
        try pts.appendSlice(alloc, &.{
            .{ cx + hw - safe_c, cy - hh },
            .{ cx + hw, cy - hh + safe_c },
            .{ cx + hw, cy + hh - safe_c },
            .{ cx + hw - safe_c, cy + hh },
            .{ cx - hw + safe_c, cy + hh },
            .{ cx - hw, cy + hh - safe_c },
            .{ cx - hw, cy - hh + safe_c },
            .{ cx - hw + safe_c, cy - hh },
        });
    }

    return vm.dag_builder.addPolygon(pts.items);
}

// --- Methods ---
pub fn nativeSquare(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = try extractGeomOptions(vm, parsed);
    if (parsed.pos_count > 0 and args[0].isNumber()) {
        opts.x = args[0].asNumber();
        opts.y = opts.x;
    }
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.y = args[1].asNumber();
    if (parsed.pos_count > 2 and args[2].isBool()) opts.center = args[2].asBool();

    try requirePositive(vm, opts.x, "x");
    try requirePositive(vm, opts.y, "y");

    var dag_idx: u32 = 0;
    if (opts.round_r != null or opts.chamfer != null) {
        dag_idx = try buildRoundedRect(vm, opts.x, opts.y, opts.center, opts.round_r, opts.chamfer, opts.segments);
    } else {
        dag_idx = try vm.dag_builder.addSquare(opts.x, opts.y, opts.center);
    }
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativeCube(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = try extractGeomOptions(vm, parsed);
    if (parsed.pos_count > 0 and args[0].isNumber()) {
        opts.x = args[0].asNumber();
        opts.y = opts.x;
        opts.z = opts.x;
    }
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.y = args[1].asNumber();
    if (parsed.pos_count > 2 and args[2].isNumber()) opts.z = args[2].asNumber();
    if (parsed.pos_count > 3 and args[3].isBool()) opts.center = args[3].asBool();

    try requirePositive(vm, opts.x, "x");
    try requirePositive(vm, opts.y, "y");
    try requirePositive(vm, opts.z, "z");

    var dag_idx: u32 = 0;
    if (opts.round_r != null or opts.chamfer != null) {
        // Build a rounded 2D cross-section and manually extrude it
        const cs_idx = try buildRoundedRect(vm, opts.x, opts.y, true, opts.round_r, opts.chamfer, opts.segments);
        dag_idx = try vm.dag_builder.addExtrude(cs_idx, opts.z, 0, 0.0, 1.0, 1.0);
        // Manually apply proper positioning
        if (opts.center) {
            dag_idx = try vm.dag_builder.addTranslate(dag_idx, 0.0, 0.0, -opts.z / 2.0);
        } else {
            dag_idx = try vm.dag_builder.addTranslate(dag_idx, opts.x / 2.0, opts.y / 2.0, 0.0);
        }
    } else {
        dag_idx = try vm.dag_builder.addCube(opts.x, opts.y, opts.z, opts.center);
    }
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeCylinder(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = try extractGeomOptions(vm, parsed);
    if (parsed.pos_count > 0 and args[0].isNumber()) opts.r = args[0].asNumber();
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.h = args[1].asNumber();
    if (parsed.pos_count > 2 and args[2].isBool()) opts.center = args[2].asBool();

    const r1 = opts.r1 orelse opts.r;
    const r2 = opts.r2 orelse opts.r;

    try requirePositive(vm, r1, "radius 1");
    try requirePositive(vm, r2, "radius 2");
    try requirePositive(vm, opts.h, "height");

    const active_config = vm.config_stack.items[vm.config_stack.items.len - 1];

    if (opts.segments == 0) {
        opts.segments = util.clampSegments(active_config.manifold.getSegments(@max(r1, r2)));
    }

    var dag_idx: u32 = 0;
    if (opts.round_r != null or opts.chamfer != null) {
        // Draw the right-half cross section using CCW winding (Bottom to Top)
        var pts = std.ArrayListUnmanaged([2]f64).empty;
        const alloc = vm.scratch_arena.allocator();
        defer pts.deinit(alloc);

        const y_min = if (opts.center) -opts.h / 2.0 else 0.0;
        const y_max = if (opts.center) opts.h / 2.0 else opts.h;

        // Bottom center axis
        try pts.append(alloc, .{ 0.0, y_min });

        if (opts.round_r) |rr| {
            const safe_r1 = @min(rr, @min(r1, opts.h / 2.0));
            const safe_r2 = @min(rr, @min(r2, opts.h / 2.0));

            const corner_segs: i32 = util.clampSegments(active_config.manifold.getSegments(@max(safe_r1, safe_r2)));
            const arc_segs = @max(1, @as(usize, @intCast(corner_segs)) / 4);
            // Bottom Right Corner (sweep from -90 deg to 0)
            try pushArc(alloc, &pts, r1 - safe_r1, y_min + safe_r1, safe_r1, -std.math.pi / 2.0, 0.0, arc_segs);
            // Top Right Corner (sweep from 0 to 90 deg)
            try pushArc(alloc, &pts, r2 - safe_r2, y_max - safe_r2, safe_r2, 0.0, std.math.pi / 2.0, arc_segs);
        } else if (opts.chamfer) |c| {
            const safe_c1 = @min(c, @min(r1, opts.h / 2.0));
            const safe_c2 = @min(c, @min(r2, opts.h / 2.0));

            try pts.appendSlice(alloc, &.{
                .{ r1 - safe_c1, y_min },
                .{ r1, y_min + safe_c1 },
                .{ r2, y_max - safe_c2 },
                .{ r2 - safe_c2, y_max },
            });
        }
        // Top center axis
        try pts.append(alloc, .{ 0.0, y_max });

        const cs_idx = try vm.dag_builder.addPolygon(pts.items);
        dag_idx = try vm.dag_builder.addRevolve(cs_idx, opts.segments, 360.0);
    } else {
        dag_idx = try vm.dag_builder.addCylinder(r1, r2, opts.h, opts.center, opts.segments);
    }
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeSphere(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = try extractGeomOptions(vm, parsed);
    if (parsed.pos_count > 0 and args[0].isNumber()) opts.r = args[0].asNumber();
    try requirePositive(vm, opts.r, "radius");
    const dag_idx = try vm.dag_builder.addSphere(opts.r);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeCircle(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = try extractGeomOptions(vm, parsed);

    if (parsed.pos_count > 0 and args[0].isNumber()) opts.r = args[0].asNumber();
    try requirePositive(vm, opts.r, "radius");

    if (opts.segments == 0) {
        const active_config = vm.config_stack.items[vm.config_stack.items.len - 1];
        opts.segments = util.clampSegments(active_config.manifold.getSegments(opts.r));
    }

    const dag_idx = try vm.dag_builder.addCircle(opts.r, opts.segments);
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativePolygon(vm: *VM, args: []const value.Value) !value.Value {
    if (args.len < 1 or !args[0].isArray()) return error.RuntimeError;
    const pt_arr = args[0].asArray().items.items;
    var paths_arr: ?[]value.Value = null;

    if (args.len > 1) {
        // Parse `paths` from kwargs or positional argument
        if (args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
            const map: *value.ObjMap = @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj()));
            // $O(1)$ Hash lookup
            var it = map.map.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                    const k_str = if (k.asObj().obj_type == .string)
                        @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                    else
                        @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;
                    if (std.mem.eql(u8, k_str, "paths")) {
                        if (entry.value_ptr.isArray()) {
                            paths_arr = entry.value_ptr.asArray().items.items;
                        }
                    }
                }
            }
        } else if (args[1].isArray()) {
            paths_arr = args[1].asArray().items.items;
        }
    }

    const alloc = vm.scratch_arena.allocator();

    if (paths_arr) |paths| {
        // Build Multi-Contour Polygon (Supports Holes via Even-Odd rule)
        const contours = try alloc.alloc([]const [2]f64, paths.len);
        // Initialize so the deferred free is safe if validation fails part-way.
        @memset(contours, &.{});
        defer {
            for (contours) |c| alloc.free(c);
            alloc.free(contours);
        }

        for (paths, 0..) |path_val, c_idx| {
            if (!path_val.isArray()) return error.RuntimeError;
            const indices = path_val.asArray().items.items;
            const contour = try alloc.alloc([2]f64, indices.len);
            contours[c_idx] = contour;

            for (indices, 0..) |idx_val, p_idx| {
                if (!idx_val.isNumber()) return error.RuntimeError;
                const pt_idx = try checkedIndex(vm, idx_val.asNumber(), pt_arr.len, "polygon path");

                const pt_val = pt_arr[pt_idx];
                if (!pt_val.isArray()) return error.RuntimeError;
                const inner = pt_val.asArray().items.items;

                contour[p_idx][0] = if (inner.len > 0 and inner[0].isNumber()) inner[0].asNumber() else 0.0;
                contour[p_idx][1] = if (inner.len > 1 and inner[1].isNumber()) inner[1].asNumber() else 0.0;
            }
        }
        const dag_idx = try vm.dag_builder.addPolygonsEvenOdd(contours);
        return try vm.allocateCrossSection(dag_idx);
    } else {
        // Standard Single-Contour Polygon
        var pts = try alloc.alloc([2]f64, pt_arr.len);
        defer alloc.free(pts);

        for (pt_arr, 0..) |val, i| {
            if (!val.isArray()) return error.RuntimeError;
            const inner = val.asArray().items.items;
            pts[i][0] = if (inner.len > 0 and inner[0].isNumber()) inner[0].asNumber() else 0.0;
            pts[i][1] = if (inner.len > 1 and inner[1].isNumber()) inner[1].asNumber() else 0.0;
        }
        const dag_idx = try vm.dag_builder.addPolygon(pts);
        return try vm.allocateCrossSection(dag_idx);
    }
}

pub fn nativeRegularPolygon(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = try extractGeomOptions(vm, parsed);

    var sides: i32 = 6; // Default to a hexagon
    if (parsed.pos_count > 0 and args[0].isNumber()) sides = try util.checkedInt(i32, vm, args[0].asNumber(), "sides");
    if (parsed.pos_count > 1 and args[1].isNumber()) opts.r = args[1].asNumber();

    // Check kwargs explicitly for sides/radius if passed
    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map = kw.asMap();
            if (util.getKey(map, "sides")) |v| {
                if (v.isNumber()) sides = try util.checkedInt(i32, vm, v.asNumber(), "sides");
            }
        }
    }

    if (sides < 3 or sides > limits.MAX_SEGMENTS) {
        vm.reportError("ValueError: 'sides' must be between 3 and {d}, got {d}.\n", .{ limits.MAX_SEGMENTS, sides });
        return error.RuntimeError;
    }
    try requirePositive(vm, opts.r, "radius");

    var pts = std.ArrayListUnmanaged([2]f64).empty;
    const alloc = vm.scratch_arena.allocator();
    defer pts.deinit(alloc);

    // Generate points around the circle
    const step = std.math.pi * 2.0 / @as(f64, @floatFromInt(sides));
    for (0..@as(usize, @intCast(sides))) |i| {
        const ang = @as(f64, @floatFromInt(i)) * step;
        try pts.append(alloc, .{ opts.r * @cos(ang), opts.r * @sin(ang) });
    }

    const dag_idx = try vm.dag_builder.addPolygon(pts.items);
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativeTorus(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    const opts = try extractGeomOptions(vm, parsed);

    var major_r: f64 = 10.0;
    var minor_r: f64 = 2.0;

    if (parsed.pos_count > 0 and args[0].isNumber()) major_r = args[0].asNumber();
    if (parsed.pos_count > 1 and args[1].isNumber()) minor_r = args[1].asNumber();

    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map = kw.asMap();
            if (util.getKey(map, "major_r")) |v| {
                if (v.isNumber()) major_r = v.asNumber();
            }
            if (util.getKey(map, "minor_r")) |v| {
                if (v.isNumber()) minor_r = v.asNumber();
            }
        }
    }

    try requirePositive(vm, major_r, "major_r");
    try requirePositive(vm, minor_r, "minor_r");

    const active_config = vm.config_stack.items[vm.config_stack.items.len - 1];

    // Create a 2D circle using the minor radius
    const circ_segs = if (opts.segments > 0) opts.segments else util.clampSegments(active_config.manifold.getSegments(minor_r));
    const circ_idx = try vm.dag_builder.addCircle(minor_r, circ_segs);

    // Translate the circle outward by the major radius
    const trans_mat = [6]f64{ 1.0, 0.0, 0.0, 1.0, major_r, 0.0 };
    const trans_idx = try vm.dag_builder.addCrossSectionTransform(circ_idx, trans_mat);

    // Revolve the translated circle 360 degrees around the origin
    const rev_segs = if (opts.segments > 0) opts.segments else util.clampSegments(active_config.manifold.getSegments(major_r));
    const dag_idx = try vm.dag_builder.addRevolve(trans_idx, rev_segs, 360.0);

    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativePolyhedron(vm: *VM, args: []const value.Value) !value.Value {
    if (args.len < 2 or !args[0].isArray() or !args[1].isArray()) {
        vm.reportError("ArgumentError: polyhedron expects points Array and faces Array.\n", .{});
        return error.RuntimeError;
    }
    const alloc = vm.scratch_arena.allocator();

    const pts_val = args[0].asArray().items.items;
    const faces_val = args[1].asArray().items.items;

    var pts = try alloc.alloc([3]f64, pts_val.len);
    defer alloc.free(pts);

    for (pts_val, 0..) |p, i| {
        if (!p.isArray()) return error.RuntimeError;
        const p_arr = p.asArray().items.items;
        pts[i][0] = if (p_arr.len > 0 and p_arr[0].isNumber()) p_arr[0].asNumber() else 0.0;
        pts[i][1] = if (p_arr.len > 1 and p_arr[1].isNumber()) p_arr[1].asNumber() else 0.0;
        pts[i][2] = if (p_arr.len > 2 and p_arr[2].isNumber()) p_arr[2].asNumber() else 0.0;
    }

    var faces = try alloc.alloc([3]u32, faces_val.len);
    defer alloc.free(faces);

    for (faces_val, 0..) |f, i| {
        if (!f.isArray()) return error.RuntimeError;
        const f_arr = f.asArray().items.items;
        for (0..3) |c| {
            const raw: f64 = if (f_arr.len > c and f_arr[c].isNumber()) f_arr[c].asNumber() else 0.0;
            // Kernels index points[] directly with these, so they must be in range.
            faces[i][c] = @intCast(try checkedIndex(vm, raw, pts.len, "polyhedron face"));
        }
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
    var size: f64 = 10.0;
    var font_name: []const u8 = "sans";
    var tolerance: f64 = 0.1;
    var halign: text_mod.HAlign = .left;
    var valign: text_mod.VAlign = .baseline;

    if (parsed.pos_count > 1 and args[1].isNumber()) size = args[1].asNumber();

    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map: *value.ObjMap = @alignCast(@fieldParentPtr("obj", kw.asObj()));
            var it = map.map.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                    const k_str = if (k.asObj().obj_type == .string)
                        @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                    else
                        @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

                    const v = entry.value_ptr.*;
                    if (std.mem.eql(u8, k_str, "size") and v.isNumber()) size = v.asNumber();
                    if (std.mem.eql(u8, k_str, "tolerance") and v.isNumber()) tolerance = v.asNumber();
                    if (std.mem.eql(u8, k_str, "font")) {
                        if (v.isString()) font_name = v.asString().chars;
                        if (v.isSymbol()) font_name = v.asSymbol().chars;
                    }
                    if (std.mem.eql(u8, k_str, "halign")) {
                        const h_str = if (v.isString()) v.asString().chars else if (v.isSymbol()) v.asSymbol().chars else "";
                        if (std.mem.eql(u8, h_str, "center")) halign = .center;
                        if (std.mem.eql(u8, h_str, "right")) halign = .right;
                    }
                    if (std.mem.eql(u8, k_str, "valign")) {
                        const v_str = if (v.isString()) v.asString().chars else if (v.isSymbol()) v.asSymbol().chars else "";
                        if (std.mem.eql(u8, v_str, "center")) valign = .center;
                        if (std.mem.eql(u8, v_str, "top")) valign = .top;
                        if (std.mem.eql(u8, v_str, "bottom")) valign = .bottom;
                    }
                }
            }
        }
    }

    try requirePositive(vm, size, "size");
    try requirePositive(vm, tolerance, "tolerance");
    // Bezier flattening recurses until the chord error is below `tolerance`, so the
    // point count grows ~sqrt(size / tolerance) per curve; a vanishing tolerance
    // (e.g. 1e-300, whose square underflows to 0) never terminates in practice.
    if (tolerance < size * MIN_TEXT_TOLERANCE_RATIO) {
        vm.reportError("ValueError: 'tolerance' must be at least size * {d} ({d}), got {d}.\n", .{ MIN_TEXT_TOLERANCE_RATIO, size * MIN_TEXT_TOLERANCE_RATIO, tolerance });
        return error.RuntimeError;
    }

    const alloc = vm.scratch_arena.allocator();

    const face = text_mod.getFaceByName(font_name) catch {
        vm.reportError("RuntimeError: Failed to load font '{s}'.\n", .{font_name});
        return error.RuntimeError;
    };
    var polygons = text_mod.extractText(alloc, &face, text_str, size, tolerance, halign, valign) catch {
        vm.reportError("RuntimeError: Failed to extract text contours.\n", .{});
        return error.RuntimeError;
    };
    defer polygons.deinit(alloc);

    var contours = try alloc.alloc([]const [2]f64, polygons.contours.items.len);
    defer alloc.free(contours);

    for (polygons.contours.items, 0..) |c, i| {
        contours[i] = c.items;
    }

    const dag_idx = try vm.dag_builder.addPolygonsEvenOdd(contours);
    return try vm.allocateCrossSection(dag_idx);
}
