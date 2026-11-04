//! libkupcad as a host calls it: through include/kupcad.h, translated (build.zig), whose
//! declarations link to capi.zig's exports in this binary. The first test holds the header's
//! declarations to the exports' ABI, which linking alone doesn't (an `extern` and an `export`
//! of the same name link whatever their types); the others hold the exports to what the
//! header promises. capi.zig allocates with the test allocator here, so a call that leaks
//! fails its test.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const c = @import("kupcad_h");
const capi = @import("capi.zig");
const packed_files = @import("vfs/packed.zig");

/// A model heavy enough for Manifold's parallel algorithms, which start oneTBB's worker threads.
const HEAVY = "sphere(r: 50, segments: 512) - cube(60, center: true).translate(x: 30)";

comptime {
    // The exports the header's declarations link to, whichever tests a filter keeps
    testing.refAllDecls(capi);
}

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
        var len: usize = 0;
        const ptr = c.kupcad_result_message(self.ptr, &len) orelse return null;
        return ptr[0..len];
    }

    fn report(self: Result) ?[]const u8 {
        const ptr = c.kupcad_result_report(self.ptr) orelse return null;
        return std.mem.span(ptr);
    }

    /// The report, parsed; the caller deinits it.
    fn parsedReport(self: Result) !std.json.Parsed(Report) {
        return std.json.parseFromSlice(Report, testing.allocator, self.report().?, .{});
    }
};

const Report = struct {
    output: []const u8,
    outputCut: bool,
    warnings: []const struct { message: []const u8, line: ?u32, column: ?u32, file: ?[]const u8 },
};

/// How `build` builds: the parameter values (JSON), the files (packed) and the limits.
const Options = struct {
    params: []const u8 = "",
    files: []const u8 = "",
    memory_limit: u64 = 0,
    timeout_ms: u64 = 0,
    draco: bool = false,
};

fn build(source: []const u8, format: [:0]const u8, options: Options) Result {
    return .of(c.kupcad_build(source.ptr, source.len, format.ptr, options.params.ptr, options.params.len, options.files.ptr, options.files.len, options.memory_limit, options.timeout_ms, options.draco));
}

/// What a C type is to the ABI: a pointer of any kind (the header's C pointers, the exports'
/// many-item and optional ones alike), an integer (a C enum among them), a bool or nothing.
const Kind = enum { pointer, integer, boolean, nothing };

fn kindOf(comptime T: type) Kind {
    return switch (@typeInfo(T)) {
        .pointer => .pointer,
        .optional => |optional| kindOf(optional.child),
        .int, .@"enum" => .integer,
        .bool => .boolean,
        .void => .nothing,
        else => @compileError("not a type of kupcad.h: " ++ @typeName(T)),
    };
}

/// Whether the function types `A` and `B` pass and return the same, as the C ABI sees it.
fn sameAbi(comptime A: type, comptime B: type) bool {
    const a = @typeInfo(A).@"fn";
    const b = @typeInfo(B).@"fn";
    if (a.param_types.len != b.param_types.len) return false;
    for (a.param_types, b.param_types) |pa, pb| {
        if (kindOf(pa.?) != kindOf(pb.?) or @sizeOf(pa.?) != @sizeOf(pb.?)) return false;
    }
    const ra = a.return_type.?;
    const rb = b.return_type.?;
    return kindOf(ra) == kindOf(rb) and @sizeOf(ra) == @sizeOf(rb);
}

/// The names of the `kupcad_*` functions `container` declares.
fn functionsOf(comptime container: type) []const []const u8 {
    // The translated header holds all of stdint.h, stddef.h and stdbool.h too
    @setEvalBranchQuota(100_000);
    var names: []const []const u8 = &.{};
    for (std.meta.declarations(container)) |name| {
        if (std.mem.startsWith(u8, name, "kupcad_") and @typeInfo(@TypeOf(@field(container, name))) == .@"fn") {
            names = names ++ .{name};
        }
    }
    return names;
}

test "C API: kupcad.h declares each export, and nothing else, as it is" {
    comptime {
        for (functionsOf(c)) |name| {
            if (!@hasDecl(capi, name)) @compileError("kupcad.h declares " ++ name ++ ", which capi.zig doesn't export");
            if (!sameAbi(@TypeOf(@field(c, name)), @TypeOf(@field(capi, name)))) @compileError("kupcad.h declares " ++ name ++ " otherwise than capi.zig exports it");
        }
        for (functionsOf(capi)) |name| {
            if (!@hasDecl(c, name)) @compileError("capi.zig exports " ++ name ++ ", which kupcad.h doesn't declare");
        }
    }
}

