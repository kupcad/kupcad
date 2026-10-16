//! Evaluates the geometry DAG the VM builds into kernel shapes: a post-order walk on an
//! explicit stack that reuses results from `vm.dag_cache`, batches chains of unions into one
//! kernel call, and keeps the shapes it makes within the vertex budget. Entry points
//! `evaluateDAG` and `evaluateCrossSectionDAG`, called from vm.zig.

const std = @import("std");
const dag = @import("dag.zig");
const error_kind = @import("error_kind.zig");
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");
const log_helpers = @import("../log.zig");
const VM = @import("vm.zig").VM;
const EngineConfig = @import("../core/engine_config.zig").EngineConfig;

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
/// `owned == false` means vm.dag_cache (or vm.cs_cache, for a sketch) owns the handle (a
/// cache hit, or a result already inserted into the cache) and the evaluator must never
/// destroy it.
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
    return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{dag.scriptName(tag)});
}

/// Raises the vertex-limit error when `verts` passes `limit`. `estimated` is set for a
/// check made before the kernel runs, from what the operation's inputs imply.
fn checkVertexLimit(vm: *VM, tag: dag.DAGTag, verts: usize, limit: usize, comptime estimated: bool) error{RamBudgetExceeded}!void {
    if (verts <= limit) return;
    const verb = if (estimated) "would produce about" else "produced";
    _ = vm.raiseError(.GeometryError, "{s} " ++ verb ++ " {d} vertices, above the {d}-vertex limit; lower the resolution (segments:) or simplify the model", .{ dag.scriptName(tag), verts, limit });
    return error.RamBudgetExceeded;
}

/// An operation whose result multiplies its inputs (a Minkowski sum, an extrusion's
/// slices, a revolution's segments) is checked against the vertex limit before the kernel
/// allocates it. The limit used to apply only to the finished mesh, by which time the
/// kernel could already have run out of memory, which aborts the process (it is built
/// without exceptions, so a failed allocation can't be caught).
fn checkEstimatedVertices(vm: *VM, tag: dag.DAGTag, factors: []const usize, limit: usize) error{RamBudgetExceeded}!void {
    var verts: usize = 1;
    for (factors) |f| verts = std.math.mul(usize, verts, f) catch std.math.maxInt(usize);
    return checkVertexLimit(vm, tag, verts, limit, true);
}

/// A hull of a curved solid needs an engine that hulls curved faces, not just vertices.
fn requireFlatOrCurvedHull(vm: *VM, solid: geom.GeometryHandle) !void {
    if (kernel.hasCurvedFaces(solid)) try vm.requireFeature(solid.engine, .curved_hull);
}

const EvalState = enum {
    visit,
    execute,
};

/// Whether `tag` moves a solid without changing its mesh: the vertex count is its
/// operand's, and a valid solid stays valid (the numbers are finite, checked where the
/// script gives them), so the result checks the evaluator makes on every fresh solid
/// have nothing to find. They also cost more than the transform: Manifold applies a
/// transform lazily, composing a chain of them into one matrix, and asking for the status
/// or the vertex count applies it then and there, so a chain of 200 translates took 12×
/// the time of one.
fn isPureTransform(tag: dag.DAGTag) bool {
    return switch (tag) {
        .translate, .rotate, .scale, .mirror, .transform_matrix => true,
        else => false,
    };
}

/// The operands of the chain of unions under `root`, `((a + b) + c) + d` as a script's
/// `acc = acc + part` loop builds it, left to right in `chain`, so the kernel unions them
/// in one batch: one call sorts and merges N shapes, where the chain made N − 1 calls,
/// each over a growing result (300 parts took 60× the batch). A union already in the
/// cache is one operand, so after an edit only the new parts join the cached rest.
fn collectUnionOperands(vm: *VM, chain: *std.ArrayListUnmanaged(dag.DAGNodeIndex), root: dag.DAGNode) !void {
    chain.clearRetainingCapacity();
    var work: std.ArrayListUnmanaged(dag.DAGNodeIndex) = .empty;
    defer work.deinit(vm.allocator);
    const p = vm.dag_builder.getBinaryPayload(root);
    try work.appendSlice(vm.allocator, &.{ p.right, p.left });
    while (work.pop()) |idx| {
        if (idx < vm.dag_builder.nodes.items.len) {
            const node = vm.dag_builder.nodes.items[idx];
            if (node.tag == .union_op and !vm.dag_cache.contains(vm.dag_builder.node_hashes.items[idx])) {
                const q = vm.dag_builder.getBinaryPayload(node);
                try work.appendSlice(vm.allocator, &.{ q.right, q.left });
                continue;
            }
        }
        try chain.append(vm.allocator, idx);
    }
}

