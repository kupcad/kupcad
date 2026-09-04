const std = @import("std");
const testing = std.testing;

// Access all submodules via the kupcad module
const kupcad = @import("kupcad");
const wasm = kupcad.wasm;
const VM = kupcad.vm.VM;
const chunk = kupcad.chunk;
const value = kupcad.value;

// Locus CAD Native Imports
const locus = kupcad.locus;
const math = locus.math;
const eigen = locus.eigen;
const geom = locus.geometry;
const nurbs_ssi = locus.nurbs_ssi;

// Pull all Locus internal unit tests into the WASM test runner
test {
    _ = locus;
}

test "WASM Interop: format_code_wasm handles invalid and empty inputs gracefully" {
    // Test Syntax Error Handling
    const bad_src = "class 123 { invalid }";
    const res_bad = wasm.format_code_wasm(bad_src.ptr, bad_src.len);

    // Formatter should fail and return null
    try testing.expect(res_bad == null);

    // Retrieve and verify the last error message
    const err_ptr = wasm.get_last_error();
    const err_slice = std.mem.sliceTo(err_ptr, 0);
    try testing.expectEqualStrings("Syntax Error", err_slice);

    // Test Zero-Length / Empty Input
    const empty_src = "";
    const res_empty = wasm.format_code_wasm(empty_src.ptr, empty_src.len);

    // Depending on the exact Formatter implementation, an empty file might
    // succeed with an empty string, or throw a Syntax Error. We handle both gracefully.
    if (res_empty) |ptr| {
        const empty_slice = std.mem.sliceTo(ptr, 0);
        try testing.expectEqualStrings("", empty_slice);
    } else {
        const err_ptr2 = wasm.get_last_error();
        const err_slice2 = std.mem.sliceTo(err_ptr2, 0);
        try testing.expectEqualStrings("Syntax Error", err_slice2);
    }
}

test "WASM Interop: check_code_wasm returns valid JSON on syntax errors" {
    // Test Syntax Error Handling
    const bad_src = "def !invalid";
    const res_bad = wasm.check_code_wasm(bad_src.ptr, bad_src.len);

    // The linter captures syntax errors natively and returns them as diagnostics!
    // Therefore, it should NOT return null, but a valid JSON array.
    try testing.expect(res_bad != null);

    const bad_slice = std.mem.sliceTo(res_bad.?, 0);

    // Verify it is a valid JSON array structure
    try testing.expect(bad_slice.len >= 2);
    try testing.expect(bad_slice[0] == '[');
    try testing.expect(bad_slice[bad_slice.len - 1] == ']');

    // Test Zero-Length / Empty Input
    const empty_src = "";
    const res_empty = wasm.check_code_wasm(empty_src.ptr, empty_src.len);

    try testing.expect(res_empty != null);
    const empty_slice = std.mem.sliceTo(res_empty.?, 0);

    // An empty file has no diagnostics, so it should return an empty JSON array
    try testing.expectEqualStrings("[]", empty_slice);
}

test "VM: Character ranges evaluate to an Array of Strings" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    const a_val = try vm.allocateString("a");
    const d_val = try vm.allocateString("d");
    vm.push(a_val); // Protect
    vm.push(d_val); // Protect

    const a_idx = try out_chunk.addConstant(testing.allocator, a_val);
    const d_idx = try out_chunk.addConstant(testing.allocator, d_val);
    const step_idx = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(1));

    _ = vm.pop();
    _ = vm.pop();

    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(a_idx), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(d_idx), 0);
    try out_chunk.writeOp(testing.allocator, .op_constant, 0);
    try out_chunk.write(testing.allocator, @intCast(step_idx), 0);

    // Inclusive range 'a'..'d'
    try out_chunk.writeOp(testing.allocator, .op_build_range, 0);
    try out_chunk.write(testing.allocator, 0, 0);
    try out_chunk.writeOp(testing.allocator, .op_return, 0);

    out_chunk.max_stack_slots = 5;

    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, result);

    // It should push an Array ["a", "b", "c", "d"]
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    const arr_val = vm.stack[0];
    try testing.expect(arr_val.isObject());

    const arr_obj = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", arr_val.asObj())));
    try testing.expectEqual(@as(usize, 4), arr_obj.items.items.len);

    const b_str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", arr_obj.items.items[1].asObj()))).chars;
    try testing.expectEqualStrings("b", b_str);
}

