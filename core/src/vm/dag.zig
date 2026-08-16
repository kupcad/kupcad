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
};

/// Exactly 8 bytes for optimal L1 cache line density (8 nodes per 64B line)
pub const DAGNode = struct {
    tag: DAGTag,
    flags: u8 = 0, // e.g., bit 0 = center boolean
    _padding: u16 = 0,
    data: u32 = 0, // Payload index into extra_data or numbers
};

pub const BinaryPayload = struct {
    left: DAGNodeIndex,
    right: DAGNodeIndex,
};

pub const TransformPayload = struct {
    target: DAGNodeIndex,
    x: f64,
    y: f64,
    z: f64,
};

pub const DAGBuilder = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayListUnmanaged(DAGNode) = .empty,
    extra_data: std.ArrayListUnmanaged(u32) = .empty,
    numbers: std.ArrayListUnmanaged(f64) = .empty,

    pub fn init(child_allocator: std.mem.Allocator) DAGBuilder {
        return .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
        };
    }

    pub fn deinit(self: *DAGBuilder) void {
        self.arena.deinit(); // Instant O(1) bulk free of all DAG memory!
    }

    inline fn allocator(self: *DAGBuilder) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Appends a binary CSG operation (Union, Difference, Intersection)
    pub fn addBinary(self: *DAGBuilder, tag: DAGTag, left: DAGNodeIndex, right: DAGNodeIndex) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(alloc, left);
        try self.extra_data.append(alloc, right);

        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{
            .tag = tag,
            .flags = 0,
            .data = extra_idx,
        });
        return node_idx;
    }

    /// Appends a Cube primitive
    pub fn addCube(self: *DAGBuilder, x: f64, y: f64, z: f64, center: bool) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.append(alloc, x);
        try self.numbers.append(alloc, y);
        try self.numbers.append(alloc, z);

        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{
            .tag = .cube,
            .flags = if (center) 1 else 0,
            .data = num_idx,
        });
        return node_idx;
    }

    /// Appends a Cylinder primitive
    pub fn addCylinder(self: *DAGBuilder, radius: f64, height: f64, center: bool) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.append(alloc, radius);
        try self.numbers.append(alloc, height);

        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{
            .tag = .cylinder,
            .flags = if (center) 1 else 0,
            .data = num_idx,
        });
        return node_idx;
    }

    /// Appends a Sphere primitive
    pub fn addSphere(self: *DAGBuilder, radius: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.append(alloc, radius);

        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{
            .tag = .sphere,
            .flags = 0,
            .data = num_idx,
        });
        return node_idx;
    }

    /// Appends a Translate transform node
    pub fn addTranslate(self: *DAGBuilder, target: DAGNodeIndex, x: f64, y: f64, z: f64) !DAGNodeIndex {
        const alloc = self.allocator();
        const extra_idx: u32 = @intCast(self.extra_data.items.len);
        const num_idx: u32 = @intCast(self.numbers.items.len);

        try self.extra_data.append(alloc, target);
        try self.extra_data.append(alloc, num_idx);

        try self.numbers.append(alloc, x);
        try self.numbers.append(alloc, y);
        try self.numbers.append(alloc, z);

        const node_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(alloc, .{
            .tag = .translate,
            .flags = 0,
            .data = extra_idx,
        });
        return node_idx;
    }

    // --- Unpackers for JIT Materialization ---
    pub inline fn getBinaryPayload(self: *const DAGBuilder, node: DAGNode) BinaryPayload {
        return .{
            .left = self.extra_data.items[node.data],
            .right = self.extra_data.items[node.data + 1],
        };
    }

    pub inline fn getCubeDimensions(self: *const DAGBuilder, node: DAGNode) struct { x: f64, y: f64, z: f64, center: bool } {
        return .{
            .x = self.numbers.items[node.data],
            .y = self.numbers.items[node.data + 1],
            .z = self.numbers.items[node.data + 2],
            .center = (node.flags & 1) != 0,
        };
    }

    pub inline fn getCylinderPayload(self: *const DAGBuilder, node: DAGNode) struct { radius: f64, height: f64, center: bool } {
        return .{
            .radius = self.numbers.items[node.data],
            .height = self.numbers.items[node.data + 1],
            .center = (node.flags & 1) != 0,
        };
    }

    pub inline fn getSpherePayload(self: *const DAGBuilder, node: DAGNode) struct { radius: f64 } {
        return .{ .radius = self.numbers.items[node.data] };
    }

    pub inline fn getTranslatePayload(self: *const DAGBuilder, node: DAGNode) TransformPayload {
        const target = self.extra_data.items[node.data];
        const num_idx = self.extra_data.items[node.data + 1];
        return .{
            .target = target,
            .x = self.numbers.items[num_idx],
            .y = self.numbers.items[num_idx + 1],
            .z = self.numbers.items[num_idx + 2],
        };
    }
};
