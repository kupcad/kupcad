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

fn extractGeomOptions(vm: *VM, parsed: ArgParseCtx, method: []const u8) !GeomOptions {
    var opts = GeomOptions{};

    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map = kw.asMap();
            opts = try util.parseKwargs(GeomOptions, vm, map, method);

            if (util.getKey(map, "size")) |v| {
                opts.x = try util.requireNumber(vm, v, method, "size");
                opts.y = opts.x;
                opts.z = opts.x;
            }
            if (util.getKey(map, "d")) |v| opts.r = try util.requireNumber(vm, v, method, "d") / 2.0;
            if (util.getKey(map, "d1")) |v| opts.r1 = try util.requireNumber(vm, v, method, "d1") / 2.0;
            if (util.getKey(map, "d2")) |v| opts.r2 = try util.requireNumber(vm, v, method, "d2") / 2.0;
            if (util.getKey(map, "radius")) |v| opts.r = try util.requireNumber(vm, v, method, "radius");
        }
    }
    try util.requireSegmentCount(vm, opts.segments, "segments");
    return opts;
}

/// Validates a user-supplied index into an array of length `len`.
fn checkedIndex(vm: *VM, raw: f64, len: usize, what: []const u8) !usize {
    if (!std.math.isFinite(raw) or raw < 0.0 or @trunc(raw) != raw or raw >= @as(f64, @floatFromInt(len)) or raw > std.math.maxInt(u32)) {
        _ = vm.raiseError(.ValueError, "{s} index {f} is out of range (0..{d})", .{ what, value.fmtNumber(raw), len });
        return error.RuntimeError;
    }
    return @intFromFloat(raw);
}

/// Fewest points that enclose an area (a polygon contour).
const MIN_CONTOUR_POINTS = 3;
/// Fewest points and faces of a closed solid (a tetrahedron).
const MIN_POLYHEDRON_POINTS = 4;
const MIN_POLYHEDRON_FACES = 4;
/// Faces are triangles: the kernels take exactly three point indices per face.
const POLYHEDRON_FACE_LEN = 3;
/// Room for an argument label such as "a point index (path 12, entry 345)".
const MAX_LABEL_LEN = 64;

