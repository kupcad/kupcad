//! Regression tests for issues found in the Oct 2026 audit.
//!
//! Stdlib input validation: user-supplied numbers must be rejected with a clean
//! runtime error before they reach @intFromFloat (UB in ReleaseFast) or a kernel.

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
const topo_arena = @import("../locus/src/topology/arena.zig");
const geom_arena = @import("../locus/src/geometry/arena.zig");
const generators = @import("../locus/src/operations/generators.zig");

/// Compiles and runs `source`, returning the interpreter result. Errors are
/// muted because the test runner treats logged errors as failures.
fn runScript(source: []const u8) !InterpretResult {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    return vm.interpret(&out_chunk);
}

fn expectRuntimeError(source: []const u8) !void {
    try testing.expectEqual(InterpretResult.runtime_error, try runScript(source));
}

test "Regression validation: i32 kwargs reject huge and NaN values" {
    try expectRuntimeError("cylinder(r: 1, h: 1, segments: 1e12)");
    try expectRuntimeError("cylinder(r: 1, h: 1, segments: 1e400 - 1e400)");
    try expectRuntimeError("square(10).extrude(5, slices: -1e12)");
    try expectRuntimeError("square(10).helix(slices: 1e400 - 1e400)");
}

test "Regression validation: segment counts are capped by MAX_SEGMENTS" {
    try expectRuntimeError("cylinder(r: 1, h: 1, segments: 2e9)");
    try expectRuntimeError("circle(r: 1, segments: 1e6)");
    try expectRuntimeError("torus(10, 2, segments: 100000)");
    try expectRuntimeError("regular_polygon(1e6, 5)");
    try expectRuntimeError("regular_polygon(sides: 1e400 - 1e400)");
    try expectRuntimeError("square(10).extrude(5, slices: 100000)");
    // Sane values still work.
    try testing.expectEqual(InterpretResult.ok, try runScript("cylinder(r: 1, h: 1, segments: 32)"));
}

test "Regression validation: CAD.config fixed_segments is clamped instead of UB" {
    try testing.expectEqual(InterpretResult.ok, try runScript(
        \\CAD.config(manifold: { fixed_segments: 1e12 })
        \\CAD.config(manifold: { fixed_segments: 1e400 - 1e400 })
    ));
}

test "Regression validation: positive/non-negative checks reject NaN and inf" {
    try expectRuntimeError("cube(1e400 - 1e400)");
    try expectRuntimeError("sphere(1e400)");
    try expectRuntimeError("cylinder(r: Math.sqrt(-1), h: 1)");
}

test "Regression validation: text tolerance cannot be vanishingly small" {
    try expectRuntimeError("text(\"A\", tolerance: 1e-300)");
}

test "Regression validation: polyhedron face indices are bounds-checked" {
    try expectRuntimeError("polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0,1]], [[0,1,2],[0,3,1],[0,2,3],[-1,2,3]])");
    try expectRuntimeError("polyhedron([[0,0,0],[1,0,0],[0,1,0],[0,0,1]], [[0,1,2],[0,3,1],[0,2,3],[99,2,3]])");
    try expectRuntimeError("polygon([[0,0],[1,0],[0,1]], paths: [[0,1,-1]])");
}

test "Regression validation: repeat counts reject NaN and huge values" {
    try expectRuntimeError("cube(1).repeat_linear(1e12, [2, 0, 0])");
    try expectRuntimeError("cube(1).repeat_polar(1e400 - 1e400)");
    // Negative counts keep their historical no-op meaning.
    try testing.expectEqual(InterpretResult.ok, try runScript("cube(1).repeat_linear(-5, [2, 0, 0])"));
}

test "Regression validation: B-Rep buildPolyhedron rejects out-of-range face indices" {
    const alloc = testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const pts = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 0, 10, 0 }, .{ 0, 0, 10 } };
    const faces = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 99, 0, 3 } };
    try testing.expectError(error.InvalidFaceIndex, generators.buildPolyhedron(alloc, &t_arena, &g_arena, &pts, &faces));
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
