//! VM tests of the geometry a script makes: primitives, sketches, booleans, sweeps, transforms,
//! measures and spatial queries, export and import.

const std = @import("std");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const testing = std.testing;
const ast = @import("../core/ast.zig");
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const resolver = @import("../core/resolver.zig");
const value = @import("../core/value.zig");
const kernel = @import("../kernel/kernel.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
const Profiler = @import("profiler.zig").Profiler;
const geom = @import("../kernel/geometry_handle.zig");
const VM = @import("vm.zig").VM;
const InterpretResult = @import("vm.zig").InterpretResult;
const ErrorKind = @import("error_kind.zig").ErrorKind;
const helpers = @import("vm_test_helpers.zig");
const executeAndAssertStack = helpers.executeAndAssertStack;
const writeGlobalOp = helpers.writeGlobalOp;

test "VM: Execute native CAD function (cube) generates symbolic DAG node" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const cube_name = try vm.allocateString("cube");
    vm.push(cube_name);
    const name_idx = try out_chunk.addConstant(testing.allocator, cube_name);
    _ = vm.pop();

    try writeGlobalOp(&out_chunk, .op_get_global, name_idx);
    try out_chunk.writeOp(testing.allocator, .op_call, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.write(testing.allocator, 0, 0); // CallFlags
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 2;

    const returned_geom = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(returned_geom.isGeometry());

    const geometry = returned_geom.asGeometry();
    try testing.expectEqual(false, geometry.isConcrete());
    try testing.expect(vm.dag_builder.nodes.items.len > 0);
}

test "VM: End-to-end compilation of fluent API method chaining (cube().translate())" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});
    const cube_call = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    const translate_str = try b.intern("translate");
    const translate_call = try b.methodCall(cube_call, translate_str, empty_args, .none, false, 0, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(translate_call);

    const returned_geom = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(returned_geom.isGeometry());
    try testing.expectEqual(false, returned_geom.asGeometry().isConcrete());
}

test "VM: Executes CSG Operator Overloading lazily (cube() + cube())" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const cube_str = try b.intern("cube");
    const empty_args = try b.addNamedArgs(&.{});
    const cube1 = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);
    const cube2 = try b.methodCall(.none, cube_str, empty_args, .none, false, 0, 0);

    const add_node = try b.binary(.add, cube1, cube2, 0);

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &b.tree, &.{}, &[_]u32{}, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(add_node);

    const final_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(final_val.isGeometry());
}

test "VM Edge Case: Gracefully handles method calls on raw primitives" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    // Built by hand, so registered as the compiler registers its chunks: under -Dgc-stress the
    // values it holds were swept before the run began.
    try vm.gc.trackChunk(&out_chunk);

    const num_idx = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(5.0));

    const m_val = try vm.allocateString("fake_method");
    vm.push(m_val);
    const m_idx = try out_chunk.addConstant(testing.allocator, m_val);
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(num_idx), 0);

    try out_chunk.writeOp(testing.allocator, .op_invoke, 0);
    try out_chunk.write(testing.allocator, @intCast(m_idx), 0);
    try out_chunk.write(testing.allocator, 0, 0); // 0 args
    try out_chunk.write(testing.allocator, 0, 0); // CallFlags

    // --- MANUAL INLINE CACHE ---
    const ic_idx = try out_chunk.addInlineCache(testing.allocator);
    try out_chunk.write(testing.allocator, @intCast((ic_idx >> 8) & 0xFF), 0);
    try out_chunk.write(testing.allocator, @intCast(ic_idx & 0xFF), 0);

    out_chunk.max_stack_slots = 3;

    const result = vm.interpret(&out_chunk);
    // You can't call methods on a raw float, so it should abort cleanly.
    try testing.expectEqual(.runtime_error, result);
}

test "VM: Primitives support flexible keyword arguments and shortcuts" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Tests:
    // 1. cube(10) -> uniform 10x10x10 cube
    // 2. cube(x: 10, y: 20, z: 30, center: true) -> explicit axes & center
    // 3. sphere(d: 20) -> diameter conversion to r=10
    // 4. cylinder(d: 10, h: 15) -> diameter & height overrides
    const source =
        \\c1 = cube(10)
        \\c2 = cube(x: 10, y: 20, z: 30, center: true)
        \\s1 = sphere(d: 20)
        \\cyl = cylinder(d: 10, h: 15)
        \\[c1.bbox(), c2.bbox(), s1.bbox(), cyl.bbox()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    // Verify the returned array contains all 4 bounding boxes
    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);
}

test "STL Exporter: exports valid Binary STL file with expected byte structure" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    // The export lands in memory, never in the working directory.
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    vm.vfs = mem_vfs.vfs();
    const test_stl_path = "test_export_cube.stl";

    // 1. Run script exporting a 10x10x10 cube
    const source =
        \\part = cube(10)
        \\part.export_stl("test_export_cube.stl")
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = vm.interpret(&out_chunk);

    try testing.expectEqual(.ok, result);

    // 2. Read the generated STL file back
    const file_contents = try mem_vfs.vfs().readFile(testing.allocator, test_stl_path);
    defer testing.allocator.free(file_contents);

    // Header must be at least 84 bytes (80-byte header + 4-byte triangle count)
    try testing.expect(file_contents.len >= 84);

    // Read the 32-bit triangle count from bytes 80..84 (little-endian)
    const tri_count = std.mem.readInt(u32, file_contents[80..84], .little);

    // A standard cube has 12 triangles (2 per face * 6 faces)
    try testing.expectEqual(@as(u32, 12), tri_count);

    // Verify exact binary size: 84 + (12 triangles * 50 bytes) = 684 bytes
    const expected_file_size = 84 + (@as(usize, tri_count) * 50);
    try testing.expectEqual(expected_file_size, file_contents.len);
}

test "VM: Inspection methods (volume, bbox) and inspect() work in KupCAD scripts" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    // Mute print_handler during unit tests
    vm.host.print_handler = null;

    const source =
        \\base = cube(size: 30, center: true)
        \\hole = cylinder(d: 10, h: 40, center: true)
        \\part = base - hole
        \\inspect(part.volume())
        \\inspect(part.bbox())
        \\part
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isGeometry());

    // Relaxed volume bounds for 16-segment dynamic arc resolution (~24,688.7)
    const handle = try vm.ensureConcrete(result);
    const vol = kernel.volume(handle);
    try testing.expect(vol > 24500.0 and vol < 24800.0);
}

test "VM: 2D Boolean Operations (Union, Difference, Intersection) work seamlessly before 3D extrusion" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Test script:
    // 1. Create a 20x20 square plate (Area = 400)
    // 2. Subtract a D=10 circle from it (Area = pi * r^2 = ~78.54)
    // 3. Extrude the result by 10 units (Volume = Area * 10 = ~3214.6)
    const source =
        \\sq = square(size: 20, center: true)
        \\circ = circle(d: 10)
        \\part2d = sq - circ
        \\part3d = part2d.extrude(10)
        \\part3d.volume()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Relaxed volume bounds for 16-segment dynamic arc resolution (~3235.4)
    const vol = result.asNumber();
    try testing.expect(vol > 3200.0 and vol < 3250.0);
}

