//! Every public operation under a failing allocator (README rule 6, architecture §9.2):
//! whichever allocation fails, the operation returns `error.OutOfMemory`, leaves nothing
//! allocated, and touches no input. `std.testing.checkAllAllocationFailures` fails each
//! allocation in turn and checks for leaks after each. And every operation that takes
//! `Options` stops on a cancel flag set before the call, the same way (`Canceled`).

const std = @import("std");
const testing = std.testing;
const vec = @import("math/vec.zig");
const mat = @import("math/mat.zig");
const Tolerance = @import("tolerance.zig").Tolerance;
const Diagnostics = @import("diagnostics.zig").Diagnostics;
const Body = @import("topology/body.zig").Body;
const primitives = @import("construct/primitives.zig");
const hull = @import("construct/hull.zig");
const transform = @import("construct/transform.zig");
const body_json = @import("io/body_json.zig");
const step_write = @import("io/step_write.zig");
const check = @import("topology/check.zig");
const bvh = @import("spatial/bvh.zig");
const tessellate = @import("mesh/tessellate.zig");
const diagnostics = @import("diagnostics.zig");
const pipeline = @import("boolean/pipeline.zig");
const trim = @import("boolean/trim.zig");
const section = @import("boolean/section.zig");
const decompose = @import("construct/decompose.zig");
const index_mod = @import("query/index.zig");
const point_in_body = @import("query/point_in_body.zig");
const raycast = @import("query/raycast.zig");
const distance = @import("query/distance.zig");
const faces = @import("query/faces.zig");
const sketch_boolean = @import("sketch/boolean.zig");
const sketch_offset = @import("sketch/offset.zig");
const sketch_hull = @import("sketch/hull.zig");
const helpers = @import("boolean/pipeline_test.zig");

const tol = Tolerance.fromZone(1e-5);

/// Stack frames kept per allocation in a sweep: none. A sweep makes about the square of an
/// operation's allocations (a boolean's 1,250 make 780,000), and a trace for each made the
/// sweep 55 times slower. A leak is found without them (the failing allocator counts the
/// bytes); raise this to see where a leaked block was allocated.
const SWEEP_TRACE_FRAMES = 0;

/// The heap a sweep runs on: double frees caught, no stack traces (`SWEEP_TRACE_FRAMES`),
/// and every in-place resize refused, so a growing list always allocates afresh: the sweep
/// counts allocations, and whether a resize succeeds in place depends on the heap's page
/// layout (it did on Linux and Windows and not on macOS), which made the count differ
/// between runs (`NondeterministicMemoryUsage`).
const SweepHeap = struct {
    heap: std.heap.SafeAllocator,

    fn init() SweepHeap {
        return .{ .heap = .init(std.heap.page_allocator, .{ .stack_trace_frames = SWEEP_TRACE_FRAMES }) };
    }

    fn allocator(self: *SweepHeap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SweepHeap = @ptrCast(@alignCast(ctx));
        return self.heap.allocator().rawAlloc(len, alignment, ret_addr);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *SweepHeap = @ptrCast(@alignCast(ctx));
        self.heap.allocator().rawFree(memory, alignment, ret_addr);
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};

/// `test_fn(allocator, args...)` with each of its allocations failed in turn, on a
/// `SweepHeap`: `error.OutOfMemory` each time, nothing left allocated.
fn sweep(comptime test_fn: anytype, args: anytype) !void {
    var heap: SweepHeap = .init();
    const swept = testing.checkAllAllocationFailures(heap.allocator(), test_fn, args);
    const leaks = heap.heap.deinit();
    try swept;
    try testing.expectEqual(0, leaks);
}

fn buildBox(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var b = try primitives.box(allocator, tol, 1, 2, 3, true, &diag);
    b.deinit();
}

fn buildCylinder(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var b = try primitives.cylinder(allocator, tol, 1, 2, false, &diag);
    b.deinit();
}

fn buildCircle(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var b = try primitives.circle(allocator, tol, 1, &diag);
    b.deinit();
}

fn buildEvenOdd(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    var b = try primitives.polygonsEvenOdd(allocator, tol, &.{ &outer, &inner }, &diag);
    b.deinit();
}

fn buildPolyhedron(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const pts = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 } };
    const tris = [_][3]u32{ .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 } };
    var b = try primitives.polyhedron(allocator, tol, &pts, &tris, &diag);
    b.deinit();
}