/// Unions or hulls the top `count` operands of `v_stack` in one kernel call, as a batch
/// node asks (or a chain of unions flattened to one, see collectUnionOperands).
fn executeBatch(vm: *VM, v_stack: *IntermediateStack, config: EngineConfig, tag: dag.DAGTag, count: usize) !void {
    if (count == 0) return error.RuntimeError;
    const is_union = tag == .batch_union_op;

    const entries = try vm.allocator.alloc(StackEntry, count);
    defer vm.allocator.free(entries);
    // Pop in reverse order to restore original left-to-right hierarchy
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        entries[i] = v_stack.pop();
    }
    defer for (entries) |e| v_stack.release(e);

    const handles = try vm.allocator.alloc(geom.GeometryHandle, count);
    defer vm.allocator.free(handles);
    for (entries, handles) |e, *h| {
        h.* = try geometryOf(e);
        try vm.requireSameEngine(handles[0].engine, h.engine);
    }
    if (is_union) try vm.requireFeature(handles[0].engine, .boolean);
    if (!is_union) for (handles) |h| try requireFlatOrCurvedHull(vm, h);

    const result = if (is_union)
        kernel.batchBoolean(vm.allocator, handles, .union_op) orelse return kernelFailed(vm, tag)
    else
        kernel.batchHull(vm.allocator, handles) orelse return kernelFailed(vm, tag);

    try v_stack.pushOwned(.{ .geometry = maybeSimplify(config, result) });
}

