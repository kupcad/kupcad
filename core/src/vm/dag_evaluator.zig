const std = @import("std");
const dag = @import("dag.zig");
const error_kind = @import("error_kind.zig");
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");
const log_helpers = @import("../log.zig");
const VM = @import("vm.zig").VM;

/// Golden-ratio multiplier used to spread engine tags across the 64-bit key space.
const ENGINE_KEY_SALT: u64 = 0x9E3779B97F4A7C15;

inline fn engineSalt(engine: geom.EngineType) u64 {
    // Manifold (tag 0) keeps salt 0, so its keys equal the raw node hash.
    return @as(u64, @backingInt(engine)) *% ENGINE_KEY_SALT;
}

/// dag_cache key for a node evaluated under `engine`. The same DAG node evaluated
/// under different engines yields different handle types, so the engine must be
/// part of the key or a Manifold handle could be fed to the B-Rep driver.
pub inline fn cacheKey(node_hash: u64, engine: geom.EngineType) u64 {
    return node_hash ^ engineSalt(engine);
}

/// Inverse of `cacheKey`, recovering the DAG node hash from a dag_cache entry
/// (the handle records which engine produced it). Used by GC cache eviction.
pub inline fn nodeHashOfCacheEntry(key: u64, handle: geom.GeometryHandle) u64 {
    return key ^ engineSalt(handle.engine);
}

/// Tagged handle to safely track unconsumed 2D/3D resources during evaluation
pub const ValueHandle = union(enum) {
    geometry: geom.GeometryHandle,
    cross_section: geom.CrossSectionHandle,
    array: []geom.GeometryHandle,

    pub fn destruct(self: ValueHandle, allocator: std.mem.Allocator) void {
        switch (self) {
            .geometry => |h| kernel.destruct(h),
            .cross_section => |h| kernel.destructCrossSection(h),
            .array => |arr| {
                for (arr) |h| kernel.destruct(h);
                allocator.free(arr);
            },
        }
    }
};

/// A value on the intermediate stack plus who owns it.
/// `owned == false` means vm.dag_cache owns the handle (a cache hit, or a result
/// already inserted into the cache) and the evaluator must never destroy it.
/// Cross-sections are never cached, so they stay owned until consumed.
pub const StackEntry = struct {
    value: ValueHandle,
    owned: bool,
};

