const std = @import("std");
const testing = std.testing;
const VM = @import("../vm/vm.zig").VM;
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("registry.zig");
const kernel = @import("../kernel/kernel.zig");

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
