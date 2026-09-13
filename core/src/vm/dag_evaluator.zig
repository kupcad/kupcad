const std = @import("std");
const dag = @import("dag.zig");
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");
const VM = @import("vm.zig").VM;

const MAX_DAG_DEPTH: usize = 256;

fn dumpDAG(vm: *VM, node_idx: dag.DAGNodeIndex, depth: usize) void {
    if (depth > 20) {
        std.debug.print("... [max depth reached]\n", .{});
        return;
    }
    if (node_idx >= vm.dag_builder.nodes.items.len) {
        std.debug.print("[OUT OF BOUNDS: {d}]\n", .{node_idx});
        return;
    }

    const node = vm.dag_builder.nodes.items[node_idx];

    var i: usize = 0;
    while (i < depth) : (i += 1) std.debug.print("  ", .{});

    std.debug.print("Node #{d}: {s}", .{ node_idx, @tagName(node.tag) });

    switch (node.tag) {
        .union_op, .difference_op, .intersection_op, .cs_union_op, .cs_difference_op, .cs_intersection_op, .minkowski => {
            const p = vm.dag_builder.getBinaryPayload(node);
            std.debug.print("\n", .{});
            dumpDAG(vm, p.left, depth + 1);
            dumpDAG(vm, p.right, depth + 1);
        },
        .translate, .rotate, .scale, .mirror, .hull, .trim_by_plane, .set_material => {
            const p = vm.dag_builder.getTranslatePayload(node);
            std.debug.print("\n", .{});
            dumpDAG(vm, p.target, depth + 1);
        },
        .extrude, .revolve => {
            const p = vm.dag_builder.getExtrudePayload(node);
            std.debug.print(" (sweeping 2D target)\n", .{});
            dumpDAG(vm, p.target, depth + 1);
        },
        .loft => {
            const p = vm.dag_builder.getLoftPayload(node);
            std.debug.print(" (height: {d})\n", .{p.height});
            dumpDAG(vm, p.base, depth + 1);
            dumpDAG(vm, p.top, depth + 1);
        },
        .batch_union_op, .batch_hull_op => {
            const targets = vm.dag_builder.getBatchUnionPayload(node);
            std.debug.print(" (batch count: {d})\n", .{targets.len});
            for (targets) |t_idx| {
                dumpDAG(vm, t_idx, depth + 1);
            }
        },
        else => {
            std.debug.print("\n", .{});
        },
    }
}

pub fn evaluateDAG(vm: *VM, node_idx: dag.DAGNodeIndex) anyerror!geom.GeometryHandle {
    return evaluateDAGInternal(vm, node_idx, 0);
}

