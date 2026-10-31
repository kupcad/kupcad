//! The primitive constructors (`cube`, `cylinder`, `sphere`, `torus`, `polyhedron`,
//! `square`, `circle`, `polygon`, `regular_polygon`, `text`): each one's `Signature`, its
//! argument checks, and the `native*` function that adds the shape to the geometry DAG.

const std = @import("std");
const rounded_rect = @import("../core/rounded_rect.zig");
const value = @import("../core/value.zig");
const arguments = @import("arguments.zig");
const Signature = @import("signature.zig").Signature;
const VM = @import("../vm/vm.zig").VM;
const text_mod = @import("../core/text.zig");
const limits = @import("../core/limits.zig");
const triangulate = @import("../core/triangulate.zig");
const affine2 = @import("../core/affine2.zig");
const path_mod = @import("../core/path.zig");
const path_corners = @import("../core/path_corners.zig");
const path_natives = @import("paths.zig");

/// The names of one option. Two of a group in one call are an error: `d:` silently beat
/// `r:`, `radius:` both, `size:` an `x:`.
const ALIAS_GROUPS = [_][]const []const u8{
    &.{ "r", "d", "radius" },
    &.{ "r1", "d1" },
    &.{ "r2", "d2" },
    &.{ "size", "x" },
    &.{ "size", "y" },
    &.{ "size", "z" },
    // A corner is rounded or cut, not both (`round_r` silently won)
    &.{ "round_r", "chamfer" },
    // A regular polygon's size, by its corners or by its flats
    &.{ "r", "across_flats" },
    &.{ "d", "across_flats" },
    &.{ "radius", "across_flats" },
};

/// Why a polygon whose corners are rounded or cut can't repeat a point.
const EASED_SIDES = "round_r: and chamfer: need each side to have a length";

/// Smallest allowed text() flattening tolerance relative to the glyph size.
const MIN_TEXT_TOLERANCE_RATIO: f64 = 1e-4;

// What each primitive takes (see signature.zig). The runtime parses its keywords from it,
// and `kupcad check` reads its sizes to flag `cube(-5)` before the script runs.
pub const CUBE = Signature{
    .positional = &.{ "x", "y", "z", "center" },
    .single = "size",
    .keywords = &.{ "x", "y", "z", "size", "center", "round_r", "chamfer", "segments" },
    .sizes = &.{ "x", "y", "z", "size" },
};
pub const SQUARE = Signature{
    .positional = &.{ "x", "y", "center" },
    .single = "size",
    .keywords = &.{ "x", "y", "size", "center", "round_r", "chamfer", "segments" },
    .sizes = &.{ "x", "y", "size" },
};
pub const CYLINDER = Signature{
    .positional = &.{ "r", "h", "center" },
    .keywords = &.{ "r", "r1", "r2", "d", "d1", "d2", "radius", "h", "center", "round_r", "chamfer", "segments", "sides" },
    .sizes = &.{ "r", "r1", "r2", "d", "d1", "d2", "radius", "h" },
};
pub const SPHERE = Signature{
    .positional = &.{"r"},
    .keywords = &.{ "r", "d", "radius", "segments" },
    .sizes = &.{ "r", "d", "radius" },
};
pub const CIRCLE = Signature{
    .positional = &.{"r"},
    .keywords = &.{ "r", "d", "radius", "segments", "sides" },
    .sizes = &.{ "r", "d", "radius" },
};
/// The sides of a regular_polygon given none: a hexagon.
const REGULAR_POLYGON_SIDES = 6;
pub const REGULAR_POLYGON = Signature{
    .positional = &.{ "sides", "r" },
    .keywords = &.{ "sides", "r", "d", "radius", "across_flats" },
    .sizes = &.{ "r", "d", "radius", "across_flats" },
};
pub const TORUS = Signature{
    .positional = &.{ "major_r", "minor_r" },
    .keywords = &.{ "major_r", "minor_r", "segments" },
    .sizes = &.{ "major_r", "minor_r" },
};
pub const POLYGON = Signature{
    .positional = &.{ "points", "paths" },
    .keywords = &.{ "paths", "round_r", "chamfer", "segments" },
    .sizes = &.{ "round_r", "chamfer" },
};
pub const POLYHEDRON = Signature{
    .positional = &.{ "points", "faces" },
    .keywords = &.{ "points", "faces" },
};
pub const TEXT = Signature{
    .positional = &.{ "content", "size" },
    .keywords = &.{ "size", "tolerance", "font", "halign", "valign" },
    .sizes = &.{ "size", "tolerance" },
};

