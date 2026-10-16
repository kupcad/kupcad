const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");

test "Formatter: formats raw KupCAD code to expected layout" {
    const input_code = @embedFile("fixtures/format_in.kup");
    const expected_code = @embedFile("fixtures/format_out.kup");

    const allocator = testing.allocator;
    const formatted = try api.formatCode(allocator, input_code, .{});
    defer allocator.free(formatted);

    try testing.expectEqualStrings(expected_code, formatted);
}

test "Linter API: checkCode surfaces all expected diagnostics on bad fixture" {
    const bad_code = @embedFile("fixtures/linter_bad.kup");
    const allocator = testing.allocator;

    const diags = try api.checkCode(allocator, testing.io, bad_code, .{});
    defer api.freeDiagnostics(allocator, diags);

    // Unused 'unused_var', unused 'check_flow', self-subtraction, unreachable code.
    try testing.expectEqual(@as(usize, 4), diags.len);
    var found: std.StringHashMapUnmanaged(usize) = .empty;
    defer found.deinit(allocator);
    for (diags) |d| (try found.getOrPutValue(allocator, d.rule.?, 0)).value_ptr.* += 1;
    try testing.expectEqual(@as(?usize, 2), found.get("unused-variable"));
    try testing.expectEqual(@as(?usize, 1), found.get("self-subtraction"));
    try testing.expectEqual(@as(?usize, 1), found.get("unreachable-code"));
}

// The parser recovers from `y = )` by dropping the statement; building that tree used to
// export the cube as if the script were fine.
const syntax_broken_source =
    \\x = 1
    \\y = )
    \\cube(x)
;

test "API: buildModel rejects a script with syntax errors instead of dropping statements" {
    try testing.expectError(
        error.SyntaxError,
        api.buildModel(testing.allocator, testing.io, syntax_broken_source, "stl", false, null, null),
    );
}

test "API: buildModelWithDiagnostic reports the first syntax error as line:col: message" {
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.SyntaxError,
        api.buildModelWithDiagnostic(testing.allocator, testing.io, syntax_broken_source, "stl", false, null, null, &diag),
    );
    try testing.expectEqualStrings("2:5: Invalid expression starting with ')'", diag.message.?);
}

test "API: buildModelWithDiagnostic reports a compile error as line:col: message" {
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.ProtectedSymbol,
        api.buildModelWithDiagnostic(testing.allocator, testing.io, "w = 1\ncube = 5", "stl", false, null, null, &diag),
    );
    try testing.expectEqualStrings("2:1: 'cube' is a built-in and can't be assigned", diag.message.?);
}

test "API: checkCode reports compile errors as well as syntax errors and lints" {
    // It used to only parse and lint, so `cube = 5` passed check but failed to build.
    const diags = try api.checkCode(testing.allocator, testing.io, "cube = 5", .{});
    defer api.freeDiagnostics(testing.allocator, diags);
    var found = false;
    for (diags) |d| {
        if (d.severity == .@"error" and std.mem.eql(u8, d.message, "'cube' is a built-in and can't be assigned")) found = true;
    }
    try testing.expect(found);
}

test "API: buildModelWithDiagnostic returns model bytes and no message for a valid script" {
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    const bytes = try api.buildModelWithDiagnostic(testing.allocator, testing.io, "cube(10)", "stl", false, null, null, &diag);
    defer testing.allocator.free(bytes);

    // 80-byte header + u32 triangle count + 12 triangles of 50 bytes each
    try testing.expectEqual(@as(usize, 84 + 12 * 50), bytes.len);
    try testing.expect(diag.message == null);
}

test "API: buildModelWithDiagnostic reports the uncaught runtime error, not a rescued one" {
    // Math.sign reports its error before failing; once that is rescued, the report must
    // not shadow the error that actually ends the run.
    const source =
        \\begin
        \\  Math.sign("x")
        \\rescue => e
        \\  e
        \\end
        \\raise "Plate too thin"
        \\cube(1)
    ;
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.RuntimeError,
        api.buildModelWithDiagnostic(testing.allocator, testing.io, source, "stl", false, null, null, &diag),
    );
    try testing.expectEqualStrings("RuntimeError: Plate too thin", diag.message.?);
}