fn requireMinCount(vm: *VM, count: usize, min: usize, method: []const u8, what: []const u8) !void {
    if (count < min) {
        _ = vm.raiseError(.ValueError, "{s} needs at least {d} {s}, got {d}", .{ method, min, what, count });
        return error.RuntimeError;
    }
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
    var opts = try extractGeomOptions(vm, parsed, "square");
    if (parsed.pos_count > 0) {
        opts.x = try util.requireNumber(vm, args[0], "square", "x");
        opts.y = opts.x;
    }
    if (parsed.pos_count > 1) opts.y = try util.requireNumber(vm, args[1], "square", "y");
    if (parsed.pos_count > 2) opts.center = try util.requireBool(vm, args[2], "square", "center");

    try util.requirePositive(vm, opts.x, "square", "x");
    try util.requirePositive(vm, opts.y, "square", "y");

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
    var opts = try extractGeomOptions(vm, parsed, "cube");
    if (parsed.pos_count > 0) {
        opts.x = try util.requireNumber(vm, args[0], "cube", "x");
        opts.y = opts.x;
        opts.z = opts.x;
    }
    if (parsed.pos_count > 1) opts.y = try util.requireNumber(vm, args[1], "cube", "y");
    if (parsed.pos_count > 2) opts.z = try util.requireNumber(vm, args[2], "cube", "z");
    if (parsed.pos_count > 3) opts.center = try util.requireBool(vm, args[3], "cube", "center");

    try util.requirePositive(vm, opts.x, "cube", "x");
    try util.requirePositive(vm, opts.y, "cube", "y");
    try util.requirePositive(vm, opts.z, "cube", "z");

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
    var opts = try extractGeomOptions(vm, parsed, "cylinder");
    if (parsed.pos_count > 0) opts.r = try util.requireNumber(vm, args[0], "cylinder", "r");
    if (parsed.pos_count > 1) opts.h = try util.requireNumber(vm, args[1], "cylinder", "h");
    if (parsed.pos_count > 2) opts.center = try util.requireBool(vm, args[2], "cylinder", "center");

    const r1 = opts.r1 orelse opts.r;
    const r2 = opts.r2 orelse opts.r;

    try util.requirePositive(vm, r1, "cylinder", "radius 1");
    try util.requirePositive(vm, r2, "cylinder", "radius 2");
    try util.requirePositive(vm, opts.h, "cylinder", "height");

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
    var opts = try extractGeomOptions(vm, parsed, "sphere");
    if (parsed.pos_count > 0) opts.r = try util.requireNumber(vm, args[0], "sphere", "r");
    try util.requirePositive(vm, opts.r, "sphere", "radius");
    const dag_idx = try vm.dag_builder.addSphere(opts.r);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeCircle(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = try extractGeomOptions(vm, parsed, "circle");

    if (parsed.pos_count > 0) opts.r = try util.requireNumber(vm, args[0], "circle", "r");
    try util.requirePositive(vm, opts.r, "circle", "radius");

    if (opts.segments == 0) {
        const active_config = vm.config_stack.items[vm.config_stack.items.len - 1];
        opts.segments = util.clampSegments(active_config.manifold.getSegments(opts.r));
    }

    const dag_idx = try vm.dag_builder.addCircle(opts.r, opts.segments);
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativePolygon(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    if (parsed.pos_count < 1) {
        _ = vm.raiseError(.ArgumentError, "polygon expects an Array of [x, y] points", .{});
        return error.RuntimeError;
    }
    const pt_arr = try util.requireArray(vm, args[0], "polygon", "points");
    try requireMinCount(vm, pt_arr.len, MIN_CONTOUR_POINTS, "polygon", "points");

    // `paths` is the second positional argument or the `paths:` kwarg (which wins).
    var paths_val: value.Value = value.Value.initNil();
    if (parsed.pos_count > 1) paths_val = args[1];
    if (parsed.kwargs) |kw| {
        if (util.getKey(kw.asMap(), "paths")) |v| paths_val = v;
    }

    // Not the scratch arena: a validation error below raises through
    // raiseError, whose backtrace capture resets that arena under us.
    const alloc = vm.allocator;

    // Every point is validated, including ones no path references.
    const pts = try alloc.alloc([2]f64, pt_arr.len);
    defer alloc.free(pts);
    for (pt_arr, pts, 0..) |pt_val, *pt, i| pt.* = try util.parsePoint(2, vm, pt_val, "polygon", i);

    if (paths_val.isNil()) {
        // Standard Single-Contour Polygon
        const dag_idx = try vm.dag_builder.addPolygon(pts);
        return try vm.allocateCrossSection(dag_idx);
    }

    // Build Multi-Contour Polygon (Supports Holes via Even-Odd rule)
    const paths = try util.requireArray(vm, paths_val, "polygon", "paths");
    const contours = try alloc.alloc([]const [2]f64, paths.len);
    // Initialize so the deferred free is safe if validation fails part-way.
    @memset(contours, &.{});
    defer {
        for (contours) |c| alloc.free(c);
        alloc.free(contours);
    }

    for (paths, 0..) |path_val, c_idx| {
        // Labels are formatted only on the error path (see util.NumberArray).
        var label_buf: [MAX_LABEL_LEN]u8 = undefined;
        if (!path_val.isArray()) {
            const path_name = std.fmt.bufPrint(&label_buf, "path {d}", .{c_idx}) catch "a path";
            _ = try util.requireArray(vm, path_val, "polygon", path_name);
        }
        const indices = path_val.asArray().items.items;
        if (indices.len < MIN_CONTOUR_POINTS) {
            const count_what = std.fmt.bufPrint(&label_buf, "point indices in path {d}", .{c_idx}) catch "point indices per path";
            try requireMinCount(vm, indices.len, MIN_CONTOUR_POINTS, "polygon", count_what);
        }

        const contour = try alloc.alloc([2]f64, indices.len);
        contours[c_idx] = contour;
        for (indices, contour, 0..) |idx_val, *pt, p_idx| {
            const raw = if (idx_val.isNumber() and std.math.isFinite(idx_val.asNumber()))
                idx_val.asNumber()
            else blk: {
                const what = std.fmt.bufPrint(&label_buf, "a point index (path {d}, entry {d})", .{ c_idx, p_idx }) catch "a point index";
                break :blk try util.requireNumber(vm, idx_val, "polygon", what);
            };
            pt.* = pts[try checkedIndex(vm, raw, pts.len, "polygon path")];
        }
    }
    const dag_idx = try vm.dag_builder.addPolygonsEvenOdd(contours);
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativeRegularPolygon(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    var opts = try extractGeomOptions(vm, parsed, "regular_polygon");

    var sides: i32 = 6; // Default to a hexagon
    if (parsed.pos_count > 0) sides = try util.checkedInt(i32, vm, try util.requireNumber(vm, args[0], "regular_polygon", "sides"), "sides");
    if (parsed.pos_count > 1) opts.r = try util.requireNumber(vm, args[1], "regular_polygon", "r");

    // Check kwargs explicitly for sides/radius if passed
    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map = kw.asMap();
            if (util.getKey(map, "sides")) |v| {
                sides = try util.checkedInt(i32, vm, try util.requireNumber(vm, v, "regular_polygon", "sides"), "sides");
            }
        }
    }

    if (sides < MIN_CONTOUR_POINTS or sides > limits.MAX_SEGMENTS) {
        _ = vm.raiseError(.ValueError, "'sides' must be between {d} and {d}, got {d}", .{ MIN_CONTOUR_POINTS, limits.MAX_SEGMENTS, sides });
        return error.RuntimeError;
    }
    try util.requirePositive(vm, opts.r, "regular_polygon", "radius");

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
    const opts = try extractGeomOptions(vm, parsed, "torus");

    var major_r: f64 = 10.0;
    var minor_r: f64 = 2.0;

    if (parsed.pos_count > 0) major_r = try util.requireNumber(vm, args[0], "torus", "major_r");
    if (parsed.pos_count > 1) minor_r = try util.requireNumber(vm, args[1], "torus", "minor_r");

    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map = kw.asMap();
            if (util.getKey(map, "major_r")) |v| major_r = try util.requireNumber(vm, v, "torus", "major_r");
            if (util.getKey(map, "minor_r")) |v| minor_r = try util.requireNumber(vm, v, "torus", "minor_r");
        }
    }

    try util.requirePositive(vm, major_r, "torus", "major_r");
    try util.requirePositive(vm, minor_r, "torus", "minor_r");

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
    if (args.len < 2) {
        _ = vm.raiseError(.ArgumentError, "polyhedron expects a points Array and a faces Array", .{});
        return error.RuntimeError;
    }
    const pts_val = try util.requireArray(vm, args[0], "polyhedron", "points");
    const faces_val = try util.requireArray(vm, args[1], "polyhedron", "faces");
    try requireMinCount(vm, pts_val.len, MIN_POLYHEDRON_POINTS, "polyhedron", "points");
    try requireMinCount(vm, faces_val.len, MIN_POLYHEDRON_FACES, "polyhedron", "faces");

    // Not the scratch arena: a validation error below raises through
    // raiseError, whose backtrace capture resets that arena under us.
    const alloc = vm.allocator;

    const pts = try alloc.alloc([3]f64, pts_val.len);
    defer alloc.free(pts);
    for (pts_val, pts, 0..) |p, *pt, i| pt.* = try util.parsePoint(3, vm, p, "polyhedron", i);

    const faces = try alloc.alloc([3]u32, faces_val.len);
    defer alloc.free(faces);

    for (faces_val, faces, 0..) |f, *face, i| {
        // A quad used to be silently truncated to its first triangle.
        if (f.isArray() and f.asArray().items.items.len != POLYHEDRON_FACE_LEN) {
            _ = vm.raiseError(.ValueError, "polyhedron faces must be triangles ({d} point indices), but face {d} has {d}", .{ POLYHEDRON_FACE_LEN, i, f.asArray().items.items.len });
            return error.RuntimeError;
        }
        const raw = try util.parseNumberArray(POLYHEDRON_FACE_LEN, vm, f, .{
            .method = "polyhedron",
            .name = "face",
            .row = i,
            .elem = "a point index",
            .index_label = "entry",
        }, POLYHEDRON_FACE_LEN, 0.0);
        // Kernels index points[] directly with these, so they must be in range.
        for (raw, face) |r, *c| c.* = @intCast(try checkedIndex(vm, r, pts.len, "polyhedron face"));
    }
    const dag_idx = try vm.dag_builder.addPolyhedron(pts, faces);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeText(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = parseArgs(args);
    if (parsed.pos_count == 0 or !args[0].isString()) {
        _ = vm.raiseError(.ArgumentError, "text() expects a String as its first argument", .{});
        return error.RuntimeError;
    }
    const text_str = args[0].asString().chars;
    var size: f64 = 10.0;
    var font_name: []const u8 = "sans";
    var tolerance: f64 = 0.1;
    var halign: text_mod.HAlign = .left;
    var valign: text_mod.VAlign = .baseline;

    if (parsed.pos_count > 1) size = try util.requireNumber(vm, args[1], "text", "size");

    if (parsed.kwargs) |kw| {
        if (kw.isObject() and kw.asObj().obj_type == .map) {
            const map = kw.asMap();
            if (util.getKey(map, "size")) |v| size = try util.requireNumber(vm, v, "text", "size");
            if (util.getKey(map, "tolerance")) |v| tolerance = try util.requireNumber(vm, v, "text", "tolerance");
            if (util.getKey(map, "font")) |v| font_name = try util.requireName(vm, v, "text", "font");
            if (util.getKey(map, "halign")) |v| {
                const name = try util.requireName(vm, v, "text", "halign");
                // An unknown alignment used to fall back to the default silently.
                halign = std.meta.stringToEnum(text_mod.HAlign, name) orelse {
                    _ = vm.raiseError(.ValueError, "text halign must be left, center or right, got '{s}'", .{name});
                    return error.RuntimeError;
                };
            }
            if (util.getKey(map, "valign")) |v| {
                const name = try util.requireName(vm, v, "text", "valign");
                valign = std.meta.stringToEnum(text_mod.VAlign, name) orelse {
                    _ = vm.raiseError(.ValueError, "text valign must be baseline, bottom, center or top, got '{s}'", .{name});
                    return error.RuntimeError;
                };
            }
        }
    }

    try util.requirePositive(vm, size, "text", "size");
    try util.requirePositive(vm, tolerance, "text", "tolerance");
    // Bezier flattening recurses until the chord error is below `tolerance`, so the
    // point count grows ~sqrt(size / tolerance) per curve; a vanishing tolerance
    // (e.g. 1e-300, whose square underflows to 0) never terminates in practice.
    if (tolerance < size * MIN_TEXT_TOLERANCE_RATIO) {
        _ = vm.raiseError(.ValueError, "'tolerance' must be at least size * {d} ({d}), got {f}", .{ MIN_TEXT_TOLERANCE_RATIO, size * MIN_TEXT_TOLERANCE_RATIO, value.fmtNumber(tolerance) });
        return error.RuntimeError;
    }

    const alloc = vm.scratch_arena.allocator();

    const face = text_mod.getFaceByName(font_name) catch {
        _ = vm.raiseError(.RuntimeError, "Failed to load font '{s}'", .{font_name});
        return error.RuntimeError;
    };
    var polygons = text_mod.extractText(alloc, &face, text_str, size, tolerance, halign, valign) catch {
        _ = vm.raiseError(.RuntimeError, "Failed to extract text contours", .{});
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
