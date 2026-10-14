const std = @import("std");
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");

pub const DAGNodeIndex = u32;

/// Legacy marker for an ObjGeometry that has no DAG node (raw concrete handle).
/// Never a valid node index: appendNodeWithRollback refuses to grow that far.
pub const CONCRETE_NODE_SENTINEL: DAGNodeIndex = std.math.maxInt(u32);

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
    loft,
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
    /// Leaf wrapping an already-evaluated handle (decompose/simplify results).
    /// `data` indexes `concrete_handles`, which owns the handle.
    concrete,
};

/// The name a script uses for the operation, for error messages ("difference failed: ...").
pub fn scriptName(tag: DAGTag) []const u8 {
    return switch (tag) {
        .cube, .cylinder, .sphere, .translate, .rotate, .scale, .square, .circle, .extrude, .revolve, .mirror, .hull, .loft, .minkowski, .trim_by_plane, .offset, .polygon => @tagName(tag),
        .union_op, .batch_union_op, .cs_union_op => "union",
        .difference_op, .cs_difference_op => "difference",
        .intersection_op, .cs_intersection_op => "intersection",
        .polyhedron_op => "polyhedron",
        .batch_hull_op => "hull",
        .slice_op => "slice",
        .project_op => "project",
        .transform_matrix, .cs_transform => "transform",
        .polygons_even_odd => "polygon",
        .set_material => "material",
        .concrete => "geometry",
    };
}

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
pub const LoftPayload = struct { base: DAGNodeIndex, top: DAGNodeIndex, height: f64 };

