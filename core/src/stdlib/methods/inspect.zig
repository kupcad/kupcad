//! The methods that measure a shape rather than make one: `bbox`, `volume`, `surface_area`,
//! `min_gap`, `contains?`, `ray_cast` and `genus`. Each evaluates the shape first and checks
//! that its engine supports the query.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../core/geometry_handle.zig");
const arguments = @import("../arguments.zig");
const error_kind = @import("../../vm/error_kind.zig");
const vec3 = @import("../../core/vec3.zig");

/// min_gap without a search length first looks this fraction of the way across the box
/// around both shapes (when their own boxes overlap), then twice as far each time: the
/// kernel tests more triangle pairs the further it looks.
const FIRST_GAP_SEARCH_FRACTION: f64 = 1.0 / 64.0;

pub fn meshBBox(vm: *VM, receiver: value.Value) !value.Value {
    if (receiver.isAssembly()) {
        // nil when its parts are all empty, as an empty Solid's
        const box = try arguments.boundsOf(vm, receiver, "bbox") orelse return value.Value.initNil();
        const bbox_inst = try vm.gc.allocateBBox(vm, box.min[0], box.min[1], box.min[2], box.max[0], box.max[1], box.max[2]);
        return value.Value.initObj(&bbox_inst.obj);
    }
    if (receiver.isGeometry()) {
        const handle = try vm.ensureConcrete(receiver);
        try vm.requireFeature(handle.engine, .bounding_box);
        const geom_obj = receiver.asGeometry();

        if (geom_obj.cached_bbox == null) {
            if (kernel.boundingBox(handle)) |k_box| {
                geom_obj.cached_bbox = value.BBox{
                    .min_x = k_box.min[0],
                    .min_y = k_box.min[1],
                    .min_z = k_box.min[2],
                    .max_x = k_box.max[0],
                    .max_y = k_box.max[1],
                    .max_z = k_box.max[2],
                };
            }
        }

        const box = geom_obj.cached_bbox orelse return value.Value.initNil();
        const bbox_inst = try vm.gc.allocateBBox(vm, box.min_x, box.min_y, box.min_z, box.max_x, box.max_y, box.max_z);
        return value.Value.initObj(&bbox_inst.obj);
    } else if (receiver.isCrossSection()) {
        const handle = try vm.ensureConcreteCrossSection(receiver);
        try vm.requireFeature(handle.engine, .sketch_measure);
        const rect = kernel.crossSectionBounds(handle) orelse return value.Value.initNil(); // empty, as a Solid's

        const bbox_inst = try vm.gc.allocateBBox(
            vm,
            rect.min[0],
            rect.min[1],
            0.0,
            rect.max[0],
            rect.max[1],
            0.0,
        );
        return value.Value.initObj(&bbox_inst.obj);
    }

    return arguments.notDefinedFor(vm, "bbox", receiver);
}

pub fn meshVolume(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "volume", receiver);
    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .volume);
    return value.Value.initNumber(kernel.volume(handle));
}

/// `solid.center_of_mass`: the centroid of its volume, [x, y, z], where it balances at a
/// uniform density: the first moments of the tetrahedra its mesh's triangles make with a
/// vertex of its own (near, so the sums keep their digits) over its volume.
pub fn meshCenterOfMass(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "center_of_mass", receiver);
    const handle = try vm.ensureConcrete(receiver);
    // A measurement of its volume, made from its mesh
    try vm.requireFeature(handle.engine, .volume);
    try vm.requireFeature(handle.engine, .mesh);
    const mesh = kernel.getMesh(vm.allocator, handle) orelse return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"center_of_mass"});
    defer vm.allocator.free(mesh.vert_props);
    defer vm.allocator.free(mesh.tri_verts);
    if (mesh.tri_verts.len == 0) return vm.fail(.ValueError, "center_of_mass: the Solid is empty, it has no volume to balance", .{});
    const ref = vertexAt(mesh, 0);
    var six_volume: f64 = 0;
    var moment: [3]f64 = @splat(0);
    var t: usize = 0;
    while (t < mesh.tri_verts.len) : (t += 3) {
        const a = vec3.sub(vertexAt(mesh, mesh.tri_verts[t]), ref);
        const b = vec3.sub(vertexAt(mesh, mesh.tri_verts[t + 1]), ref);
        const c = vec3.sub(vertexAt(mesh, mesh.tri_verts[t + 2]), ref);
        // Six times the tetrahedron's signed volume; its centroid is (a + b + c) / 4
        const v6 = vec3.dot(a, vec3.cross(b, c));
        six_volume += v6;
        moment = vec3.add(moment, vec3.scale(vec3.add(vec3.add(a, b), c), v6));
    }
    if (!(six_volume > 0)) return vm.fail(.ValueError, "center_of_mass: the Solid encloses no volume", .{});
    const centroid = vec3.add(ref, vec3.scale(moment, 1 / (4 * six_volume)));
    return vec3Value(vm, centroid);
}

