const std = @import("std");
const dag = @import("dag.zig");
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");
const log_helpers = @import("../log.zig");
const VM = @import("vm.zig").VM;

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

/// Fixed-capacity intermediate value stack replacing recursive C++ object returns
pub const IntermediateStack = struct {
    handles: [4096]ValueHandle = undefined,
    top: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IntermediateStack {
        return .{ .allocator = allocator };
    }

    pub fn push(self: *IntermediateStack, handle: ValueHandle) !void {
        if (self.top >= self.handles.len) return error.EvaluationStackOverflow;
        self.handles[self.top] = handle;
        self.top += 1;
    }

    pub fn pop(self: *IntermediateStack) ValueHandle {
        std.debug.assert(self.top > 0);
        self.top -= 1;
        return self.handles[self.top];
    }

    pub fn destructAll(self: *IntermediateStack) void {
        while (self.top > 0) {
            self.pop().destruct(self.allocator);
        }
    }
};

const EvalState = enum {
    visit,
    execute,
};

pub const EvaluationFrame = struct {
    node_idx: dag.DAGNodeIndex,
    state: EvalState = .visit,
};

pub const EvaluationFrameStack = struct {
    frames: [4096]EvaluationFrame = undefined,
    top: usize = 0,

    pub fn push(self: *EvaluationFrameStack, node_idx: dag.DAGNodeIndex) !void {
        if (self.top >= self.frames.len) return error.EvaluationStackOverflow;
        self.frames[self.top] = .{ .node_idx = node_idx };
        self.top += 1;
    }

    pub fn pop(self: *EvaluationFrameStack) EvaluationFrame {
        std.debug.assert(self.top > 0);
        self.top -= 1;
        return self.frames[self.top];
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

pub fn evaluateDAG(vm: *VM, root_node_idx: dag.DAGNodeIndex) anyerror!geom.GeometryHandle {
    var v_stack = IntermediateStack.init(vm.allocator);
    // errdefer ensures that if any kernel function panics or returns null,
    // all dangling intermediate meshes on the stack are safely destroyed.
    errdefer v_stack.destructAll();

    var f_stack = EvaluationFrameStack{};
    try f_stack.push(root_node_idx);

    const config = vm.config_stack.items[vm.config_stack.items.len - 1];
    const engine = config.engine;

    while (f_stack.top > 0) {
        var frame = &f_stack.frames[f_stack.top - 1];

        if (frame.node_idx >= vm.dag_builder.nodes.items.len) {
            vm.reportError("Runtime Error: DAG Node Index {d} out of bounds.\n", .{frame.node_idx});
            return error.RuntimeError;
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
                else => {}, // Leaf nodes (cube, sphere, square, polygon) have no children to visit
            }
        } else {
            // State == .execute
            _ = f_stack.pop();

            switch (node.tag) {
                // --- Leaf Geometry 3D ---
                .cube => {
                    const p = vm.dag_builder.getCubeDimensions(node);
                    const handle = kernel.cube(engine, p.x, p.y, p.z, p.center) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = handle });
                },
                .cylinder => {
                    const p = vm.dag_builder.getCylinderPayload(node);
                    const handle = kernel.cylinder(engine, p.r1, p.r2, p.height, p.center, p.segments) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = handle });
                },
                .sphere => {
                    const p = vm.dag_builder.getSpherePayload(node);
                    const handle = kernel.sphere(engine, p.radius) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = handle });
                },
                .polyhedron_op => {
                    const p = vm.dag_builder.getPolyhedronPayload(node);
                    const handle = kernel.polyhedron(engine, vm.allocator, p.pts, p.faces) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = handle });
                },

                // --- Binary 3D Ops ---
                .union_op, .difference_op, .intersection_op => {
                    const right_handle = v_stack.pop().geometry;
                    const left_handle = v_stack.pop().geometry;

                    const op: kernel.BooleanOp = switch (node.tag) {
                        .union_op => .union_op,
                        .difference_op => .difference_op,
                        .intersection_op => .intersection_op,
                        else => unreachable,
                    };

                    const result = kernel.boolean(left_handle, right_handle, op) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = maybeSimplify(vm, result) });
                },
                .minkowski => {
                    const right_handle = v_stack.pop().geometry;
                    const left_handle = v_stack.pop().geometry;
                    const result = kernel.minkowski(left_handle, right_handle) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = maybeSimplify(vm, result) });
                },

                // --- Batch 3D Ops ---
                .batch_union_op, .batch_hull_op => {
                    const targets = vm.dag_builder.getBatchUnionPayload(node);
                    if (targets.len == 0) return error.RuntimeError;

                    var handles = try vm.allocator.alloc(geom.GeometryHandle, targets.len);
                    defer vm.allocator.free(handles);

                    // Pop in reverse order to restore original left-to-right hierarchy
                    var i: usize = targets.len;
                    while (i > 0) {
                        i -= 1;
                        handles[i] = v_stack.pop().geometry;
                    }

                    const result = if (node.tag == .batch_union_op)
                        kernel.batchBoolean(vm.allocator, handles, .union_op) orelse return error.RuntimeError
                    else
                        kernel.batchHull(vm.allocator, handles) orelse return error.RuntimeError;

                    try v_stack.push(.{ .geometry = maybeSimplify(vm, result) });
                },

                // --- Unary 3D Transforms ---
                .translate, .rotate, .scale, .mirror => {
                    const target_handle = v_stack.pop().geometry;
                    const p = vm.dag_builder.getTranslatePayload(node); // All share same struct layout

                    const result = switch (node.tag) {
                        .translate => kernel.translate(target_handle, p.x, p.y, p.z),
                        .rotate => kernel.rotate(target_handle, p.x, p.y, p.z),
                        .scale => kernel.scale(target_handle, p.x, p.y, p.z),
                        .mirror => kernel.mirror(target_handle, p.x, p.y, p.z),
                        else => unreachable,
                    };
                    try v_stack.push(.{ .geometry = result orelse return error.RuntimeError });
                },
                .transform_matrix => {
                    const target_handle = v_stack.pop().geometry;
                    const p = vm.dag_builder.getTransformPayload(node);
                    var mat: [12]f64 = undefined;
                    std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 12]);
                    const result = kernel.transformMatrix(target_handle, mat) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },
                .trim_by_plane => {
                    const target_handle = v_stack.pop().geometry;
                    const p = vm.dag_builder.getTrimByPlanePayload(node);
                    const result = kernel.trimByPlane(target_handle, p.nx, p.ny, p.nz, p.offset) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },
                .hull => {
                    const target_handle = v_stack.pop().geometry;
                    const result = kernel.hull(target_handle) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = maybeSimplify(vm, result) });
                },
                .set_material => {
                    const target_handle = v_stack.pop().geometry;
                    const p = vm.dag_builder.getMaterialPayload(node);
                    const result = kernel.setMaterial(target_handle, p.material_id) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },

                // --- 2D to 3D Generation ---
                .extrude => {
                    const target_cs = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getExtrudePayload(node);
                    const result = kernel.extrude(target_cs, p.height, p.slices, p.twist_degrees, p.scale_x, p.scale_y) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },
                .revolve => {
                    const target_cs = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getRevolvePayload(node);
                    const result = kernel.revolve(target_cs, p.segments, p.degrees) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },
                .loft => {
                    const top_cs = v_stack.pop().cross_section;
                    const base_cs = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getLoftPayload(node);
                    const result = kernel.loft(engine, base_cs, top_cs, p.height) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },

                // --- Leaf Cross Sections 2D ---
                .square => {
                    const p = vm.dag_builder.getSquarePayload(node);
                    const handle = kernel.square(engine, p.x, p.y, p.center) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .circle => {
                    const p = vm.dag_builder.getCirclePayload(node);
                    const handle = kernel.circle(engine, p.radius, p.segments) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
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
                    const handle = kernel.polygon(engine, vm.allocator, pts) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .polygons_even_odd => {
                    const num_contours = vm.dag_builder.extra_data.items[node.data];
                    var contours = try vm.allocator.alloc([][2]f64, num_contours);
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
                    const handle = kernel.polygonsEvenOdd(engine, vm.allocator, contours) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },

                // --- 3D to 2D Generation ---
                .slice_op => {
                    const target = v_stack.pop().geometry;
                    const p = vm.dag_builder.getSlicePayload(node);
                    const handle = kernel.slice(target, p.height) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .project_op => {
                    const target = v_stack.pop().geometry;
                    const handle = kernel.project(target) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },

                // --- 2D Ops ---
                .offset => {
                    const target = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getOffsetPayload(node);
                    const handle = kernel.offset(target, p.delta, p.join_type) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .cs_transform => {
                    const target = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getTransformPayload(node);
                    var mat: [6]f64 = undefined;
                    std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 6]);
                    const handle = kernel.crossSectionTransform(target, mat) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .cs_union_op, .cs_difference_op, .cs_intersection_op => {
                    const right_handle = v_stack.pop().cross_section;
                    const left_handle = v_stack.pop().cross_section;
                    const op: kernel.BooleanOp = switch (node.tag) {
                        .cs_union_op => .union_op,
                        .cs_difference_op => .difference_op,
                        .cs_intersection_op => .intersection_op,
                        else => unreachable,
                    };
                    const handle = kernel.crossSectionBoolean(left_handle, right_handle, op) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
            }
        }
    }

    std.debug.assert(v_stack.top == 1);

    // Ensure we are returning exactly a 3D Geometry mesh, not a CrossSection
    const final_val = v_stack.pop();
    if (final_val == .cross_section) {
        final_val.destruct(vm.allocator);
        return error.RuntimeError;
    }

    return final_val.geometry;
}

