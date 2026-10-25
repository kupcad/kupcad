const std = @import("std");
const testing = std.testing;

// Access all submodules via the kupcad module
const kupcad = @import("kupcad");
const wasm = kupcad.wasm;
const preview_frame = kupcad.api.preview_frame;
const VM = kupcad.vm.VM;
const chunk = kupcad.chunk;
const value = kupcad.value;

// Locus CAD Native Imports
const locus = kupcad.locus;
const math = locus.math;
const eigen = locus.eigen;

/// What build_model_wasm takes for "no parameter values", and for "no files".
const NO_PARAMS: []const u8 = "";
const NO_FILES: []const u8 = "";

test "WASM Interop: format_code_wasm handles invalid and empty inputs gracefully" {
    // Test Syntax Error Handling
    const bad_src = "class 123 { invalid }";
    var out_len: usize = 0;
    const res_bad = wasm.format_code_wasm(bad_src.ptr, bad_src.len, &out_len);

    // Formatter should fail and return null
    try testing.expect(res_bad == null);

    // Retrieve and verify the last error message (which is still a null-terminated constant)
    const err_ptr = wasm.get_last_error();
    const err_slice = std.mem.sliceTo(err_ptr, 0);
    try testing.expectEqualStrings("Syntax Error", err_slice);

    // Test Zero-Length / Empty Input
    const empty_src = "";
    var empty_len: usize = 0;
    const res_empty = wasm.format_code_wasm(empty_src.ptr, empty_src.len, &empty_len);

    if (res_empty) |ptr| {
        // Safely construct the slice using the explicit length
        const empty_slice = ptr[0..empty_len];
        try testing.expectEqualStrings("", empty_slice);

        // Prevent memory leaks in the test environment
        wasm.wasm_free(@constCast(ptr), empty_len);
    } else {
        const err_ptr2 = wasm.get_last_error();
        const err_slice2 = std.mem.sliceTo(err_ptr2, 0);
        try testing.expectEqualStrings("Syntax Error", err_slice2);
    }
}

test "WASM Interop: check_code_wasm returns valid JSON on syntax errors" {
    // Test Syntax Error Handling
    const bad_src = "def !invalid";
    var out_len: usize = 0;
    const res_bad = wasm.check_code_wasm(bad_src.ptr, bad_src.len, &out_len);

    try testing.expect(res_bad != null);

    // Construct the slice precisely
    const bad_slice = res_bad.?[0..out_len];

    // Verify it is a valid JSON array structure
    try testing.expect(bad_slice.len >= 2);
    try testing.expect(bad_slice[0] == '[');
    try testing.expect(bad_slice[bad_slice.len - 1] == ']');

    wasm.wasm_free(@constCast(res_bad.?), out_len);

    // Test Zero-Length / Empty Input
    const empty_src = "";
    var empty_len: usize = 0;
    const res_empty = wasm.check_code_wasm(empty_src.ptr, empty_src.len, &empty_len);

    try testing.expect(res_empty != null);
    const empty_slice = res_empty.?[0..empty_len];

    // An empty file has no diagnostics, so it should return an empty JSON array
    try testing.expectEqualStrings("[]", empty_slice);

    wasm.wasm_free(@constCast(res_empty.?), empty_len);
}