test "VM: Minkowski sums and 2D Offsets evaluate correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Test script:
    // 1. Minkowski: A 10x10x10 cube and a r=2 sphere.
    //    Bounds should expand from [-5, 5] to [-7, 7].
    // 2. Offset: A 10x10 square offset by 2 (creates rounded corners by default).
    //    Area = 100 (base) + 80 (edges) + ~12.56 (corners) = ~192.56.
    //    Extruded by 10 = ~1925.6 volume.
    const source =
        \\c = cube(size: 10, center: true)
        \\s = sphere(r: 2)
        \\m_part = c.minkowski(s)
        \\
        \\sq = square(size: 10, center: true)
        \\off_sq = sq.offset(2)
        \\off_part = off_sq.extrude(10)
        \\
        \\[m_part.bbox(), off_part.volume()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();

    // 1. Minkowski Native BBox check
    const bbox_inst = arr_obj.items.items[0].asBBox();
    try testing.expect(bbox_inst.min[0] < 0.0);
    try testing.expect(bbox_inst.max[1] > 0.0);

    // 2. Offset volume check (~1925.6)
    const vol = arr_obj.items.items[1].asNumber();
    try testing.expect(vol > 1900.0 and vol < 2000.0);
}

test "VM: Affine transformations via multmatrix evaluate correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Test script:
    // 1. 3D Transform: Translate a cube by +5, +10, +15 using an explicit 4x3 matrix.
    // 2. 2D Transform: Translate a square by +2, +4 using an explicit 3x2 matrix.
    const source =
        \\c = cube(size: 10, center: true)
        \\c_trans = c.transform([1, 0, 0,  0, 1, 0,  0, 0, 1,  5, 10, 15])
        \\
        \\sq = square(size: 10, center: true)
        \\sq_trans = sq.transform([1, 0,  0, 1,  2, 4])
        \\
        \\[c_trans.bbox(), sq_trans.extrude(10).bbox()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();

    // Check 3D Transform natively
    const c_bbox = arr_obj.items.items[0].asBBox();
    try testing.expectEqual(@as(f64, 0.0), c_bbox.min[0]); // -5 + 5
    try testing.expectEqual(@as(f64, 5.0), c_bbox.min[1]); // -5 + 10

    // Check 2D Transform natively
    const sq_bbox = arr_obj.items.items[1].asBBox();
    try testing.expectEqual(@as(f64, -3.0), sq_bbox.min[0]); // -5 + 2
    try testing.expectEqual(@as(f64, -1.0), sq_bbox.min[1]); // -5 + 4
}

test "VM: Spatial Queries (min_gap, contains?, ray_cast) evaluate safely" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Script:
    // 1. Min Gap between two cubes offset by 15 units. Gap should be 5.
    // 2. Contains point: cube size 10, center true. contains [0,0,0], doesn't contain [10, 10, 10]
    // 3. Ray cast: cube size 10. Cast from [0, 0, 10] to [0, 0, -10]. Hits top face at z=5.
    const source =
        \\c1 = cube(size: 10, center: true)
        \\c2 = cube(size: 10, center: true).translate(15, 0, 0)
        \\gap = c1.min_gap(c2)
        \\
        \\in1 = c1.contains?([0, 0, 0])
        \\in2 = c1.contains?([10, 10, 10])
        \\
        \\ray_hits = c1.ray_cast([0, 0, 10], [0, 0, -10])
        \\
        \\[gap, in1, in2, ray_hits.length(), ray_hits[0]["distance"], ray_hits[0]["position"][2]]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(arr_val.isArray());
    const arr_obj = arr_val.asArray();

    // 1. Min gap (kernel extrema search)
    try testing.expect(arr_obj.items.items[0].asNumber() > 0.0);
    // 2. Contains [0,0,0] = true
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());
    // 3. Contains [10,10,10] = false
    try testing.expectEqual(false, arr_obj.items.items[2].asBool());
    // 4. Ray hits length
    try testing.expect(arr_obj.items.items[3].asNumber() > 0.0);
    // 5. Metric distance from [0, 0, 10] to top face [0, 0, 5] = 5.0 units!
    try testing.expectApproxEqAbs(@as(f64, 5.0), arr_obj.items.items[4].asNumber(), 0.1);
    // 6. Hit position Z = 5.0
    try testing.expectApproxEqAbs(@as(f64, 5.0), arr_obj.items.items[5].asNumber(), 0.1);
}

test "VM: Custom Polygons and Fixed Matrix Transforms evaluate seamlessly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    // Test Script:
    // 1. Create a custom 2D Triangle using `polygon`
    // 2. Skew the 2D polygon using a 3x2 Transformation Matrix
    // 3. Extrude to 3D and skew again using a 4x3 Transformation Matrix
    const source =
        \\pts = [ [0, 0], [10, 0], [0, 10] ]
        \\poly = polygon(pts)
        \\
        \\# 2D Transform (Scale X by 2, Translate Y by 5)
        \\poly_trans = poly.transform([2, 0,  0, 1,  0, 5])
        \\
        \\# 3D Transform (Extrude, then translate Z by 15)
        \\poly_3d = poly_trans.extrude(10).transform([1, 0, 0,  0, 1, 0,  0, 0, 1,  0, 0, 15])
        \\
        \\[poly_3d.volume()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Area of Triangle was (10 * 10) / 2 = 50
    // Scale X by 2 -> Area = 100
    // Extrude by 10 -> Volume = 1000
    const vol = result.asArray().items.items[0].asNumber();
    try testing.expect(vol > 999.0 and vol < 1001.0);
}

test "VM Edge Case: Safe casting prevents panics on invalid CAD arguments" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Attempt to translate a geometry using a String instead of a Number
    const source =
        \\c = cube(10)
        \\c.translate("hello", 0, 0)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);

    // It should cleanly catch the invalid type and safely abort the execution
    try testing.expectEqual(.runtime_error, result);
}

test "VM: Consolidated numeric operations (*, /, %, **) evaluate correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const source =
        \\[ 10 * 5, 10 / 2, 11 % 3, 2 ** 4 ]
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", result.asObj()));
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    try testing.expectEqual(@as(f64, 50.0), arr_obj.items.items[0].asNumber()); // 10 * 5
    try testing.expectEqual(@as(f64, 5.0), arr_obj.items.items[1].asNumber()); // 10 / 2
    try testing.expectEqual(@as(f64, 2.0), arr_obj.items.items[2].asNumber()); // 11 % 3
    try testing.expectEqual(@as(f64, 16.0), arr_obj.items.items[3].asNumber()); // 2 ^ 4
}