test "C API: the ABI version is the header's" {
    try testing.expectEqual(@as(u32, c.KUPCAD_ABI_VERSION), c.kupcad_abi_version());
    try testing.expectEqual(capi.ABI_VERSION, c.kupcad_abi_version());
}

test "C API: kupcad_version says what kupcad version --json says, the formats a build takes among it" {
    const result: Result = .of(c.kupcad_version());
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    const Info = struct { version: []const u8, protocolVersion: u32, os: []const u8, arch: []const u8, formats: []const []const u8 };
    const info = try std.json.parseFromSlice(Info, testing.allocator, result.data(), .{});
    defer info.deinit();
    try testing.expectEqualStrings(@import("build_info").version, info.value.version);
    for (info.value.formats) |format| {
        const name = try testing.allocator.dupeSentinel(u8, format, 0);
        defer testing.allocator.free(name);
        const model = build("cube(1)", name, .{});
        defer model.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), model.status());
    }
    try testing.expectEqual(null, result.message());
    try testing.expectEqual(null, result.report());
}

test "C API: a build gives the model's bytes and its report" {
    const result = build("cube(10)", "stl", .{});
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    // A binary STL: an 80-byte header, the triangle count, 50 bytes a triangle
    try testing.expectEqual(@as(usize, 84 + 12 * 50), result.data().len);
    try testing.expectEqual(null, result.message());
    const report = try result.parsedReport();
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
    const result = build(source, "glb", .{ .params = "{\"width\": 20}" });
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    const report = try result.parsedReport();
    defer report.deinit();
    try testing.expectEqualStrings("20\n", report.value.output);
}

test "C API: a value a parameter refuses fails the script, saying which and why" {
    const source = "width = param(:width, default: 5, validate: { min: 1 })\ncube(width)";
    const result = build(source, "stl", .{ .params = "{\"width\": 0}" });
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
    try testing.expect(std.mem.startsWith(u8, result.message().?, "ValueError: "));
    try testing.expect(std.mem.find(u8, result.message().?, "width") != null);
}

test "C API: a build's report keeps a warning where the script warned, and in which file" {
    const files = try packed_files.pack(testing.allocator, &.{
        .{ .path = "lib/walls.kup", .content = "def wall\n  warn(\"thin wall\")\n  cube(1)\nend\nexport wall" },
    });
    defer testing.allocator.free(files);
    const result = build("import { wall } from \"./lib/walls.kup\"\nwarn(\"mine\")\nwall()", "stl", .{ .files = files });
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    const report = try result.parsedReport();
    defer report.deinit();
    const warnings = report.value.warnings;
    try testing.expectEqual(2, warnings.len);
    try testing.expectEqualStrings("mine", warnings[0].message);
    try testing.expectEqual(@as(?u32, 2), warnings[0].line);
    try testing.expectEqual(null, warnings[0].file);
    try testing.expectEqualStrings("thin wall", warnings[1].message);
    try testing.expectEqual(@as(?u32, 2), warnings[1].line);
    try testing.expectEqualStrings("lib/walls.kup", warnings[1].file.?);
    try testing.expectEqualStrings("[Warning] mine\n[Warning] thin wall\n", report.value.output);
}

test "C API: a build's report keeps the start of what a script prints past 64 KB, and says so" {
    const result = build("(1..10000).each { |i| puts \"line #{i}\" }\ncube(1)", "stl", .{});
    defer result.deinit();
    const report = try result.parsedReport();
    defer report.deinit();
    try testing.expect(report.value.outputCut);
    try testing.expect(report.value.output.len <= 64 * 1024);
    try testing.expect(std.mem.startsWith(u8, report.value.output, "line 1\nline 2\n"));
}

test "C API: a script that fails is a script error, its message where and why, its report kept" {
    {
        const result = build("x = 1\ny = )\ncube(x)", "stl", .{});
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
        try testing.expectEqualStrings("2:5: Invalid expression starting with ')' [invalid-expression]", result.message().?);
        try testing.expectEqual(0, result.data().len);
        try testing.expect(result.report() != null);
    }
    {
        const result = build("puts \"before\"\nraise \"Plate too thin\"", "stl", .{});
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
        try testing.expectEqualStrings("RuntimeError: Plate too thin", result.message().?);
        const report = try result.parsedReport();
        defer report.deinit();
        try testing.expectEqualStrings("before\n", report.value.output);
    }
    {
        const result = build("x = 1", "stl", .{});
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
        try testing.expect(std.mem.startsWith(u8, result.message().?, "TypeError: the script's last value (Number) is not a model"));
    }
}