test "VM: Character ranges evaluate to an Array of Strings" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    // Built by hand, so registered as the compiler registers its chunks (see -Dgc-stress).
    try vm.gc.trackChunk(&out_chunk);

    // Each string is a constant of the registered chunk before the next allocation.
    const a_idx = try out_chunk.addConstant(testing.allocator, try vm.allocateString("a"));
    const d_idx = try out_chunk.addConstant(testing.allocator, try vm.allocateString("d"));
    const step_idx = try out_chunk.addConstant(testing.allocator, value.Value.initNumber(1));

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

    const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", arr_val.asObj()));
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
    func.local_count = 3; // slot 0: the closure, slots 1-2: the parameters

    // 2. Call it with only ONE argument
    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(testing.allocator);
    // Built by hand, so registered as the compiler registers its chunks (see -Dgc-stress).
    try vm.gc.trackChunk(&main_chunk);

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
    try main_chunk.write(testing.allocator, 0, 0); // CallFlags
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
    const stl_ptr = wasm.build_model_wasm(src.ptr, src.len, NO_PARAMS.ptr, NO_PARAMS.len, NO_FILES.ptr, NO_FILES.len, stl_fmt.ptr, stl_fmt.len, false, &stl_len);

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
    const glb_ptr = wasm.build_model_wasm(src.ptr, src.len, NO_PARAMS.ptr, NO_PARAMS.len, NO_FILES.ptr, NO_FILES.len, glb_fmt.ptr, glb_fmt.len, false, &glb_len);

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

test "WASM Interop: build_model_wasm supports benchmark blocks (vm.io must be a real Io)" {
    // Audit regression: buildModel used to receive `io = undefined`, so Clock.now in
    // `benchmark` dereferenced garbage and trapped the instance.
    const src =
        \\b = benchmark("t") do
        \\  1 + 1
        \\end
        \\cube(1)
    ;
    const fmt = "stl";
    var out_len: usize = 0;
    const res = wasm.build_model_wasm(src.ptr, src.len, NO_PARAMS.ptr, NO_PARAMS.len, NO_FILES.ptr, NO_FILES.len, fmt.ptr, fmt.len, false, &out_len);
    try testing.expect(res != null);
    try testing.expect(out_len > 84);
    wasm.wasm_free(@constCast(res.?), out_len);
}

/// Runs build_model_wasm on `src`, expecting it to fail, and returns get_last_error().
fn expectBuildFailure(src: []const u8) ![]const u8 {
    return expectBuildFailureWith(src, NO_PARAMS);
}

/// expectBuildFailure with the parameter values in `params` (JSON).
fn expectBuildFailureWith(src: []const u8, params: []const u8) ![]const u8 {
    const fmt = "stl";
    var out_len: usize = 0;
    const res = wasm.build_model_wasm(src.ptr, src.len, params.ptr, params.len, NO_FILES.ptr, NO_FILES.len, fmt.ptr, fmt.len, false, &out_len);
    if (res) |ptr| {
        wasm.wasm_free(@constCast(ptr), out_len);
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 0), out_len);
    return std.mem.sliceTo(wasm.get_last_error(), 0);
}

test "WASM Interop: build_model_wasm rejects syntax errors with their line:col" {
    // The parser drops `y = )` and recovers; this used to export the cube anyway.
    const src =
        \\x = 1
        \\y = )
        \\cube(x)
    ;
    try testing.expectEqualStrings("2:5: Invalid expression starting with ')' [invalid-expression]", try expectBuildFailure(src));
}

test "WASM Interop: build_model_wasm reports the runtime error message" {
    const src =
        \\raise "Plate too thin"
        \\cube(1)
    ;
    try testing.expectEqualStrings("RuntimeError: Plate too thin", try expectBuildFailure(src));

    // A native that reports and fails: its own message, not the generic one raised after it
    const native_msg = try expectBuildFailure("Math.sign(\"x\")");
    try testing.expect(std.mem.find(u8, native_msg, "Math.sign expects a number") != null);
    try testing.expect(std.mem.find(u8, native_msg, "Native Execution Error") == null);
}

test "WASM Interop: build_model_wasm reports a script that leaves no model" {
    // The script runs fine but leaves nothing to export; it was a bare "Build Error: NoGeometry"
    try testing.expectEqualStrings("TypeError: the script's last value (Number) is not a model: end it with a Solid, a Sketch, a Path, an Assembly or an Array of them", try expectBuildFailure("x = 1"));
}