test "VM: Closure invocation pads missing arguments with nil natively" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // 1. Build a closure that expects TWO arguments (x, y) but does nothing.
    var closure_chunk = try testing.allocator.create(chunk.Chunk);
    closure_chunk.* = chunk.Chunk.init();
    defer {
        closure_chunk.free(testing.allocator);
        testing.allocator.destroy(closure_chunk);
    }

    // Pushes local slot 2 (which is the padded `y`), and returns it!
    try closure_chunk.writeOp(testing.allocator, .op_get_local, 0);
    try closure_chunk.write(testing.allocator, 2, 0);
    try closure_chunk.writeOp(testing.allocator, .op_return, 0);
    closure_chunk.max_stack_slots = 5;

    const func = try vm.gc.allocateFunction(&vm);
    func.chunk = closure_chunk;
    func.owns_chunk = false;
    func.arity = 2; // EXPECTS 2 ARGS!

    // 2. Call it with only ONE argument
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(testing.allocator);

    const const_func = try main_chunk.addConstant(testing.allocator, value.Value.initObj(&func.obj));
    try main_chunk.writeOp(testing.allocator, .op_closure, 0);
    try main_chunk.write(testing.allocator, @intCast(const_func), 0);

    // Push exactly 1 argument (the number 42)
    const const_42 = try main_chunk.addConstant(testing.allocator, value.Value.initNumber(42.0));
    try main_chunk.writeOp(testing.allocator, .op_constant, 0);
    try main_chunk.write(testing.allocator, @intCast(const_42), 0);

    // Execute with arg_count = 1
    try main_chunk.writeOp(testing.allocator, .op_call, 0);
    try main_chunk.write(testing.allocator, 1, 0);
    try main_chunk.writeOp(testing.allocator, .op_return, 0);
    main_chunk.max_stack_slots = 5;

    const result = vm.interpret(&main_chunk);
    try testing.expectEqual(.ok, result);

    // Because we only passed 1 argument to a closure expecting 2,
    // the VM should have padded `y` with `nil`, which is then returned!
    try testing.expectEqual(@as(usize, 1), vm.stack_top);
    try testing.expect(vm.stack[0].isNil());
}

test "WASM Interop: build_model_wasm evaluates geometry and exports requested formats" {
    // A simple script that generates a standard cube
    const src = "cube(10)";
    const stl_fmt = "stl";
    const glb_fmt = "glb";

    // Test STL export via WASM (use_draco: false)
    var stl_len: usize = 0;
    const stl_ptr = wasm.build_model_wasm(src.ptr, src.len, stl_fmt.ptr, stl_fmt.len, false, &stl_len);

    // The build should successfully yield a pointer to memory
    try testing.expect(stl_ptr != null);

    // An STL file must have an 80 byte header + 4 byte count + triangles.
    // A cube has exactly 12 triangles (50 bytes each), so size = 84 + (12 * 50) = 684 bytes
    try testing.expectEqual(@as(usize, 684), stl_len);

    const stl_bytes = stl_ptr.?[0..stl_len];
    const tri_count = std.mem.readInt(u32, stl_bytes[80..84], .little);
    try testing.expectEqual(@as(u32, 12), tri_count);

    // Ensure we don't leak memory in the test environment
    wasm.wasm_free(@constCast(stl_ptr.?), stl_len);

    // Test GLB export via WASM (use_draco: false)
    var glb_len: usize = 0;
    const glb_ptr = wasm.build_model_wasm(src.ptr, src.len, glb_fmt.ptr, glb_fmt.len, false, &glb_len);

    try testing.expect(glb_ptr != null);
    try testing.expect(glb_len > 20);

    const glb_bytes = glb_ptr.?[0..glb_len];
    const magic = std.mem.readInt(u32, glb_bytes[0..4], .little);
    try testing.expectEqual(@as(u32, 0x46546C67), magic); // "glTF"

    wasm.wasm_free(@constCast(glb_ptr.?), glb_len);
}

// ====================================================================
// WASM PURE-ZIG MATH & EIGEN FALLBACK TEST SUITE
// ====================================================================

