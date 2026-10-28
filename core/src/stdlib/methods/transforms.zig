//! The transform methods of solids and sketches: `translate`, `rotate`, `scale`, `resize`,
//! `center`, `align`, `mirror`, `transform` (a flat affine matrix), `repeat_linear` and
//! `repeat_polar`. Listed in `manifest.zig`.

const std = @import("std");
const geom = @import("../../core/geometry_handle.zig");
const assembly = @import("../assembly.zig");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const arguments = @import("../arguments.zig");
const sig = @import("../method_signatures.zig");
const limits = @import("../../core/limits.zig");
const affine2 = @import("../../core/affine2.zig");
const placement = @import("../../core/placement.zig");

// A Sketch lies in the XY plane, so its transforms stay in that plane. A component that
// would move it out of the plane is a ValueError: it used to be dropped silently, so
// `translate(z: 5)` did nothing and `rotate(z: 45)` left the sketch unrotated.

/// Flat matrix lengths `transform` accepts: a column-major 3x4 affine matrix
/// (3x3 linear part, then the translation) for a Geometry, 2x3 for a CrossSection.
const MATRIX_3D_LEN = 12;
const MATRIX_2D_LEN = 6;

pub fn meshTranslate(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try arguments.parseVec3(vm, args, 0.0, "translate");
    if (receiver.isAssembly()) return assembly.translated(vm, receiver, vec);
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        if (vec[2] != 0.0) {
            return vm.fail(.ValueError, "a Sketch can only translate in x and y (it lies in the XY plane), got z {f}; extrude it to lift it", .{value.fmtNumber(vec[2])});
        }
        const mat = affine2.translation(vec[0], vec[1]);
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return arguments.notDefinedFor(vm, "translate", receiver);
}