test "WASM Interop: get_last_error truncates long messages on a UTF-8 boundary" {
    // "RuntimeError: x" is 15 bytes, so the 2-byte 'é' sequences straddle the byte limit.
    const src =
        \\s = "x"
        \\i = 0
        \\while i < 800
        \\  s = s + "é"
        \\  i += 1
        \\end
        \\raise s
    ;
    const msg = try expectBuildFailure(src);
    try testing.expect(std.mem.startsWith(u8, msg, "RuntimeError: xé"));
    try testing.expect(msg.len <= wasm.MAX_ERROR_MSG_LEN);
    try testing.expect(msg.len > wasm.MAX_ERROR_MSG_LEN - "é".len);
    try testing.expect(std.unicode.utf8ValidateSlice(msg));
}

/// Builds `src` as STL and returns its bytes' length (freeing them).
fn expectBuildLength(src: []const u8) !usize {
    return expectBuildLengthWith(src, NO_PARAMS);
}

/// expectBuildLength with the parameter values in `params` (JSON).
fn expectBuildLengthWith(src: []const u8, params: []const u8) !usize {
    const fmt = "stl";
    var out_len: usize = 0;
    const res = wasm.build_model_wasm(src.ptr, src.len, params.ptr, params.len, NO_FILES.ptr, NO_FILES.len, fmt.ptr, fmt.len, false, &out_len) orelse {
        std.debug.print("build failed: {s}\n", .{std.mem.sliceTo(wasm.get_last_error(), 0)});
        return error.BuildFailed;
    };
    wasm.wasm_free(@constCast(res), out_len);
    return out_len;
}

test "WASM Interop: build_model_wasm takes parameter values as a JSON object" {
    // The browser couldn't set a parameter at all. Each cube is 12 triangles of 50 bytes.
    const src = "n = param(:n, default: 1)\nlabel = param(:label, default: \"x\")\nraise label unless label == \"ok\" || n == 1\nunion((0...n).map { |i| cube(1).translate(x: i * 3) })";
    try testing.expectEqual(@as(usize, 84 + 12 * 50), try expectBuildLength(src));
    try testing.expectEqual(@as(usize, 84 + 3 * 12 * 50), try expectBuildLengthWith(src, "{\"n\": 3, \"label\": \"ok\"}"));
    // A refusal says it is about the parameters, not the script.
    try testing.expectEqualStrings("parameters: parameter 'n' is an array; a parameter takes a number, a string, true or false", try expectBuildFailureWith(src, "{\"n\": [1, 2]}"));
    try testing.expectEqualStrings("parameters: line 1, column 2: invalid JSON", try expectBuildFailureWith(src, "{n: 3}"));
}

test "WASM Interop: a build the instruction cap stops leaves the next one working" {
    // In the browser a runaway loop stops at the cap, and the worker goes on serving builds.
    const msg = try expectBuildFailure("while true\nend\ncube(1)");
    try testing.expect(std.mem.find(u8, msg, "Execution limit") != null);
    try testing.expectEqual(@as(usize, 84 + 12 * 50), try expectBuildLength("cube(2)"));
}

test "WASM Interop: repeated builds, previews, checks and formats don't grow the module's memory" {
    // Whatever one call leaves allocated (in the VFS, the error buffer, a cache) adds up
    // over an editing session in the browser, which never restarts the module.
    const src = "w = param(:w, default: 4)\nx = [cube(w).material(color: \"#FF0000\"), sphere(2).translate(x: 6)]\nx";
    const fmt = "glb";
    const once = struct {
        fn run(source: []const u8, format: []const u8) !void {
            var len: usize = 0;
            const built = wasm.build_model_wasm(source.ptr, source.len, NO_PARAMS.ptr, NO_PARAMS.len, NO_FILES.ptr, NO_FILES.len, format.ptr, format.len, true, &len) orelse return error.BuildFailed;
            wasm.wasm_free(@constCast(built), len);
            const checked = wasm.check_code_wasm(source.ptr, source.len, &len) orelse return error.CheckFailed;
            wasm.wasm_free(@constCast(checked), len);
            const formatted = wasm.format_code_wasm(source.ptr, source.len, &len) orelse return error.FormatFailed;
            wasm.wasm_free(@constCast(formatted), len);
            const previewed = wasm.preview_wasm(source.ptr, source.len, NO_PARAMS.ptr, NO_PARAMS.len, NO_FILES.ptr, NO_FILES.len, &len) orelse return error.PreviewFailed;
            wasm.wasm_free(@constCast(previewed), len);
            _ = try expectBuildFailure("raise \"x\"");
        }
    };
    for (0..3) |_| try once.run(src, fmt); // the allocator's own pools settle first
    const pages = @wasmMemorySize(0);
    for (0..30) |_| try once.run(src, fmt);
    try testing.expectEqual(pages, @wasmMemorySize(0));
}

