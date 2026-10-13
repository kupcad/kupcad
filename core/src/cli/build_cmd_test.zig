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
    input: []u8,
    output: []u8,

    fn init(source: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "model.kup", .data = source });
        const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(dir);
        const input = try std.fs.path.join(testing.allocator, &.{ dir, "model.kup" });
        errdefer testing.allocator.free(input);
        const output = try std.fs.path.join(testing.allocator, &.{ dir, "model.stl" });
        return .{ .tmp = tmp, .input = input, .output = output };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.input);
        testing.allocator.free(self.output);
        self.tmp.cleanup();
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
        .{ .args = &.{"-o"}, .message = "Error: Missing input file path.\n" },
        .{ .args = &.{ "model.kup", "--param" }, .message = "Error: Missing key=value after --param\n" },
        .{ .args = &.{ "model.kup", "-p", "width" }, .message = "Error: Invalid param format. Use --param key=value.\n" },
        .{ .args = &.{ "model.kup", "-p", "width=wide" }, .message = "Error: Param value must be numeric. Got 'wide'\n" },
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