fn vertexAt(mesh: geom.Mesh, i: usize) [3]f64 {
    const p = mesh.vert_props[i * mesh.num_prop ..][0..3];
    return .{ p[0], p[1], p[2] };
}

/// `solid.intersects?(other)`: whether the two overlap, their intersection holding more
/// than the tolerance cubed; solids that only touch (a face on a face) don't.
pub fn meshIntersects(vm: *VM, receiver: value.Value, other: value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "intersects?", receiver);
    if (!other.isGeometry()) return vm.fail(.TypeError, "intersects? expects a Solid to test against, got {s}", .{arguments.typeName(vm, other)});
    const handle = try vm.ensureConcrete(receiver);
    const other_handle = try vm.ensureConcrete(other);
    try vm.requireSameEngine(handle.engine, other_handle.engine);
    try vm.requireFeature(handle.engine, .boolean);
    try vm.requireFeature(handle.engine, .volume);
    const common = kernel.boolean(handle, other_handle, .intersection_op) orelse return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"intersects?"});
    defer kernel.destruct(common);
    const tolerance = vm.settingsOf(receiver).tolerance;
    return value.Value.initBool(kernel.volume(common) > tolerance * tolerance * tolerance);
}

/// `sketch.area`: how much the sketch encloses, in mm² (its holes left out).
pub fn sketchArea(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isCrossSection()) return arguments.notDefinedFor(vm, "area", receiver);
    const handle = try vm.ensureConcreteCrossSection(receiver);
    try vm.requireFeature(handle.engine, .sketch_measure);
    return value.Value.initNumber(kernel.crossSectionArea(handle));
}

pub fn meshSurfaceArea(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "surface_area", receiver);
    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .surface_area);
    return value.Value.initNumber(kernel.surfaceArea(handle));
}

pub fn meshMinGap(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "min_gap", receiver);
    if (args.len < 1 or !args[0].isGeometry()) {
        return vm.fail(.TypeError, "min_gap expects a Solid to measure against, got {s}", .{if (args.len < 1) "nothing" else arguments.typeName(vm, args[0])});
    }
    const search_length: ?f64 = if (args.len > 1) try arguments.requireNumber(vm, args[1], "min_gap", "search_length") else null;
    if (search_length) |length| try arguments.requirePositive(vm, length, "min_gap", "search_length");
    const handle = try vm.ensureConcrete(receiver);
    const other_handle = try vm.ensureConcrete(args[0]);
    try vm.requireSameEngine(handle.engine, other_handle.engine); // the kernel answered 0
    try vm.requireFeature(handle.engine, .min_gap);
    if (search_length) |length| return value.Value.initNumber(kernel.minGap(handle, other_handle, length));
    try vm.requireFeature(handle.engine, .bounding_box);
    // Infinity to an empty one: there is nothing in it to be near (its box has none)
    if (kernel.numVerts(handle) == 0 or kernel.numVerts(other_handle) == 0) return value.Value.initNumber(std.math.inf(f64));
    const box_a = kernel.boundingBox(handle) orelse return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"min_gap"});
    const box_b = kernel.boundingBox(other_handle) orelse return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"min_gap"});
    return value.Value.initNumber(fullGap(handle, other_handle, box_a, box_b));
}

/// The gap between two solids, however far apart (`min_gap` without a search length):
/// searched from just past the gap between their boxes, doubling up to the diagonal of
/// the box around both, which no gap between them is longer than. Neither is empty.
fn fullGap(a: geom.GeometryHandle, b: geom.GeometryHandle, box_a: geom.BoundingBox, box_b: geom.BoundingBox) f64 {
    var box_gap_sq: f64 = 0;
    var diagonal_sq: f64 = 0;
    for (0..3) |axis| {
        const apart = @max(0, @max(box_a.min[axis] - box_b.max[axis], box_b.min[axis] - box_a.max[axis]));
        const across = @max(box_a.max[axis], box_b.max[axis]) - @min(box_a.min[axis], box_b.min[axis]);
        box_gap_sq += apart * apart;
        diagonal_sq += across * across;
    }
    const diagonal = @sqrt(diagonal_sq);
    if (diagonal == 0) return 0;
    var search = @min(diagonal, @max(2 * @sqrt(box_gap_sq), diagonal * FIRST_GAP_SEARCH_FRACTION));
    while (true) : (search = @min(2 * search, diagonal)) {
        const gap = kernel.minGap(a, b, search);
        if (gap < search or search == diagonal) return gap;
    }
}

