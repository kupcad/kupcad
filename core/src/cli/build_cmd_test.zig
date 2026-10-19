const std = @import("std");
const testing = std.testing;
const build_cmd = @import("build_cmd.zig");

const Args = @import("args.zig").Args;

const STL_HEADER_LEN = 80;
const STL_COUNT_LEN = 4;
const STL_TRIANGLE_LEN = 50;
const GLB_MAGIC = "glTF";
const STEP_MAGIC = "ISO-10303-21";

const UNKNOWN_EXTENSION_HINT = "Use an extension (.stl, .glb, .gltf, .step, .stp) or pass --format.\n";

const Result = struct {
    outcome: build_cmd.Outcome,
    output: std.Io.Writer.Allocating,

    fn deinit(self: *Result) void {
        self.output.deinit();
    }

    fn text(self: *Result) []const u8 {
        return self.output.written();
    }
};

fn runBuild(args: []const []const u8) !Result {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    var it: Args = .{ .items = args };
    const outcome = try build_cmd.run(testing.allocator, &it, .{ .io = testing.io, .capture = &output.writer });
    return .{ .outcome = outcome, .output = output };
}

/// Temp dir holding `model.kup` with `source`; paths are absolute so cwd does not matter.
const Fixture = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,
    input: []u8,
    output: []u8,

    fn init(source: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "model.kup", .data = source });
        const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(dir);
        const input = try std.fs.path.join(testing.allocator, &.{ dir, "model.kup" });
        errdefer testing.allocator.free(input);
        const output = try std.fs.path.join(testing.allocator, &.{ dir, "model.stl" });
        return .{ .tmp = tmp, .dir = dir, .input = input, .output = output };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.dir);
        testing.allocator.free(self.input);
        testing.allocator.free(self.output);
        self.tmp.cleanup();
    }

    /// Absolute path of `name` inside the fixture dir; caller frees.
    fn path(self: *Fixture, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.dir, name });
    }

    fn entryCount(self: *Fixture) !usize {
        var it = self.tmp.dir.iterate();
        var entries: usize = 0;
        while (try it.next(testing.io)) |_| entries += 1;
        return entries;
    }

    fn build(self: *Fixture) !Result {
        return runBuild(&.{ self.input, "-f", "stl", "-o", self.output });
    }

    fn outputExists(self: *Fixture) bool {
        self.tmp.dir.access(testing.io, "model.stl", .{}) catch return false;
        return true;
    }
};

test "build_cmd: invalid arguments fail before touching the filesystem" {
    const cases = [_]struct { args: []const []const u8, message: []const u8 }{
        .{ .args = &.{}, .message = "Error: Missing input file path.\n\n" ++ build_cmd.USAGE },
        .{ .args = &.{"-o"}, .message = "Error: Missing output path after -o\n" },
        .{ .args = &.{ "model.kup", "--param" }, .message = "Error: Missing key=value after --param\n" },
        .{ .args = &.{ "model.kup", "-p", "width" }, .message = "Error: Invalid param format. Use --param key=value.\n" },
        // `=5` used to be skipped silently. (A value that isn't the parameter's type is
        // refused by param(), which knows the type: see the -p test below.)
        .{ .args = &.{ "model.kup", "-p", "=5" }, .message = "Error: Param '=5' has no name. Use --param key=value.\n" },
        .{ .args = &.{ "model.kup", "-P" }, .message = "Error: Missing parameter file after -P\n" },
        .{ .args = &.{ "model.kup", "--bom" }, .message = "Error: Missing parts list path after --bom\n" },
        .{ .args = &.{ "model.kup", "-f" }, .message = "Error: Missing format after -f\n" },
        .{ .args = &.{ "model.kup", "--format", "obj" }, .message = "Error: Unsupported format 'obj'. Allowed: stl, glb, gltf, step\n" },
    };
    for (cases) |case| {
        var res = try runBuild(case.args);
        defer res.deinit();
        try testing.expectEqual(build_cmd.Outcome.failure, res.outcome);
        try testing.expectEqualStrings(case.message, res.text());
    }
}