pub const EvaluationFrame = struct {
    node_idx: dag.DAGNodeIndex,
    state: EvalState = .visit,
    /// For a union at the top of a chain of unions: how many operands the chain was
    /// flattened to (see collectUnionOperands); 0 for every other node.
    operands: u32 = 0,
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

    // The operands of the union chain being visited (collectUnionOperands).
    var chain: std.ArrayListUnmanaged(dag.DAGNodeIndex) = .empty;
    defer chain.deinit(vm.allocator);

    try f_stack.push(root_node_idx);

    while (f_stack.frames.items.len > 0) {
        if (vm.cancel_token.load(.acquire)) return error.Canceled;

        var frame = &f_stack.frames.items[f_stack.frames.items.len - 1];

        if (frame.node_idx >= vm.dag_builder.nodes.items.len) {
            return vm.fail(.RuntimeError, "internal error: geometry node {d} is out of range", .{frame.node_idx});
        }

        // --- O(1) DAG Node Caching ---
        // The hash covers the node's settings, so it is the whole key: the same shape made
        // under another engine, tolerance or resolution is another node.
        const node_hash = vm.dag_builder.node_hashes.items[frame.node_idx];
        if (vm.dag_cache.get(node_hash)) |cached| {
            _ = f_stack.pop();
            try v_stack.pushBorrowed(.{ .geometry = cached });
            continue;
        }
        if (vm.cs_cache.get(node_hash)) |cached| {
            _ = f_stack.pop();
            try v_stack.pushBorrowed(.{ .cross_section = cached });
            continue;
        }

        const node = vm.dag_builder.nodes.items[frame.node_idx];
        // The settings the node was made under, whatever is in force now.
        const config = vm.dag_builder.settings(node.settings);

        if (frame.state == .visit) {
            frame.state = .execute;

            // Push children onto the frame stack (Post-Order Traversal)
            switch (node.tag) {
                .union_op => {
                    try collectUnionOperands(vm, &chain, node);
                    // Two operands: the plain binary union below. More: a batch of them.
                    // The count goes on the frame before anything is pushed (pushing may
                    // move the frames).
                    if (chain.items.len > 2) frame.operands = @intCast(chain.items.len);
                    var i: usize = chain.items.len;
                    while (i > 0) {
                        i -= 1;
                        try f_stack.push(chain.items[i]);
                    }
                },
                .difference_op, .intersection_op, .minkowski, .cs_union_op, .cs_difference_op, .cs_intersection_op => {
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
            const operands = frame.operands;
            _ = f_stack.pop();

            // Operands are popped into locals and released by `defer`, so they are
            // freed (if owned) on both success and error paths. Kernel calls never
            // consume their inputs and always return new handles (kernel.zig).
            if (operands > 2) try executeBatch(vm, &v_stack, config, .batch_union_op, operands) else switch (node.tag) {
                // --- Leaf Geometry 3D ---
                .empty_solid => {
                    try vm.requireFeature(config.engine, .empty);
                    const handle = kernel.empty(&config) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = handle });
                },
                .empty_sketch => {
                    try vm.requireFeature(config.engine, .empty);
                    const handle = kernel.emptySketch(&config) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .cube => {
                    const p = vm.dag_builder.getCubeDimensions(node);
                    const handle = kernel.cube(&config, p.x, p.y, p.z, p.center) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = handle });
                },
                .cylinder => {
                    const p = vm.dag_builder.getCylinderPayload(node);
                    if (p.r1 != p.r2) try vm.requireFeature(config.engine, .cone);
                    const handle = kernel.cylinder(&config, p.r1, p.r2, p.height, p.center, p.segments) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = handle });
                },
                .sphere => {
                    try vm.requireFeature(config.engine, .sphere);
                    const p = vm.dag_builder.getSpherePayload(node);
                    const handle = kernel.sphere(&config, p.radius, p.segments) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = handle });
                },
                .polyhedron_op => {
                    const p = vm.dag_builder.getPolyhedronPayload(node);
                    const handle = kernel.polyhedron(&config, vm.allocator, p.pts, p.faces) orelse return kernelFailed(vm, node.tag);
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
                    try vm.requireSameEngine(left_handle.engine, right_handle.engine);
                    try vm.requireFeature(left_handle.engine, if (node.tag == .minkowski) .minkowski else .boolean);
                    if (node.tag == .minkowski) {
                        try checkEstimatedVertices(vm, node.tag, &.{ kernel.numVerts(left_handle), kernel.numVerts(right_handle) }, config.max_vertices);
                    }

                    const result = switch (node.tag) {
                        .union_op => kernel.boolean(left_handle, right_handle, .union_op),
                        .difference_op => kernel.boolean(left_handle, right_handle, .difference_op),
                        .intersection_op => kernel.boolean(left_handle, right_handle, .intersection_op),
                        .minkowski => kernel.minkowski(left_handle, right_handle),
                        else => unreachable,
                    } orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = maybeSimplify(config, result) });
                },

                // --- Batch 3D Ops ---
                .batch_union_op, .batch_hull_op => {
                    const targets = vm.dag_builder.getBatchUnionPayload(node);
                    try executeBatch(vm, &v_stack, config, node.tag, targets.len);
                },

                // --- Unary 3D Transforms ---
                .translate, .rotate, .scale, .mirror => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const target_handle = try geometryOf(target);
                    try vm.requireFeature(target_handle.engine, .transform);
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
                    const solid = try geometryOf(target);
                    try vm.requireFeature(solid.engine, .transform);
                    const result = kernel.transformMatrix(solid, mat) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },
                .trim_by_plane => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getTrimByPlanePayload(node);
                    const solid = try geometryOf(target);
                    try vm.requireFeature(solid.engine, .trim_by_plane);
                    const result = kernel.trimByPlane(solid, p.nx, p.ny, p.nz, p.offset) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },
                .hull => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const solid = try geometryOf(target);
                    try requireFlatOrCurvedHull(vm, solid);
                    const result = kernel.hull(solid) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = maybeSimplify(config, result) });
                },
                .set_material => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getMaterialPayload(node);
                    const solid = try geometryOf(target);
                    vm.warnUnsupported(solid.engine, .materials);
                    const result = kernel.setMaterial(solid, p.material_id) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },

                // --- 2D to 3D Generation ---
                .extrude => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getExtrudePayload(node);
                    const profile = try crossSectionOf(target);
                    try vm.requireFeature(profile.engine, .extrude);
                    if (p.twist_degrees != 0) try vm.requireFeature(profile.engine, .extrude_twist);
                    if (p.scale_x != 1 or p.scale_y != 1) try vm.requireFeature(profile.engine, .extrude_scale);
                    // A copy of the profile at the bottom, the top and each slice between.
                    try checkEstimatedVertices(vm, node.tag, &.{ kernel.crossSectionNumVerts(profile), @as(usize, @intCast(@max(p.slices, 0))) + 2 }, config.max_vertices);
                    const result = kernel.extrude(profile, p.height, p.slices, p.twist_degrees, p.scale_x, p.scale_y) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },
                .revolve => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getRevolvePayload(node);
                    const profile = try crossSectionOf(target);
                    try vm.requireFeature(profile.engine, .revolve);
                    // A copy of the profile per segment, and one more to close a partial turn.
                    try checkEstimatedVertices(vm, node.tag, &.{ kernel.crossSectionNumVerts(profile), @as(usize, @intCast(@max(p.segments, 0))) + 1 }, config.max_vertices);
                    const result = kernel.revolve(profile, p.segments, p.degrees) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },
                .loft => {
                    const top = v_stack.pop();
                    defer v_stack.release(top);
                    const base = v_stack.pop();
                    defer v_stack.release(base);
                    const top_cs = try crossSectionOf(top);
                    const base_cs = try crossSectionOf(base);
                    try vm.requireSameEngine(base_cs.engine, top_cs.engine);
                    try vm.requireFeature(base_cs.engine, .loft);
                    // loft is a hull of the two profiles, which is only the true loft for convex
                    // ones; a concave profile would be filled in silently.
                    inline for (.{ .{ "base", base_cs }, .{ "top", top_cs } }) |profile| {
                        if (kernel.crossSectionIsConvex(profile[1]) == false) {
                            return vm.fail(.NotImplementedError, "loft supports convex profiles only for now; the " ++ profile[0] ++ " profile is concave or has holes", .{});
                        }
                    }
                    const p = vm.dag_builder.getLoftPayload(node);
                    const result = kernel.loft(config.engine, vm.allocator, base_cs, top_cs, p.height) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .geometry = result });
                },

                // --- Leaf Cross Sections 2D ---
                .square => {
                    const p = vm.dag_builder.getSquarePayload(node);
                    const handle = kernel.square(&config, p.x, p.y, p.center) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .circle => {
                    const p = vm.dag_builder.getCirclePayload(node);
                    const handle = kernel.circle(&config, p.radius, p.segments) orelse return kernelFailed(vm, node.tag);
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
                    const handle = kernel.polygon(&config, vm.allocator, pts) orelse return kernelFailed(vm, node.tag);
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
                    const handle = kernel.polygonsEvenOdd(&config, vm.allocator, contours) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },

                // --- 3D to 2D Generation ---
                .slice_op => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getSlicePayload(node);
                    const solid = try geometryOf(target);
                    try vm.requireFeature(solid.engine, .slice);
                    const handle = kernel.slice(solid, p.height) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .project_op => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const solid = try geometryOf(target);
                    try vm.requireFeature(solid.engine, .project);
                    const handle = kernel.project(solid) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },

                // --- 2D Ops ---
                .offset => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getOffsetPayload(node);
                    const sketch = try crossSectionOf(target);
                    try vm.requireFeature(sketch.engine, .offset);
                    const handle = kernel.offset(sketch, p.delta, p.join_type) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .cs_transform => {
                    const target = v_stack.pop();
                    defer v_stack.release(target);
                    const p = vm.dag_builder.getTransformPayload(node);
                    var mat: [6]f64 = undefined;
                    std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 6]);
                    const sketch = try crossSectionOf(target);
                    try vm.requireFeature(sketch.engine, .transform);
                    const handle = kernel.crossSectionTransform(sketch, mat) orelse return kernelFailed(vm, node.tag);
                    try v_stack.pushOwned(.{ .cross_section = handle });
                },
                .cs_union_op, .cs_difference_op, .cs_intersection_op => {
                    const right = v_stack.pop();
                    defer v_stack.release(right);
                    const left = v_stack.pop();
                    defer v_stack.release(left);
                    const left_handle = try crossSectionOf(left);
                    const right_handle = try crossSectionOf(right);
                    try vm.requireSameEngine(left_handle.engine, right_handle.engine);
                    try vm.requireFeature(left_handle.engine, .sketch_boolean);
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
                // non-manifold polyhedron) is an error, not an empty export later. A moved
                // solid is its operand's, already checked (isPureTransform).
                if (!isPureTransform(node.tag)) {
                    if (kernel.problem(top.value.geometry)) |reason| {
                        return vm.fail(.GeometryError, error_kind.INVALID_RESULT_FMT, .{ dag.scriptName(node.tag), reason }); // still owned -> destroyed by errdefer
                    }
                    // On error the result is still owned, so the errdefer destroys it.
                    try checkVertexLimit(vm, node.tag, kernel.numVerts(top.value.geometry), config.max_vertices, false);
                }

                // Ownership moves to the cache only once the put succeeds.
                try vm.dag_cache.put(vm.allocator, node_hash, top.value.geometry);
                top.owned = false;
            } else if (top.value == .cross_section and top.owned) {
                try vm.cs_cache.put(vm.allocator, node_hash, top.value.cross_section);
                top.owned = false;
            }
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
    // A sketch's result is the cs_cache's, like a solid's is the dag_cache's.
    if (final_val == .cross_section) return error.RuntimeError;
    return final_val.geometry;
}

/// Returns a cross-section handle BORROWED from vm.cs_cache, as evaluateDAG's is from
/// vm.dag_cache.
pub fn evaluateCrossSectionDAG(vm: *VM, root_node_idx: dag.DAGNodeIndex) anyerror!geom.CrossSectionHandle {
    const final_val = try evaluateInternal(vm, root_node_idx);
    // A geometry result is owned by vm.dag_cache; leave it there (freeing it here
    // would leave a dangling cache entry).
    if (final_val == .geometry) return error.RuntimeError;
    return final_val.cross_section;
}

/// Takes ownership of `handle` (a fresh, uncached result) and returns the
/// handle to keep: either the same one or a simplified replacement.
inline fn maybeSimplify(config: EngineConfig, handle: geom.GeometryHandle) geom.GeometryHandle {
    if (handle.engine == .manifold and config.manifold.simplify_coplanar) {
        const simplified = kernel.simplify(handle, config.tolerance) orelse return handle;
        kernel.destruct(handle);
        return simplified;
    }
    return handle;
}
