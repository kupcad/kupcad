const std = @import("std");

pub const DAGNodeIndex = u32;

pub const DAGTag = enum(u8) {
    cube,
    cylinder,
    sphere,
    union_op,
    difference_op,
    intersection_op,
    translate,
    rotate,
    scale,
    square,
    circle,
    extrude,
    revolve,
    slice_op,
    project_op,
    mirror,
    hull,
    minkowski,
    trim_by_plane,
    transform_matrix,
    cs_union_op,
    cs_difference_op,
    cs_intersection_op,
    offset,
    cs_transform,
    polygon,
};

/// Exactly 8 bytes for optimal L1 cache line density (8 nodes per 64B line)
pub const DAGNode = struct {
    tag: DAGTag,
    flags: u8 = 0, // e.g., bit 0 = center boolean
    _padding: u16 = 0,
    data: u32 = 0, // Payload index into extra_data or numbers
};

pub const BinaryPayload = struct { left: DAGNodeIndex, right: DAGNodeIndex };
pub const ExtrudePayload = struct { target: DAGNodeIndex, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64 };
pub const RevolvePayload = struct { target: DAGNodeIndex, segments: i32, degrees: f64 };
pub const PlanePayload = struct { target: DAGNodeIndex, nx: f64, ny: f64, nz: f64, offset: f64 };
pub const OffsetPayload = struct { target: DAGNodeIndex, delta: f64, join_type: u8 };
pub const TranslatePayload = struct { target: DAGNodeIndex, x: f64, y: f64, z: f64 };
pub const RotatePayload = struct { target: DAGNodeIndex, x: f64, y: f64, z: f64 };
pub const ScalePayload = struct { target: DAGNodeIndex, x: f64, y: f64, z: f64 };
pub const TransformPayload = struct { target: DAGNodeIndex, num_idx: u32 };