test "C API: a message keeps a NUL it quotes, its length saying where it ends" {
    const result = build("raise \"a\\0b\"", "stl", .{});
    defer result.deinit();
    try testing.expectEqualStrings("RuntimeError: a\x00b", result.message().?);
}

test "C API: a build's arguments refused before it runs: the format, the parameters, the files" {
    {
        const result = build("cube(1)", "stp", .{});
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_INVALID_ARGUMENT), result.status());
        try testing.expectEqualStrings("'stp' isn't a format: one of stl, glb, gltf, step, 3mf, obj, svg, dxf", result.message().?);
        try testing.expectEqual(null, result.report());
    }
    {
        const result = build("cube(1)", "stl", .{ .params = "{width: 1}" });
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_INVALID_ARGUMENT), result.status());
        try testing.expect(std.mem.startsWith(u8, result.message().?, "parameters: "));
    }
    {
        const result = build("cube(1)", "stl", .{ .files = "\x09\x00\x00\x00lib" });
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_INVALID_ARGUMENT), result.status());
    }
    {
        // No format at all: it crashed
        const result = Result.of(c.kupcad_build("cube(1)", 7, null, null, 0, null, 0, 0, 0, false));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_INVALID_ARGUMENT), result.status());
        try testing.expectEqualStrings("no format: one of stl, glb, gltf, step, 3mf, obj, svg, dxf", result.message().?);
    }
}

test "C API: a result's data and message may be read without their lengths" {
    // kupcad_result_message took a NULL length, and kupcad_result_data crashed on one
    const result = build("cube(1)", "stl", .{});
    defer result.deinit();
    try testing.expect(c.kupcad_result_data(result.ptr, null) != null);
    try testing.expectEqual(null, c.kupcad_result_message(result.ptr, null));
}

test "C API: a build imports the files given with it, text and binary" {
    const mesh = build("cube(2)", "stl", .{});
    defer mesh.deinit();
    const files = try packed_files.pack(testing.allocator, &.{
        .{ .path = "lib/sizes.kup", .content = "def side = 12\nexport side" },
        .{ .path = "parts/block.stl", .content = mesh.data() },
    });
    defer testing.allocator.free(files);
    const source =
        \\import { side } from "./lib/sizes.kup"
        \\block = import_stl("parts/block.stl")
        \\puts side, block.volume
        \\block + cube(side)
    ;
    const result = build(source, "stl", .{ .files = files });
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    const report = try result.parsedReport();
    defer report.deinit();
    try testing.expectEqualStrings("12\n8\n", report.value.output);
}

test "C API: a build's memory limit stops a script that holds more, however small it is" {
    for ([_]u64{ 1_000_000, 1 }) |limit| {
        const result = build("a = (1..2_000_000).to_a\ncube(1)", "stl", .{ .memory_limit = limit });
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
        try testing.expect(std.mem.startsWith(u8, result.message().?, "OutOfMemoryError: "));
    }
}

test "C API: a build's time limit stops a script that never ends" {
    const result = build("while true\nend\ncube(1)", "stl", .{ .timeout_ms = 100 });
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
    try testing.expect(std.mem.startsWith(u8, result.message().?, "Time limit: the run took longer than 100 ms"));
}

test "C API: a build past its time limit fails, though the kernel spent it meshing the model" {
    // The evaluator walks this chain of booleans in a few milliseconds, and the kernel computes
    // them as it meshes the model, in one call: the build took a hundred times its limit, and
    // succeeded
    const chain = "m = cube(1)\n(1..10).each { |i| m = m + sphere(r: 1, segments: 32).translate(x: i * 0.5) }\nm";
    const result = build(chain, "stl", .{ .timeout_ms = 5 });
    defer result.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
    try testing.expect(std.mem.startsWith(u8, result.message().?, "Time limit: the run took longer than 5 ms"));
}