test "WASM Interop: wasm_alloc of nothing, of more than memory holds, and past the initial memory" {
    // JS asks for 0 bytes for an empty file: a pointer it can hand back to wasm_free.
    const empty = wasm.wasm_alloc(0) orelse return error.TestUnexpectedResult;
    wasm.wasm_free(empty, 0);

    // More than the 4 GiB memory can hold: null, for JS to report, not a trap (malloc's
    // header overflowed the size and panicked).
    try testing.expect(wasm.wasm_alloc(std.math.maxInt(usize)) == null);
    try testing.expect(wasm.wasm_alloc(std.math.maxInt(usize) - 8) == null);

    // Past the initial 128 MiB the memory grows, and all of the block is usable.
    const initial_bytes = 128 * 1024 * 1024;
    const len = 2 * initial_bytes;
    const block = wasm.wasm_alloc(len) orelse return error.TestUnexpectedResult;
    defer wasm.wasm_free(block, len);
    try testing.expect(@wasmMemorySize(0) * std.wasm.page_size > initial_bytes);
    block[0] = 1;
    block[len - 1] = 2;
    try testing.expectEqual(@as(u8, 1), block[0]);
    try testing.expectEqual(@as(u8, 2), block[len - 1]);

    // And a build still works in the grown memory.
    try testing.expect(try expectBuildLength("cube(2)") > 84);
}

test "WASM Interop: a recursion through built-ins is an error, not a trapped instance" {
    // Each run nested in a built-in's call is wasm stack, whose limit the engine sets (512
    // KiB in wasmtime): `map` recursion trapped the module before 1000 levels, ending every
    // build in that tab. The nested-run limit stops it with an error.
    const sources = [_][]const u8{
        "def f(n) = n == 0 ? 0 : [1].map { |x| f(n - 1) + x }[0]\nf(5000)\ncube(1)",
        "class Loop < RuntimeError\n  def initialize\n    raise Loop\n  end\nend\nraise Loop",
    };
    for (sources) |src| {
        const msg = try expectBuildFailure(src);
        try testing.expect(std.mem.find(u8, msg, "Call stack overflow") != null);
    }
    try testing.expect(try expectBuildLength("cube(1)") > 84); // and the next build works
}

/// Builds `src` as STL with the files given, and returns its bytes' length (freeing them);
/// the core's message when it fails.
fn buildWithFiles(src: []const u8, files: []const kupcad.vfs_packed.File) !union(enum) { built: usize, failed: []const u8 } {
    const packed_bytes = try kupcad.vfs_packed.pack(testing.allocator, files);
    defer testing.allocator.free(packed_bytes);
    const fmt = "stl";
    var out_len: usize = 0;
    const res = wasm.build_model_wasm(src.ptr, src.len, NO_PARAMS.ptr, NO_PARAMS.len, packed_bytes.ptr, packed_bytes.len, fmt.ptr, fmt.len, false, &out_len) orelse {
        return .{ .failed = std.mem.sliceTo(wasm.get_last_error(), 0) };
    };
    wasm.wasm_free(@constCast(res), out_len);
    return .{ .built = out_len };
}