test "API: buildModelWithDiagnostic reports VM runtime errors as the CLI prints them" {
    const source =
        \\def bad_fn()
        \\  undefined_var + 10
        \\end
        \\bad_fn()
        \\cube(1)
    ;
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.RuntimeError,
        api.buildModelWithDiagnostic(testing.allocator, testing.io, source, "stl", false, null, null, &diag),
    );
    // One class prefix (it used to read "RuntimeError: Runtime Error: ...") and the real cause.
    try testing.expectEqualStrings("NameError: Undefined variable 'undefined_var'", diag.message.?);
}

test "API: buildModelWithDiagnostic keeps a native's own message over the generic boundary error" {
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.RuntimeError,
        api.buildModelWithDiagnostic(testing.allocator, testing.io, "Math.sign(\"x\")", "stl", false, null, null, &diag),
    );
    const msg = diag.message.?;
    try testing.expect(std.mem.indexOf(u8, msg, "Math.sign expects a number") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Native Execution Error") == null);
}

test "API: buildModelWithDiagnostic sets no message when nothing was reported" {
    // A rescued native report must not resurface as the reason for a later export failure.
    const source =
        \\begin
        \\  Math.sign("x")
        \\rescue => e
        \\  e
        \\end
        \\x = 1
    ;
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.NoGeometry,
        api.buildModelWithDiagnostic(testing.allocator, testing.io, source, "stl", false, null, null, &diag),
    );
    try testing.expect(diag.message == null);
}

test "API: buildModelWithDiagnostic reports an error raised while exporting" {
    // Geometry is lazy, so the run succeeds and the engine mismatch only surfaces when
    // the export evaluates the DAG: `part` is a concrete Manifold leaf, `cube(1)` is B-Rep.
    const source =
        \\part = cube(10).decompose[0]
        \\CAD.config(engine: :brep)
        \\part + cube(1)
    ;
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.RuntimeError,
        api.buildModelWithDiagnostic(testing.allocator, testing.io, source, "stl", false, null, null, &diag),
    );
    try testing.expectEqualStrings(
        "GeometryError: can't combine manifold and brep geometry in one operation",
        diag.message.?,
    );
}

test "API: a model the engine can't mesh says so, for every mesh format" {
    // The API, wasm and the CLI got only error.EngineCannotTessellate, with no message.
    const expected = "NotImplementedError: the brep engine can't tessellate solids for STL, glTF or the viewport (STEP export works) yet; build this part with engine: :manifold";
    inline for (.{ "stl", "glb", "gltf" }) |format| {
        var diag: api.BuildDiagnostic = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(error.RuntimeError, api.buildModelWithDiagnostic(testing.allocator, testing.io, "CAD.config(engine: :brep)\ncube(10)", format, false, null, null, &diag));
        try testing.expectEqualStrings(expected, diag.message.?);
    }
    // STEP is what the B-Rep engine exports.
    const step = try api.buildModel(testing.allocator, testing.io, "CAD.config(engine: :brep)\ncube(10)", "step", false, null, null);
    defer testing.allocator.free(step);
    try testing.expect(std.mem.startsWith(u8, step, "ISO-10303-21;"));
}

test "API: an STL of several parts is their union; glTF keeps them apart" {
    const source = "[cube(10), cube(10).translate(5, 0, 0)]";
    const stl = try api.buildModel(testing.allocator, testing.io, source, "stl", false, null, null);
    defer testing.allocator.free(stl);
    // One closed 15 x 10 x 10 box: the overlap is gone, so fewer than 2 x 12 triangles.
    try testing.expect(std.mem.readInt(u32, stl[80..84], .little) < 24);
    const glb = try api.buildModel(testing.allocator, testing.io, source, "glb", false, null, null);
    defer testing.allocator.free(glb);
    try testing.expectEqualStrings("glTF", glb[0..4]);
}