pub const DAGBuilder = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayListUnmanaged(DAGNode) = .empty,
    extra_data: std.ArrayListUnmanaged(u32) = .empty,
    numbers: std.ArrayListUnmanaged(f64) = .empty,

    pub fn init(child_allocator: std.mem.Allocator) DAGBuilder {
        return .{ .arena = std.heap.ArenaAllocator.init(child_allocator) };
    }

    pub fn deinit(self: *DAGBuilder) void {
        self.arena.deinit(); // Instant O(1) bulk free of all DAG memory!
    }

    inline fn allocator(self: *DAGBuilder) std.mem.Allocator {
        return self.arena.allocator();
    }

    // --- Adders ---
    pub fn addBinary(self: *DAGBuilder, tag: DAGTag, left: DAGNodeIndex, right: DAGNodeIndex) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(alloc, left);
        try self.extra_data.append(alloc, right);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = tag, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    pub fn addCube(self: *DAGBuilder, x: f64, y: f64, z: f64, center: bool) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.appendSlice(alloc, &.{ x, y, z });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .cube, .flags = if (center) 1 else 0, .data = num_idx });
        return node_idx;
    }

    pub fn addCylinder(self: *DAGBuilder, radius: f64, height: f64, center: bool) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.appendSlice(alloc, &.{ radius, height });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .cylinder, .flags = if (center) 1 else 0, .data = num_idx });
        return node_idx;
    }

    pub fn addSphere(self: *DAGBuilder, radius: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.append(alloc, radius);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .sphere, .flags = 0, .data = num_idx });
        return node_idx;
    }

    pub fn addSquare(self: *DAGBuilder, x: f64, y: f64, center: bool) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.appendSlice(alloc, &.{ x, y });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .square, .flags = if (center) 1 else 0, .data = num_idx });
        return node_idx;
    }

    pub fn addCircle(self: *DAGBuilder, radius: f64, segments: i32) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.appendSlice(alloc, &.{ radius, @floatFromInt(segments) });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .circle, .flags = 0, .data = num_idx });
        return node_idx;
    }

    pub fn addTransform(self: *DAGBuilder, tag: DAGTag, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &.{ x, y, z });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = tag, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    pub fn addTranslate(self: *DAGBuilder, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        return self.addTransform(.translate, target, x, y, z);
    }
    pub fn addRotate(self: *DAGBuilder, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        return self.addTransform(.rotate, target, x, y, z);
    }
    pub fn addScale(self: *DAGBuilder, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        return self.addTransform(.scale, target, x, y, z);
    }
    pub fn addMirror(self: *DAGBuilder, target: DAGNodeIndex, nx: f64, ny: f64, nz: f64) !DAGNodeIndex {
        return self.addTransform(.mirror, target, nx, ny, nz);
    }

    pub fn addHull(self: *DAGBuilder, target: DAGNodeIndex) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(alloc, target);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .hull, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    pub fn addProject(self: *DAGBuilder, target: DAGNodeIndex) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(alloc, target);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .project_op, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    pub fn addSlice(self: *DAGBuilder, target: DAGNodeIndex, height: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.append(alloc, height);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .slice_op, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    pub fn addTrimByPlane(self: *DAGBuilder, target: DAGNodeIndex, nx: f64, ny: f64, nz: f64, offset: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &.{ nx, ny, nz, offset });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .trim_by_plane, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    pub fn addExtrude(self: *DAGBuilder, target: DAGNodeIndex, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);

        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &.{ height, @as(f64, @floatFromInt(slices)), twist_degrees, scale_x, scale_y });

        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .extrude, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    pub fn addOffset(self: *DAGBuilder, target: DAGNodeIndex, delta: f64, join_type: u8) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.append(alloc, delta);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .offset, .flags = join_type, .data = extra_idx });
        return node_idx;
    }

    pub fn addRevolve(self: *DAGBuilder, target: DAGNodeIndex, segments: i32, degrees: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);

        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &.{ @as(f64, @floatFromInt(segments)), degrees });

        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .revolve, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    pub fn addTransformMatrix(self: *DAGBuilder, target: DAGNodeIndex, mat: [12]f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &mat);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .transform_matrix, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    pub fn addCrossSectionTransform(self: *DAGBuilder, target: DAGNodeIndex, mat: [6]f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &mat);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .cs_transform, .flags = 0, .data = extra_idx });
        return node_idx;
    }

    // --- Unpackers for JIT Materialization ---
    pub inline fn getBinaryPayload(self: *const DAGBuilder, node: DAGNode) BinaryPayload {
        return .{ .left = self.extra_data.items[node.data], .right = self.extra_data.items[node.data + 1] };
    }
    pub inline fn getCubeDimensions(self: *const DAGBuilder, node: DAGNode) struct { x: f64, y: f64, z: f64, center: bool } {
        return .{ .x = self.numbers.items[node.data], .y = self.numbers.items[node.data + 1], .z = self.numbers.items[node.data + 2], .center = (node.flags & 1) != 0 };
    }
    pub inline fn getCylinderPayload(self: *const DAGBuilder, node: DAGNode) struct { radius: f64, height: f64, center: bool } {
        return .{ .radius = self.numbers.items[node.data], .height = self.numbers.items[node.data + 1], .center = (node.flags & 1) != 0 };
    }
    pub inline fn getSpherePayload(self: *const DAGBuilder, node: DAGNode) struct { radius: f64 } {
        return .{ .radius = self.numbers.items[node.data] };
    }
    pub inline fn getSquarePayload(self: *const DAGBuilder, node: DAGNode) struct { x: f64, y: f64, center: bool } {
        return .{ .x = self.numbers.items[node.data], .y = self.numbers.items[node.data + 1], .center = (node.flags & 1) != 0 };
    }
    pub inline fn getCirclePayload(self: *const DAGBuilder, node: DAGNode) struct { radius: f64, segments: i32 } {
        return .{ .radius = self.numbers.items[node.data], .segments = @intFromFloat(self.numbers.items[node.data + 1]) };
    }
    pub inline fn getTranslatePayload(self: *const DAGBuilder, node: DAGNode) TranslatePayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];
        return .{
            .target = target,
            .x = self.numbers.items[num_idx],
            .y = self.numbers.items[num_idx + 1],
            .z = self.numbers.items[num_idx + 2],
        };
    }

    pub inline fn getTransformPayload(self: *const DAGBuilder, node: DAGNode) TransformPayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];
        return .{ .target = target, .num_idx = num_idx };
    }

    pub const getRotatePayload = getTranslatePayload;
    pub const getScalePayload = getTranslatePayload;
    pub const getMirrorPayload = getTranslatePayload;

    pub inline fn getHullPayload(self: *const DAGBuilder, node: DAGNode) struct { target: DAGNodeIndex } {
        return .{ .target = self.extra_data.items[node.data] };
    }
    pub inline fn getOffsetPayload(self: *const DAGBuilder, node: DAGNode) OffsetPayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];
        return .{ .target = target, .delta = self.numbers.items[num_idx], .join_type = node.flags };
    }
    pub const getProjectPayload = getHullPayload;
    pub inline fn getSlicePayload(self: *const DAGBuilder, node: DAGNode) struct { target: DAGNodeIndex, height: f64 } {
        const num_idx = self.extra_data.items[node.data + 1];
        return .{ .target = self.extra_data.items[node.data], .height = self.numbers.items[num_idx] };
    }
    pub inline fn getTrimByPlanePayload(self: *const DAGBuilder, node: DAGNode) PlanePayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];
        return .{ .target = target, .nx = self.numbers.items[num_idx], .ny = self.numbers.items[num_idx + 1], .nz = self.numbers.items[num_idx + 2], .offset = self.numbers.items[num_idx + 3] };
    }

    pub inline fn getExtrudePayload(self: *const DAGBuilder, node: DAGNode) ExtrudePayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];

        // Ensure the numbers payload wasn't truncated
        std.debug.assert(num_idx + 4 < self.numbers.items.len);

        return .{
            .target = target,
            .height = self.numbers.items[num_idx],
            .slices = @as(i32, @intFromFloat(self.numbers.items[num_idx + 1])),
            .twist_degrees = self.numbers.items[num_idx + 2],
            .scale_x = self.numbers.items[num_idx + 3],
            .scale_y = self.numbers.items[num_idx + 4],
        };
    }

    pub inline fn getRevolvePayload(self: *const DAGBuilder, node: DAGNode) RevolvePayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];
        return .{
            .target = target,
            .segments = @as(i32, @intFromFloat(self.numbers.items[num_idx])),
            .degrees = self.numbers.items[num_idx + 1],
        };
    }

    pub fn addPolygon(self: *DAGBuilder, pts: [][2]f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        for (pts) |pt| {
            try self.numbers.append(alloc, pt[0]);
            try self.numbers.append(alloc, pt[1]);
        }
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(alloc, &.{ num_idx, @intCast(pts.len) });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{ .tag = .polygon, .flags = 0, .data = extra_idx });
        return node_idx;
    }
};