// At the bottom of src/vm/vm_test.zig
test "VM Edge Case: Robot Mount Bracket execution safely resolves Spatial Queries without Segfaulting" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null; // Mute prints during CI testing

    // Use core snippets from the reported segfault
    const source =
        \\raw_pts = [ [0.0, 0.0], [40.0, 0.0], [30.0, 25.0], [10.0, 25.0] ]
        \\base_poly = polygon(raw_pts)
        \\outer_profile = base_poly.offset(4.0)
        \\center_hole = circle(d: 12.0).translate(22.0, 17.5)
        \\bracket_profile = outer_profile - center_hole
        \\bracket_3d = bracket_profile.extrude(12.0)
        \\trimmed_bracket = bracket_3d.trim_by_plane(0.0, 0.0, 1.0, 18.0)
        \\
        \\# Spatial query which triggered GC sweep bug
        \\ray_hits = trimmed_bracket.ray_cast([22.0, 17.5, 40.0], [22.0, 17.5, -10.0])
        \\
        \\inspect("Ray hit:", ray_hits.length)
        \\trimmed_bracket
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Test that the return is the valid constructed Geometry
    try testing.expect(result.isGeometry());
}

test "VM: FFI getReceiver safely extracts receiver and enforces pointer bounds" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // 1. Simulate the stack state right before a native call
    vm.push(value.Value.initNumber(10.0)); // Receiver (base slot)
    vm.push(value.Value.initNumber(20.0)); // Arg 1
    vm.push(value.Value.initNumber(30.0)); // Arg 2

    // 2. The native FFI boundary is handed a pointer starting at Arg 1
    const args_ptr = vm.stack.ptr + 1;

    // 3. Extract the receiver safely
    const receiver = vm.getReceiver(args_ptr);

    // 4. Verify it correctly stepped back 1 slot to grab the receiver
    try testing.expectEqual(@as(f64, 10.0), receiver.asNumber());
}

test "VM: Geometries and CrossSections are First-Class Objects (is_a? and respond_to?)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Prove that primitives are true classes and methods resolve instantly
    const source =
        \\[
        \\  cube(10).is_a?(Geometry),
        \\  square(10).is_a?(CrossSection),
        \\  cube(10).respond_to?(:translate),
        \\  square(10).respond_to?(:extrude),
        \\  cube(10).is_a?(Object)
        \\]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    // All 5 checks should definitively return true!
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());
    try testing.expectEqual(true, arr_obj.items.items[1].asBool());
    try testing.expectEqual(true, arr_obj.items.items[2].asBool());
    try testing.expectEqual(true, arr_obj.items.items[3].asBool());
    try testing.expectEqual(true, arr_obj.items.items[4].asBool());
}

test "VM CAD: Geometry processing inside functional array iterators (.map)" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    vm.host.print_handler = null;

    const source =
        \\sizes = [10, 20, 30]
        \\boxes = sizes.map do |s|
        \\  cube(s)
        \\end
        \\vols = boxes.map do |b|
        \\  b.volume
        \\end
        \\[vols[0], vols[1], vols[2]]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    try testing.expectEqual(@as(f64, 1000.0), arr_obj.items.items[0].asNumber()); // 10^3
    try testing.expectEqual(@as(f64, 8000.0), arr_obj.items.items[1].asNumber()); // 20^3
    try testing.expectEqual(@as(f64, 27000.0), arr_obj.items.items[2].asNumber()); // 30^3
}

test "VM: Fluent CSG method chaining on 3D geometry" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // script: cube(10).union(sphere(5)).difference(cylinder(r: 2, h: 20))
    const source =
        \\c = cube(10)
        \\s = sphere(5)
        \\cyl = cylinder(r: 2, h: 20)
        \\c.union(s).difference(cyl)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);
    try testing.expect(vm.stack[0].isGeometry());
}

test "VM: Fluent CSG method chaining on 2D cross sections" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // script: square(10).intersection(circle(6))
    const source =
        \\sq = square(10)
        \\circ = circle(6)
        \\sq.intersection(circ)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);
    try testing.expect(vm.stack[0].isCrossSection());
}

test "VM: polyhedron generates custom 3D mesh from multidimensional arrays" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // A script defining a simple tetrahedron (pyramid)
    const source =
        \\pts = [[0,0,0], [10,0,0], [0,10,0], [0,0,10]]
        \\faces = [[0,1,2], [0,2,3], [0,3,1], [1,3,2]]
        \\polyhedron(pts, faces)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Verify it yielded a valid Geometry object
    try testing.expect(result.isGeometry());

    // Verify the data was stored securely in the DAG Builder arrays
    try testing.expectEqual(@as(usize, 4), vm.dag_builder.poly_points.items.len);
    try testing.expectEqual(@as(usize, 4), vm.dag_builder.poly_faces.items.len);
}

test "VM: text() primitive generates a valid 2D CrossSection" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Script to generate a stencil text object, then extrude it to 3D
    const source =
        \\t = text("KupCAD", size: 15, font: :stencil)
        \\t.extrude(5)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // 1. Evaluate the script
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // 2. Ensure it yielded geometry
    try testing.expect(result.isGeometry());

    // 3. Ensure we can physically materialize it (DAG Evaluates successfully)
    const handle = try vm.ensureConcrete(result);

    // 4. Assert it is a valid, solid volume
    const vol = kernel.volume(handle);
    try testing.expect(vol > 0.0);
}

test "VM: Extruded text has mathematically correct bounding box and mass properties" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create a 10mm high "CAD" text and extrude it by exactly 7.5mm
    const source =
        \\txt = text("CAD", size: 10.0, font: :sans)
        \\txt.extrude(7.5)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const handle = try vm.ensureConcrete(result);

    // 1. Check Volume (Must be solid, > 0)
    const vol = kernel.volume(handle);
    try testing.expect(vol > 50.0);

    // 2. Check Bounding Box (Unwrap the optional and use struct fields)
    const bbox = kernel.boundingBox(handle) orelse return error.MissingBBox;

    // Assuming BoundingBox has `min` and `max` arrays of [3]f64
    const dx = bbox.max[0] - bbox.min[0]; // max_x - min_x
    const dy = bbox.max[1] - bbox.min[1]; // max_y - min_y
    const dz = bbox.max[2] - bbox.min[2]; // max_z - min_z

    // The text "CAD" should be wider than it is tall
    try testing.expect(dx > dy);

    // The height of the text (Y-axis) should be roughly 10mm (the size parameter)
    try testing.expect(dy > 5.0 and dy < 15.0);

    // The extrusion depth (Z-axis) MUST be exactly 7.5mm
    try testing.expectApproxEqAbs(7.5, dz, 0.0001);
}