test "build_cmd: nonexistent input file fails" {
    var res = try runBuild(&.{"/nonexistent/kupcad/build_cmd_test/model.kup"});
    defer res.deinit();
    try testing.expectEqual(build_cmd.Outcome.failure, res.outcome);
    try testing.expect(std.mem.startsWith(u8, res.text(), "Failed to initialize session: "));
}

test "build_cmd: script failures and empty exports return failure without writing output" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "x = undefined_var + 10\n", .message = "Build failed: " },
        .{ .source = "x = 1\n", .message = "Export failed: error.NoGeometry\n" },
    };
    for (cases) |case| {
        var fx = try Fixture.init(case.source);
        defer fx.deinit();
        var res = try fx.build();
        defer res.deinit();
        try testing.expectEqual(build_cmd.Outcome.failure, res.outcome);
        try testing.expect(std.mem.startsWith(u8, res.text(), case.message));
        try testing.expect(!fx.outputExists());
    }
}

test "build_cmd: valid script succeeds and writes the export" {
    var fx = try Fixture.init("cube(10)\n");
    defer fx.deinit();
    var res = try fx.build();
    defer res.deinit();
    try testing.expectEqual(build_cmd.Outcome.success, res.outcome);
    try testing.expect(std.mem.startsWith(u8, res.text(), "Successfully built "));
    try testing.expect(fx.outputExists());
}