/// Fewest points that enclose an area (a polygon contour).
const MIN_CONTOUR_POINTS = 3;
/// Fewest points and faces of a closed solid (a tetrahedron).
const MIN_POLYHEDRON_POINTS = 4;
const MIN_POLYHEDRON_FACES = 4;
/// The fewest corners a face has: a triangle.
const MIN_FACE_CORNERS = 3;
/// Room for an argument label such as "a point index (path 12, entry 345)".
const MAX_LABEL_LEN = 64;

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
    /// A faceted shape: a circle with this many straight sides is a regular polygon, a
    /// cylinder a prism. Unlike `segments` (how finely a curve is drawn, which the B-Rep
    /// engine keeps exact), it is the shape itself, so it is the same on both engines.
    sides: ?i32 = null,
    /// A regular polygon's width between opposite flats (a nut's wrench size), for `r`.
    across_flats: ?f64 = null,
    // Aliases, folded into the fields above by parseGeomOptions (a `size` Array by the
    // primitive, which knows how many it takes: sizeOf).
    size: ?value.Value = null,
    d: ?f64 = null,
    d1: ?f64 = null,
    d2: ?f64 = null,
    radius: ?f64 = null,
};

// --- Helpers ---

/// The primitives share GeomOptions; each accepts only the keywords it lists.
/// `base` holds what the positional arguments set; keywords override it.
fn parseGeomOptions(comptime accepted: []const []const u8, base: GeomOptions, vm: *VM, args: []const value.Value, method: []const u8) !arguments.Parsed(GeomOptions) {
    inline for (ALIAS_GROUPS) |group| {
        if (comptime acceptsAll(accepted, group)) try arguments.requireOneOf(vm, args, group, method);
    }
    var parsed = try arguments.parseKwargsOver(GeomOptions, base, accepted, vm, args, method);
    const opts = &parsed.opts;
    if (opts.size) |size| {
        if (size.isNumber()) {
            const n = try arguments.requireNumber(vm, size, method, "size");
            opts.x, opts.y, opts.z = .{ n, n, n };
        } else if (!size.isArray()) return vm.fail(.TypeError, "{s} expects a number or an Array of sizes for size, got {s}", .{ method, vm.typeName(size) });
    }
    if (opts.d) |d| opts.r = d / 2.0;
    if (opts.d1) |d1| opts.r1 = d1 / 2.0;
    if (opts.d2) |d2| opts.r2 = d2 / 2.0;
    if (opts.radius) |radius| opts.r = radius;
    try arguments.requireSegmentCount(vm, opts.segments, "segments");
    return parsed;
}

fn acceptsAll(comptime accepted: []const []const u8, comptime names: []const []const u8) bool {
    for (names) |name| {
        for (accepted) |a| {
            if (std.mem.eql(u8, a, name)) break;
        } else return false;
    }
    return true;
}

/// The sizes an Array gives a box of `N` sides (`cube([w, d, h])`, `square([w, d])`), for
/// x, y (and z).
fn sizeOf(comptime N: usize, vm: *VM, size: value.Value, comptime method: []const u8) ![N]f64 {
    return arguments.parseNumberArray(N, vm, size, .{ .method = method, .name = "the size", .elem = "a size", .index_label = "axis" }, N, 0);
}

/// Validates a user-supplied index into an array of length `len`.
fn checkedIndex(vm: *VM, raw: f64, len: usize, what: []const u8) !usize {
    if (!std.math.isFinite(raw) or raw < 0.0 or @trunc(raw) != raw or raw >= @as(f64, @floatFromInt(len)) or raw > std.math.maxInt(u32)) {
        return vm.fail(.ValueError, "{s} index {f} is out of range (0..{d})", .{ what, value.fmtNumber(raw), len });
    }
    return @intFromFloat(raw);
}

fn requireMinCount(vm: *VM, count: usize, min: usize, method: []const u8, what: []const u8) !void {
    if (count < min) {
        return vm.fail(.ValueError, "{s} needs at least {d} {s}, got {d}", .{ method, min, what, count });
    }
}

/// `sides` as a side count, or an error if it isn't one (or comes with `segments`, which
/// would ask for a smooth curve and a faceted one at once). It took the count from
/// `opts.sides` and assumed one, so `regular_polygon(sides: nil)` crashed.
fn requireSides(vm: *VM, sides: i32, opts: GeomOptions, method: []const u8) !i32 {
    if (sides < MIN_CONTOUR_POINTS or sides > limits.MAX_SEGMENTS) {
        return vm.fail(.ValueError, "'sides' must be between {d} and {d}, got {d}", .{ MIN_CONTOUR_POINTS, limits.MAX_SEGMENTS, sides });
    }
    if (opts.segments != 0) {
        return vm.fail(.ArgumentError, "{s} takes sides: (a faceted shape) or segments: (how smooth a round one is), not both", .{method});
    }
    return sides;
}