test "WASM Math: 3x3 & 4x4 Determinant Precision" {
    // 3x3 Matrix Determinant
    const mat3 = [9]f64{
        1.0, 2.0, 3.0,
        0.0, 1.0, 4.0,
        5.0, 6.0, 0.0,
    };
    // Det = 1*(0-24) - 2*(0-20) + 3*(0-5) = -24 + 40 - 15 = 1.0
    const det3 = eigen.determinant3x3(&mat3);
    try testing.expectApproxEqAbs(1.0, det3, 1e-9);

    // 4x4 Identity Matrix
    const mat4_id = [16]f64{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    try testing.expectApproxEqAbs(1.0, eigen.determinant4x4(&mat4_id), 1e-9);
}

test "WASM Math: Pure-Zig Jacobi PCA Normal Estimation" {
    // Tilted plane: points lying on Z = X + Y (Plane eq: X + Y - Z = 0)
    const pts = [_]math.Vec3{
        .{ 0.0, 0.0, 0.0 },
        .{ 10.0, 0.0, 10.0 },
        .{ 0.0, 10.0, 10.0 },
        .{ 10.0, 10.0, 20.0 },
    };

    const norm = eigen.pcaNormal(&pts);

    // 1. Check orthogonality to in-plane vector (1, 0, 1): dot product must be 0
    try std.testing.expectApproxEqAbs(0.0, math.dot(norm, .{ 1.0, 0.0, 1.0 }), 1e-3);

    // 2. Check parallel alignment with unit normal (1/sqrt(3), 1/sqrt(3), -1/sqrt(3))
    const expected_norm = math.Vec3{ 1.0 / @sqrt(3.0), 1.0 / @sqrt(3.0), -1.0 / @sqrt(3.0) };
    try std.testing.expectApproxEqAbs(1.0, @abs(math.dot(norm, expected_norm)), 1e-3);

    // 3. Normal vector must be unit length
    try std.testing.expectApproxEqAbs(1.0, math.mag(norm), 1e-6);
}

test "WASM Math: Pure-Zig Non-Linear LM Solver (Circle-Line Intersection)" {
    const Context = struct {
        radius: f64,
        fn eval(ctx: *@This(), x: []const f64, fvec: []f64) i32 {
            // Residual 0: x^2 + y^2 - r^2 = 0
            fvec[0] = (x[0] * x[0] + x[1] * x[1]) - (ctx.radius * ctx.radius);
            // Residual 1: y - x = 0
            fvec[1] = x[1] - x[0];
            return 0;
        }
    };

    var ctx = Context{ .radius = 5.0 };
    var vars = [_]f64{ 1.0, 0.5 }; // Initial guess

    const status = eigen.minimizeNonLinear(
        Context,
        2,
        &vars,
        &ctx,
        Context.eval,
        1e-6,
        200,
    );

    try testing.expect(status.isSuccess());

    // Expected intersection in Quadrant 1: x = y = 5 / sqrt(2) ~= 3.5355339
    const expected = 5.0 / @sqrt(2.0);
    try testing.expectApproxEqAbs(expected, vars[0], 1e-4);
    try testing.expectApproxEqAbs(expected, vars[1], 1e-4);
}

test "WASM B-Rep: Surface-Surface Intersection Marching" {
    const alloc = testing.allocator;

    const a_cps = [_]math.Vec4{
        .{ 0, 0, 0, 1 },  .{ 10, 0, 0, 1 },
        .{ 0, 10, 0, 1 }, .{ 10, 10, 0, 1 },
    };
    const b_cps = [_]math.Vec4{
        .{ 0, 5, -5, 1 }, .{ 10, 5, -5, 1 },
        .{ 0, 5, 5, 1 },  .{ 10, 5, 5, 1 },
    };
    const knots = [_]f64{ 0, 0, 1, 1 };

    const surf_a = geom.NurbsSurface{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = &knots,
        .knots_v = &knots,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = &a_cps,
    };
    const surf_b = geom.NurbsSurface{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = &knots,
        .knots_v = &knots,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = &b_cps,
    };

    const seams = try nurbs_ssi.findAllIntersectionSeams(alloc, &surf_a, &surf_b, 1.0);
    defer {
        for (seams) |s| {
            alloc.free(s.points_3d);
            alloc.free(s.uvs_a);
            alloc.free(s.uvs_b);
        }
        alloc.free(seams);
    }

    try testing.expect(seams.len >= 1);
    try testing.expect(seams[0].points_3d.len > 3);
}