test "VM: Primitive shape options generate valid 3D solids" {
    const sources = [_][]const u8{
        "cylinder(r1: 5.0, r2: 2.0, h: 10.0)", // tapered
        "cube(size: 10.0, chamfer: 1.0)", // chamfered profile, extruded
        "cylinder(r: 5.0, h: 10.0, round_r: 1.0)", // rounded profile, revolved
    };
    for (sources) |source| {
        errdefer std.debug.print("failing source: {s}\n", .{source});
        var vm = try VM.init(testing.allocator, testing.io);
        defer vm.deinit();
        try registry.registerStandardLibrary(&vm);

        var doc = try Document.parse(testing.allocator, source);
        defer doc.deinit();

        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(testing.allocator);

        var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
        defer comp.deinit();
        try comp.compile(doc.tree.root);

        const result = try executeAndAssertStack(&vm, &out_chunk, 1);
        try testing.expect(result.isGeometry());
        const handle = try vm.ensureConcrete(result);
        try testing.expect(kernel.volume(handle) > 0.0);
    }
}

test "VM: Extrude with center: true positions geometry symmetrically along Z" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source = "square(10.0).extrude(10.0, center: true)";
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const handle = try vm.ensureConcrete(result);

    const bbox = kernel.boundingBox(handle) orelse return error.MissingBBox;
    // With height = 10 and center: true, min_z must be -5.0 and max_z must be 5.0
    try testing.expectApproxEqAbs(-5.0, bbox.min[2], 0.001);
    try testing.expectApproxEqAbs(5.0, bbox.max[2], 0.001);
}

test "VM: Text alignment with halign and valign centers bounding box" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\t = text("ABC", size: 10.0, halign: :center, valign: :center)
        \\t.extrude(2.0)
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const handle = try vm.ensureConcrete(result);

    const bbox = kernel.boundingBox(handle) orelse return error.MissingBBox;
    const center_x = (bbox.min[0] + bbox.max[0]) / 2.0;
    const center_y = (bbox.min[1] + bbox.max[1]) / 2.0;

    // Centered text alignment should place its X and Y midpoint near 0.0
    try testing.expectApproxEqAbs(0.0, center_x, 0.1);
    try testing.expectApproxEqAbs(0.0, center_y, 0.1);
}

test "VM: Square with round_r generates valid 2D cross-section" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 10x10 square with 2mm rounded corners
    const source = "square(10.0, round_r: 2.0)";
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isCrossSection());
}

test "VM: Resize calculates bbox and scales geometry automatically" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Initial 10x10x10 cube resized to 50x20x(auto scaled to 50 based on X)
    const source = "cube(10).resize([50, 20, 0], auto: true)";
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isGeometry());

    const handle = try vm.ensureConcrete(result);
    const bbox = kernel.boundingBox(handle) orelse return error.MissingBBox;

    // Check if the scale properly hit the targets!
    try testing.expectApproxEqAbs(50.0, bbox.max[0] - bbox.min[0], 0.001); // X = 50
    try testing.expectApproxEqAbs(20.0, bbox.max[1] - bbox.min[1], 0.001); // Y = 20
    try testing.expectApproxEqAbs(50.0, bbox.max[2] - bbox.min[2], 0.001); // Z = auto scaled based on X
}

test "VM: Polygon with multiple paths uses Even-Odd cutout routing" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // A large square with a smaller square hole cut out of the middle
    const source =
        \\points = [[0,0], [10,0], [10,10], [0,10], [2,2], [8,2], [8,8], [2,8]]
        \\paths = [[0,1,2,3], [4,5,6,7]]
        \\polygon(points, paths: paths)
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isCrossSection());
}

test "VM: Project handles cut kwargs and slice extracts 2D cross sections" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Test standard project (shadow)
    const src1 = "cube(10).project()";
    var doc1 = try Document.parse(testing.allocator, src1);
    defer doc1.deinit();
    var chunk1 = chunk.Chunk.init();
    defer chunk1.free(testing.allocator);
    var comp1 = Compiler.forDocument(testing.allocator, &doc1, &chunk1, &vm);
    defer comp1.deinit();
    try comp1.compile(doc1.tree.root);
    const res1 = try executeAndAssertStack(&vm, &chunk1, 1);
    try testing.expect(res1.isCrossSection());

    vm.stack_top = 0; // Reset stack

    // Test project(cut: true)
    const src2 = "cube(10).project(cut: true)";
    var doc2 = try Document.parse(testing.allocator, src2);
    defer doc2.deinit();
    var chunk2 = chunk.Chunk.init();
    defer chunk2.free(testing.allocator);
    var comp2 = Compiler.forDocument(testing.allocator, &doc2, &chunk2, &vm);
    defer comp2.deinit();
    try comp2.compile(doc2.tree.root);
    const res2 = try executeAndAssertStack(&vm, &chunk2, 1);
    try testing.expect(res2.isCrossSection());
}

test "VM: Material DSL registers properties and injects ID into mesh property channel" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source = "cube(10).material(color: \"#FF0000\", roughness: 0.2, metallic: 0.8, transmission: 0.5)";
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isGeometry());

    // 1. Verify material definition was saved in VM registry
    try testing.expectEqual(@as(usize, 1), vm.materials.items.len);
    const mat = vm.materials.items[0];
    try testing.expectEqual([3]u8{ 0xFF, 0x00, 0x00 }, mat.rgb);
    try testing.expectApproxEqAbs(0.2, mat.roughness, 0.001);
    try testing.expectApproxEqAbs(0.8, mat.metallic, 0.001);
    try testing.expectApproxEqAbs(0.5, mat.transmission, 0.001);

    // 2. Evaluate mesh and check vertex property channel 4
    const handle = try vm.ensureConcrete(result);
    const mesh = kernel.getMesh(testing.allocator, handle) orelse return error.MissingMesh;
    defer testing.allocator.free(mesh.vert_props);
    defer testing.allocator.free(mesh.tri_verts);

    try testing.expect(mesh.num_prop >= 4);

    // Check first vertex: channel 4 must equal Material ID 0
    const slot: u32 = @intFromFloat(mesh.vert_props[3]);
    try testing.expectEqual(kernel.materialSlot(0), slot);
}

test "VM: CSG Booleans preserve face material IDs across cuts" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\red_box = cube(10).material(color: "#FF0000")
        \\green_box = cube(10).translate(5, 0, 0).material(color: "#00FF00")
        \\red_box - green_box
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const handle = try vm.ensureConcrete(result);

    const mesh = kernel.getMesh(testing.allocator, handle) orelse return error.MissingMesh;
    defer testing.allocator.free(mesh.vert_props);
    defer testing.allocator.free(mesh.tri_verts);

    try testing.expectEqual(@as(usize, 2), vm.materials.items.len);

    var found_mat0 = false;
    var found_mat1 = false;

    var v: usize = 0;
    while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
        const slot: u32 = @intFromFloat(mesh.vert_props[v + 3]);
        if (slot == kernel.materialSlot(0)) found_mat0 = true;
        if (slot == kernel.materialSlot(1)) found_mat1 = true;
    }

    try testing.expect(found_mat0);
    try testing.expect(found_mat1);
}

