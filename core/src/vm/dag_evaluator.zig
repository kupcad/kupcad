//! Evaluates the geometry DAG the VM builds into kernel shapes: a post-order walk on an
//! explicit stack that reuses results from `vm.dag_cache` and `vm.cs_cache`, batches chains
//! of unions into one kernel call, and keeps the shapes it makes within the vertex budget. Entry points
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

        const frame = &f_stack.frames.items[f_stack.frames.items.len - 1];
        if (frame.node_idx >= vm.dag_builder.nodes.items.len) {
            return vm.fail(.RuntimeError, "internal error: geometry node {d} is out of range", .{frame.node_idx});
        }

        // The hash covers the node's settings, so it is the whole key: the same shape made
        // under another engine, tolerance or resolution is another node.
        const node_hash = vm.dag_builder.node_hashes.items[frame.node_idx];
        if (try pushCached(vm, &v_stack, node_hash)) {
            _ = f_stack.pop();
            continue;
        }

        const node = vm.dag_builder.nodes.items[frame.node_idx];
        if (frame.state == .visit) {
            // Post-order: the operands are evaluated first, and the node when it is met again.
            frame.state = .execute;
            try pushOperands(vm, &f_stack, &chain, frame, node);
        } else {
            const operands = frame.operands;
            _ = f_stack.pop();
            // The settings the node was made under, whatever is in force now.
            const config = vm.dag_builder.settings(node.settings);
            if (operands > 2) try executeBatch(vm, &v_stack, config, .batch_union_op, operands) else try executeNode(vm, &v_stack, node, config);
            try cacheResult(vm, &v_stack, node.tag, node_hash, config);
        }
    }

    std.debug.assert(v_stack.handles.items.len == 1);
    const result = v_stack.pop();
    v_stack.handles.deinit(vm.allocator); // Free the dynamic array on success
    // Borrowed from vm.dag_cache (a solid) or vm.cs_cache (a sketch).
    return result.value;
}

/// Pushes the cached result of the node with `node_hash`, borrowed, if there is one.
fn pushCached(vm: *VM, v_stack: *IntermediateStack, node_hash: u64) !bool {
    if (vm.dag_cache.get(node_hash)) |cached| {
        try v_stack.pushBorrowed(.{ .geometry = cached });
        return true;
    }
    if (vm.cs_cache.get(node_hash)) |cached| {
        try v_stack.pushBorrowed(.{ .cross_section = cached });
        return true;
    }
    return false;
}

/// Pushes the frames of `node`'s operands, in reverse so they are evaluated left to right.
fn pushOperands(vm: *VM, f_stack: *EvaluationFrameStack, chain: *std.ArrayListUnmanaged(dag.DAGNodeIndex), frame: *EvaluationFrame, node: dag.DAGNode) !void {
    const b = &vm.dag_builder;
    switch (node.tag) {
        .union_op => {
            try collectUnionOperands(vm, chain, node);
            // Two operands: the plain binary union. More: a batch of them. The count goes
            // on the frame before anything is pushed (pushing may move the frames).
            if (chain.items.len > 2) frame.operands = @intCast(chain.items.len);
            try pushAll(f_stack, chain.items);
        },
        .difference_op, .intersection_op, .minkowski, .cs_union_op, .cs_difference_op, .cs_intersection_op => {
            const p = b.getBinaryPayload(node);
            try pushAll(f_stack, &.{ p.left, p.right });
        },
        // Each stores its operand ('target') first in its extra_data payload
        .translate, .rotate, .scale, .mirror, .hull, .trim_by_plane, .set_material, .transform_matrix, .project_op, .slice_op, .offset, .cs_transform, .extrude, .revolve => {
            try f_stack.push(b.extra_data.items[node.data]);
        },
        .loft => {
            const p = b.getLoftPayload(node);
            try pushAll(f_stack, &.{ p.base, p.top });
        },
        .batch_union_op, .batch_hull_op => try pushAll(f_stack, b.getBatchUnionPayload(node)),
        .empty_solid, .empty_sketch, .cube, .cylinder, .sphere, .polyhedron_op, .concrete, .square, .circle, .polygon, .polygons_even_odd => {},
    }
}

/// Pushes a frame for each of `nodes`, the last first, so the first is evaluated first.
fn pushAll(f_stack: *EvaluationFrameStack, nodes: []const dag.DAGNodeIndex) !void {
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        try f_stack.push(nodes[i]);
    }
}

