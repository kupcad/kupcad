const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const util = @import("util.zig");
const limits = @import("../../core/limits.zig");

// A Sketch lies in the XY plane, so its transforms stay in that plane. A component that
// would move it out of the plane is a ValueError: it used to be dropped silently, so
// `translate(z: 5)` did nothing and `rotate(z: 45)` left the sketch unrotated.

/// Flat matrix lengths `transform` accepts: a column-major 3x4 affine matrix
/// (3x3 linear part, then the translation) for a Geometry, 2x3 for a CrossSection.
const MATRIX_3D_LEN = 12;
const MATRIX_2D_LEN = 6;

pub fn meshTranslate(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(vm, args, 0.0, "translate");
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        if (vec[2] != 0.0) {
            _ = vm.raiseError(.ValueError, "a Sketch can only translate in x and y (it lies in the XY plane), got z {f}; extrude it to lift it", .{value.fmtNumber(vec[2])});
            return error.RuntimeError;
        }
        const mat = [6]f64{ 1.0, 0.0, 0.0, 1.0, vec[0], vec[1] };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return util.notDefinedFor(vm, "translate", receiver);
}

pub fn meshRotate(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(vm, args, 0.0, "rotate");
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addRotate(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const rad = try sketchRotation(vm, args, vec) * std.math.pi / 180.0;
        const cos_a = std.math.cos(rad);
        const sin_a = std.math.sin(rad);
        const mat = [6]f64{ cos_a, sin_a, -sin_a, cos_a, 0.0, 0.0 };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return util.notDefinedFor(vm, "rotate", receiver);
}

/// A Sketch turns about z only: `rotate(a)` (OpenSCAD's 2D rotate), `rotate(z: a)` or
/// `rotate(0, 0, a)`, in degrees.
fn sketchRotation(vm: *VM, args: []const value.Value, vec: [3]f64) !f64 {
    const single_angle = args.len == 1 and util.trailingKwargs(args) == null;
    if (single_angle) return vec[0];
    if (vec[0] != 0.0 or vec[1] != 0.0) {
        _ = vm.raiseError(.ValueError, "a Sketch can only rotate about z (it lies in the XY plane), got x {f} and y {f}; extrude it to tilt it", .{ value.fmtNumber(vec[0]), value.fmtNumber(vec[1]) });
        return error.RuntimeError;
    }
    return vec[2];
}

pub fn meshScale(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(vm, args, 1.0, "scale");
    // A zero factor flattens the shape onto a plane: never a valid solid or sketch.
    // Subnormal factors are rejected too, since they collapse just the same. A
    // CrossSection ignores z, so only x and y are checked for it.
    const checked_axes: usize = if (receiver.isCrossSection()) 2 else 3;
    for (vec[0..checked_axes]) |f| {
        if (!(@abs(f) >= std.math.floatMin(f64))) {
            _ = vm.raiseError(.ValueError, "scale factors must be non-zero, got [{f}, {f}, {f}]", .{ value.fmtNumber(vec[0]), value.fmtNumber(vec[1]), value.fmtNumber(vec[2]) });
            return error.RuntimeError;
        }
    }
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addScale(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = [6]f64{ vec[0], 0.0, 0.0, vec[1], 0.0, 0.0 };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return util.notDefinedFor(vm, "scale", receiver);
}

pub fn meshCenter(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    // Signature: center(axes: String = "xyz")
    var axes_str: []const u8 = "xyz";
    if (args.len > 0 and args[0].isString()) {
        axes_str = args[0].asString().chars;
    }

    const bbox = try util.boundsOf(vm, receiver, "center");

    const cx = bbox.min[0] + (bbox.max[0] - bbox.min[0]) / 2.0;
    const cy = bbox.min[1] + (bbox.max[1] - bbox.min[1]) / 2.0;
    const cz = bbox.min[2] + (bbox.max[2] - bbox.min[2]) / 2.0;

    var tx: f64 = 0;
    var ty: f64 = 0;
    var tz: f64 = 0;

    for (axes_str) |c| {
        switch (c) {
            'x', 'X' => tx = -cx,
            'y', 'Y' => ty = -cy,
            'z', 'Z' => tz = -cz,
            else => {},
        }
    }

    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, tx, ty, tz);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = [6]f64{ 1.0, 0.0, 0.0, 1.0, tx, ty };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return util.notDefinedFor(vm, "center", receiver);
}

pub fn meshAlign(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    // Signature: align(target, axes, my_align, target_align = my_align, offset = 0.0)
    if (args.len < 3 or !args[1].isString() or !args[2].isString()) {
        _ = vm.raiseError(.ArgumentError, "align(target, axes, my_align, [target_align], [offset]) requires at least 3 args", .{});
        return error.RuntimeError;
    }

    const target = args[0];
    const axis_str = args[1].asString().chars;
    const my_align_str = args[2].asString().chars;
    var target_align_str = my_align_str;
    var offset: f64 = 0.0;

    if (args.len > 3) {
        if (args[3].isString()) {
            target_align_str = args[3].asString().chars;
        } else if (args[3].isNumber()) {
            // Allow skipping target_align: align(target, axes, my_align, offset)
            offset = try util.requireNumber(vm, args[3], "align", "offset");
        } else if (!args[3].isNil()) { // nil keeps target_align = my_align
            _ = vm.raiseError(.TypeError, "align expects a String target_align or a number offset as argument 4, got {s}", .{util.typeName(vm, args[3])});
            return error.RuntimeError;
        }
    }
    if (args.len > 4) offset = try util.requireNumber(vm, args[4], "align", "offset");

    // The target used to be evaluated as a Geometry whatever it was.
    if (!target.isGeometry() and !target.isCrossSection()) {
        _ = vm.raiseError(.TypeError, "align expects a Geometry or CrossSection to align to, got {s}", .{util.typeName(vm, target)});
        return error.RuntimeError;
    }
    const my_bbox = try util.boundsOf(vm, receiver, "align");
    const target_bbox = try util.boundsOf(vm, target, "align");

    var tx: f64 = 0;
    var ty: f64 = 0;
    var tz: f64 = 0;

    for (axis_str) |c| {
        var axis_idx: usize = 0;
        switch (c) {
            'x', 'X' => axis_idx = 0,
            'y', 'Y' => axis_idx = 1,
            'z', 'Z' => axis_idx = 2,
            else => continue,
        }

        const my_min = my_bbox.min[axis_idx];
        const my_max = my_bbox.max[axis_idx];
        const my_center = my_min + (my_max - my_min) / 2.0;

        const target_min = target_bbox.min[axis_idx];
        const target_max = target_bbox.max[axis_idx];
        const target_center = target_min + (target_max - target_min) / 2.0;

        var my_pt: f64 = 0.0;
        if (std.mem.eql(u8, my_align_str, "min")) my_pt = my_min else if (std.mem.eql(u8, my_align_str, "max")) my_pt = my_max else if (std.mem.eql(u8, my_align_str, "center")) my_pt = my_center else {
            _ = vm.raiseError(.ArgumentError, "invalid alignment '{s}' (use 'min', 'max', or 'center')", .{my_align_str});
            return error.RuntimeError;
        }

        var target_pt: f64 = 0.0;
        if (std.mem.eql(u8, target_align_str, "min")) target_pt = target_min else if (std.mem.eql(u8, target_align_str, "max")) target_pt = target_max else if (std.mem.eql(u8, target_align_str, "center")) target_pt = target_center else {
            _ = vm.raiseError(.ArgumentError, "invalid alignment '{s}' (use 'min', 'max', or 'center')", .{target_align_str});
            return error.RuntimeError;
        }

        const delta = target_pt - my_pt + offset;
        if (axis_idx == 0) tx = delta;
        if (axis_idx == 1) ty = delta;
        if (axis_idx == 2) tz = delta;
    }

    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, tx, ty, tz);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = [6]f64{ 1.0, 0.0, 0.0, 1.0, tx, ty };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return util.notDefinedFor(vm, "align", receiver);
}