test "VM: Export GLTF generates valid .glb file with extensions" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    vm.vfs = mem_vfs.vfs();
    const test_path = "test_output.glb";

    const source = "sphere(5).material(color: \"#0000FF\", transmission: 0.9).export_gltf(\"test_output.glb\")";
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    _ = try executeAndAssertStack(&vm, &out_chunk, 1);

    const written = try mem_vfs.vfs().readFile(testing.allocator, test_path);
    defer testing.allocator.free(written);
    try testing.expect(written.len >= 12);

    const magic = std.mem.readInt(u32, written[0..4], .little);
    try testing.expectEqual(@as(u32, 0x46546C67), magic); // "glTF"
}

test "STL Importer: imports exported binary STL and evaluates valid volume" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    vm.vfs = mem_vfs.vfs();

    // Export a 10x10x10 cube (Volume = 1000)
    const export_source = "cube(10).export_stl(\"import_test.stl\")";
    var doc_export = try Document.parse(testing.allocator, export_source);
    defer doc_export.deinit();

    var chunk_export = chunk.Chunk.init();
    defer chunk_export.free(testing.allocator);

    var comp_export = Compiler.forDocument(testing.allocator, &doc_export, &chunk_export, &vm);
    defer comp_export.deinit();
    try comp_export.compile(doc_export.tree.root);

    _ = try executeAndAssertStack(&vm, &chunk_export, 1);

    // Now import the STL and check its volume
    const import_source =
        \\imported = import_stl("import_test.stl")
        \\imported.volume()
    ;
    var doc_import = try Document.parse(testing.allocator, import_source);
    defer doc_import.deinit();

    var chunk_import = chunk.Chunk.init();
    defer chunk_import.free(testing.allocator);

    var comp_import = Compiler.forDocument(testing.allocator, &doc_import, &chunk_import, &vm);
    defer comp_import.deinit();
    try comp_import.compile(doc_import.tree.root);

    const vol_val = try executeAndAssertStack(&vm, &chunk_import, 1);
    try testing.expect(vol_val.isNumber());
    try testing.expectApproxEqAbs(1000.0, vol_val.asNumber(), 0.01);
}

test "VM: CAD.with_config safely applies and pops engine settings block-scoped" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\CAD.config(resolution: { segments: 16 })
        \\conf1 = CAD.current_config
        \\
        \\conf2 = nil
        \\CAD.with_config(resolution: { segments: 64 }, engine: :brep) do
        \\  conf2 = CAD.current_config
        \\end
        \\
        \\conf3 = CAD.current_config
        \\[conf1[:resolution][:segments], conf2[:resolution][:segments], conf3[:resolution][:segments], conf2[:engine]]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr = result.asArray().items.items;

    try testing.expectEqual(@as(f64, 16.0), arr[0].asNumber()); // Original
    try testing.expectEqual(@as(f64, 64.0), arr[1].asNumber()); // Block Scoped
    try testing.expectEqual(@as(f64, 16.0), arr[2].asNumber()); // Restored
    try testing.expectEqualStrings("brep", arr[3].asSymbol().chars); // Engine Swapped!
}

test "VM: ghost and highlight modifiers tag materials and route geometry correctly" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\# Highlight stays on the stack for math
        \\h = cube(10).highlight
        \\
        \\# Ghost shows a copy and gives the shape back, untouched
        \\g = cylinder(r: 5, h: 10).ghost
        \\
        \\[h, g]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr = result.asArray().items.items;

    // highlight returns geometry
    try testing.expect(arr[0].isGeometry());
    // ghost returns the shape itself, not the ghosted copy
    try testing.expect(arr[1].isGeometry());
    try testing.expect(vm.dag_builder.nodes.items[arr[1].asGeometry().dag_idx].tag == .cylinder);

    // Check the VM materials registry
    try testing.expectEqual(@as(usize, 2), vm.materials.items.len);
    try testing.expectEqual(.highlight, vm.materials.items[0].role);
    try testing.expectEqual(.ghost, vm.materials.items[1].role);

    // Check the display list (should contain exactly 1 item: the ghost)
    try testing.expectEqual(@as(usize, 1), vm.display_list.items.len);
}

test "VM: Block modifiers ghost do and highlight do apply to inner CSG" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\ghost do
        \\  cube(10) - cylinder(r: 2, h: 10)
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // ghost block returns nil
    try testing.expect(result.isNil());

    // VM caught the ghost
    try testing.expectEqual(@as(usize, 1), vm.display_list.items.len);
    try testing.expectEqual(.ghost, vm.materials.items[0].role);
}

test "VM: manifold.simplify_coplanar merges coplanar triangles on boolean operations" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Evaluate with simplify_coplanar: false
    // Slices creates 10 rows of coplanar triangles along each side face
    const source_unsimplified =
        \\CAD.config(manifold: { simplify_coplanar: false })
        \\a = square(size: 10).extrude(10, slices: 10)
        \\b = cube(size: 2).translate(4, 4, 10)
        \\a + b
    ;

    var doc1 = try Document.parse(testing.allocator, source_unsimplified);
    defer doc1.deinit();
    var chunk1 = chunk.Chunk.init();
    defer chunk1.free(testing.allocator);
    var comp1 = Compiler.forDocument(testing.allocator, &doc1, &chunk1, &vm);
    defer comp1.deinit();
    try comp1.compile(doc1.tree.root);

    const res1 = try executeAndAssertStack(&vm, &chunk1, 1);
    const h1 = try vm.ensureConcrete(res1);
    const mesh_unsimplified = (kernel.getMesh(testing.allocator, h1)).?;
    defer {
        testing.allocator.free(mesh_unsimplified.vert_props);
        testing.allocator.free(mesh_unsimplified.tri_verts);
    }

    // clear cache
    vm.clearDagCache();

    // 2. Evaluate with simplify_coplanar: true
    const source_simplified =
        \\CAD.config(manifold: { simplify_coplanar: true })
        \\a = square(size: 10).extrude(10, slices: 10)
        \\b = cube(size: 2).translate(4, 4, 10)
        \\a + b
    ;

    var doc2 = try Document.parse(testing.allocator, source_simplified);
    defer doc2.deinit();
    var chunk2 = chunk.Chunk.init();
    defer chunk2.free(testing.allocator);
    var comp2 = Compiler.forDocument(testing.allocator, &doc2, &chunk2, &vm);
    defer comp2.deinit();
    try comp2.compile(doc2.tree.root);

    const res2 = try executeAndAssertStack(&vm, &chunk2, 1);
    const h2 = try vm.ensureConcrete(res2);
    const mesh_simplified = (kernel.getMesh(testing.allocator, h2)).?;
    defer {
        testing.allocator.free(mesh_simplified.vert_props);
        testing.allocator.free(mesh_simplified.tri_verts);
    }

    // Unsimplified mesh retains the 10 height-slice subdivisions (~260+ indices)
    // Simplified mesh dissolves the coplanar slice edges (~60-80 indices)
    try testing.expect(mesh_unsimplified.tri_verts.len > mesh_simplified.tri_verts.len);
}

