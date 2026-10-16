//! Geometry methods beyond the primitives and booleans: `hull`, `minkowski`, `trim_by_plane`,
//! `split_by_plane`, `slice`, `project`, `offset`, `on_face`, `decompose`, `fillet_edges` and
//! `simplify`. Most add a node to the geometry DAG; `on_face`, `decompose` and `simplify`
//! evaluate the shape at once. Exported through methods.zig.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const util = @import("util.zig");
const sig = @import("../method_signatures.zig");
const kernel = @import("../../kernel/kernel.zig");
const error_kind = @import("../../vm/error_kind.zig");
const booleans = @import("booleans.zig");

// --- Utilizing Strongly Typed Receivers ---

/// split_by_plane's arguments, positionally or as kwargs.
const PLANE_ARGS = sig.SPLIT_BY_PLANE.positional;

pub fn meshHull(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    var scratch = std.ArrayListUnmanaged(u32).empty;
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

// Arguments arrive as raw Values (not f64) so a wrong type gets a TypeError naming it.
pub fn meshTrimByPlane(vm: *VM, receiver: *value.ObjGeometry, nx: value.Value, ny: value.Value, nz: value.Value, offset: ?value.Value) !value.Value {
    const normal = [3]f64{
        try util.requireNumber(vm, nx, "trim_by_plane", "nx"),
        try util.requireNumber(vm, ny, "trim_by_plane", "ny"),
        try util.requireNumber(vm, nz, "trim_by_plane", "nz"),
    };
    try util.requireNonZeroVector(vm, normal, "trim_by_plane", "plane normal");
    const off = if (offset) |o| try util.requireNumber(vm, o, "trim_by_plane", "offset") else 0.0;
    const new_idx = try vm.dag_builder.addTrimByPlane(receiver.dag_idx, normal[0], normal[1], normal[2], off);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// Offset corner styles; the values are the kernel's join_type codes.
const JoinType = enum(u8) { square = 0, round = 1, miter = 2, bevel = 3 };

pub fn meshOffset(vm: *VM, receiver: *value.ObjCrossSection, args: []const value.Value) !value.Value {
    const OffsetOpts = struct { delta: f64 = 1.0, join: JoinType = .round };
    const pos = util.positionalArgs(args);
    var base = OffsetOpts{};
    if (pos.len > 0) base.delta = try util.requireNumber(vm, pos[0], "offset", "delta");
    const opts = (try util.parseKwargsOver(OffsetOpts, base, sig.OFFSET.keywords, vm, args, "offset")).opts;

    const new_idx = try vm.dag_builder.addOffset(receiver.dag_idx, opts.delta, @backingInt(opts.join));
    return try vm.allocateCrossSection(new_idx);
}

pub fn meshSlice(vm: *VM, receiver: *value.ObjGeometry, height: ?value.Value) !value.Value {
    const z = if (height) |h| try util.requireNumber(vm, h, "slice", "height") else 0.0;
    const new_idx = try vm.dag_builder.addSlice(receiver.dag_idx, z);
    return try vm.allocateCrossSection(new_idx);
}

pub fn meshProject(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    const parsed = try util.parseKwargsSubset(struct { cut: bool = false }, sig.PROJECT.keywords, vm, args, "project");

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
        direction = try util.parseNumberArray(3, vm, dir_arg, .{ .method = "on_face", .name = "the direction" }, 3, 0.0);
        try util.requireNonZeroVector(vm, direction, "on_face", "direction");
    } else if (dir_arg.isObject() and (dir_arg.asObj().obj_type == .symbol or dir_arg.asObj().obj_type == .string)) {
        const dir_str = if (dir_arg.asObj().obj_type == .symbol)
            @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", dir_arg.asObj()))).chars
        else
            @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", dir_arg.asObj()))).chars;

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
        return vm.fail(.TypeError, "on_face expects a direction Array or Symbol, got {s}", .{util.typeName(vm, dir_arg)});
    }

    const tolerance = vm.config().tolerance;

    const faces = kernel.queryFaces(vm.scratch_arena.allocator(), handle, direction, tolerance) orelse {
        return vm.fail(.RuntimeError, "Could not find a coplanar face matching the requested direction", .{});
    };

    if (faces.len == 0) {
        return vm.fail(.ValueError, "on_face found no planar face facing [{f}, {f}, {f}]", .{ value.fmtNumber(direction[0]), value.fmtNumber(direction[1]), value.fmtNumber(direction[2]) });
    }

    return try vm.allocateWorkplane(receiver, faces[0].centroid, faces[0].normal);
}

pub fn meshSplitByPlane(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "split_by_plane", receiver);

    const parsed = try util.parseKwargsSubset(struct { nx: ?f64 = null, ny: ?f64 = null, nz: ?f64 = null, offset: ?f64 = null }, sig.SPLIT_BY_PLANE.keywords, vm, args, "split_by_plane");
    const positional = parsed.positional;
    if (positional.len != 0 and positional.len != PLANE_ARGS.len - 1 and positional.len != PLANE_ARGS.len) {
        return vm.fail(.ArgumentError, "split_by_plane expects (nx, ny, nz[, offset]), got {d} positional arguments", .{positional.len});
    }

    // Unset normal components are 0 once any is given, so split_by_plane(nz: 1)
    // means the XY plane (it used to keep the default nx = 1, a diagonal plane).
    var plane = [PLANE_ARGS.len]f64{ 0.0, 0.0, 0.0, 0.0 };
    var normal_given = positional.len > 0;
    for (positional, 0..) |arg, i| plane[i] = try util.requireNumber(vm, arg, "split_by_plane", PLANE_ARGS[i]);
    inline for (PLANE_ARGS, 0..) |name, i| {
        if (@field(parsed.opts, name)) |n| {
            plane[i] = n;
            if (i < 3) normal_given = true;
        }
    }
    if (!normal_given) plane[0] = 1.0; // Default: split at the YZ plane.
    const nx, const ny, const nz, const offset = plane;
    try util.requireNonZeroVector(vm, .{ nx, ny, nz }, "split_by_plane", "plane normal");

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
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "decompose", receiver);
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

pub fn meshFilletEdges(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    const parsed = try util.parseKwargsSubset(struct { r: ?f64 = null }, sig.FILLET_EDGES.keywords, vm, args, "fillet_edges");
    var radius: f64 = 1.0;
    if (parsed.positional.len > 0) radius = try util.requireNumber(vm, args[0], "fillet_edges", "r");
    if (parsed.opts.r) |r| radius = r;
    try util.requirePositive(vm, radius, "fillet_edges", "r");

    // Generate tool and sum
    const sphere_idx = try vm.dag_builder.addSphere(radius, util.autoSegments(vm, radius));
    const new_idx = try vm.dag_builder.addBinary(.minkowski, receiver.dag_idx, sphere_idx);

    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshSimplify(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    var tolerance: ?f64 = null;

    // Optional positional argument: part.simplify(0.01); nil keeps the configured tolerance.
    if (args.len > 0 and !args[0].isNil()) tolerance = try util.requireNumber(vm, args[0], "simplify", "tolerance");

    const tol = tolerance orelse vm.config().tolerance;

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
