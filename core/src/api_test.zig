const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");
const support = @import("test_support.zig");

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
    for (diags) |d| (try found.getOrPutValue(allocator, d.ruleId().?, 0)).value_ptr.* += 1;
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
        api.buildModel(testing.allocator, testing.io, syntax_broken_source, .{ .format = .stl }),
    );
}

test "API: buildModel with a diagnostic reports the first syntax error as line:col: message" {
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.SyntaxError,
        api.buildModel(testing.allocator, testing.io, syntax_broken_source, .{ .format = .stl, .diagnostic = &diag }),
    );
    try testing.expectEqualStrings("2:5: Invalid expression starting with ')' [invalid-expression]", diag.message.?);
}

test "API: buildModel with a diagnostic reports a compile error as line:col: message" {
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.ProtectedSymbol,
        api.buildModel(testing.allocator, testing.io, "w = 1\ncube = 5", .{ .format = .stl, .diagnostic = &diag }),
    );
    try testing.expectEqualStrings("2:1: 'cube' is a built-in and can't be assigned [builtin-redefined]", diag.message.?);
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

test "API: buildModel runs under the interactive limits when asked, as a browser's build is" {
    // Natively a build runs without an instruction limit: this one would never end
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.RuntimeError, api.buildModel(testing.allocator, testing.io, "while true\nend\ncube(1)", .{ .format = .stl, .diagnostic = &diag, .interactive = true }));
    try testing.expect(std.mem.find(u8, diag.message.?, "Execution limit") != null);
}

test "API: buildModel with a diagnostic returns model bytes and no message for a valid script" {
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    const bytes = try api.buildModel(testing.allocator, testing.io, "cube(10)", .{ .format = .stl, .diagnostic = &diag });
    defer testing.allocator.free(bytes);

    // 80-byte header + u32 triangle count + 12 triangles of 50 bytes each
    try testing.expectEqual(@as(usize, 84 + 12 * 50), bytes.len);
    try testing.expect(diag.message == null);
}

test "API: buildModel with a diagnostic reports the uncaught runtime error, not a rescued one" {
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
        api.buildModel(testing.allocator, testing.io, source, .{ .format = .stl, .diagnostic = &diag }),
    );
    try testing.expectEqualStrings("RuntimeError: Plate too thin", diag.message.?);
}

test "API: buildModel with a diagnostic reports VM runtime errors as the CLI prints them" {
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
        api.buildModel(testing.allocator, testing.io, source, .{ .format = .stl, .diagnostic = &diag }),
    );
    // One class prefix (it used to read "RuntimeError: Runtime Error: ...") and the real cause.
    try testing.expectEqualStrings("NameError: Undefined variable 'undefined_var'", diag.message.?);
}

test "API: buildModel with a diagnostic keeps a native's own message over the generic boundary error" {
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.RuntimeError,
        api.buildModel(testing.allocator, testing.io, "Math.sign(\"x\")", .{ .format = .stl, .diagnostic = &diag }),
    );
    const msg = diag.message.?;
    try testing.expect(std.mem.find(u8, msg, "Math.sign expects a number") != null);
    try testing.expect(std.mem.find(u8, msg, "Native Execution Error") == null);
}

test "API: buildModel with a diagnostic sets no message when nothing was reported" {
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
        error.RuntimeError,
        api.buildModel(testing.allocator, testing.io, source, .{ .format = .stl, .diagnostic = &diag }),
    );
    // The export's own report, not the rescued one
    try testing.expectEqualStrings("TypeError: the script's last value (Number) is not a model: end it with a Solid, a Sketch, a Path, an Assembly or an Array of them", diag.message.?);
}

