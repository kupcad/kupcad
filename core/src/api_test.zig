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

    var found_csg = false;
    var found_unreachable = false;
    var found_unused_var = false;
    var found_unused_flow = false;

    for (diags) |d| {
        if (std.mem.indexOf(u8, d.message, "Self-difference") != null) found_csg = true;
        if (std.mem.indexOf(u8, d.message, "Unreachable code") != null) found_unreachable = true;
        if (std.mem.indexOf(u8, d.message, "Unused variable 'unused_var'") != null) found_unused_var = true;
        if (std.mem.indexOf(u8, d.message, "Unused variable 'check_flow'") != null) found_unused_flow = true;
    }

    try testing.expect(found_csg);
    try testing.expect(found_unreachable);
    try testing.expect(found_unused_var);
    try testing.expect(found_unused_flow);
}

test "API: benchmarkScript completes successfully on valid code" {
    const source =
        \\def calculate_val(a)
        \\  a * 3.0
        \\end
        \\
        \\c = cube(5.0)
        \\val = calculate_val(2.0)
        \\c.translate(val, 0.0, 0.0)
    ;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try api.benchmarkScript(testing.allocator, source, testing.io, &out.writer);
    try testing.expect(out.written().len > 0);
}

test "API: benchmarkScript propagates errors on syntax failure" {
    const invalid_source = "def broken_syntax(";

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try testing.expectError(error.ParseError, api.benchmarkScript(testing.allocator, invalid_source, testing.io, &out.writer));
}

test "API: benchmarkScript propagates error.RuntimeError on VM runtime failure" {
    const runtime_err_source =
        \\def bad_fn()
        \\  undefined_var + 10
        \\end
        \\bad_fn()
    ;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try testing.expectError(error.RuntimeError, api.benchmarkScript(testing.allocator, runtime_err_source, testing.io, &out.writer));
}

test "API: benchmarkScript handles empty source code cleanly" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // Ensures zero-instruction scripts compile and profile without underflowing or panicking
    try api.benchmarkScript(testing.allocator, "", testing.io, &out.writer);
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
        error.EngineMismatch,
        api.buildModelWithDiagnostic(testing.allocator, testing.io, source, "stl", false, null, null, &diag),
    );
    try testing.expectEqualStrings(
        "GeometryError: can't combine manifold and brep geometry in one operation",
        diag.message.?,
    );
}
