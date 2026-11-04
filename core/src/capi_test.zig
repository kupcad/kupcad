//! libkupcad as a host calls it: through include/kupcad.h, translated (build.zig), whose
//! declarations link to capi.zig's exports in this binary. So these tests hold the header to
//! the exports as well as the exports to what the header promises.

const std = @import("std");
const testing = std.testing;
const c = @import("kupcad_h");
const capi = @import("capi.zig");
const packed_files = @import("vfs/packed.zig");

/// A result, freed when the test is done with it.
const Result = struct {
    ptr: *c.kupcad_result,

    fn of(ptr: ?*c.kupcad_result) Result {
        return .{ .ptr = ptr orelse @panic("a call returned NULL") };
    }

    fn deinit(self: Result) void {
        c.kupcad_result_free(self.ptr);
    }

    fn status(self: Result) c_int {
        return @intCast(c.kupcad_result_status(self.ptr));
    }

    fn data(self: Result) []const u8 {
        var len: usize = 0;
        const ptr = c.kupcad_result_data(self.ptr, &len);
        return ptr[0..len];
    }

    fn message(self: Result) ?[]const u8 {
        const ptr = c.kupcad_result_message(self.ptr) orelse return null;
        return std.mem.span(ptr);
    }

    fn report(self: Result) ?[]const u8 {
        const ptr = c.kupcad_result_report(self.ptr) orelse return null;
        return std.mem.span(ptr);
    }
};

const Report = struct {
    output: []const u8,
    outputCut: bool,
    warnings: []const struct { message: []const u8, line: ?u32, column: ?u32, file: ?[]const u8 },
};

test {
    // The exports the header's declarations link to
    testing.refAllDecls(capi);
}

fn build(source: []const u8, format: [:0]const u8, params: []const u8, files: []const u8, memory_limit: u64) Result {
    return .of(c.kupcad_build(source.ptr, source.len, format.ptr, params.ptr, params.len, files.ptr, files.len, memory_limit, false));
}

test "C API: the ABI version is the header's" {
    try testing.expectEqual(@as(u32, c.KUPCAD_ABI_VERSION), c.kupcad_abi_version());
    try testing.expectEqual(capi.ABI_VERSION, c.kupcad_abi_version());
}

test "C API: kupcad_version says what kupcad version --json says" {
    const result: Result = .of(c.kupcad_version());
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    const Info = struct { version: []const u8, protocolVersion: u32, os: []const u8, arch: []const u8 };
    const info = try std.json.parseFromSlice(Info, testing.allocator, result.data(), .{});
    defer info.deinit();
    try testing.expectEqualStrings(@import("build_info").version, info.value.version);
    try testing.expectEqual(null, result.message());
    try testing.expectEqual(null, result.report());
}

test "C API: a build gives the model's bytes and its report" {
    const result = build("cube(10)", "stl", "", "", 0);
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    // A binary STL: an 80-byte header, the triangle count, 50 bytes a triangle
    try testing.expect(result.data().len > 84);
    try testing.expectEqual(null, result.message());
    const report = try std.json.parseFromSlice(Report, testing.allocator, result.report().?, .{});
    defer report.deinit();
    try testing.expectEqualStrings("", report.value.output);
    try testing.expectEqual(0, report.value.warnings.len);
}

test "C API: a build takes parameter values as JSON, and keeps what the script prints" {
    const source =
        \\width = param(:width, default: 5)
        \\puts width
        \\cube(width)
    ;
    const result = build(source, "glb", "{\"width\": 20}", "", 0);
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    const report = try std.json.parseFromSlice(Report, testing.allocator, result.report().?, .{});
    defer report.deinit();
    try testing.expectEqualStrings("20\n", report.value.output);
}

test "C API: a build's warnings come in its report, where the script warned" {
    const result = build("warn(\"thin wall\")\ncube(1)", "stl", "", "", 0);
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    const report = try std.json.parseFromSlice(Report, testing.allocator, result.report().?, .{});
    defer report.deinit();
    try testing.expectEqual(1, report.value.warnings.len);
    try testing.expectEqualStrings("thin wall", report.value.warnings[0].message);
    try testing.expectEqual(@as(?u32, 1), report.value.warnings[0].line);
    try testing.expectEqualStrings("[Warning] thin wall\n", report.value.output);
}

test "C API: a script that fails is a script error, its message where and why, its report kept" {
    {
        const result = build("x = 1\ny = )\ncube(x)", "stl", "", "", 0);
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
        try testing.expectEqualStrings("2:5: Invalid expression starting with ')' [invalid-expression]", result.message().?);
        try testing.expectEqual(0, result.data().len);
        try testing.expect(result.report() != null);
    }
    {
        const result = build("puts \"before\"\nraise \"Plate too thin\"", "stl", "", "", 0);
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
        try testing.expectEqualStrings("RuntimeError: Plate too thin", result.message().?);
        const report = try std.json.parseFromSlice(Report, testing.allocator, result.report().?, .{});
        defer report.deinit();
        try testing.expectEqualStrings("before\n", report.value.output);
    }
    {
        const result = build("x = 1", "stl", "", "", 0);
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
        try testing.expect(std.mem.startsWith(u8, result.message().?, "TypeError: the script's last value (Number) is not a model"));
    }
}