fn buildHull(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const pts = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 }, .{ 5, 5, 5 }, .{ 2, 2, 2 } };
    var b = try hull.hull(allocator, tol, &pts, &diag);
    b.deinit();
}

/// The input body, built with an allocator that never fails, so a failure inside the
/// operation cannot be one of its own.
fn withBody(allocator: std.mem.Allocator, op: *const fn (std.mem.Allocator, *const Body) anyerror!void) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var body = try primitives.cylinder(testing.allocator, tol, 2, 5, true, &diag);
    defer body.deinit();
    const before = try body_json.dump(testing.allocator, &body);
    defer testing.allocator.free(before);
    try op(allocator, &body);
    // The input is untouched whatever happened
    const after = try body_json.dump(testing.allocator, &body);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

fn opTransform(allocator: std.mem.Allocator, body: *const Body) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const affine = mat.Affine.mirror(vec.X3).compose(&mat.Affine.scaleBy(.{ 2, 2, 2 }));
    var out = try transform.transform(allocator, body, &affine, .{}, &diag);
    out.deinit();
}

fn opDumpLoad(allocator: std.mem.Allocator, body: *const Body) !void {
    const text = try body_json.dump(allocator, body);
    defer allocator.free(text);
    var loaded = try body_json.load(allocator, text);
    loaded.deinit();
    _ = try body_json.hash(allocator, body);
}

fn opStep(allocator: std.mem.Allocator, body: *const Body) !void {
    const text = try step_write.write(allocator, &.{body});
    allocator.free(text);
}

fn opCheck(allocator: std.mem.Allocator, body: *const Body) !void {
    var report = try check.run(allocator, body, .geometric);
    report.deinit(allocator);
}

fn opClone(allocator: std.mem.Allocator, body: *const Body) !void {
    var copy = try body.clone(allocator);
    copy.deinit();
}

fn opCompact(allocator: std.mem.Allocator, body: *const Body) !void {
    var copy = try body.clone(allocator);
    defer copy.deinit();
    var remap = try copy.compact();
    remap.deinit(allocator);
}

fn opTessellate(allocator: std.mem.Allocator, body: *const Body) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var mesh = try tessellate.tessellate(allocator, body, .{}, .{}, &diag);
    mesh.deinit(allocator);
}

fn opBvh(allocator: std.mem.Allocator, body: *const Body) !void {
    _ = body;
    var boxes: [40]@import("geometry/types.zig").Box3 = undefined;
    for (&boxes, 0..) |*b, i| {
        const x: f64 = @floatFromInt(i % 7);
        const y: f64 = @floatFromInt(i / 7);
        b.* = .{ .min = .{ x, y, 0 }, .max = .{ x + 1.5, y + 1.5, 1 } };
    }
    var tree = try bvh.Bvh.build(allocator, &boxes);
    tree.deinit(allocator);
}

/// The inputs of the operations since M1: two boxes overlapping at a corner, a small box
/// inside the void of a body of parts (two solids apart, the first holding the void), two
/// squares overlapping. Built with an allocator that never fails.
const Inputs = struct {
    a: Body,
    b: Body,
    inner: Body,
    parts: Body,
    square: Body,
    other_square: Body,

    fn init() !Inputs {
        var a = try helpers.box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
        errdefer a.deinit();
        var b = try helpers.box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
        errdefer b.deinit();
        var inner = try helpers.box(.{ 1.5, 1.5, 1.5 }, .{ 2.5, 2.5, 2.5 });
        errdefer inner.deinit();
        var outer = try helpers.box(.{ 0, 0, 0 }, .{ 4, 4, 4 });
        defer outer.deinit();
        var cavity = try helpers.box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
        defer cavity.deinit();
        var hollow = try helpers.sound(&outer, &cavity, .difference);
        defer hollow.deinit();
        var apart = try helpers.box(.{ 6, 0, 0 }, .{ 7, 1, 1 });
        defer apart.deinit();
        var parts = try helpers.sound(&hollow, &apart, .@"union");
        errdefer parts.deinit();
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var square = try primitives.square(testing.allocator, tol, 2, 2, false, &diag);
        errdefer square.deinit();
        var unit = try primitives.square(testing.allocator, tol, 2, 2, false, &diag);
        defer unit.deinit();
        const other_square = try transform.transform(testing.allocator, &unit, &mat.Affine.translate(.{ 1, 1, 0 }), .{}, &diag);
        return .{ .a = a, .b = b, .inner = inner, .parts = parts, .square = square, .other_square = other_square };
    }

    const NAMES = .{ "a", "b", "inner", "parts", "square", "other_square" };

    fn deinit(self: *Inputs) void {
        inline for (NAMES) |name| @field(self, name).deinit();
    }

    /// Every input as JSON, for the check that nothing touched them.
    const Dump = [NAMES.len][]u8;

    fn dump(self: *const Inputs) !Dump {
        var out: Dump = undefined;
        inline for (NAMES, 0..) |name, i| out[i] = try body_json.dump(testing.allocator, &@field(self, name));
        return out;
    }

    fn free(d: Dump) void {
        for (d) |t| testing.allocator.free(t);
    }

    /// The inputs as they were in `before`.
    fn expectUntouched(self: *const Inputs, before: Dump) !void {
        const after = try self.dump();
        defer free(after);
        for (before, after) |x, y| try testing.expectEqualStrings(x, y);
    }
};

