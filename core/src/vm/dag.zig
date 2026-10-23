//! The geometry DAG a script builds: `DAGBuilder` appends `DAGNode`s (primitives, booleans,
//! transforms, extrusions, ...) with their payloads in side tables, reuses an identical node
//! instead of adding it twice, and records the settings each node was made under. The DAG is
//! evaluated later, by `dag_evaluator.zig`.

const std = @import("std");
const rounded_rect = @import("../core/rounded_rect.zig");
const path_mod = @import("../core/path.zig");
const bezier = @import("../core/bezier.zig");
const builtin = @import("builtin");
const kernel = @import("../kernel/kernel.zig");
const dag_verifier = @import("dag_verifier.zig");
const geom = @import("../kernel/geometry_handle.zig");
const EngineConfig = @import("../core/engine_config.zig").EngineConfig;

pub const DAGNodeIndex = u32;

/// Every node is checked as it is added (dag_verifier.zig) where a check costs nothing
/// that matters: Debug and test builds.
const VERIFY_NODES = builtin.mode == .debug or builtin.is_test;

/// A closed path's numbers: its start (x, y), then per segment its end (x, y), whether it
/// is an arc, the arc's centre (x, y) and radius, its way round, its angle and its chords.
pub const PATH_START_NUMBERS = 2;
pub const PATH_SEGMENT_NUMBERS = 9;
/// A polygons node's curve's numbers: its two controls (x, y each).
pub const CURVE_NUMBERS = 4;
/// A polygons node's curve's words in extra_data: its contour, first point and point count.
pub const CURVE_WORDS = 3;

/// A closed path as read from its node (DAGBuilder.readClosedPath).
pub const ClosedPath = struct {
    start: [2]f64,
    segments: []path_mod.Segment,
    chords: []u32,

    pub fn deinit(self: ClosedPath, allocator: std.mem.Allocator) void {
        allocator.free(self.segments);
        allocator.free(self.chords);
    }
};

/// The size of the tables below which the graph is never compacted (DAGBuilder.compact).
const MIN_COMPACTION_BYTES: usize = 1 << 20;

/// Index of a node's settings in DAGBuilder.settings_table; 0 is the default settings.
pub const SettingsId = u16;

/// Legacy marker for an ObjGeometry that has no DAG node (raw concrete handle).
/// Never a valid node index: appendNodeWithRollback refuses to grow that far.
pub const CONCRETE_NODE_SENTINEL: DAGNodeIndex = std.math.maxInt(u32);

pub const DAGTag = enum(u8) {
    /// A shape with nothing in it (no payload): `union([])`, `a.intersection([])`.
    empty_solid,
    empty_sketch,
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
    /// `square(round_r:)`: a rectangle with rounded corners (core/rounded_rect.zig), kept
    /// as such so the 2D exporters know its corners' circles; it was the points.
    rounded_square,
    /// A Path closed into a sketch (`close`): its start and segments (core/path.zig), with
    /// the chords each arc is drawn with, kept so the 2D exporters know its arcs.
    closed_path,
    polygon,
    polygons_even_odd,
    set_material,
    /// A part's name (`named`), for the parts list: the shape is its operand's.
    set_name,
    /// A sketch's material and name (`material`, `named`), for a drawing: the shape is its
    /// operand's (stdlib/bom.zig reads them). Tags of their own, as every sketch node has.
    cs_set_material,
    cs_set_name,
    /// Leaf wrapping an already-evaluated handle (decompose/simplify results).
    /// `data` indexes `concrete_leaves`, which owns the handle.
    concrete,
};

/// The name a script uses for the operation, for error messages ("difference failed: ...").
pub fn scriptName(tag: DAGTag) []const u8 {
    return switch (tag) {
        .cube, .cylinder, .sphere, .translate, .rotate, .scale, .square, .circle, .extrude, .revolve, .mirror, .hull, .loft, .minkowski, .trim_by_plane, .offset, .polygon => @tagName(tag),
        .rounded_square => "square",
        .closed_path => "close",
        .union_op, .batch_union_op, .cs_union_op => "union",
        .difference_op, .cs_difference_op => "difference",
        .intersection_op, .cs_intersection_op => "intersection",
        .polyhedron_op => "polyhedron",
        .batch_hull_op => "hull",
        .slice_op => "slice",
        .project_op => "project",
        .transform_matrix, .cs_transform => "transform",
        .polygons_even_odd => "polygon",
        .set_material, .cs_set_material => "material",
        .set_name, .cs_set_name => "named",
        .empty_solid, .empty_sketch => "empty",
        .concrete => "geometry",
    };
}

/// Where a node's payload lives in the side tables, by tag: the one description of the
/// layouts. The verifier checks every node against it, and a node's operands are found by it.
pub const Layout = union(enum) {
    /// No payload.
    none,
    /// `data` starts this many numbers.
    numbers: u8,
    /// `data` starts this many operands in extra_data.
    operands: u8,
    /// `data` is an operand count in extra_data, the operands after it.
    operand_list,
    /// extra_data at `data`: the operand, then the index of this many numbers.
    target_numbers: u8,
    /// extra_data at `data`: the operand, then a plain value (a material id, a part name's).
    target_value,
    /// extra_data at `data`: the base and top operands, then the index of one number.
    loft,
    /// extra_data at `data`: the index of the points' numbers (x, y each), then their count.
    polygon,
    /// extra_data at `data`: the index of a closed path's numbers (PATH_START_NUMBERS, then
    /// PATH_SEGMENT_NUMBERS per segment), then its segment count.
    path,
    /// extra_data at `data`: the contour count, then a polygon's two words per contour,
    /// then the count of the curves the contours' points were flattened from, the index
    /// of their numbers (CURVE_NUMBERS each) and CURVE_WORDS per curve.
    polygons,
    /// extra_data at `data`: the points' start and count, the faces' start and count, and
    /// the two halves of the mesh's hash.
    polyhedron,
    /// `data` is the node's slot in concrete_leaves.
    concrete,

    /// Whether the payload's parts can be of different lengths from node to node.
    pub fn variesInLength(self: Layout) bool {
        return switch (self) {
            .operand_list, .polygon, .path, .polygons => true,
            else => false,
        };
    }
};