/// `rotate(x, y, z)` in degrees, or `rotate(a)`: about z, for a Solid as for a Sketch
/// (OpenSCAD's default; one angle used to mean x on a Solid and z on a Sketch); `about:` a
/// point turns it about that point, and a Solid turns `rotate(a, axis: [x, y, z])` about
/// any axis (see parseRotation).
pub fn meshRotate(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (receiver.isGeometry()) {
        const turn = try parseRotation(vm, args, false, "a Solid", "");
        const a = turn.angles;
        var node = receiver.asGeometry().dag_idx;
        // About a point: there to the origin, turned, and back
        if (turn.about) |p| node = try vm.dag_builder.addTranslate(node, -p[0], -p[1], -p[2]);
        node = try vm.dag_builder.addRotate(node, a[0], a[1], a[2]);
        if (turn.about) |p| node = try vm.dag_builder.addTranslate(node, p[0], p[1], p[2]);
        return try vm.allocateGeometry(.{ .symbolic = node });
    } else if (receiver.isCrossSection()) {
        const mat = planarRotation(try parseRotation(vm, args, true, "a Sketch", "; extrude it to tilt it"));
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return arguments.notDefinedFor(vm, "rotate", receiver);
}

/// A turn as `rotate` is given it: the angles about x, y and z, in degrees, and the point
/// it turns about (the origin when null).
pub const Rotation = struct { angles: [3]f64, about: ?[3]f64 = null };

const RotateOpts = struct {
    x: ?value.Value = null,
    y: ?value.Value = null,
    z: ?value.Value = null,
    angle: ?f64 = null,
    axis: ?value.Value = null,
    about: ?value.Value = null,
};

/// The turn `rotate`'s arguments ask for: `rotate(x, y, z)` (or an Array, or x:, y:, z:),
/// `rotate(a)` or `rotate(angle: a)` about z, `rotate(a, axis: [x, y, z])` about that axis
/// (right-handed; placement.eulerOfAxisAngle makes it the three angles), and `about: [x, y,
/// z]` about that point. A `planar` shape (`what`, a Sketch or a Path) lies in the XY
/// plane: it turns about z only, about a point [x, y]; `tilt_hint` says how to tilt one.
pub fn parseRotation(vm: *VM, args: []const value.Value, planar: bool, comptime what: []const u8, comptime tilt_hint: []const u8) !Rotation {
    const parsed = try arguments.parseKwargsSubset(RotateOpts, sig.ROTATE.keywords, vm, args, "rotate");
    const o = parsed.opts;
    const pos = parsed.positional;
    const has_xyz = o.x != null or o.y != null or o.z != null;
    var turn: Rotation = .{ .angles = @splat(0) };
    if (o.axis) |axis_val| {
        if (planar) return vm.fail(.ArgumentError, "rotate: " ++ what ++ " turns about z only (it lies in the XY plane), so it takes no axis:", .{});
        if (has_xyz or pos.len > 1) return vm.fail(.ArgumentError, "rotate takes an angle with axis:, or angles x, y and z, not both", .{});
        const axis = try arguments.parseNumberArray(3, vm, axis_val, .{ .method = "rotate", .name = "the axis" }, 3, 0);
        try arguments.requireNonZeroVector(vm, axis, "rotate", "axis");
        if (o.angle != null and pos.len > 0) return vm.fail(.ArgumentError, "rotate takes its angle once, as a number or angle:", .{});
        const angle = o.angle orelse if (pos.len == 1) try arguments.requireNumber(vm, pos[0], "rotate", "angle") else return vm.fail(.ArgumentError, "rotate with axis: needs the angle to turn by, in degrees", .{});
        turn.angles = placement.eulerOfAxisAngle(axis, angle);
    } else if (o.angle) |angle| {
        if (has_xyz or pos.len > 0) return vm.fail(.ArgumentError, "rotate takes angle: (about z, or axis:) or angles x, y and z, not both", .{});
        turn.angles = .{ 0, 0, angle };
    } else {
        turn.angles = try arguments.vec3From(vm, pos, o, 0, "rotate");
        // One bare angle turns about z (copied out first: the literal is written straight
        // into `turn.angles`, and read a cleared x)
        if (pos.len == 1 and pos[0].isNumber() and !has_xyz) {
            const angle = turn.angles[0];
            turn.angles = .{ 0, 0, angle };
        }
    }
    if (planar and (turn.angles[0] != 0 or turn.angles[1] != 0)) {
        return vm.fail(.ValueError, what ++ " can only rotate about z (it lies in the XY plane), got x {f} and y {f}" ++ tilt_hint, .{ value.fmtNumber(turn.angles[0]), value.fmtNumber(turn.angles[1]) });
    }
    if (o.about) |about_val| {
        const p = try arguments.parseNumberArray(3, vm, about_val, .{ .method = "rotate", .name = "the point about:" }, 2, 0);
        if (planar and p[2] != 0) return vm.fail(.ValueError, "rotate: " ++ what ++ " turns about a point [x, y] (it lies in the XY plane), got z {f}", .{value.fmtNumber(p[2])});
        turn.about = p;
    }
    // Within a turn: the kernels take a cosine as the sine a quarter turn on (Manifold's
    // cosd), which a quarter turn added to 1e17 isn't. Exact, the same turn.
    for (&turn.angles) |*angle| angle.* = @mod(angle.*, 360);
    return turn;
}

/// The 2D matrix of a planar shape's turn (parseRotation's, about z): about its point when
/// it has one, there to the origin, turned and back.
pub fn planarRotation(turn: Rotation) affine2.Matrix {
    const spin = affine2.rotation(turn.angles[2]);
    const p = turn.about orelse return spin;
    return affine2.compose(affine2.translation(p[0], p[1]), affine2.compose(spin, affine2.translation(-p[0], -p[1])));
}

/// `scale(x, y, z)`, `scale([x, y, z])`, `scale(x: 2)`, or `scale(s)`: the same factor on
/// every axis, as every CAD tool reads it (one number used to stretch x alone).
pub fn meshScale(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    var vec = try arguments.parseVec3(vm, args, 1.0, "scale");
    if (arguments.singleNumber(args)) {
        const factor = vec[0];
        vec = @splat(factor);
    }
    // A zero factor flattens the shape onto a plane: never a valid solid or sketch.
    // Subnormal factors are rejected too, since they collapse just the same. A
    // CrossSection ignores z, so only x and y are checked for it.
    const checked_axes: usize = if (receiver.isCrossSection()) 2 else 3;
    for (vec[0..checked_axes]) |f| {
        if (!(@abs(f) >= std.math.floatMin(f64))) {
            return vm.fail(.ValueError, "scale factors must be non-zero, got [{f}, {f}, {f}]", .{ value.fmtNumber(vec[0]), value.fmtNumber(vec[1]), value.fmtNumber(vec[2]) });
        }
    }
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addScale(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = affine2.scaling(vec[0], vec[1]);
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return arguments.notDefinedFor(vm, "scale", receiver);
}

/// The move that puts the center of `bbox` at the origin on the axes in `axes` (x, y, z).
fn centerShift(bbox: geom.BoundingBox, axes: []const u8) [3]f64 {
    var shift: [3]f64 = @splat(0);
    for (axes) |c| {
        const axis: usize = switch (c) {
            'x', 'X' => 0,
            'y', 'Y' => 1,
            'z', 'Z' => 2,
            else => continue,
        };
        shift[axis] = -(bbox.min[axis] + (bbox.max[axis] - bbox.min[axis]) / 2.0);
    }
    return shift;
}

/// center(axes = "xyz"): moves the bounds' center to the origin on the axes named, a
/// String or Symbol of x, y and z (`center(:xy)`).
pub fn meshCenter(vm: *VM, receiver: value.Value, axes_arg: ?value.Value) !value.Value {
    const axes_str = if (axes_arg) |a| try arguments.requireName(vm, a, "center", "axes") else "xyz";
    // Any other letter used to be skipped, so `center("xq")` centered x alone.
    const valid = axes_str.len > 0 and for (axes_str) |c| {
        if (std.mem.findScalar(u8, "xyzXYZ", c) == null) break false;
    } else true;
    if (!valid) {
        return vm.fail(.ValueError, "center axes are some of x, y and z, got \"{s}\"", .{axes_str});
    }
    if (axes_arg != null and receiver.isCrossSection() and std.mem.findAny(u8, axes_str, "zZ") != null) {
        return vm.fail(.ValueError, "a Sketch lies in the XY plane: center it on x and y, got \"{s}\"", .{axes_str});
    }

    // An empty shape, which has no bounds, stays as it is: moved by its ±infinite box, the
    // VM stopped on a NaN translate
    const shift = centerShift(try arguments.boundsOf(vm, receiver, "center") orelse return receiver, axes_str);
    const tx, const ty, const tz = shift;

    if (receiver.isAssembly()) return assembly.translated(vm, receiver, shift);
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, tx, ty, tz);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = affine2.translation(tx, ty);
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return arguments.notDefinedFor(vm, "center", receiver);
}

/// A side of a shape's box along an axis `align` lines up: its low end, its high end or
/// its middle.
const Alignment = enum {
    min,
    max,
    center,

    /// The alignment `text` names, or an ArgumentError listing the three.
    fn parse(vm: *VM, text: []const u8) !Alignment {
        return std.meta.stringToEnum(Alignment, text) orelse vm.fail(.ArgumentError, "invalid alignment '{s}' (use 'min', 'max', or 'center')", .{text});
    }

    /// Where it is on `box` along `axis`.
    fn on(self: Alignment, box: anytype, axis: usize) f64 {
        return switch (self) {
            .min => box.min[axis],
            .max => box.max[axis],
            .center => (box.min[axis] + box.max[axis]) / 2.0,
        };
    }
};

/// `align(target, axes, my_align, target_align = my_align, offset = 0)`: the shape moved
/// along each of `axes` (letters of x, y and z) so its `my_align` side meets the target's
/// `target_align` side, `offset` beyond it; the names are Strings or Symbols (`:z`, `:max`).
pub fn meshAlign(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (args.len < 3) {
        return vm.fail(.ArgumentError, "align(target, axes, my_align, [target_align], [offset]) requires at least 3 args", .{});
    }
    const target = args[0];
    const axes_text = try arguments.requireName(vm, args[1], "align", "axes");
    const my_align = try Alignment.parse(vm, try arguments.requireName(vm, args[2], "align", "my_align"));
    var target_align = my_align;
    var offset: f64 = 0.0;
    if (args.len > 3) {
        if (args[3].nameChars()) |text| {
            target_align = try Alignment.parse(vm, text);
        } else if (args[3].isNumber()) {
            // Allow skipping target_align: align(target, axes, my_align, offset)
            offset = try arguments.requireNumber(vm, args[3], "align", "offset");
        } else if (!args[3].isNil()) { // nil keeps target_align = my_align
            return vm.fail(.TypeError, "align expects a String or Symbol target_align or a number offset as argument 4, got {s}", .{arguments.typeName(vm, args[3])});
        }
    }
    if (args.len > 4) offset = try arguments.requireNumber(vm, args[4], "align", "offset");

    var axes = [3]bool{ false, false, false };
    for (axes_text) |c| switch (std.ascii.toLower(c)) {
        'x' => axes[0] = true,
        'y' => axes[1] = true,
        'z' => axes[2] = true,
        else => {},
    };
    if (!axes[0] and !axes[1] and !axes[2]) {
        return vm.fail(.ArgumentError, "align needs axes to move along, letters of x, y and z, got '{s}'", .{axes_text});
    }

    // The target used to be evaluated as a Geometry whatever it was.
    if (!target.isGeometry() and !target.isCrossSection()) {
        return vm.fail(.TypeError, "align expects a Solid or Sketch to align to, got {s}", .{arguments.typeName(vm, target)});
    }
    // An empty shape stays as it is (as `center`'s); an empty target has no side to meet
    const my_bbox = try arguments.boundsOf(vm, receiver, "align") orelse return receiver;
    const target_bbox = try arguments.boundsOf(vm, target, "align") orelse return vm.fail(.ValueError, "align: the target is empty, with no side to align to", .{});
    var move = [3]f64{ 0, 0, 0 };
    for (axes, &move, 0..) |on_axis, *delta, axis| {
        if (on_axis) delta.* = target_align.on(target_bbox, axis) - my_align.on(my_bbox, axis) + offset;
    }
    const tx = move[0];
    const ty = move[1];
    const tz = move[2];

    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, tx, ty, tz);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = affine2.translation(tx, ty);
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return arguments.notDefinedFor(vm, "align", receiver);
}