/// Builds `node` from its operands, which are on top of `v_stack` (popped and released
/// here, so they are freed, if owned, on both success and error paths), and pushes the
/// result. Kernel calls never consume their inputs and always return new handles.
fn executeNode(vm: *VM, v_stack: *IntermediateStack, node: dag.DAGNode, config: EngineConfig) !void {
    switch (node.tag) {
        .empty_solid, .cube, .cylinder, .sphere, .polyhedron_op, .concrete, .empty_sketch, .square, .circle, .polygon, .polygons_even_odd => try buildLeaf(vm, v_stack, node, config),
        .union_op, .difference_op, .intersection_op, .minkowski, .translate, .rotate, .scale, .mirror, .transform_matrix, .trim_by_plane, .hull, .set_material => try executeSolidOp(vm, v_stack, node, config),
        .batch_union_op, .batch_hull_op => try executeBatch(vm, v_stack, config, node.tag, vm.dag_builder.getBatchUnionPayload(node).len),
        .extrude, .revolve, .loft => try executeSweep(vm, v_stack, node, config),
        .slice_op, .project_op, .offset, .cs_transform, .cs_union_op, .cs_difference_op, .cs_intersection_op => try executeSketchOp(vm, v_stack, node),
    }
}

/// Pushes a kernel's new solid, or raises its failure.
fn pushSolid(vm: *VM, v_stack: *IntermediateStack, tag: dag.DAGTag, handle: ?geom.GeometryHandle) !void {
    try v_stack.pushOwned(.{ .geometry = handle orelse return kernelFailed(vm, tag) });
}

/// Pushes a kernel's new sketch, or raises its failure.
fn pushSketch(vm: *VM, v_stack: *IntermediateStack, tag: dag.DAGTag, handle: ?geom.CrossSectionHandle) !void {
    try v_stack.pushOwned(.{ .cross_section = handle orelse return kernelFailed(vm, tag) });
}

/// A shape made from its parameters alone: a primitive solid or sketch, or a concrete leaf.
fn buildLeaf(vm: *VM, v_stack: *IntermediateStack, node: dag.DAGNode, config: EngineConfig) !void {
    const b = &vm.dag_builder;
    switch (node.tag) {
        .empty_solid => {
            try vm.requireFeature(config.engine, .empty);
            try pushSolid(vm, v_stack, node.tag, kernel.empty(&config));
        },
        .cube => {
            const p = b.getCubeDimensions(node);
            try pushSolid(vm, v_stack, node.tag, kernel.cube(&config, p.x, p.y, p.z, p.center));
        },
        .cylinder => {
            const p = b.getCylinderPayload(node);
            if (p.r1 != p.r2) try vm.requireFeature(config.engine, .cone);
            try pushSolid(vm, v_stack, node.tag, kernel.cylinder(&config, p.r1, p.r2, p.height, p.center, p.segments));
        },
        .sphere => {
            try vm.requireFeature(config.engine, .sphere);
            const p = b.getSpherePayload(node);
            try pushSolid(vm, v_stack, node.tag, kernel.sphere(&config, p.radius, p.segments));
        },
        .polyhedron_op => {
            const p = b.getPolyhedronPayload(node);
            try pushSolid(vm, v_stack, node.tag, kernel.polyhedron(&config, vm.allocator, p.pts, p.faces));
        },
        .concrete => {
            // Owned by dag_builder.concrete_leaves: borrow it, never cache it. A released
            // leaf is reachable from no live shape, so nothing evaluates it.
            if (node.data >= b.concrete_leaves.items.len) return error.RuntimeError;
            try v_stack.pushBorrowed(.{ .geometry = b.concrete_leaves.items[node.data].handle orelse return error.RuntimeError });
        },
        .empty_sketch => {
            try vm.requireFeature(config.engine, .empty);
            try pushSketch(vm, v_stack, node.tag, kernel.emptySketch(&config));
        },
        .square => {
            const p = b.getSquarePayload(node);
            try pushSketch(vm, v_stack, node.tag, kernel.square(&config, p.x, p.y, p.center));
        },
        .circle => {
            const p = b.getCirclePayload(node);
            try pushSketch(vm, v_stack, node.tag, kernel.circle(&config, p.radius, p.segments));
        },
        .polygon => {
            const pts = try readPoints(vm, b.extra_data.items[node.data], b.extra_data.items[node.data + 1]);
            defer vm.allocator.free(pts);
            try pushSketch(vm, v_stack, node.tag, kernel.polygon(&config, vm.allocator, pts));
        },
        .polygons_even_odd => {
            const contours = try vm.allocator.alloc([][2]f64, b.extra_data.items[node.data]);
            // Empty slots make the deferred free safe after a partial allocation failure.
            @memset(contours, &.{});
            defer {
                for (contours) |c| vm.allocator.free(c);
                vm.allocator.free(contours);
            }
            for (contours, 0..) |*contour, i| {
                const at = node.data + 1 + i * 2;
                contour.* = try readPoints(vm, b.extra_data.items[at], b.extra_data.items[at + 1]);
            }
            try pushSketch(vm, v_stack, node.tag, kernel.polygonsEvenOdd(&config, vm.allocator, contours));
        },
        else => unreachable,
    }
}

