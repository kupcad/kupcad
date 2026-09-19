const std = @import("std");
const types = @import("types.zig");
const topo_arena = @import("arena.zig");
const geom_arena = @import("../geometry/arena.zig");

pub const NULL_LEAF = std.math.maxInt(u32);

pub const BVHNode = struct {
    min: [3]f64,
    max: [3]f64,
    left: u32, // Index in FlatBVH.nodes. If is_leaf == true, left = @intFromEnum(FaceIndex)
    right: u32, // If is_leaf == true, right = NULL_LEAF
    is_leaf: bool,

    pub inline fn intersectsBox(self: BVHNode, box_min: [3]f64, box_max: [3]f64) bool {
        return (self.min[0] <= box_max[0] and self.max[0] >= box_min[0]) and
            (self.min[1] <= box_max[1] and self.max[1] >= box_min[1]) and
            (self.min[2] <= box_max[2] and self.max[2] >= box_min[2]);
    }
};

pub const FlatBVH = struct {
    nodes: std.ArrayListUnmanaged(BVHNode) = .empty,
    root_index: u32 = NULL_LEAF,

    pub fn deinit(self: *FlatBVH, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }

    /// Constructs a flat BVH tree over a slice of FaceIndex items.
    pub fn build(
        self: *FlatBVH,
        allocator: std.mem.Allocator,
        t_arena: *const topo_arena.TopologyArena,
        g_arena: *const geom_arena.GeometryArena,
        faces: []const types.FaceIndex,
    ) !void {
        self.nodes.clearRetainingCapacity();
        if (faces.len == 0) return;

        var item_list = try allocator.alloc(FaceAABB, faces.len);
        defer allocator.free(item_list);

        for (faces, 0..) |f_idx, i| {
            item_list[i] = computeFaceAABB(t_arena, g_arena, f_idx);
        }

        self.root_index = try self.buildRecursive(allocator, item_list);
    }

    const FaceAABB = struct {
        face: types.FaceIndex,
        min: [3]f64,
        max: [3]f64,
        center: [3]f64,
    };

    fn computeFaceAABB(
        t_arena: *const topo_arena.TopologyArena,
        g_arena: *const geom_arena.GeometryArena,
        f_idx: types.FaceIndex,
    ) FaceAABB {
        var min = [3]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
        var max = [3]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };

        const face = t_arena.faces.items[@intFromEnum(f_idx)];
        for (0..face.loops_len) |l_off| {
            const loop_idx = t_arena.face_loops.items[face.loops_start + l_off];
            const loop = t_arena.loops.items[@intFromEnum(loop_idx)];
            var curr = loop.first_half_edge;

            var safety: usize = 0;
            while (safety < 10_000) : (safety += 1) {
                const he = t_arena.half_edges.items[@intFromEnum(curr)];
                const pt = g_arena.points.items[@intFromEnum(t_arena.vertices.items[@intFromEnum(he.start_vertex)].point)];

                min[0] = @min(min[0], pt[0]);
                min[1] = @min(min[1], pt[1]);
                min[2] = @min(min[2], pt[2]);

                max[0] = @max(max[0], pt[0]);
                max[1] = @max(max[1], pt[1]);
                max[2] = @max(max[2], pt[2]);

                curr = he.next;
                if (curr == loop.first_half_edge) break;
            }
        }

        return .{
            .face = f_idx,
            .min = min,
            .max = max,
            .center = .{
                (min[0] + max[0]) * 0.5,
                (min[1] + max[1]) * 0.5,
                (min[2] + max[2]) * 0.5,
            },
        };
    }

    fn buildRecursive(self: *FlatBVH, allocator: std.mem.Allocator, items: []FaceAABB) !u32 {
        if (items.len == 1) {
            const node_idx = @as(u32, @intCast(self.nodes.items.len));
            try self.nodes.append(allocator, .{
                .min = items[0].min,
                .max = items[0].max,
                .left = @intFromEnum(items[0].face),
                .right = NULL_LEAF,
                .is_leaf = true,
            });
            return node_idx;
        }

        // Calculate enclosing AABB
        var bounds_min = [3]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
        var bounds_max = [3]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };

        for (items) |it| {
            bounds_min[0] = @min(bounds_min[0], it.min[0]);
            bounds_min[1] = @min(bounds_min[1], it.min[1]);
            bounds_min[2] = @min(bounds_min[2], it.min[2]);

            bounds_max[0] = @max(bounds_max[0], it.max[0]);
            bounds_max[1] = @max(bounds_max[1], it.max[1]);
            bounds_max[2] = @max(bounds_max[2], it.max[2]);
        }

        // Split along longest axis
        const dx = bounds_max[0] - bounds_min[0];
        const dy = bounds_max[1] - bounds_min[1];
        const dz = bounds_max[2] - bounds_min[2];

        const axis: usize = if (dx >= dy and dx >= dz) 0 else if (dy >= dz) 1 else 2;

        std.mem.sort(FaceAABB, items, axis, struct {
            ax: usize,
            pub fn lessThan(ax: usize, a: FaceAABB, b: FaceAABB) bool {
                return a.center[ax] < b.center[ax];
            }
        }.lessThan);

        const mid = items.len / 2;
        const node_idx = @as(u32, @intCast(self.nodes.items.len));

        // Placeholder node
        try self.nodes.append(allocator, .{
            .min = bounds_min,
            .max = bounds_max,
            .left = 0,
            .right = 0,
            .is_leaf = false,
        });

        const left_child = try self.buildRecursive(allocator, items[0..mid]);
        const right_child = try self.buildRecursive(allocator, items[mid..]);

        self.nodes.items[node_idx].left = left_child;
        self.nodes.items[node_idx].right = right_child;

        return node_idx;
    }

    /// Queries the BVH for all faces whose bounding boxes overlap with the query box.
    pub fn queryBox(
        self: *const FlatBVH,
        allocator: std.mem.Allocator,
        box_min: [3]f64,
        box_max: [3]f64,
        out_faces: *std.ArrayListUnmanaged(types.FaceIndex),
    ) !void {
        if (self.root_index == NULL_LEAF) return;

        var stack: [128]u32 = undefined;
        var stack_top: usize = 0;

        stack[0] = self.root_index;
        stack_top = 1;

        while (stack_top > 0) {
            stack_top -= 1;
            const node_idx = stack[stack_top];
            const node = self.nodes.items[node_idx];

            if (node.intersectsBox(box_min, box_max)) {
                if (node.is_leaf) {
                    try out_faces.append(allocator, @enumFromInt(node.left));
                } else {
                    if (node.left != NULL_LEAF) {
                        stack[stack_top] = node.left;
                        stack_top += 1;
                    }
                    if (node.right != NULL_LEAF) {
                        stack[stack_top] = node.right;
                        stack_top += 1;
                    }
                }
            }
        }
    }
};