pub fn evaluateCrossSectionDAG(vm: *VM, root_node_idx: dag.DAGNodeIndex) anyerror!geom.CrossSectionHandle {
    var v_stack = IntermediateStack.init(vm.allocator);
    // errdefer ensures that if any kernel function panics or returns null,
    // all dangling intermediate meshes on the stack are safely destroyed.
    errdefer v_stack.destructAll();

    var f_stack = EvaluationFrameStack{};
    try f_stack.push(root_node_idx);

    const config = vm.config_stack.items[vm.config_stack.items.len - 1];
    const engine = config.engine;

    while (f_stack.top > 0) {
        var frame = &f_stack.frames[f_stack.top - 1];

        if (frame.node_idx >= vm.dag_builder.nodes.items.len) {
            vm.reportError("Runtime Error: DAG Node Index {d} out of bounds.\n", .{frame.node_idx});
            return error.RuntimeError;
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
                else => {}, // Leaf nodes (cube, sphere, square, polygon) have no children to visit
            }
        } else {
            // State == .execute
            _ = f_stack.pop();

            switch (node.tag) {
                // --- Leaf Geometry 3D ---
                .cube => {
                    const p = vm.dag_builder.getCubeDimensions(node);
                    const handle = kernel.cube(engine, p.x, p.y, p.z, p.center) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = handle });
                },
                .cylinder => {
                    const p = vm.dag_builder.getCylinderPayload(node);
                    const handle = kernel.cylinder(engine, p.r1, p.r2, p.height, p.center, p.segments) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = handle });
                },
                .sphere => {
                    const p = vm.dag_builder.getSpherePayload(node);
                    const handle = kernel.sphere(engine, p.radius) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = handle });
                },
                .polyhedron_op => {
                    const p = vm.dag_builder.getPolyhedronPayload(node);
                    const handle = kernel.polyhedron(engine, vm.allocator, p.pts, p.faces) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = handle });
                },

                // --- Binary 3D Ops ---
                .union_op, .difference_op, .intersection_op => {
                    const right_handle = v_stack.pop().geometry;
                    const left_handle = v_stack.pop().geometry;

                    const op: kernel.BooleanOp = switch (node.tag) {
                        .union_op => .union_op,
                        .difference_op => .difference_op,
                        .intersection_op => .intersection_op,
                        else => unreachable,
                    };

                    const result = kernel.boolean(left_handle, right_handle, op) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = maybeSimplify(vm, result) });
                },
                .minkowski => {
                    const right_handle = v_stack.pop().geometry;
                    const left_handle = v_stack.pop().geometry;
                    const result = kernel.minkowski(left_handle, right_handle) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = maybeSimplify(vm, result) });
                },

                // --- Batch 3D Ops ---
                .batch_union_op, .batch_hull_op => {
                    const targets = vm.dag_builder.getBatchUnionPayload(node);
                    if (targets.len == 0) return error.RuntimeError;

                    var handles = try vm.allocator.alloc(geom.GeometryHandle, targets.len);
                    defer vm.allocator.free(handles);

                    // Pop in reverse order to restore original left-to-right hierarchy
                    var i: usize = targets.len;
                    while (i > 0) {
                        i -= 1;
                        handles[i] = v_stack.pop().geometry;
                    }

                    const result = if (node.tag == .batch_union_op)
                        kernel.batchBoolean(vm.allocator, handles, .union_op) orelse return error.RuntimeError
                    else
                        kernel.batchHull(vm.allocator, handles) orelse return error.RuntimeError;

                    try v_stack.push(.{ .geometry = maybeSimplify(vm, result) });
                },

                // --- Unary 3D Transforms ---
                .translate, .rotate, .scale, .mirror => {
                    const target_handle = v_stack.pop().geometry;
                    const p = vm.dag_builder.getTranslatePayload(node); // All share same struct layout

                    const result = switch (node.tag) {
                        .translate => kernel.translate(target_handle, p.x, p.y, p.z),
                        .rotate => kernel.rotate(target_handle, p.x, p.y, p.z),
                        .scale => kernel.scale(target_handle, p.x, p.y, p.z),
                        .mirror => kernel.mirror(target_handle, p.x, p.y, p.z),
                        else => unreachable,
                    };
                    try v_stack.push(.{ .geometry = result orelse return error.RuntimeError });
                },
                .transform_matrix => {
                    const target_handle = v_stack.pop().geometry;
                    const p = vm.dag_builder.getTransformPayload(node);
                    var mat: [12]f64 = undefined;
                    std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 12]);
                    const result = kernel.transformMatrix(target_handle, mat) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },
                .trim_by_plane => {
                    const target_handle = v_stack.pop().geometry;
                    const p = vm.dag_builder.getTrimByPlanePayload(node);
                    const result = kernel.trimByPlane(target_handle, p.nx, p.ny, p.nz, p.offset) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },
                .hull => {
                    const target_handle = v_stack.pop().geometry;
                    const result = kernel.hull(target_handle) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = maybeSimplify(vm, result) });
                },
                .set_material => {
                    const target_handle = v_stack.pop().geometry;
                    const p = vm.dag_builder.getMaterialPayload(node);
                    const result = kernel.setMaterial(target_handle, p.material_id) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },

                // --- 2D to 3D Generation ---
                .extrude => {
                    const target_cs = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getExtrudePayload(node);
                    const result = kernel.extrude(target_cs, p.height, p.slices, p.twist_degrees, p.scale_x, p.scale_y) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },
                .revolve => {
                    const target_cs = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getRevolvePayload(node);
                    const result = kernel.revolve(target_cs, p.segments, p.degrees) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },
                .loft => {
                    const top_cs = v_stack.pop().cross_section;
                    const base_cs = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getLoftPayload(node);
                    const result = kernel.loft(engine, base_cs, top_cs, p.height) orelse return error.RuntimeError;
                    try v_stack.push(.{ .geometry = result });
                },

                // --- Leaf Cross Sections 2D ---
                .square => {
                    const p = vm.dag_builder.getSquarePayload(node);
                    const handle = kernel.square(engine, p.x, p.y, p.center) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .circle => {
                    const p = vm.dag_builder.getCirclePayload(node);
                    const handle = kernel.circle(engine, p.radius, p.segments) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
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
                    const handle = kernel.polygon(engine, vm.allocator, pts) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .polygons_even_odd => {
                    const num_contours = vm.dag_builder.extra_data.items[node.data];
                    var contours = try vm.allocator.alloc([][2]f64, num_contours);
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
                    const handle = kernel.polygonsEvenOdd(engine, vm.allocator, contours) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },

                // --- 3D to 2D Generation ---
                .slice_op => {
                    const target = v_stack.pop().geometry;
                    const p = vm.dag_builder.getSlicePayload(node);
                    const handle = kernel.slice(target, p.height) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .project_op => {
                    const target = v_stack.pop().geometry;
                    const handle = kernel.project(target) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },

                // --- 2D Ops ---
                .offset => {
                    const target = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getOffsetPayload(node);
                    const handle = kernel.offset(target, p.delta, p.join_type) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .cs_transform => {
                    const target = v_stack.pop().cross_section;
                    const p = vm.dag_builder.getTransformPayload(node);
                    var mat: [6]f64 = undefined;
                    std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 6]);
                    const handle = kernel.crossSectionTransform(target, mat) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
                .cs_union_op, .cs_difference_op, .cs_intersection_op => {
                    const right_handle = v_stack.pop().cross_section;
                    const left_handle = v_stack.pop().cross_section;
                    const op: kernel.BooleanOp = switch (node.tag) {
                        .cs_union_op => .union_op,
                        .cs_difference_op => .difference_op,
                        .cs_intersection_op => .intersection_op,
                        else => unreachable,
                    };
                    const handle = kernel.crossSectionBoolean(left_handle, right_handle, op) orelse return error.RuntimeError;
                    try v_stack.push(.{ .cross_section = handle });
                },
            }
        }
    }

    std.debug.assert(v_stack.top == 1);

    // Validate the final result is actually 2D
    const final_val = v_stack.pop();
    if (final_val == .geometry) {
        final_val.destruct(vm.allocator);
        return error.RuntimeError;
    }

    return final_val.cross_section;
}

inline fn maybeSimplify(vm: *VM, handle: geom.GeometryHandle) geom.GeometryHandle {
    const config = vm.config_stack.items[vm.config_stack.items.len - 1];
    if (handle.engine == .manifold and config.manifold.simplify_coplanar) {
        return kernel.simplify(handle, config.manifold.tolerance);
    }
    return handle;
}