test "VM: .simplify() script method decimates mesh on demand" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\shape = square(size: 10).extrude(10, slices: 10)
        \\simplified = shape.simplify(0.001)
        \\simplified
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expect(result.isGeometry());

    const handle = try vm.ensureConcrete(result);
    const mesh = (kernel.getMesh(testing.allocator, handle)).?;
    defer {
        testing.allocator.free(mesh.vert_props);
        testing.allocator.free(mesh.tri_verts);
    }

    // Verified: simplified multi-slice extrusion should reduce down to 12 triangles (36 index entries)
    try testing.expectEqual(@as(usize, 36), mesh.tri_verts.len);
}

test "VM: assemble() creates a valid ObjAssembly with name and parts" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Creates an assembly and returns it
    const source =
        \\c1 = cube(10)
        \\c2 = cube(20)
        \\asm = assemble(name: "MyAssembly", parts: [c1, c2])
        \\asm
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    // Verify it yielded an Assembly object natively
    try testing.expect(result.isAssembly());

    const assembly_obj = result.asAssembly();
    try testing.expectEqualStrings("MyAssembly", assembly_obj.name.chars);
    try testing.expectEqual(@as(usize, 2), assembly_obj.parts.items.items.len);
    try testing.expect(assembly_obj.parts.items.items[0].isGeometry());
    try testing.expect(assembly_obj.parts.items.items[1].isGeometry());
}

test "VM: union() performs a batch CSG union on an array of geometries" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // We create two 10x10x10 cubes.
    // We shift the second one by exactly 10 units on the X-axis so they touch end-to-end.
    // The fused batch volume should be exactly 2000.
    const source =
        \\c1 = cube(10, 10, 10, false)
        \\c2 = cube(10, 10, 10, false).translate(10, 0, 0)
        \\fused = union([c1, c2])
        \\fused.volume
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Execute the compiled bytecode
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expect(result.isNumber());
    try testing.expectApproxEqAbs(@as(f64, 2000.0), result.asNumber(), 0.1);
}

test "VM: batch_hull() wraps multiple shapes in a convex hull" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Two 10x10 cubes separated by 100 units. The hull should stretch across them.
    const source =
        \\c1 = cube(10).translate(-50, 0, 0)
        \\c2 = cube(10).translate(50, 0, 0)
        \\h = batch_hull([c1, c2])
        \\h.volume()
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expect(result.isNumber());
    // Hull of two 10x10 cubes 100 units apart (center to center) forms a 110x10x10 box
    try testing.expectApproxEqAbs(@as(f64, 11000.0), result.asNumber(), 1.0);
}

test "VM: split_by_plane() returns an array of two geometries" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Split a 10x10x10 centered cube straight down the middle (Z=0 plane)
    const source =
        \\c = cube(10, center: true)
        \\halves = c.split_by_plane(0, 0, 1, 0)
        \\halves
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expect(result.isArray());
    const arr = result.asArray().items.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expect(arr[0].isGeometry()); // Top half
    try testing.expect(arr[1].isGeometry()); // Bottom half
}

test "VM: genus() calculates topological holes" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // A cube with a cylinder subtracted through the middle creates a "donut" (genus 1)
    const source =
        \\box = cube(20, 20, 20, true)
        \\hole = cylinder(d: 10, h: 30, center: true)
        \\donut = box - hole
        \\donut.genus
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);

    try testing.expect(result.isNumber());
    try testing.expectEqual(@as(f64, 1.0), result.asNumber()); // Genus 1 = 1 hole
}

test "VM CAD: BoundingBox explicit axis getters return precise dimensions" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create a 10x20x30 cube at the origin (0,0,0)
    const source =
        \\c = cube(x: 10, y: 20, z: 30, center: false)
        \\box = c.bbox
        \\[
        \\  box.x_size, box.y_size, box.z_size,
        \\  box.x_min, box.y_min, box.z_min,
        \\  box.x_max, box.y_max, box.z_max
        \\]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 9), arr_obj.items.items.len);

    // Sizes
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[0].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[1].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[2].asNumber());

    // Mins (Since center: false, they start at 0)
    try testing.expectEqual(@as(f64, 0.0), arr_obj.items.items[3].asNumber());
    try testing.expectEqual(@as(f64, 0.0), arr_obj.items.items[4].asNumber());
    try testing.expectEqual(@as(f64, 0.0), arr_obj.items.items[5].asNumber());

    // Maxes
    try testing.expectEqual(@as(f64, 10.0), arr_obj.items.items[6].asNumber());
    try testing.expectEqual(@as(f64, 20.0), arr_obj.items.items[7].asNumber());
    try testing.expectEqual(@as(f64, 30.0), arr_obj.items.items[8].asNumber());
}

test "VM CAD: align and center mesh methods correctly translate geometry" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // 1. Create a shaft (height 50)
    // 2. Create a washer (height 2)
    // 3. Center the washer on X/Y, and snap its bottom to the shaft's top
    const source =
        \\shaft = cylinder(d: 10, h: 50, center: false)
        \\washer = cylinder(d: 20, h: 2, center: false)
        \\          .center("XY")
        \\          .align(shaft, "Z", "min", "max")
        \\
        \\box = washer.bbox
        \\[box.x_min, box.x_max, box.z_min, box.z_max]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    // Washer X bounds (Diameter 20, centered, so -10 to 10)
    try testing.expectApproxEqAbs(@as(f64, -10.0), arr_obj.items.items[0].asNumber(), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 10.0), arr_obj.items.items[1].asNumber(), 0.001);

    // Washer Z bounds (Snapped to top of 50mm shaft, height is 2, so 50 to 52)
    try testing.expectApproxEqAbs(@as(f64, 50.0), arr_obj.items.items[2].asNumber(), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 52.0), arr_obj.items.items[3].asNumber(), 0.001);
}

test "VM CAD: repeat_linear duplicates and translates geometry" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create a 10x10x10 cube, and repeat it 5 times along the X axis, spaced 10 units apart.
    const source =
        \\base = cube(10, center: false)
        \\pattern = base.repeat_linear(5, [10, 0, 0])
        \\box = pattern.bbox()
        \\[box.x_size(), pattern.volume()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    // 1. Check X Size: 5 cubes of size 10, offset by 10 each -> total span is exactly 50.
    try testing.expectApproxEqAbs(@as(f64, 50.0), arr_obj.items.items[0].asNumber(), 0.001);

    // 2. Check Volume: 5 cubes * 1000 volume each = 5000.
    try testing.expectApproxEqAbs(@as(f64, 5000.0), arr_obj.items.items[1].asNumber(), 0.1);
}