test "WASM Interop: a build imports the files given with it, and the next call none of them" {
    const plate: kupcad.vfs_packed.File = .{ .path = "parts/plate.kup", .content = "def plate(w)\n  cube(w, w, 1)\nend\nexport { plate }" };
    const size: kupcad.vfs_packed.File = .{ .path = "size.json", .content = "{\"w\": 3}" };
    const main = "import { plate } from \"./parts/plate.kup\"\nplate(import_json(\"size.json\")[:w])";
    try testing.expectEqual(@as(usize, 84 + 12 * 50), (try buildWithFiles(main, &.{ plate, size })).built);
    // Without them, the import is what fails: the files were that call's alone
    const msg = (try buildWithFiles(main, &.{})).failed;
    try testing.expect(std.mem.find(u8, msg, "plate.kup") != null);
    // Files packed wrong are the host's fault, not the script's: refused as such
    var out_len: usize = 0;
    const fmt = "stl";
    const cut = "\x05\x00\x00\x00ab";
    try testing.expect(wasm.build_model_wasm(main.ptr, main.len, NO_PARAMS.ptr, NO_PARAMS.len, cut.ptr, cut.len, fmt.ptr, fmt.len, false, &out_len) == null);
    try testing.expectEqualStrings("Build Error: MalformedFiles", std.mem.sliceTo(wasm.get_last_error(), 0));
}

test "WASM Interop: a preview imports the files given with it" {
    const lib: kupcad.vfs_packed.File = .{ .path = "lib.kup", .content = "side = 2\nexport side\n" };
    const packed_bytes = try kupcad.vfs_packed.pack(testing.allocator, &.{lib});
    defer testing.allocator.free(packed_bytes);
    const src = "import { side } from \"./lib.kup\"\ncube(side)";
    var len: usize = 0;
    const res = wasm.preview_wasm(src.ptr, src.len, NO_PARAMS.ptr, NO_PARAMS.len, packed_bytes.ptr, packed_bytes.len, &len) orelse return error.PreviewFailed;
    defer wasm.wasm_free(@constCast(res), len);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const read = try kupcad.test_support.readFrame(arena.allocator(), res[0..len]);
    try testing.expectEqualStrings("3d", read.header.kind);
    // Without the file, the frame says why
    var missing = try previewOf(src, NO_PARAMS);
    defer missing.arena.deinit();
    try testing.expectEqualStrings("none", missing.kind);
    try testing.expect(std.mem.find(u8, missing.message.?, "lib.kup") != null);
}

test "WASM Interop: check_code_wasm's JSON is check --format json's finding, without its path" {
    const src = "x = 1\ncube(-2)";
    var len: usize = 0;
    const res = wasm.check_code_wasm(src.ptr, src.len, &len) orelse return error.CheckFailed;
    defer wasm.wasm_free(@constCast(res), len);
    // Parsed strictly: a field missing or added fails
    const parsed = try std.json.parseFromSlice([]CheckFinding, testing.allocator, res[0..len], .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.len);
    const unused = parsed.value[0];
    try testing.expectEqual(@as(u32, 1), unused.line); // one-based, as an editor shows them
    try testing.expectEqual(@as(u32, 1), unused.column);
    try testing.expectEqualStrings("x", src[unused.offset..][0..unused.length]);
    try testing.expectEqualStrings("unused-variable", unused.rule.?);
    try testing.expectEqualStrings("_x", unused.fix.?.edits[0].text);
    const negative = parsed.value[1];
    try testing.expectEqual(@as(u32, 2), negative.line);
    try testing.expectEqual(@as(u32, 6), negative.column);
    try testing.expectEqual(@as(u32, 8), negative.endColumn);
    try testing.expectEqualStrings("-2", src[negative.offset..][0..negative.length]);
    try testing.expectEqualStrings("nonpositive-size", negative.code);
    try testing.expectEqualStrings("warning", negative.severity);
}