test "C API: a build compresses a GLB's meshes with Draco when asked" {
    const plain = build("sphere(r: 5)", "glb", .{});
    defer plain.deinit();
    const draco = build("sphere(r: 5)", "glb", .{ .draco = true });
    defer draco.deinit();
    try testing.expect(std.mem.find(u8, draco.data(), "KHR_draco_mesh_compression") != null);
    try testing.expect(std.mem.find(u8, plain.data(), "KHR_draco_mesh_compression") == null);
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

test "C API: kupcad_check gives the findings as JSON, a syntax error among them" {
    const Finding = struct { line: u32, rule: ?[]const u8, code: ?[]const u8, severity: []const u8 };
    {
        const source = "x = 1\ncube(1)";
        const result: Result = .of(c.kupcad_check(source.ptr, source.len));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
        const findings = try std.json.parseFromSlice([]const Finding, testing.allocator, result.data(), .{ .ignore_unknown_fields = true });
        defer findings.deinit();
        try testing.expectEqual(1, findings.value.len);
        try testing.expectEqualStrings("unused-variable", findings.value[0].rule.?);
    }
    {
        const source = "x = )";
        const result: Result = .of(c.kupcad_check(source.ptr, source.len));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
        const findings = try std.json.parseFromSlice([]const Finding, testing.allocator, result.data(), .{ .ignore_unknown_fields = true });
        defer findings.deinit();
        try testing.expectEqualStrings("error", findings.value[0].severity);
        try testing.expectEqualStrings("invalid-expression", findings.value[0].code.?);
        try testing.expectEqual(null, findings.value[0].rule);
    }
}

test "C API: kupcad_params gives the schema kupcad doc prints, of what parses" {
    {
        const source = "# @title Plate\nwidth = param(:width, default: 40, validate: { min: 10 })\ncube(width)";
        const result: Result = .of(c.kupcad_params(source.ptr, source.len));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
        try testing.expect(std.mem.find(u8, result.data(), "\"title\":\"Plate\"") != null);
        try testing.expect(std.mem.find(u8, result.data(), "\"name\":\"width\"") != null);
    }
    {
        // A script half written still declares its parameters: a form shows them as it is typed
        const source = "width = param(:width, default: 40)\ny = )";
        const result: Result = .of(c.kupcad_params(source.ptr, source.len));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
        try testing.expect(std.mem.find(u8, result.data(), "\"name\":\"width\"") != null);
    }
}

test "C API: an empty source, or none (NULL), is an empty script to every call" {
    {
        const result: Result = .of(c.kupcad_format(null, 0));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
        try testing.expectEqualStrings("", result.data());
    }
    {
        const result: Result = .of(c.kupcad_check(null, 0));
        defer result.deinit();
        try testing.expectEqualStrings("[]", result.data());
    }
    {
        const result: Result = .of(c.kupcad_params(null, 0));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    }
    {
        const result: Result = .of(c.kupcad_build(null, 0, "stl", null, 0, null, 0, 0, 0, false));
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_SCRIPT_ERROR), result.status());
        try testing.expectEqualStrings("GeometryError: the model holds no Solid: nothing to write as stl", result.message().?);
    }
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
            const result = build(source, "stl", .{});
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

test "C API: a process forked after a build that ran on worker threads builds too" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    {
        const result = build(HEAVY, "stl", .{});
        defer result.deinit();
        try testing.expectEqual(@as(c_int, c.KUPCAD_OK), result.status());
    }
    try expectForkBuilds();
    // And the parent builds on, its workers started again
    const after = build(HEAVY, "stl", .{});
    defer after.deinit();
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), after.status());
}

test "C API: a process forked while another thread that built is alive builds too" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // A thread holds oneTBB's workers until it ends: ending them at the fork failed while one
    // that had built waited in a host's pool, and the child trapped
    const Pooled = struct {
        fn run(built: *std.Io.Event, done: *std.Io.Event, status: *c_int) void {
            const result = build(HEAVY, "stl", .{});
            status.* = result.status();
            result.deinit();
            built.set(testing.io);
            done.waitUncancelable(testing.io);
        }
    };
    var built: std.Io.Event = .unset;
    var done: std.Io.Event = .unset;
    var status: c_int = -1;
    const thread = try std.Thread.spawn(.{}, Pooled.run, .{ &built, &done, &status });
    defer thread.join();
    defer done.set(testing.io);
    built.waitUncancelable(testing.io);
    try testing.expectEqual(@as(c_int, c.KUPCAD_OK), status);
    try expectForkBuilds();
}

/// Forks, and expects the child to build HEAVY and exit with 0, not be killed by a signal.
fn expectForkBuilds() !void {
    const pid = std.c.fork();
    if (pid == 0) {
        const result = build(HEAVY, "stl", .{});
        std.c._exit(if (result.status() == c.KUPCAD_OK) 0 else 1);
    }
    var status: c_int = undefined;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    try testing.expectEqual(@as(c_int, 0), status);
}