const Op = *const fn (std.mem.Allocator, *const Inputs, diagnostics.Options) anyerror!void;

/// `op` called, for the sweep (which takes a function, not a pointer to one).
fn callOp(allocator: std.mem.Allocator, op: Op, inputs: *const Inputs, options: diagnostics.Options) !void {
    return op(allocator, inputs, options);
}

fn opBoolean(comptime op: pipeline.Op) Op {
    return struct {
        fn run(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
            var diag = Diagnostics.init(allocator);
            defer diag.deinit();
            var report = pipeline.Report.init(allocator);
            defer report.deinit();
            var r = try pipeline.boolean(allocator, &in.a, &in.b, op, .{ .common = options }, &diag, &report);
            r.deinit();
        }
    }.run;
}

fn opContainment(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    // The box in the void meets the parts nowhere
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var report = pipeline.Report.init(allocator);
    defer report.deinit();
    var r = try pipeline.boolean(allocator, &in.parts, &in.inner, .@"union", .{ .common = options }, &diag, &report);
    r.deinit();
    try testing.expect(report.by_containment);
}

fn opChain(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var report = pipeline.Report.init(allocator);
    defer report.deinit();
    var r = try pipeline.chain(allocator, &.{ &in.a, &in.b, &in.inner }, .@"union", .{ .common = options }, &diag, &report);
    r.deinit();
}

fn opTrim(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var r = try trim.trimByPlane(allocator, &in.a, .{ 1, 1, 1 }, 1.5, .{ .common = options }, &diag, null);
    r.deinit();
}

fn opSplit(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var sides = try trim.splitByPlane(allocator, &in.a, .{ 0, 0, 1 }, 1, .{ .common = options }, &diag);
    for (&sides) |*side| side.deinit();
}

fn opDecompose(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const parts = try decompose.decompose(allocator, &in.parts, options, &diag);
    for (parts) |*part| part.deinit();
    allocator.free(parts);
}

fn opSlice(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var r = try section.slice(allocator, &in.parts, 2, options, &diag);
    r.deinit();
}

fn opContains(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var index = try index_mod.FaceIndex.build(allocator, &in.parts, &diag);
    defer index.deinit(allocator);
    _ = try point_in_body.contains(allocator, &in.parts, &index, .{ 2, 2, 0.5 }, options, &diag);
}

fn opRayCast(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var index = try index_mod.FaceIndex.build(allocator, &in.parts, &diag);
    defer index.deinit(allocator);
    const hits = try raycast.cast(allocator, &in.parts, &index, .{ -1, 2, 2 }, .{ 8, 2, 2 }, options, &diag);
    allocator.free(hits);
}

fn opMinGap(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var mesh_a = try tessellate.tessellate(allocator, &in.a, .{}, options, &diag);
    defer mesh_a.deinit(allocator);
    var mesh_b = try tessellate.tessellate(allocator, &in.parts, .{}, options, &diag);
    defer mesh_b.deinit(allocator);
    _ = try distance.minGap(allocator, .{ .body = &in.a, .mesh = &mesh_a, .resolution = .{} }, .{ .body = &in.parts, .mesh = &mesh_b, .resolution = .{} }, 10, options, &diag);
}

fn opFaces(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    _ = options;
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const matches = try faces.byDirection(allocator, &in.parts, .{ 0, 0, 1 }, &diag);
    allocator.free(matches);
}

