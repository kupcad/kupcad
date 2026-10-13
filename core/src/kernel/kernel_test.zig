const std = @import("std");
const testing = std.testing;
const kernel = @import("kernel.zig");
const geom = @import("geometry_handle.zig");
const VM = @import("../vm/vm.zig").VM;
const InterpretResult = @import("../vm/vm.zig").InterpretResult;
const chunk = @import("../vm/chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");

fn initVm() !VM {
    var vm = try VM.init(testing.allocator, testing.io);
    errdefer vm.deinit();
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);
    return vm;
}

/// Compiles and runs `source` on an existing VM.
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
    defer vm.deinit(); // double frees used to crash here
    return runOn(&vm, source);
}

test "Kernel Dispatcher: routes primitives to the requested engine" {
    inline for (.{ geom.EngineType.manifold, geom.EngineType.brep_native }) |engine| {
        const handle = kernel.cube(engine, 10.0, 10.0, 10.0, true) orelse return error.DispatchFailed;
        defer kernel.destruct(handle);

        // The returned handle is tagged with, and usable by, the requested engine.
        try testing.expectEqual(engine, handle.engine);
        try testing.expectEqual(@as(i32, 8), kernel.numVerts(handle));
    }
}

test "Kernel Dispatcher: rejects mixed-engine operands at runtime" {
    // Engine tags must be checked: a handle of one engine is never fed to the other.
    const m = kernel.cube(.manifold, 10, 10, 10, false) orelse return error.KernelFailed;
    defer kernel.destruct(m);
    const b = kernel.cube(.brep_native, 20, 20, 20, false) orelse return error.KernelFailed;
    defer kernel.destruct(b);

    try testing.expect(kernel.boolean(b, m, .difference_op) == null);
    try testing.expect(kernel.boolean(m, b, .union_op) == null);
    try testing.expect(kernel.minkowski(m, b) == null);
    try testing.expect(kernel.batchBoolean(testing.allocator, &.{ m, b }, .union_op) == null);
    try testing.expect(kernel.batchHull(testing.allocator, &.{ b, m }) == null);
    try testing.expectEqual(@as(f64, 0.0), kernel.minGap(m, b, 1.0));
}

// --- Handle ownership (single-owner rule) ---

test "Kernel: B-Rep scripts using material/decompose/simplify do not double free" {
    // B-Rep drivers used to return their input handle, so both owners freed it.
    try testing.expectEqual(InterpretResult.ok, try runScript(
        \\CAD.config(engine: :brep)
        \\part = cube(10).material(color: "#FF0000")
        \\part.volume
    ));
    try testing.expectEqual(InterpretResult.ok, try runScript(
        \\CAD.config(engine: :brep)
        \\part = cube(10).decompose[0]
        \\part.volume
    ));
    try testing.expectEqual(InterpretResult.ok, try runScript(
        \\CAD.config(engine: :brep)
        \\part = cube(10).simplify
        \\part.volume
    ));
}

test "Kernel: ghost display list survives garbage collection" {
    // The display list must own its handle, not borrow the dag_cache's.
    var vm = try initVm();
    defer vm.deinit();

    try testing.expectEqual(InterpretResult.ok, try runOn(&vm, "cube(10).ghost\nnil"));
    try testing.expectEqual(@as(usize, 1), vm.display_list.items.len);

    // Nothing roots the ghost geometry; a GC evicts its dag_cache entry.
    vm.resetStack();
    vm.gc.collectGarbage(&vm, false);
    try testing.expectEqual(@as(u32, 0), vm.dag_cache.count());

    try testing.expectApproxEqAbs(@as(f64, 1000.0), kernel.volume(vm.display_list.items[0]), 1e-6);
}