fn evaluateDAGInternal(vm: *VM, node_idx: dag.DAGNodeIndex, depth: usize) anyerror!geom.GeometryHandle {
    if (depth > MAX_DAG_DEPTH) {
        vm.reportError("Runtime Error: CSG Tree exceeds maximum recursion depth of {d}.\n", .{MAX_DAG_DEPTH});
        return error.RuntimeError;
    }

    if (node_idx >= vm.dag_builder.nodes.items.len) {
        vm.reportError("Runtime Error: DAG Node Index {d} out of bounds.\n", .{node_idx});
        return error.RuntimeError;
    }

    const node = vm.dag_builder.nodes.items[node_idx];
    const config = vm.config_stack.items[vm.config_stack.items.len - 1];
    const engine = config.engine;

    switch (node.tag) {
        .cube => {
            const dims = vm.dag_builder.getCubeDimensions(node);
            return kernel.cube(engine, dims.x, dims.y, dims.z, dims.center) orelse return error.RuntimeError;
        },
        .cylinder => {
            const p = vm.dag_builder.getCylinderPayload(node);
            return kernel.cylinder(engine, p.r1, p.r2, p.height, p.center, p.segments) orelse return error.RuntimeError;
        },
        .sphere => {
            const p = vm.dag_builder.getSpherePayload(node);
            return kernel.sphere(engine, p.radius) orelse return error.RuntimeError;
        },
        .polyhedron_op => {
            const p = vm.dag_builder.getPolyhedronPayload(node);
            return kernel.polyhedron(engine, vm.allocator, p.pts, p.faces) orelse return error.RuntimeError;
        },
        .union_op, .difference_op, .intersection_op => {
            const payload = vm.dag_builder.getBinaryPayload(node);
            const left_handle = try evaluateDAGInternal(vm, payload.left, depth + 1);
            const right_handle = try evaluateDAGInternal(vm, payload.right, depth + 1);

            const op: kernel.BooleanOp = switch (node.tag) {
                .union_op => .union_op,
                .difference_op => .difference_op,
                .intersection_op => .intersection_op,
                else => unreachable,
            };

            const result = kernel.boolean(left_handle, right_handle, op) orelse return error.RuntimeError;
            return maybeSimplify(vm, result);
        },
        .batch_union_op => {
            const targets = vm.dag_builder.getBatchUnionPayload(node);
            if (targets.len == 0) return error.RuntimeError;

            var handles = try vm.allocator.alloc(geom.GeometryHandle, targets.len);
            defer vm.allocator.free(handles);

            for (targets, 0..) |target_idx, i| {
                handles[i] = try evaluateDAGInternal(vm, target_idx, depth + 1);
            }

            const result = kernel.batchBoolean(vm.allocator, handles, .union_op) orelse return error.RuntimeError;
            return maybeSimplify(vm, result);
        },
        .translate => {
            const p = vm.dag_builder.getTranslatePayload(node);
            const target_handle = try evaluateDAGInternal(vm, p.target, depth + 1);
            return kernel.translate(target_handle, p.x, p.y, p.z) orelse return error.RuntimeError;
        },
        .rotate => {
            const p = vm.dag_builder.getRotatePayload(node);
            const target_handle = try evaluateDAGInternal(vm, p.target, depth + 1);
            return kernel.rotate(target_handle, p.x, p.y, p.z) orelse return error.RuntimeError;
        },
        .scale => {
            const p = vm.dag_builder.getScalePayload(node);
            const target_handle = try evaluateDAGInternal(vm, p.target, depth + 1);
            return kernel.scale(target_handle, p.x, p.y, p.z) orelse return error.RuntimeError;
        },
        .mirror => {
            const p = vm.dag_builder.getMirrorPayload(node);
            const target_handle = try evaluateDAGInternal(vm, p.target, depth + 1);
            return kernel.mirror(target_handle, p.x, p.y, p.z) orelse return error.RuntimeError;
        },
        .trim_by_plane => {
            const p = vm.dag_builder.getTrimByPlanePayload(node);
            const target_handle = try evaluateDAGInternal(vm, p.target, depth + 1);
            return kernel.trimByPlane(target_handle, p.nx, p.ny, p.nz, p.offset) orelse return error.RuntimeError;
        },
        .hull => {
            const p = vm.dag_builder.getHullPayload(node);
            const target_handle = try evaluateDAGInternal(vm, p.target, depth + 1);
            const result = kernel.hull(target_handle) orelse return error.RuntimeError;
            return maybeSimplify(vm, result);
        },
        .batch_hull_op => {
            const targets = vm.dag_builder.getBatchUnionPayload(node);
            if (targets.len == 0) return error.RuntimeError;

            var handles = try vm.allocator.alloc(geom.GeometryHandle, targets.len);
            defer vm.allocator.free(handles);

            for (targets, 0..) |target_idx, i| {
                handles[i] = try evaluateDAGInternal(vm, target_idx, depth + 1);
            }

            const result = kernel.batchHull(vm.allocator, handles) orelse return error.RuntimeError;
            return maybeSimplify(vm, result);
        },
        .loft => {
            const p = vm.dag_builder.getLoftPayload(node);
            const base_cs = try evaluateCrossSectionDAGInternal(vm, p.base, depth + 1);
            const top_cs = try evaluateCrossSectionDAGInternal(vm, p.top, depth + 1);
            return kernel.loft(engine, base_cs, top_cs, p.height) orelse return error.RuntimeError;
        },
        .minkowski => {
            const p = vm.dag_builder.getBinaryPayload(node);
            const left_handle = try evaluateDAGInternal(vm, p.left, depth + 1);
            const right_handle = try evaluateDAGInternal(vm, p.right, depth + 1);
            const result = kernel.minkowski(left_handle, right_handle) orelse return error.RuntimeError;
            return maybeSimplify(vm, result);
        },
        .extrude => {
            const p = vm.dag_builder.getExtrudePayload(node);
            const cs = try evaluateCrossSectionDAGInternal(vm, p.target, depth + 1);
            return kernel.extrude(cs, p.height, p.slices, p.twist_degrees, p.scale_x, p.scale_y) orelse return error.RuntimeError;
        },
        .revolve => {
            const p = vm.dag_builder.getRevolvePayload(node);
            const cs = try evaluateCrossSectionDAGInternal(vm, p.target, depth + 1);
            return kernel.revolve(cs, p.segments, p.degrees) orelse return error.RuntimeError;
        },
        .transform_matrix => {
            const p = vm.dag_builder.getTransformPayload(node);
            const target = try evaluateDAGInternal(vm, p.target, depth + 1);
            var mat: [12]f64 = undefined;
            std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 12]);
            return kernel.transformMatrix(target, mat) orelse return error.RuntimeError;
        },
        .set_material => {
            const p = vm.dag_builder.getMaterialPayload(node);
            const target = try evaluateDAGInternal(vm, p.target, depth + 1);
            return kernel.setMaterial(target, p.material_id) orelse return error.RuntimeError;
        },
        else => {
            vm.reportError("Runtime Error: Expected 3D Geometry node in DAG.\n", .{});
            return error.RuntimeError;
        },
    }
}