test "build_cmd: --bom writes the model's parts list beside the export" {
    var fx = try Fixture.init(
        \\bolt = cylinder(r: 1, h: 10).named("bolt").material(density: 8)
        \\assemble(name: "pair", parts: [bolt, bolt.translate(5, 0, 0), cube(2)])
        \\
    );
    defer fx.deinit();
    const bom_path = try std.fs.path.join(testing.allocator, &.{ fx.dir, "bom.json" });
    defer testing.allocator.free(bom_path);
    var res = try runBuild(&.{ fx.input, "-o", fx.output, "--bom", bom_path });
    defer res.deinit();
    try testing.expectEqual(build_cmd.Outcome.success, res.outcome);
    try testing.expect(fx.outputExists());

    const text = try fx.tmp.dir.readFileAlloc(testing.io, "bom.json", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(text);
    const Row = struct { name: ?[]const u8, count: u32, volume: f64, size: [3]f64, density: ?f64, mass: ?f64 };
    const parsed = try std.json.parseFromSlice(struct { parts: []const Row }, testing.allocator, text, .{});
    defer parsed.deinit();
    const parts = parsed.value.parts;
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expectEqualStrings("bolt", parts[0].name.?);
    try testing.expectEqual(@as(u32, 2), parts[0].count);
    try testing.expectApproxEqAbs(parts[0].volume * 8 / 1000, parts[0].mass.?, 1e-12);
    try testing.expect(parts[1].name == null and parts[1].mass == null);
    try testing.expectEqual([3]f64{ 2, 2, 2 }, parts[1].size);
}

test "build_cmd: --param sets the script's param" {
    // The script fails unless `w` arrives as 20, so success shows the value reached it.
    var fx = try Fixture.init("w = param(:w, default: 1)\nraise \"w is #{w}\" unless w == 20\ncube(w)\n");
    defer fx.deinit();
    var res = try runBuild(&.{ fx.input, "-p", "w=20", "-o", fx.output });
    defer res.deinit();
    try testing.expectEqual(build_cmd.Outcome.success, res.outcome);

    var default = try fx.build();
    defer default.deinit();
    try testing.expectEqual(build_cmd.Outcome.failure, default.outcome);
}

test "build_cmd: -p text is read as the parameter's type, and refused when it isn't one" {
    // -p took numbers only, so a String, boolean or Symbol parameter couldn't be set.
    var fx = try Fixture.init(
        \\w = param(:w, default: 1)
        \\label = param(:label, default: "x")
        \\hollow = param(:hollow, default: false)
        \\size = param(:size, default: :m3, validate: { in: [:m3, :m4] })
        \\raise "#{w} #{label} #{hollow} #{size}" unless w == 2.5 && label == "Gear A" && hollow && size == :m4
        \\cube(w)
        \\
    );
    defer fx.deinit();
    var res = try runBuild(&.{ fx.input, "-p", "w=2.5", "-p", "label=Gear A", "-p", "hollow=true", "-p", "size=m4", "-o", fx.output });
    defer res.deinit();
    try testing.expectEqual(build_cmd.Outcome.success, res.outcome);

    // `w=1=2` is the text "1=2" for w, which no number is: the run stops at param()
    // (its TypeError, naming the text, is params_test.zig's).
    for ([_][]const u8{ "w=wide", "w=1=2", "w=", "w=inf" }) |pair| {
        errdefer std.debug.print("-p {s}\n", .{pair});
        var bad = try runBuild(&.{ fx.input, "-p", pair, "-o", fx.output });
        defer bad.deinit();
        try testing.expectEqual(build_cmd.Outcome.failure, bad.outcome);
        try testing.expect(std.mem.startsWith(u8, bad.text(), "Build failed: "));
    }
}

test "build_cmd: -P reads a JSON object of values, and of two for one parameter the later wins" {
    // The script fails unless `w` is `expected`, which each case sets on the command line.
    var fx = try Fixture.init("w = param(:w, default: 1)\nexpected = param(:expected, default: 0)\nlabel = param(:label, default: \"x\")\nraise \"#{w} #{label}\" unless w == expected && label == \"from file\"\ncube(w)\n");
    defer fx.deinit();
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "params.json", .data = "{\"w\": 3, \"label\": \"from file\"}" });
    const file = try fx.path("params.json");
    defer testing.allocator.free(file);
    const cases = [_][]const []const u8{
        &.{ "-p", "expected=3", "-P", file },
        &.{ "-p", "expected=5", "-P", file, "-p", "w=5" },
        &.{ "-p", "expected=3", "-p", "w=5", "--params", file },
    };
    for (cases) |case| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(testing.allocator);
        try args.appendSlice(testing.allocator, &.{ fx.input, "-o", fx.output });
        try args.appendSlice(testing.allocator, case);
        var res = try runBuild(args.items);
        defer res.deinit();
        errdefer std.debug.print("{s}\n", .{res.text()});
        try testing.expectEqual(build_cmd.Outcome.success, res.outcome);
    }
}

test "build_cmd: -P refuses a file it can't read, and one that isn't parameter values" {
    var fx = try Fixture.init("cube(1)\n");
    defer fx.deinit();
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "list.json", .data = "{\"gears\": [20, 30]}" });
    const list = try fx.path("list.json");
    defer testing.allocator.free(list);
    const missing = try fx.path("missing.json");
    defer testing.allocator.free(missing);
    const cases = [_]struct { file: []const u8, message: []const u8 }{
        .{ .file = list, .message = ": parameter 'gears' is an array; a parameter takes a number, a string, true or false\n" },
        .{ .file = missing, .message = "': FileNotFound\n" },
    };
    for (cases) |case| {
        var res = try runBuild(&.{ fx.input, "-P", case.file, "-o", fx.output });
        defer res.deinit();
        errdefer std.debug.print("{s}\n", .{res.text()});
        try testing.expectEqual(build_cmd.Outcome.failure, res.outcome);
        try testing.expect(std.mem.startsWith(u8, res.text(), "Error: "));
        try testing.expect(std.mem.endsWith(u8, res.text(), case.message));
        try testing.expect(std.mem.find(u8, res.text(), case.file) != null);
        try testing.expect(!fx.outputExists());
    }
}