test "VM CAD: repeat_polar duplicates and rotates geometry radially" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create a centered 10x10x10 cube, shift it 20 units out on X, and copy it 4 times radially.
    const source =
        \\base = cube(10, center: true).translate(20, 0, 0)
        \\pattern = base.repeat_polar(4, angle: 360)
        \\box = pattern.bbox()
        \\[box.x_size(), box.y_size(), pattern.volume()]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();

    // 1. Check Sizes: 4 cubes placed at radius 20. Bounding box max should be 25, min -25. Size = 50 on X and Y.
    try testing.expectApproxEqAbs(@as(f64, 50.0), arr_obj.items.items[0].asNumber(), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 50.0), arr_obj.items.items[1].asNumber(), 0.001);

    // 2. Check Volume: 4 cubes * 1000 volume each = 4000.
    try testing.expectApproxEqAbs(@as(f64, 4000.0), arr_obj.items.items[2].asNumber(), 0.1);
}

test "VM CAD: regular_polygon creates 2D cross sections" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create an 8-sided octagon with r=10, then extrude it by 5.
    const source =
        \\poly = regular_polygon(8, r: 10)
        \\solid = poly.extrude(5)
        \\[poly.is_a?(CrossSection), solid.bbox.x_size]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 2), arr_obj.items.items.len);

    // It successfully registered as a 2D profile
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());

    // X dimension for r=10 octagon should be exactly 20
    try testing.expectApproxEqAbs(@as(f64, 20.0), arr_obj.items.items[1].asNumber(), 0.001);
}

test "VM CAD: torus synthesizes properly via revolve" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Create a Torus (major_r: 10, minor_r: 2)
    const source =
        \\ring = torus(major_r: 10, minor_r: 2)
        \\box = ring.bbox
        \\[ring.is_a?(Geometry), box.x_size, box.z_size]
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const arr_val = try executeAndAssertStack(&vm, &out_chunk, 1);
    const arr_obj = arr_val.asArray();
    try testing.expectEqual(@as(usize, 3), arr_obj.items.items.len);

    // Returns a 3D volume
    try testing.expectEqual(true, arr_obj.items.items[0].asBool());

    // Total width = (major_r + minor_r) * 2 = (10 + 2) * 2 = 24
    try testing.expectApproxEqAbs(@as(f64, 24.0), arr_obj.items.items[1].asNumber(), 0.5);

    // Total height = minor_r * 2 = 4 (Polygonal approximation shrinks this slightly to ~3.9)
    try testing.expectApproxEqAbs(@as(f64, 4.0), arr_obj.items.items[2].asNumber(), 0.2); // Increased tolerance
}

test "VM: Evaluates nested spatial tuple destructuring inside blocks" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Sends an array containing `[[10, 20], 30]` into the block
    const source =
        \\def call_it(&b)
        \\  b.call([[10, 20], 30])
        \\end
        \\call_it do |((x, y), z)|
        \\  x + y + z
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Result should be 10 + 20 + 30 = 60
    const res = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expectEqual(@as(f64, 60.0), res.asNumber());
}

test "VM CAD: 2D CrossSection bounding boxes map correctly to Z=0 dimensions" {
    const source =
        \\ s = square(x: 10, y: 20, center: true)
        \\ b = s.bbox
        \\
        \\ assert(b.x_size == 10)
        \\ assert(b.y_size == 20)
        \\ assert(b.z_size == 0)
        \\ assert(b.x_min == -5)
        \\ assert(b.y_max == 10)
        \\ assert(b.z_min == 0)
        \\ assert(b.z_max == 0)
        \\
        \\ c = circle(r: 5, segments: 16)
        \\ cb = c.bbox
        \\
        \\ assert(cb.x_size == 10)
        \\ assert(cb.y_size == 10)
        \\ assert(cb.z_size == 0)
        \\ assert(cb.x_max == 5)
        \\ assert(cb.y_min == -5)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    _ = try executeAndAssertStack(&vm, &out_chunk, 1);
}

test "VM: Solid and Sketch2D static class method execution" {
    const alloc = testing.allocator;

    const source =
        \\s = Solid.cube(10.0)
        \\c = Solid.cylinder(5.0, 20.0)
        \\p = Solid.sphere(8.0)
        \\sq = Sketch2D.square(15.0)
        \\circ = Sketch2D.circle(6.0)
        \\[s, c, p, sq, circ]
    ;

    var doc = try Document.parse(alloc, source);
    defer doc.deinit();

    var vm = try VM.init(alloc, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var exec_chunk = chunk.Chunk.init();
    defer exec_chunk.free(alloc);

    var comp = Compiler.forDocument(alloc, &doc, &exec_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    // Execute with stack equilibrium validation
    const result_val = try executeAndAssertStack(&vm, &exec_chunk, 1);

    const result_arr = result_val.asArray();
    try testing.expectEqual(@as(usize, 5), result_arr.items.items.len);

    // 3D Solids
    try testing.expect(result_arr.items.items[0].isGeometry());
    try testing.expect(result_arr.items.items[1].isGeometry());
    try testing.expect(result_arr.items.items[2].isGeometry());

    // 2D Profiles
    try testing.expect(result_arr.items.items[3].isCrossSection());
    try testing.expect(result_arr.items.items[4].isCrossSection());
}

test "VM: Instance export methods on Solid and Geometry objects" {
    const alloc = testing.allocator;
    const test_stl = "vm_test_out.stl";
    const test_glb = "vm_test_out.glb";

    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(testing.io, test_stl) catch {};
    defer cwd.deleteFile(testing.io, test_glb) catch {};

    const source =
        \\part = Solid.cube(12.0)
        \\part.export_stl("vm_test_out.stl")
        \\part.export_gltf("vm_test_out.glb")
        \\part
    ;

    var doc = try Document.parse(alloc, source);
    defer doc.deinit();

    var vm = try VM.init(alloc, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    var exec_chunk = chunk.Chunk.init();
    defer exec_chunk.free(alloc);

    var comp = Compiler.forDocument(alloc, &doc, &exec_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    // Execute with stack equilibrium validation
    const result_val = try executeAndAssertStack(&vm, &exec_chunk, 1);

    // Assert receiver remains intact on top of the stack
    try testing.expect(result_val.isGeometry());

    // --- Assert STL file was generated and has valid header ---
    const stl_file = try cwd.openFile(vm.io, test_stl, .{});
    defer stl_file.close(vm.io);

    var stl_header: [84]u8 = undefined;
    const stl_bytes_read = try stl_file.readStreaming(vm.io, &.{&stl_header});
    try testing.expect(stl_bytes_read >= 84);

    // --- Assert GLTF binary (.glb) file was generated with magic header ---
    const glb_file = try cwd.openFile(vm.io, test_glb, .{});
    defer glb_file.close(vm.io);

    var glb_header: [12]u8 = undefined;
    const glb_bytes_read = try glb_file.readStreaming(vm.io, &.{&glb_header});
    try testing.expect(glb_bytes_read >= 12);

    const magic = std.mem.readInt(u32, glb_header[0..4], .little);
    try testing.expectEqual(@as(u32, 0x46546C67), magic); // "glTF"
}

test "VM CAD: loft skins two 2D profiles into a 3D solid" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null;

    // Loft a 10x10 square up to a 5x5 square across 10mm of height
    const source =
        \\base = square(10, center: true)
        \\top = square(5, center: true)
        \\part = base.loft(top, 10)
        \\part.volume
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isNumber());

    // Exact volume of a square frustum: V = (h/3) * (A1 + A2 + sqrt(A1*A2))
    // (10/3) * (100 + 25 + 50) = 583.33
    // Exact: it used to be the hull of two 1e-3 thick sheets, a little larger.
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0 * 175.0), result.asNumber(), 1e-9);
}