/// `count` points of a polygon (x, y each) from the builder's numbers at `start`.
fn readPoints(vm: *VM, start: u32, count: u32) ![][2]f64 {
    const numbers = vm.dag_builder.numbers.items;
    const pts = try vm.allocator.alloc([2]f64, count);
    for (pts, 0..) |*pt, i| pt.* = .{ numbers[start + i * 2], numbers[start + i * 2 + 1] };
    return pts;
}

/// A solid made from solids: a boolean or Minkowski sum of two, or one moved or changed.
fn executeSolidOp(vm: *VM, v_stack: *IntermediateStack, node: dag.DAGNode, config: EngineConfig) !void {
    const b = &vm.dag_builder;
    switch (node.tag) {
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
        .translate, .rotate, .scale, .mirror => {
            const target = v_stack.pop();
            defer v_stack.release(target);
            const solid = try geometryOf(target);
            try vm.requireFeature(solid.engine, .transform);
            const p = b.getTranslatePayload(node); // All share same struct layout
            try pushSolid(vm, v_stack, node.tag, switch (node.tag) {
                .translate => kernel.translate(solid, p.x, p.y, p.z),
                .rotate => kernel.rotate(solid, p.x, p.y, p.z),
                .scale => kernel.scale(solid, p.x, p.y, p.z),
                .mirror => kernel.mirror(solid, p.x, p.y, p.z),
                else => unreachable,
            });
        },
        .transform_matrix => {
            const target = v_stack.pop();
            defer v_stack.release(target);
            const p = b.getTransformPayload(node);
            const solid = try geometryOf(target);
            try vm.requireFeature(solid.engine, .transform);
            try pushSolid(vm, v_stack, node.tag, kernel.transformMatrix(solid, b.numbers.items[p.num_idx..][0..12].*));
        },
        .trim_by_plane => {
            const target = v_stack.pop();
            defer v_stack.release(target);
            const p = b.getTrimByPlanePayload(node);
            const solid = try geometryOf(target);
            try vm.requireFeature(solid.engine, .trim_by_plane);
            try pushSolid(vm, v_stack, node.tag, kernel.trimByPlane(solid, p.nx, p.ny, p.nz, p.offset));
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
            const p = b.getMaterialPayload(node);
            const solid = try geometryOf(target);
            vm.warnUnsupported(solid.engine, .materials);
            try pushSolid(vm, v_stack, node.tag, kernel.setMaterial(solid, p.material_id));
        },
        else => unreachable,
    }
}

