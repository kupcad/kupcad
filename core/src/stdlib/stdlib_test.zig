const std = @import("std");
const testing = std.testing;
const VM = @import("../vm/vm.zig").VM;
const InterpretResult = @import("../vm/vm.zig").InterpretResult;
const chunk = @import("../vm/chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("registry.zig");
const kernel = @import("../kernel/kernel.zig");
const limits = @import("../core/limits.zig");
const ErrorKind = @import("../vm/error_kind.zig").ErrorKind;
const engine_config = @import("../core/engine_config.zig");

const print = std.fmt.comptimePrint;
const MAX_SEGS = limits.MAX_SEGMENTS;
const MAX_COUNT = limits.MAX_PATTERN_COUNT;

test "Stdlib: Formalized Solid and Sketch2D classes generate identical primitive instances" {
    const alloc = testing.allocator;

    // 1. Verify thin global alias 'cube()' and static method 'Solid.cube()'
    const src_3d =
        \\c1 = cube(10)
        \\c2 = Solid.cube(10)
        \\[c1, c2]
    ;
    var doc_3d = try Document.parse(alloc, src_3d);
    defer doc_3d.deinit();

    var vm_3d = try VM.init(alloc, testing.io);
    defer vm_3d.deinit();
    try registry.registerStandardLibrary(&vm_3d);

    var chunk_3d = chunk.Chunk.init();
    defer chunk_3d.free(alloc);

    var comp_3d = Compiler.init(alloc, &doc_3d.tree, doc_3d.symbols, doc_3d.tokens.starts, &chunk_3d, &vm_3d);
    defer comp_3d.deinit();

    try comp_3d.compile(doc_3d.tree.root);
    try testing.expectEqual(vm_3d.interpret(&chunk_3d), .ok);

    try testing.expect(vm_3d.stack_top > 0);
    const arr_3d = vm_3d.stack[0].asArray();
    try testing.expectEqual(@as(usize, 2), arr_3d.items.items.len);
    try testing.expect(arr_3d.items.items[0].isGeometry());
    try testing.expect(arr_3d.items.items[1].isGeometry());

    // 2. Verify thin global alias 'square()' and static method 'Sketch2D.square()'
    const src_2d =
        \\s1 = square(10)
        \\s2 = Sketch2D.square(10)
        \\[s1, s2]
    ;
    var doc_2d = try Document.parse(alloc, src_2d);
    defer doc_2d.deinit();

    var vm_2d = try VM.init(alloc, testing.io);
    defer vm_2d.deinit();
    try registry.registerStandardLibrary(&vm_2d);

    var chunk_2d = chunk.Chunk.init();
    defer chunk_2d.free(alloc);

    var comp_2d = Compiler.init(alloc, &doc_2d.tree, doc_2d.symbols, doc_2d.tokens.starts, &chunk_2d, &vm_2d);
    defer comp_2d.deinit();

    try comp_2d.compile(doc_2d.tree.root);
    try testing.expectEqual(vm_2d.interpret(&chunk_2d), .ok);

    const arr_2d = vm_2d.stack[0].asArray();
    try testing.expectEqual(@as(usize, 2), arr_2d.items.items.len);
    try testing.expect(arr_2d.items.items[0].isCrossSection());
    try testing.expect(arr_2d.items.items[1].isCrossSection());
}

test "Stdlib: Instance export methods allow fluent method chaining and return receiver" {
    const alloc = testing.allocator;
    const tmp_stl = "test_chain_export.stl";
    defer std.Io.Dir.cwd().deleteFile(testing.io, tmp_stl) catch {};

    const src =
        \\c = Solid.cube(10).translate(5, 0, 0).export_stl("test_chain_export.stl")
        \\c
    ;
    var doc = try Document.parse(alloc, src);
    defer doc.deinit();

    var vm = try VM.init(alloc, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(alloc);

    var comp = Compiler.init(alloc, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    try testing.expectEqual(vm.interpret(&out_chunk), .ok);

    // Verify receiver geometry was returned for chaining
    try testing.expect(vm.stack_top > 0);
    try testing.expect(vm.stack[0].isGeometry());

    // Verify file export was executed
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(testing.io, tmp_stl, .{});
    try testing.expect(stat.size > 84);
}

test "Stdlib: global union() processes arrays into batch DAG nodes" {
    const alloc = testing.allocator;
    const src =
        \\a = cube(10)
        \\b = cube(10).translate(10, 0, 0)
        \\c = cube(10).translate(20, 0, 0)
        \\res = union([a, b, c])
        \\[res]
    ;
    var doc = try Document.parse(alloc, src);
    defer doc.deinit();

    var vm = try VM.init(alloc, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var chunk_out = chunk.Chunk.init();
    defer chunk_out.free(alloc);

    var comp = Compiler.init(alloc, &doc.tree, doc.symbols, doc.tokens.starts, &chunk_out, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    try testing.expectEqual(vm.interpret(&chunk_out), .ok);

    try testing.expect(vm.stack_top > 0);
    const arr = vm.stack[0].asArray();
    const res_geom = arr.items.items[0].asGeometry();

    // Verify DAG node correctly bypassed binary trees and flattened to batch_union_op
    const root_node = vm.dag_builder.nodes.items[res_geom.dag_idx];
    try testing.expectEqual(.batch_union_op, root_node.tag);

    // 3 cubes of 10x10x10 side-by-side -> exactly 3000 volume
    const handle = try vm.ensureConcrete(arr.items.items[0]);
    const vol = kernel.volume(handle);
    try testing.expectApproxEqAbs(@as(f64, 3000.0), vol, 1e-5);
}

test "Stdlib: variadic instance booleans flatten arguments and balance trees" {
    const alloc = testing.allocator;
    // Base is 0..20.
    // cut1 overlaps the top-right quadrant (10..20) -> 1000 volume removed
    // cut2 is at -10..0 -> 0 volume removed
    const src =
        \\base = cube(20)
        \\cut1 = cube(10).translate(10, 10, 10)
        \\cut2 = cube(10).translate(-10, -10, -10)
        \\res = base.difference(cut1, [cut2])
        \\[res]
    ;
    var doc = try Document.parse(alloc, src);
    defer doc.deinit();

    var vm = try VM.init(alloc, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var chunk_out = chunk.Chunk.init();
    defer chunk_out.free(alloc);

    var comp = Compiler.init(alloc, &doc.tree, doc.symbols, doc.tokens.starts, &chunk_out, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    try testing.expectEqual(vm.interpret(&chunk_out), .ok);

    try testing.expect(vm.stack_top > 0);
    const arr = vm.stack[0].asArray();
    const res_geom = arr.items.items[0].asGeometry();

    // Verify DAG node is a balanced difference_op, not a batch op
    const root_node = vm.dag_builder.nodes.items[res_geom.dag_idx];
    try testing.expectEqual(.difference_op, root_node.tag);

    // 8000 base volume - 1000 removed = 7000 final volume
    const handle = try vm.ensureConcrete(arr.items.items[0]);
    const vol = kernel.volume(handle);
    try testing.expectApproxEqAbs(@as(f64, 7000.0), vol, 1e-5);
}

test "Stdlib: meshHull dynamically gathers direct arguments and arrays into batch hull" {
    const alloc = testing.allocator;
    const src =
        \\a = cube(10).translate(-50, 0, 0)
        \\b = cube(10).translate(50, 0, 0)
        \\c = cube(10).translate(0, 50, 0)
        \\res = a.hull([b], c)
        \\[res]
    ;
    var doc = try Document.parse(alloc, src);
    defer doc.deinit();

    var vm = try VM.init(alloc, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var chunk_out = chunk.Chunk.init();
    defer chunk_out.free(alloc);

    var comp = Compiler.init(alloc, &doc.tree, doc.symbols, doc.tokens.starts, &chunk_out, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    try testing.expectEqual(vm.interpret(&chunk_out), .ok);

    try testing.expect(vm.stack_top > 0);
    const arr = vm.stack[0].asArray();
    const res_geom = arr.items.items[0].asGeometry();

    // Verify it correctly routed to the $O(1)$ Manifold Batch Hull wrapper
    const root_node = vm.dag_builder.nodes.items[res_geom.dag_idx];
    try testing.expectEqual(.batch_hull_op, root_node.tag);
}

// Input validation: user-supplied numbers must be rejected with a clean runtime
// error before they reach @intFromFloat (UB in ReleaseFast) or a kernel.
// These scripts only build DAG nodes (geometry is evaluated lazily), so a runtime
// error can only come from argument validation, not from a kernel.
// `Number::INFINITY` is +inf and `Number::NAN` is NaN (the VM traps `0.0 / 0.0` itself).

fn initVm() !VM {
    var vm = try VM.init(testing.allocator, testing.io);
    errdefer vm.deinit();
    // Errors are muted because the test runner treats logged errors as failures.
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);
    return vm;
}

fn runOn(vm: *VM, source: []const u8) !InterpretResult {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    return vm.interpret(&out_chunk);
}

fn runScript(source: []const u8) !InterpretResult {
    var vm = try initVm();
    defer vm.deinit();
    return runOn(&vm, source);
}

/// Runs each script on a fresh VM and expects `expected`; names the offending script on failure.
fn expectAll(expected: InterpretResult, sources: []const []const u8) !void {
    for (sources) |src| {
        errdefer std.debug.print("script: {s}\n", .{src});
        try testing.expectEqual(expected, try runScript(src));
    }
}

test "Stdlib: integer kwargs reject NaN, inf and out-of-i32 values" {
    try expectAll(.runtime_error, &.{
        "cylinder(r: 1, h: 1, segments: 1e12)",
        "cylinder(r: 1, h: 1, segments: Number::INFINITY)",
        "cylinder(r: 1, h: 1, segments: Number::NAN)",
        "square(10).extrude(5, slices: -1e12)",
        "square(10).helix(slices: Number::NAN)",
        "regular_polygon(sides: 1e12, r: 5)",
        "regular_polygon(Number::INFINITY, 5)",
    });
}

test "Stdlib: tessellation counts are capped at MAX_SEGMENTS" {
    try expectAll(.runtime_error, &.{
        print("cylinder(r: 1, h: 1, segments: {d})", .{MAX_SEGS + 1}),
        print("circle(r: 1, segments: {d})", .{MAX_SEGS + 1}),
        print("torus(10, 2, segments: {d})", .{MAX_SEGS + 1}),
        print("regular_polygon({d}, 5)", .{MAX_SEGS + 1}),
        print("regular_polygon(sides: {d})", .{MAX_SEGS + 1}),
        print("square(10).extrude(5, slices: {d})", .{MAX_SEGS + 1}),
        print("square(10).helix(slices: {d})", .{MAX_SEGS + 1}),
    });
    try expectAll(.ok, &.{
        print("cylinder(r: 1, h: 1, segments: {d})", .{MAX_SEGS}),
        print("regular_polygon({d}, 5)", .{MAX_SEGS}),
        print("square(10).extrude(5, slices: {d})", .{MAX_SEGS}),
    });
}

test "Stdlib: an operation that multiplies its inputs is refused before the kernel runs it" {
    // The vertex limit used to apply only to the finished mesh, after the kernel had
    // allocated it (an allocation failure in the kernel aborts the process).
    const cases = [_]struct { src: []const u8, expected: []const u8 }{
        .{ .src = comptime rescued("cube(1).minkowski(cube(1)).volume"), .expected = "GeometryError: minkowski would produce about 64 vertices, above the 50-vertex limit; lower the resolution (segments:) or simplify the model" },
        .{ .src = comptime rescued("square(10).extrude(5, slices: 20).volume"), .expected = "GeometryError: extrude would produce about 88 vertices, above the 50-vertex limit; lower the resolution (segments:) or simplify the model" },
        .{ .src = comptime rescued("square(10).translate(20, 0).revolve(segments: 30).volume"), .expected = "GeometryError: revolve would produce about 124 vertices, above the 50-vertex limit; lower the resolution (segments:) or simplify the model" },
        // Under the limit, the same operations run.
        .{ .src = comptime rescued("cube(1).minkowski(cube(1)).volume"), .expected = "no error" },
        .{ .src = comptime rescued("square(10).extrude(5, slices: 5).volume"), .expected = "no error" },
    };
    for (cases, 0..) |case, i| {
        errdefer std.debug.print("script: {s}\n", .{case.src});
        var vm = try initVm();
        defer vm.deinit();
        vm.config_stack.items[vm.config_stack.items.len - 1].max_vertices = if (i < 3) 50 else 100;
        try testing.expectEqual(InterpretResult.ok, try runOn(&vm, case.src));
        try testing.expectEqualStrings(case.expected, vm.globals.get("r").?.asString().chars);
    }
}

test "Stdlib: auto-computed segment counts are clamped to MAX_SEGMENTS" {
    var vm = try initVm();
    defer vm.deinit();

    // min_angle_deg 0.1 asks getSegments() for 3600 segments on a large circle.
    try testing.expectEqual(InterpretResult.ok, try runOn(&vm,
        \\CAD.config(manifold: { min_angle_deg: 0.1, min_segment_len: 0.01 })
        \\c = circle(r: 1000)
    ));
    const c = vm.globals.get("c") orelse return error.MissingGlobal;
    const node = vm.dag_builder.nodes.items[c.asCrossSection().dag_idx];
    try testing.expectEqual(MAX_SEGS, vm.dag_builder.getCirclePayload(node).segments);
}

test "Stdlib: CAD.config fixed_segments is clamped instead of UB" {
    var vm = try initVm();
    defer vm.deinit();
    const Case = struct { src: []const u8, expected: u32 };
    const cases = [_]Case{
        .{ .src = "CAD.config(manifold: { fixed_segments: 1e12 })", .expected = @intCast(MAX_SEGS) },
        .{ .src = "CAD.config(manifold: { fixed_segments: Number::INFINITY })", .expected = @intCast(MAX_SEGS) },
        .{ .src = "CAD.config(manifold: { fixed_segments: Number::NAN })", .expected = 0 },
        .{ .src = "CAD.config(manifold: { fixed_segments: -5 })", .expected = 0 },
    };
    for (cases) |case| {
        errdefer std.debug.print("script: {s}\n", .{case.src});
        try testing.expectEqual(InterpretResult.ok, try runOn(&vm, case.src));
        const config = vm.config_stack.items[vm.config_stack.items.len - 1];
        try testing.expectEqual(case.expected, config.manifold.fixed_segments);
    }
}

test "Stdlib: CAD.config brep counts are clamped instead of UB" {
    const defaults = engine_config.BRepConfig{};
    const Field = enum { min_circle_segments, max_newton_trials, max_marching_steps };
    const Case = struct { src: []const u8, field: Field, expected: u32 };
    const cases = [_]Case{
        .{ .src = "CAD.config(brep: { min_circle_segments: 1e12 })", .field = .min_circle_segments, .expected = @intCast(MAX_SEGS) },
        .{ .src = "CAD.config(brep: { min_circle_segments: Number::INFINITY })", .field = .min_circle_segments, .expected = @intCast(MAX_SEGS) },
        .{ .src = "CAD.config(brep: { min_circle_segments: -5 })", .field = .min_circle_segments, .expected = 0 },
        .{ .src = "CAD.config(brep: { min_circle_segments: 32.7 })", .field = .min_circle_segments, .expected = 32 },
        // NaN keeps the current value (0 is not an "auto" sentinel for these fields).
        .{ .src = "CAD.config(brep: { min_circle_segments: Number::NAN })", .field = .min_circle_segments, .expected = defaults.min_circle_segments },
        .{ .src = "CAD.config(brep: { max_newton_trials: 1e12 })", .field = .max_newton_trials, .expected = limits.MAX_NEWTON_TRIALS },
        .{ .src = "CAD.config(brep: { max_newton_trials: Number::NAN })", .field = .max_newton_trials, .expected = defaults.max_newton_trials },
        .{ .src = "CAD.config(brep: { max_newton_trials: 20 })", .field = .max_newton_trials, .expected = 20 },
        .{ .src = "CAD.config(brep: { max_marching_steps: Number::INFINITY })", .field = .max_marching_steps, .expected = limits.MAX_MARCHING_STEPS },
        .{ .src = "CAD.config(brep: { max_marching_steps: -Number::INFINITY })", .field = .max_marching_steps, .expected = 0 },
        .{ .src = "CAD.config(brep: { max_marching_steps: Number::NAN })", .field = .max_marching_steps, .expected = defaults.max_marching_steps },
        // CAD.with_config shares the same parsing path.
        .{ .src = "CAD.with_config({ brep: { max_marching_steps: 1e12 } }) do\n  1\nend", .field = .max_marching_steps, .expected = defaults.max_marching_steps },
    };
    for (cases) |case| {
        errdefer std.debug.print("script: {s}\n", .{case.src});
        var vm = try initVm();
        defer vm.deinit();
        try testing.expectEqual(InterpretResult.ok, try runOn(&vm, case.src));
        const brep = vm.config_stack.items[vm.config_stack.items.len - 1].brep;
        const actual = switch (case.field) {
            .min_circle_segments => brep.min_circle_segments,
            .max_newton_trials => brep.max_newton_trials,
            .max_marching_steps => brep.max_marching_steps,
        };
        try testing.expectEqual(case.expected, actual);
    }
}

test "Stdlib: Array#slice follows Ruby arr[start, len] semantics" {
    const nil: ?[]const f64 = null;
    const Case = struct { args: []const u8, expected: ?[]const f64 };
    const cases = [_]Case{
        .{ .args = "0, 2", .expected = &.{ 1, 2 } },
        // Negative starts count from the end (used to panic in @intFromFloat).
        .{ .args = "-1, 2", .expected = &.{3} },
        .{ .args = "-3, 2", .expected = &.{ 1, 2 } },
        .{ .args = "-4, 1", .expected = nil },
        .{ .args = "-Number::INFINITY, 1", .expected = nil },
        // Lengths are clamped to what is available (1e12 used to over-allocate).
        .{ .args = "1, 1e12", .expected = &.{ 2, 3 } },
        .{ .args = "1, Number::INFINITY", .expected = &.{ 2, 3 } },
        // start == size is an empty slice; past the end is nil.
        .{ .args = "3, 1", .expected = &.{} },
        .{ .args = "4, 1", .expected = nil },
        .{ .args = "1e12, 1", .expected = nil },
        .{ .args = "Number::INFINITY, 1", .expected = nil },
        .{ .args = "0, -1", .expected = nil },
        .{ .args = "0, 0", .expected = &.{} },
        .{ .args = "1.9, 1.9", .expected = &.{2} },
    };
    for (cases) |case| {
        var src_buf: [128]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, "r = [1, 2, 3].slice({s})", .{case.args});
        errdefer std.debug.print("script: {s}\n", .{src});
        var vm = try initVm();
        defer vm.deinit();
        try testing.expectEqual(InterpretResult.ok, try runOn(&vm, src));
        const r = vm.globals.get("r") orelse return error.MissingGlobal;
        const expected = case.expected orelse {
            try testing.expect(r.isNil());
            continue;
        };
        try testing.expect(r.isArray());
        const items = r.asArray().items.items;
        try testing.expectEqual(expected.len, items.len);
        for (expected, items) |e, item| try testing.expectEqual(e, item.asNumber());
    }
    try expectAll(.runtime_error, &.{
        "[1, 2, 3].slice(Number::NAN, 1)",
        "[1, 2, 3].slice(0, Number::NAN)",
    });
}

test "Stdlib: dimensions and sweep parameters reject NaN and inf" {
    try expectAll(.runtime_error, &.{
        "cube(Number::INFINITY - Number::INFINITY)",
        "sphere(Number::INFINITY)",
        "cylinder(r: Math.sqrt(-1), h: 1)",
        "square(10).extrude(Number::INFINITY - Number::INFINITY)",
        "square(10).extrude(5, twist: Number::INFINITY)",
        "square(10).extrude(5, scale: Number::NAN)",
        "square(10).helix(Number::INFINITY)",
        "square(10).helix(5, Number::NAN)",
        "square(10).translate(x: 20).revolve(Number::INFINITY - Number::INFINITY)",
        "square(10).loft(circle(r: 5), Number::INFINITY)",
    });
}

test "Stdlib: text tolerance cannot be vanishingly small" {
    try expectAll(.runtime_error, &.{
        // Degenerate: its square underflows to 0 in the Bezier flattening test.
        "text(\"A\", tolerance: 1e-300)",
        // The minimum is relative to the glyph size (0.05 is fine at the default size).
        "text(\"A\", size: 1000, tolerance: 0.05)",
    });
}

test "Stdlib: polyhedron and polygon path indices are bounds-checked" {
    try expectAll(.runtime_error, &.{
        "polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0,1]], [[0,1,2],[0,3,1],[0,2,3],[-1,2,3]])",
        "polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0,1]], [[0,1,2],[0,3,1],[0,2,3],[4,2,3]])",
        "polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0,1]], [[0,1,2],[0,3,1],[0,2,3],[Number::NAN,2,3]])",
        "polygon([[0,0],[1,0],[0,1]], paths: [[0,1,-1]])",
        "polygon([[0,0],[1,0],[0,1]], paths: [[0,1,1.5]])",
        // An error in a later path used to free the uninitialised contour slots.
        "polygon([[0,0],[1,0],[0,1]], paths: [[0,1,2],[0,1,3]])",
    });
}

test "Stdlib: repeat counts reject NaN and values above MAX_PATTERN_COUNT" {
    try expectAll(.runtime_error, &.{
        print("cube(1).repeat_linear({d}, [2, 0, 0])", .{MAX_COUNT + 1}),
        "cube(1).repeat_linear(Number::INFINITY, [2, 0, 0])",
        print("cube(1).repeat_polar({d})", .{MAX_COUNT + 1}),
        "cube(1).repeat_polar(Number::INFINITY - Number::INFINITY)",
    });
    // Negative counts are a no-op (they used to panic in @intFromFloat to usize).
    try expectAll(.ok, &.{
        "cube(1).repeat_linear(-5, [2, 0, 0])",
        "cube(1).repeat_polar(-5)",
    });
}

// --- Range iteration and Number#times/upto/downto ---

const MAX_MATERIALIZE = limits.MAX_RANGE_MATERIALIZE;

/// What a script leaves in the global `r`.
/// Kernel-computed quantities (volumes, bounds) are compared with this absolute tolerance.
const NUMBER_TOLERANCE = 1e-9;

const Expected = union(enum) {
    nums: []const f64,
    num: f64,
    boolean: bool,
    str: []const u8,
};

const IterCase = struct { src: []const u8, expected: Expected };

fn expectGlobalR(cases: []const IterCase) !void {
    for (cases) |case| {
        errdefer std.debug.print("script: {s}\n", .{case.src});
        var vm = try initVm();
        defer vm.deinit();
        try testing.expectEqual(InterpretResult.ok, try runOn(&vm, case.src));
        const r = vm.globals.get("r") orelse return error.MissingGlobal;
        switch (case.expected) {
            .nums => |want| {
                try testing.expect(r.isArray());
                const items = r.asArray().items.items;
                try testing.expectEqual(want.len, items.len);
                for (want, items) |w, item| try testing.expectApproxEqAbs(w, item.asNumber(), 1e-12);
            },
            .num => |want| try testing.expectApproxEqAbs(want, r.asNumber(), NUMBER_TOLERANCE),
            .boolean => |want| try testing.expectEqual(want, r.asBool()),
            .str => |want| {
                try testing.expect(r.isString());
                try testing.expectEqualStrings(want, r.asString().chars);
            },
        }
    }
}

test "Stdlib: Range#to_a and #step follow Ruby's step semantics" {
    try expectGlobalR(&.{
        .{ .src = "r = (0..3).to_a", .expected = .{ .nums = &.{ 0, 1, 2, 3 } } },
        .{ .src = "r = (0...3).to_a", .expected = .{ .nums = &.{ 0, 1, 2 } } },
        .{ .src = "r = (0..0).to_a", .expected = .{ .nums = &.{0} } },
        .{ .src = "r = (0...0).to_a", .expected = .{ .nums = &.{} } },
        .{ .src = "r = (5..1).to_a", .expected = .{ .nums = &.{} } },
        .{ .src = "r = (-2..1).to_a", .expected = .{ .nums = &.{ -2, -1, 0, 1 } } },
        .{ .src = "r = (1..10).step(3).to_a", .expected = .{ .nums = &.{ 1, 4, 7, 10 } } },
        .{ .src = "r = (0...9).step(3).to_a", .expected = .{ .nums = &.{ 0, 3, 6 } } },
        .{ .src = "r = (10..1).step(-3).to_a", .expected = .{ .nums = &.{ 10, 7, 4, 1 } } },
        .{ .src = "r = (10...0).step(-5).to_a", .expected = .{ .nums = &.{ 10, 5 } } },
        .{ .src = "r = (1..5).step(-1).to_a", .expected = .{ .nums = &.{} } },
        .{ .src = "r = (0..1).step(0.25).to_a", .expected = .{ .nums = &.{ 0, 0.25, 0.5, 0.75, 1 } } },
        // 0.3 / 0.1 is 2.9999999999999996: the epsilon allowance keeps the end value.
        .{ .src = "r = (0..0.3).step(0.1).to_a", .expected = .{ .nums = &.{ 0, 0.1, 0.2, 0.3 } } },
        .{ .src = "r = (0...0.3).step(0.1).to_a", .expected = .{ .nums = &.{ 0, 0.1, 0.2 } } },
        .{ .src = "r = (0..3).map { |i| i * i }", .expected = .{ .nums = &.{ 0, 1, 4, 9 } } },
        .{ .src = "r = []\n(0...3).each { |i| r.push(i) }", .expected = .{ .nums = &.{ 0, 1, 2 } } },
        .{ .src = "r = []\n(0..2).each { |i| (0..1).each { |j| r.push(i * 10 + j) } }", .expected = .{ .nums = &.{ 0, 1, 10, 11, 20, 21 } } },
    });
}

test "Stdlib: Range query methods" {
    try expectGlobalR(&.{
        .{ .src = "r = (0..3).size", .expected = .{ .num = 4 } },
        .{ .src = "r = (0...3).length", .expected = .{ .num = 3 } },
        .{ .src = "r = (5..1).count", .expected = .{ .num = 0 } },
        .{ .src = "r = (0..3).include?(3)", .expected = .{ .boolean = true } },
        .{ .src = "r = (0...3).include?(3)", .expected = .{ .boolean = false } },
        .{ .src = "r = (0..3).cover?(1.5)", .expected = .{ .boolean = true } },
        .{ .src = "r = (0..3).include?(-1)", .expected = .{ .boolean = false } },
        .{ .src = "r = (0..3).include?(\"1\")", .expected = .{ .boolean = false } },
        .{ .src = "r = (2..5).first", .expected = .{ .num = 2 } },
        .{ .src = "r = (2...5).last", .expected = .{ .num = 5 } },
        .{ .src = "r = (0...3).exclusive?", .expected = .{ .boolean = true } },
        .{ .src = "r = (0..3).exclusive?", .expected = .{ .boolean = false } },
        .{ .src = "r = (0...3).to_s", .expected = .{ .str = "0...3" } },
        .{ .src = "r = (0..2.5).to_s", .expected = .{ .str = "0..2.5" } },
        .{ .src = "r = (0..3).is_a?(Range)", .expected = .{ .boolean = true } },
        .{ .src = "r = (1..2).step(0.5).exclusive?", .expected = .{ .boolean = false } },
        .{ .src = "r = case (1..2)\n  when Range\n    \"range\"\n  else\n    \"other\"\nend", .expected = .{ .str = "range" } },
    });
}

test "Stdlib: Number#times, #upto and #downto" {
    try expectGlobalR(&.{
        .{ .src = "r = []\n3.times { |i| r.push(i) }", .expected = .{ .nums = &.{ 0, 1, 2 } } },
        .{ .src = "r = []\n0.times { |i| r.push(i) }", .expected = .{ .nums = &.{} } },
        .{ .src = "r = []\n(-2).times { |i| r.push(i) }", .expected = .{ .nums = &.{} } },
        .{ .src = "r = 3.times { }", .expected = .{ .num = 3 } },
        .{ .src = "r = []\n5.upto(7) { |i| r.push(i) }", .expected = .{ .nums = &.{ 5, 6, 7 } } },
        .{ .src = "r = []\n5.upto(3) { |i| r.push(i) }", .expected = .{ .nums = &.{} } },
        .{ .src = "r = []\n3.downto(1) { |i| r.push(i) }", .expected = .{ .nums = &.{ 3, 2, 1 } } },
        .{ .src = "r = []\n1.downto(3) { |i| r.push(i) }", .expected = .{ .nums = &.{} } },
        .{ .src = "r = 2.upto(4) { }", .expected = .{ .num = 2 } },
    });
}

test "Stdlib: break, next, return and exceptions inside range and times blocks" {
    try expectGlobalR(&.{
        // `break value` becomes the method's return value; without break, each returns the receiver.
        .{ .src = "r = (0..5).each { |i| break i * 10 if i == 2 }", .expected = .{ .num = 20 } },
        .{ .src = "r = (0..5).map { |i| break 42 if i == 3\n i }", .expected = .{ .num = 42 } },
        .{ .src = "r = 10.times { |i| break i if i == 4 }", .expected = .{ .num = 4 } },
        .{ .src = "r = (0..2).each { |i| }.to_s", .expected = .{ .str = "0..2" } },
        .{ .src = "r = []\n(0..4).each { |i| next if i % 2 == 1\n r.push(i) }", .expected = .{ .nums = &.{ 0, 2, 4 } } },
        .{ .src = "r = (0..3).map { |i| next 0 if i == 1\n i }", .expected = .{ .nums = &.{ 0, 0, 2, 3 } } },
        .{ .src = "r = begin\n  (0..3).each { |i| raise \"boom\" if i == 2 }\nrescue => e\n  e.message\nend", .expected = .{ .str = "boom" } },
        .{ .src = "r = []\nbegin\n  (0..3).map { |i| r.push(i)\n raise \"stop\" if i == 1\n i }\nrescue => e\n  r.push(99)\nend", .expected = .{ .nums = &.{ 0, 1, 99 } } },
    });
    // `return` inside a block leaves only the block in KupCAD (same as Array#each);
    // this guards that it unwinds cleanly through the native loop.
    try expectAll(.ok, &.{
        "def f(limit)\n  (0..limit).each { |i| return i if i > 2 }\n  -1\nend\nf(10)",
        "def g\n  3.times { |i| return i }\n  0\nend\ng()",
    });
}

test "Stdlib: range and times errors are rescuable with their class and real message" {
    const max_mat = std.fmt.comptimePrint("{d}", .{MAX_MATERIALIZE});
    const cases = [_]struct { src: []const u8, prefix: []const u8 }{
        .{ .src = "2.5.times { }", .prefix = "ValueError: times requires an integer" },
        .{ .src = "(Number::INFINITY - Number::INFINITY).times { }", .prefix = "ValueError: times requires an integer" },
        .{ .src = "3.times", .prefix = "ArgumentError: times requires a block" },
        .{ .src = "(0..3).each", .prefix = "ArgumentError: Range#each requires a block" },
        .{ .src = "(0..3).map", .prefix = "ArgumentError: Range#map requires a block" },
        .{ .src = "(0..3).step(0)", .prefix = "ValueError: Range#step requires a finite, non-zero step" },
        .{ .src = "(0..3).step(Number::INFINITY)", .prefix = "ValueError: Range#step requires a finite, non-zero step" },
        .{ .src = "(0..Number::INFINITY).to_a", .prefix = "ValueError: Range#to_a requires finite bounds" },
        .{ .src = "(0..(Number::INFINITY - Number::INFINITY)).size", .prefix = "ValueError: Range#size requires finite bounds" },
        .{ .src = "1.upto(2.5) { }", .prefix = "ValueError: upto requires an integer" },
        .{ .src = "1.5.downto(0) { }", .prefix = "ValueError: downto requires an integer" },
        // Building an array one past the cap is rejected before anything is allocated.
        .{ .src = "(0.." ++ max_mat ++ ").to_a", .prefix = "ValueError: Range#to_a would build an array" },
        .{ .src = "(0.." ++ max_mat ++ ").map { |i| i }", .prefix = "ValueError: Range#map would build an array" },
        .{ .src = "(0..1e12).to_a", .prefix = "ValueError: Range#to_a would build an array" },
        // Past 2^53 the values stop being distinct floats, so iteration would be wrong.
        .{ .src = "(0..1e17).each { |i| }", .prefix = "ValueError: Range#each would iterate" },
        .{ .src = "1e17.times { }", .prefix = "ValueError: times would iterate" },
    };
    for (cases) |case| {
        var src_buf: [4096]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, "r = begin\n  {s}\n  \"no error\"\n" ++ RESCUE_BY_KIND ++ "end", .{case.src});
        errdefer std.debug.print("script: {s}\n", .{src});
        var vm = try initVm();
        defer vm.deinit();
        try testing.expectEqual(InterpretResult.ok, try runOn(&vm, src));
        const r = vm.globals.get("r") orelse return error.MissingGlobal;
        try testing.expect(r.isString());
        try testing.expect(std.mem.startsWith(u8, r.asString().chars, case.prefix));
    }
    // Uncaught, the same errors fail the script.
    try expectAll(.runtime_error, &.{ "2.5.times { }", "(0..3).each", "(0..3).step(0)" });
}

test "Stdlib: block iteration is not capped, only array building is" {
    try expectGlobalR(&.{
        // Far past the array cap: each/times/upto run until the block breaks out.
        .{ .src = "r = (0..1e12).each { |i| break i if i == 5 }", .expected = .{ .num = 5 } },
        .{ .src = "r = 1e12.times { |i| break i if i == 3 }", .expected = .{ .num = 3 } },
        .{ .src = "r = 0.upto(1e12) { |i| break i if i == 7 }", .expected = .{ .num = 7 } },
        .{ .src = "r = 1e12.downto(0) { |i| break i if i < 1e12 - 2 }", .expected = .{ .num = 1e12 - 3 } },
        // size is arithmetic, so it has no cap at all.
        .{ .src = "r = (0..1e12).size", .expected = .{ .num = 1e12 + 1 } },
        .{ .src = "r = (1.." ++ std.fmt.comptimePrint("{d}", .{MAX_MATERIALIZE}) ++ ").size", .expected = .{ .num = @floatFromInt(MAX_MATERIALIZE) } },
    });
}

test "Stdlib: the instruction budget stops an uncapped range loop" {
    // Without a count cap, the instruction budget (and cancellation, checked in the same
    // loop) is what bounds `(0..1e12).each`: every block call goes through the dispatch loop.
    const budget = 10_000;
    for ([_][]const u8{ "(0..1e12).each { |i| }", "1e12.times { }", "0.upto(1e12) { }" }) |src| {
        errdefer std.debug.print("script: {s}\n", .{src});
        var vm = try initVm();
        defer vm.deinit();
        vm.instruction_limit = budget;
        // Same outcome as a runaway `while` loop under the same budget.
        try testing.expectEqual(InterpretResult.execution_limit_exceeded, try runOn(&vm, src));
        try testing.expect(vm.instruction_count > budget);
    }
}

test "Stdlib: the docs (0...3).each example builds three pegs" {
    try expectGlobalR(&.{.{
        .src =
        \\pegs = []
        \\(0...3).each do |row|
        \\  pegs.push(cylinder(r: 2, h: 10).translate(x: row * 10))
        \\end
        \\r = pegs.length
        ,
        .expected = .{ .num = 3 },
    }});
}

test "Stdlib: named functions are called by name, callable values with .call" {
    const not_by_name = "TypeError: a lambda is called with .call(...), not like a function";
    try expectGlobalR(&.{
        // The README's Lambdas example.
        .{ .src = "double = ->(x) { x * 2 }\ndef apply(f, v)\n  f.call(v)\nend\nr = [double.call(4), apply(double, 5)]", .expected = .{ .nums = &.{ 8, 10 } } },
        .{ .src = "plate = ->(w, h = 10, thickness: 2) do\n  cube(x: w, y: h, z: thickness)\nend\nr = plate.call(30, thickness: 3).volume", .expected = .{ .num = 900 } },
        // Like any method call, `.call` needs no parentheses; a bare name is the lambda itself.
        .{ .src = "f = -> { 2 }\nr = f.call", .expected = .{ .num = 2 } },
        .{ .src = "f = -> { 2 }\ng = f\nr = g.call + 1", .expected = .{ .num = 3 } },
        .{ .src = "f = -> { 2 }\nr = \"#{f}\"", .expected = .{ .str = "<Function>" } },
        // Calling a lambda like a function used to work, so `f` and `f()` meant different things.
        .{ .src = comptime rescued("f = ->(x) { x }\n  f(3)"), .expected = .{ .str = not_by_name } },
        .{ .src = comptime rescued("f = ->(x) { x }\n  f 3"), .expected = .{ .str = not_by_name } },
        .{ .src = comptime rescued("f = -> { 1 }\n  f()"), .expected = .{ .str = not_by_name } },
        // A captured block is a lambda too; `yield` still calls it implicitly.
        .{ .src = "def m(&blk)\n  blk.call(2)\nend\nr = m { |x| x * 3 }", .expected = .{ .num = 6 } },
        .{ .src = comptime rescued("def m(&blk)\n    blk(2)\n  end\n  m { |x| x }"), .expected = .{ .str = not_by_name } },
        .{ .src = "def m\n  yield 2\nend\nr = m { |x| x * 3 }", .expected = .{ .num = 6 } },
        // So is a bound method.
        .{ .src = "class C\n  def g(n)\n    n + 1\n  end\nend\nm = C.new.method(:g)\nr = m.call(4)", .expected = .{ .num = 5 } },
        .{ .src = comptime rescued("class C\n    def g\n      1\n    end\n  end\n  m = C.new.method(:g)\n  m(1)"), .expected = .{ .str = "TypeError: a bound method is called with .call(...), not like a function" } },
        // Named functions (defs and built-ins) are called by name, with or without parentheses.
        .{ .src = "def foo\n  2\nend\nr = [foo, foo()]", .expected = .{ .nums = &.{ 2, 2 } } },
        .{ .src = "def twice(n)\n  n * 2\nend\nr = twice 4", .expected = .{ .num = 8 } },
        // A bare `cube` used to be the function value itself rather than a cube.
        .{ .src = "r = cube.volume", .expected = .{ .num = 1 } },
        .{ .src = "def f(cube)\n  cube\nend\nr = f(5)", .expected = .{ .num = 5 } },
        // Lambdas are the only callables.
        .{ .src = comptime rescued("proc { |x| x }"), .expected = .{ .str = "NameError: Undefined variable 'proc'" } },
        .{ .src = comptime rescued("Proc.new { |x| x }"), .expected = .{ .str = "NoMethodError: undefined method 'new' for Proc; KupCAD makes them with lambdas: ->(x) { ... }" } },
        .{ .src = comptime rescued("lambda { |x| x }"), .expected = .{ .str = "NameError: Undefined variable 'lambda'" } },
    });
}

test "Stdlib: a *rest parameter that gets no arguments is empty" {
    // Padding used to fill the splat's slot with nil, so `rest` was [nil].
    try expectGlobalR(&.{
        .{ .src = "def g(*rest)\n  rest\nend\nr = g().length", .expected = .{ .num = 0 } },
        .{ .src = "def g(a, *rest)\n  rest\nend\nr = g(1).length", .expected = .{ .num = 0 } },
        .{ .src = "def g(a, *rest)\n  [a.nil?, rest.length]\nend\nr = \"#{g()}\"", .expected = .{ .str = "[true, 0]" } },
        .{ .src = "def g(*rest, last)\n  [rest.length, last]\nend\nr = g(1)", .expected = .{ .nums = &.{ 0, 1 } } },
        .{ .src = "def g(*rest, o: 1)\n  [rest.length, o]\nend\nr = g(o: 5)", .expected = .{ .nums = &.{ 0, 5 } } },
        .{ .src = "f = ->(*xs) { xs.length }\nr = f.call", .expected = .{ .num = 0 } },
        .{ .src = "def g(*rest)\n  rest\nend\nr = g(1, 2)", .expected = .{ .nums = &.{ 1, 2 } } },
    });
}

test "Stdlib: *splat, **hash and &blk spread into any call" {
    const sum2 = "def g(a, b)\n  a + b\nend\n";
    try expectGlobalR(&.{
        // `*arr` used to arrive as one Array argument.
        .{ .src = sum2 ++ "r = g(*[1, 2])", .expected = .{ .num = 3 } },
        .{ .src = "def g(a, b, c, d)\n  [a, b, c, d]\nend\nr = g(1, *[2, 3], 4)", .expected = .{ .nums = &.{ 1, 2, 3, 4 } } },
        .{ .src = "def g(a, b, k: 0)\n  a + b + k\nend\nr = g(*[1, 2], k: 10)", .expected = .{ .num = 13 } },
        .{ .src = sum2 ++ "def h(*xs)\n  g(*xs) { 0 }\nend\nr = h(1, 2)", .expected = .{ .num = 3 } },
        .{ .src = "def g(first, *rest)\n  rest\nend\nr = g(*[1, 2, 3])", .expected = .{ .nums = &.{ 2, 3 } } },
        .{ .src = "def g(*rest)\n  rest.length\nend\nr = g(*[])", .expected = .{ .num = 0 } },
        .{ .src = "f = ->(a, b) { a * b }\nr = f.call(*[3, 4])", .expected = .{ .num = 12 } },
        .{ .src = "r = cube(*[2, 3, 4]).volume", .expected = .{ .num = 24 } },
        .{ .src = "r = [1].push(*[2, 3])", .expected = .{ .nums = &.{ 1, 2, 3 } } },
        .{ .src = "r = [1].push(2, 3)", .expected = .{ .nums = &.{ 1, 2, 3 } } },
        .{ .src = "class P\n  def initialize(a, b)\n    @s = a + b\n  end\n  def s\n    @s\n  end\nend\nr = P.new(*[1, 2]).s", .expected = .{ .num = 3 } },
        .{ .src = "class A\n  def m(a, b)\n    a + b\n  end\nend\nclass B < A\n  def m(*args)\n    super(*args)\n  end\nend\nr = B.new.m(1, 2)", .expected = .{ .num = 3 } },
        .{ .src = "def g\n  yield(*[1, 2])\nend\nr = g { |a, b| a + b }", .expected = .{ .num = 3 } },
        .{ .src = "def g\n  yield *[1, 2]\nend\nr = g { |a, b| a * b }", .expected = .{ .num = 2 } },
        .{ .src = comptime rescued(sum2 ++ "  g(*5)"), .expected = .{ .str = "TypeError: only an Array can be spread with *" } },
        // `**hash` used to arrive as a positional argument.
        .{ .src = "def g(a:, b: 2)\n  a * 10 + b\nend\nopts = { a: 1 }\nr = [g(**opts), g(**opts, b: 5)]", .expected = .{ .nums = &.{ 12, 15 } } },
        .{ .src = comptime rescued("def g(a: 1)\n    a\n  end\n  g(**[1])"), .expected = .{ .str = "TypeError: only a Map can be spread with **" } },
        // `&blk` used to be dropped, so the method saw no block.
        .{ .src = "def g\n  yield 2\nend\nf = ->(x) { x * 3 }\nr = g(&f)", .expected = .{ .num = 6 } },
        .{ .src = "f = ->(x) { x * 3 }\nr = [1, 2].map(&f)", .expected = .{ .nums = &.{ 3, 6 } } },
        .{ .src = "def g(&b)\n  b.nil?\nend\nr = g(&nil)", .expected = .{ .boolean = true } },
        .{ .src = comptime rescued("def g\n    yield\n  end\n  g(&5)"), .expected = .{ .str = "TypeError: a block argument (&blk) must be a lambda or a block" } },
        // A lambda as the last argument used to be taken for the block, leaving the parameter nil.
        .{ .src = "def apply(v, f)\n  f.call(v)\nend\nr = apply(5, ->(x) { x * 2 })", .expected = .{ .num = 10 } },
        .{ .src = "def keep(f)\n  f\nend\nr = keep(-> { 1 }).call", .expected = .{ .num = 1 } },
        .{ .src = "def both(f, &b)\n  f.call + b.call\nend\nr = both(-> { 1 }) { 10 }", .expected = .{ .num = 11 } },
    });
}

test "Stdlib: every value answers class and inspect" {
    try expectGlobalR(&.{
        // `x.class` was a syntax error (`class` lexed as the keyword) and `inspect` didn't exist.
        .{ .src = "r = 5.class == Number", .expected = .{ .boolean = true } },
        .{ .src = "r = \"#{[1].class} #{\"s\".class}\"", .expected = .{ .str = "Array String" } },
        .{ .src = "class Foo\nend\nr = Foo.new.class == Foo", .expected = .{ .boolean = true } },
        .{ .src = "r = \"a\".inspect", .expected = .{ .str = "\"a\"" } },
        .{ .src = "r = [1, \"a\", :b, nil, 2.5].inspect", .expected = .{ .str = "[1, \"a\", :b, nil, 2.5]" } },
        .{ .src = "r = { x: 1, \"y\" => [2] }.inspect", .expected = .{ .str = "{x: 1, \"y\" => [2]}" } },
        .{ .src = "class Foo\nend\nr = Foo.new.inspect", .expected = .{ .str = "#<Foo>" } },
        .{ .src = "class Foo\n  def inspect\n    \"custom\"\n  end\nend\nr = Foo.new.inspect", .expected = .{ .str = "custom" } },
        // Values without a class of their own still get Object's methods.
        .{ .src = "r = nil.inspect", .expected = .{ .str = "nil" } },
        .{ .src = "r = nil.class == NilClass", .expected = .{ .boolean = true } },
        .{ .src = "f = -> { 1 }\nr = f.inspect", .expected = .{ .str = "<Function>" } },
        // Any keyword names a method after a dot.
        .{ .src = "class R\n  def end\n    7\n  end\nend\nr = R.new.end", .expected = .{ .num = 7 } },
    });
}

test "Stdlib: a method name takes -1, *xs, &blk and [..] as its argument; a variable doesn't" {
    // `f -1` used to subtract 1 from f's result, and `f *xs` multiplied.
    const defs = "def f(a = 10) = a\ndef inc(a) = a + 1\ndef count(*a) = a.length\n";
    try expectGlobalR(&.{
        .{ .src = defs ++ "r = [(f -1), f - 1, f-1]", .expected = .{ .nums = &.{ -1, 9, 9 } } },
        .{ .src = defs ++ "xs = [1, 2, 3]\nr = count *xs", .expected = .{ .num = 3 } },
        .{ .src = defs ++ "sq = ->(v) { v * v }\nr = [2, 3].map &sq", .expected = .{ .nums = &.{ 4, 9 } } },
        .{ .src = defs ++ "r = count [4, 5]", .expected = .{ .num = 1 } },
        // `inc (1) * 3` is inc(3); it used to be inc(1) * 3. Like Ruby, a call without
        // parentheses takes every argument after it, so `[f -1, 2]` is `[f(-1, 2)]`.
        .{ .src = defs ++ "r = [(inc (1) * 3), inc(1) * 3]", .expected = .{ .nums = &.{ 4, 6 } } },
        // A variable before the same tokens is arithmetic or indexing, wherever it was bound.
        .{ .src = "x = 10\nn = 2\npts = [7, 8]\nr = [x -1, n *3, pts [1], n &3]", .expected = .{ .nums = &.{ 9, 6, 8, 2 } } },
        .{ .src = "def g(v) = v -1\nr = g(5)", .expected = .{ .num = 4 } },
        .{ .src = "def k(a, b = a -1) = b\nr = k(5)", .expected = .{ .num = 4 } },
        .{ .src = "h = ->(v) { v -1 }\nr = [5].map { |v| v -1 } + [h.call(5)]", .expected = .{ .nums = &.{ 4, 4 } } },
        .{ .src = "a, b = 5, 6\nr = b -1", .expected = .{ .num = 5 } },
        .{ .src = "if true\n  y = 10\nend\nr = y -1", .expected = .{ .num = 9 } },
        .{ .src = "w = 3\ndef width = w -1\nr = width", .expected = .{ .num = 2 } },
        .{ .src = "W = 5\nr = W -1", .expected = .{ .num = 4 } },
        .{ .src = "class C\n  def initialize\n    @v = 5\n  end\n  def get = @v -1\nend\nr = C.new.get", .expected = .{ .num = 4 } },
        // A block's parameter ends with the block: after it, `f` is the method again.
        .{ .src = defs ++ "[1].each { |f| f }\nr = f -1", .expected = .{ .num = -1 } },
    });
}

test "Stdlib: each primitive's Signature lists exactly the keywords it accepts" {
    // `kupcad check` reads the Signature; a keyword added to a primitive but not to it would
    // drift silently. The unknown-keyword error lists what the primitive really accepts.
    const manifest = @import("manifest.zig");
    var checked: usize = 0;
    inline for (manifest.global_functions) |f| {
        if (f.signature) |sig| {
            const call = if (comptime std.mem.eql(u8, f.name, "text")) "text(\"A\", zz_unknown: 1)" else f.name ++ "(zz_unknown: 1)";
            comptime var accepted: []const u8 = "";
            inline for (sig.keywords, 0..) |k, i| accepted = accepted ++ (if (i == 0) "" else ", ") ++ k;
            try expectGlobalR(&.{.{
                .src = comptime rescued(call),
                .expected = .{ .str = "ArgumentError: " ++ f.name ++ " does not take a keyword 'zz_unknown' (it accepts: " ++ accepted ++ ")" },
            }});
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 8), checked);
}

test "Stdlib: for walks an Array, a Range or a Map, as Ruby's does" {
    // `for` was a syntax error.
    try expectGlobalR(&.{
        .{ .src = "r = []\nfor x in [3, 1, 2]\n  r.push(x * 10)\nend", .expected = .{ .nums = &.{ 30, 10, 20 } } },
        // Ranges yield what Range#each does: exclusive ends, steps, negative steps, floats.
        .{ .src = "r = []\nfor i in 0...3\n  r.push(i)\nend", .expected = .{ .nums = &.{ 0, 1, 2 } } },
        .{ .src = "r = []\nfor i in (0..1).step(0.25)\n  r.push(i)\nend", .expected = .{ .nums = &.{ 0, 0.25, 0.5, 0.75, 1 } } },
        .{ .src = "r = []\nfor i in (3..1).step(-1)\n  r.push(i)\nend", .expected = .{ .nums = &.{ 3, 2, 1 } } },
        // A Map yields [key, value] pairs; several variables spread each element.
        .{ .src = "r = []\nfor k, v in { a: 1, b: 2 }\n  r.push(\"#{k.to_s}#{v}\")\nend\nr = r.join(\",\")", .expected = .{ .str = "a1,b2" } },
        .{ .src = "r = 0\nfor x, y in [[1, 2], [3, 4]]\n  r += x * y\nend", .expected = .{ .num = 14 } },
        .{ .src = "r = []\nfor head, *tail in [[1, 2, 3]]\n  r = tail\nend", .expected = .{ .nums = &.{ 2, 3 } } },
        // One variable takes the element whole.
        .{ .src = "r = nil\nfor pair in [[1, 2]]\n  r = pair\nend", .expected = .{ .nums = &.{ 1, 2 } } },
        // Nested loops.
        .{ .src = "r = []\nfor i in 1..2\n  for j in 1..2\n    r.push(i * 10 + j)\n  end\nend", .expected = .{ .nums = &.{ 11, 12, 21, 22 } } },
        // An Array is read live, so elements pushed during the loop are visited too.
        .{ .src = "a = [1]\nr = []\nfor x in a\n  a.push(x + 1) if x < 3\n  r.push(x)\nend", .expected = .{ .nums = &.{ 1, 2, 3 } } },
    });
}

test "Stdlib: for's value, break, next and return behave as in Ruby" {
    try expectGlobalR(&.{
        // The loop's value is what it iterated, or what break passes.
        .{ .src = "r = for x in [1, 2]\nend", .expected = .{ .nums = &.{ 1, 2 } } },
        .{ .src = "r = for x in [1, 2, 3]\n  break x * 10 if x == 2\nend", .expected = .{ .num = 20 } },
        .{ .src = "r = []\nfor i in 0...6\n  next if i % 2 == 1\n  r.push(i)\nend", .expected = .{ .nums = &.{ 0, 2, 4 } } },
        // return leaves the method, not just the loop (a block's return is block-local).
        .{ .src = "def f\n  for i in 1..5\n    return i if i == 3\n  end\n  0\nend\nr = f", .expected = .{ .num = 3 } },
        // No scope: the variables stay, at the top level and in a method.
        .{ .src = "for i in [7, 8]\nend\nr = i", .expected = .{ .num = 8 } },
        .{ .src = "def g\n  for a, b in [[1, 2]]\n    c = a + b\n  end\n  [a, b, c]\nend\nr = g", .expected = .{ .nums = &.{ 1, 2, 3 } } },
        .{ .src = "f = ->(xs) {\n  t = 0\n  for x in xs\n    t += x\n  end\n  t\n}\nr = f.call([1, 2, 3])", .expected = .{ .num = 6 } },
        // An empty iterable runs nothing.
        .{ .src = "r = 5\nfor x in []\n  r = 0\nend", .expected = .{ .num = 5 } },
    });
}

test "Stdlib: for rejects what it can't iterate" {
    try expectGlobalR(&.{
        .{ .src = comptime rescued("for x in 5\n  end"), .expected = .{ .str = "TypeError: for expects an Array, a Range or a Map, got Number" } },
        .{ .src = comptime rescued("for x in \"abc\"\n  end"), .expected = .{ .str = "TypeError: for expects an Array, a Range or a Map, got String" } },
        .{ .src = comptime rescued("for x in 1..Number::INFINITY\n  end"), .expected = .{ .str = "ValueError: for requires finite bounds and step, got 1..Infinity step 1" } },
    });
}

test "Stdlib: a Symbol reads as its name, and inspects with its colon" {
    // Interpolation, join and puts kept the colon: "#{:m3}" was ":m3".
    try expectGlobalR(&.{
        .{ .src = "r = \"#{:m3} #{[:a, :b].join(\"-\")} #{:c.to_s}\"", .expected = .{ .str = "m3 a-b c" } },
        .{ .src = "r = \"#{:m3.inspect} #{[:a].inspect} #{{ k: :v }.inspect}\"", .expected = .{ .str = ":m3 [:a] {k: :v}" } },
    });
}

test "Stdlib: respond_to? has Ruby's name" {
    // It was spelled `responds_to?`.
    try expectGlobalR(&.{
        .{ .src = "r = \"#{[1].respond_to?(:push)} #{1.respond_to?(\"push\")} #{Array.respond_to?(:new)}\"", .expected = .{ .str = "true false true" } },
        .{ .src = comptime rescued("1.responds_to?(:abs)"), .expected = .{ .str = "NoMethodError: undefined method 'responds_to?' for Number" } },
    });
}

test "Stdlib: an implicit super spreads the method's *rest back into arguments" {
    // `super` with no arguments used to pass `*xs` as one Array argument.
    const classes =
        \\class A
        \\  def m(*xs)
        \\    xs
        \\  end
        \\  def n(a, *xs, k: 0)
        \\    [a, xs.length, k]
        \\  end
        \\  def o(*xs)
        \\    yield(xs.length)
        \\  end
        \\end
        \\class B < A
        \\  def m(*xs)
        \\    super
        \\  end
        \\  def n(a, *xs, k: 0)
        \\    super
        \\  end
        \\  def o(*xs)
        \\    super
        \\  end
        \\end
        \\
    ;
    try expectGlobalR(&.{
        .{ .src = classes ++ "r = B.new.m(1, 2, 3)", .expected = .{ .nums = &.{ 1, 2, 3 } } },
        .{ .src = classes ++ "r = B.new.m.length", .expected = .{ .num = 0 } },
        .{ .src = classes ++ "r = B.new.n(1, 2, 3, k: 9)", .expected = .{ .nums = &.{ 1, 2, 9 } } },
        .{ .src = classes ++ "r = B.new.n(1)", .expected = .{ .nums = &.{ 1, 0, 0 } } },
        .{ .src = classes ++ "r = B.new.o(1, 2) { |c| c * 100 }", .expected = .{ .num = 200 } },
    });
}

test "Stdlib: built-in methods check their argument count, types and block" {
    try expectGlobalR(&.{
        // Extra arguments used to be dropped silently and missing ones were a generic error.
        .{ .src = comptime rescued("Math.sqrt(4, 9)"), .expected = .{ .str = "ArgumentError: Math.sqrt expects 1 argument, got 2" } },
        .{ .src = comptime rescued("Math.sqrt()"), .expected = .{ .str = "ArgumentError: Math.sqrt expects 1 argument, got 0" } },
        .{ .src = comptime rescued("Math.clamp(1)"), .expected = .{ .str = "ArgumentError: Math.clamp expects 3 arguments, got 1" } },
        .{ .src = comptime rescued("[1].each(5) { |x| x }"), .expected = .{ .str = "ArgumentError: Array#each expects 0 arguments, got 1" } },
        .{ .src = comptime rescued("assert(true, \"a\", AssertionError, 4)"), .expected = .{ .str = "ArgumentError: assert expects 1 to 3 arguments, got 4" } },
        // Wrong types name the method and the argument.
        .{ .src = comptime rescued("Math.sqrt(\"x\")"), .expected = .{ .str = "TypeError: Math.sqrt expects a number for argument 1, got String" } },
        .{ .src = comptime rescued("Math.min(1, \"a\")"), .expected = .{ .str = "TypeError: Math.min expects a number for argument 2, got String" } },
        .{ .src = comptime rescued("5.is_a?(3)"), .expected = .{ .str = "TypeError: is_a? expects a Class for argument 1, got Number" } },
        .{ .src = comptime rescued("CAD.config(5)"), .expected = .{ .str = "TypeError: CAD.config expects a Map for argument 1, got Number" } },
        .{ .src = comptime rescued("assert(false, 5)"), .expected = .{ .str = "TypeError: assert expects a String for its message, got Number" } },
        .{ .src = comptime rescued("union([cube(1), 2])"), .expected = .{ .str = "TypeError: union expects only Solids, got Number at index 1" } },
        // A block a method needs is required; a lambda argument is never taken for it.
        .{ .src = comptime rescued("[1].each"), .expected = .{ .str = "ArgumentError: Array#each requires a block" } },
        .{ .src = comptime rescued("benchmark(\"x\")"), .expected = .{ .str = "ArgumentError: benchmark requires a block" } },
        .{ .src = comptime rescued("f = ->(x) { x }\n  [1].map(f)"), .expected = .{ .str = "ArgumentError: Array#map expects 0 arguments, got 1" } },
        .{ .src = comptime rescued("f = -> { 1 }\n  CAD.with_config({}, f)"), .expected = .{ .str = "ArgumentError: CAD.with_config expects 1 argument, got 2" } },
        .{ .src = "f = ->(x) { x * 2 }\nr = [1, 2].map(&f)", .expected = .{ .nums = &.{ 2, 4 } } },
        .{ .src = "r = [].push(-> { 1 }, -> { 2 }).length", .expected = .{ .num = 2 } },
        // Valid calls are unchanged.
        .{ .src = "r = \"#{[Math.sqrt(9), Math.clamp(5, 0, 3), Math.min(3, 1, 2), Math.max]}\"", .expected = .{ .str = "[3, 3, 1, nil]" } },
        .{ .src = comptime rescued("assert(false, \"boom\")"), .expected = .{ .str = "AssertionError: boom" } },
        .{ .src = comptime rescued("assert(false) { \"lazy\" }"), .expected = .{ .str = "AssertionError: lazy" } },
        .{ .src = "r = benchmark(\"x\") { 5 }", .expected = .{ .num = 5 } },
    });
}

test "Stdlib: errors carry their real cause, never a generic message" {
    // Each used to be "CAD Kernel / Method Error" or "Native Execution Error" (or, for a
    // Sketch passed where a Solid was assumed, undefined behaviour).
    try expectGlobalR(&.{
        .{ .src = comptime rescued("nil.foo"), .expected = .{ .str = "NoMethodError: undefined method 'foo' for nil" } },
        .{ .src = comptime rescued("cube(1).extrude(1)"), .expected = .{ .str = "NoMethodError: undefined method 'extrude' for Geometry" } },
        .{ .src = comptime rescued("square(1).volume"), .expected = .{ .str = "NoMethodError: undefined method 'volume' for CrossSection" } },
        .{ .src = comptime rescued("square(1).genus"), .expected = .{ .str = "NoMethodError: undefined method 'genus' for CrossSection" } },
        .{ .src = comptime rescued("square(1).decompose"), .expected = .{ .str = "NoMethodError: undefined method 'decompose' for CrossSection" } },
        .{ .src = comptime rescued("square(1).export_stl(\"a.stl\")"), .expected = .{ .str = "NoMethodError: undefined method 'export_stl' for CrossSection" } },
        .{ .src = comptime rescued("cube(1).align(5, \"x\", \"min\")"), .expected = .{ .str = "TypeError: align expects a Geometry or CrossSection to align to, got Number" } },
        .{ .src = comptime rescued("import_step(\"a.step\")"), .expected = .{ .str = "NotImplementedError: import_step is not supported yet" } },
        // Operators name themselves and both operands.
        .{ .src = comptime rescued("[1] + nil"), .expected = .{ .str = "TypeError: '+' can't combine Array and nil" } },
        .{ .src = comptime rescued("\"a\" * 2"), .expected = .{ .str = "TypeError: '*' can't combine String and Number" } },
        .{ .src = comptime rescued("cube(1) | cube(1)"), .expected = .{ .str = "TypeError: '|' can't combine Geometry and Geometry" } },
        .{ .src = comptime rescued("-\"a\""), .expected = .{ .str = "TypeError: unary '-' expects a number, got String" } },
        .{ .src = comptime rescued("(1..nil)"), .expected = .{ .str = "TypeError: a range needs numbers or single characters, got Number..nil" } },
        // param checks its keywords, and its failures are typed.
        .{ .src = comptime rescued("param(:w, defualt: 5)"), .expected = .{ .str = "ArgumentError: param does not take a keyword 'defualt' (it accepts: default, validate)" } },
        .{ .src = comptime rescued("param(:w, default: 5, validate: { minimum: 1 })"), .expected = .{ .str = "ArgumentError: param validate does not take a keyword 'minimum' (it accepts: min, max, in)" } },
        .{ .src = comptime rescued("param(:w, default: 5, validate: { max: 3 })"), .expected = .{ .str = "ValueError: parameter :w value 5 is above its maximum 3" } },
        .{ .src = comptime rescued("param(:missing)"), .expected = .{ .str = "NameError: parameter :missing is used before it is defined" } },
        .{ .src = comptime rescued("assemble(name: 5, parts: [])"), .expected = .{ .str = "TypeError: assemble expects a String for name, got Number" } },
        // center works on a Sketch: it used to evaluate the Sketch as a Solid.
        .{ .src = "r = square(2).center.extrude(1).bbox.min", .expected = .{ .nums = &.{ -1, -1, 0 } } },
        .{ .src = "r = square(2).align(square(4), \"xy\", \"max\").extrude(1).bbox.min", .expected = .{ .nums = &.{ 2, 2, 0 } } },
    });
}

test "Stdlib: a deep backtrace lists its innermost and outermost frames only" {
    // A stack overflow used to print and allocate all ~100,000 frames.
    const deep = "def f(n)\n  raise \"deep\" if n == 0\n  f(n - 1)\nend\nr = begin\n  f(100)\nrescue => e\n  ";
    try expectGlobalR(&.{
        // 102 frames (the script and 101 calls of f): 16 + the omission line + 16.
        .{ .src = deep ++ "e.backtrace.length\nend", .expected = .{ .num = 33 } },
        .{ .src = deep ++ "e.backtrace[16]\nend", .expected = .{ .str = "    ... 70 frames omitted ..." } },
        .{ .src = deep ++ "e.backtrace[32].split(\":\").last\nend", .expected = .{ .str = "in 'script'" } },
        .{ .src = deep ++ "e.backtrace[0].split(\":\").last\nend", .expected = .{ .str = "in 'f'" } },
        // A shallow one is complete.
        .{ .src = "def g\n  raise \"x\"\nend\nr = begin\n  g\nrescue => e\n  e.backtrace.length\nend", .expected = .{ .num = 2 } },
    });
}

test "Stdlib: raising a value that isn't an exception keeps all of it as the message" {
    // A non-String value was stringified into a 1 KB stack buffer, cutting the message.
    try expectGlobalR(&.{
        .{ .src = "big = (1..500).to_a\nr = begin\n  raise big\nrescue => e\n  e.message == big.inspect\nend", .expected = .{ .boolean = true } },
        .{ .src = "r = begin\n  raise 42\nrescue RuntimeError => e\n  e.message\nend", .expected = .{ .str = "42" } },
    });
}

test "Stdlib: Strings index by character and Arrays and Strings by Range, as in Ruby" {
    try expectGlobalR(&.{
        // `"abc"[0]` used to be "TypeError: Cannot index target."
        .{ .src = "r = \"abc\"[0]", .expected = .{ .str = "a" } },
        .{ .src = "r = \"abc\"[-1]", .expected = .{ .str = "c" } },
        .{ .src = "r = \"h\u{e9}llo\"[1]", .expected = .{ .str = "\u{e9}" } }, // by character, not byte
        .{ .src = "r = \"h\u{e9}llo\"[1..3]", .expected = .{ .str = "\u{e9}ll" } },
        .{ .src = "r = \"hello\"[1...3]", .expected = .{ .str = "el" } },
        .{ .src = "r = \"hello\"[-3..-1]", .expected = .{ .str = "llo" } },
        .{ .src = "r = \"abc\"[1..10]", .expected = .{ .str = "bc" } }, // clamped at the end
        .{ .src = "r = \"abc\"[3..5]", .expected = .{ .str = "" } },
        .{ .src = "r = \"abc\"[4..5].nil?", .expected = .{ .boolean = true } }, // starts past the end
        .{ .src = "r = [1, 2, 3, 4][1..2]", .expected = .{ .nums = &.{ 2, 3 } } },
        .{ .src = "r = [1, 2, 3][1..-1]", .expected = .{ .nums = &.{ 2, 3 } } },
        .{ .src = "r = [1, 2, 3][0...0].length", .expected = .{ .num = 0 } },
        // Like Arrays, an index past the end is an IndexError (Crystal's choice; Ruby gives nil).
        .{ .src = comptime rescued("\"abc\"[5]"), .expected = .{ .str = "IndexError: String index 5 is out of bounds (size 3)" } },
        .{ .src = comptime rescued("\"abc\"[1.5]"), .expected = .{ .str = "TypeError: String index must be an integer, got 1.5" } },
        .{ .src = comptime rescued("\"abc\"[\"x\"]"), .expected = .{ .str = "TypeError: String index must be an integer or a Range, got String" } },
        .{ .src = comptime rescued("[1, 2][(0..1).step(2)]"), .expected = .{ .str = "ArgumentError: a stepped Range can't index an Array" } },
        .{ .src = comptime rescued("\"abc\"[0] = \"x\""), .expected = .{ .str = "TypeError: String doesn't support index assignment ([]=)" } },
    });
}

test "Stdlib: arithmetic that overflows is a RangeError, not Infinity" {
    // Numbers are 64-bit floats; `2 ** 1024` used to become Infinity silently.
    try expectGlobalR(&.{
        .{ .src = comptime rescued("2 ** 1024"), .expected = .{ .str = "RangeError: 2 ** 1024 overflows: the result is beyond the largest number (1.8e308)" } },
        .{ .src = comptime rescued("x = 2\n  x ** 1024"), .expected = .{ .str = "RangeError: 2 ** 1024 overflows: the result is beyond the largest number (1.8e308)" } },
        .{ .src = comptime rescued("x = 1e308\n  x + x"), .expected = .{ .str = "RangeError: 1e308 + 1e308 overflows: the result is beyond the largest number (1.8e308)" } },
        .{ .src = comptime rescued("x = 1e300\n  x * x"), .expected = .{ .str = "RangeError: 1e300 * 1e300 overflows: the result is beyond the largest number (1.8e308)" } },
        .{ .src = "r = 2 ** 1023 > 0", .expected = .{ .boolean = true } },
        // Math functions don't return NaN either.
        .{ .src = comptime rescued("Math.sqrt(-1)"), .expected = .{ .str = "MathError: Math.sqrt(-1) has no real result" } },
        .{ .src = comptime rescued("Math.asin(2)"), .expected = .{ .str = "MathError: Math.asin(2) has no real result" } },
        .{ .src = "r = Math.sqrt(16)", .expected = .{ .num = 4 } },
        // A script that needs a non-finite value says so, as with Ruby's Float::INFINITY.
        .{ .src = "r = \"#{Number::INFINITY} #{-Number::INFINITY} #{Number::NAN}\"", .expected = .{ .str = "Infinity -Infinity NaN" } },
        .{ .src = "r = Number::INFINITY > 1e308", .expected = .{ .boolean = true } },
    });
}

test "Stdlib: numbers print plainly only while their digits are exact" {
    try expectGlobalR(&.{
        // Huge and tiny numbers print in scientific notation (1e300 used to print 301 digits).
        .{ .src = "r = \"#{1e300} #{1e-7} #{123456.5}\"", .expected = .{ .str = "1e300 1e-7 123456.5" } },
        // Integers stay plain up to 2^53; from 1e16 the digits would claim a precision f64 lacks.
        .{ .src = "r = \"#{2 ** 53} #{9999999999999998} #{-(2 ** 53)}\"", .expected = .{ .str = "9007199254740992 9999999999999998 -9007199254740992" } },
        .{ .src = "r = \"#{1e16} #{2 ** 60} #{-1.5e20} #{123456789012345678901}\"", .expected = .{ .str = "1e16 1.152921504606847e18 -1.5e20 1.2345678901234568e20" } },
    });
}

test "Stdlib: a keyword wins over the same option given positionally" {
    // Primitives and sweeps used to let the positional value win, while translate, polygon,
    // fillet_edges and repeat_polar let the keyword win.
    try expectGlobalR(&.{
        .{ .src = "r = cube(5, z: 3).bbox.max", .expected = .{ .nums = &.{ 5, 5, 3 } } },
        .{ .src = "r = square(2, x: 4).extrude(1).bbox.max", .expected = .{ .nums = &.{ 4, 2, 1 } } },
        .{ .src = "r = cylinder(1, 5, h: 2).bbox.max[2]", .expected = .{ .num = 2 } },
        .{ .src = "r = sphere(1, r: 3).bbox.max[0] > 2", .expected = .{ .boolean = true } },
        .{ .src = "r = square(2).extrude(5, h: 2).bbox.max[2]", .expected = .{ .num = 2 } },
        .{ .src = "r = square(2).translate(x: 3).revolve(90, deg: 180).bbox.min[0] < 0", .expected = .{ .boolean = true } }, // half a turn reaches -x
        .{ .src = "r = square(2).offset(5, delta: 1).extrude(1).bbox.max[0]", .expected = .{ .num = 3 } },
        .{ .src = "r = regular_polygon(3, 1, sides: 4).extrude(1).volume", .expected = .{ .num = 2 } },
    });
}

test "Stdlib: revolve takes segments and sizes them to the profile" {
    // revolve assumed a 10 mm profile radius for its segment count, and took no segments:.
    const seg8 = "v = nil\nCAD.with_config(manifold: { min_angle_deg: 1, min_segment_len: 1 }) do\n  v = ";
    try expectGlobalR(&.{
        .{ .src = "r = square(1).translate(x: 1).revolve(segments: 4).volume < square(1).translate(x: 1).revolve(segments: 64).volume", .expected = .{ .boolean = true } },
        // A larger profile gets more segments for the same minimum segment length.
        .{ .src = seg8 ++ "[square(1).translate(x: 1).revolve.volume, square(1).translate(x: 100).revolve.volume]\nend\nr = v[0] / (Math::PI * 2 * 1.5) < v[1] / (Math::PI * 2 * 100.5)", .expected = .{ .boolean = true } },
        .{ .src = comptime rescued("square(1).revolve(segments: 1e9)"), .expected = .{ .str = "ValueError: 'segments' must be between 0 and 2048, got 1000000000" } },
    });
}

test "Stdlib: material checks its color and factors" {
    try expectGlobalR(&.{
        // An invalid color used to export as white, and factors out of 0..1 were kept.
        .{ .src = comptime rescued("cube(1).material(color: \"red\")"), .expected = .{ .str = "ValueError: material color must be \"#RRGGBB\" or \"#RGB\", got \"red\"" } },
        .{ .src = comptime rescued("cube(1).material(color: \"#12345\")"), .expected = .{ .str = "ValueError: material color must be \"#RRGGBB\" or \"#RGB\", got \"#12345\"" } },
        .{ .src = comptime rescued("cube(1).material(roughness: 5)"), .expected = .{ .str = "ValueError: material roughness must be between 0 and 1, got 5" } },
        .{ .src = comptime rescued("cube(1).material(alpha: -0.1)"), .expected = .{ .str = "ValueError: material alpha must be between 0 and 1, got -0.1" } },
        .{ .src = comptime rescued("cube(1).material(color: \"#f80\", alpha: 0.5, metallic: 1, transmission: 0)"), .expected = .{ .str = "no error" } },
    });
}

test "Stdlib: every value has a class, and value classes aren't built with .new" {
    // nil, lambdas, bound methods, classes and modules had no class (`.class` was nil).
    try expectGlobalR(&.{
        .{ .src = "r = \"#{nil.class} #{true.class} #{1.class} #{:s.class}\"", .expected = .{ .str = "NilClass Boolean Number Symbol" } },
        .{ .src = "f = -> { 1 }\nr = \"#{f.class} #{f.is_a?(Proc)}\"", .expected = .{ .str = "Proc true" } },
        .{ .src = "class C\n  def g\n  end\nend\nr = \"#{C.new.method(:g).class} #{C.class} #{Math.class}\"", .expected = .{ .str = "Method Class Math" } },
        .{ .src = "module M\nend\nr = M.class == Module", .expected = .{ .boolean = true } },
        .{ .src = "r = nil.is_a?(NilClass) && nil.is_a?(Object)", .expected = .{ .boolean = true } },
        // `Array.new` used to make an empty object that was no Array at all.
        .{ .src = "r = Array.new(3, 0)", .expected = .{ .nums = &.{ 0, 0, 0 } } },
        .{ .src = "r = \"#{Array.new.inspect} #{String.new.inspect} #{Map.new.inspect} #{String.new(\"s\")}\"", .expected = .{ .str = "[] \"\" {} s" } },
        .{ .src = comptime rescued("Array.new(-1)"), .expected = .{ .str = "ValueError: Array.new size must be a whole number from 0 to 10000000, got -1" } },
        .{ .src = comptime rescued("Number.new"), .expected = .{ .str = "NoMethodError: undefined method 'new' for Number" } },
        .{ .src = comptime rescued("NilClass.new"), .expected = .{ .str = "NoMethodError: undefined method 'new' for NilClass" } },
        .{ .src = comptime rescued("Solid.new"), .expected = .{ .str = "NoMethodError: undefined method 'new' for Solid" } },
        // Exception classes and user classes still are.
        .{ .src = "r = ValueError.new(\"x\").message", .expected = .{ .str = "x" } },
        .{ .src = "class P\nend\nr = P.new.class == P", .expected = .{ .boolean = true } },
    });
}

test "Stdlib: constants of a class or module are read with ::" {
    // `Foo::BAR` was "NameError: Undefined class member 'BAR'" (only nested classes worked).
    const src = "module M\n  K = 3\n  class Inner\n    Z = 4\n    def self.z\n      Z\n    end\n  end\nend\nclass Foo\n  BAR = 7\n  BAR2 = BAR + 1\nend\n";
    try expectGlobalR(&.{
        .{ .src = src ++ "r = [M::K, M::Inner::Z, M::Inner.z, Foo::BAR, Foo::BAR2]", .expected = .{ .nums = &.{ 3, 4, 4, 7, 8 } } },
        .{ .src = "r = Math::PI > 3", .expected = .{ .boolean = true } },
    });
}

test "Stdlib: block_given? works with or without parentheses" {
    // The bare form used to be looked up as a variable: NameError.
    const m = "def m(&b)\n  [block_given?, block_given?()]\nend\n";
    try expectGlobalR(&.{
        .{ .src = m ++ "r = \"#{m}\"", .expected = .{ .str = "[false, false]" } },
        .{ .src = m ++ "r = \"#{m { 1 }}\"", .expected = .{ .str = "[true, true]" } },
        .{ .src = m ++ "f = -> { 1 }\nr = \"#{m(&f)}\"", .expected = .{ .str = "[true, true]" } },
        .{ .src = m ++ "r = \"#{m(&nil)}\"", .expected = .{ .str = "[false, false]" } },
    });
}

test "Stdlib: yield works anywhere an expression does" {
    try expectGlobalR(&.{
        .{ .src = "def a\n  x = yield\n  x + 1\nend\nr = a { 1 }", .expected = .{ .num = 2 } },
        .{ .src = "def b\n  yield(2).round\nend\nr = b { |v| v * 1.4 }", .expected = .{ .num = 3 } },
        .{ .src = "def c\n  block_given? ? yield : 0\nend\nr = [c, c { 5 }]", .expected = .{ .nums = &.{ 0, 5 } } },
        .{ .src = "def d\n  [yield(1), yield 2]\nend\nr = d { |v| v * 10 }", .expected = .{ .nums = &.{ 10, 20 } } },
        .{ .src = "def e\n  return yield(3) if block_given?\n  0\nend\nr = [e { |v| v + 1 }, e]", .expected = .{ .nums = &.{ 4, 0 } } },
        // Ruby's spacing rule: `yield -1` passes -1, `yield - 1` subtracts 1 from the result.
        .{ .src = "def f\n  [(yield -1), (yield - 1)]\nend\nr = f { |v = 10| v }", .expected = .{ .nums = &.{ -1, 9 } } },
        .{ .src = "def g\n  yield *[1, 2]\nend\nr = g { |p, q| p + q }", .expected = .{ .num = 3 } },
    });
}

test "Stdlib: lambdas behave like blocks" {
    try expectGlobalR(&.{
        // `return` and `next` leave just the lambda or block, never the enclosing def.
        .{ .src = "f = ->(x) do\n  return 10 if x > 0\n  20\nend\nr = [f.call(1), f.call(-1)]", .expected = .{ .nums = &.{ 10, 20 } } },
        .{ .src = "f = -> do\n  next 7\n  8\nend\nr = f.call", .expected = .{ .num = 7 } },
        .{ .src = "def m\n  f = -> { return 5 }\n  f.call\n  1\nend\nr = m", .expected = .{ .num = 1 } },
        .{ .src = "def m\n  [1, 2, 3].each { |v| return v if v == 2 }\n  1\nend\nr = m", .expected = .{ .num = 1 } },
        // Both are lenient about arguments, unlike a Ruby lambda.
        .{ .src = "f = ->(x, y) { [x, y] }\nr = \"#{f.call(1)}\"", .expected = .{ .str = "[1, nil]" } },
        .{ .src = "f = ->(x) { x }\nr = f.call(1, 2)", .expected = .{ .num = 1 } },
        // Closures capture and update their enclosing variables.
        .{ .src = "n = 1\nbump = -> { n += 1 }\nbump.call\nbump.call\nr = n", .expected = .{ .num = 3 } },
        // Block parameters don't unpack arrays; `|(a, b)|` does, and a Map passes key and value.
        .{ .src = "r = \"#{[[1, 2]].map { |a, b| [a, b] }}\"", .expected = .{ .str = "[[[1, 2], nil]]" } },
        .{ .src = "r = [[1, 2]].map { |(a, b)| a + b }", .expected = .{ .nums = &.{3} } },
        .{ .src = "r = \"#{{ x: 1 }.map { |k, v| [k, v] }}\"", .expected = .{ .str = "[[:x, 1]]" } },
    });
}

test "Stdlib: Range#map keeps its result array and block results alive across GC" {
    var vm = try initVm();
    defer vm.deinit();
    // Collect on every allocation: an unrooted result array or element would be swept here.
    vm.gc.stress = true;
    defer vm.gc.stress = false;
    try testing.expectEqual(InterpretResult.ok, try runOn(&vm, "r = (0..200).map { |i| \"s\" + i.to_s }"));
    const r = vm.globals.get("r") orelse return error.MissingGlobal;
    const items = r.asArray().items.items;
    try testing.expectEqual(@as(usize, 201), items.len);
    var buf: [16]u8 = undefined;
    for (items, 0..) |item, i| {
        try testing.expect(item.isString());
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "s{d}", .{i}), item.asString().chars);
    }
}

// --- Coordinate and geometry-argument validation ---
// Non-number coordinates used to read as 0 (polygon([[0,0],[10,"x"],[10,10]]) was a
// 50 mm^3 prism) and NaN/inf went straight to the kernels.

/// Wraps `src` so the global `r` holds the rescued error message (or "no error").
/// `rescue <Kind> => e` for every runtime error kind, each yielding "<Kind>: <message>",
/// so an expected string checks the error's class as well as its message.
const RESCUE_BY_KIND = blk: {
    var text: []const u8 = "";
    for (std.meta.fieldNames(ErrorKind)) |kind| text = text ++ "rescue " ++ kind ++ " => e\n  \"" ++ kind ++ ": \" + e.message\n";
    break :blk text;
};

fn rescued(comptime src: []const u8) []const u8 {
    return "r = begin\n  " ++ src ++ "\n  \"no error\"\n" ++ RESCUE_BY_KIND ++ "end";
}

const TETRA_PTS = "[[0,0,0],[1,0,0],[0,1,0],[0,0,1]]";
const TETRA_FACES = "[[0,1,2],[0,3,1],[0,2,3],[1,3,2]]";

test "Stdlib: geometry arguments reject non-number coordinates" {
    try expectAll(.runtime_error, &.{
        // The reported case, and every way a polygon point can be malformed.
        "polygon([[0,0],[10,\"x\"],[10,10]]).extrude(1).volume",
        "polygon([[0,0],[10,nil],[10,10]])",
        "polygon([[0,0],[10,:y],[10,10]])",
        "polygon([[0,0],[10,[1]],[10,10]])",
        "polygon([[0,0],[10],[10,10]])",
        "polygon([[0,0],[10,0,5],[10,10]])",
        "polygon([[0,0],10,[10,10]])",
        "polygon(\"pts\")",
        "polygon([[0,0],[10,0]])",
        "polygon([[0,0],[1,0],[0,1]], paths: 3)",
        "polygon([[0,0],[1,0],[0,1]], [[0,1,\"2\"]])",
        "polygon([[0,0],[1,0],[0,1]], paths: [[0,1]])",
        "polygon([[0,0],[1,0],[0,1]], paths: [5])",
        // An unreferenced point is still validated.
        "polygon([[0,0],[1,0],[0,1],[\"x\",0]], paths: [[0,1,2]])",
        // polyhedron points and faces.
        "polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0,\"z\"]], " ++ TETRA_FACES ++ ")",
        "polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0]], " ++ TETRA_FACES ++ ")",
        "polyhedron([[0,0,0],[1,0,0],[0,1,0]], [[0,1,2],[0,1,2],[0,1,2],[0,1,2]])",
        "polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2],[0,3,1],[0,2,3]])",
        "polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2],[0,3,1],[0,2,3],[1,3,\"2\"]])",
        "polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2],[0,3,1],[0,2,3],[1,3]])",
        // A quad face used to be truncated to its first triangle.
        "polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2,3],[0,3,1],[0,2,3],[1,3,2]])",
        "polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2],[0,3,1],[0,2,3],7])",
        // Vector transforms, positional and kwarg forms.
        "cube(1).translate(\"10\", 0, 0)",
        "cube(1).translate(z: \"up\")",
        "cube(1).translate(x: nil)",
        "cube(1).translate([1, 2, 3])",
        "cube(1).translate(1, 2, 3, 4)",
        "square(1).translate(y: :a)",
        "cube(1).rotate(z: \"45\")",
        "square(1).rotate(\"45\")",
        "cube(1).scale(x: \"2\")",
        "cube(1).mirror(\"x\")",
        "cube(1).mirror(z: [1])",
        // Matrices: flat 12 (3D) or 6 (2D) numbers, exactly.
        "cube(1).transform([1,0,0, 0,1,0, 0,0,\"1\", 0,0,0])",
        "cube(1).transform([1,0,0, 0,1,0, 0,0,1, 0,0])",
        "cube(1).transform([1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])",
        "cube(1).transform([[1,0,0],[0,1,0],[0,0,1],[0,0,0]])",
        "cube(1).transform(5)",
        "square(1).transform([1,0, 0,1, 0,\"5\"])",
        "square(1).transform([1,0, 0,1, 0])",
        "square(1).transform([1,0, 0,1, 0,0, 0])",
        // resize / align / patterns.
        "cube(1).resize([\"2\", 0, 0])",
        "cube(1).resize([2, 0, 0, 0])",
        "cube(1).resize([])",
        "cube(1).resize(2)",
        "cube(1).resize([-2, 0, 0])",
        "cube(1).resize([2, 0, 0], auto: \"yes\")",
        "cube(1).align(cube(2), \"z\", \"min\", \"max\", \"1\")",
        "cube(1).align(cube(2), \"z\", \"min\", [1])",
        "cube(1).repeat_linear(3, [2, \"0\", 0])",
        "cube(1).repeat_linear(3, [2, 0, 0, 0])",
        "cube(1).repeat_linear(3, \"2\")",
        "cube(1).repeat_linear(3, 2, :y)",
        "cube(1).repeat_linear(3, x: \"2\")",
        "cube(1).repeat_polar(3, \"90\")",
        "cube(1).repeat_polar(3, angle: \"90\")",
        // 2D offset, planes, faces and queries.
        "square(1).offset(\"1\")",
        "square(1).offset(delta: \"1\")",
        "square(1).offset(1, join: 2)",
        "square(1).offset(1, join: :spiky)",
        "cube(1).trim_by_plane(0, \"0\", 1)",
        "cube(1).trim_by_plane(0, 0, 1, \"5\")",
        "cube(1).slice(\"0.5\")",
        "cube(1).on_face([0, 0, \"1\"])",
        "cube(1).on_face([0, 0])",
        "cube(1).on_face([0, 0, 1, 0])",
        "cube(1).on_face(5)",
        "cube(1).split_by_plane(0, 0, \"1\", 0)",
        "cube(1).split_by_plane(nz: \"1\")",
        "cube(1).split_by_plane(0, 0)",
        "cube(1).fillet_edges(\"1\")",
        "cube(1).fillet_edges(r: \"1\")",
        "cube(1).simplify(\"0.1\")",
        "cube(1).contains?([0, \"0\", 0])",
        "cube(1).contains?([0, 0])",
        "cube(1).ray_cast([0, 0, 5], [0, :y, -5])",
        "cube(1).ray_cast([0, 0, 5], [0, -5])",
        "cube(1).min_gap(cube(1), \"100\")",
        "cube(1).min_gap(5)",
        // Sweeps.
        "square(1).extrude(\"5\")",
        "square(1).extrude(5, twist: \"30\")",
        "square(1).extrude(5, center: \"yes\")",
        "square(1).translate(x: 5).revolve(\"90\")",
        "square(1).translate(x: 5).revolve(deg: \"90\")",
        "square(1).helix(\"10\")",
        "square(1).helix(10, \"360\")",
        "square(1).loft(circle(r: 1), \"5\")",
        "square(1).loft(cube(1), 5)",
        // Primitives: positional and kwargs.
        "cube(\"10\")",
        "cube(10, \"20\", 30)",
        "cube(10, 20, 30, \"yes\")",
        "cube(x: \"10\")",
        "cube(size: [1, 2, 3])",
        "square(10, 10, 1)",
        "cylinder(d: \"4\", h: 2)",
        "cylinder(r: 1, h: 2, center: 1)",
        "sphere(true)",
        "circle(radius: \"2\")",
        "regular_polygon(\"6\", 5)",
        "regular_polygon(sides: \"6\")",
        "torus(\"10\", 2)",
        "torus(major_r: 10, minor_r: \"2\")",
        "text(\"A\", \"12\")",
        "text(\"A\", size: \"12\")",
        "text(\"A\", font: 5)",
        "text(\"A\", halign: 1)",
        "text(\"A\", halign: \"middle\")",
        "text(\"A\", valign: :centre)",
    });
}

test "Stdlib: geometry coordinates reject NaN and inf" {
    try expectAll(.runtime_error, &.{
        "polygon([[0,0],[10,Number::NAN],[10,10]])",
        "polygon([[0,0],[Number::INFINITY,0],[10,10]])",
        "polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0,-Number::INFINITY]], " ++ TETRA_FACES ++ ")",
        "cube(1).translate(Number::INFINITY, 0, 0)",
        "cube(1).translate(z: Number::NAN)",
        "cube(1).rotate(x: Number::INFINITY)",
        "square(1).rotate(Number::INFINITY - Number::INFINITY)",
        "cube(1).scale(Number::INFINITY, 1, 1)",
        "cube(1).mirror(Number::NAN, 0, 0)",
        "cube(1).transform([1,0,0, 0,1,0, 0,0,1, 0,0,Number::INFINITY])",
        "square(1).transform([1,0, 0,1, Number::NAN,0])",
        "cube(1).resize([Number::INFINITY, 0, 0])",
        "cube(1).align(cube(2), \"z\", \"min\", \"max\", Number::INFINITY)",
        "cube(1).align(cube(2), \"z\", \"min\", Number::NAN)",
        "cube(1).repeat_linear(3, [Number::INFINITY, 0, 0])",
        "cube(1).repeat_linear(3, 0, 0, Number::NAN)",
        "cube(1).repeat_polar(3, Number::NAN)",
        "square(1).offset(Number::INFINITY)",
        "cube(1).trim_by_plane(0, 0, 1, Number::INFINITY)",
        "cube(1).slice(Number::INFINITY - Number::INFINITY)",
        "cube(1).on_face([0, 0, Number::INFINITY])",
        "cube(1).split_by_plane(0, 0, 1, Number::NAN)",
        "cube(1).fillet_edges(Number::INFINITY)",
        "cube(1).simplify(Number::INFINITY - Number::INFINITY)",
        "cube(1).contains?([0, Number::INFINITY, 0])",
        "cube(1).ray_cast([0, 0, Number::NAN], [0, 0, -5])",
        "cube(1).min_gap(cube(1), Number::INFINITY)",
        "cube(size: Number::NAN)",
        "torus(major_r: Number::INFINITY)",
        "text(\"A\", size: Number::NAN)",
    });
}

test "Stdlib: degenerate vectors and matrices are rejected" {
    try expectAll(.runtime_error, &.{
        // A zero mirror normal or scale factor can never produce a valid solid.
        "cube(1).mirror(0, 0, 0)",
        "cube(1).mirror()",
        "cube(1).mirror(x: 0)",
        "cube(1).scale(0)",
        "cube(1).scale(1, 0, 1)",
        "cube(1).scale(z: 0)",
        "square(1).scale(0, 1)",
        // Singular matrices flatten the shape the same way.
        "cube(1).transform([1,0,0, 0,1,0, 0,0,0, 0,0,0])",
        "cube(1).transform([1,2,3, 2,4,6, 0,0,1, 0,0,0])",
        "square(1).transform([1,2, 2,4, 0,0])",
        "cube(1).trim_by_plane(0, 0, 0)",
        "cube(1).split_by_plane(0, 0, 0, 1)",
        "cube(1).split_by_plane(nx: 0)",
        "cube(1).on_face([0, 0, 0])",
        "cube(1).ray_cast([1, 2, 3], [1, 2, 3])",
        "cube(1).min_gap(cube(1), 0)",
        "cube(1).fillet_edges(0)",
        "cube(1).fillet_edges(r: -1)",
    });
}

test "Stdlib: near-zero normals and subnormal factors are rejected, not silently emptied" {
    // Not exactly zero, but normalizing them underflows: these used to build an
    // empty or zero-volume solid with no error.
    try expectAll(.runtime_error, &.{
        "cube(1).mirror(1e-320, 0, 0)",
        "cube(1).mirror(1e-170, 1e-170, 0)",
        "cube(10).translate(x: -5).trim_by_plane(1e-200, 0, 0)",
        "cube(10).translate(x: -5).split_by_plane(1e-200, 0, 0, 0)",
        "cube(1).on_face([0, 0, 1e-200])",
        "cube(1).scale(1e-320)",
        "square(1).scale(1, 1e-320)",
        // det = inf - inf = NaN used to pass the `det == 0` check.
        "cube(1).transform([1e200,0,0, 0,1e200,1e200, 0,1e200,1e200, 0,0,0])",
        // A subnormal determinant flattens the shape as surely as 0.
        "cube(1).transform([1e-110,0,0, 0,1e-110,0, 0,0,1e-110, 0,0,0])",
    });
    try expectGlobalR(&.{
        .{ .src = rescued("cube(1).mirror(1e-320, 0, 0)"), .expected = .{ .str = "ValueError: mirror expects a non-zero plane normal, got [1e-320, 0, 0]" } },
        .{ .src = rescued("cube(1).trim_by_plane(0, 1e-200, 0)"), .expected = .{ .str = "ValueError: trim_by_plane expects a non-zero plane normal, got [0, 1e-200, 0]" } },
    });
}

test "Stdlib: tiny-but-normal and huge vectors, CrossSection z scale and nil step still build" {
    try expectGlobalR(&.{
        // The smallest normals that still normalize keep working, as do huge ones.
        .{ .src = "r = cube(1).mirror(1e-150, 0, 0).volume.round(6)", .expected = .{ .num = 1 } },
        .{ .src = "r = cube(1).mirror(1e200, 0, 0).volume.round(6)", .expected = .{ .num = 1 } },
        .{ .src = "r = cube(10).translate(x: -5).trim_by_plane(1e-150, 0, 0).volume.round(6)", .expected = .{ .num = 500 } },
        // A CrossSection ignores the z factor, so a 0 there is harmless.
        .{ .src = "r = square(1).scale(2, 2, 0).extrude(1).volume.round(6)", .expected = .{ .num = 4 } },
        // A nil step (a forwarded optional parameter) means no offset.
        .{ .src = "r = cube(1).repeat_linear(3, nil).volume.round(6)", .expected = .{ .num = 1 } },
    });
}

test "Stdlib: lazily formatted element errors keep their exact wording" {
    try expectGlobalR(&.{
        .{ .src = rescued("polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2],[0,3,\"a\"],[0,2,3],[1,3,2]])"), .expected = .{ .str = "TypeError: polyhedron expects a number for a point index (face 1, entry 2), got String" } },
        .{ .src = rescued("polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2],5,[0,2,3],[1,3,2]])"), .expected = .{ .str = "TypeError: polyhedron expects an Array for face 1, got Number" } },
        .{ .src = rescued("polygon([[0,0],[1,0],5])"), .expected = .{ .str = "TypeError: polygon expects an Array for point 2, got Number" } },
        .{ .src = rescued("polygon([[0,0],[1,0],[0,Number::INFINITY]])"), .expected = .{ .str = "ValueError: polygon expects a finite number for a coordinate (point 2, component 1), got Infinity" } },
        .{ .src = rescued("polygon([[0,0],[1,0],[0,1]], paths: [[0,1,2], 7])"), .expected = .{ .str = "TypeError: polygon expects an Array for path 1, got Number" } },
        .{ .src = rescued("polygon([[0,0],[1,0],[0,1]], paths: [[0,1]])"), .expected = .{ .str = "ValueError: polygon needs at least 3 point indices in path 0, got 2" } },
        .{ .src = rescued("polygon([[0,0],[1,0],[0,1]], paths: [[0,1,Number::INFINITY]])"), .expected = .{ .str = "ValueError: polygon expects a finite number for a point index (path 0, entry 2), got Infinity" } },
        .{ .src = rescued("cube(1).transform([1,0,0, 0,1,0, 0,0,Number::INFINITY, 0,0,0])"), .expected = .{ .str = "ValueError: transform expects a finite number for a matrix entry (index 8), got Infinity" } },
    });
}

test "Stdlib: rescued argument errors name the method, the position and the bad type" {
    try expectGlobalR(&.{
        .{ .src = rescued("polygon([[0,0],[10,\"x\"],[10,10]]).extrude(1).volume"), .expected = .{ .str = "TypeError: polygon expects a number for a coordinate (point 1, component 1), got String" } },
        .{ .src = rescued("polygon([[0,0],[10,0],[Number::NAN,10]])"), .expected = .{ .str = "ValueError: polygon expects a finite number for a coordinate (point 2, component 0), got NaN" } },
        .{ .src = rescued("polygon([[0,0],[10],[10,10]])"), .expected = .{ .str = "ValueError: polygon expects point 1 to have 2 numbers, got 1" } },
        .{ .src = rescued("polygon([[0,0],[1,0],[0,1]], paths: [[0,1,[2]]])"), .expected = .{ .str = "TypeError: polygon expects a number for a point index (path 0, entry 2), got Array" } },
        .{ .src = rescued("polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,nil,1]], " ++ TETRA_FACES ++ ")"), .expected = .{ .str = "TypeError: polyhedron expects a number for a coordinate (point 3, component 1), got nil" } },
        .{ .src = rescued("polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2],[0,3,1,2],[0,2,3],[1,3,2]])"), .expected = .{ .str = "ValueError: polyhedron faces must be triangles (3 point indices), but face 1 has 4" } },
        .{ .src = rescued("cube(1).translate(z: \"up\")"), .expected = .{ .str = "TypeError: translate expects a number for z, got String" } },
        .{ .src = rescued("cube(1).rotate(0, :y)"), .expected = .{ .str = "TypeError: rotate expects a number for y, got Symbol" } },
        .{ .src = rescued("cube(1).transform([1,0,0, 0,1,0, 0,0,:s, 0,0,0])"), .expected = .{ .str = "TypeError: transform expects a number for a matrix entry (index 8), got Symbol" } },
        .{ .src = rescued("cube(1).transform([1,0,0, 0,1,0, 0,0,1, 0,0])"), .expected = .{ .str = "ValueError: transform expects the matrix to have 12 numbers, got 11" } },
        .{ .src = rescued("cube(1).trim_by_plane(0, \"a\", 1)"), .expected = .{ .str = "TypeError: trim_by_plane expects a number for ny, got String" } },
        .{ .src = rescued("cube(1).contains?([0, 0, [1]])"), .expected = .{ .str = "TypeError: contains? expects a number for a coordinate (component 2), got Array" } },
        .{ .src = rescued("cube(x: true)"), .expected = .{ .str = "TypeError: cube expects a number for x, got Boolean" } },
        .{ .src = rescued("text(\"A\", halign: 5)"), .expected = .{ .str = "TypeError: text expects a String or Symbol for halign, got Number" } },
        .{ .src = rescued("cube(1).translate(Number::INFINITY)"), .expected = .{ .str = "ValueError: translate expects a finite number for x, got Infinity" } },
        .{ .src = rescued("cube(1).mirror(0, 0, 0)"), .expected = .{ .str = "ValueError: mirror expects a non-zero plane normal, got [0, 0, 0]" } },
        .{ .src = rescued("cube(1).scale(1, 0, 1)"), .expected = .{ .str = "ValueError: scale factors must be non-zero, got [1, 0, 1]" } },
        // Errors that used to surface as the generic "Native Execution Error" when rescued.
        .{ .src = rescued("polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2],[0,3,1],[0,2,3],[4,2,3]])"), .expected = .{ .str = "ValueError: polyhedron face index 4 is out of range (0..4)" } },
        .{ .src = rescued("cube(Number::INFINITY - Number::INFINITY)"), .expected = .{ .str = "ValueError: cube expects a finite number for x, got NaN" } },
        .{ .src = rescued("cube(-1)"), .expected = .{ .str = "ValueError: cube expects x to be a finite number greater than zero, got -1" } },
    });
}

test "Stdlib: valid coordinates and vector arguments still build" {
    try expectAll(.ok, &.{
        "polygon([[0,0],[10,0],[10,10]])",
        "polygon([[0.5,-1.5],[10,0],[-3,10.25]]).extrude(2)",
        "polygon([[0,0],[10,0],[10,10],[0,10],[2,2],[8,2],[8,8],[2,8]], paths: [[0,1,2,3],[4,5,6,7]])",
        "polygon([[0,0],[10,0],[10,10],[0,10]], [[0,1,2,3]])",
        "polygon([[0,0],[10,0],[10,10]], paths: nil)",
        "polyhedron(" ++ TETRA_PTS ++ ", " ++ TETRA_FACES ++ ")",
        "polyhedron([[0,0,0],[1.5,0,0],[0,-1.5,0],[0,0,2.25]], " ++ TETRA_FACES ++ ")",
        "cube(1).translate(1, -2, 3.5)",
        "cube(1).translate(x: -1)",
        "cube(1).translate(1, z: 2)",
        "cube(1).translate()",
        "square(1).translate(2, -3)",
        "cube(1).rotate(10, 20, 30)",
        "cube(1).rotate(z: -45.5)",
        "square(1).rotate(45)",
        "cube(1).scale(2)",
        "cube(1).scale(-1, 1, 1)",
        "cube(1).scale(x: 0.5, z: 3)",
        "square(1).scale(2, 0.5)",
        "cube(1).mirror(1, 0, 0)",
        "cube(1).mirror(z: -1)",
        "cube(1).mirror(0.5, 0.5, 0)",
        "cube(1).transform([1,0,0, 0,1,0, 0,0,1, 5,10,15])",
        "cube(1).transform([2.5,0,0, 0,-1,0, 0,0,1, 0,0,0])",
        "square(1).transform([1,0, 0,1, 2,4])",
        "square(1).transform([1.1,0.5, 0,1, -2,0])",
        "cube(10).resize([20])",
        "cube(10).resize([20, 0, 0], auto: true)",
        "cube(10).resize([0, 0, 5.5])",
        "cube(1).align(cube(2), \"z\", \"min\", \"max\")",
        "cube(1).align(cube(2), \"z\", \"min\", \"max\", 1.5)",
        "cube(1).align(cube(2), \"z\", \"min\", -2)",
        "cube(1).align(cube(2), \"z\", \"min\", nil, 1)",
        "cube(1).repeat_linear(3, [2, 0, 0])",
        "cube(1).repeat_linear(3, [2])",
        "cube(1).repeat_linear(3, 2, -1, 0.5)",
        "cube(1).repeat_linear(3, x: 2, z: 1)",
        "cube(1).repeat_linear(3)",
        "cube(1).repeat_polar(4)",
        "cube(1).repeat_polar(3, 90)",
        "cube(1).repeat_polar(3, angle: 180.5)",
        "square(1).offset(-0.25)",
        "square(1).offset(delta: 1, join: :miter)",
        "square(1).offset(1, join: \"bevel\")",
        "square(1).offset(1, join: :square)",
        "square(1).offset(1, join: :round)",
        "cube(1).trim_by_plane(0, 0, 1)",
        "cube(1).trim_by_plane(0, 0, -1, -0.5)",
        "cube(1).slice()",
        "cube(1).slice(0.5)",
        "cube(1).on_face(:top)",
        "cube(1).on_face([0, 0, 1])",
        "cube(1).on_face([-1, 0, 0])",
        "cube(1).split_by_plane()",
        "cube(1).split_by_plane(0, 0, 1, 0.5)",
        "cube(1).split_by_plane(0, 0, 1)",
        "cube(1).split_by_plane(nz: 1, offset: 0.5)",
        "cube(1).split_by_plane(offset: 0.5)",
        "cube(1).fillet_edges(0.5)",
        "cube(1).fillet_edges(r: 1)",
        "cube(1).simplify(0.01)",
        "cube(1).simplify()",
        "cube(1).contains?([0.5, 0.5, 0.5])",
        "cube(1).contains?([-1, 2.5, 0])",
        "cube(1).ray_cast([0.5, 0.5, 5], [0.5, 0.5, -5])",
        "cube(1).min_gap(cube(1).translate(x: 5))",
        "cube(1).min_gap(cube(1).translate(x: 5), 50.5)",
        "square(1).extrude(5)",
        "square(1).extrude(h: 2.5, twist: -30, scale: 0.5, slices: 4, center: true)",
        "square(1).extrude(5, scale_x: 0.5, scale_y: 2)",
        "square(1).translate(x: 5).revolve(90)",
        "square(1).translate(x: 5).revolve(deg: 180)",
        "square(1).helix(10, 180)",
        "square(1).helix(h: 5, twist: -90, slices: 8)",
        "square(1).loft(circle(r: 2), 5)",
        "cube(1, 2, 3, true)",
        "cube(size: 2)",
        "cube(x: 1.5, y: 2, z: 3, round_r: 0.2)",
        "square(2, 3, true)",
        "square(4, chamfer: 0.5, center: false)",
        "cylinder(d: 4, h: 2)",
        "cylinder(2, 5, true)",
        "cylinder(r1: 1, r2: 2, h: 3, round_r: nil)",
        "sphere(r: 1.5)",
        "circle(d: 3)",
        "circle(radius: 2, segments: 12)",
        "regular_polygon(5, 2)",
        "regular_polygon(sides: 8, r: 1)",
        "torus(5, 1)",
        "torus(major_r: 5.5, minor_r: 1)",
        "text(\"A\", 12, halign: :center, valign: \"top\", font: \"sans\")",
        "text(\"A\", halign: \"left\", valign: :baseline)",
        "text(\"A\", size: 5, halign: :right, valign: :bottom, tolerance: 0.05)",
    });
}

test "Stdlib: validated geometry methods keep their results for valid input" {
    try expectGlobalR(&.{
        .{ .src = "r = polygon([[0,0],[10,0],[10,10]]).extrude(1).volume.round(6)", .expected = .{ .num = 50 } },
        .{ .src = "r = polygon([[0,0],[10,0],[10,10],[0,10],[2,2],[8,2],[8,8],[2,8]], paths: [[0,1,2,3],[4,5,6,7]]).extrude(1).volume.round(6)", .expected = .{ .num = 64 } },
        .{ .src = "r = polyhedron([[0,0,0],[6,0,0],[0,6,0],[0,0,6]], [[0,2,1],[0,1,3],[0,3,2],[1,2,3]]).volume.round(6)", .expected = .{ .num = 36 } },
        .{ .src = "r = cube(2).scale(-1, 1, 1).volume.round(6)", .expected = .{ .num = 8 } },
        .{ .src = "r = cube(2).scale(1.5, z: 2).volume.round(6)", .expected = .{ .num = 24 } },
        .{ .src = "r = cube(2).mirror(1, 0, 0).bbox.x_min", .expected = .{ .num = -2 } },
        .{ .src = "r = cube(1).transform([2,0,0, 0,1,0, 0,0,1, 0,0,10]).bbox.z_min", .expected = .{ .num = 10 } },
        .{ .src = "r = cube(10).resize([20]).volume.round(6)", .expected = .{ .num = 2000 } },
        .{ .src = "r = cube(10).resize([20, 0, 0], auto: true).volume.round(6)", .expected = .{ .num = 8000 } },
        .{ .src = "r = cube(1).repeat_linear(3, 2, 0, 0).bbox.x_max", .expected = .{ .num = 5 } },
        .{ .src = "r = cube(1).repeat_linear(3, [0, 2]).bbox.y_max", .expected = .{ .num = 5 } },
        .{ .src = "r = cube(1).align(cube(2), \"z\", \"min\", \"max\", 1.5).bbox.z_min", .expected = .{ .num = 3.5 } },
        .{ .src = "r = cube(10).trim_by_plane(0, 0, 1, 4).volume.round(6)", .expected = .{ .num = 600 } },
        // The default plane is still x = 0 when no normal component is given.
        .{ .src = "parts = cube(10, 20, 30).split_by_plane(offset: 4)\nr = [parts[0].volume.round(6), parts[1].volume.round(6)]", .expected = .{ .nums = &.{ 3600, 2400 } } },
        .{ .src = "parts = cube(10, 20, 30).split_by_plane(0, 0, 1, 10)\nr = [parts[0].volume.round(6), parts[1].volume.round(6)]", .expected = .{ .nums = &.{ 4000, 2000 } } },
    });
}

test "Stdlib: split_by_plane normal kwargs default the other components to 0" {
    // nz: 1 alone used to keep the default nx = 1, splitting along a diagonal plane.
    try expectGlobalR(&.{
        .{ .src = "parts = cube(10, 20, 30).split_by_plane(nz: 1, offset: 10)\nr = [parts[0].volume.round(6), parts[1].volume.round(6)]", .expected = .{ .nums = &.{ 4000, 2000 } } },
        .{ .src = "parts = cube(10, 20, 30).split_by_plane(ny: -1, offset: -5)\nr = [parts[0].volume.round(6), parts[1].volume.round(6)]", .expected = .{ .nums = &.{ 1500, 4500 } } },
    });
}

test "Stdlib: split_by_plane keeps both halves alive across GC" {
    var vm = try initVm();
    defer vm.deinit();
    // Collect on every allocation: an unrooted half would be swept before it reaches the array.
    vm.gc.stress = true;
    defer vm.gc.stress = false;
    try testing.expectEqual(InterpretResult.ok, try runOn(&vm, "parts = cube(10).split_by_plane(0, 0, 1, 4)\nr = [parts[0].volume.round(6), parts[1].volume.round(6)]"));
    const r = vm.globals.get("r") orelse return error.MissingGlobal;
    const items = r.asArray().items.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(@as(f64, 600), items[0].asNumber());
    try testing.expectEqual(@as(f64, 400), items[1].asNumber());
}

test "Stdlib: non-finite numbers print the same on every platform" {
    // `inf - inf` is a NaN with the sign bit set on x86 (printed "-nan" by {d}) but not on
    // ARM ("nan"), so output and error messages used to differ between machines.
    try expectGlobalR(&.{
        .{ .src = "r = (Number::INFINITY - Number::INFINITY).to_s", .expected = .{ .str = "NaN" } },
        .{ .src = "r = Number::INFINITY.to_s", .expected = .{ .str = "Infinity" } },
        .{ .src = "r = (-Number::INFINITY).to_s", .expected = .{ .str = "-Infinity" } },
        .{ .src = "r = \"#{Number::NAN} #{-Number::INFINITY}\"", .expected = .{ .str = "NaN -Infinity" } },
        .{ .src = "r = (0..Number::INFINITY).to_s", .expected = .{ .str = "0..Infinity" } },
        .{ .src = "r = 2.5.to_s", .expected = .{ .str = "2.5" } },
    });
}

test "Stdlib: Sketch#contains? tests the closed 2D region" {
    // contains? on a sketch used to fail with "Native Execution Error": the method only
    // accepted solids.
    const square = "s = square(10)\n";
    const ring = "s = square(10, center: true) - circle(r: 3)\n";
    try expectGlobalR(&.{
        .{ .src = square ++ "r = s.contains?([5, 5])", .expected = .{ .boolean = true } },
        .{ .src = square ++ "r = s.contains?([15, 5])", .expected = .{ .boolean = false } },
        .{ .src = square ++ "r = s.contains?([-0.5, 5])", .expected = .{ .boolean = false } },
        // Closed region: the outline and corners count as inside.
        .{ .src = square ++ "r = s.contains?([10, 5])", .expected = .{ .boolean = true } },
        .{ .src = square ++ "r = s.contains?([0, 0])", .expected = .{ .boolean = true } },
        // A sketch lies in the z = 0 plane.
        .{ .src = square ++ "r = s.contains?([5, 5, 0])", .expected = .{ .boolean = true } },
        .{ .src = square ++ "r = s.contains?([5, 5, 3])", .expected = .{ .boolean = false } },
        // Holes are not material; their outline is.
        .{ .src = ring ++ "r = s.contains?([0, 0])", .expected = .{ .boolean = false } },
        .{ .src = ring ++ "r = s.contains?([4, 0])", .expected = .{ .boolean = true } },
        .{ .src = ring ++ "r = s.contains?([4.9, 4.9])", .expected = .{ .boolean = true } },
        // Transforms and arbitrary polygons.
        .{ .src = "s = square(2).translate(x: 20)\nr = s.contains?([21, 1])", .expected = .{ .boolean = true } },
        .{ .src = "s = square(2).translate(x: 20)\nr = s.contains?([1, 1])", .expected = .{ .boolean = false } },
        .{ .src = "s = polygon([[0, 0], [10, 0], [0, 10]])\nr = s.contains?([2, 2])", .expected = .{ .boolean = true } },
        .{ .src = "s = polygon([[0, 0], [10, 0], [0, 10]])\nr = s.contains?([8, 8])", .expected = .{ .boolean = false } },
        // Solids are unchanged.
        .{ .src = "r = cube(10).contains?([5, 5, 5])", .expected = .{ .boolean = true } },
    });
    try expectGlobalR(&.{
        .{ .src = rescued("square(10).contains?([5])"), .expected = .{ .str = "ValueError: contains? expects the point to have 2 to 3 numbers, got 1" } },
        .{ .src = rescued("cube(10).contains?([5, 5])"), .expected = .{ .str = "ValueError: contains? expects the point to have 3 numbers, got 2" } },
        .{ .src = "CAD.config(engine: :brep)\n" ++ comptime rescued("square(10).contains?([5, 5])"), .expected = .{ .str = "NotImplementedError: contains? is not supported for B-Rep sketches yet; build the sketch with the default Manifold engine" } },
    });
}

test "Stdlib: kernel failures and invalid meshes raise GeometryError instead of wrong geometry" {
    const tetra = "pts = [[0,0,0],[1,0,0],[0,1,0],[0,0,1]]\n";
    try expectGlobalR(&.{
        // Non-manifold input (inconsistent winding, a duplicated face) used to export nothing.
        .{ .src = tetra ++ comptime rescued("polyhedron(pts, [[0,1,2],[0,3,1],[0,2,3],[1,2,3]]).volume"), .expected = .{ .str = "GeometryError: polyhedron produced invalid geometry: the mesh is not a closed manifold (every edge must join exactly two faces, with consistent winding)" } },
        .{ .src = tetra ++ comptime rescued("polyhedron(pts, [[0,1,2],[0,3,1],[0,2,3],[0,1,2]]).volume"), .expected = .{ .str = "GeometryError: polyhedron produced invalid geometry: the mesh is not a closed manifold (every edge must join exactly two faces, with consistent winding)" } },
        // B-Rep offset is unimplemented; it used to return the unchanged sketch.
        .{ .src = "CAD.config(engine: :brep)\n" ++ comptime rescued("square(10).offset(1).extrude(1).volume"), .expected = .{ .str = "GeometryError: offset failed: the geometry kernel could not compute a result" } },
        // An empty result is valid geometry, not a failure.
        .{ .src = "r = (cube(1) - cube(5, center: true)).volume", .expected = .{ .num = 0 } },
        .{ .src = "r = (cube(1) & cube(1).translate(x: 5)).volume", .expected = .{ .num = 0 } },
    });
}

test "Stdlib: import_stl errors are rescuable ImportErrors, invalid meshes GeometryErrors" {
    const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    // A single triangle: valid STL, but not a closed solid.
    try mem_vfs.vfs().writeFile("tri.stl", "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid t\n");
    try mem_vfs.vfs().writeFile("junk.stl", "not an stl at all");
    const cases = [_]IterCase{
        .{ .src = rescued("import_stl(\"missing.stl\")"), .expected = .{ .str = "ImportError: could not read STL file 'missing.stl': FileNotFound" } },
        .{ .src = rescued("import_stl(\"tri.stl\").volume"), .expected = .{ .str = "GeometryError: polyhedron produced invalid geometry: the mesh is not a closed manifold (every edge must join exactly two faces, with consistent winding)" } },
    };
    for (cases) |case| {
        errdefer std.debug.print("script: {s}\n", .{case.src});
        var vm = try initVm();
        defer vm.deinit();
        vm.vfs = mem_vfs.vfs();
        try testing.expectEqual(InterpretResult.ok, try runOn(&vm, case.src));
        const r = vm.globals.get("r") orelse return error.MissingGlobal;
        try testing.expectEqualStrings(case.expected.str, r.asString().chars);
    }
    {
        var vm = try initVm();
        defer vm.deinit();
        vm.vfs = mem_vfs.vfs();
        try testing.expectEqual(InterpretResult.ok, try runOn(&vm, comptime rescued("import_stl(\"junk.stl\")")));
        const r = vm.globals.get("r") orelse return error.MissingGlobal;
        try testing.expect(std.mem.startsWith(u8, r.asString().chars, "ImportError: could not parse STL file 'junk.stl': "));
    }
}

test "Stdlib: degenerate solids are rejected or repaired instead of exported wrong" {
    const tetra = "pts = [[0,0,0],[1,0,0],[0,1,0],[0,0,1]]\n";
    const outward = "[[0,2,1],[0,1,3],[0,3,2],[1,2,3]]";
    const inward = "[[0,1,2],[0,3,1],[0,2,3],[1,3,2]]";
    try expectGlobalR(&.{
        // A tube reaching the axis makes the torus intersect itself.
        .{ .src = comptime rescued("torus(major_r: 5, minor_r: 5)"), .expected = .{ .str = "ValueError: torus needs minor_r smaller than major_r, got minor_r 5 and major_r 5" } },
        .{ .src = comptime rescued("torus(major_r: 2, minor_r: 3)"), .expected = .{ .str = "ValueError: torus needs minor_r smaller than major_r, got minor_r 3 and major_r 2" } },
        .{ .src = "r = torus(major_r: 10, minor_r: 2).volume > 0", .expected = .{ .boolean = true } },
        // An inward-wound polyhedron used to be an inside-out solid with negative volume.
        .{ .src = tetra ++ "r = polyhedron(pts, " ++ inward ++ ").volume", .expected = .{ .num = 1.0 / 6.0 } },
        .{ .src = tetra ++ "r = polyhedron(pts, " ++ outward ++ ").volume", .expected = .{ .num = 1.0 / 6.0 } },
        // ... and booleans with it were wrong.
        .{ .src = tetra ++ "r = (cube(1) - polyhedron(pts, " ++ inward ++ ")).volume", .expected = .{ .num = 1.0 - 1.0 / 6.0 } },
        // loft hulls its profiles, which only matches a true loft for convex ones.
        .{ .src = comptime rescued("polygon([[0,0],[10,0],[10,10],[5,3],[0,10]]).loft(square(2), 5).volume"), .expected = .{ .str = "NotImplementedError: loft supports convex profiles only for now; the base profile is concave or has holes" } },
        .{ .src = comptime rescued("square(4).loft(square(10, center: true) - circle(r: 2), 5).volume"), .expected = .{ .str = "NotImplementedError: loft supports convex profiles only for now; the top profile is concave or has holes" } },
        // A convex loft spans exactly [0, height]: square to equal square is a prism.
        .{ .src = "r = square(4).loft(square(4), 10).volume", .expected = .{ .num = 160 } },
        .{ .src = "r = square(4).loft(square(4), 10).bbox.max[2]", .expected = .{ .num = 10 } },
    });
}

test "Stdlib: sphere resolution follows segments and the active config" {
    const with_8_segments = "v = nil\nCAD.with_config(manifold: { fixed_segments: 8 }) do\n  v = ";
    try expectGlobalR(&.{
        // Both used to be Manifold's built-in default, whatever was asked for.
        .{ .src = "r = sphere(r: 1, segments: 8).volume < sphere(r: 1, segments: 64).volume", .expected = .{ .boolean = true } },
        .{ .src = with_8_segments ++ "sphere(r: 1).volume\nend\nr = v == sphere(r: 1, segments: 8).volume && v < sphere(r: 1, segments: 64).volume", .expected = .{ .boolean = true } },
        // fillet_edges rounds with a sphere, so its corners follow the config too.
        .{ .src = with_8_segments ++ "cube(1).fillet_edges(r: 0.5).volume\nend\nr = v == cube(1).minkowski(sphere(r: 0.5, segments: 8)).volume && v < cube(1).minkowski(sphere(r: 0.5, segments: 64)).volume", .expected = .{ .boolean = true } },
    });
}

test "Stdlib: unknown keywords are ArgumentErrors that list the accepted ones" {
    // Each of these used to be ignored silently, building the default shape instead.
    const cases = [_]struct { src: []const u8, method: []const u8, accepted: []const u8 }{
        .{ .src = "cube(1, bogus: 1)", .method = "cube", .accepted = "x, y, z, size, center, round_r, chamfer, segments" },
        .{ .src = "square(1, bogus: 1)", .method = "square", .accepted = "x, y, size, center, round_r, chamfer, segments" },
        .{ .src = "cylinder(r: 1, bogus: 1)", .method = "cylinder", .accepted = "r, r1, r2, d, d1, d2, radius, h, center, round_r, chamfer, segments" },
        .{ .src = "sphere(r: 1, bogus: 1)", .method = "sphere", .accepted = "r, d, radius, segments" },
        .{ .src = "circle(r: 1, bogus: 1)", .method = "circle", .accepted = "r, d, radius, segments" },
        .{ .src = "regular_polygon(bogus: 1)", .method = "regular_polygon", .accepted = "sides, r, d, radius" },
        .{ .src = "torus(bogus: 1)", .method = "torus", .accepted = "major_r, minor_r, segments" },
        .{ .src = "polygon([[0,0],[1,0],[0,1]], bogus: 1)", .method = "polygon", .accepted = "paths" },
        .{ .src = "polyhedron(" ++ TETRA_PTS ++ ", " ++ TETRA_FACES ++ ", bogus: 1)", .method = "polyhedron", .accepted = "points, faces" },
        .{ .src = "text(\"A\", bogus: 1)", .method = "text", .accepted = "size, tolerance, font, halign, valign" },
        .{ .src = "cube(1).translate(bogus: 1)", .method = "translate", .accepted = "x, y, z" },
        .{ .src = "cube(1).rotate(bogus: 1)", .method = "rotate", .accepted = "x, y, z" },
        .{ .src = "cube(1).scale(bogus: 1)", .method = "scale", .accepted = "x, y, z" },
        .{ .src = "cube(1).mirror(bogus: 1)", .method = "mirror", .accepted = "x, y, z" },
        .{ .src = "cube(1).resize([2], bogus: 1)", .method = "resize", .accepted = "auto" },
        .{ .src = "cube(1).repeat_linear(2, bogus: 1)", .method = "repeat_linear", .accepted = "x, y, z" },
        .{ .src = "cube(1).repeat_polar(2, bogus: 1)", .method = "repeat_polar", .accepted = "angle" },
        .{ .src = "square(1).extrude(bogus: 1)", .method = "extrude", .accepted = "h, slices, twist, scale_x, scale_y, scale, center" },
        .{ .src = "square(1).revolve(bogus: 1)", .method = "revolve", .accepted = "deg, segments" },
        .{ .src = "square(1).helix(bogus: 1)", .method = "helix", .accepted = "h, twist, slices" },
        .{ .src = "square(1).offset(bogus: 1)", .method = "offset", .accepted = "delta, join" },
        .{ .src = "cube(1).split_by_plane(bogus: 1)", .method = "split_by_plane", .accepted = "nx, ny, nz, offset" },
        .{ .src = "cube(1).fillet_edges(bogus: 1)", .method = "fillet_edges", .accepted = "r" },
        .{ .src = "cube(1).project(bogus: 1)", .method = "project", .accepted = "cut" },
        .{ .src = "cube(1).material(bogus: 1)", .method = "material", .accepted = "color, alpha, roughness, metallic, transmission" },
    };
    const iter_cases = comptime blk: {
        var list: [cases.len]IterCase = undefined;
        for (cases, &list) |case, *iter_case| iter_case.* = .{
            .src = rescued(case.src),
            .expected = .{ .str = "ArgumentError: " ++ case.method ++ " does not take a keyword 'bogus' (it accepts: " ++ case.accepted ++ ")" },
        };
        break :blk list;
    };
    try expectGlobalR(&iter_cases);

    try expectGlobalR(&.{
        // The typos that motivated the check.
        .{ .src = comptime rescued("square(1).revolve(angle: 90)"), .expected = .{ .str = "ArgumentError: revolve does not take a keyword 'angle' (it accepts: deg, segments)" } },
        .{ .src = comptime rescued("cube(1).translate(X: 5)"), .expected = .{ .str = "ArgumentError: translate does not take a keyword 'X' (it accepts: x, y, z)" } },
        // Keywords valid for one primitive are not quietly accepted by another.
        .{ .src = comptime rescued("sphere(r: 5, h: 3)"), .expected = .{ .str = "ArgumentError: sphere does not take a keyword 'h' (it accepts: r, d, radius, segments)" } },
        .{ .src = comptime rescued("cube(1, {1 => 2})"), .expected = .{ .str = "ArgumentError: cube keywords must be names, got a Number key" } },
        // Values of the wrong type used to be dropped too.
        .{ .src = comptime rescued("cube(1).material(alpha: \"half\")"), .expected = .{ .str = "TypeError: material expects a number for alpha, got String" } },
        .{ .src = comptime rescued("cube(1).project(cut: 1)"), .expected = .{ .str = "TypeError: project expects true or false for cut, got Number" } },
        .{ .src = comptime rescued("square(1).offset(1, join: :spiky)"), .expected = .{ .str = "ValueError: offset join must be square, round, miter or bevel, got 'spiky'" } },
        .{ .src = comptime rescued("cube(1).material(color: \"#FF0000\")"), .expected = .{ .str = "no error" } },
    });
}

test "Stdlib: accepted keywords and aliases still build" {
    try expectGlobalR(&.{
        .{ .src = "r = cube(size: 2).volume", .expected = .{ .num = 8 } },
        .{ .src = "r = cylinder(d: 2, h: 1, segments: 4).volume", .expected = .{ .num = 2 } },
        .{ .src = "r = cylinder(radius: 1, h: 1, segments: 4).volume", .expected = .{ .num = 2 } },
        .{ .src = "r = sphere(d: 2, segments: 8).volume == sphere(r: 1, segments: 8).volume", .expected = .{ .boolean = true } },
        .{ .src = "r = circle(d: 2, segments: 4).extrude(1).volume", .expected = .{ .num = 2 } },
        .{ .src = "r = regular_polygon(sides: 4, radius: 1).extrude(h: 1).volume", .expected = .{ .num = 2 } },
        .{ .src = "r = square(2).revolve(deg: 90).volume > 0", .expected = .{ .boolean = true } },
        .{ .src = "r = cube(1).repeat_polar(4, angle: 90).volume > 1", .expected = .{ .boolean = true } },
        .{ .src = "r = cube(2).project(cut: true).extrude(1).volume", .expected = .{ .num = 4 } },
        .{ .src = "r = cube(1).fillet_edges(r: 0.1).volume > 1", .expected = .{ .boolean = true } },
        .{ .src = "r = polyhedron(points: " ++ TETRA_PTS ++ ", faces: " ++ TETRA_FACES ++ ").volume", .expected = .{ .num = 1.0 / 6.0 } },
    });
}

test "Stdlib: Sketch transforms stay in the XY plane" {
    const diagonal = 2.0 * std.math.sqrt2; // A 2x2 square turned 45 degrees spans its diagonal.
    try expectGlobalR(&.{
        // rotate(z:) and rotate(0, 0, a) used to read x, so they did not rotate at all.
        .{ .src = "r = square(2).rotate(z: 45).extrude(1).bbox.max[1]", .expected = .{ .num = diagonal } },
        .{ .src = "r = square(2).rotate(0, 0, 45).extrude(1).bbox.max[1]", .expected = .{ .num = diagonal } },
        .{ .src = "r = square(2).rotate(45).extrude(1).bbox.max[1]", .expected = .{ .num = diagonal } },
        // ... and rotate(x:) turned the sketch in its plane instead of tilting it.
        .{ .src = comptime rescued("square(2).rotate(x: 45)"), .expected = .{ .str = "ValueError: a Sketch can only rotate about z (it lies in the XY plane), got x 45 and y 0; extrude it to tilt it" } },
        .{ .src = comptime rescued("square(2).rotate(45, 0, 0)"), .expected = .{ .str = "ValueError: a Sketch can only rotate about z (it lies in the XY plane), got x 45 and y 0; extrude it to tilt it" } },
        // translate(z:) was dropped.
        .{ .src = comptime rescued("square(2).translate(z: 5)"), .expected = .{ .str = "ValueError: a Sketch can only translate in x and y (it lies in the XY plane), got z 5; extrude it to lift it" } },
        .{ .src = "r = square(2).translate(1, 2, 0).extrude(1).bbox.min[1]", .expected = .{ .num = 2 } },
        // mirror used to fail with a generic error on a Sketch.
        .{ .src = "r = square(2).mirror(1, 0).extrude(1).bbox.min[0]", .expected = .{ .num = -2 } },
        .{ .src = "r = square(2).mirror(x: 1, y: 1).extrude(1).bbox.min", .expected = .{ .nums = &.{ -2, -2, 0 } } },
        .{ .src = "r = square(2).mirror(1, 0).extrude(1).volume", .expected = .{ .num = 4 } },
        .{ .src = comptime rescued("square(2).mirror(0, 0, 1)"), .expected = .{ .str = "ValueError: a Sketch can only mirror across a line in the XY plane, got a normal with z 1" } },
    });
}
