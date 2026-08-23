const std = @import("std");
const dag = @import("dag.zig");
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");
const VM = @import("vm.zig").VM;

pub fn evaluateDAG(vm: *VM, node_idx: dag.DAGNodeIndex) anyerror!geom.GeometryHandle {
    const node = vm.dag_builder.nodes.items[node_idx];

    switch (node.tag) {
        .cube => {
            const dims = vm.dag_builder.getCubeDimensions(node);
            return kernel.cube(dims.x, dims.y, dims.z, dims.center) orelse return error.RuntimeError;
        },
        .cylinder => {
            const p = vm.dag_builder.getCylinderPayload(node);
            return kernel.cylinder(p.radius, p.height, p.center) orelse return error.RuntimeError;
        },
        .sphere => {
            const p = vm.dag_builder.getSpherePayload(node);
            return kernel.sphere(p.radius) orelse return error.RuntimeError;
        },
        .polyhedron_op => {
            const p = vm.dag_builder.getPolyhedronPayload(node);
            return kernel.polyhedron(vm.allocator, p.pts, p.faces) orelse return error.RuntimeError;
        },
        .union_op, .difference_op, .intersection_op => {
            const payload = vm.dag_builder.getBinaryPayload(node);
            const left_handle = try evaluateDAG(vm, payload.left);
            const right_handle = try evaluateDAG(vm, payload.right);
            // Ensure evaluated handles contain valid C++ pointers
            std.debug.assert(@intFromPtr(left_handle.ptr) != 0);
            std.debug.assert(@intFromPtr(right_handle.ptr) != 0);

            const op: kernel.BooleanOp = switch (node.tag) {
                .union_op => .union_op,
                .difference_op => .difference_op,
                .intersection_op => .intersection_op,
                else => unreachable,
            };
            return kernel.boolean(left_handle, right_handle, op) orelse return error.RuntimeError;
        },
        .translate => {
            const p = vm.dag_builder.getTranslatePayload(node);
            const target_handle = try evaluateDAG(vm, p.target);
            return kernel.translate(target_handle, p.x, p.y, p.z) orelse return error.RuntimeError;
        },
        .rotate => {
            const p = vm.dag_builder.getRotatePayload(node);
            const target_handle = try evaluateDAG(vm, p.target);
            return kernel.rotate(target_handle, p.x, p.y, p.z) orelse return error.RuntimeError;
        },
        .scale => {
            const p = vm.dag_builder.getScalePayload(node);
            const target_handle = try evaluateDAG(vm, p.target);
            return kernel.scale(target_handle, p.x, p.y, p.z) orelse return error.RuntimeError;
        },
        .mirror => {
            const p = vm.dag_builder.getMirrorPayload(node);
            const target_handle = try evaluateDAG(vm, p.target);
            return kernel.mirror(target_handle, p.x, p.y, p.z) orelse return error.RuntimeError;
        },
        .trim_by_plane => {
            const p = vm.dag_builder.getTrimByPlanePayload(node);
            const target_handle = try evaluateDAG(vm, p.target);
            return kernel.trimByPlane(target_handle, p.nx, p.ny, p.nz, p.offset) orelse return error.RuntimeError;
        },
        .hull => {
            const p = vm.dag_builder.getHullPayload(node);
            const target_handle = try evaluateDAG(vm, p.target);
            return kernel.hull(target_handle) orelse return error.RuntimeError;
        },
        .minkowski => {
            const p = vm.dag_builder.getBinaryPayload(node);
            const left_handle = try evaluateDAG(vm, p.left);
            const right_handle = try evaluateDAG(vm, p.right);
            return kernel.minkowski(left_handle, right_handle) orelse return error.RuntimeError;
        },
        .extrude => {
            const p = vm.dag_builder.getExtrudePayload(node);
            const cs = try evaluateCrossSectionDAG(vm, p.target);
            return kernel.extrude(cs, p.height, p.slices, p.twist_degrees, p.scale_x, p.scale_y) orelse return error.RuntimeError;
        },
        .revolve => {
            const p = vm.dag_builder.getRevolvePayload(node);
            const cs = try evaluateCrossSectionDAG(vm, p.target);
            return kernel.revolve(cs, p.segments, p.degrees) orelse return error.RuntimeError;
        },
        .transform_matrix => {
            const p = vm.dag_builder.getTransformPayload(node);
            const target = try evaluateDAG(vm, p.target);
            var mat: [12]f64 = undefined;
            std.mem.copyForwards(f64, &mat, vm.dag_builder.numbers.items[p.num_idx .. p.num_idx + 12]);
            return kernel.transformMatrix(target, mat) orelse return error.RuntimeError;
        },
        else => {
            vm.reportError("Runtime Error: Expected 3D Geometry node in DAG.\n", .{});
            return error.RuntimeError;
        },
    }
}

pub fn evaluateCrossSectionDAG(vm: *VM, node_idx: dag.DAGNodeIndex) anyerror!geom.CrossSectionHandle {
    const node = vm.dag_builder.nodes.items[node_idx];

    switch (node.tag) {
        .square => {
            const p = vm.dag_builder.getSquarePayload(node);
            return kernel.square(p.x, p.y, p.center) orelse return error.RuntimeError;
        },
        .circle => {
            const p = vm.dag_builder.getCirclePayload(node);
            return kernel.circle(p.radius, p.segments) orelse return error.RuntimeError;
        },
        .slice_op => {
            const p = vm.dag_builder.getSlicePayload(node);
            const target = try evaluateDAG(vm, p.target);
            return kernel.slice(target, p.height) orelse return error.RuntimeError;
        },
        .project_op => {
            const p = vm.dag_builder.getProjectPayload(node);
            const target = try evaluateDAG(vm, p.target);
            return kernel.project(target) orelse return error.RuntimeError;
        },
        .offset => {
            const p = vm.dag_builder.getOffsetPayload(node);
            const target = try evaluateCrossSectionDAG(vm, p.target);
            return kernel.offset(target, p.delta, p.join_type) orelse return error.RuntimeError;
        },
        .cs_transform => {
            const p = vm.dag_builder.getTransformPayload(node);
            const target = try evaluateCrossSectionDAG(vm, p.target);
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
            return kernel.polygon(vm.allocator, pts) orelse return error.RuntimeError;
        },
        .cs_union_op, .cs_difference_op, .cs_intersection_op => {
            const payload = vm.dag_builder.getBinaryPayload(node);
            const left_handle = try evaluateCrossSectionDAG(vm, payload.left);
            const right_handle = try evaluateCrossSectionDAG(vm, payload.right);
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