pub fn layoutOf(tag: DAGTag) Layout {
    return switch (tag) {
        .empty_solid, .empty_sketch => .none,
        .cube => .{ .numbers = 3 },
        .cylinder => .{ .numbers = 4 },
        .sphere, .square, .circle => .{ .numbers = 2 },
        .rounded_square => .{ .numbers = 4 },
        .closed_path => .path,
        .union_op, .difference_op, .intersection_op, .minkowski, .cs_union_op, .cs_difference_op, .cs_intersection_op => .{ .operands = 2 },
        .hull, .project_op => .{ .operands = 1 },
        .batch_union_op, .batch_hull_op => .operand_list,
        .translate, .rotate, .scale, .mirror => .{ .target_numbers = 3 },
        .transform_matrix => .{ .target_numbers = 12 },
        .trim_by_plane => .{ .target_numbers = 4 },
        .slice_op => .{ .target_numbers = 1 },
        .offset => .{ .target_numbers = 2 },
        .extrude => .{ .target_numbers = 5 },
        .revolve => .{ .target_numbers = 2 },
        .cs_transform => .{ .target_numbers = 6 },
        .set_material, .set_name, .cs_set_material, .cs_set_name => .target_value,
        .loft => .loft,
        .polygon => .polygon,
        .polygons_even_odd => .polygons,
        .polyhedron_op => .polyhedron,
        .concrete => .concrete,
    };
}

/// Exactly 8 bytes for optimal L1 cache line density (8 nodes per 64B line)
pub const DAGNode = struct {
    tag: DAGTag,
    flags: u8 = 0, // e.g., bit 0 = center boolean
    /// The settings (CAD.config) the node was created under, which it is built with.
    settings: SettingsId = 0,
    data: u32 = 0, // Payload index into extra_data or numbers
};

pub const BinaryPayload = struct { left: DAGNodeIndex, right: DAGNodeIndex };
pub const ExtrudePayload = struct { target: DAGNodeIndex, height: f64, slices: i32, twist_degrees: f64, scale_x: f64, scale_y: f64 };
pub const RevolvePayload = struct { target: DAGNodeIndex, segments: i32, degrees: f64 };
pub const PlanePayload = struct { target: DAGNodeIndex, nx: f64, ny: f64, nz: f64, offset: f64 };
pub const OffsetPayload = struct { target: DAGNodeIndex, delta: f64, join_type: u8, segments: i32 };
pub const TranslatePayload = struct { target: DAGNodeIndex, x: f64, y: f64, z: f64 };
pub const TransformPayload = struct { target: DAGNodeIndex, num_idx: u32 };
pub const LoftPayload = struct { base: DAGNodeIndex, top: DAGNodeIndex, height: f64 };

/// A piece of a node's payload (DAGBuilder.payloadParts).
const PayloadPart = union(enum) {
    operands: []const DAGNodeIndex,
    numbers: []const f64,
    /// A plain value: a count, a material id, a polyhedron's mesh hash.
    value: u64,
    /// Plain words of extra_data: a polygons node's curves' places.
    words: []const u32,
    points: []const [3]f64,
    faces: []const [3]u32,
    /// A concrete leaf's serial.
    serial: u64,
};

/// The parts of one node's payload, in order (see layoutOf).
const PayloadParts = struct {
    b: *const DAGBuilder,
    node: DAGNode,
    layout: Layout,
    step: u32 = 0,

    // Inline: it runs for every node a script builds, a few times each.
    inline fn next(self: *PayloadParts) ?PayloadPart {
        defer self.step += 1;
        const b = self.b;
        const extra = b.extra_data.items;
        const at = self.node.data;
        const step = self.step;
        return switch (self.layout) {
            .none => null,
            .numbers => |n| if (step == 0) .{ .numbers = b.numbers.items[at..][0..n] } else null,
            .operands => |n| if (step == 0) .{ .operands = extra[at..][0..n] } else null,
            .operand_list => if (step == 0) .{ .operands = extra[at + 1 ..][0..extra[at]] } else null,
            .target_numbers => |n| switch (step) {
                0 => .{ .operands = extra[at..][0..1] },
                1 => .{ .numbers = b.numbers.items[extra[at + 1]..][0..n] },
                else => null,
            },
            .target_value => switch (step) {
                0 => .{ .operands = extra[at..][0..1] },
                1 => .{ .value = extra[at + 1] },
                else => null,
            },
            .loft => switch (step) {
                0 => .{ .operands = extra[at..][0..2] },
                1 => .{ .numbers = b.numbers.items[extra[at + 2]..][0..1] },
                else => null,
            },
            .polygon => if (step == 0) .{ .numbers = b.numbers.items[extra[at]..][0 .. 2 * extra[at + 1]] } else null,
            .path => if (step == 0) .{ .numbers = b.numbers.items[extra[at]..][0 .. PATH_START_NUMBERS + PATH_SEGMENT_NUMBERS * extra[at + 1]] } else null,
            .polygons => if (step == 0)
                .{ .value = extra[at] }
            else if (step <= extra[at])
                .{ .numbers = b.numbers.items[extra[at + 2 * step - 1]..][0 .. 2 * extra[at + 2 * step]] }
            else switch (step - extra[at]) {
                1 => .{ .value = b.polygonsCurveCount(at) },
                2 => .{ .numbers = b.numbers.items[extra[b.polygonsCurvesAt(at) + 1]..][0 .. CURVE_NUMBERS * b.polygonsCurveCount(at)] },
                3 => .{ .words = extra[b.polygonsCurvesAt(at) + 2 ..][0 .. CURVE_WORDS * b.polygonsCurveCount(at)] },
                else => null,
            },
            .polyhedron => switch (step) {
                0 => .{ .value = (@as(u64, extra[at + 4]) << 32) | extra[at + 5] },
                1 => .{ .points = b.poly_points.items[extra[at]..][0..extra[at + 1]] },
                2 => .{ .faces = b.poly_faces.items[extra[at + 2]..][0..extra[at + 3]] },
                else => null,
            },
            .concrete => if (step == 0) .{ .serial = b.concrete_leaves.items[at].serial } else null,
        };
    }
};