/// Dynamic intermediate value stack replacing recursive C++ object returns
pub const IntermediateStack = struct {
    handles: std.ArrayListUnmanaged(StackEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IntermediateStack {
        return .{ .allocator = allocator };
    }

    /// Pushes a freshly created handle; destroys it if the push itself fails.
    pub fn pushOwned(self: *IntermediateStack, handle: ValueHandle) !void {
        self.handles.append(self.allocator, .{ .value = handle, .owned = true }) catch |err| {
            handle.destruct(self.allocator);
            return err;
        };
    }

    /// Pushes a handle owned by someone else (the DAG cache).
    pub fn pushBorrowed(self: *IntermediateStack, handle: ValueHandle) !void {
        try self.handles.append(self.allocator, .{ .value = handle, .owned = false });
    }

    pub fn pop(self: *IntermediateStack) StackEntry {
        std.debug.assert(self.handles.items.len > 0);
        // Universally compatible across Zig versions
        const val = self.handles.items[self.handles.items.len - 1];
        self.handles.items.len -= 1;
        return val;
    }

    /// Releases a consumed operand: destroys it only if the evaluator owns it.
    pub fn release(self: *IntermediateStack, entry: StackEntry) void {
        if (entry.owned) entry.value.destruct(self.allocator);
    }

    /// Error-path cleanup: destroys only evaluator-owned handles. Cache-owned
    /// entries are left to vm.dag_cache, otherwise they would be freed twice.
    pub fn destructOwned(self: *IntermediateStack) void {
        while (self.handles.items.len > 0) {
            self.release(self.pop());
        }
        self.handles.deinit(self.allocator);
    }
};

fn geometryOf(entry: StackEntry) !geom.GeometryHandle {
    return switch (entry.value) {
        .geometry => |h| h,
        else => error.RuntimeError,
    };
}

fn crossSectionOf(entry: StackEntry) !geom.CrossSectionHandle {
    return switch (entry.value) {
        .cross_section => |h| h,
        else => error.RuntimeError,
    };
}

/// A kernel operation returned no result: raise a rescuable GeometryError naming the
/// operation. Drivers never substitute an operand for a failed result (kernel.zig).
fn kernelFailed(vm: *VM, tag: dag.DAGTag) error{RuntimeError} {
    _ = vm.raiseError(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{dag.scriptName(tag)});
    return error.RuntimeError;
}

fn checkSameEngine(vm: *VM, a: geom.EngineType, b: geom.EngineType) !void {
    if (a != b) {
        vm.reportError("Runtime Error: cannot combine {s} and {s} geometry in one operation.\n", .{ @tagName(a), @tagName(b) });
        return error.EngineMismatch;
    }
}

const EvalState = enum {
    visit,
    execute,
};

pub const EvaluationFrame = struct {
    node_idx: dag.DAGNodeIndex,
    state: EvalState = .visit,
};

pub const EvaluationFrameStack = struct {
    frames: std.ArrayListUnmanaged(EvaluationFrame) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EvaluationFrameStack {
        return .{ .allocator = allocator };
    }

    pub fn push(self: *EvaluationFrameStack, node_idx: dag.DAGNodeIndex) !void {
        try self.frames.append(self.allocator, .{ .node_idx = node_idx });
    }

    pub fn pop(self: *EvaluationFrameStack) EvaluationFrame {
        std.debug.assert(self.frames.items.len > 0);
        const val = self.frames.items[self.frames.items.len - 1];
        self.frames.items.len -= 1;
        return val;
    }

    pub fn deinit(self: *EvaluationFrameStack) void {
        self.frames.deinit(self.allocator);
    }
};

fn dumpDAG(vm: *VM, node_idx: dag.DAGNodeIndex, depth: usize) void {
    if (depth > 20) {
        log_helpers.printStdout("... [max depth reached]\n", .{});
        return;
    }
    if (node_idx >= vm.dag_builder.nodes.items.len) {
        log_helpers.printStdout("[OUT OF BOUNDS: {d}]\n", .{node_idx});
        return;
    }

    const node = vm.dag_builder.nodes.items[node_idx];

    var i: usize = 0;
    while (i < depth) : (i += 1) log_helpers.printStdout("  ", .{});

    log_helpers.printStdout("Node #{d}: {s}", .{ node_idx, @tagName(node.tag) });

    switch (node.tag) {
        .union_op, .difference_op, .intersection_op, .cs_union_op, .cs_difference_op, .cs_intersection_op, .minkowski => {
            const p = vm.dag_builder.getBinaryPayload(node);
            log_helpers.printStdout("\n", .{});
            dumpDAG(vm, p.left, depth + 1);
            dumpDAG(vm, p.right, depth + 1);
        },
        .translate, .rotate, .scale, .mirror, .hull, .trim_by_plane, .set_material => {
            const p = vm.dag_builder.getTranslatePayload(node);
            log_helpers.printStdout("\n", .{});
            dumpDAG(vm, p.target, depth + 1);
        },
        .extrude, .revolve => {
            const p = vm.dag_builder.getExtrudePayload(node);
            log_helpers.printStdout(" (sweeping 2D target)\n", .{});
            dumpDAG(vm, p.target, depth + 1);
        },
        .loft => {
            const p = vm.dag_builder.getLoftPayload(node);
            log_helpers.printStdout(" (height: {d})\n", .{p.height});
            dumpDAG(vm, p.base, depth + 1);
            dumpDAG(vm, p.top, depth + 1);
        },
        .batch_union_op, .batch_hull_op => {
            const targets = vm.dag_builder.getBatchUnionPayload(node);
            log_helpers.printStdout(" (batch count: {d})\n", .{targets.len});
            for (targets) |t_idx| {
                dumpDAG(vm, t_idx, depth + 1);
            }
        },
        else => {
            log_helpers.printStdout("\n", .{});
        },
    }
}

fn evaluateInternal(vm: *VM, root_node_idx: dag.DAGNodeIndex) anyerror!ValueHandle {
    var v_stack = IntermediateStack.init(vm.allocator);
    // Only evaluator-owned entries are destroyed on error; see StackEntry.
    errdefer v_stack.destructOwned();

    var f_stack = EvaluationFrameStack.init(vm.allocator);
    defer f_stack.deinit();

    try f_stack.push(root_node_idx);

    const config = vm.config_stack.items[vm.config_stack.items.len - 1];
    const engine = config.engine;

    while (f_stack.frames.items.len > 0) {
        if (vm.cancel_token.load(.acquire)) return error.Cancelled;

        var frame = &f_stack.frames.items[f_stack.frames.items.len - 1];

        if (frame.node_idx >= vm.dag_builder.nodes.items.len) {
            vm.reportError("Runtime Error: DAG Node Index {d} out of bounds.\n", .{frame.node_idx});
            return error.RuntimeError;
        }

        // --- O(1) DAG Node Caching ---
        const node_hash = vm.dag_builder.node_hashes.items[frame.node_idx];
        const cache_key = cacheKey(node_hash, engine);
        if (vm.dag_cache.get(cache_key)) |cached_handle| {
            _ = f_stack.pop();
            try v_stack.pushBorrowed(.{ .geometry = cached_handle });
            continue;
        }

        const node = vm.dag_builder.nodes.items[frame.node_idx];

        if (frame.state == .visit) {
            frame.state = .execute;

            // Push children onto the frame stack (Post-Order Traversal)
            switch (node.tag) {
                .union_op, .difference_op, .intersection_op, .minkowski, .cs_union_op, .cs_difference_op, .cs_intersection_op => {
                    const p = vm.dag_builder.getBinaryPayload(node);
                    // Push right then left so left evaluates first
                    try f_stack.push(p.right);
                    try f_stack.push(p.left);
                },
                .translate, .rotate, .scale, .mirror, .hull, .trim_by_plane, .set_material, .transform_matrix, .project_op, .slice_op, .offset, .cs_transform => {
                    // All these ops store their child in 'target' as the first payload extra_data
                    const target_idx = vm.dag_builder.extra_data.items[node.data];
                    try f_stack.push(target_idx);
                },
                .extrude, .revolve => {
                    const target_idx = vm.dag_builder.extra_data.items[node.data];
                    try f_stack.push(target_idx);
                },
                .loft => {
                    const p = vm.dag_builder.getLoftPayload(node);
                    try f_stack.push(p.top);
                    try f_stack.push(p.base);
                },
                .batch_union_op, .batch_hull_op => {
                    const targets = vm.dag_builder.getBatchUnionPayload(node);
                    // Push backwards so they evaluate left-to-right
                    var i: usize = targets.len;
                    while (i > 0) {
                        i -= 1;
                        try f_stack.push(targets[i]);
                    }
                },
                else => {}, // Leaf nodes have no children to visit
            }
        } else {
            // State == .execute
            _ = f_stack.pop();

            // Operands are popped into locals and released by `defer`, so they are
            // freed (if owned) on both success and error paths. Kernel calls never
            // consume their inputs and always return new handles (kernel.zig).
            switch (node.tag) {
                // --- Leaf Geometry 3D ---
                .cube => {
                    const p = vm.dag_builder.getCubeDimensions(node);
                    const handle = kernel.cube(engine, p.x, p.y, p.z, p.center) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = handle });
                },
                .cylinder => {
                    const p = vm.dag_builder.getCylinderPayload(node);
                    const handle = kernel.cylinder(engine, p.r1, p.r2, p.height, p.center, p.segments) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = handle });
                },
                .sphere => {
                    const p = vm.dag_builder.getSpherePayload(node);
                    const handle = kernel.sphere(engine, p.radius) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = handle });
                },
                .polyhedron_op => {
                    const p = vm.dag_builder.getPolyhedronPayload(node);
                    const handle = kernel.polyhedron(engine, vm.allocator, p.pts, p.faces) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = handle });
                },

                .concrete => {
                    // Owned by dag_builder.concrete_handles: borrow it, never cache it.
                    if (node.data >= vm.dag_builder.concrete_handles.items.len) return error.RuntimeError;
                    try v_stack.pushBorrowed(.{ .geometry = vm.dag_builder.concrete_handles.items[node.data] });
                },

                // --- Binary 3D Ops ---
                .union_op, .difference_op, .intersection_op, .minkowski => {
                    const right = v_stack.pop();
                    defer v_stack.release(right);
                    const left = v_stack.pop();
                    defer v_stack.release(left);
                    const left_handle = try geometryOf(left);
                    const right_handle = try geometryOf(right);
                    try checkSameEngine(vm, left_handle.engine, right_handle.engine);

                    const result = switch (node.tag) {
                        .union_op => kernel.boolean(left_handle, right_handle, .union_op),
                        .difference_op => kernel.boolean(left_handle, right_handle, .difference_op),
                        .intersection_op => kernel.boolean(left_handle, right_handle, .intersection_op),
                        .minkowski => kernel.minkowski(left_handle, right_handle),
                        else => unreachable,
                    } orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = maybeSimplify(vm, result) });
                },

                // --- Batch 3D Ops ---
                .batch_union_op, .batch_hull_op => {
                    const targets = vm.dag_builder.getBatchUnionPayload(node);
                    if (targets.len == 0) return error.RuntimeError;

                    const entries = try vm.allocator.alloc(StackEntry, targets.len);
                    defer vm.allocator.free(entries);
                    // Pop in reverse order to restore original left-to-right hierarchy
                    var i: usize = targets.len;
                    while (i > 0) {
                        i -= 1;
                        entries[i] = v_stack.pop();
                    }
                    defer for (entries) |e| v_stack.release(e);

                    const handles = try vm.allocator.alloc(geom.GeometryHandle, targets.len);
                    defer vm.allocator.free(handles);
                    for (entries, handles) |e, *h| {
                        h.* = try geometryOf(e);
                        try checkSameEngine(vm, handles[0].engine, h.engine);
                    }

                    const result = if (node.tag == .batch_union_op)
                        kernel.batchBoolean(vm.allocator, handles, .union_op) orelse return kernelFailed(vm, node.tag)
                    else
                        kernel.batchHull(vm.allocator, handles) orelse return kernelFailed(vm, node.tag);

                    try v_stack.pushOwned(.{ .geometry = maybeSimplify(vm, result) });
                },

                // --- Unary 3D Transforms ---
                .translate, .rotate, .scale, .mirror => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const target_handle = try geometryOf(target);
                    const p = vm.dag_builder.getTranslatePayload(node); // All share same struct layout
                    const result = switch (node.tag) {
                        .translate => kernel.translate(target_handle, p.x, p.y, p.z),
                        .rotate => kernel.rotate(target_handle, p.x, p.y, p.z),
                        .scale => kernel.scale(target_handle, p.x, p.y, p.z),
                        .mirror => kernel.mirror(target_handle, p.x, p.y, p.z),
                        else => unreachable,
                    };
                    try v_stack.pushOwned(.{ .geometry = result orelse return kernelFailed(vm, node.tag) });
                },
                .transform_matrix => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getTransformPayload(node);
                    var mat: [12]f64 = undefined;
                    std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 12]);
                    const result = kernel.transformMatrix(try geometryOf(target), mat) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },
                .trim_by_plane => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getTrimByPlanePayload(node);
                    const result = kernel.trimByPlane(try geometryOf(target), p.nx, p.ny, p.nz, p.offset) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },
                .hull => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const result = kernel.hull(try geometryOf(target)) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = maybeSimplify(vm, result) });
                },
                .set_material => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getMaterialPayload(node);
                    const result = kernel.setMaterial(try geometryOf(target), p.material_id) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },

                // --- 2D to 3D Generation ---
                .extrude => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getExtrudePayload(node);
                    const result = kernel.extrude(try crossSectionOf(target), p.height, p.slices, p.twist_degrees, p.scale_x, p.scale_y) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },
                .revolve => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getRevolvePayload(node);
                    const result = kernel.revolve(try crossSectionOf(target), p.segments, p.degrees) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },
                .loft => {
                    const top = v_stack.pop();
                    defer v_stack.release(top);
                    const base = v_stack.pop();
                    defer v_stack.release(base);
                    const top_cs = try crossSectionOf(top);
                    const base_cs = try crossSectionOf(base);
                    try checkSameEngine(vm, base_cs.engine, top_cs.engine);
                    const p = vm.dag_builder.getLoftPayload(node);
                    const result = kernel.loft(engine, base_cs, top_cs, p.height) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },

                // --- Leaf Cross Sections 2D ---
                .square => {
                    const p = vm.dag_builder.getSquarePayload(node);
                    const handle = kernel.square(engine, p.x, p.y, p.center) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .circle => {
                    const p = vm.dag_builder.getCirclePayload(node);
                    const handle = kernel.circle(engine, p.radius, p.segments) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .polygon => {
                    const num_idx = vm.dag_builder.extra_data.items[node.data];
                    const pt_count = vm.dag_builder.extra_data.items[node.data + 1];
                    var pts = try vm.allocator.alloc([2]f64, pt_count);
                    defer vm.allocator.free(pts);
                    for (0..pt_count) |i| {
                        pts[i][0] = vm.dag_builder.numbers.items[num_idx + (i * 2)];
                        pts[i][1] = vm.dag_builder.numbers.items[num_idx + (i * 2) + 1];
                    }
                    const handle = kernel.polygon(engine, vm.allocator, pts) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .polygons_even_odd => {
                    const num_contours = vm.dag_builder.extra_data.items[node.data];
                    var contours = try vm.allocator.alloc([][2]f64, num_contours);
                    // Empty slots make the deferred free safe after a partial allocation failure.
                    @memset(contours, &.{});
                    defer {
                        for (contours) |c| vm.allocator.free(c);
                        vm.allocator.free(contours);
                    }

                    for (0..num_contours) |i| {
                        const pts_start = vm.dag_builder.extra_data.items[node.data + 1 + (i * 2)];
                        const pts_len = vm.dag_builder.extra_data.items[node.data + 1 + (i * 2) + 1];

                        var pts = try vm.allocator.alloc([2]f64, pts_len);
                        for (0..pts_len) |pt_idx| {
                            pts[pt_idx][0] = vm.dag_builder.numbers.items[pts_start + (pt_idx * 2)];
                            pts[pt_idx][1] = vm.dag_builder.numbers.items[pts_start + (pt_idx * 2) + 1];
                        }
                        contours[i] = pts;
                    }
                    const handle = kernel.polygonsEvenOdd(engine, vm.allocator, contours) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },

                // --- 3D to 2D Generation ---
                .slice_op => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getSlicePayload(node);
                    const handle = kernel.slice(try geometryOf(target), p.height) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .project_op => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const handle = kernel.project(try geometryOf(target)) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },

                // --- 2D Ops ---
                .offset => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getOffsetPayload(node);
                    const handle = kernel.offset(try crossSectionOf(target), p.delta, p.join_type) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .cs_transform => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getTransformPayload(node);
                    var mat: [6]f64 = undefined;
                    std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 6]);
                    const handle = kernel.crossSectionTransform(try crossSectionOf(target), mat) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .cs_union_op, .cs_difference_op, .cs_intersection_op => {
                    const right = v_stack.pop();
                    defer v_stack.release(right);
                    const left = v_stack.pop();
                    defer v_stack.release(left);
                    const left_handle = try crossSectionOf(left);
                    const right_handle = try crossSectionOf(right);
                    try checkSameEngine(vm, left_handle.engine, right_handle.engine);
                    const op: kernel.BooleanOp = switch (node.tag) {
                        .cs_union_op => .union_op,
                        .cs_difference_op => .difference_op,
                        .cs_intersection_op => .intersection_op,
                        else => unreachable,
                    };
                    const handle = kernel.crossSectionBoolean(left_handle, right_handle, op) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
            }

            const top = &v_stack.handles.items[v_stack.handles.items.len - 1];

            // Only freshly computed results move into the cache; borrowed ones
            // (concrete leaves) already have an owner.
            if (top.value == .geometry and top.owned) {
                // Every freshly computed solid is checked here, once: an invalid mesh (e.g. a
                // non-manifold polyhedron) is an error, not an empty export later.
                if (kernel.problem(top.value.geometry)) |reason| {
                    _ = vm.raiseError(.GeometryError, error_kind.INVALID_RESULT_FMT, .{ dag.scriptName(node.tag), reason });
                    return error.RuntimeError; // still owned -> destroyed by errdefer
                }
                const verts = kernel.numVerts(top.value.geometry);
                if (verts > config.max_vertices) {
                    vm.reportError("RAM Budget Exceeded: Generated mesh is too complex ({d} vertices).\n", .{verts});
                    return error.RamBudgetExceeded; // still owned -> destroyed by errdefer
                }

                // Ownership moves to the cache only once the put succeeds.
                try vm.dag_cache.put(vm.allocator, cache_key, top.value.geometry);
                top.owned = false;
            }
            // Cross-sections are intentionally not cached: they stay owned by the
            // stack and are destroyed by the consuming parent (or returned to the caller).
        }
    }

    std.debug.assert(v_stack.handles.items.len == 1);
    const result = v_stack.pop();
    v_stack.handles.deinit(vm.allocator); // Free the dynamic array on success
    // Geometry results are borrowed from vm.dag_cache; cross-section results are
    // owned by the caller.
    return result.value;
}