/// What an exporter actually wrote, judged by content rather than by file name.
const FileKind = enum { stl, glb, gltf, step };

fn detectFileKind(bytes: []const u8) ?FileKind {
    if (std.mem.startsWith(u8, bytes, GLB_MAGIC)) return .glb;
    if (std.mem.startsWith(u8, bytes, "{\"asset\":")) return .gltf;
    if (std.mem.startsWith(u8, bytes, STEP_MAGIC)) return .step;
    // Binary STL: 80-byte header, u32 triangle count, then fixed-size triangle records.
    if (bytes.len >= STL_HEADER_LEN + STL_COUNT_LEN) {
        const count = std.mem.readInt(u32, bytes[STL_HEADER_LEN..][0..STL_COUNT_LEN], .little);
        if (bytes.len == STL_HEADER_LEN + STL_COUNT_LEN + @as(usize, count) * STL_TRIANGLE_LEN) return .stl;
    }
    return null;
}

test "build_cmd: detectFileKind recognises each export by content" {
    var stl_bytes: [STL_HEADER_LEN + STL_COUNT_LEN + STL_TRIANGLE_LEN]u8 = @splat(0);
    std.mem.writeInt(u32, stl_bytes[STL_HEADER_LEN..][0..STL_COUNT_LEN], 1, .little);
    try testing.expectEqual(@as(?FileKind, .stl), detectFileKind(&stl_bytes));
    try testing.expectEqual(@as(?FileKind, .glb), detectFileKind(GLB_MAGIC ++ "\x02\x00\x00\x00"));
    try testing.expectEqual(@as(?FileKind, .step), detectFileKind(STEP_MAGIC ++ ";\nHEADER;"));
    try testing.expectEqual(@as(?FileKind, .gltf), detectFileKind("{\"asset\":{\"version\":\"2.0\"}}"));
    try testing.expectEqual(@as(?FileKind, null), detectFileKind(stl_bytes[0 .. stl_bytes.len - 1]));
}

const FormatCase = struct {
    /// `-o` file name inside the fixture dir; null omits `-o`.
    output: ?[]const u8,
    /// `-f` value; null omits `-f`.
    format: ?[]const u8 = null,
    draco: bool = false,
    expect: union(enum) {
        /// File name expected in the fixture dir and the format of its bytes.
        written: struct { name: []const u8, kind: FileKind },
        /// Trailing part of the error message (absolute paths precede it).
        rejected: []const u8,
    },
};