test "API: a model a format can't hold is refused with a message, never cut down to fit" {
    // A Sketch beside Solids was dropped from the file, a Number or nil in the Array too,
    // an Array inside the Array with everything in it, and a Sketch alone or a script
    // ending in a Number failed with a bare NoGeometry.
    const refused = [_]struct { source: []const u8, format: api.ExportFormat = .stl, message: []const u8 }{
        .{ .source = "circle(r: 5)", .message = "TypeError: the model is a Sketch, which stl (a 3D format) can't hold: extrude it (.extrude(h)) to a Solid" },
        .{ .source = "[cube(1), circle(r: 1)]", .format = .glb, .message = "TypeError: the model holds a Sketch, which glb (a 3D format) can't hold: extrude it (.extrude(h)) to a Solid" },
        .{ .source = "[cube(1), 1]", .message = "TypeError: the model's item 2 (Number) is not a shape: a model holds Solids, Sketches, Paths and Arrays of them" },
        .{ .source = "[cube(1), [cube(2), nil]]", .message = "TypeError: the model's item 2.2 (nil) is not a shape: a model holds Solids, Sketches, Paths and Arrays of them" },
        .{ .source = "\"model\"", .message = "TypeError: the script's last value (String) is not a model: end it with a Solid, a Sketch, a Path, an Assembly or an Array of them" },
        .{ .source = "[]", .message = "GeometryError: the model holds no Solid: nothing to write as stl" },
        .{ .source = "line([0, 0], [1, 0])", .message = "TypeError: the model holds only open paths: stl (a 3D format) needs Solids; a Path is open and encloses nothing: close it (.close) into a Sketch or give it a width (.stroke(w)) first, then extrude it" },
        .{ .source = "[cube(1), line([0, 0], [1, 0])]", .format = .obj, .message = "TypeError: the model holds a Path, which obj (a 3D format) can't hold: a Path is open and encloses nothing: close it (.close) into a Sketch or give it a width (.stroke(w)) first, then extrude it" },
        .{ .source = "cube(1).ghost\nnil", .message = "GeometryError: the model holds no Solid: nothing to write as stl" },
        .{ .source = "cube(1).ghost\nnil", .format = .@"3mf", .message = "GeometryError: the model holds no Solid: nothing to write as 3mf" },
    };
    for (refused) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        var diag: api.BuildDiagnostic = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(error.RuntimeError, api.buildModel(testing.allocator, testing.io, case.source, .{ .format = case.format, .diagnostic = &diag }));
        try testing.expectEqualStrings(case.message, diag.message.?);
    }
    // Nested Arrays are the model too, and the viewer's formats take ghosts alone
    const accepted = [_]struct { source: []const u8, format: api.ExportFormat = .stl }{
        .{ .source = "[[cube(1), [cube(2)]], cube(3)]" },
        .{ .source = "assemble(name: \"a\", parts: [cube(1)])" },
        .{ .source = "cube(1).ghost\nnil", .format = .glb },
    };
    for (accepted) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        const bytes = try api.buildModel(testing.allocator, testing.io, case.source, .{ .format = case.format });
        defer testing.allocator.free(bytes);
        try testing.expect(bytes.len > 0);
    }
}

test "API: the parts list of a model with no Solid is refused with a message" {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, "circle(r: 1)"));
    try testing.expectError(error.RuntimeError, api.billOfMaterials(testing.allocator, &vm));
    try testing.expectEqualStrings("GeometryError: the model holds no Solid: nothing for the parts list", vm.last_error.?);
}

test "API: buildModel with a diagnostic reports an error raised while exporting" {
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
        api.buildModel(testing.allocator, testing.io, source, .{ .format = .stl, .diagnostic = &diag }),
    );
    try testing.expectEqualStrings(
        "GeometryError: can't combine manifold and brep geometry in one operation",
        diag.message.?,
    );
}