pub fn meshMirror(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try arguments.parseVec3(vm, args, 0.0, "mirror");
    // The vector is the mirror plane's normal; the zero vector used to yield an empty solid.
    try arguments.requireNonZeroVector(vm, vec, "mirror", "plane normal");
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addMirror(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        // A Sketch mirrors across the line through the origin with normal (x, y).
        if (vec[2] != 0.0) {
            return vm.fail(.ValueError, "a Sketch can only mirror across a line in the XY plane, got a normal with z {f}", .{value.fmtNumber(vec[2])});
        }
        const mat = affine2.reflection(vec[0], vec[1]);
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return arguments.notDefinedFor(vm, "mirror", receiver);
}

pub fn meshTransform(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (args.len < 1) {
        return vm.fail(.ArgumentError, "transform expects a flat matrix Array", .{});
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
    return arguments.notDefinedFor(vm, "transform", receiver);
}

fn parseMatrix(comptime N: usize, vm: *VM, val: value.Value) ![N]f64 {
    // Exact length: extra entries (e.g. a flat 4x4) used to be silently dropped.
    return arguments.parseNumberArray(N, vm, val, .{
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
        return vm.fail(.ValueError, "transform matrix is singular (determinant {f}), which flattens the shape", .{value.fmtNumber(det)});
    }
}

pub fn meshResize(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "resize", receiver);
    const parsed = try arguments.parseKwargsSubset(struct { auto: bool = false }, sig.RESIZE.keywords, vm, args, "resize");
    const auto = parsed.opts.auto;

    if (parsed.positional.len < 1) {
        return vm.fail(.ArgumentError, "resize() requires an array of target dimensions [x, y, z]", .{});
    }
    // Missing trailing dimensions are 0, which means "keep" (or "auto" with auto: true).
    const target = try arguments.parseNumberArray(3, vm, args[0], .{
        .method = "resize",
        .name = "the target size",
        .elem = "a dimension",
    }, 1, 0.0);
    for (target, 0..) |t, i| {
        if (t < 0.0) {
            return vm.fail(.ValueError, "resize dimensions must be >= 0 (0 keeps that axis), got {f} at component {d}", .{ value.fmtNumber(t), i });
        }
    }
    const target_x = target[0];
    const target_y = target[1];
    const target_z = target[2];

    // An empty shape stays as it is: there is nothing to scale
    const bbox = try arguments.boundsOf(vm, receiver, "resize") orelse return receiver;
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
        return vm.fail(.ValueError, "{s} 'count' must be a finite number <= {d}, got {f}", .{ what, limits.MAX_PATTERN_COUNT, value.fmtNumber(raw) });
    }
    if (raw < 1.0) return 0;
    return @intFromFloat(raw);
}

pub fn meshRepeatLinear(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry() and !receiver.isCrossSection()) return arguments.notDefinedFor(vm, "repeat_linear", receiver);
    if (args.len < 1 or !args[0].isNumber()) {
        return vm.fail(.ArgumentError, "repeat_linear requires a 'count' number", .{});
    }

    const count = try checkedCount(vm, args[0].asNumber(), "repeat_linear");

    // The step is an [x, y, z] Array or positional/kwarg x, y, z (missing axes are 0).
    // It is validated even for a no-op count so a bad step never passes silently.
    // A nil step (e.g. a forwarded optional parameter) means no offset, as it did before.
    if (args.len > 2 and args[1].isArray()) {
        // They were ignored: `repeat_linear(3, [10, 0, 0], z: 5)` stepped 10 in x only.
        return vm.fail(.ArgumentError, "repeat_linear takes the step as an Array or as x, y, z, not both", .{});
    }
    const step: [3]f64 = if (args.len > 1 and args[1].isNil())
        @splat(0.0)
    else if (args.len > 1 and args[1].isArray())
        try arguments.parseNumberArray(3, vm, args[1], .{ .method = "repeat_linear", .name = "the step" }, 1, 0.0)
    else
        try arguments.parseVec3(vm, args[1..], 0.0, "repeat_linear");
    const tx, const ty, const tz = step;
    if (receiver.isCrossSection() and tz != 0) return vm.fail(.ArgumentError, "repeat_linear: a Sketch repeats in x and y, not z (got a z step of {f})", .{value.fmtNumber(tz)});
    if (count <= 1) return Copies.same(vm, receiver);

    // One batch union of the copies: a chain of N − 1 unions took 60× the time.
    var copies = try Copies.init(vm, receiver, count);
    defer copies.deinit(vm);
    for (1..count) |i| {
        const factor: f64 = @floatFromInt(i);
        copies.add(try copies.translated(vm, tx * factor, ty * factor, tz * factor));
    }
    return copies.unionOf(vm);
}