pub fn evaluateCrossSectionDAG(vm: *VM, node_idx: dag.DAGNodeIndex) anyerror!geom.CrossSectionHandle {
    return evaluateCrossSectionDAGInternal(vm, node_idx, 0);
}

fn evaluateCrossSectionDAGInternal(vm: *VM, node_idx: dag.DAGNodeIndex, depth: usize) anyerror!geom.CrossSectionHandle {
    if (depth > MAX_DAG_DEPTH) {
        vm.reportError("Runtime Error: CSG Tree exceeds maximum recursion depth of {d}.\n", .{MAX_DAG_DEPTH});
        return error.RuntimeError;
    }

    if (node_idx >= vm.dag_builder.nodes.items.len) {
        vm.reportError("Runtime Error: DAG Node Index {d} out of bounds.\n", .{node_idx});
        return error.RuntimeError;
    }

    const node = vm.dag_builder.nodes.items[node_idx];
    const config = vm.config_stack.items[vm.config_stack.items.len - 1];
    const engine = config.engine;

    switch (node.tag) {
        .square => {
            const p = vm.dag_builder.getSquarePayload(node);
            return kernel.square(engine, p.x, p.y, p.center) orelse return error.RuntimeError;
        },
        .circle => {
            const p = vm.dag_builder.getCirclePayload(node);
            return kernel.circle(engine, p.radius, p.segments) orelse return error.RuntimeError;
        },
        .slice_op => {
            const p = vm.dag_builder.getSlicePayload(node);
            const target = try evaluateDAGInternal(vm, p.target, depth + 1);
            return kernel.slice(target, p.height) orelse return error.RuntimeError;
        },
        .project_op => {
            const p = vm.dag_builder.getProjectPayload(node);
            const target = try evaluateDAGInternal(vm, p.target, depth + 1);
            return kernel.project(target) orelse return error.RuntimeError;
        },
        .offset => {
            const p = vm.dag_builder.getOffsetPayload(node);
            const target = try evaluateCrossSectionDAGInternal(vm, p.target, depth + 1);
            return kernel.offset(target, p.delta, p.join_type) orelse return error.RuntimeError;
        },
        .cs_transform => {
            const p = vm.dag_builder.getTransformPayload(node);
            const target = try evaluateCrossSectionDAGInternal(vm, p.target, depth + 1);
            var mat: [6]f64 = undefined;
            std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 6]);
            return kernel.crossSectionTransform(target, mat) orelse return error.RuntimeError;
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
            return kernel.polygon(engine, vm.allocator, pts) orelse return error.RuntimeError;
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

            return kernel.polygonsEvenOdd(engine, vm.allocator, contours) orelse return error.RuntimeError;
        },
        .cs_union_op, .cs_difference_op, .cs_intersection_op => {
            const payload = vm.dag_builder.getBinaryPayload(node);
            const left_handle = try evaluateCrossSectionDAGInternal(vm, payload.left, depth + 1);
            const right_handle = try evaluateCrossSectionDAGInternal(vm, payload.right, depth + 1);
            const op: kernel.BooleanOp = switch (node.tag) {
                .cs_union_op => .union_op,
                .cs_difference_op => .difference_op,
                .cs_intersection_op => .intersection_op,
                else => unreachable,
            };
            return kernel.crossSectionBoolean(left_handle, right_handle, op) orelse return error.RuntimeError;
        },
        else => {
            vm.reportError("Runtime Error: Expected 2D CrossSection node in DAG.\n", .{});
            return error.RuntimeError;
        },
    }
}

inline fn maybeSimplify(vm: *VM, handle: geom.GeometryHandle) geom.GeometryHandle {
    const config = vm.config_stack.items[vm.config_stack.items.len - 1];
    if (handle.engine == .manifold and config.manifold.simplify_coplanar) {
        return kernel.simplify(handle, config.manifold.tolerance);
    }
    return handle;
}
