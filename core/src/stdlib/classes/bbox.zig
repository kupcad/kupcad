//! The methods of `BoundingBox`: its corners, center and size as `[x, y, z]` arrays, each
//! axis's bounds and extent (`x_min`, `z_size`, ...), and `to_s`. Bound by `core_classes.zig`.

const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

fn buildVec3(vm: *VM, v: [3]f64) !value.Value {
    const arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&arr.obj));
    defer _ = vm.pop();
    for (v) |n| try arr.items.append(vm.gc.trackingAllocator(), value.Value.initNumber(n));
    return value.Value.initObj(&arr.obj);
}

/// The extent along each axis (never negative, even for an empty box).
fn size(bbox: *const value.ObjBBox) [3]f64 {
    var s: [3]f64 = undefined;
    for (&s, bbox.min, bbox.max) |*out, lo, hi| out.* = @max(0.0, hi - lo);
    return s;
}

fn center(bbox: *const value.ObjBBox) [3]f64 {
    var c: [3]f64 = undefined;
    for (&c, bbox.min, bbox.max) |*out, lo, hi| out.* = lo + (hi - lo) / 2.0;
    return c;
}

const Corner = enum { min, max, size, center };

/// BoundingBox#min, #max, #size, #center -> [x, y, z]
fn vecGetter(comptime corner: Corner) value.NativeFn {
    return common.wrapMethod(struct {
        fn call(vm: *VM, bbox: *value.ObjBBox) !value.Value {
            return buildVec3(vm, switch (corner) {
                .min => bbox.min,
                .max => bbox.max,
                .size => size(bbox),
                .center => center(bbox),
            });
        }
    }.call);
}

/// BoundingBox#x_min, #y_size, ... -> one component of a corner or the size
fn axisGetter(comptime corner: Corner, comptime axis: usize) value.NativeFn {
    return common.wrapMethod(struct {
        fn call(vm: *VM, bbox: *value.ObjBBox) !value.Value {
            _ = vm;
            return value.Value.initNumber(switch (corner) {
                .min => bbox.min[axis],
                .max => bbox.max[axis],
                .size => size(bbox)[axis],
                .center => center(bbox)[axis],
            });
        }
    }.call);
}

fn bboxToS(vm: *VM, bbox: *value.ObjBBox) !value.Value {
    const s = size(bbox);
    const f = value.fmtNumber;
    const str = try vm.fmtScratch("BoundingBox(min: [{f}, {f}, {f}], max: [{f}, {f}, {f}], size: [{f}, {f}, {f}])", .{
        f(bbox.min[0]), f(bbox.min[1]), f(bbox.min[2]),
        f(bbox.max[0]), f(bbox.max[1]), f(bbox.max[2]),
        f(s[0]),        f(s[1]),        f(s[2]),
    });
    return try vm.allocateString(str);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "size", .func = vecGetter(.size) },
    .{ .name = "center", .func = vecGetter(.center) },
    .{ .name = "min", .func = vecGetter(.min) },
    .{ .name = "max", .func = vecGetter(.max) },
    .{ .name = "x_min", .func = axisGetter(.min, 0) },
    .{ .name = "y_min", .func = axisGetter(.min, 1) },
    .{ .name = "z_min", .func = axisGetter(.min, 2) },
    .{ .name = "x_max", .func = axisGetter(.max, 0) },
    .{ .name = "y_max", .func = axisGetter(.max, 1) },
    .{ .name = "z_max", .func = axisGetter(.max, 2) },
    .{ .name = "x_size", .func = axisGetter(.size, 0) },
    .{ .name = "y_size", .func = axisGetter(.size, 1) },
    .{ .name = "z_size", .func = axisGetter(.size, 2) },
    .{ .name = "to_s", .func = common.wrapMethod(bboxToS) },
    .{ .name = "inspect", .func = common.wrapMethod(bboxToS) },
};