pub fn meshMirror(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(vm, args, 0.0, "mirror");
    // The vector is the mirror plane's normal; the zero vector used to yield an empty solid.
    try util.requireNonZeroVector(vm, vec, "mirror", "plane normal");
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addMirror(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        // A Sketch mirrors across the line through the origin with normal (x, y).
        if (vec[2] != 0.0) {
            _ = vm.raiseError(.ValueError, "a Sketch can only mirror across a line in the XY plane, got a normal with z {f}", .{value.fmtNumber(vec[2])});
            return error.RuntimeError;
        }
        const len = std.math.hypot(vec[0], vec[1]);
        const nx = vec[0] / len;
        const ny = vec[1] / len;
        // The reflection I - 2nn^T (symmetric, so its column-major layout is the same).
        const mat = [6]f64{ 1.0 - 2.0 * nx * nx, -2.0 * nx * ny, -2.0 * nx * ny, 1.0 - 2.0 * ny * ny, 0.0, 0.0 };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return util.notDefinedFor(vm, "mirror", receiver);
}

pub fn meshTransform(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (args.len < 1) {
        _ = vm.raiseError(.ArgumentError, "transform expects a flat matrix Array", .{});
        return error.RuntimeError;
    }
    if (receiver.isGeometry()) {
        const mat = try parseMatrix(MATRIX_3D_LEN, vm, args[0]);
        // Column-major: columns are mat[0..3], mat[3..6], mat[6..9]; det = c0 . (c1 x c2).
        const det = mat[0] * (mat[4] * mat[8] - mat[5] * mat[7]) -
            mat[3] * (mat[1] * mat[8] - mat[2] * mat[7]) +
            mat[6] * (mat[1] * mat[5] - mat[2] * mat[4]);
        try requireInvertible(vm, det);
        const new_idx = try vm.dag_builder.addTransformMatrix(receiver.asGeometry().dag_idx, mat);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = try parseMatrix(MATRIX_2D_LEN, vm, args[0]);
        try requireInvertible(vm, mat[0] * mat[3] - mat[1] * mat[2]);
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return util.notDefinedFor(vm, "transform", receiver);
}

fn parseMatrix(comptime N: usize, vm: *VM, val: value.Value) ![N]f64 {
    // Exact length: extra entries (e.g. a flat 4x4) used to be silently dropped.
    return util.parseNumberArray(N, vm, val, .{
        .method = "transform",
        .name = "the matrix",
        .elem = "a matrix entry",
        .index_label = "index",
    }, N, 0.0);
}

/// A singular linear part collapses the shape onto a plane or line, like a zero scale.
fn requireInvertible(vm: *VM, det: f64) !void {
    // `!(>=)` also catches a NaN determinant (inf - inf from huge entries) and a
    // subnormal one, which flattens the shape as surely as an exact 0.
    if (!(@abs(det) >= std.math.floatMin(f64))) {
        _ = vm.raiseError(.ValueError, "transform matrix is singular (determinant {f}), which flattens the shape", .{value.fmtNumber(det)});
        return error.RuntimeError;
    }
}

pub fn meshResize(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "resize", receiver);
    const parsed = try util.parseKwargs(struct { auto: bool = false }, vm, args, "resize");
    const auto = parsed.opts.auto;

    if (parsed.positional.len < 1) {
        _ = vm.raiseError(.ArgumentError, "resize() requires an array of target dimensions [x, y, z]", .{});
        return error.RuntimeError;
    }
    // Missing trailing dimensions are 0, which means "keep" (or "auto" with auto: true).
    const target = try util.parseNumberArray(3, vm, args[0], .{
        .method = "resize",
        .name = "the target size",
        .elem = "a dimension",
    }, 1, 0.0);
    for (target, 0..) |t, i| {
        if (t < 0.0) {
            _ = vm.raiseError(.ValueError, "resize dimensions must be >= 0 (0 keeps that axis), got {f} at component {d}", .{ value.fmtNumber(t), i });
            return error.RuntimeError;
        }
    }
    const target_x = target[0];
    const target_y = target[1];
    const target_z = target[2];

    const bbox = try util.boundsOf(vm, receiver, "resize");
    const cur_x = bbox.max[0] - bbox.min[0];
    const cur_y = bbox.max[1] - bbox.min[1];
    const cur_z = bbox.max[2] - bbox.min[2];

    // Calculate required scale multipliers
    var sx: f64 = if (cur_x > 0.0 and target_x > 0.0) target_x / cur_x else 1.0;
    var sy: f64 = if (cur_y > 0.0 and target_y > 0.0) target_y / cur_y else 1.0;
    var sz: f64 = if (cur_z > 0.0 and target_z > 0.0) target_z / cur_z else 1.0;

    // Apply auto-scaling for axes specified as 0.0
    if (auto) {
        var auto_scale: f64 = 1.0;
        if (target_x > 0.0) {
            auto_scale = sx;
        } else if (target_y > 0.0) {
            auto_scale = sy;
        } else if (target_z > 0.0) {
            auto_scale = sz;
        }
        if (target_x <= 0.0) sx = auto_scale;
        if (target_y <= 0.0) sy = auto_scale;
        if (target_z <= 0.0) sz = auto_scale;
    }

    const new_idx = try vm.dag_builder.addScale(receiver.asGeometry().dag_idx, sx, sy, sz);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// Validates a pattern copy count. Counts <= 1 keep their old "no-op" meaning,
/// but NaN/inf/huge values would hit @intFromFloat UB or build millions of DAG nodes.
fn checkedCount(vm: *VM, raw: f64, what: []const u8) !usize {
    if (!std.math.isFinite(raw) or raw > @as(f64, @floatFromInt(limits.MAX_PATTERN_COUNT))) {
        _ = vm.raiseError(.ValueError, "{s} 'count' must be a finite number <= {d}, got {f}", .{ what, limits.MAX_PATTERN_COUNT, value.fmtNumber(raw) });
        return error.RuntimeError;
    }
    if (raw < 1.0) return 0;
    return @intFromFloat(raw);
}

pub fn meshRepeatLinear(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "repeat_linear", receiver);
    if (args.len < 1 or !args[0].isNumber()) {
        _ = vm.raiseError(.ArgumentError, "repeat_linear requires a 'count' number", .{});
        return error.RuntimeError;
    }

    const count = try checkedCount(vm, args[0].asNumber(), "repeat_linear");

    // The step is an [x, y, z] Array or positional/kwarg x, y, z (missing axes are 0).
    // It is validated even for a no-op count so a bad step never passes silently.
    // A nil step (e.g. a forwarded optional parameter) means no offset, as it did before.
    const step: [3]f64 = if (args.len > 1 and args[1].isNil())
        @splat(0.0)
    else if (args.len > 1 and args[1].isArray())
        try util.parseNumberArray(3, vm, args[1], .{ .method = "repeat_linear", .name = "the step" }, 1, 0.0)
    else
        try util.parseVec3(vm, args[1..], 0.0, "repeat_linear");
    if (count <= 1) return try vm.allocateGeometry(.{ .symbolic = receiver.asGeometry().dag_idx });
    const tx, const ty, const tz = step;

    const base_idx = receiver.asGeometry().dag_idx;
    var current_idx = base_idx;

    for (1..count) |i| {
        const factor: f64 = @floatFromInt(i);
        const next_idx = try vm.dag_builder.addTranslate(base_idx, tx * factor, ty * factor, tz * factor);
        current_idx = try vm.dag_builder.addBinary(.union_op, current_idx, next_idx);
    }

    return try vm.allocateGeometry(.{ .symbolic = current_idx });
}

pub fn meshRepeatPolar(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "repeat_polar", receiver);
    if (args.len < 1 or !args[0].isNumber()) {
        _ = vm.raiseError(.ArgumentError, "repeat_polar requires a 'count' number", .{});
        return error.RuntimeError;
    }

    const count = try checkedCount(vm, args[0].asNumber(), "repeat_polar");

    const parsed = try util.parseKwargs(struct { angle: ?f64 = null }, vm, args[1..], "repeat_polar");
    var total_angle: f64 = 360.0;
    if (parsed.positional.len > 0) total_angle = try util.requireNumber(vm, parsed.positional[0], "repeat_polar", "angle");
    if (parsed.opts.angle) |angle| total_angle = angle;
    if (count <= 1) return try vm.allocateGeometry(.{ .symbolic = receiver.asGeometry().dag_idx });

    const step_angle = if (@abs(total_angle - 360.0) < 0.001)
        total_angle / @as(f64, @floatFromInt(count))
    else
        total_angle / @as(f64, @floatFromInt(count - 1));

    const base_idx = receiver.asGeometry().dag_idx;
    var current_idx = base_idx;

    for (1..count) |i| {
        const rot_z = step_angle * @as(f64, @floatFromInt(i));
        const next_idx = try vm.dag_builder.addRotate(base_idx, 0, 0, rot_z);
        current_idx = try vm.dag_builder.addBinary(.union_op, current_idx, next_idx);
    }

    return try vm.allocateGeometry(.{ .symbolic = current_idx });
}