test "C API: a build's arguments refused before it runs: the format, the parameters, the files" {
    {
        const result = build("cube(1)", "stp", "", "", 0);
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_INVALID_ARGUMENT), result.status());
        try testing.expectEqualStrings("'stp' isn't a format: one of stl, glb, gltf, step, 3mf, obj, svg, dxf", result.message().?);
        try testing.expectEqual(null, result.report());
    }
    {
        const result = build("cube(1)", "stl", "{width: 1}", "", 0);
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_INVALID_ARGUMENT), result.status());
        try testing.expect(std.mem.startsWith(u8, result.message().?, "parameters: "));
    }
    {
        const result = build("cube(1)", "stl", "", "\x09\x00\x00\x00lib", 0);
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_INVALID_ARGUMENT), result.status());
    }
}

test "C API: a build imports the files given with it" {
    const files = try packed_files.pack(testing.allocator, &.{
        .{ .path = "lib/sizes.kup", .content = "def side = 12\nexport side" },
    });
    defer testing.allocator.free(files);
    const result = build("import { side } from \"./lib/sizes.kup\"\nputs side\ncube(side)", "stl", "", files, 0);
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    const report = try std.json.parseFromSlice(Report, testing.allocator, result.report().?, .{});
    defer report.deinit();
    try testing.expectEqualStrings("12\n", report.value.output);
}

test "C API: a build's memory limit stops a script that holds more" {
    const result = build("a = (1..2_000_000).to_a\ncube(1)", "stl", "", "", 1_000_000);
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
    try testing.expect(std.mem.startsWith(u8, result.message().?, "OutOfMemoryError: "));
}

test "C API: kupcad_format formats, and says a syntax error where it is" {
    {
        const result: Result = .of(c.kupcad_format("cube( 1 )".ptr, 9));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
        try testing.expectEqualStrings("cube(1)\n", result.data());
    }
    {
        const source = "x = )";
        const result: Result = .of(c.kupcad_format(source.ptr, source.len));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
        try testing.expect(std.mem.startsWith(u8, result.message().?, "1:5: "));
    }
}

test "C API: kupcad_check gives the findings as JSON, and NULL is no source" {
    {
        const source = "x = 1\ncube(1)";
        const result: Result = .of(c.kupcad_check(source.ptr, source.len));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
        const Finding = struct { line: u32, rule: ?[]const u8, severity: []const u8 };
        const findings = try std.json.parseFromSlice([]const Finding, testing.allocator, result.data(), .{ .ignore_unknown_fields = true });
        defer findings.deinit();
        try testing.expectEqual(1, findings.value.len);
        try testing.expectEqualStrings("unused-variable", findings.value[0].rule.?);
    }
    {
        const result: Result = .of(c.kupcad_check(null, 0));
        defer result.deinit();
        try testing.expectEqualStrings("[]", result.data());
    }
}

test "C API: kupcad_params gives the schema kupcad doc prints" {
    const source = "# @title Plate\nwidth = param(:width, default: 40, validate: { min: 10 })\ncube(width)";
    const result: Result = .of(c.kupcad_params(source.ptr, source.len));
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    try testing.expect(std.mem.find(u8, result.data(), "\"title\":\"Plate\"") != null);
    try testing.expect(std.mem.find(u8, result.data(), "\"name\":\"width\"") != null);
}

test "C API: freeing NULL does nothing" {
    c.kupcad_result_free(null);
}

test "C API: threads build at once, each its own script" {
    const THREADS = 8;
    const Worker = struct {
        fn run(index: usize, outcome: *?anyerror) void {
            check(index) catch |err| {
                outcome.* = err;
            };
        }

        fn check(index: usize) !void {
            var source_buf: [128]u8 = undefined;
            const source = try std.fmt.bufPrint(&source_buf, "side = {d}\nputs side\ncube(side).translate(x: side)", .{index + 1});
            const result = build(source, "stl", "", "", 0);
            defer result.deinit();
            if (result.status() != c.KUPCAD_OK) return error.BuildFailed;
            var expected_buf: [16]u8 = undefined;
            const expected = try std.fmt.bufPrint(&expected_buf, "{d}\\n", .{index + 1});
            if (std.mem.find(u8, result.report().?, expected) == null) return error.WrongOutput;
        }
    };
    var outcomes: [THREADS]?anyerror = @splat(null);
    var threads: [THREADS]std.Thread = undefined;
    for (&threads, &outcomes, 0..) |*thread, *outcome, i| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ i, outcome });
    for (threads) |thread| thread.join();
    for (outcomes) |outcome| try testing.expectEqual(null, outcome);
}