test "build_cmd: output format follows the -o extension and must agree with --format" {
    const cases = [_]FormatCase{
        // Extension alone decides, case-insensitively.
        .{ .output = "part.stl", .expect = .{ .written = .{ .name = "part.stl", .kind = .stl } } },
        .{ .output = "PART.STL", .expect = .{ .written = .{ .name = "PART.STL", .kind = .stl } } },
        .{ .output = "part.glb", .expect = .{ .written = .{ .name = "part.glb", .kind = .glb } } },
        .{ .output = "part.gltf", .expect = .{ .written = .{ .name = "part.gltf", .kind = .gltf } } },
        .{ .output = "part.step", .expect = .{ .written = .{ .name = "part.step", .kind = .step } } },
        .{ .output = "part.stp", .expect = .{ .written = .{ .name = "part.stp", .kind = .step } } },
        // An agreeing --format is accepted.
        .{ .output = "part.stl", .format = "stl", .expect = .{ .written = .{ .name = "part.stl", .kind = .stl } } },
        .{ .output = "part.Stp", .format = "step", .expect = .{ .written = .{ .name = "part.Stp", .kind = .step } } },
        // A disagreeing --format is refused rather than writing a mislabeled file.
        .{ .output = "part.glb", .format = "stl", .expect = .{ .rejected = "Error: --format stl conflicts with output extension .glb\n" } },
        .{ .output = "part.STL", .format = "glb", .expect = .{ .rejected = "Error: --format glb conflicts with output extension .STL\n" } },
        .{ .output = "part.stp", .format = "gltf", .expect = .{ .rejected = "Error: --format gltf conflicts with output extension .stp\n" } },
        // Unrecognized or missing extensions need an explicit --format.
        .{ .output = "part.obj", .expect = .{ .rejected = UNKNOWN_EXTENSION_HINT } },
        .{ .output = "part", .expect = .{ .rejected = UNKNOWN_EXTENSION_HINT } },
        .{ .output = "part.bin", .format = "stl", .expect = .{ .written = .{ .name = "part.bin", .kind = .stl } } },
        // Without -o the name is derived from the input stem and the format.
        .{ .output = null, .expect = .{ .written = .{ .name = "model.glb", .kind = .glb } } },
        .{ .output = null, .format = "stl", .expect = .{ .written = .{ .name = "model.stl", .kind = .stl } } },
        .{ .output = null, .format = "step", .expect = .{ .written = .{ .name = "model.step", .kind = .step } } },
        // Draco compression exists only for glTF output.
        .{ .output = "part.glb", .draco = true, .expect = .{ .written = .{ .name = "part.glb", .kind = .glb } } },
        .{ .output = "part.stl", .draco = true, .expect = .{ .rejected = "Error: --draco only applies to glb and gltf output, not stl\n" } },
        .{ .output = null, .format = "step", .draco = true, .expect = .{ .rejected = "Error: --draco only applies to glb and gltf output, not step\n" } },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: -o {?s} -f {?s} draco={}\n", .{ case.output, case.format, case.draco });

        var fx = try Fixture.init("cube(10)\n");
        defer fx.deinit();

        const output_path = if (case.output) |name| try fx.path(name) else null;
        defer if (output_path) |p| testing.allocator.free(p);

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(testing.allocator);
        try args.append(testing.allocator, fx.input);
        if (output_path) |p| try args.appendSlice(testing.allocator, &.{ "-o", p });
        if (case.format) |f| try args.appendSlice(testing.allocator, &.{ "-f", f });
        if (case.draco) try args.append(testing.allocator, "--draco");

        var res = try runBuild(args.items);
        defer res.deinit();

        switch (case.expect) {
            .written => |want| {
                try testing.expectEqual(build_cmd.Outcome.success, res.outcome);
                const bytes = try fx.tmp.dir.readFileAlloc(testing.io, want.name, testing.allocator, .unlimited);
                defer testing.allocator.free(bytes);
                try testing.expectEqual(@as(?FileKind, want.kind), detectFileKind(bytes));
                try testing.expectEqual(@as(usize, 2), try fx.entryCount()); // model.kup + the export
            },
            .rejected => |message| {
                try testing.expectEqual(build_cmd.Outcome.failure, res.outcome);
                try testing.expectStringEndsWith(res.text(), message);
                try testing.expectEqual(@as(usize, 1), try fx.entryCount()); // only model.kup
            },
        }
    }
}

test "build_cmd: syntax errors are reported with file, line, column and a caret" {
    // `kupcad build` used to print only "Build failed: error.ParseError".
    var fx = try Fixture.init("w = 10\ncube(w\nsphere(2)\nx = )\n");
    defer fx.deinit();
    var res = try fx.build();
    defer res.deinit();
    try testing.expectEqual(build_cmd.Outcome.failure, res.outcome);
    try testing.expect(!fx.outputExists());

    const text = res.text();
    const first = try testing.allocator.print("{s}:3:1:", .{fx.input});
    defer testing.allocator.free(first);
    const second = try testing.allocator.print("{s}:4:5:", .{fx.input});
    defer testing.allocator.free(second);
    for ([_][]const u8{ first, "Expected 'r_paren', but found 'sphere' [unexpected-token]\nsphere(2)\n", second, "Invalid expression starting with ')' [invalid-expression]\nx = )\n    ", "^" }) |needle| {
        errdefer std.debug.print("missing {s} in:\n{s}\n", .{ needle, text });
        try testing.expect(std.mem.find(u8, text, needle) != null);
    }
    const summary = try testing.allocator.print("Build failed: 2 errors in {s}\n", .{fx.input});
    defer testing.allocator.free(summary);
    try testing.expect(std.mem.endsWith(u8, text, summary));
}

