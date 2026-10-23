//! Geometry methods beyond the primitives and booleans: `hull`, `minkowski`, `trim_by_plane`,
//! `split_by_plane`, `slice`, `project`, `offset`, `on_face`, `decompose` and `simplify`. Most add a node to the geometry DAG; `on_face`, `decompose` and `simplify`
//! evaluate the shape at once. Exported through methods.zig.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const arguments = @import("../arguments.zig");
const sig = @import("../method_signatures.zig");
const kernel = @import("../../kernel/kernel.zig");
const error_kind = @import("../../vm/error_kind.zig");
const booleans = @import("booleans.zig");

// --- Utilizing Strongly Typed Receivers ---

/// split_by_plane's arguments, positionally or as kwargs.
const PLANE_ARGS = sig.SPLIT_BY_PLANE.positional;

pub fn meshHull(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    var scratch = std.ArrayList(u32).empty;
    const alloc = vm.scratch_arena.allocator();

    try scratch.append(alloc, receiver.dag_idx);
    try booleans.appendOperands(vm, alloc, &scratch, args, true, "hull");

    const hull_idx = try vm.dag_builder.addBalancedChain(.hull, scratch.items);
    return try vm.allocateGeometry(.{ .symbolic = hull_idx });
}

pub fn meshMinkowski(vm: *VM, receiver: *value.ObjGeometry, other: *value.ObjGeometry) !value.Value {
    const new_idx = try vm.dag_builder.addBinary(.minkowski, receiver.dag_idx, other.dag_idx);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// `trim_by_plane(nx, ny, nz, offset)`: the part of the solid on the side of the plane its
/// normal points to, the plane `offset` along it from the origin (see parsePlane for the
/// forms the plane takes).
pub fn meshTrimByPlane(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    const nx, const ny, const nz, const off = try parsePlane(vm, args, null, "trim_by_plane");
    const new_idx = try vm.dag_builder.addTrimByPlane(receiver.dag_idx, nx, ny, nz, off);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// The plane [nx, ny, nz, offset] a plane method's arguments give: positionally (nx, ny,
/// nz[, offset]) or ([nx, ny, nz][, offset]), or by keywords nx:, ny:, nz: or normal:,
/// and offset: (0 unless given). Once any normal component is given the others are 0;
/// with none, the normal is `default_normal`, or an error when there is none.
pub fn parsePlane(vm: *VM, args: []const value.Value, default_normal: ?[3]f64, comptime method: []const u8) ![4]f64 {
    const parsed = try arguments.parseKwargsSubset(struct { nx: ?f64 = null, ny: ?f64 = null, nz: ?f64 = null, offset: ?f64 = null, normal: ?value.Value = null }, sig.TRIM_BY_PLANE.keywords, vm, args, method);
    const o = parsed.opts;
    var pos = parsed.positional;
    var plane = [PLANE_ARGS.len]f64{ 0.0, 0.0, 0.0, 0.0 };
    var normal_given = false;
    if (pos.len > 0 and pos[0].isArray()) {
        // ([nx, ny, nz], offset)
        if (o.normal != null) return vm.fail(.ArgumentError, method ++ " takes the normal once, as an Array or normal:", .{});
        plane[0..3].* = try arguments.parseNumberArray(3, vm, pos[0], .{ .method = method, .name = "the plane normal" }, 3, 0);
        normal_given = true;
        pos = pos[1..];
        if (pos.len > 1) return vm.fail(.ArgumentError, method ++ " expects ([nx, ny, nz], offset), got {d} arguments after the normal", .{pos.len});
        if (pos.len == 1) plane[3] = try arguments.requireNumber(vm, pos[0], method, "offset");
    } else {
        if (pos.len != 0 and pos.len != PLANE_ARGS.len - 1 and pos.len != PLANE_ARGS.len) {
            return vm.fail(.ArgumentError, method ++ " expects (nx, ny, nz[, offset]) or ([nx, ny, nz], offset), got {d} positional arguments", .{pos.len});
        }
        for (pos, 0..) |arg, i| plane[i] = try arguments.requireNumber(vm, arg, method, PLANE_ARGS[i]);
        normal_given = pos.len > 0;
    }
    if (o.normal) |normal_val| {
        if (normal_given or o.nx != null or o.ny != null or o.nz != null) return vm.fail(.ArgumentError, method ++ " takes normal: or nx, ny, nz, not both", .{});
        plane[0..3].* = try arguments.parseNumberArray(3, vm, normal_val, .{ .method = method, .name = "the plane normal" }, 3, 0);
        normal_given = true;
    }
    // Unset components are 0 once any is given: nz: 1 alone is the XY plane (it used to
    // keep a default nx = 1, a diagonal plane)
    inline for (PLANE_ARGS[0..3], 0..) |name, i| {
        if (@field(o, name)) |n| {
            plane[i] = n;
            normal_given = true;
        }
    }
    if (o.offset) |off| plane[3] = off;
    if (!normal_given) {
        plane[0..3].* = default_normal orelse return vm.fail(.ArgumentError, method ++ " needs the plane's normal: nx, ny, nz, or an Array [nx, ny, nz]", .{});
    }
    try arguments.requireNonZeroVector(vm, plane[0..3].*, method, "plane normal");
    return plane;
}

/// Offset corner styles; the values are the kernel's join_type codes.
const JoinType = enum(u8) { square = 0, round = 1, miter = 2, bevel = 3 };
/// How far a miter join's corner may reach, in multiples of the offset, before it is
/// squared off: without `miter_limit:`, and at least (the kernel raises a lower one to it).
const MIN_MITER_LIMIT = 2.0;

/// `offset(delta, join:, miter_limit:, segments:)`. A Sketch grows by `delta` (shrinks,
/// when it is negative), its corners joined as `join` says, a miter's reaching at most
/// `miter_limit` times `delta` before it is squared off. A Solid grows by `delta` in every
/// direction: a Minkowski sum with a sphere of that radius, the 3D form of a round join, so
/// its edges and corners come out rounded. A Solid can't shrink (that is an erosion, which
/// the kernel lacks) and has no other join. The rounding, a join's or the sphere's, is as
/// fine as the resolution makes a circle of radius `delta`, or `segments:` says (a sketch's
/// took the kernel's own default, whatever the script's resolution).
pub fn meshOffset(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const OffsetOpts = struct { delta: f64 = 1.0, join: JoinType = .round, miter_limit: ?f64 = null, segments: i32 = 0 };
    const pos = arguments.positionalArgs(args);
    var base = OffsetOpts{};
    if (pos.len > 0) base.delta = try arguments.requireNumber(vm, pos[0], "offset", "delta");
    const opts = (try arguments.parseKwargsOver(OffsetOpts, base, sig.OFFSET.keywords, vm, args, "offset")).opts;
    try arguments.requireSegmentCount(vm, opts.segments, "segments");
    const segments = if (opts.segments > 0) opts.segments else arguments.autoSegments(vm, @abs(opts.delta));

    if (receiver.isCrossSection()) {
        if (opts.miter_limit) |limit| {
            // A limit that limits nothing would be silently ignored
            if (opts.join != .miter) return vm.fail(.ArgumentError, "offset's miter_limit applies to join: :miter only, not join: :{s}", .{@tagName(opts.join)});
            if (!(limit >= MIN_MITER_LIMIT) or !std.math.isFinite(limit)) {
                return vm.fail(.ValueError, "offset miter_limit must be a number of at least {d} (a multiple of delta), got {f}", .{ MIN_MITER_LIMIT, value.fmtNumber(limit) });
            }
        }
        const new_idx = try vm.dag_builder.addOffset(receiver.asCrossSection().dag_idx, opts.delta, @backingInt(opts.join), segments, opts.miter_limit orelse MIN_MITER_LIMIT);
        return try vm.allocateCrossSection(new_idx);
    }
    if (receiver.isGeometry()) {
        if (!std.math.isFinite(opts.delta) or opts.delta <= 0.0) {
            return vm.fail(.ValueError, "a Solid's offset only grows it: delta must be a finite number greater than zero, got {f}", .{value.fmtNumber(opts.delta)});
        }
        if (opts.join != .round) {
            return vm.fail(.ValueError, "a Solid's offset rounds its edges (a Minkowski sum with a sphere), so it takes no join: :{s}", .{@tagName(opts.join)});
        }
        if (opts.miter_limit != null) {
            return vm.fail(.ArgumentError, "a Solid's offset rounds its edges (a Minkowski sum with a sphere), so it takes no miter_limit", .{});
        }
        const sphere_idx = try vm.dag_builder.addSphere(opts.delta, segments);
        const new_idx = try vm.dag_builder.addBinary(.minkowski, receiver.asGeometry().dag_idx, sphere_idx);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    }
    return arguments.notDefinedFor(vm, "offset", receiver);
}

pub fn meshSlice(vm: *VM, receiver: *value.ObjGeometry, height: ?value.Value) !value.Value {
    const z = if (height) |h| try arguments.requireNumber(vm, h, "slice", "height") else 0.0;
    const new_idx = try vm.dag_builder.addSlice(receiver.dag_idx, z);
    return try vm.allocateCrossSection(new_idx);
}

pub fn meshProject(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    const parsed = try arguments.parseKwargsSubset(struct { cut: bool = false }, sig.PROJECT.keywords, vm, args, "project");

    if (parsed.opts.cut) {
        // project(cut: true) is a 2D slice exactly at Z=0
        const new_idx = try vm.dag_builder.addSlice(receiver.dag_idx, 0.0);
        return try vm.allocateCrossSection(new_idx);
    } else {
        // Standard 2D shadow projection of the entire 3D volume
        const new_idx = try vm.dag_builder.addProject(receiver.dag_idx);
        return try vm.allocateCrossSection(new_idx);
    }
}

pub fn meshOnFace(vm: *VM, receiver: *value.ObjGeometry, dir_arg: value.Value) !value.Value {
    const handle = try vm.ensureConcrete(value.Value.initGeometry(receiver));
    try vm.requireFeature(handle.engine, .faces);

    var direction = [3]f64{ 0, 0, 1 };

    if (dir_arg.isArray()) {
        direction = try arguments.parseNumberArray(3, vm, dir_arg, .{ .method = "on_face", .name = "the direction" }, 3, 0.0);
        try arguments.requireNonZeroVector(vm, direction, "on_face", "direction");
    } else if (dir_arg.nameChars()) |dir_str| {
        if (std.mem.eql(u8, dir_str, "top")) {
            direction = .{ 0, 0, 1 };
        } else if (std.mem.eql(u8, dir_str, "bottom")) {
            direction = .{ 0, 0, -1 };
        } else if (std.mem.eql(u8, dir_str, "front")) {
            direction = .{ 0, -1, 0 };
        } else if (std.mem.eql(u8, dir_str, "back")) {
            direction = .{ 0, 1, 0 };
        } else if (std.mem.eql(u8, dir_str, "left")) {
            direction = .{ -1, 0, 0 };
        } else if (std.mem.eql(u8, dir_str, "right")) {
            direction = .{ 1, 0, 0 };
        } else {
            return vm.fail(.ValueError, "Unknown face direction '{s}' (use top, bottom, front, back, left or right)", .{dir_str});
        }
    } else {
        return vm.fail(.TypeError, "on_face expects a direction Array or Symbol, got {s}", .{arguments.typeName(vm, dir_arg)});
    }

    const tolerance = vm.settingsOf(receiver).tolerance;

    const faces = kernel.queryFaces(vm.scratch_arena.allocator(), handle, direction, tolerance) orelse {
        return vm.fail(.RuntimeError, "Could not find a coplanar face matching the requested direction", .{});
    };

    if (faces.len == 0) {
        return vm.fail(.ValueError, "on_face found no planar face facing [{f}, {f}, {f}]", .{ value.fmtNumber(direction[0]), value.fmtNumber(direction[1]), value.fmtNumber(direction[2]) });
    }

    return try vm.allocateWorkplane(receiver, faces[0].centroid, faces[0].normal);
}

pub fn meshSplitByPlane(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "split_by_plane", receiver);

    // Without a normal, at the YZ plane
    const nx, const ny, const nz, const offset = try parsePlane(vm, args, .{ 1, 0, 0 }, "split_by_plane");

    const target_idx = receiver.asGeometry().dag_idx;

    // Front half: trimmed along plane (nx, ny, nz, offset)
    const front_dag = try vm.dag_builder.addTrimByPlane(target_idx, nx, ny, nz, offset);

    // Back half: trimmed along opposite plane (-nx, -ny, -nz, -offset)
    const back_dag = try vm.dag_builder.addTrimByPlane(target_idx, -nx, -ny, -nz, -offset);

    // Each allocation can collect, so keep the earlier results on the stack until
    // they are reachable from the returned array.
    const front_geom = try vm.allocateGeometry(.{ .symbolic = front_dag });
    vm.push(front_geom);
    defer _ = vm.pop();
    const back_geom = try vm.allocateGeometry(.{ .symbolic = back_dag });
    vm.push(back_geom);
    defer _ = vm.pop();

    const arr = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&arr.obj));
    defer _ = vm.pop();
    try arr.items.append(vm.gc.trackingAllocator(), front_geom);
    try arr.items.append(vm.gc.trackingAllocator(), back_geom);

    return value.Value.initObj(&arr.obj);
}

