const std = @import("std");
const testing = std.testing;
const build_cmd = @import("build_cmd.zig");

const SliceArgs = struct {
    args: []const []const u8,
    index: usize = 0,

    pub fn next(self: *SliceArgs) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }
};

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
    var it = SliceArgs{ .args = args };
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
        .{ .args = &.{}, .message = "Error: Missing input file path.\n" },
        .{ .args = &.{"-o"}, .message = "Error: Missing output path after -o\n" },
        .{ .args = &.{ "model.kup", "--param" }, .message = "Error: Missing key=value after --param\n" },
        .{ .args = &.{ "model.kup", "-p", "width" }, .message = "Error: Invalid param format. Use --param key=value.\n" },
        .{ .args = &.{ "model.kup", "-p", "width=wide" }, .message = "Error: Param value must be a finite number. Got 'wide'\n" },
        // `=5` used to be skipped silently, and `w=1=2` read as w=1.
        .{ .args = &.{ "model.kup", "-p", "=5" }, .message = "Error: Param '=5' has no name. Use --param key=value.\n" },
        .{ .args = &.{ "model.kup", "-p", "w=1=2" }, .message = "Error: Param value must be a finite number. Got '1=2'\n" },
        .{ .args = &.{ "model.kup", "-p", "w=" }, .message = "Error: Param value must be a finite number. Got ''\n" },
        .{ .args = &.{ "model.kup", "-p", "w=inf" }, .message = "Error: Param value must be a finite number. Got 'inf'\n" },
        .{ .args = &.{ "model.kup", "-p", "w=nan" }, .message = "Error: Param value must be a finite number. Got 'nan'\n" },
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

const STL_HEADER_LEN = 80;
const STL_COUNT_LEN = 4;
const STL_TRIANGLE_LEN = 50;
const GLB_MAGIC = "glTF";
const STEP_MAGIC = "ISO-10303-21";

/// What an exporter actually wrote, judged by content rather than by file name.
/// `-f gltf` also yields binary glTF, so there is no separate JSON kind.
const FileKind = enum { stl, glb, step };

fn detectFileKind(bytes: []const u8) ?FileKind {
    if (std.mem.startsWith(u8, bytes, GLB_MAGIC)) return .glb;
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

const UNKNOWN_EXTENSION_HINT = "Use an extension (.stl, .glb, .gltf, .step, .stp) or pass --format.\n";

test "build_cmd: output format follows the -o extension and must agree with --format" {
    const cases = [_]FormatCase{
        // Extension alone decides, case-insensitively.
        .{ .output = "part.stl", .expect = .{ .written = .{ .name = "part.stl", .kind = .stl } } },
        .{ .output = "PART.STL", .expect = .{ .written = .{ .name = "PART.STL", .kind = .stl } } },
        .{ .output = "part.glb", .expect = .{ .written = .{ .name = "part.glb", .kind = .glb } } },
        .{ .output = "part.gltf", .expect = .{ .written = .{ .name = "part.gltf", .kind = .glb } } },
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
    const first = try std.fmt.allocPrint(testing.allocator, "{s}:3:1:", .{fx.input});
    defer testing.allocator.free(first);
    const second = try std.fmt.allocPrint(testing.allocator, "{s}:4:5:", .{fx.input});
    defer testing.allocator.free(second);
    for ([_][]const u8{ first, "Expected 'r_paren', but found 'sphere'\nsphere(2)\n", second, "Invalid expression starting with ')'\nx = )\n    ", "^" }) |needle| {
        errdefer std.debug.print("missing {s} in:\n{s}\n", .{ needle, text });
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
    const summary = try std.fmt.allocPrint(testing.allocator, "Build failed: 2 errors in {s}\n", .{fx.input});
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
    const location = try std.fmt.allocPrint(testing.allocator, "{s}:1:13:", .{fx.input});
    defer testing.allocator.free(location);
    const summary = try std.fmt.allocPrint(testing.allocator, "Build failed: 1 error in {s}\n", .{fx.input});
    defer testing.allocator.free(summary);
    for ([_][]const u8{ location, "Cannot use 'break' outside of a loop\nf = ->(x) { break x }\n", summary }) |needle| {
        errdefer std.debug.print("missing {s} in:\n{s}\n", .{ needle, text });
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
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
    const location = try std.fmt.allocPrint(testing.allocator, "{s}:2:1:", .{fx.input});
    defer testing.allocator.free(location);
    for ([_][]const u8{ location, "'cube' is a built-in and can't be assigned\ncube = 5\n", "Build failed: 1 error in" }) |needle| {
        errdefer std.debug.print("missing {s} in:\n{s}\n", .{ needle, text });
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
}

test "build_cmd: unknown options, a missing -o value and extra inputs are rejected" {
    // Each used to be ignored silently: a typo like `--fromat stl` built with defaults.
    const cases = [_]struct { args: []const []const u8, message: []const u8 }{
        .{ .args = &.{ "model.kup", "--fromat", "stl" }, .message = "Error: Unknown option '--fromat'. Options: -o/--output, -f/--format, -p/--param, -d/--draco\n" },
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