/// The copies a repeat pattern makes of its base shape, a Solid or a Sketch, moved as the
/// shape moves and unioned in one batch.
const Copies = struct {
    base: u32,
    sketch: bool,
    indices: std.ArrayList(u32),

    fn init(vm: *VM, shape: value.Value, count: usize) !Copies {
        const base = nodeOf(shape);
        var indices = try std.ArrayList(u32).initCapacity(vm.allocator, count);
        indices.appendAssumeCapacity(base);
        return .{ .base = base, .sketch = shape.isCrossSection(), .indices = indices };
    }

    fn nodeOf(shape: value.Value) u32 {
        return if (shape.isCrossSection()) shape.asCrossSection().dag_idx else shape.asGeometry().dag_idx;
    }

    /// A pattern of one copy: the shape itself, as a new value.
    fn same(vm: *VM, shape: value.Value) !value.Value {
        if (shape.isCrossSection()) return vm.allocateCrossSection(nodeOf(shape));
        return vm.allocateGeometry(.{ .symbolic = nodeOf(shape) });
    }

    /// The base moved by (x, y, z); a sketch's z is 0.
    fn translated(self: *const Copies, vm: *VM, x: f64, y: f64, z: f64) !u32 {
        if (self.sketch) return vm.dag_builder.addCrossSectionTransform(self.base, affine2.translation(x, y));
        return vm.dag_builder.addTranslate(self.base, x, y, z);
    }

    /// The base turned `degrees` about z.
    fn turned(self: *const Copies, vm: *VM, degrees: f64) !u32 {
        if (self.sketch) return vm.dag_builder.addCrossSectionTransform(self.base, affine2.rotation(degrees));
        return vm.dag_builder.addRotate(self.base, 0, 0, degrees);
    }

    fn deinit(self: *Copies, vm: *VM) void {
        self.indices.deinit(vm.allocator);
    }

    fn add(self: *Copies, copy: u32) void {
        self.indices.appendAssumeCapacity(copy);
    }

    fn unionOf(self: *const Copies, vm: *VM) !value.Value {
        if (self.sketch) return vm.allocateCrossSection(try vm.dag_builder.addBalancedChain(.cs_union_op, self.indices.items));
        return try vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addBalancedChain(.union_op, self.indices.items) });
    }
};