const CheckEdit = struct { line: u32, column: u32, endLine: u32, endColumn: u32, offset: u32, length: u32, text: []const u8 };
const CheckFinding = struct {
    line: u32,
    column: u32,
    endLine: u32,
    endColumn: u32,
    offset: u32,
    length: u32,
    severity: []const u8,
    rule: ?[]const u8,
    code: []const u8,
    message: []const u8,
    fix: ?struct { title: []const u8, safe: bool, edits: []const CheckEdit },
};

test "WASM Interop: check_code_wasm's JSON gives a syntax error its code, as a finding its rule" {
    const src = "cube(1";
    var len: usize = 0;
    const res = wasm.check_code_wasm(src.ptr, src.len, &len) orelse return error.CheckFailed;
    defer wasm.wasm_free(@constCast(res), len);
    const parsed = try std.json.parseFromSlice([]CheckFinding, testing.allocator, res[0..len], .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.len);
    try testing.expectEqualStrings("error", parsed.value[0].severity);
    try testing.expectEqualStrings("unexpected-token", parsed.value[0].code);
    // A syntax error is no rule's
    try testing.expectEqual(@as(?[]const u8, null), parsed.value[0].rule);
}

test "WASM Interop: extract_params_wasm's JSON is the schema kupcad doc prints" {
    const src =
        \\# @title Plate
        \\w = param(:width, default: 10, validate: { min: 1, max: 50 }, step: 0.5, unit: "mm", group: "Size")
        \\m = param(:material, default: "PLA", validate: { in: ["PLA", "PETG"] })
        \\cube(w)
    ;
    var len: usize = 0;
    const res = wasm.extract_params_wasm(src.ptr, src.len, &len) orelse return error.ExtractFailed;
    defer wasm.wasm_free(@constCast(res), len);
    const Schema = struct {
        meta: struct { title: ?[]const u8, description: ?[]const u8, author: ?[]const u8 },
        parameters: []struct {
            name: []const u8,
            type: []const u8,
            default_value: std.json.Value,
            validate: struct { min: ?f64, max: ?f64, in: ?[]const std.json.Value },
            step: ?f64,
            unit: ?[]const u8,
            group: ?[]const u8,
        },
    };
    const parsed = try std.json.parseFromSlice(Schema, testing.allocator, res[0..len], .{});
    defer parsed.deinit();
    const s = parsed.value;
    try testing.expectEqualStrings("Plate", s.meta.title.?);
    try testing.expectEqual(@as(usize, 2), s.parameters.len);
    try testing.expectEqualStrings("width", s.parameters[0].name);
    try testing.expectEqual(@as(?f64, 1), s.parameters[0].validate.min);
    try testing.expectEqual(@as(?f64, 50), s.parameters[0].validate.max);
    try testing.expectEqual(@as(?f64, 0.5), s.parameters[0].step);
    try testing.expectEqualStrings("mm", s.parameters[0].unit.?);
    try testing.expectEqualStrings("Size", s.parameters[0].group.?);
    try testing.expectEqual(@as(?[]const u8, null), s.parameters[1].unit);
    try testing.expectEqualStrings("material", s.parameters[1].name);
    try testing.expectEqualStrings("PLA", s.parameters[1].default_value.string);
    try testing.expectEqual(@as(usize, 2), s.parameters[1].validate.in.?.len);
}

test "WASM GC: scripts under GC stress run right with 32-bit pointers" {
    // The collector, the NaN-boxed values and the natives' rooting, where usize and every
    // pointer are 32 bits: the native suite only ever runs them with 64.
    const support = kupcad.test_support;
    try support.expectScripts(&.{
        .{ .src = "a = (1..50).map { |i| \"s#{i}\" }\nr = a.join(\",\").length", .expected = .{ .num = 190 }, .gc_stress = true },
        .{ .src = "m = {}\n(1..40).each { |i| m[\"k#{i}\"] = [i, i * 2] }\nr = m.values.map { |v| v[1] }.reduce(0) { |s, v| s + v }", .expected = .{ .num = 1640 }, .gc_stress = true },
        .{ .src = "add = ->(x) { ->(y) { x + y } }\nr = (1..20).map { |i| add.call(i).call(1) }.last", .expected = .{ .num = 21 }, .gc_stress = true },
        .{ .src = "class P\n  def initialize(v)\n    @v = v\n  end\n  def v\n    @v\n  end\nend\nr = (1..30).map { |i| P.new(i) }.map { |p| p.v }.reduce(0) { |s, v| s + v }", .expected = .{ .num = 465 }, .gc_stress = true },
    });
}