pub const DAGBuilder = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayListUnmanaged(DAGNode) = .empty,
    extra_data: std.ArrayListUnmanaged(u32) = .empty,
    numbers: std.ArrayListUnmanaged(f64) = .empty,
    poly_points: std.ArrayListUnmanaged([3]f64) = .empty,
    poly_faces: std.ArrayListUnmanaged([3]u32) = .empty,
    /// Handles owned by `.concrete` leaves. They cannot be recomputed from the DAG,
    /// so they live as long as the builder (not in the evictable dag_cache).
    concrete_handles: std.ArrayListUnmanaged(geom.GeometryHandle) = .empty,

    // CSE Deduplication
    node_hashes: std.ArrayListUnmanaged(u64) = .empty,
    dedup_map: std.AutoHashMapUnmanaged(u64, DAGNodeIndex) = .empty,

    pub fn init(child_allocator: std.mem.Allocator) DAGBuilder {
        return .{ .arena = std.heap.ArenaAllocator.init(child_allocator) };
    }

    pub fn deinit(self: *DAGBuilder) void {
        for (self.concrete_handles.items) |h| kernel.destruct(h);
        self.arena.deinit(); // Instant O(1) bulk free of all DAG memory!
    }

    inline fn allocator(self: *DAGBuilder) std.mem.Allocator {
        return self.arena.allocator();
    }

    // --- Allocation & Rollback Infrastructure ---

    /// Encapsulates initial slice lengths to enable unified OOM rollbacks across all payload buffers.
    const StateSnapshot = struct {
        nodes: usize,
        extra_data: usize,
        numbers: usize,
        poly_points: usize,
        poly_faces: usize,
    };

    inline fn snapshot(self: *const DAGBuilder) StateSnapshot {
        return .{
            .nodes = self.nodes.items.len,
            .extra_data = self.extra_data.items.len,
            .numbers = self.numbers.items.len,
            .poly_points = self.poly_points.items.len,
            .poly_faces = self.poly_faces.items.len,
        };
    }

    inline fn rollback(self: *DAGBuilder, snap: StateSnapshot) void {
        self.nodes.shrinkRetainingCapacity(snap.nodes);
        self.node_hashes.shrinkRetainingCapacity(snap.nodes);
        self.extra_data.shrinkRetainingCapacity(snap.extra_data);
        self.numbers.shrinkRetainingCapacity(snap.numbers);
        self.poly_points.shrinkRetainingCapacity(snap.poly_points);
        self.poly_faces.shrinkRetainingCapacity(snap.poly_faces);
    }

    /// Primary internal entry point to register nodes with common subexpression elimination (CSE)
    fn appendNodeWithRollback(self: *DAGBuilder, new_node: DAGNode, snap: StateSnapshot) !DAGNodeIndex {
        errdefer self.rollback(snap);

        // SAFETY: Prevents the DAG index from reaching CONCRETE_NODE_SENTINEL
        if (self.nodes.items.len >= CONCRETE_NODE_SENTINEL - 1) {
            return error.ExecutionLimitExceeded;
        }

        var hash = try self.computeNodeHash(new_node);
        var probe: u64 = 0;
        while (self.dedup_map.get(hash)) |existing_idx| {
            // A hash hit alone is not proof of identity: verify structurally before reusing.
            if (self.nodesEqual(self.nodes.items[existing_idx], new_node)) {
                // Roll back array mutations if CSE found an existing identical node
                self.rollback(snap);
                return existing_idx;
            }
            // Genuine collision between different nodes. Derive a fresh deterministic
            // hash so the new node gets its own dedup slot AND its own dag_cache key
            // (the evaluator caches handles by node hash).
            probe += 1;
            var rehasher = std.hash.Wyhash.init(probe);
            rehasher.update(std.mem.asBytes(&hash));
            hash = rehasher.final();
        }

        const alloc = self.allocator();
        const node_idx: u32 = @intCast(self.nodes.items.len);

        try self.nodes.append(alloc, new_node);
        try self.node_hashes.append(alloc, hash);
        try self.dedup_map.put(alloc, hash, node_idx);

        return node_idx;
    }

    inline fn appendNumbers(self: *DAGBuilder, slice: []const f64) !u32 {
        const start_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.appendSlice(self.allocator(), slice);
        return start_idx;
    }

    inline fn appendExtraData(self: *DAGBuilder, slice: []const u32) !u32 {
        const start_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(self.allocator(), slice);
        return start_idx;
    }

    // --- Standardized Adder Helpers ---

    /// Helper for unary operations that take only a single target DAGNodeIndex (e.g., hull, project_op)
    inline fn addSingleTargetNode(self: *DAGBuilder, tag: DAGTag, target: DAGNodeIndex) !DAGNodeIndex {
        const snap = self.snapshot();
        const extra_idx = try self.appendExtraData(&.{target});
        return try self.appendNodeWithRollback(.{ .tag = tag, .flags = 0, .data = extra_idx }, snap);
    }

    /// Helper for 3D geometric spatial transforms (translate, rotate, scale, mirror)
    inline fn addNumericTransformNode(self: *DAGBuilder, tag: DAGTag, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ x, y, z });
        const extra_idx = try self.appendExtraData(&.{ target, num_idx });
        return try self.appendNodeWithRollback(.{ .tag = tag, .flags = 0, .data = extra_idx }, snap);
    }

    // --- Public Adders ---

    pub fn addBinary(self: *DAGBuilder, tag: DAGTag, left: DAGNodeIndex, right: DAGNodeIndex) !DAGNodeIndex {
        const snap = self.snapshot();
        const extra_idx = try self.appendExtraData(&.{ left, right });
        return try self.appendNodeWithRollback(.{ .tag = tag, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addBatchUnion(self: *DAGBuilder, targets: []const DAGNodeIndex) !DAGNodeIndex {
        const snap = self.snapshot();
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);

        try self.extra_data.append(alloc, @intCast(targets.len));
        try self.extra_data.appendSlice(alloc, targets);

        return try self.appendNodeWithRollback(.{ .tag = .batch_union_op, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addCube(self: *DAGBuilder, x: f64, y: f64, z: f64, center: bool) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ x, y, z });
        return try self.appendNodeWithRollback(.{ .tag = .cube, .flags = if (center) 1 else 0, .data = num_idx }, snap);
    }

    pub fn addCylinder(self: *DAGBuilder, r1: f64, r2: f64, height: f64, center: bool, segments: i32) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ r1, r2, height, @floatFromInt(segments) });
        return try self.appendNodeWithRollback(.{ .tag = .cylinder, .flags = if (center) 1 else 0, .data = num_idx }, snap);
    }

    pub fn addSphere(self: *DAGBuilder, radius: f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{radius});
        return try self.appendNodeWithRollback(.{ .tag = .sphere, .flags = 0, .data = num_idx }, snap);
    }

    pub fn addSquare(self: *DAGBuilder, x: f64, y: f64, center: bool) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ x, y });
        return try self.appendNodeWithRollback(.{ .tag = .square, .flags = if (center) 1 else 0, .data = num_idx }, snap);
    }

    pub fn addCircle(self: *DAGBuilder, radius: f64, segments: i32) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ radius, @floatFromInt(segments) });
        return try self.appendNodeWithRollback(.{ .tag = .circle, .flags = 0, .data = num_idx }, snap);
    }

    pub fn addPolyhedron(self: *DAGBuilder, pts: []const [3]f64, faces: []const [3]u32) !DAGNodeIndex {
        const snap = self.snapshot();
        const alloc = self.allocator();

        // --- PRECOMPUTE GEOMETRY HASH (O(N) -> O(1) CSE Optimization) ---
        // We hash the raw bytes of the vertices and faces exactly ONCE upon creation.
        // This prevents the CSE engine from re-hashing millions of floats every time this node is evaluated.
        var hasher = std.hash.Wyhash.init(0);
        // Hash the lengths too, otherwise moving bytes between the pts/faces
        // streams (same concatenation) would collide.
        const pts_len: u64 = pts.len;
        const faces_len: u64 = faces.len;
        hasher.update(std.mem.asBytes(&pts_len));
        hasher.update(std.mem.sliceAsBytes(pts));
        hasher.update(std.mem.asBytes(&faces_len));
        hasher.update(std.mem.sliceAsBytes(faces));
        const geom_hash = hasher.final();

        // Split the 64-bit hash into two 32-bit halves to pack seamlessly into the DOD `extra_data` array
        const hash_high: u32 = @truncate(geom_hash >> 32);
        const hash_low: u32 = @truncate(geom_hash);

        const pts_start: u32 = @intCast(self.poly_points.items.len);
        try self.poly_points.appendSlice(alloc, pts);

        const faces_start: u32 = @intCast(self.poly_faces.items.len);
        try self.poly_faces.appendSlice(alloc, faces);

        // Store the two hash halves immediately after the geometry footprint
        const data_offset = try self.appendExtraData(&.{ pts_start, @intCast(pts.len), faces_start, @intCast(faces.len), hash_high, hash_low });
        return try self.appendNodeWithRollback(.{ .tag = .polyhedron_op, .flags = 0, .data = data_offset }, snap);
    }

    pub fn addPolygonsEvenOdd(self: *DAGBuilder, contours: []const []const [2]f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const alloc = self.allocator();
        const data_offset: u32 = @intCast(self.extra_data.items.len);

        try self.extra_data.append(alloc, @intCast(contours.len));

        for (contours) |contour| {
            const pts_start: u32 = @intCast(self.numbers.items.len);
            for (contour) |pt| {
                try self.numbers.append(alloc, pt[0]);
                try self.numbers.append(alloc, pt[1]);
            }
            try self.extra_data.appendSlice(alloc, &.{ pts_start, @intCast(contour.len) });
        }

        return try self.appendNodeWithRollback(.{ .tag = .polygons_even_odd, .flags = 0, .data = data_offset }, snap);
    }

    /// Registers an evaluated handle as a DAG leaf. On success the builder takes
    /// ownership of `handle`; on error the caller still owns it.
    pub fn addConcrete(self: *DAGBuilder, handle: geom.GeometryHandle) !DAGNodeIndex {
        const snap = self.snapshot();
        const slot: u32 = @intCast(self.concrete_handles.items.len);
        try self.concrete_handles.append(self.allocator(), handle);
        errdefer self.concrete_handles.items.len = slot;
        return try self.appendNodeWithRollback(.{ .tag = .concrete, .flags = 0, .data = slot }, snap);
    }

    pub fn addSetMaterial(self: *DAGBuilder, target: DAGNodeIndex, material_id: u32) !DAGNodeIndex {
        const snap = self.snapshot();
        const extra_idx = try self.appendExtraData(&.{ target, material_id });
        return try self.appendNodeWithRollback(.{ .tag = .set_material, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addTranslate(self: *DAGBuilder, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        return self.addNumericTransformNode(.translate, target, x, y, z);
    }
    pub fn addRotate(self: *DAGBuilder, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        return self.addNumericTransformNode(.rotate, target, x, y, z);
    }
    pub fn addScale(self: *DAGBuilder, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        return self.addNumericTransformNode(.scale, target, x, y, z);
    }
    pub fn addMirror(self: *DAGBuilder, target: DAGNodeIndex, nx: f64, ny: f64, nz: f64) !DAGNodeIndex {
        return self.addNumericTransformNode(.mirror, target, nx, ny, nz);
    }

    pub fn addHull(self: *DAGBuilder, target: DAGNodeIndex) !DAGNodeIndex {
        return self.addSingleTargetNode(.hull, target);
    }

    pub fn addBatchHull(self: *DAGBuilder, targets: []const DAGNodeIndex) !DAGNodeIndex {
        const snap = self.snapshot();
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);

        try self.extra_data.append(alloc, @intCast(targets.len));
        try self.extra_data.appendSlice(alloc, targets);

        return try self.appendNodeWithRollback(.{ .tag = .batch_hull_op, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addLoft(self: *DAGBuilder, base: DAGNodeIndex, top: DAGNodeIndex, height: f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{height});
        const extra_idx = try self.appendExtraData(&.{ base, top, num_idx });
        return try self.appendNodeWithRollback(.{ .tag = .loft, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addProject(self: *DAGBuilder, target: DAGNodeIndex) !DAGNodeIndex {
        return self.addSingleTargetNode(.project_op, target);
    }

    pub fn addSlice(self: *DAGBuilder, target: DAGNodeIndex, height: f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{height});
        const extra_idx = try self.appendExtraData(&.{ target, num_idx });
        return try self.appendNodeWithRollback(.{ .tag = .slice_op, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addTrimByPlane(self: *DAGBuilder, target: DAGNodeIndex, nx: f64, ny: f64, nz: f64, offset: f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ nx, ny, nz, offset });
        const extra_idx = try self.appendExtraData(&.{ target, num_idx });
        return try self.appendNodeWithRollback(.{ .tag = .trim_by_plane, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addExtrude(self: *DAGBuilder, target: DAGNodeIndex, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ height, @floatFromInt(slices), twist_degrees, scale_x, scale_y });
        const extra_idx = try self.appendExtraData(&.{ target, num_idx });
        return try self.appendNodeWithRollback(.{ .tag = .extrude, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addOffset(self: *DAGBuilder, target: DAGNodeIndex, delta: f64, join_type: u8) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{delta});
        const extra_idx = try self.appendExtraData(&.{ target, num_idx });
        return try self.appendNodeWithRollback(.{ .tag = .offset, .flags = join_type, .data = extra_idx }, snap);
    }

    pub fn addRevolve(self: *DAGBuilder, target: DAGNodeIndex, segments: i32, degrees: f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ @floatFromInt(segments), degrees });
        const extra_idx = try self.appendExtraData(&.{ target, num_idx });
        return try self.appendNodeWithRollback(.{ .tag = .revolve, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addTransformMatrix(self: *DAGBuilder, target: DAGNodeIndex, mat: [12]f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&mat);
        const extra_idx = try self.appendExtraData(&.{ target, num_idx });
        return try self.appendNodeWithRollback(.{ .tag = .transform_matrix, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addCrossSectionTransform(self: *DAGBuilder, target: DAGNodeIndex, mat: [6]f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&mat);
        const extra_idx = try self.appendExtraData(&.{ target, num_idx });
        return try self.appendNodeWithRollback(.{ .tag = .cs_transform, .flags = 0, .data = extra_idx }, snap);
    }

    pub fn addPolygon(self: *DAGBuilder, pts: [][2]f64) !DAGNodeIndex {
        const snap = self.snapshot();
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);

        for (pts) |pt| {
            try self.numbers.append(alloc, pt[0]);
            try self.numbers.append(alloc, pt[1]);
        }

        const extra_idx = try self.appendExtraData(&.{ num_idx, @intCast(pts.len) });
        return try self.appendNodeWithRollback(.{ .tag = .polygon, .flags = 0, .data = extra_idx }, snap);
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
        return .{
            .x = self.numbers.items[node.data],
            .y = self.numbers.items[node.data + 1],
            .z = self.numbers.items[node.data + 2],
            .center = (node.flags & 1) != 0,
        };
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
        return .{
            .x = self.numbers.items[node.data],
            .y = self.numbers.items[node.data + 1],
            .center = (node.flags & 1) != 0,
        };
    }

    pub inline fn getCirclePayload(self: *const DAGBuilder, node: DAGNode) struct { radius: f64, segments: i32 } {
        return .{
            .radius = self.numbers.items[node.data],
            .segments = @intFromFloat(self.numbers.items[node.data + 1]),
        };
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
        return .{
            .target = self.extra_data.items[node.data],
            .num_idx = self.extra_data.items[node.data + 1],
        };
    }

    pub const getRotatePayload = getTranslatePayload;
    pub const getScalePayload = getTranslatePayload;
    pub const getMirrorPayload = getTranslatePayload;

    pub inline fn getHullPayload(self: *const DAGBuilder, node: DAGNode) struct { target: DAGNodeIndex } {
        return .{ .target = self.extra_data.items[node.data] };
    }

    pub inline fn getLoftPayload(self: *const DAGBuilder, node: DAGNode) LoftPayload {
        return .{
            .base = self.extra_data.items[node.data],
            .top = self.extra_data.items[node.data + 1],
            .height = self.numbers.items[self.extra_data.items[node.data + 2]],
        };
    }

    pub inline fn getOffsetPayload(self: *const DAGBuilder, node: DAGNode) OffsetPayload {
        return .{
            .target = self.extra_data.items[node.data],
            .delta = self.numbers.items[self.extra_data.items[node.data + 1]],
            .join_type = node.flags,
        };
    }

    pub const getProjectPayload = getHullPayload;

    pub inline fn getSlicePayload(self: *const DAGBuilder, node: DAGNode) struct { target: DAGNodeIndex, height: f64 } {
        return .{
            .target = self.extra_data.items[node.data],
            .height = self.numbers.items[self.extra_data.items[node.data + 1]],
        };
    }

    pub inline fn getTrimByPlanePayload(self: *const DAGBuilder, node: DAGNode) PlanePayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];
        return .{
            .target = target,
            .nx = self.numbers.items[num_idx],
            .ny = self.numbers.items[num_idx + 1],
            .nz = self.numbers.items[num_idx + 2],
            .offset = self.numbers.items[num_idx + 3],
        };
    }

    pub inline fn getExtrudePayload(self: *const DAGBuilder, node: DAGNode) ExtrudePayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];

        std.debug.assert(num_idx + 4 < self.numbers.items.len);

        return .{
            .target = target,
            .height = self.numbers.items[num_idx],
            .slices = @intFromFloat(self.numbers.items[num_idx + 1]),
            .twist_degrees = self.numbers.items[num_idx + 2],
            .scale_x = self.numbers.items[num_idx + 3],
            .scale_y = self.numbers.items[num_idx + 4],
        };
    }

    pub inline fn getPolyhedronPayload(self: *const DAGBuilder, node: DAGNode) struct { pts: []const [3]f64, faces: []const [3]u32, geom_hash: u64 } {
        const pts_start = self.extra_data.items[node.data];
        const pts_len = self.extra_data.items[node.data + 1];
        const faces_start = self.extra_data.items[node.data + 2];
        const faces_len = self.extra_data.items[node.data + 3];

        // Reconstruct the cached 64-bit hash from the two 32-bit payloads
        const hash_high: u64 = self.extra_data.items[node.data + 4];
        const hash_low: u64 = self.extra_data.items[node.data + 5];
        const geom_hash = (hash_high << 32) | hash_low;

        return .{
            .pts = self.poly_points.items[pts_start .. pts_start + pts_len],
            .faces = self.poly_faces.items[faces_start .. faces_start + faces_len],
            .geom_hash = geom_hash,
        };
    }

    pub inline fn getRevolvePayload(self: *const DAGBuilder, node: DAGNode) RevolvePayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];
        return .{
            .target = target,
            .segments = @intFromFloat(self.numbers.items[num_idx]),
            .degrees = self.numbers.items[num_idx + 1],
        };
    }

    pub inline fn getMaterialPayload(self: *const DAGBuilder, node: DAGNode) struct { target: DAGNodeIndex, material_id: u32 } {
        return .{
            .target = self.extra_data.items[node.data],
            .material_id = self.extra_data.items[node.data + 1],
        };
    }

    // --- Deterministic Wyhash CSE Node Hashing ---

    /// Hash of an existing child node. Rejects out-of-range indices (e.g. the
    /// CONCRETE_NODE_SENTINEL of a legacy concrete geometry) with a real error,
    /// since an OOB slice index is UB in ReleaseFast.
    inline fn childHash(self: *const DAGBuilder, idx: DAGNodeIndex) !u64 {
        if (idx >= self.node_hashes.items.len) return error.InvalidDAGNode;
        return self.node_hashes.items[idx];
    }

    fn computeNodeHash(self: *const DAGBuilder, node: DAGNode) !u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&node.tag));
        hasher.update(std.mem.asBytes(&node.flags));

        switch (node.tag) {
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
                const num_idx = self.extra_data.items[node.data];
                const pt_count = self.extra_data.items[node.data + 1];
                hasher.update(std.mem.asBytes(&pt_count));
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
                    // Per-contour length: [3 pts][5 pts] must not hash like [4 pts][4 pts].
                    hasher.update(std.mem.asBytes(&pts_len));
                    for (0..pts_len) |pt_idx| {
                        hasher.update(std.mem.asBytes(&self.numbers.items[pts_start + (pt_idx * 2)]));
                        hasher.update(std.mem.asBytes(&self.numbers.items[pts_start + (pt_idx * 2) + 1]));
                    }
                }
            },
            .polyhedron_op => {
                const p = self.getPolyhedronPayload(node);
                // O(1) CSE Hashing: We use the precomputed mesh hash instead of iterating millions of vertices
                hasher.update(std.mem.asBytes(&p.geom_hash));
            },
            .union_op, .difference_op, .intersection_op, .cs_union_op, .cs_difference_op, .cs_intersection_op, .minkowski => {
                const p = self.getBinaryPayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.left))));
                hasher.update(std.mem.asBytes(&(try self.childHash(p.right))));
            },
            .batch_union_op, .batch_hull_op => {
                const targets = self.getBatchUnionPayload(node);
                const count: u64 = targets.len;
                hasher.update(std.mem.asBytes(&count));
                for (targets) |t_idx| {
                    hasher.update(std.mem.asBytes(&(try self.childHash(t_idx))));
                }
            },
            .translate, .rotate, .scale, .mirror => {
                const p = self.getTranslatePayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.target))));
                hasher.update(std.mem.asBytes(&p.x));
                hasher.update(std.mem.asBytes(&p.y));
                hasher.update(std.mem.asBytes(&p.z));
            },
            .extrude => {
                const p = self.getExtrudePayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.target))));
                hasher.update(std.mem.asBytes(&p.height));
                hasher.update(std.mem.asBytes(&p.slices));
                hasher.update(std.mem.asBytes(&p.twist_degrees));
                hasher.update(std.mem.asBytes(&p.scale_x));
                hasher.update(std.mem.asBytes(&p.scale_y));
            },
            .revolve => {
                const p = self.getRevolvePayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.target))));
                hasher.update(std.mem.asBytes(&p.segments));
                hasher.update(std.mem.asBytes(&p.degrees));
            },
            .trim_by_plane => {
                const p = self.getTrimByPlanePayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.target))));
                hasher.update(std.mem.asBytes(&p.nx));
                hasher.update(std.mem.asBytes(&p.ny));
                hasher.update(std.mem.asBytes(&p.nz));
                hasher.update(std.mem.asBytes(&p.offset));
            },
            .offset => {
                const p = self.getOffsetPayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.target))));
                hasher.update(std.mem.asBytes(&p.delta));
                hasher.update(std.mem.asBytes(&p.join_type));
            },
            .loft => {
                const p = self.getLoftPayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.base))));
                hasher.update(std.mem.asBytes(&(try self.childHash(p.top))));
                hasher.update(std.mem.asBytes(&p.height));
            },
            .slice_op => {
                const p = self.getSlicePayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.target))));
                hasher.update(std.mem.asBytes(&p.height));
            },
            .project_op, .hull => {
                const p = self.getProjectPayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.target))));
            },
            .transform_matrix, .cs_transform => {
                const p = self.getTransformPayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.target))));

                const count: u32 = if (node.tag == .transform_matrix) 12 else 6;
                for (0..count) |i| {
                    hasher.update(std.mem.asBytes(&self.numbers.items[p.num_idx + i]));
                }
            },
            .concrete => {
                // Each wrapped handle is unique; its table slot identifies it.
                hasher.update(std.mem.asBytes(&node.data));
            },
            .set_material => {
                const p = self.getMaterialPayload(node);
                hasher.update(std.mem.asBytes(&(try self.childHash(p.target))));
                hasher.update(std.mem.asBytes(&p.material_id));
            },
        }
        return hasher.final();
    }

    // --- Structural Equality (CSE verification) ---

    inline fn numbersEql(self: *const DAGBuilder, a_idx: u32, b_idx: u32, count: u32) bool {
        const a = self.numbers.items[a_idx .. a_idx + count];
        const b = self.numbers.items[b_idx .. b_idx + count];
        // Bitwise, to match the byte-wise hashing (and so NaN payloads compare equal).
        return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
    }

    inline fn extraEql(self: *const DAGBuilder, a_idx: u32, b_idx: u32, count: u32) bool {
        return std.mem.eql(u32, self.extra_data.items[a_idx .. a_idx + count], self.extra_data.items[b_idx .. b_idx + count]);
    }

    /// Compares tag, flags and every side-table payload. Child references are
    /// compared by index: children are themselves deduplicated exactly, so equal
    /// sub-DAGs always share one index.
    fn nodesEqual(self: *const DAGBuilder, a: DAGNode, b: DAGNode) bool {
        if (a.tag != b.tag or a.flags != b.flags) return false;
        const ex = self.extra_data.items;

        return switch (a.tag) {
            .cube => self.numbersEql(a.data, b.data, 3),
            .cylinder => self.numbersEql(a.data, b.data, 4),
            .sphere => self.numbersEql(a.data, b.data, 1),
            .square, .circle => self.numbersEql(a.data, b.data, 2),
            .polygon => blk: {
                const count = ex[a.data + 1];
                if (count != ex[b.data + 1]) break :blk false;
                break :blk self.numbersEql(ex[a.data], ex[b.data], count * 2);
            },
            .polygons_even_odd => blk: {
                const n = ex[a.data];
                if (n != ex[b.data]) break :blk false;
                for (0..n) |i| {
                    const off: u32 = @intCast(1 + i * 2);
                    const len = ex[a.data + off + 1];
                    if (len != ex[b.data + off + 1]) break :blk false;
                    if (!self.numbersEql(ex[a.data + off], ex[b.data + off], len * 2)) break :blk false;
                }
                break :blk true;
            },
            .polyhedron_op => blk: {
                const pa = self.getPolyhedronPayload(a);
                const pb = self.getPolyhedronPayload(b);
                break :blk std.mem.eql(u8, std.mem.sliceAsBytes(pa.pts), std.mem.sliceAsBytes(pb.pts)) and
                    std.mem.eql(u8, std.mem.sliceAsBytes(pa.faces), std.mem.sliceAsBytes(pb.faces));
            },
            .union_op, .difference_op, .intersection_op, .cs_union_op, .cs_difference_op, .cs_intersection_op, .minkowski => self.extraEql(a.data, b.data, 2),
            .batch_union_op, .batch_hull_op => std.mem.eql(DAGNodeIndex, self.getBatchUnionPayload(a), self.getBatchUnionPayload(b)),
            .project_op, .hull => ex[a.data] == ex[b.data],
            .concrete => a.data == b.data,
            .set_material => self.extraEql(a.data, b.data, 2),
            .loft => self.extraEql(a.data, b.data, 2) and self.numbersEql(ex[a.data + 2], ex[b.data + 2], 1),
            // Remaining unary ops: [target, num_idx] in extra_data plus N numbers.
            .translate, .rotate, .scale, .mirror, .transform_matrix, .cs_transform, .extrude, .revolve, .trim_by_plane, .offset, .slice_op => blk: {
                if (ex[a.data] != ex[b.data]) break :blk false;
                const count: u32 = switch (a.tag) {
                    .translate, .rotate, .scale, .mirror => 3,
                    .transform_matrix => 12,
                    .cs_transform => 6,
                    .extrude => 5,
                    .revolve => 2,
                    .trim_by_plane => 4,
                    .offset, .slice_op => 1,
                    else => unreachable,
                };
                break :blk self.numbersEql(ex[a.data + 1], ex[b.data + 1], count);
            },
        };
    }

    // --- Hybrid CSG Tree Balancing ---

    /// Automatically routes a list of target geometries into either a flat Batch node
    /// or a Balanced Binary Tree depending on the operation type.
    pub fn addBalancedChain(self: *DAGBuilder, tag: DAGTag, targets: []const DAGNodeIndex) !DAGNodeIndex {
        if (targets.len == 0) return error.EmptyChain;
        if (targets.len == 1) return targets[0];

        // 1. Homogeneous Chain Flattening (Spatial $O(N \log N)$ acceleration in Manifold)
        // Commutative associative ops are best sent to the C++ kernel as a single array.
        if (tag == .union_op or tag == .batch_union_op) {
            return self.addBatchUnion(targets);
        }
        if (tag == .hull or tag == .batch_hull_op) {
            return self.addBatchHull(targets);
        }

        // 2. Heterogeneous/Non-Batchable Chain Balancing
        // For Differences, Intersections, or 2D ops, we reduce the DAG depth
        // from $O(N)$ to $O(\log N)$ by building a balanced binary tree `(a+b) + (c+d)`.
        // This is critical for interactive memoization (Sliders) so a change in `d`
        // doesn't invalidate `a+b`.
        return self.buildBalancedTree(tag, targets);
    }

    /// Recursively subdivides an array of nodes into a perfectly balanced binary tree.
    fn buildBalancedTree(self: *DAGBuilder, tag: DAGTag, targets: []const DAGNodeIndex) anyerror!DAGNodeIndex {
        if (targets.len == 1) return targets[0];
        if (targets.len == 2) {
            return self.addBinary(tag, targets[0], targets[1]);
        }

        const mid = targets.len / 2;
        const left_subtree = try self.buildBalancedTree(tag, targets[0..mid]);
        const right_subtree = try self.buildBalancedTree(tag, targets[mid..]);

        return self.addBinary(tag, left_subtree, right_subtree);
    }
};