/// Whether the box is an empty solid's (its min above its max).
pub fn meshContains(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (receiver.isCrossSection()) return sketchContains(vm, receiver, args);
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "contains?", receiver);
    if (args.len < 1) {
        return vm.fail(.ArgumentError, "contains? expects a point [x, y, z]", .{});
    }
    const pt = try arguments.parseNumberArray(3, vm, args[0], .{ .method = "contains?", .name = "the point" }, 3, 0.0);

    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .contains_point);
    const settings = vm.settingsOf(receiver);
    const inside = kernel.containsPoint(vm.allocator, handle, &settings, pt) orelse {
        return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"contains?"});
    };
    return value.Value.initBool(inside);
}

/// Sketch#contains?([x, y]) / ([x, y, z]): whether the point lies in the sketch's region.
/// The region is closed (points on the outline count, within the engine tolerance) and
/// holes are excluded. A sketch lives in the z = 0 plane, so a 3D point off that plane is
/// never contained; accepting [x, y, z] lets generic code pass 3D points.
fn sketchContains(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (args.len < 1) {
        return vm.fail(.ArgumentError, "contains? on a sketch expects a point [x, y]", .{});
    }
    const pt = try arguments.parseNumberArray(3, vm, args[0], .{ .method = "contains?", .name = "the point" }, 2, 0.0);
    const tolerance = vm.settingsOf(receiver).tolerance;
    if (@abs(pt[2]) > tolerance) return value.Value.initBool(false);

    const handle = try vm.ensureConcreteCrossSection(receiver);
    try vm.requireFeature(handle.engine, .contains_point);
    const inside = kernel.crossSectionContainsPoint(handle, .{ pt[0], pt[1] }, tolerance) orelse {
        return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"contains?"});
    };
    return value.Value.initBool(inside);
}

pub fn meshRayCast(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "ray_cast", receiver);
    if (args.len < 2) {
        return vm.fail(.ArgumentError, "ray_cast expects an origin [x, y, z] and an end point [x, y, z]", .{});
    }
    const origin = try arguments.parseNumberArray(3, vm, args[0], .{ .method = "ray_cast", .name = "the origin" }, 3, 0.0);
    const end = try arguments.parseNumberArray(3, vm, args[1], .{ .method = "ray_cast", .name = "the end point" }, 3, 0.0);
    // A zero-length ray has no direction.
    try arguments.requireNonZeroVector(vm, .{ end[0] - origin[0], end[1] - origin[1], end[2] - origin[2] }, "ray_cast", "ray (end - origin)");

    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .ray_cast);
    const hits = kernel.rayCast(vm.scratch_arena.allocator(), handle, origin, end) orelse return value.Value.initNil();
    // No need to free `hits`, scratch arena cleans it up!

    const hit_arr_obj = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&hit_arr_obj.obj));
    defer _ = vm.pop();

    for (hits) |hit| {
        const map_obj = try vm.gc.allocateMap(vm);
        vm.push(value.Value.initObj(&map_obj.obj));
        defer _ = vm.pop();

        try putEntry(vm, map_obj, "distance", value.Value.initNumber(hit.distance));
        try putEntry(vm, map_obj, "position", try vec3Value(vm, hit.position));
        try putEntry(vm, map_obj, "normal", try vec3Value(vm, hit.normal));
        try putEntry(vm, map_obj, "crossing", value.Value.initNumber(@floatFromInt(hit.crossing)));

        try hit_arr_obj.items.append(vm.gc.trackingAllocator(), value.Value.initObj(&map_obj.obj));
    }
    return value.Value.initObj(&hit_arr_obj.obj);
}

/// `map[key] = item`, `item` rooted while the key is allocated (which may collect).
fn putEntry(vm: *VM, map: *value.ObjMap, key: []const u8, item: value.Value) !void {
    vm.push(item);
    defer _ = vm.pop();
    try map.table.put(vm.gc.trackingAllocator(), try vm.allocateString(key), item);
}

fn vec3Value(vm: *VM, v: [3]f64) !value.Value {
    return value.Value.initObj(&(try vm.gc.allocateArrayOf(vm, &.{ value.Value.initNumber(v[0]), value.Value.initNumber(v[1]), value.Value.initNumber(v[2]) })).obj);
}

pub fn meshGenus(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "genus", receiver);
    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .genus);
    return value.Value.initNumber(@floatFromInt(kernel.genus(handle)));
}