test "VM CAD: fillet_edges rounds 3D geometry via Minkowski sum" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null;

    // Apply a 2mm fillet to a 10x10x10 cube
    const source =
        \\c = cube(10, center: true)
        \\part = c.fillet_edges(2)
        \\part.volume
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isNumber());

    // Minkowski sum of 10x10x10 cube and r=2 sphere expands the base volume.
    // Mathematical volume is ~2610.5.
    const vol = result.asNumber();
    try testing.expect(vol > 2400.0 and vol < 2800.0);
}

test "VM: Value.stringify recursively handles nested arrays and primitives" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const arr = try vm.gc.allocateArray(&vm);
    vm.push(value.Value.initObj(&arr.obj)); // Root it

    try arr.items.append(vm.gc.trackingAllocator(), value.Value.initNumber(42));
    try arr.items.append(vm.gc.trackingAllocator(), value.Value.initBool(false));
    try arr.items.append(vm.gc.trackingAllocator(), value.Value.initNil());

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try value.Value.initObj(&arr.obj).stringify(false, &out.writer);

    // Proves stringify successfully jumps through the union payload into the Array items
    try testing.expectEqualStrings("[42, false, nil]", out.written());
    _ = vm.pop();
}

test "VM: Case statement executes fast-path jump table for primitives" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const source =
        \\val = 2
        \\case val
        \\when 1
        \\  "one"
        \\when 2
        \\  "two"
        \\else
        \\  "other"
        \\end
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Verify the chunk actually generated the op_switch opcode
    var found_switch = false;
    for (out_chunk.code.items) |byte| {
        if (byte == @backingInt(chunk.OpCode.op_switch)) {
            found_switch = true;
            break;
        }
    }
    try testing.expect(found_switch);

    // Verify the VM can successfully interpret the generated jump offsets
    const result = try executeAndAssertStack(&vm, &out_chunk, 1);
    try testing.expect(result.isObject() and result.asObj().obj_type == .string);

    const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", result.asObj()));
    try testing.expectEqualStrings("two", str_obj.chars);
}

test "VM: FFI Boundary - Exhaustive type checking prevents kernel segfaults" {
    const source =
        \\ # Attempting to pass a malicious string to a kernel math/vector function
        \\ kernel_translate("crash_the_c_kernel_please")
    ;

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Mock C++ boundary function matching the exact NativeFn prototype
    const MockKernel = struct {
        fn translate(ctx_opaque: *anyopaque, call: value.NativeArgs) !value.Value {
            const arg_count = call.count;
            const args = call.ptr;
            const ctx: *VM = @ptrCast(@alignCast(ctx_opaque));

            if (arg_count != 1) {
                _ = ctx.raiseError(.ArgumentError, "expected 1 arg", .{});
                return error.RuntimeError;
            }

            const vec_arg = args[0];

            // DOD FFI DEFENSE: Explicit type guard before operating on native memory
            if (!vec_arg.isNumber()) {
                _ = ctx.raiseError(.TypeError, "kernel_translate expects a Number, got invalid type", .{});
                return error.RuntimeError;
            }

            return value.Value.initNumber(vec_arg.asNumber() + 10.0);
        }
    };

    try vm.defineNative("kernel_translate", MockKernel.translate);

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Assert that the script fails safely with an intercepted .runtime_error, NOT a segfault
    const result = vm.interpret(&main_chunk);
    try std.testing.expectEqual(.runtime_error, result);
}

test "VM: DAG Benchmark - Safely orchestrates 10,000 deeply nested CSG booleans" {
    const source =
        \\ i = 0
        \\ tree = mock_box()
        \\ while i < 10000
        \\   # The '-' operator routes to host.binary_handler for non-primitives
        \\   tree = tree - mock_cylinder()
        \\   i = i + 1
        \\ end
        \\ tree
    ;

    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    // Explicitly expand the VM instruction limit to accommodate the massive tree generation loop
    vm.hooks.setLimit(1_000_000);

    const MockKernel = struct {
        fn shape(ctx_opaque: *anyopaque, _: value.NativeArgs) !value.Value {
            const ctx: *VM = @ptrCast(@alignCast(ctx_opaque));
            // Return a generic map so '-' bypasses standard math and triggers binary_handler
            const map_obj = try ctx.gc.allocateMap(ctx);
            return value.Value.initObj(&map_obj.obj);
        }

        fn mockCSG(ctx: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) !value.Value {
            _ = op;
            _ = a;
            _ = b;
            // Mimic C++ DAG node generation: allocate a new heap object to simulate memory pressure
            const node = try ctx.gc.allocateMap(ctx);
            return value.Value.initObj(&node.obj);
        }
    };

    try vm.defineNative("mock_box", MockKernel.shape);
    try vm.defineNative("mock_cylinder", MockKernel.shape);

    // Inject the mock C++ DAG builder (binary_handler natively expects *VM)
    vm.host.binary_handler = MockKernel.mockCSG;

    var doc = try Document.parse(std.testing.allocator, source);
    defer doc.deinit();

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(std.testing.allocator);

    var comp = Compiler.forDocument(std.testing.allocator, &doc, &main_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // Execute the massive CSG loop
    // (Note: Do not use executeAndAssertStack here, as 10,000 full GC mark-and-sweeps will take too long)
    const result = vm.interpret(&main_chunk);
    try std.testing.expectEqual(.ok, result);

    // The final result sitting on the top of the stack is our 10,000-node deep DAG map
    const final_val = vm.pop();
    try std.testing.expect(final_val.isMap());
}

test "VM Edge Case: Import depth limit prevents host stack overflow" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // 1. Create a secure, in-memory virtual file system[cite: 6, 7]
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // 2. Override the VM's file system to use the memory VFS[cite: 7]
    vm.vfs = mem_vfs.vfs();

    // 3. Generate an import chain that safely exceeds the constant limit
    // (e.g. if MAX_IMPORT_DEPTH is 64, we generate 66 virtual files)
    const max_chain = VM.MAX_IMPORT_DEPTH + 2;
    for (0..max_chain) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "mod_{d}.kcad", .{i});

        var content_buf: [64]u8 = undefined;
        const content = if (i == max_chain - 1)
            "exports = 42"
        else
            try std.fmt.bufPrint(&content_buf, "import \"mod_{d}.kcad\"", .{i + 1});

        // Write directly to the in-memory sandbox[cite: 6, 7]
        try vm.vfs.writeFile(name, content);
    }

    const source = "import \"mod_0.kcad\"";
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // This should hit the depth limit of MAX_IMPORT_DEPTH and gracefully throw an ImportError
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
}