pub fn meshDecompose(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "decompose", receiver);
    const handle = try vm.ensureConcrete(receiver); // Eager!
    try vm.requireFeature(handle.engine, .decompose);
    // `handle` is borrowed from the DAG cache; `parts` are new handles we own.
    const parts = kernel.decompose(vm.allocator, handle) orelse {
        return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"decompose"});
    };
    defer vm.allocator.free(parts);

    // Register every part as a `.concrete` DAG leaf first: the DAG builder then
    // owns the handles, and the parts stay usable in later DAG ops. Parts not yet
    // registered must be freed if we bail out early.
    var registered: usize = 0;
    errdefer for (parts[registered..]) |p| kernel.destruct(p);
    const leaf_idxs = try vm.allocator.alloc(u32, parts.len);
    defer vm.allocator.free(leaf_idxs);
    for (parts, leaf_idxs) |p, *idx| {
        idx.* = try vm.dag_builder.addConcrete(p);
        registered += 1;
    }

    const arr_obj = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&arr_obj.obj)); // Protect during alloc

    for (leaf_idxs) |idx| {
        const geom_val = try vm.allocateGeometry(.{ .symbolic = idx });
        try arr_obj.items.append(vm.gc.trackingAllocator(), geom_val);
    }

    _ = vm.pop();
    return value.Value.initObj(&arr_obj.obj);
}

pub fn meshSimplify(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    var tolerance: ?f64 = null;

    // Optional positional argument: part.simplify(0.01); nil keeps the tolerance the part
    // was made under.
    if (args.len > 0 and !args[0].isNil()) tolerance = try arguments.requireNumber(vm, args[0], "simplify", "tolerance");

    const tol = tolerance orelse vm.settingsOf(value.Value.initGeometry(receiver)).tolerance;

    // Force concrete DAG evaluation up to this point and run simplification
    const handle = try vm.ensureConcrete(value.Value.initGeometry(receiver));
    // kernel.simplify always returns a NEW handle (never `handle`, which the DAG
    // cache owns). Registering it as a `.concrete` leaf hands ownership to the
    // DAG builder and keeps the result usable in later DAG ops.
    const simplified_handle = kernel.simplify(handle, tol) orelse {
        return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"simplify"});
    };
    const leaf_idx = vm.dag_builder.addConcrete(simplified_handle) catch |err| {
        kernel.destruct(simplified_handle);
        return err;
    };

    return try vm.allocateGeometry(.{ .symbolic = leaf_idx });
}