/// A `.concrete` node's mesh, and the serial its hash is made from.
pub const ConcreteLeaf = struct {
    /// Null once released: no live shape was made from the node any more.
    handle: ?geom.GeometryHandle,
    serial: u64,
};

pub const DAGBuilder = struct {
    /// The tables below grow as the script builds geometry; they were in an arena, which
    /// keeps every outgrown buffer until the end, so a DAG held about twice its size.
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(DAGNode) = .empty,
    extra_data: std.ArrayList(u32) = .empty,
    numbers: std.ArrayList(f64) = .empty,
    poly_points: std.ArrayList([3]f64) = .empty,
    poly_faces: std.ArrayList([3]u32) = .empty,
    /// The meshes of `.concrete` nodes. They cannot be recomputed from the DAG, so they
    /// aren't in the evictable dag_cache: one lives until no live shape is made from its
    /// node (releaseUnreachableLeaves).
    concrete_leaves: std.ArrayList(ConcreteLeaf) = .empty,
    /// The serial the next concrete leaf gets.
    next_leaf_serial: u64 = 0,
    /// How many concrete leaves still hold their mesh.
    held_leaves: usize = 0,

    // CSE Deduplication
    node_hashes: std.ArrayList(u64) = .empty,
    dedup_map: std.AutoHashMapUnmanaged(u64, DAGNodeIndex) = .empty,

    /// Every distinct non-default settings nodes were created under (SettingsId n is entry
    /// n - 1). Geometry is evaluated lazily, so a node made inside CAD.with_config must
    /// carry its settings: it used to be built with whatever was active when evaluated.
    settings_table: std.ArrayList(EngineConfig) = .empty,
    /// The settings new nodes get; the VM sets it whenever its config changes.
    current_settings: SettingsId = 0,

    /// The names `named` gives parts, each once: a set_name node holds its index. Owned,
    /// and kept through compactions, as the settings are.
    part_names: std.ArrayList([]u8) = .empty,
    part_name_ids: std.StringHashMapUnmanaged(u32) = .empty,

    /// The size of the tables (tableBytes) at which `wantsCompaction`: twice what the last
    /// compaction kept, and never below `compaction_floor`.
    compact_at: usize = MIN_COMPACTION_BYTES,
    compaction_floor: usize = MIN_COMPACTION_BYTES,

    pub fn init(gpa: std.mem.Allocator) DAGBuilder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DAGBuilder) void {
        for (self.concrete_leaves.items) |leaf| if (leaf.handle) |h| kernel.destruct(h);
        self.freeTables();
        self.settings_table.deinit(self.gpa);
        for (self.part_names.items) |name| self.gpa.free(name);
        self.part_names.deinit(self.gpa);
        self.part_name_ids.deinit(self.gpa);
    }

    /// Frees the node tables, not the meshes their leaves hold.
    fn freeTables(self: *DAGBuilder) void {
        self.nodes.deinit(self.gpa);
        self.extra_data.deinit(self.gpa);
        self.numbers.deinit(self.gpa);
        self.poly_points.deinit(self.gpa);
        self.poly_faces.deinit(self.gpa);
        self.concrete_leaves.deinit(self.gpa);
        self.node_hashes.deinit(self.gpa);
        self.dedup_map.deinit(self.gpa);
    }

    inline fn allocator(self: *DAGBuilder) std.mem.Allocator {
        return self.gpa;
    }

    // --- Settings ---

    /// The id of `config`, added to the table if it is new.
    pub fn internSettings(self: *DAGBuilder, config: EngineConfig) !SettingsId {
        if (std.meta.eql(config, EngineConfig{})) return 0;
        for (self.settings_table.items, 1..) |known, id| {
            if (std.meta.eql(known, config)) return @intCast(id);
        }
        if (self.settings_table.items.len == std.math.maxInt(SettingsId)) return error.TooManySettings;
        try self.settings_table.append(self.allocator(), config);
        return @intCast(self.settings_table.items.len);
    }

    pub fn settings(self: *const DAGBuilder, id: SettingsId) EngineConfig {
        return if (id == 0) .{} else self.settings_table.items[id - 1];
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
    fn appendNodeWithRollback(self: *DAGBuilder, node: DAGNode, snap: StateSnapshot) !DAGNodeIndex {
        errdefer self.rollback(snap);
        var new_node = node;
        new_node.settings = self.current_settings;

        // SAFETY: Prevents the DAG index from reaching CONCRETE_NODE_SENTINEL
        if (self.nodes.items.len >= CONCRETE_NODE_SENTINEL - 1) {
            return error.ExecutionLimitExceeded;
        }

        // Rejects an operand that is no node, in every build (childHash).
        var hash = try self.computeNodeHash(new_node);
        // Anything else malformed is a bug in the native that built the node: stop there,
        // with its trace, where checking is cheap enough.
        if (VERIFY_NODES) if (dag_verifier.problem(self, new_node)) |why| {
            std.debug.panic("DAG builder bug: a {s} node is malformed: {s}", .{ @tagName(new_node.tag), why });
        };
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

    /// The empty Solid (`is_3d`) or Sketch.
    pub fn addEmpty(self: *DAGBuilder, is_3d: bool) !DAGNodeIndex {
        const snap = self.snapshot();
        return try self.appendNodeWithRollback(.{ .tag = if (is_3d) .empty_solid else .empty_sketch, .flags = 0, .data = 0 }, snap);
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

    pub fn addSphere(self: *DAGBuilder, radius: f64, segments: i32) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ radius, @floatFromInt(segments) });
        return try self.appendNodeWithRollback(.{ .tag = .sphere, .flags = 0, .data = num_idx }, snap);
    }

    pub fn addSquare(self: *DAGBuilder, x: f64, y: f64, center: bool) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ x, y });
        return try self.appendNodeWithRollback(.{ .tag = .square, .flags = if (center) 1 else 0, .data = num_idx }, snap);
    }

    /// A rectangle with rounded corners (rounded_rect.RoundedRect: `radius` as given,
    /// `segments` a full circle's share, resolved).
    pub fn addRoundedSquare(self: *DAGBuilder, rect: rounded_rect.RoundedRect) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ rect.x, rect.y, rect.radius, @floatFromInt(rect.segments) });
        return try self.appendNodeWithRollback(.{ .tag = .rounded_square, .flags = if (rect.center) 1 else 0, .data = num_idx }, snap);
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

    /// The sketch of `contours` filled by the even-odd rule, with `curves` the curves runs
    /// of their points were flattened from (a text's glyphs'), for a drawing to write
    /// exactly; each must name points its contour has.
    pub fn addPolygonsEvenOdd(self: *DAGBuilder, contours: []const []const [2]f64, curves: []const bezier.Flattened) !DAGNodeIndex {
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

        try self.extra_data.appendSlice(alloc, &.{ @intCast(curves.len), @intCast(self.numbers.items.len) });
        for (curves) |curve| {
            std.debug.assert(curve.contour < contours.len and curve.count >= 2 and curve.first + curve.count <= contours[curve.contour].len);
            try self.numbers.appendSlice(alloc, &.{ curve.cubic.c1[0], curve.cubic.c1[1], curve.cubic.c2[0], curve.cubic.c2[1] });
            try self.extra_data.appendSlice(alloc, &.{ curve.contour, curve.first, curve.count });
        }

        return try self.appendNodeWithRollback(.{ .tag = .polygons_even_odd, .flags = 0, .data = data_offset }, snap);
    }

    /// Where a polygons node's curves start in extra_data (their count), the node's
    /// payload at `at`.
    pub fn polygonsCurvesAt(self: *const DAGBuilder, at: u32) u32 {
        return at + 1 + 2 * self.extra_data.items[at];
    }

    pub fn polygonsCurveCount(self: *const DAGBuilder, at: u32) u32 {
        return self.extra_data.items[self.polygonsCurvesAt(at)];
    }

    /// A polygons node's contours and curves, read from its payload.
    pub const PolygonsPayload = struct {
        b: *const DAGBuilder,
        at: u32,

        pub fn contourCount(self: PolygonsPayload) u32 {
            return self.b.extra_data.items[self.at];
        }

        /// Contour `i`'s points.
        pub fn contour(self: PolygonsPayload, i: u32) []const [2]f64 {
            const extra = self.b.extra_data.items;
            const flat = self.b.numbers.items[extra[self.at + 1 + 2 * i]..][0 .. 2 * extra[self.at + 2 + 2 * i]];
            return @as([*]const [2]f64, @ptrCast(flat.ptr))[0..extra[self.at + 2 + 2 * i]];
        }

        pub fn curveCount(self: PolygonsPayload) u32 {
            return self.b.polygonsCurveCount(self.at);
        }

        /// Curve `i`: which of a contour's points it became, and its controls.
        pub fn curve(self: PolygonsPayload, i: u32) bezier.Flattened {
            const extra = self.b.extra_data.items;
            const curves_at = self.b.polygonsCurvesAt(self.at);
            const words = extra[curves_at + 2 + CURVE_WORDS * i ..][0..CURVE_WORDS];
            const n = self.b.numbers.items[extra[curves_at + 1] + CURVE_NUMBERS * i ..][0..CURVE_NUMBERS];
            return .{ .contour = words[0], .first = words[1], .count = words[2], .cubic = .{ .c1 = .{ n[0], n[1] }, .c2 = .{ n[2], n[3] } } };
        }
    };

    pub fn getPolygonsPayload(self: *const DAGBuilder, node: DAGNode) PolygonsPayload {
        return .{ .b = self, .at = node.data };
    }

    /// Registers an evaluated handle as a DAG leaf. On success the builder takes
    /// ownership of `handle`; on error the caller still owns it.
    pub fn addConcrete(self: *DAGBuilder, handle: geom.GeometryHandle) !DAGNodeIndex {
        const snap = self.snapshot();
        const slot: u32 = @intCast(self.concrete_leaves.items.len);
        try self.concrete_leaves.append(self.allocator(), .{ .handle = handle, .serial = self.next_leaf_serial });
        errdefer self.concrete_leaves.items.len = slot;
        const idx = try self.appendNodeWithRollback(.{ .tag = .concrete, .flags = 0, .data = slot }, snap);
        self.next_leaf_serial += 1;
        self.held_leaves += 1;
        return idx;
    }

    /// The solid `target` with material `material_id` (the VM's).
    pub fn addSetMaterial(self: *DAGBuilder, target: DAGNodeIndex, material_id: u32) !DAGNodeIndex {
        return self.addLabel(.set_material, target, material_id);
    }

    /// The solid `target` named `name_id` (internPartName).
    pub fn addSetName(self: *DAGBuilder, target: DAGNodeIndex, name_id: u32) !DAGNodeIndex {
        return self.addLabel(.set_name, target, name_id);
    }

    /// The sketch `target` with material `material_id` (the VM's).
    pub fn addSketchMaterial(self: *DAGBuilder, target: DAGNodeIndex, material_id: u32) !DAGNodeIndex {
        return self.addLabel(.cs_set_material, target, material_id);
    }

    /// The sketch `target` named `name_id` (internPartName).
    pub fn addSketchName(self: *DAGBuilder, target: DAGNodeIndex, name_id: u32) !DAGNodeIndex {
        return self.addLabel(.cs_set_name, target, name_id);
    }

    /// A name or material node (`target_value` layout) of `tag` on `target`.
    fn addLabel(self: *DAGBuilder, tag: DAGTag, target: DAGNodeIndex, id: u32) !DAGNodeIndex {
        const snap = self.snapshot();
        const extra_idx = try self.appendExtraData(&.{ target, id });
        return try self.appendNodeWithRollback(.{ .tag = tag, .flags = 0, .data = extra_idx }, snap);
    }

    /// The id of the part name `name`, the same for the same text.
    pub fn internPartName(self: *DAGBuilder, name: []const u8) !u32 {
        if (self.part_name_ids.get(name)) |id| return id;
        const copy = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(copy);
        const id: u32 = @intCast(self.part_names.items.len);
        try self.part_names.append(self.gpa, copy);
        errdefer _ = self.part_names.pop();
        try self.part_name_ids.put(self.gpa, copy, id);
        return id;
    }

    pub fn partName(self: *const DAGBuilder, id: u32) []const u8 {
        return self.part_names.items[id];
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

    /// `target` projected onto XY under the settings `target` was made under, not the
    /// ones in force: a drawing of a Solid made under its own (CAD.with_config) measures
    /// it as it was made.
    pub fn addProjectAsMade(self: *DAGBuilder, target: DAGNodeIndex) !DAGNodeIndex {
        const in_force = self.current_settings;
        defer self.current_settings = in_force;
        self.current_settings = self.nodes.items[target].settings;
        return self.addProject(target);
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

    /// `segments`: how many a full circle of round joins gets.
    pub fn addOffset(self: *DAGBuilder, target: DAGNodeIndex, delta: f64, join_type: u8, segments: i32) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx = try self.appendNumbers(&.{ delta, @floatFromInt(segments) });
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

    /// A Path closed into a sketch: `start`, then each segment with the chords it is drawn
    /// with (`chords[i]`, 0 for a line), as numbers.
    pub fn addClosedPath(self: *DAGBuilder, start: [2]f64, segments: []const path_mod.Segment, chords: []const u32) !DAGNodeIndex {
        const snap = self.snapshot();
        const num_idx: u32 = @intCast(self.numbers.items.len);
        try self.numbers.append(self.allocator(), start[0]);
        try self.numbers.append(self.allocator(), start[1]);
        for (segments, chords) |segment, count| {
            const arc = segment.arc orelse path_mod.Arc{ .center = .{ 0, 0 }, .radius = 0 };
            try self.numbers.appendSlice(self.allocator(), &.{ segment.to[0], segment.to[1], @floatFromInt(@intFromBool(segment.arc != null)), arc.center[0], arc.center[1], arc.radius, @floatFromInt(@intFromBool(segment.ccw)), segment.angle, @floatFromInt(count) });
        }
        const extra_idx = try self.appendExtraData(&.{ num_idx, @intCast(segments.len) });
        return try self.appendNodeWithRollback(.{ .tag = .closed_path, .flags = 0, .data = extra_idx }, snap);
    }

    /// A closed path's start, segments and chords, read back from its node; owned by
    /// `allocator` (ClosedPath.deinit).
    pub fn readClosedPath(self: *const DAGBuilder, alloc: std.mem.Allocator, node: DAGNode) !ClosedPath {
        const count = self.extra_data.items[node.data + 1];
        const numbers = self.numbers.items[self.extra_data.items[node.data]..][0 .. PATH_START_NUMBERS + PATH_SEGMENT_NUMBERS * count];
        const segments = try alloc.alloc(path_mod.Segment, count);
        errdefer alloc.free(segments);
        const chords = try alloc.alloc(u32, count);
        for (segments, chords, 0..) |*segment, *chord, i| {
            const n = numbers[PATH_START_NUMBERS + PATH_SEGMENT_NUMBERS * i ..][0..PATH_SEGMENT_NUMBERS];
            segment.* = .{ .to = .{ n[0], n[1] }, .arc = if (n[2] != 0) .{ .center = .{ n[3], n[4] }, .radius = n[5] } else null, .ccw = n[6] != 0, .angle = n[7] };
            chord.* = @intFromFloat(n[8]);
        }
        return .{ .start = .{ numbers[0], numbers[1] }, .segments = segments, .chords = chords };
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

    /// The nodes `node` is made from, in extra_data (`node` must be sound, as the verifier
    /// checks every node to be).
    pub fn operandsOf(self: *const DAGBuilder, node: DAGNode) []const DAGNodeIndex {
        const extra = self.extra_data.items;
        return switch (layoutOf(node.tag)) {
            .operands => |n| extra[node.data..][0..n],
            .operand_list => extra[node.data + 1 ..][0..extra[node.data]],
            .target_numbers, .target_value => extra[node.data..][0..1],
            .loft => extra[node.data..][0..2],
            .none, .numbers, .polygon, .path, .polygons, .polyhedron, .concrete => &.{},
        };
    }

    /// The nodes the `roots` are made from, the roots included. A node's operands are
    /// always earlier nodes, so one pass from the last node back finds them all.
    pub fn liveNodes(self: *const DAGBuilder, set_allocator: std.mem.Allocator, roots: []const DAGNodeIndex) !std.bit_set.Dynamic {
        var live = try std.bit_set.Dynamic.initEmpty(set_allocator, self.nodes.items.len);
        for (roots) |root| {
            if (root < self.nodes.items.len) live.set(root);
        }
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            if (!live.isSet(i)) continue;
            for (self.operandsOf(self.nodes.items[i])) |operand| live.set(operand);
        }
        return live;
    }

    /// Destroys the meshes of the concrete leaves no `live` node is made from. Their nodes
    /// stay, emptied: nothing can reach them again, since building on a node takes a live
    /// shape made from it.
    pub fn releaseUnreachableLeaves(self: *DAGBuilder, live: *const std.bit_set.Dynamic) void {
        for (self.nodes.items, 0..) |node, i| {
            if (node.tag != .concrete or live.isSet(i)) continue;
            const leaf = &self.concrete_leaves.items[node.data];
            if (leaf.handle) |h| {
                kernel.destruct(h);
                leaf.handle = null;
                self.held_leaves -= 1;
            }
        }
    }

    // --- Compaction ---

    /// The bytes the node tables hold.
    pub fn tableBytes(self: *const DAGBuilder) usize {
        return self.nodes.items.len * @sizeOf(DAGNode) +
            self.node_hashes.items.len * @sizeOf(u64) +
            self.dedup_map.count() * (@sizeOf(u64) + @sizeOf(DAGNodeIndex)) +
            self.extra_data.items.len * @sizeOf(u32) +
            self.numbers.items.len * @sizeOf(f64) +
            self.poly_points.items.len * @sizeOf([3]f64) +
            self.poly_faces.items.len * @sizeOf([3]u32) +
            self.concrete_leaves.items.len * @sizeOf(ConcreteLeaf);
    }

    /// The hash node `idx` has by its payload now, for tests that check a copied payload: it
    /// is the stored one but after a collision (appendNodeWithRollback).
    pub fn recomputedHash(self: *const DAGBuilder, idx: DAGNodeIndex) !u64 {
        return self.computeNodeHash(self.nodes.items[idx]);
    }

    /// Moves the next compaction to when the tables have doubled from now.
    pub fn postponeCompaction(self: *DAGBuilder) void {
        self.compact_at = @max(self.compaction_floor, 2 * self.tableBytes());
    }

    /// Whether the tables have grown enough since the last compaction to compact them.
    pub fn wantsCompaction(self: *const DAGBuilder) bool {
        return self.tableBytes() >= self.compact_at;
    }

    /// Keeps only the `live` nodes (liveNodes): copies each, with its payload, into new
    /// tables in their order, so operands stay before what is made from them, with its hash
    /// (the result caches' key, so what they hold stays theirs), and drops the rest with
    /// their leaves' meshes. Returns each old index's new one (maxInt for a dropped node),
    /// which the caller applies to every shape it holds; on failure nothing has changed.
    pub fn compact(self: *DAGBuilder, live: *const std.bit_set.Dynamic) ![]DAGNodeIndex {
        var fresh = DAGBuilder.init(self.gpa);
        // The leaves' meshes are still this builder's until the swap, and the settings ids
        // stay the same: the table is shared, and not freed with the copy's.
        errdefer fresh.freeTables();
        fresh.settings_table = self.settings_table;
        fresh.part_names = self.part_names;
        fresh.part_name_ids = self.part_name_ids;
        const renumbered = try self.gpa.alloc(DAGNodeIndex, self.nodes.items.len);
        errdefer self.gpa.free(renumbered);

        const kept = live.count();
        try fresh.nodes.ensureTotalCapacity(self.gpa, kept);
        try fresh.node_hashes.ensureTotalCapacity(self.gpa, kept);
        try fresh.dedup_map.ensureTotalCapacity(self.gpa, @intCast(kept));
        for (self.nodes.items, self.node_hashes.items, renumbered, 0..) |node, hash, *new_index, i| {
            if (!live.isSet(i)) {
                new_index.* = std.math.maxInt(DAGNodeIndex);
                continue;
            }
            const copy = try self.copyNode(&fresh, node, renumbered);
            if (VERIFY_NODES) if (dag_verifier.problem(&fresh, copy)) |why| {
                std.debug.panic("DAG compaction bug: a {s} node copied malformed: {s}", .{ @tagName(copy.tag), why });
            };
            new_index.* = @intCast(fresh.nodes.items.len);
            fresh.nodes.appendAssumeCapacity(copy);
            fresh.node_hashes.appendAssumeCapacity(hash);
            fresh.dedup_map.putAssumeCapacity(hash, new_index.*);
        }

        // Nothing fails from here: the dropped leaves' meshes go, and the new tables in.
        for (self.nodes.items, 0..) |node, i| {
            if (node.tag != .concrete or live.isSet(i)) continue;
            if (self.concrete_leaves.items[node.data].handle) |h| kernel.destruct(h);
        }
        self.freeTables();
        fresh.current_settings = self.current_settings;
        fresh.next_leaf_serial = self.next_leaf_serial;
        for (fresh.concrete_leaves.items) |leaf| fresh.held_leaves += @intFromBool(leaf.handle != null);
        fresh.compaction_floor = self.compaction_floor;
        fresh.postponeCompaction();
        self.* = fresh;
        return renumbered;
    }

    /// `node`, its payload copied into `fresh` (by layoutOf) and its operands renumbered.
    fn copyNode(self: *const DAGBuilder, fresh: *DAGBuilder, node: DAGNode, renumbered: []const DAGNodeIndex) !DAGNode {
        const extra = self.extra_data.items;
        const at = node.data;
        var copy = node;
        switch (layoutOf(node.tag)) {
            .none => {},
            .numbers => |n| copy.data = try fresh.appendNumbers(self.numbers.items[at..][0..n]),
            .operands => |n| copy.data = try fresh.appendOperands(extra[at..][0..n], renumbered),
            .operand_list => {
                copy.data = try fresh.appendExtraData(&.{extra[at]});
                _ = try fresh.appendOperands(extra[at + 1 ..][0..extra[at]], renumbered);
            },
            .target_numbers => |n| {
                const numbers_at = try fresh.appendNumbers(self.numbers.items[extra[at + 1]..][0..n]);
                copy.data = try fresh.appendExtraData(&.{ renumbered[extra[at]], numbers_at });
            },
            .target_value => copy.data = try fresh.appendExtraData(&.{ renumbered[extra[at]], extra[at + 1] }),
            .loft => {
                const numbers_at = try fresh.appendNumbers(self.numbers.items[extra[at + 2]..][0..1]);
                copy.data = try fresh.appendExtraData(&.{ renumbered[extra[at]], renumbered[extra[at + 1]], numbers_at });
            },
            .polygon => {
                const count = extra[at + 1];
                const numbers_at = try fresh.appendNumbers(self.numbers.items[extra[at]..][0 .. 2 * count]);
                copy.data = try fresh.appendExtraData(&.{ numbers_at, count });
            },
            .path => {
                const count = extra[at + 1];
                const numbers_at = try fresh.appendNumbers(self.numbers.items[extra[at]..][0 .. PATH_START_NUMBERS + PATH_SEGMENT_NUMBERS * count]);
                copy.data = try fresh.appendExtraData(&.{ numbers_at, count });
            },
            .polygons => {
                const count = extra[at];
                copy.data = try fresh.appendExtraData(&.{count});
                for (0..count) |i| {
                    const points = extra[at + 1 + 2 * i];
                    const len = extra[at + 2 + 2 * i];
                    const numbers_at = try fresh.appendNumbers(self.numbers.items[points..][0 .. 2 * len]);
                    _ = try fresh.appendExtraData(&.{ numbers_at, len });
                }
                const curves_at = self.polygonsCurvesAt(at);
                const curves = extra[curves_at];
                const numbers_at = try fresh.appendNumbers(self.numbers.items[extra[curves_at + 1]..][0 .. CURVE_NUMBERS * curves]);
                _ = try fresh.appendExtraData(&.{ curves, numbers_at });
                _ = try fresh.appendExtraData(extra[curves_at + 2 ..][0 .. CURVE_WORDS * curves]);
            },
            .polyhedron => {
                const points_at: u32 = @intCast(fresh.poly_points.items.len);
                try fresh.poly_points.appendSlice(fresh.gpa, self.poly_points.items[extra[at]..][0..extra[at + 1]]);
                const faces_at: u32 = @intCast(fresh.poly_faces.items.len);
                try fresh.poly_faces.appendSlice(fresh.gpa, self.poly_faces.items[extra[at + 2]..][0..extra[at + 3]]);
                copy.data = try fresh.appendExtraData(&.{ points_at, extra[at + 1], faces_at, extra[at + 3], extra[at + 4], extra[at + 5] });
            },
            .concrete => {
                copy.data = @intCast(fresh.concrete_leaves.items.len);
                try fresh.concrete_leaves.append(fresh.gpa, self.concrete_leaves.items[at]);
            },
        }
        return copy;
    }

    /// `operands` renumbered, appended to extra_data; where they start.
    fn appendOperands(self: *DAGBuilder, operands: []const DAGNodeIndex, renumbered: []const DAGNodeIndex) !u32 {
        const start: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.ensureUnusedCapacity(self.gpa, operands.len);
        for (operands) |operand| self.extra_data.appendAssumeCapacity(renumbered[operand]);
        return start;
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

    pub inline fn getSpherePayload(self: *const DAGBuilder, node: DAGNode) struct { radius: f64, segments: i32 } {
        return .{
            .radius = self.numbers.items[node.data],
            .segments = @intFromFloat(self.numbers.items[node.data + 1]),
        };
    }

    pub inline fn getSquarePayload(self: *const DAGBuilder, node: DAGNode) struct { x: f64, y: f64, center: bool } {
        return .{
            .x = self.numbers.items[node.data],
            .y = self.numbers.items[node.data + 1],
            .center = (node.flags & 1) != 0,
        };
    }

    pub inline fn getRoundedSquarePayload(self: *const DAGBuilder, node: DAGNode) rounded_rect.RoundedRect {
        const n = self.numbers.items[node.data..][0..4];
        return .{ .x = n[0], .y = n[1], .center = (node.flags & 1) != 0, .radius = n[2], .segments = @intFromFloat(n[3]) };
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
            .segments = @intFromFloat(self.numbers.items[self.extra_data.items[node.data + 1] + 1]),
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

    pub inline fn getNamePayload(self: *const DAGBuilder, node: DAGNode) struct { target: DAGNodeIndex, name_id: u32 } {
        return .{
            .target = self.extra_data.items[node.data],
            .name_id = self.extra_data.items[node.data + 1],
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
        // By content, not id: the hash keys the result cache, which outlives the table.
        hasher.update(std.mem.asBytes(&self.settings(node.settings).resultHash()));

        // Where the layout lets a part's length vary, the length too, so payloads split
        // differently (a polygon's contours [3 pts][5 pts] and [4 pts][4 pts]) never hash
        // alike; elsewhere the tag fixes it.
        var parts = self.payloadParts(node);
        const sized = parts.layout.variesInLength();
        while (parts.next()) |part| switch (part) {
            .operands => |operands| {
                if (sized) hasher.update(std.mem.asBytes(&@as(u64, operands.len)));
                for (operands) |operand| hasher.update(std.mem.asBytes(&(try self.childHash(operand))));
            },
            .numbers => |numbers| {
                if (sized) hasher.update(std.mem.asBytes(&@as(u64, numbers.len)));
                hasher.update(std.mem.sliceAsBytes(numbers));
            },
            .value => |v| hasher.update(std.mem.asBytes(&v)),
            .words => |words| {
                if (sized) hasher.update(std.mem.asBytes(&@as(u64, words.len)));
                hasher.update(std.mem.sliceAsBytes(words));
            },
            .serial => |v| hasher.update(std.mem.asBytes(&v)),
            // Covered by the mesh hash before them, computed once when the node was made:
            // a polyhedron can have millions of points.
            .points, .faces => {},
        };
        return hasher.final();
    }

    // --- Structural Equality (CSE verification) ---

    /// Compares tag, flags, settings and every payload part. Operands are compared by index:
    /// they are deduplicated exactly themselves, so equal sub-DAGs always share one index.
    fn nodesEqual(self: *const DAGBuilder, a: DAGNode, b: DAGNode) bool {
        if (a.tag != b.tag or a.flags != b.flags or a.settings != b.settings) return false;
        var parts_a = self.payloadParts(a);
        var parts_b = self.payloadParts(b);
        while (parts_a.next()) |part_a| {
            const part_b = parts_b.next() orelse return false;
            if (!partsEqual(part_a, part_b)) return false;
        }
        return parts_b.next() == null;
    }

    fn partsEqual(a: PayloadPart, b: PayloadPart) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .operands => |x| std.mem.eql(DAGNodeIndex, x, b.operands),
            // Bitwise, as they are hashed (so NaN payloads compare equal).
            .numbers => |x| std.mem.eql(u8, std.mem.sliceAsBytes(x), std.mem.sliceAsBytes(b.numbers)),
            .points => |x| std.mem.eql(u8, std.mem.sliceAsBytes(x), std.mem.sliceAsBytes(b.points)),
            .faces => |x| std.mem.eql(u8, std.mem.sliceAsBytes(x), std.mem.sliceAsBytes(b.faces)),
            .value => |x| x == b.value,
            .words => |x| std.mem.eql(u32, x, b.words),
            .serial => |x| x == b.serial,
        };
    }

    /// `node`'s payload, part by part, as its layout lays it out: what the hash covers and
    /// equality compares.
    fn payloadParts(self: *const DAGBuilder, node: DAGNode) PayloadParts {
        return .{ .b = self, .node = node, .layout = layoutOf(node.tag) };
    }

    // --- Hybrid CSG Tree Balancing ---

    /// Automatically routes a list of target geometries into either a flat Batch node
    /// or a Balanced Binary Tree depending on the operation type.
    pub fn addBalancedChain(self: *DAGBuilder, tag: DAGTag, targets: []const DAGNodeIndex) !DAGNodeIndex {
        if (targets.len == 0) return error.EmptyChain;
        // A union of one shape is that shape, but its hull is not: `part.hull` with no
        // arguments used to return `part` itself, concave or not.
        if (targets.len == 1) return if (tag == .hull or tag == .batch_hull_op) self.addHull(targets[0]) else targets[0];

        // 1. Homogeneous Chain Flattening (Spatial $O(N \log N)$ acceleration in Manifold)
        // Commutative associative ops are best sent to the C++ kernel as a single array.
        if (tag == .union_op or tag == .batch_union_op) {
            return self.addBatchUnion(targets);
        }
        if (tag == .hull or tag == .batch_hull_op) {
            return self.addBatchHull(targets);
        }

        // A difference isn't associative: a - b - c is a - (b ∪ c). The balanced tree
        // below made (a - b) - (c - d) of it, putting back whatever c cut out of d.
        if (tag == .difference_op or tag == .cs_difference_op) {
            const cutters = try self.addBalancedChain(if (tag == .difference_op) .union_op else .cs_union_op, targets[1..]);
            return self.addBinary(tag, targets[0], cutters);
        }

        // 2. Heterogeneous/Non-Batchable Chain Balancing
        // For Intersections or 2D ops, we reduce the DAG depth
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