/// Returns a geometry handle BORROWED from vm.dag_cache (the cache owns it and the
/// GC evicts it once no ObjGeometry references the node). Callers that keep the
/// handle beyond the current operation must kernel.clone it.
pub fn evaluateDAG(vm: *VM, root_node_idx: dag.DAGNodeIndex) anyerror!geom.GeometryHandle {
    const final_val = try evaluateInternal(vm, root_node_idx);
    if (final_val == .cross_section) {
        // Cross-sections are never cached, so this one is ours to free.
        final_val.destruct(vm.allocator);
        return error.RuntimeError;
    }
    return final_val.geometry;
}

/// Returns a cross-section handle OWNED by the caller.
pub fn evaluateCrossSectionDAG(vm: *VM, root_node_idx: dag.DAGNodeIndex) anyerror!geom.CrossSectionHandle {
    const final_val = try evaluateInternal(vm, root_node_idx);
    // A geometry result is owned by vm.dag_cache; leave it there (freeing it here
    // would leave a dangling cache entry).
    if (final_val == .geometry) return error.RuntimeError;
    return final_val.cross_section;
}

/// Takes ownership of `handle` (a fresh, uncached result) and returns the
/// handle to keep: either the same one or a simplified replacement.
inline fn maybeSimplify(vm: *VM, handle: geom.GeometryHandle) geom.GeometryHandle {
    const config = vm.config_stack.items[vm.config_stack.items.len - 1];
    if (handle.engine == .manifold and config.manifold.simplify_coplanar) {
        const simplified = kernel.simplify(handle, config.manifold.tolerance) orelse return handle;
        kernel.destruct(handle);
        return simplified;
    }
    return handle;
}