test "API: a model the engine can't mesh says so, for every mesh format" {
    // The API, wasm and the CLI got only error.EngineCannotTessellate, with no message.
    const expected = "NotImplementedError: the brep engine can't tessellate solids for STL, glTF, 3MF, OBJ or the viewport (STEP export works) yet; build this part with engine: :manifold";
    inline for (.{ "stl", "glb", "gltf" }) |format| {
        var diag: api.BuildDiagnostic = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(error.RuntimeError, api.buildModel(testing.allocator, testing.io, "CAD.config(engine: :brep)\ncube(10)", .{ .format = api.ExportFormat.parse(format).?, .diagnostic = &diag }));
        try testing.expectEqualStrings(expected, diag.message.?);
    }
    // STEP is what the B-Rep engine exports.
    const step = try api.buildModel(testing.allocator, testing.io, "CAD.config(engine: :brep)\ncube(10)", .{ .format = .step });
    defer testing.allocator.free(step);
    try testing.expect(std.mem.startsWith(u8, step, "ISO-10303-21;"));
}

test "API: a STEP build refuses a part that isn't exact geometry, instead of dropping it" {
    // The B-Rep writer skipped every mesh part: a model with a Manifold part exported a
    // STEP file without it, and an all-Manifold model failed with a bare NoGeometry.
    const cases = [_]struct { src: []const u8, message: []const u8 }{
        .{
            // A STEP build makes everything with the B-Rep engine, unless the script asks
            // for another one.
            .src = "m = nil\nCAD.with_config(engine: :manifold) do\n  m = cube(10).translate(20, 0, 0)\nend\n[cylinder(r: 2, h: 5), m]",
            .message = "NotImplementedError: STEP export needs exact geometry, and part 2 of 2 was built by the manifold engine (a mesh); build it with engine: :brep",
        },
        .{
            .src = "CAD.config(engine: :manifold)\ncube(10)",
            .message = "NotImplementedError: STEP export needs exact geometry, and the model was built by the manifold engine (a mesh); build it with engine: :brep",
        },
    };
    for (cases) |case| {
        var diag: api.BuildDiagnostic = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(error.RuntimeError, api.buildModel(testing.allocator, testing.io, case.src, .{ .format = .step, .diagnostic = &diag }));
        try testing.expectEqualStrings(case.message, diag.message.?);
    }
}

test "API: a STEP build builds the modules the script imports on the B-Rep engine too" {
    var files = @import("vfs/memory.zig").MemoryVfs.init(testing.allocator);
    defer files.deinit();
    try files.vfs().writeFile("lib.kup", "part = cube(2)\nexport part\n");
    const step = try api.buildModel(testing.allocator, testing.io, "import { part } from \"./lib.kup\"\npart\n", .{ .format = .step, .vfs = files.vfs() });
    defer testing.allocator.free(step);
    try testing.expect(std.mem.startsWith(u8, step, "ISO-10303-21;"));
}

test "API: an STL of several parts is their union; glTF keeps them apart" {
    const source = "[cube(10), cube(10).translate(5, 0, 0)]";
    const stl = try api.buildModel(testing.allocator, testing.io, source, .{ .format = .stl });
    defer testing.allocator.free(stl);
    // One closed 15 x 10 x 10 box: the overlap is gone, so fewer than 2 x 12 triangles.
    try testing.expect(std.mem.readInt(u32, stl[80..84], .little) < 24);
    const glb = try api.buildModel(testing.allocator, testing.io, source, .{ .format = .glb });
    defer testing.allocator.free(glb);
    try testing.expectEqualStrings("glTF", glb[0..4]);
}

/// fixKeepsModel with `original` built from `before`.
fn keepsModel(before: []const u8, after: []const u8) !bool {
    return api.fixKeepsModel(testing.allocator, testing.io, try api.modelFingerprintForTest(testing.allocator, testing.io, before), after);
}