pub fn meshRepeatPolar(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry() and !receiver.isCrossSection()) return arguments.notDefinedFor(vm, "repeat_polar", receiver);
    if (args.len < 1 or !args[0].isNumber()) {
        return vm.fail(.ArgumentError, "repeat_polar requires a 'count' number", .{});
    }

    const count = try checkedCount(vm, args[0].asNumber(), "repeat_polar");

    const parsed = try arguments.parseKwargsSubset(struct { angle: ?f64 = null }, sig.REPEAT_POLAR.keywords, vm, args[1..], "repeat_polar");
    var total_angle: f64 = 360.0;
    if (parsed.positional.len > 0) total_angle = try arguments.requireNumber(vm, parsed.positional[0], "repeat_polar", "angle");
    if (parsed.opts.angle) |angle| total_angle = angle;
    if (count <= 1) return Copies.same(vm, receiver);

    const step_angle = if (@abs(total_angle - 360.0) < 0.001)
        total_angle / @as(f64, @floatFromInt(count))
    else
        total_angle / @as(f64, @floatFromInt(count - 1));

    var copies = try Copies.init(vm, receiver, count);
    defer copies.deinit(vm);
    for (1..count) |i| {
        copies.add(try copies.turned(vm, step_angle * @as(f64, @floatFromInt(i))));
    }
    return copies.unionOf(vm);
}