test "build_cmd: resolver errors are reported like syntax errors" {
    // A `break` in a lambda used to fail with "Build failed: 0 syntax errors" and no message.
    var fx = try Fixture.init("f = ->(x) { break x }\ncube(1)\n");
    defer fx.deinit();
    var res = try fx.build();
    defer res.deinit();
    try testing.expectEqual(build_cmd.Outcome.failure, res.outcome);

    const text = res.text();
    const location = try testing.allocator.print("{s}:1:13:", .{fx.input});
    defer testing.allocator.free(location);
    const summary = try testing.allocator.print("Build failed: 1 error in {s}\n", .{fx.input});
    defer testing.allocator.free(summary);
    for ([_][]const u8{ location, "Cannot use 'break' outside of a loop [outside-loop]\nf = ->(x) { break x }\n", summary }) |needle| {
        errdefer std.debug.print("missing {s} in:\n{s}\n", .{ needle, text });
        try testing.expect(std.mem.find(u8, text, needle) != null);
    }
}

test "build_cmd: compile errors are reported like syntax errors" {
    // `cube = 5` used to print only "Build failed: error.ProtectedSymbol".
    var fx = try Fixture.init("w = 10\ncube = 5\n");
    defer fx.deinit();
    var res = try fx.build();
    defer res.deinit();
    try testing.expectEqual(build_cmd.Outcome.failure, res.outcome);

    const text = res.text();
    const location = try testing.allocator.print("{s}:2:1:", .{fx.input});
    defer testing.allocator.free(location);
    for ([_][]const u8{ location, "'cube' is a built-in and can't be assigned [builtin-redefined]\ncube = 5\n", "Build failed: 1 error in" }) |needle| {
        errdefer std.debug.print("missing {s} in:\n{s}\n", .{ needle, text });
        try testing.expect(std.mem.find(u8, text, needle) != null);
    }
}

test "build_cmd: unknown options, a missing -o value and extra inputs are rejected" {
    // Each used to be ignored silently: a typo like `--fromat stl` built with defaults.
    const cases = [_]struct { args: []const []const u8, message: []const u8 }{
        .{ .args = &.{ "model.kup", "--fromat", "stl" }, .message = "Error: Unknown option '--fromat'\n\n" ++ build_cmd.USAGE },
        .{ .args = &.{ "model.kup", "-o" }, .message = "Error: Missing output path after -o\n" },
        .{ .args = &.{ "a.kup", "b.kup" }, .message = "Error: Expected one input file, got 'a.kup' and 'b.kup'\n" },
    };
    for (cases) |case| {
        var res = try runBuild(case.args);
        defer res.deinit();
        try testing.expectEqual(build_cmd.Outcome.failure, res.outcome);
        try testing.expectEqualStrings(case.message, res.text());
    }
}

test "build_cmd: the project's vm_memory_limit caps the script's heap" {
    // `.kupcad.json` had the setting, but no command applied it.
    var fx = try Fixture.init("a = []\n2000.times { |i| a.push(\"item number #{i}\") }\ncube(1)\n");
    defer fx.deinit();
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = ".kupcad.json", .data = "{ \"vm_memory_limit\": 65536 }" });
    var result = try runBuild(&.{ fx.input, "-o", fx.output });
    defer result.deinit();
    try testing.expectEqual(.failure, result.outcome);
    try testing.expect(std.mem.find(u8, result.text(), "Build failed") != null); // the VM reports the OutOfMemoryError itself
}