/// A solid swept from sketches: extruded, revolved or lofted.
fn executeSweep(vm: *VM, v_stack: *IntermediateStack, node: dag.DAGNode, config: EngineConfig) !void {
    const b = &vm.dag_builder;
    switch (node.tag) {
        .extrude => {
            const target = v_stack.pop();
            defer v_stack.release(target);
            const p = b.getExtrudePayload(node);
            const profile = try crossSectionOf(target);
            try vm.requireFeature(profile.engine, .extrude);
            if (p.twist_degrees != 0) try vm.requireFeature(profile.engine, .extrude_twist);
            if (p.scale_x != 1 or p.scale_y != 1) try vm.requireFeature(profile.engine, .extrude_scale);
            // A copy of the profile at the bottom, the top and each slice between.
            try checkEstimatedVertices(vm, node.tag, &.{ kernel.crossSectionNumVerts(profile), @as(usize, @intCast(@max(p.slices, 0))) + 2 }, config.max_vertices);
            try pushSolid(vm, v_stack, node.tag, kernel.extrude(profile, p.height, p.slices, p.twist_degrees, p.scale_x, p.scale_y));
        },
        .revolve => {
            const target = v_stack.pop();
            defer v_stack.release(target);
            const p = b.getRevolvePayload(node);
            const profile = try crossSectionOf(target);
            try vm.requireFeature(profile.engine, .revolve);
            // A copy of the profile per segment, and one more to close a partial turn.
            try checkEstimatedVertices(vm, node.tag, &.{ kernel.crossSectionNumVerts(profile), @as(usize, @intCast(@max(p.segments, 0))) + 1 }, config.max_vertices);
            try pushSolid(vm, v_stack, node.tag, kernel.revolve(profile, p.segments, p.degrees));
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
            const p = b.getLoftPayload(node);
            try pushSolid(vm, v_stack, node.tag, kernel.loft(config.engine, vm.allocator, base_cs, top_cs, p.height));
        },
        else => unreachable,
    }
}

/// A sketch made from a solid (a slice, a projection) or from sketches.
fn executeSketchOp(vm: *VM, v_stack: *IntermediateStack, node: dag.DAGNode) !void {
    const b = &vm.dag_builder;
    switch (node.tag) {
        .slice_op => {
            const target = v_stack.pop();
            defer v_stack.release(target);
            const p = b.getSlicePayload(node);
            const solid = try geometryOf(target);
            try vm.requireFeature(solid.engine, .slice);
            try pushSketch(vm, v_stack, node.tag, kernel.slice(solid, p.height));
        },
        .project_op => {
            const target = v_stack.pop();
            defer v_stack.release(target);
            const solid = try geometryOf(target);
            try vm.requireFeature(solid.engine, .project);
            try pushSketch(vm, v_stack, node.tag, kernel.project(solid));
        },
        .offset => {
            const target = v_stack.pop();
            defer v_stack.release(target);
            const p = b.getOffsetPayload(node);
            const sketch = try crossSectionOf(target);
            try vm.requireFeature(sketch.engine, .offset);
            try pushSketch(vm, v_stack, node.tag, kernel.offset(sketch, p.delta, p.join_type));
        },
        .cs_transform => {
            const target = v_stack.pop();
            defer v_stack.release(target);
            const p = b.getTransformPayload(node);
            const sketch = try crossSectionOf(target);
            try vm.requireFeature(sketch.engine, .transform);
            try pushSketch(vm, v_stack, node.tag, kernel.crossSectionTransform(sketch, b.numbers.items[p.num_idx..][0..6].*));
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
            try pushSketch(vm, v_stack, node.tag, kernel.crossSectionBoolean(left_handle, right_handle, op));
        },
        else => unreachable,
    }
}

/// Moves the fresh result on top of `v_stack` into its cache, once checked. A borrowed
/// one (a concrete leaf) already has an owner.
fn cacheResult(vm: *VM, v_stack: *IntermediateStack, tag: dag.DAGTag, node_hash: u64, config: EngineConfig) !void {
    const top = &v_stack.handles.items[v_stack.handles.items.len - 1];
    if (!top.owned) return;
    switch (top.value) {
        .geometry => |solid| {
            // Every freshly computed solid is checked here, once: an invalid mesh (e.g. a
            // non-manifold polyhedron) is an error, not an empty export later. A moved
            // solid is its operand's, already checked (isPureTransform). On error the
            // result is still owned, so the evaluator's errdefer destroys it.
            if (!isPureTransform(tag)) {
                if (kernel.problem(solid)) |reason| {
                    return vm.fail(.GeometryError, error_kind.INVALID_RESULT_FMT, .{ dag.scriptName(tag), reason });
                }
                try checkVertexLimit(vm, tag, kernel.numVerts(solid), config.max_vertices, false);
            }
            // Ownership moves to the cache only once the put succeeds.
            try vm.dag_cache.put(vm.allocator, node_hash, solid);
        },
        .cross_section => |sketch| try vm.cs_cache.put(vm.allocator, node_hash, sketch),
        .array => return,
    }
    top.owned = false;
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