test "API: a lint fix is kept only when it builds the same model" {
    // fixCode guarded fixes by the error count alone, so a fix that changed the part
    // (dropped a ghost, a material, an engine setting, a size) was written back.
    try testing.expect(try keepsModel("x = 1\ncube(10)\n", "_x = 1\ncube(10)\n"));
    try testing.expect(try keepsModel("a = cube(10)\nb = a.translate(1, 0, 0)\nb\n", "_a = cube(10)\nb = _a.translate(1, 0, 0)\nb\n"));
    try testing.expect(try keepsModel("p = cube(1)\nassemble(name: \"Arm\", parts: [p])\n", "_p = cube(1)\nassemble(name: \"Arm\", parts: [_p])\n"));
    const changed = [_][2][]const u8{
        .{ "cube(10)\n", "cube(11)\n" },
        .{ "cube(10).material(color: \"#ff0000\")\n", "cube(10).material(color: \"#00ff00\")\n" },
        .{ "g = cube(5).ghost\ncube(10)\n", "cube(10)\n" },
        .{ "CAD.config(engine: :brep)\ncube(10)\n", "cube(10)\n" },
        .{ "[cube(1), cube(2)]\n", "[cube(1)]\n" },
        // An assembly by its name, which its export writes, and its parts
        .{ "assemble(name: \"Arm\", parts: [cube(1)])\n", "assemble(name: \"Leg\", parts: [cube(1)])\n" },
        .{ "assemble(name: \"Arm\", parts: [cube(1)])\n", "assemble(name: \"Arm\", parts: [cube(2)])\n" },
        .{ "cube(10)\n", "cube(\n" }, // no longer parses
        .{ "cube(10)\n", "cube(10).undefined_thing\n" }, // fails where the original ran
    };
    for (changed) |c| {
        errdefer std.debug.print("{s}  ->  {s}\n", .{ c[0], c[1] });
        try testing.expect(!try keepsModel(c[0], c[1]));
    }
    // Nothing to compare when the original itself fails: the error count still guards.
    try testing.expect(try keepsModel("cube(10).undefined_thing\n", "cube(11)\n"));
}

test "API: buildModel reads and writes no files unless the caller gives it a file system" {
    // Given none, it ran on the disk at the working directory, where build.zig is: a
    // script given to the API could read and write there
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "import_stl(\"build.zig\")", .message = "ImportError: could not read STL file 'build.zig': FileNotFound" },
        .{ .source = "import_json(\"build.zig.zon\")", .message = "ImportError: could not read JSON file 'build.zig.zon': FileNotFound" },
        .{ .source = "cube(1).export_stl(\"api_no_files.stl\")", .message = "RuntimeError: export_stl: could not write 'api_no_files.stl': AccessDenied" },
    };
    for (cases) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        var diag: api.BuildDiagnostic = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(error.RuntimeError, api.buildModel(testing.allocator, testing.io, case.source, .{ .format = .stl, .diagnostic = &diag }));
        try testing.expectEqualStrings(case.message, diag.message.?);
    }
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, "api_no_files.stl", .{}));
}

test "API: telling a model runs it with every write discarded" {
    const probe = "fingerprint_probe.stl";
    _ = try api.modelFingerprintForTest(testing.allocator, testing.io, "cube(1).export_stl(\"" ++ probe ++ "\")\n");
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, probe, .{}));
}

test "API: fixCode fixes every finding over as many passes as it takes, and then nothing" {
    const source = "a = 1\nb = 2\nc = cube(3)\ncube(10)\n";
    const first = try api.fixCode(testing.allocator, testing.io, source, .{});
    defer testing.allocator.free(first.source);
    try testing.expect(!first.refused);
    try testing.expectEqual(@as(usize, 3), first.fixes);
    try testing.expectEqualStrings("_a = 1\n_b = 2\n_c = cube(3)\ncube(10)\n", first.source);
    const again = try api.fixCode(testing.allocator, testing.io, first.source, .{});
    defer testing.allocator.free(again.source);
    try testing.expectEqual(@as(usize, 0), again.fixes);
    try testing.expectEqualStrings(first.source, again.source);
}
