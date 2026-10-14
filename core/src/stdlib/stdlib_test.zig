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
        .{ .src = "(1e400 - 1e400).times { }", .prefix = "ValueError: times requires an integer" },
        .{ .src = "3.times", .prefix = "ArgumentError: times requires a block" },
        .{ .src = "(0..3).each", .prefix = "ArgumentError: Range#each requires a block" },
        .{ .src = "(0..3).map", .prefix = "ArgumentError: Range#map requires a block" },
        .{ .src = "(0..3).step(0)", .prefix = "ValueError: Range#step requires a finite, non-zero step" },
        .{ .src = "(0..3).step(1e400)", .prefix = "ValueError: Range#step requires a finite, non-zero step" },
        .{ .src = "(0..1e400).to_a", .prefix = "ValueError: Range#to_a requires finite bounds" },
        .{ .src = "(0..(1e400 - 1e400)).size", .prefix = "ValueError: Range#size requires finite bounds" },
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
        "polygon([[0,0],[10,1e400 - 1e400],[10,10]])",
        "polygon([[0,0],[1e400,0],[10,10]])",
        "polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0,-1e400]], " ++ TETRA_FACES ++ ")",
        "cube(1).translate(1e400, 0, 0)",
        "cube(1).translate(z: 1e400 - 1e400)",
        "cube(1).rotate(x: 1e400)",
        "square(1).rotate(1e400 - 1e400)",
        "cube(1).scale(1e400, 1, 1)",
        "cube(1).mirror(1e400 - 1e400, 0, 0)",
        "cube(1).transform([1,0,0, 0,1,0, 0,0,1, 0,0,1e400])",
        "square(1).transform([1,0, 0,1, 1e400 - 1e400,0])",
        "cube(1).resize([1e400, 0, 0])",
        "cube(1).align(cube(2), \"z\", \"min\", \"max\", 1e400)",
        "cube(1).align(cube(2), \"z\", \"min\", 1e400 - 1e400)",
        "cube(1).repeat_linear(3, [1e400, 0, 0])",
        "cube(1).repeat_linear(3, 0, 0, 1e400 - 1e400)",
        "cube(1).repeat_polar(3, 1e400 - 1e400)",
        "square(1).offset(1e400)",
        "cube(1).trim_by_plane(0, 0, 1, 1e400)",
        "cube(1).slice(1e400 - 1e400)",
        "cube(1).on_face([0, 0, 1e400])",
        "cube(1).split_by_plane(0, 0, 1, 1e400 - 1e400)",
        "cube(1).fillet_edges(1e400)",
        "cube(1).simplify(1e400 - 1e400)",
        "cube(1).contains?([0, 1e400, 0])",
        "cube(1).ray_cast([0, 0, 1e400 - 1e400], [0, 0, -5])",
        "cube(1).min_gap(cube(1), 1e400)",
        "cube(size: 1e400 - 1e400)",
        "torus(major_r: 1e400)",
        "text(\"A\", size: 1e400 - 1e400)",
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
        .{ .src = rescued("polygon([[0,0],[1,0],[0,1e400]])"), .expected = .{ .str = "ValueError: polygon expects a finite number for a coordinate (point 2, component 1), got Infinity" } },
        .{ .src = rescued("polygon([[0,0],[1,0],[0,1]], paths: [[0,1,2], 7])"), .expected = .{ .str = "TypeError: polygon expects an Array for path 1, got Number" } },
        .{ .src = rescued("polygon([[0,0],[1,0],[0,1]], paths: [[0,1]])"), .expected = .{ .str = "ValueError: polygon needs at least 3 point indices in path 0, got 2" } },
        .{ .src = rescued("polygon([[0,0],[1,0],[0,1]], paths: [[0,1,1e400]])"), .expected = .{ .str = "ValueError: polygon expects a finite number for a point index (path 0, entry 2), got Infinity" } },
        .{ .src = rescued("cube(1).transform([1,0,0, 0,1,0, 0,0,1e400, 0,0,0])"), .expected = .{ .str = "ValueError: transform expects a finite number for a matrix entry (index 8), got Infinity" } },
    });
}

test "Stdlib: rescued argument errors name the method, the position and the bad type" {
    try expectGlobalR(&.{
        .{ .src = rescued("polygon([[0,0],[10,\"x\"],[10,10]]).extrude(1).volume"), .expected = .{ .str = "TypeError: polygon expects a number for a coordinate (point 1, component 1), got String" } },
        .{ .src = rescued("polygon([[0,0],[10,0],[1e400 - 1e400,10]])"), .expected = .{ .str = "ValueError: polygon expects a finite number for a coordinate (point 2, component 0), got NaN" } },
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
        .{ .src = rescued("cube(1).translate(1e400)"), .expected = .{ .str = "ValueError: translate expects a finite number for x, got Infinity" } },
        .{ .src = rescued("cube(1).mirror(0, 0, 0)"), .expected = .{ .str = "ValueError: mirror expects a non-zero plane normal, got [0, 0, 0]" } },
        .{ .src = rescued("cube(1).scale(1, 0, 1)"), .expected = .{ .str = "ValueError: scale factors must be non-zero, got [1, 0, 1]" } },
        // Errors that used to surface as the generic "Native Execution Error" when rescued.
        .{ .src = rescued("polyhedron(" ++ TETRA_PTS ++ ", [[0,1,2],[0,3,1],[0,2,3],[4,2,3]])"), .expected = .{ .str = "ValueError: polyhedron face index 4 is out of range (0..4)" } },
        .{ .src = rescued("cube(1e400 - 1e400)"), .expected = .{ .str = "ValueError: cube expects a finite number for x, got NaN" } },
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
        .{ .src = "r = (1e400 - 1e400).to_s", .expected = .{ .str = "NaN" } },
        .{ .src = "r = 1e400.to_s", .expected = .{ .str = "Infinity" } },
        .{ .src = "r = (-1e400).to_s", .expected = .{ .str = "-Infinity" } },
        .{ .src = "r = \"#{1e400 - 1e400} #{-1e400}\"", .expected = .{ .str = "NaN -Infinity" } },
        .{ .src = "r = (0..1e400).to_s", .expected = .{ .str = "0..Infinity" } },
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
