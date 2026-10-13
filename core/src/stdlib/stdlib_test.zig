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
// `1e400` is +inf and `1e400 - 1e400` is NaN (the VM traps `0.0 / 0.0` itself).

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
        "cylinder(r: 1, h: 1, segments: 1e400)",
        "cylinder(r: 1, h: 1, segments: 1e400 - 1e400)",
        "square(10).extrude(5, slices: -1e12)",
        "square(10).helix(slices: 1e400 - 1e400)",
        "regular_polygon(sides: 1e12, r: 5)",
        "regular_polygon(1e400, 5)",
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
        .{ .src = "CAD.config(manifold: { fixed_segments: 1e400 })", .expected = @intCast(MAX_SEGS) },
        .{ .src = "CAD.config(manifold: { fixed_segments: 1e400 - 1e400 })", .expected = 0 },
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
        .{ .src = "CAD.config(brep: { min_circle_segments: 1e400 })", .field = .min_circle_segments, .expected = @intCast(MAX_SEGS) },
        .{ .src = "CAD.config(brep: { min_circle_segments: -5 })", .field = .min_circle_segments, .expected = 0 },
        .{ .src = "CAD.config(brep: { min_circle_segments: 32.7 })", .field = .min_circle_segments, .expected = 32 },
        // NaN keeps the current value (0 is not an "auto" sentinel for these fields).
        .{ .src = "CAD.config(brep: { min_circle_segments: 1e400 - 1e400 })", .field = .min_circle_segments, .expected = defaults.min_circle_segments },
        .{ .src = "CAD.config(brep: { max_newton_trials: 1e12 })", .field = .max_newton_trials, .expected = limits.MAX_NEWTON_TRIALS },
        .{ .src = "CAD.config(brep: { max_newton_trials: 1e400 - 1e400 })", .field = .max_newton_trials, .expected = defaults.max_newton_trials },
        .{ .src = "CAD.config(brep: { max_newton_trials: 20 })", .field = .max_newton_trials, .expected = 20 },
        .{ .src = "CAD.config(brep: { max_marching_steps: 1e400 })", .field = .max_marching_steps, .expected = limits.MAX_MARCHING_STEPS },
        .{ .src = "CAD.config(brep: { max_marching_steps: -1e400 })", .field = .max_marching_steps, .expected = 0 },
        .{ .src = "CAD.config(brep: { max_marching_steps: 1e400 - 1e400 })", .field = .max_marching_steps, .expected = defaults.max_marching_steps },
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
        .{ .args = "-1e400, 1", .expected = nil },
        // Lengths are clamped to what is available (1e12 used to over-allocate).
        .{ .args = "1, 1e12", .expected = &.{ 2, 3 } },
        .{ .args = "1, 1e400", .expected = &.{ 2, 3 } },
        // start == size is an empty slice; past the end is nil.
        .{ .args = "3, 1", .expected = &.{} },
        .{ .args = "4, 1", .expected = nil },
        .{ .args = "1e12, 1", .expected = nil },
        .{ .args = "1e400, 1", .expected = nil },
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
        "[1, 2, 3].slice(1e400 - 1e400, 1)",
        "[1, 2, 3].slice(0, 1e400 - 1e400)",
    });
}

test "Stdlib: dimensions and sweep parameters reject NaN and inf" {
    try expectAll(.runtime_error, &.{
        "cube(1e400 - 1e400)",
        "sphere(1e400)",
        "cylinder(r: Math.sqrt(-1), h: 1)",
        "square(10).extrude(1e400 - 1e400)",
        "square(10).extrude(5, twist: 1e400)",
        "square(10).extrude(5, scale: 1e400 - 1e400)",
        "square(10).helix(1e400)",
        "square(10).helix(5, 1e400 - 1e400)",
        "square(10).translate(x: 20).revolve(1e400 - 1e400)",
        "square(10).loft(circle(r: 5), 1e400)",
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
        "polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0,1]], [[0,1,2],[0,3,1],[0,2,3],[1e400 - 1e400,2,3]])",
        "polygon([[0,0],[1,0],[0,1]], paths: [[0,1,-1]])",
        "polygon([[0,0],[1,0],[0,1]], paths: [[0,1,1.5]])",
        // An error in a later path used to free the uninitialised contour slots.
        "polygon([[0,0],[1,0],[0,1]], paths: [[0,1,2],[0,1,3]])",
    });
}

test "Stdlib: repeat counts reject NaN and values above MAX_PATTERN_COUNT" {
    try expectAll(.runtime_error, &.{
        print("cube(1).repeat_linear({d}, [2, 0, 0])", .{MAX_COUNT + 1}),
        "cube(1).repeat_linear(1e400, [2, 0, 0])",
        print("cube(1).repeat_polar({d})", .{MAX_COUNT + 1}),
        "cube(1).repeat_polar(1e400 - 1e400)",
    });
    // Negative counts are a no-op (they used to panic in @intFromFloat to usize).
    try expectAll(.ok, &.{
        "cube(1).repeat_linear(-5, [2, 0, 0])",
        "cube(1).repeat_polar(-5)",
    });
}

// --- Range iteration and Number#times/upto/downto ---

const MAX_ITER = limits.MAX_RANGE_ITERATIONS;

/// What a script leaves in the global `r`.
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
            .num => |want| try testing.expectEqual(want, r.asNumber()),
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

test "Stdlib: range and times errors are rescuable ValueErrors with the real message" {
    const max_iter = std.fmt.comptimePrint("{d}", .{MAX_ITER});
    const cases = [_]struct { src: []const u8, prefix: []const u8 }{
        .{ .src = "2.5.times { }", .prefix = "ValueError: times requires an integer" },
        .{ .src = "(1e400 - 1e400).times { }", .prefix = "ValueError: times requires an integer" },
        .{ .src = "3.times", .prefix = "ValueError: times requires a block" },
        .{ .src = "(0..3).each", .prefix = "ValueError: Range#each requires a block" },
        .{ .src = "(0..3).map", .prefix = "ValueError: Range#map requires a block" },
        .{ .src = "(0..3).step(0)", .prefix = "ValueError: Range#step requires a finite, non-zero step" },
        .{ .src = "(0..3).step(1e400)", .prefix = "ValueError: Range#step requires a finite, non-zero step" },
        .{ .src = "(0..1e400).to_a", .prefix = "ValueError: Range#to_a requires finite bounds" },
        .{ .src = "(0..(1e400 - 1e400)).size", .prefix = "ValueError: Range#size requires finite bounds" },
        .{ .src = "1.upto(2.5) { }", .prefix = "ValueError: upto requires an integer" },
        .{ .src = "1.5.downto(0) { }", .prefix = "ValueError: downto requires an integer" },
        // One past the cap is rejected before the loop starts (no hang, no partial work).
        .{ .src = "(0.." ++ max_iter ++ ").each { |i| }", .prefix = "ValueError: Range#each would iterate" },
        .{ .src = "(0..1e12).to_a", .prefix = "ValueError: Range#to_a would iterate" },
        .{ .src = "(" ++ max_iter ++ " + 1).times { }", .prefix = "ValueError: times would iterate" },
    };
    for (cases) |case| {
        var src_buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, "r = begin\n  {s}\n  \"no error\"\nrescue => e\n  e.message\nend", .{case.src});
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
    // Exactly at the cap is allowed: size doesn't iterate, so this stays cheap.
    try expectGlobalR(&.{
        .{ .src = "r = (1.." ++ max_iter ++ ").size", .expected = .{ .num = @floatFromInt(MAX_ITER) } },
    });
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