/// A regular polygon centred on the origin, its first corner on +x (as Manifold's circles).
fn addRegularPolygon(vm: *VM, sides: i32, r: f64) !u32 {
    var pts = std.ArrayList([2]f64).empty;
    const alloc = vm.scratch_arena.allocator();
    defer pts.deinit(alloc);
    const step = std.math.pi * 2.0 / @as(f64, @floatFromInt(sides));
    for (0..@as(usize, @intCast(sides))) |i| {
        const ang = @as(f64, @floatFromInt(i)) * step;
        try pts.append(alloc, .{ r * @cos(ang), r * @sin(ang) });
    }
    return vm.dag_builder.addPolygon(pts.items);
}

// --- Filleting Math Helpers ---

/// A rectangle with rounded corners (its own node, so a drawing knows the corners'
/// circles) or chamfered ones (a polygon).
fn buildRoundedRect(vm: *VM, x: f64, y: f64, center: bool, round_r: ?f64, chamfer: ?f64, segs: i32) !u32 {
    if (round_r) |r| {
        var rect = rounded_rect.RoundedRect{ .x = x, .y = y, .center = center, .radius = r, .segments = segs };
        rect.radius = rect.safeRadius();
        if (segs == 0) rect.segments = arguments.autoSegments(vm, rect.radius);
        return vm.dag_builder.addRoundedSquare(rect);
    }
    var pts = std.ArrayList([2]f64).empty;
    // Temporary structures map to scratch_arena instead of standard allocator
    const alloc = vm.scratch_arena.allocator();
    defer pts.deinit(alloc);

    const hw = x / 2.0;
    const hh = y / 2.0;
    const cx = if (center) 0.0 else hw;
    const cy = if (center) 0.0 else hh;

    if (chamfer) |c| {
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
    const pos = arguments.positionalArgs(args);
    var base = GeomOptions{};
    if (pos.len > 0 and pos[0].isArray()) {
        // square([w, d], center)
        base.x, base.y = try sizeOf(2, vm, pos[0], "square");
        if (pos.len > 1) base.center = try arguments.requireBool(vm, pos[1], "square", "center");
        if (pos.len > 2) return vm.fail(.ArgumentError, "square takes its sizes as an Array or as x, y: [w, d] and center, got {d} positional arguments", .{pos.len});
    } else {
        if (pos.len > 0) {
            base.x = try arguments.requireNumber(vm, pos[0], "square", "x");
            base.y = base.x;
        }
        if (pos.len > 1) base.y = try arguments.requireNumber(vm, pos[1], "square", "y");
        if (pos.len > 2) base.center = try arguments.requireBool(vm, pos[2], "square", "center");
    }
    var opts = (try parseGeomOptions(SQUARE.keywords, base, vm, args, "square")).opts;
    if (opts.size) |size| if (size.isArray()) {
        opts.x, opts.y = try sizeOf(2, vm, size, "square");
    };

    try arguments.requirePositive(vm, opts.x, "square", "x");
    try arguments.requirePositive(vm, opts.y, "square", "y");

    var dag_idx: u32 = 0;
    if (opts.round_r != null or opts.chamfer != null) {
        dag_idx = try buildRoundedRect(vm, opts.x, opts.y, opts.center, opts.round_r, opts.chamfer, opts.segments);
    } else {
        dag_idx = try vm.dag_builder.addSquare(opts.x, opts.y, opts.center);
    }
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativeCube(vm: *VM, args: []const value.Value) !value.Value {
    const pos = arguments.positionalArgs(args);
    var base = GeomOptions{};
    if (pos.len > 0 and pos[0].isArray()) {
        // cube([w, d, h], center), as OpenSCAD writes one
        base.x, base.y, base.z = try sizeOf(3, vm, pos[0], "cube");
        if (pos.len > 1) base.center = try arguments.requireBool(vm, pos[1], "cube", "center");
        if (pos.len > 2) return vm.fail(.ArgumentError, "cube takes its sizes as an Array or as x, y, z: [w, d, h] and center, got {d} positional arguments", .{pos.len});
    } else {
        if (pos.len > 0) {
            base.x = try arguments.requireNumber(vm, pos[0], "cube", "x");
            base.y = base.x;
            base.z = base.x;
        }
        if (pos.len > 1) base.y = try arguments.requireNumber(vm, pos[1], "cube", "y");
        if (pos.len > 2) base.z = try arguments.requireNumber(vm, pos[2], "cube", "z");
        if (pos.len > 3) base.center = try arguments.requireBool(vm, pos[3], "cube", "center");
    }
    var opts = (try parseGeomOptions(CUBE.keywords, base, vm, args, "cube")).opts;
    if (opts.size) |size| if (size.isArray()) {
        opts.x, opts.y, opts.z = try sizeOf(3, vm, size, "cube");
    };

    try arguments.requirePositive(vm, opts.x, "cube", "x");
    try arguments.requirePositive(vm, opts.y, "cube", "y");
    try arguments.requirePositive(vm, opts.z, "cube", "z");

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
    const pos = arguments.positionalArgs(args);
    var base = GeomOptions{};
    if (pos.len > 0) base.r = try arguments.requireNumber(vm, pos[0], "cylinder", "r");
    if (pos.len > 1) base.h = try arguments.requireNumber(vm, pos[1], "cylinder", "h");
    if (pos.len > 2) base.center = try arguments.requireBool(vm, pos[2], "cylinder", "center");
    var opts = (try parseGeomOptions(CYLINDER.keywords, base, vm, args, "cylinder")).opts;

    const r1 = opts.r1 orelse opts.r;
    const r2 = opts.r2 orelse opts.r;

    try arguments.requirePositive(vm, r1, "cylinder", "radius 1");
    try arguments.requirePositive(vm, r2, "cylinder", "radius 2");
    try arguments.requirePositive(vm, opts.h, "cylinder", "height");

    if (opts.sides) |given_sides| {
        const sides = try requireSides(vm, given_sides, opts, "cylinder");
        if (opts.round_r != null or opts.chamfer != null) {
            return vm.fail(.ArgumentError, "cylinder takes sides: or round_r:/chamfer:, not both yet", .{});
        }
        // A prism (a frustum when r2 differs): the polygon swept up, narrowing to r2.
        const outline = try addRegularPolygon(vm, sides, r1);
        var prism = try vm.dag_builder.addExtrude(outline, opts.h, 0, 0.0, r2 / r1, r2 / r1);
        if (opts.center) prism = try vm.dag_builder.addTranslate(prism, 0.0, 0.0, -opts.h / 2.0);
        return try vm.allocateGeometry(.{ .symbolic = prism });
    }

    // The corners' arcs follow `segments:` too (they took the resolution's count whatever
    // it said), else the resolution for their own radius
    const given_segments = opts.segments;
    if (opts.segments == 0) opts.segments = arguments.autoSegments(vm, @max(r1, r2));

    var dag_idx: u32 = 0;
    if (opts.round_r != null or opts.chamfer != null) {
        // Draw the right-half cross section using CCW winding (Bottom to Top)
        var pts = std.ArrayList([2]f64).empty;
        const alloc = vm.scratch_arena.allocator();
        defer pts.deinit(alloc);

        const y_min = if (opts.center) -opts.h / 2.0 else 0.0;
        const y_max = if (opts.center) opts.h / 2.0 else opts.h;

        // Bottom center axis
        try pts.append(alloc, .{ 0.0, y_min });

        if (opts.round_r) |rr| {
            const safe_r1 = @min(rr, @min(r1, opts.h / 2.0));
            const safe_r2 = @min(rr, @min(r2, opts.h / 2.0));

            const corner_segs: i32 = if (given_segments > 0) given_segments else arguments.autoSegments(vm, @max(safe_r1, safe_r2));
            const arc_segs = rounded_rect.quarterArcSegments(corner_segs);
            // Bottom Right Corner (sweep from -90 deg to 0)
            try rounded_rect.appendArc(alloc, &pts, r1 - safe_r1, y_min + safe_r1, safe_r1, -std.math.pi / 2.0, 0.0, arc_segs);
            // Top Right Corner (sweep from 0 to 90 deg)
            try rounded_rect.appendArc(alloc, &pts, r2 - safe_r2, y_max - safe_r2, safe_r2, 0.0, std.math.pi / 2.0, arc_segs);
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
    const pos = arguments.positionalArgs(args);
    var base = GeomOptions{};
    if (pos.len > 0) base.r = try arguments.requireNumber(vm, pos[0], "sphere", "r");
    var opts = (try parseGeomOptions(SPHERE.keywords, base, vm, args, "sphere")).opts;
    try arguments.requirePositive(vm, opts.r, "sphere", "radius");
    if (opts.segments == 0) opts.segments = arguments.autoSegments(vm, opts.r);
    const dag_idx = try vm.dag_builder.addSphere(opts.r, opts.segments);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativeCircle(vm: *VM, args: []const value.Value) !value.Value {
    const pos = arguments.positionalArgs(args);
    var base = GeomOptions{};
    if (pos.len > 0) base.r = try arguments.requireNumber(vm, pos[0], "circle", "r");
    var opts = (try parseGeomOptions(CIRCLE.keywords, base, vm, args, "circle")).opts;
    try arguments.requirePositive(vm, opts.r, "circle", "radius");
    if (opts.sides) |sides| return try vm.allocateCrossSection(try addRegularPolygon(vm, try requireSides(vm, sides, opts, "circle"), opts.r));

    if (opts.segments == 0) opts.segments = arguments.autoSegments(vm, opts.r);

    const dag_idx = try vm.dag_builder.addCircle(opts.r, opts.segments);
    return try vm.allocateCrossSection(dag_idx);
}

pub fn nativePolygon(vm: *VM, args: []const value.Value) !value.Value {
    const Opts = struct { paths: ?value.Value = null, round_r: ?f64 = null, chamfer: ?f64 = null, segments: i32 = 0 };
    try arguments.requireOneOf(vm, args, &.{ "round_r", "chamfer" }, "polygon");
    const parsed = try arguments.parseKwargsSubset(Opts, POLYGON.keywords, vm, args, "polygon");
    if (parsed.positional.len < 1) {
        return vm.fail(.ArgumentError, "polygon expects an Array of [x, y] points", .{});
    }
    try arguments.requireSegmentCount(vm, parsed.opts.segments, "segments");
    const pt_arr = try arguments.requireArray(vm, args[0], "polygon", "points");
    try requireMinCount(vm, pt_arr.len, MIN_CONTOUR_POINTS, "polygon", "points");

    // `paths` is the second positional argument or the `paths:` kwarg (which wins).
    var paths_val: value.Value = value.Value.initNil();
    if (parsed.positional.len > 1) paths_val = args[1];
    if (parsed.opts.paths) |v| paths_val = v;

    const alloc = vm.allocator;

    // Every point is validated, including ones no path references.
    const pts = try alloc.alloc([2]f64, pt_arr.len);
    defer alloc.free(pts);
    for (pt_arr, pts, 0..) |pt_val, *pt, i| pt.* = try arguments.parsePoint(2, vm, pt_val, "polygon", i);

    const ease: ?path_corners.Ease = if (parsed.opts.round_r) |r| .{ .round = r } else if (parsed.opts.chamfer) |c| .{ .chamfer = c } else null;
    if (ease) |how| {
        if (!paths_val.isNil()) return vm.fail(.ArgumentError, "polygon takes paths: or round_r:/chamfer:, not both yet", .{});
        return easedPolygon(vm, pts, how, parsed.opts.segments);
    }

    if (paths_val.isNil()) {
        // Standard Single-Contour Polygon
        const dag_idx = try vm.dag_builder.addPolygon(pts);
        return try vm.allocateCrossSection(dag_idx);
    }

    // Build Multi-Contour Polygon (Supports Holes via Even-Odd rule)
    const paths = try arguments.requireArray(vm, paths_val, "polygon", "paths");
    const contours = try alloc.alloc([]const [2]f64, paths.len);
    // Initialize so the deferred free is safe if validation fails part-way.
    @memset(contours, &.{});
    defer {
        for (contours) |c| alloc.free(c);
        alloc.free(contours);
    }

    for (paths, 0..) |path_val, c_idx| {
        // Labels are formatted only on the error path (see arguments.NumberArray).
        var label_buf: [MAX_LABEL_LEN]u8 = undefined;
        if (!path_val.isArray()) {
            const path_name = std.mem.print(&label_buf, "path {d}", .{c_idx}) catch "a path";
            _ = try arguments.requireArray(vm, path_val, "polygon", path_name);
        }
        const indices = path_val.asArray().items.items;
        if (indices.len < MIN_CONTOUR_POINTS) {
            const count_what = std.mem.print(&label_buf, "point indices in path {d}", .{c_idx}) catch "point indices per path";
            try requireMinCount(vm, indices.len, MIN_CONTOUR_POINTS, "polygon", count_what);
        }

        const contour = try alloc.alloc([2]f64, indices.len);
        contours[c_idx] = contour;
        for (indices, contour, 0..) |idx_val, *pt, p_idx| {
            const raw = if (idx_val.isNumber() and std.math.isFinite(idx_val.asNumber()))
                idx_val.asNumber()
            else blk: {
                const what = std.mem.print(&label_buf, "a point index (path {d}, entry {d})", .{ c_idx, p_idx }) catch "a point index";
                break :blk try arguments.requireNumber(vm, idx_val, "polygon", what);
            };
            pt.* = pts[try checkedIndex(vm, raw, pts.len, "polygon path")];
        }
    }
    const dag_idx = try vm.dag_builder.addPolygonsEvenOdd(contours, &.{});
    return try vm.allocateCrossSection(dag_idx);
}

/// The polygon through `pts` with each corner rounded or cut as `how` says: the closed path
/// of its sides eased (core/path_corners.zig), its arcs drawn with `per_turn` chords a turn
/// (0: the resolution's) and known to a drawing.
fn easedPolygon(vm: *VM, pts: []const [2]f64, how: path_corners.Ease, per_turn: i32) !value.Value {
    const size_name = if (how == .round) "round_r" else "chamfer";
    try arguments.requirePositive(vm, how.size(), "polygon", size_name);
    const sides = try vm.allocator.alloc(path_mod.Segment, pts.len);
    defer vm.allocator.free(sides);
    for (sides, 0..) |*side, i| {
        const to = pts[(i + 1) % pts.len];
        if (to[0] == pts[i][0] and to[1] == pts[i][1]) {
            if (i + 1 == pts.len) return vm.fail(.ValueError, "polygon's last point repeats its first, [{f}, {f}] (a polygon closes itself): " ++ EASED_SIDES, .{ value.fmtNumber(to[0]), value.fmtNumber(to[1]) });
            return vm.fail(.ValueError, "polygon point {d} repeats the one before it, [{f}, {f}]: " ++ EASED_SIDES, .{ i + 1, value.fmtNumber(to[0]), value.fmtNumber(to[1]) });
        }
        side.* = .{ .to = to };
    }
    const eased = try path_natives.easeCorners(vm, pts[0], sides, true, how, "polygon", size_name);
    defer eased.deinit(vm.allocator);
    return path_natives.closedSketch(vm, eased.start, eased.segments, per_turn);
}

pub fn nativeRegularPolygon(vm: *VM, args: []const value.Value) !value.Value {
    const pos = arguments.positionalArgs(args);
    var base = GeomOptions{ .sides = REGULAR_POLYGON_SIDES };
    if (pos.len > 0) base.sides = try arguments.checkedInt(i32, vm, try arguments.requireNumber(vm, pos[0], "regular_polygon", "sides"), "sides");
    if (pos.len > 1) base.r = try arguments.requireNumber(vm, pos[1], "regular_polygon", "r");
    const opts = (try parseGeomOptions(REGULAR_POLYGON.keywords, base, vm, args, "regular_polygon")).opts;
    // `sides: nil` is a keyword not given, as for circle: the default, not a missing count
    const sides = try requireSides(vm, opts.sides orelse REGULAR_POLYGON_SIDES, opts, "regular_polygon");
    var r = opts.r;
    if (opts.across_flats) |across| {
        // Opposite flats are parallel only with an even number of sides
        if (@rem(sides, 2) != 0) return vm.fail(.ArgumentError, "regular_polygon takes across_flats: with an even number of sides (a hex nut's 6), got {d}", .{sides});
        try arguments.requirePositive(vm, across, "regular_polygon", "across_flats");
        r = across / (2 * @cos(std.math.pi / @as(f64, @floatFromInt(sides))));
    }
    try arguments.requirePositive(vm, r, "regular_polygon", "radius");
    return try vm.allocateCrossSection(try addRegularPolygon(vm, sides, r));
}

pub fn nativeTorus(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = try arguments.parseKwargsSubset(struct { major_r: ?f64 = null, minor_r: ?f64 = null, segments: i32 = 0 }, TORUS.keywords, vm, args, "torus");
    const opts = parsed.opts;
    try arguments.requireSegmentCount(vm, opts.segments, "segments");

    var major_r: f64 = 10.0;
    var minor_r: f64 = 2.0;

    if (parsed.positional.len > 0) major_r = try arguments.requireNumber(vm, args[0], "torus", "major_r");
    if (parsed.positional.len > 1) minor_r = try arguments.requireNumber(vm, args[1], "torus", "minor_r");
    if (opts.major_r) |r| major_r = r;
    if (opts.minor_r) |r| minor_r = r;

    try arguments.requirePositive(vm, major_r, "torus", "major_r");
    try arguments.requirePositive(vm, minor_r, "torus", "minor_r");
    if (minor_r >= major_r) {
        // The tube would reach (or cross) the axis and the revolved solid would intersect itself.
        return vm.fail(.ValueError, "torus needs minor_r smaller than major_r, got minor_r {f} and major_r {f}", .{ value.fmtNumber(minor_r), value.fmtNumber(major_r) });
    }

    // Create a 2D circle using the minor radius
    const circ_segs = if (opts.segments > 0) opts.segments else arguments.autoSegments(vm, minor_r);
    const circ_idx = try vm.dag_builder.addCircle(minor_r, circ_segs);

    // Translate the circle outward by the major radius
    const trans_mat = affine2.translation(major_r, 0);
    const trans_idx = try vm.dag_builder.addCrossSectionTransform(circ_idx, trans_mat);

    // Revolve the translated circle 360 degrees around the origin
    const rev_segs = if (opts.segments > 0) opts.segments else arguments.autoSegments(vm, major_r);
    const dag_idx = try vm.dag_builder.addRevolve(trans_idx, rev_segs, 360.0);

    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

pub fn nativePolyhedron(vm: *VM, args: []const value.Value) !value.Value {
    // `points` and `faces` are positional or kwargs (which win), like polygon's `paths`.
    const parsed = try arguments.parseKwargsSubset(struct { points: ?value.Value = null, faces: ?value.Value = null }, POLYHEDRON.keywords, vm, args, "polyhedron");
    const pos = parsed.positional;
    const points_arg = parsed.opts.points orelse if (pos.len > 0) pos[0] else null;
    const faces_arg = parsed.opts.faces orelse if (pos.len > 1) pos[1] else null;
    if (points_arg == null or faces_arg == null) {
        return vm.fail(.ArgumentError, "polyhedron expects a points Array and a faces Array", .{});
    }
    const pts_val = try arguments.requireArray(vm, points_arg.?, "polyhedron", "points");
    const faces_val = try arguments.requireArray(vm, faces_arg.?, "polyhedron", "faces");
    try requireMinCount(vm, pts_val.len, MIN_POLYHEDRON_POINTS, "polyhedron", "points");
    try requireMinCount(vm, faces_val.len, MIN_POLYHEDRON_FACES, "polyhedron", "faces");

    const alloc = vm.allocator;

    const pts = try alloc.alloc([3]f64, pts_val.len);
    defer alloc.free(pts);
    for (pts_val, pts, 0..) |p, *pt, i| pt.* = try arguments.parsePoint(3, vm, p, "polyhedron", i);

    // A face of more corners is triangles to the kernels (core/triangulate.zig): a quad was
    // once silently cut to its first triangle, then refused
    var faces: std.ArrayList([3]u32) = .empty;
    defer faces.deinit(alloc);
    var corners: std.ArrayList(u32) = .empty;
    defer corners.deinit(alloc);
    for (faces_val, 0..) |f, i| {
        if (!f.isArray()) return vm.fail(.TypeError, "polyhedron expects an Array for face {d}, got {s}", .{ i, vm.typeName(f) });
        const items = f.asArray().items.items;
        if (items.len < MIN_FACE_CORNERS) return vm.fail(.ValueError, "polyhedron face {d} has {d} corners; a face has at least {d}", .{ i, items.len, MIN_FACE_CORNERS });
        if (items.len > limits.MAX_FACE_CORNERS) return vm.fail(.ValueError, "polyhedron face {d} has {d} corners; a face has at most {d}", .{ i, items.len, limits.MAX_FACE_CORNERS });
        corners.clearRetainingCapacity();
        for (items, 0..) |item, k| {
            if (!item.isNumber()) return vm.fail(.TypeError, "polyhedron expects a number for a point index (face {d}, entry {d}), got {s}", .{ i, k, vm.typeName(item) });
            // Kernels index points[] directly with these, so they must be in range.
            const corner: u32 = @intCast(try checkedIndex(vm, item.asNumber(), pts.len, "polyhedron face"));
            if (std.mem.findScalar(u32, corners.items, corner) != null) return vm.fail(.ValueError, "polyhedron face {d} has point {d} twice", .{ i, corner });
            try corners.append(alloc, corner);
        }
        triangulate.face(alloc, pts, corners.items, &faces) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Degenerate => return vm.fail(.ValueError, "polyhedron face {d} encloses no area: its corners are in a line", .{i}),
            error.SelfIntersecting => return vm.fail(.ValueError, "polyhedron face {d} can't be cut into triangles: seen on its plane, its outline crosses itself (a face's corners lie in one plane, in order around it)", .{i}),
        };
    }
    const dag_idx = try vm.dag_builder.addPolyhedron(pts, faces.items);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}

/// The font `text` draws in, and its name for errors.
const TextFont = struct { face: text_mod.Face, name: []const u8 };

/// The font `font:` names: an embedded one by name (a String or a Symbol; nil is sans), or a
/// Font a script imported, whose face borrows its bytes (the argument keeps it alive).
fn textFont(vm: *VM, font: value.Value) !TextFont {
    if (font.isFont()) {
        const imported = font.asFont();
        // Checked when it was imported, from the same bytes
        const face = text_mod.importedFace(imported.bytes) catch {
            return vm.fail(.RuntimeError, "text: the font '{s}' could not be read again", .{imported.name.chars});
        };
        return .{ .face = face, .name = imported.name.chars };
    }
    const name = if (font.isNil()) text_mod.FontKey.sans.name() else font.nameChars() orelse {
        return vm.fail(.TypeError, "text: font is the name of a font ({s}) or a Font imported from a font file, got {s}", .{ text_mod.FONT_LIST, vm.typeName(font) });
    };
    // An unknown name used to draw in sans without a word, so a typo went unseen
    const key = text_mod.FontKey.fromString(name) orelse {
        return vm.fail(.ArgumentError, "text: there is no font '{s}'; the fonts are {s}, or a Font imported from a font file", .{ name, text_mod.FONT_LIST });
    };
    const face = text_mod.getFace(key) catch {
        return vm.fail(.RuntimeError, "text: the font '{s}' could not be read", .{name});
    };
    return .{ .face = face, .name = key.name() };
}

pub fn nativeText(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = try arguments.parseKwargsSubset(struct {
        size: ?f64 = null,
        tolerance: ?f64 = null,
        font: ?value.Value = null,
        halign: text_mod.HAlign = .left,
        valign: text_mod.VAlign = .baseline,
    }, TEXT.keywords, vm, args, "text");
    if (parsed.positional.len == 0 or !args[0].isString()) {
        return vm.fail(.ArgumentError, "text() expects a String as its first argument", .{});
    }
    const text_str = args[0].asString().chars;
    const opts = parsed.opts;
    var size: f64 = 10.0;
    if (parsed.positional.len > 1) size = try arguments.requireNumber(vm, args[1], "text", "size");
    if (opts.size) |n| size = n;

    try arguments.requirePositive(vm, size, "text", "size");
    // By default the glyphs are drawn as finely as a circle the size of a letter's bowl
    // (half the text size) at the active resolution, never finer than the floor below.
    const tolerance = opts.tolerance orelse @max(vm.config().chordError(size / 2.0), size * MIN_TEXT_TOLERANCE_RATIO);
    try arguments.requirePositive(vm, tolerance, "text", "tolerance");
    // Bezier flattening recurses until the chord error is below `tolerance`, so the
    // point count grows ~sqrt(size / tolerance) per curve; a vanishing tolerance
    // (e.g. 1e-300, whose square underflows to 0) never terminates in practice.
    if (tolerance < size * MIN_TEXT_TOLERANCE_RATIO) {
        return vm.fail(.ValueError, "'tolerance' must be at least size * {d} ({d}), got {f}", .{ MIN_TEXT_TOLERANCE_RATIO, size * MIN_TEXT_TOLERANCE_RATIO, value.fmtNumber(tolerance) });
    }

    const alloc = vm.scratch_arena.allocator();

    const font = try textFont(vm, opts.font orelse value.Value.initNil());
    const font_name = font.name;
    const face = font.face;
    var polygons = text_mod.extractText(alloc, &face, text_str, size, tolerance, opts.halign, opts.valign) catch |err| switch (err) {
        error.InvalidUtf8 => {
            return vm.fail(.ValueError, "text: the String isn't valid UTF-8", .{});
        },
        error.MissingGlyph => {
            const cp = text_mod.firstMissingGlyph(&face, text_str) orelse 0;
            // A control character (a line break: text is one line) is named by its code alone.
            if (cp < 0x20 or cp == 0x7F) return vm.fail(.ValueError, "text: the font '{s}' has no glyph for U+{X:0>4} (text is one line, without control characters)", .{ font_name, cp });
            return vm.fail(.ValueError, "text: neither the font '{s}' nor the symbol font has a glyph for '{u}' (U+{X:0>4})", .{ font_name, cp, cp });
        },
        else => {
            return vm.fail(.RuntimeError, "Failed to extract text contours", .{});
        },
    };
    defer polygons.deinit(alloc);

    var contours = try alloc.alloc([]const [2]f64, polygons.contours.items.len);
    defer alloc.free(contours);

    for (polygons.contours.items, 0..) |c, i| {
        contours[i] = c.items;
    }

    const dag_idx = try vm.dag_builder.addPolygonsEvenOdd(contours, polygons.curves.items);
    return try vm.allocateCrossSection(dag_idx);
}