fn opSketchBoolean(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var r = try sketch_boolean.boolean(allocator, &.{ &in.square, &in.other_square }, .difference, options, &diag);
    r.deinit();
}

fn opSketchOffset(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var r = try sketch_offset.offset(allocator, &in.square, 0.5, .round, sketch_offset.LEAST_MITER_LIMIT, options, &diag);
    r.deinit();
}

fn opSketchHull(allocator: std.mem.Allocator, in: *const Inputs, options: diagnostics.Options) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var r = try sketch_hull.hull(allocator, &.{ &in.square, &in.other_square }, options, &diag);
    r.deinit();
}

/// The operations since M1, by name; `cancels` when they take `Options` (all but the
/// face query, which visits each face once and allocates its answer).
const SINCE_M1 = [_]struct { name: []const u8, op: Op, cancels: bool = true }{
    .{ .name = "union", .op = opBoolean(.@"union") },
    .{ .name = "difference", .op = opBoolean(.difference) },
    .{ .name = "intersection", .op = opBoolean(.intersection) },
    .{ .name = "a boolean by the containment table", .op = opContainment },
    .{ .name = "a chain", .op = opChain },
    .{ .name = "trim_by_plane", .op = opTrim },
    .{ .name = "split_by_plane", .op = opSplit },
    .{ .name = "decompose", .op = opDecompose },
    .{ .name = "slice", .op = opSlice },
    .{ .name = "contains", .op = opContains },
    .{ .name = "ray cast", .op = opRayCast },
    .{ .name = "min gap", .op = opMinGap },
    .{ .name = "faces by direction", .op = opFaces, .cancels = false },
    .{ .name = "a sketch boolean", .op = opSketchBoolean },
    .{ .name = "a sketch offset", .op = opSketchOffset },
    .{ .name = "a sketch hull", .op = opSketchHull },
};

test "allocation failure: every primitive leaves nothing allocated whichever allocation fails" {
    try sweep(buildBox, .{});
    try sweep(buildCylinder, .{});
    try sweep(buildCircle, .{});
    try sweep(buildEvenOdd, .{});
    try sweep(buildPolyhedron, .{});
    try sweep(buildHull, .{});
}

test "allocation failure: every operation on a body leaves nothing allocated and the input untouched" {
    try sweep(withBody, .{opTransform});
    try sweep(withBody, .{opDumpLoad});
    try sweep(withBody, .{opStep});
    try sweep(withBody, .{opCheck});
    try sweep(withBody, .{opClone});
    try sweep(withBody, .{opCompact});
    try sweep(withBody, .{opBvh});
    try sweep(withBody, .{opTessellate});
}

test "cancel: a flag set before the call is error.Canceled, with nothing allocated and the input untouched" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var body = try primitives.cylinder(testing.allocator, tol, 2, 5, true, &diag);
    defer body.deinit();
    const before = try body_json.dump(testing.allocator, &body);
    defer testing.allocator.free(before);
    var flag = std.atomic.Value(bool).init(true);
    const affine = mat.Affine.translate(.{ 1, 0, 0 });
    try testing.expectError(error.Canceled, transform.transform(testing.allocator, &body, &affine, .{ .cancel = &flag }, &diag));
    const after = try body_json.dump(testing.allocator, &body);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

// The inputs are built once for all operations and checked after each (a sweep runs its
// operation once per allocation, and a run that touched them leaves the change for the
// check to see).

test "allocation failure: every operation since M1 leaves nothing allocated and its inputs untouched" {
    var inputs = try Inputs.init();
    defer inputs.deinit();
    const before = try inputs.dump();
    defer Inputs.free(before);
    for (SINCE_M1) |case| {
        errdefer std.debug.print("operation: {s}\n", .{case.name});
        try sweep(callOp, .{ case.op, &inputs, diagnostics.Options{} });
        try inputs.expectUntouched(before);
    }
}

test "cancel: every operation since M1 that takes options stops on a flag set before the call, nothing allocated, its inputs untouched" {
    var inputs = try Inputs.init();
    defer inputs.deinit();
    const before = try inputs.dump();
    defer Inputs.free(before);
    var flag = std.atomic.Value(bool).init(true);
    for (SINCE_M1) |case| {
        if (!case.cancels) continue;
        errdefer std.debug.print("operation: {s}\n", .{case.name});
        try testing.expectError(error.Canceled, case.op(testing.allocator, &inputs, .{ .cancel = &flag }));
        try inputs.expectUntouched(before);
    }
}