test "WASM Interop: build_model_wasm writes 3MF, a zip of the model's parts" {
    const src = "bolt = cylinder(r: 1, h: 5)\nassemble(name: \"pair\", parts: [bolt, bolt.translate(3, 0, 0)])";
    const fmt = "3mf";
    var out_len: usize = 0;
    const res = wasm.build_model_wasm(src.ptr, src.len, NO_PARAMS.ptr, NO_PARAMS.len, NO_FILES.ptr, NO_FILES.len, fmt.ptr, fmt.len, false, &out_len) orelse {
        std.debug.print("build failed: {s}\n", .{std.mem.sliceTo(wasm.get_last_error(), 0)});
        return error.BuildFailed;
    };
    defer wasm.wasm_free(@constCast(res), out_len);
    try testing.expectEqualSlices(u8, "PK\x03\x04", res[0..4]);
}

/// The preview frame preview_wasm gives for `src` with `params`: its header's kind and its
/// error's message, and whether its body is a GLB.
fn previewOf(src: []const u8, params: []const u8) !struct { kind: []const u8, message: ?[]const u8, glb: bool, arena: std.heap.ArenaAllocator } {
    var len: usize = 0;
    const res = wasm.preview_wasm(src.ptr, src.len, params.ptr, params.len, NO_FILES.ptr, NO_FILES.len, &len) orelse return error.PreviewFailed;
    defer wasm.wasm_free(@constCast(res), len);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const read = try kupcad.test_support.readFrame(arena.allocator(), res[0..len]);
    return .{
        .kind = read.header.kind,
        .message = if (read.header.@"error") |e| e.message else null,
        .glb = std.mem.startsWith(u8, read.body, "glTF"),
        .arena = arena,
    };
}

test "WASM Interop: preview_wasm gives a frame: the model as GLB, or why it failed" {
    var cube = try previewOf("w = param(:w, default: 2)\ncube(w)", "{\"w\": 3}");
    defer cube.arena.deinit();
    try testing.expectEqualStrings("3d", cube.kind);
    try testing.expect(cube.glb);
    try testing.expect(cube.message == null);

    var refused = try previewOf("cube(2)", "{\"w\": [1]}");
    defer refused.arena.deinit();
    try testing.expectEqualStrings("none", refused.kind);
    try testing.expect(std.mem.startsWith(u8, refused.message.?, "parameters: parameter 'w' is an array"));

    var failed = try previewOf("cube(1)\nraise \"boom\"", "");
    defer failed.arena.deinit();
    try testing.expectEqualStrings("none", failed.kind);
    try testing.expectEqualStrings("RuntimeError: boom", failed.message.?);
}

test "WASM Interop: version_wasm says what kupcad version --json says, of this module" {
    var len: usize = 0;
    const res = wasm.version_wasm(&len) orelse return error.VersionFailed;
    defer wasm.wasm_free(@constCast(res), len);
    // Parsed strictly: what a page reads, field for field
    const Info = struct { version: []const u8, protocolVersion: u32, os: []const u8, arch: []const u8 };
    const parsed = try std.json.parseFromSlice(Info, testing.allocator, res[0..len], .{});
    defer parsed.deinit();
    const built: kupcad.version.Info = .{};
    try testing.expectEqualStrings(built.version, parsed.value.version);
    try testing.expectEqual(preview_frame.PROTOCOL_VERSION, parsed.value.protocolVersion);
    try testing.expectEqualStrings("wasi", parsed.value.os);
    try testing.expectEqualStrings("wasm32", parsed.value.arch);
}
