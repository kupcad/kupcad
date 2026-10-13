//! Regression tests for issues found in the Oct 2026 audit.
//!
//! Stdlib input validation: user-supplied numbers must be rejected with a clean
//! runtime error before they reach @intFromFloat (UB in ReleaseFast) or a kernel.
//!
//! The scripts below only build DAG nodes (geometry is evaluated lazily), so a
//! runtime error can only come from argument validation, not from a kernel.
//! `1e400` is +inf and `1e400 - 1e400` is NaN (the VM traps `0.0 / 0.0` itself).

const std = @import("std");
const testing = std.testing;
const VM = @import("../vm/vm.zig").VM;
const InterpretResult = @import("../vm/vm.zig").InterpretResult;
const chunk = @import("../vm/chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("registry.zig");
const limits = @import("../core/limits.zig");
const stl_format = @import("../formats/stl.zig");
const stl_import = @import("../exporters/3d/stl.zig");

const print = std.fmt.comptimePrint;
const MAX_SEGS = limits.MAX_SEGMENTS;
const MAX_COUNT = limits.MAX_PATTERN_COUNT;

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

test "Regression validation: integer kwargs reject NaN, inf and out-of-i32 values" {
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

test "Regression validation: tessellation counts are capped at MAX_SEGMENTS" {
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

test "Regression validation: auto-computed segment counts are clamped to MAX_SEGMENTS" {
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

test "Regression validation: CAD.config fixed_segments is clamped instead of UB" {
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

test "Regression validation: CAD.config brep counts are clamped instead of UB" {
    const defaults = @import("../core/engine_config.zig").BRepConfig{};
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

test "Regression validation: Array#slice follows Ruby arr[start, len] semantics" {
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

test "Regression validation: dimensions and sweep parameters reject NaN and inf" {
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

test "Regression validation: text tolerance cannot be vanishingly small" {
    try expectAll(.runtime_error, &.{
        // Degenerate: its square underflows to 0 in the Bezier flattening test.
        "text(\"A\", tolerance: 1e-300)",
        // The minimum is relative to the glyph size (0.05 is fine at the default size).
        "text(\"A\", size: 1000, tolerance: 0.05)",
    });
}

test "Regression validation: polyhedron and polygon path indices are bounds-checked" {
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

test "Regression validation: repeat counts reject NaN and values above MAX_PATTERN_COUNT" {
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

test "Regression validation: binary STL triangle count cannot wrap the length check" {
    // 85_899_346 * 50 == 2^32 + 4, so in u32 math 84 + n*50 wraps to 88 and a
    // 100-byte buffer used to pass the check and then be read far out of bounds.
    var data: [100]u8 = @splat(0);
    std.mem.writeInt(u32, data[80..84], 85_899_346, .little);
    try testing.expectError(error.InvalidStl, stl_format.readBinary(testing.allocator, &data));
    // The importer must not trust the count either (falls back to ASCII, which finds no facets).
    try testing.expectError(error.InvalidStl, stl_import.parseStlBuffer(testing.allocator, &data));
}
