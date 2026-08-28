const std = @import("std");

pub const DAGNodeIndex = u32;

pub const DAGTag = enum(u8) {
    cube,
    cylinder,
    sphere,
    union_op,
    batch_union_op,
    difference_op,
    intersection_op,
    polyhedron_op,
    batch_hull_op,
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
    polygons_even_odd,
    set_material,
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
    poly_points: std.ArrayListUnmanaged([3]f64) = .empty,
    poly_faces: std.ArrayListUnmanaged([3]u32) = .empty,

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

    fn appendNode(self: *DAGBuilder, new_node: DAGNode) !void {
        const alloc = self.allocator();
        try self.nodes.append(alloc, new_node);
    }

    pub fn addBinary(self: *DAGBuilder, tag: DAGTag, left: DAGNodeIndex, right: DAGNodeIndex) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(alloc, left);
        try self.extra_data.append(alloc, right);

        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = tag, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addBatchUnion(self: *DAGBuilder, targets: []const DAGNodeIndex) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);

        // Store length, then the indices
        try self.extra_data.append(alloc, @intCast(targets.len));
        try self.extra_data.appendSlice(alloc, targets);

        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .batch_union_op, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addCube(self: *DAGBuilder, x: f64, y: f64, z: f64, center: bool) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.appendSlice(alloc, &.{ x, y, z });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .cube, .flags = if (center) 1 else 0, .data = num_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addCylinder(self: *DAGBuilder, r1: f64, r2: f64, height: f64, center: bool, segments: i32) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.appendSlice(alloc, &.{ r1, r2, height, @as(f64, @floatFromInt(segments)) });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .cylinder, .flags = if (center) 1 else 0, .data = num_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addSphere(self: *DAGBuilder, radius: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.append(alloc, radius);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .sphere, .flags = 0, .data = num_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addSquare(self: *DAGBuilder, x: f64, y: f64, center: bool) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.appendSlice(alloc, &.{ x, y });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .square, .flags = if (center) 1 else 0, .data = num_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addCircle(self: *DAGBuilder, radius: f64, segments: i32) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.appendSlice(alloc, &.{ radius, @floatFromInt(segments) });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .circle, .flags = 0, .data = num_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addTransform(self: *DAGBuilder, tag: DAGTag, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &.{ x, y, z });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = tag, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addPolyhedron(self: *DAGBuilder, pts: []const [3]f64, faces: []const [3]u32) !DAGNodeIndex {
        const alloc = self.allocator();

        const pts_start = @as(u32, @intCast(self.poly_points.items.len));
        try self.poly_points.appendSlice(alloc, pts);

        const faces_start = @as(u32, @intCast(self.poly_faces.items.len));
        try self.poly_faces.appendSlice(alloc, faces);

        // Store the slice offsets in `extra_data`
        const data_offset = @as(u32, @intCast(self.extra_data.items.len));
        try self.extra_data.append(alloc, pts_start);
        try self.extra_data.append(alloc, @intCast(pts.len));
        try self.extra_data.append(alloc, faces_start);
        try self.extra_data.append(alloc, @intCast(faces.len));

        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .polyhedron_op, .flags = 0, .data = data_offset };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addPolygonsEvenOdd(self: *DAGBuilder, contours: []const []const [2]f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const data_offset = @as(u32, @intCast(self.extra_data.items.len));

        // Store the total number of contours
        try self.extra_data.append(alloc, @intCast(contours.len));

        for (contours) |contour| {
            const pts_start = @as(u32, @intCast(self.numbers.items.len));
            // Flatten [2]f64 into f64
            for (contour) |pt| {
                try self.numbers.append(alloc, pt[0]);
                try self.numbers.append(alloc, pt[1]);
            }
            // Store [start_idx, length] for each contour
            try self.extra_data.append(alloc, pts_start);
            try self.extra_data.append(alloc, @intCast(contour.len));
        }

        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .polygons_even_odd, .flags = 0, .data = data_offset };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addSetMaterial(self: *DAGBuilder, target: DAGNodeIndex, material_id: u32) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, material_id });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .set_material, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

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
        const new_node = DAGNode{ .tag = .hull, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addBatchHull(self: *DAGBuilder, targets: []const DAGNodeIndex) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(alloc, @intCast(targets.len));
        try self.extra_data.appendSlice(alloc, targets);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .batch_hull_op, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addProject(self: *DAGBuilder, target: DAGNodeIndex) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(alloc, target);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .project_op, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addSlice(self: *DAGBuilder, target: DAGNodeIndex, height: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.append(alloc, height);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .slice_op, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addTrimByPlane(self: *DAGBuilder, target: DAGNodeIndex, nx: f64, ny: f64, nz: f64, offset: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &.{ nx, ny, nz, offset });
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .trim_by_plane, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addExtrude(self: *DAGBuilder, target: DAGNodeIndex, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);

        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &.{ height, @as(f64, @floatFromInt(slices)), twist_degrees, scale_x, scale_y });

        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .extrude, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addOffset(self: *DAGBuilder, target: DAGNodeIndex, delta: f64, join_type: u8) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.append(alloc, delta);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .offset, .flags = join_type, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addRevolve(self: *DAGBuilder, target: DAGNodeIndex, segments: i32, degrees: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);

        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &.{ @as(f64, @floatFromInt(segments)), degrees });

        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .revolve, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addTransformMatrix(self: *DAGBuilder, target: DAGNodeIndex, mat: [12]f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &mat);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .transform_matrix, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    pub fn addCrossSectionTransform(self: *DAGBuilder, target: DAGNodeIndex, mat: [6]f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.extra_data.appendSlice(alloc, &.{ target, num_idx });
        try self.numbers.appendSlice(alloc, &mat);
        const node_idx: u32 = @intCast(self.nodes.items.len);
        const new_node = DAGNode{ .tag = .cs_transform, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
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
        const new_node = DAGNode{ .tag = .polygon, .flags = 0, .data = extra_idx };

        try self.appendNode(new_node);

        return node_idx;
    }

    // --- Unpackers for JIT Materialization ---
    pub inline fn getBinaryPayload(self: *const DAGBuilder, node: DAGNode) BinaryPayload {
        return .{ .left = self.extra_data.items[node.data], .right = self.extra_data.items[node.data + 1] };
    }

    pub inline fn getBatchUnionPayload(self: *const DAGBuilder, node: DAGNode) []const DAGNodeIndex {
        const len = self.extra_data.items[node.data];
        const start = node.data + 1;
        return self.extra_data.items[start .. start + len];
    }

    pub inline fn getCubeDimensions(self: *const DAGBuilder, node: DAGNode) struct { x: f64, y: f64, z: f64, center: bool } {
        return .{ .x = self.numbers.items[node.data], .y = self.numbers.items[node.data + 1], .z = self.numbers.items[node.data + 2], .center = (node.flags & 1) != 0 };
    }

    pub inline fn getCylinderPayload(self: *const DAGBuilder, node: DAGNode) struct { r1: f64, r2: f64, height: f64, center: bool, segments: i32 } {
        return .{
            .r1 = self.numbers.items[node.data],
            .r2 = self.numbers.items[node.data + 1],
            .height = self.numbers.items[node.data + 2],
            .center = (node.flags & 1) != 0,
            .segments = @intFromFloat(self.numbers.items[node.data + 3]),
        };
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

    pub inline fn getPolyhedronPayload(self: *const DAGBuilder, node: DAGNode) struct { pts: []const [3]f64, faces: []const [3]u32 } {
        const pts_start = self.extra_data.items[node.data];
        const pts_len = self.extra_data.items[node.data + 1];
        const faces_start = self.extra_data.items[node.data + 2];
        const faces_len = self.extra_data.items[node.data + 3];
        return .{
            .pts = self.poly_points.items[pts_start .. pts_start + pts_len],
            .faces = self.poly_faces.items[faces_start .. faces_start + faces_len],
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

    pub inline fn getMaterialPayload(self: *const DAGBuilder, node: DAGNode) struct { target: DAGNodeIndex, material_id: u32 } {
        return .{
            .target = self.extra_data.items[node.data],
            .material_id = self.extra_data.items[node.data + 1],
        };
    }

    // Add the deterministic hashing engine to the bottom of the file
    fn computeNodeHash(self: *const DAGBuilder, node: DAGNode) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&node.tag));
        hasher.update(std.mem.asBytes(&node.flags));

        switch (node.tag) {
            // --- 3D Primitives ---
            .cube => {
                const p = self.getCubeDimensions(node);
                hasher.update(std.mem.asBytes(&p.x));
                hasher.update(std.mem.asBytes(&p.y));
                hasher.update(std.mem.asBytes(&p.z));
            },
            .cylinder => {
                const p = self.getCylinderPayload(node);
                hasher.update(std.mem.asBytes(&p.r1));
                hasher.update(std.mem.asBytes(&p.r2));
                hasher.update(std.mem.asBytes(&p.height));
                hasher.update(std.mem.asBytes(&p.segments));
            },
            .sphere => {
                const p = self.getSpherePayload(node);
                hasher.update(std.mem.asBytes(&p.radius));
            },
            // --- 2D Primitives ---
            .square => {
                const p = self.getSquarePayload(node);
                hasher.update(std.mem.asBytes(&p.x));
                hasher.update(std.mem.asBytes(&p.y));
            },
            .circle => {
                const p = self.getCirclePayload(node);
                hasher.update(std.mem.asBytes(&p.radius));
                hasher.update(std.mem.asBytes(&p.segments));
            },
            .polygon => {
                // Polygon data is stored in the numbers array
                const num_idx = self.extra_data.items[node.data];
                const pt_count = self.extra_data.items[node.data + 1];
                for (0..pt_count) |i| {
                    hasher.update(std.mem.asBytes(&self.numbers.items[num_idx + (i * 2)]));
                    hasher.update(std.mem.asBytes(&self.numbers.items[num_idx + (i * 2) + 1]));
                }
            },
            .polygons_even_odd => {
                const num_contours = self.extra_data.items[node.data];
                hasher.update(std.mem.asBytes(&num_contours));
                for (0..num_contours) |i| {
                    const pts_start = self.extra_data.items[node.data + 1 + (i * 2)];
                    const pts_len = self.extra_data.items[node.data + 1 + (i * 2) + 1];
                    for (0..pts_len) |pt_idx| {
                        hasher.update(std.mem.asBytes(&self.numbers.items[pts_start + (pt_idx * 2)]));
                        hasher.update(std.mem.asBytes(&self.numbers.items[pts_start + (pt_idx * 2) + 1]));
                    }
                }
            },
            .polyhedron_op => {
                const p = self.getPolyhedronPayload(node);
                for (p.pts) |pt| {
                    hasher.update(std.mem.asBytes(&pt[0]));
                    hasher.update(std.mem.asBytes(&pt[1]));
                    hasher.update(std.mem.asBytes(&pt[2]));
                }
                for (p.faces) |f| {
                    hasher.update(std.mem.asBytes(&f[0]));
                    hasher.update(std.mem.asBytes(&f[1]));
                    hasher.update(std.mem.asBytes(&f[2]));
                }
            },
            // --- Binary & Batch Operations ---
            .union_op, .difference_op, .intersection_op, .cs_union_op, .cs_difference_op, .cs_intersection_op, .minkowski => {
                const p = self.getBinaryPayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.left]));
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.right]));
            },
            .batch_union_op, .batch_hull_op => {
                const targets = self.getBatchUnionPayload(node);
                for (targets) |t_idx| {
                    hasher.update(std.mem.asBytes(&self.node_hashes.items[t_idx]));
                }
            },
            // --- Unary Transforms ---
            .translate, .rotate, .scale, .mirror => {
                const p = self.getTranslatePayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.target]));
                hasher.update(std.mem.asBytes(&p.x));
                hasher.update(std.mem.asBytes(&p.y));
                hasher.update(std.mem.asBytes(&p.z));
            },
            .extrude => {
                const p = self.getExtrudePayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.target]));
                hasher.update(std.mem.asBytes(&p.height));
                hasher.update(std.mem.asBytes(&p.slices));
                hasher.update(std.mem.asBytes(&p.twist_degrees));
                hasher.update(std.mem.asBytes(&p.scale_x));
                hasher.update(std.mem.asBytes(&p.scale_y));
            },
            .revolve => {
                const p = self.getRevolvePayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.target]));
                hasher.update(std.mem.asBytes(&p.segments));
                hasher.update(std.mem.asBytes(&p.degrees));
            },
            .trim_by_plane => {
                const p = self.getTrimByPlanePayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.target]));
                hasher.update(std.mem.asBytes(&p.nx));
                hasher.update(std.mem.asBytes(&p.ny));
                hasher.update(std.mem.asBytes(&p.nz));
                hasher.update(std.mem.asBytes(&p.offset));
            },
            .offset => {
                const p = self.getOffsetPayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.target]));
                hasher.update(std.mem.asBytes(&p.delta));
                hasher.update(std.mem.asBytes(&p.join_type));
            },
            .slice_op => {
                const p = self.getSlicePayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.target]));
                hasher.update(std.mem.asBytes(&p.height));
            },
            .project_op, .hull => {
                const p = self.getProjectPayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.target]));
            },
            .transform_matrix, .cs_transform => {
                const p = self.getTransformPayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.target]));

                const count: u32 = if (node.tag == .transform_matrix) 12 else 6;
                for (0..count) |i| {
                    hasher.update(std.mem.asBytes(&self.numbers.items[p.num_idx + i]));
                }
            },
            .set_material => {
                const p = self.getMaterialPayload(node);
                hasher.update(std.mem.asBytes(&self.node_hashes.items[p.target]));
                hasher.update(std.mem.asBytes(&p.material_id));
            },
        }
        return hasher.final();
    }
};
