//! The example models (../examples) built end to end and fingerprinted: each part's engine,
//! volume, surface area, bounds and genus, and its mesh's vertices and triangles, then the
//! export `kupcad build` would write (STEP for exact models, glb for the rest). The
//! fingerprints must match examples.snap, measures within a relative tolerance and mesh
//! counts within 1% (the last bits of a sine differ between platforms' math libraries), so
//! a change that alters a real model shows up. `zig build test -Dupdate-snapshots` rewrites
//! the snapshot from the current output; review the diff before committing it.

const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");
const kernel = @import("kernel/kernel.zig");
const geom = @import("kernel/geometry_handle.zig");
const test_support = @import("test_support.zig");
const examples = @import("examples");

const SNAPSHOT_PATH = "src/examples.snap";
const EXAMPLES_DIR = "../examples";
/// Measures (volume, area, bounds) may differ by this fraction between platforms.
const MEASURE_TOLERANCE = 1e-6;
/// Mesh counts may differ by this fraction (a boolean can split one triangle differently).
const COUNT_TOLERANCE = 0.01;
/// Keys whose values are mesh counts; genus and the rest compare exactly or as measures.
const COUNT_KEYS = [_][]const u8{ "vertices", "triangles" };

test "Examples: every example builds, exports, and matches its snapshot" {
    const allocator = testing.allocator;
    var actual: std.Io.Writer.Allocating = .init(allocator);
    defer actual.deinit();
    inline for (examples.names) |name| {
        errdefer std.debug.print("example {s}.kup\n", .{name});
        try actual.writer.print("{s}\n", .{name});
        try fingerprint(allocator, @embedFile("example/" ++ name), &actual.writer);
    }

    if (examples.update) {
        return std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = SNAPSHOT_PATH, .data = actual.written() });
    }
    errdefer std.debug.print("{s} differs; if the new output is right, run zig build test -Dupdate-snapshots\n--- now:\n{s}", .{ SNAPSHOT_PATH, actual.written() });
    try expectMatches(@embedFile("examples.snap"), actual.written());
}

test "Examples: every example in the directory is listed in build.zig" {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, EXAMPLES_DIR, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".kup")) continue;
        const name = entry.name[0 .. entry.name.len - ".kup".len];
        for (examples.names) |listed| {
            if (std.mem.eql(u8, listed, name)) break;
        } else {
            std.debug.print("{s}/{s} isn't in build.zig's EXAMPLES, so it is never built\n", .{ EXAMPLES_DIR, entry.name });
            return error.UnlistedExample;
        }
    }
}

/// Runs `source` and writes one line per part, then the export it gives.
fn fingerprint(allocator: std.mem.Allocator, source: []const u8, w: *std.Io.Writer) !void {
    var vm = try test_support.initVm();
    defer vm.deinit();
    const result = try test_support.runOn(&vm, source);
    if (result != .ok) {
        std.debug.print("run failed: {s}\n", .{vm.last_error orelse "(no message)"});
        return error.ExampleFailed;
    }

    var parts: std.ArrayListUnmanaged(geom.GeometryHandle) = .empty;
    defer parts.deinit(allocator);
    try api.modelParts(allocator, &vm, &parts);
    if (parts.items.len == 0) return error.ExampleHasNoModel;

    var exact = true;
    for (parts.items, 1..) |h, n| {
        try w.print("  part {d} {s}", .{ n, h.engine.scriptName() });
        if (kernel.supports(h.engine, .volume)) try w.print(" volume={d}", .{kernel.volume(h)});
        if (kernel.supports(h.engine, .surface_area)) try w.print(" area={d}", .{kernel.surfaceArea(h)});
        if (kernel.supports(h.engine, .bounding_box)) if (kernel.boundingBox(h)) |b| {
            try w.print(" min={d},{d},{d} max={d},{d},{d}", .{ b.min[0], b.min[1], b.min[2], b.max[0], b.max[1], b.max[2] });
        };
        if (kernel.supports(h.engine, .genus)) try w.print(" genus={d}", .{kernel.genus(h)});
        try w.print(" vertices={d}", .{kernel.numVerts(h)});
        if (kernel.numTris(h)) |tris| try w.print(" triangles={d}", .{tris});
        try w.writeAll("\n");
        if (h.engine != .brep_native) exact = false;
    }

    const format: api.ExportFormat = if (exact) .step else .glb;
    const bytes = api.exportModelFromVm(allocator, &vm, format, false) catch |err| {
        std.debug.print("{t} export failed: {s} {s}\n", .{ format, @errorName(err), vm.last_error orelse "" });
        return err;
    };
    defer allocator.free(bytes);
    try w.print("  exports {t}\n", .{format});
}

/// Line by line, token by token; `key=a,b,c` values compare as numbers within the key's
/// tolerance, everything else exactly.
fn expectMatches(expected: []const u8, actual: []const u8) !void {
    var exp_lines = std.mem.splitScalar(u8, expected, '\n');
    var act_lines = std.mem.splitScalar(u8, actual, '\n');
    while (true) {
        const e = exp_lines.next();
        const a = act_lines.next();
        if (e == null and a == null) return;
        const el = e orelse return mismatch("", a.?);
        const al = a orelse return mismatch(el, "");
        if (!linesMatch(el, al)) return mismatch(el, al);
    }
}

fn linesMatch(expected: []const u8, actual: []const u8) bool {
    var et = std.mem.tokenizeScalar(u8, expected, ' ');
    var at = std.mem.tokenizeScalar(u8, actual, ' ');
    while (true) {
        const e = et.next();
        const a = at.next();
        if (e == null and a == null) return true;
        if (e == null or a == null) return false;
        if (!tokensMatch(e.?, a.?)) return false;
    }
}

fn tokensMatch(expected: []const u8, actual: []const u8) bool {
    const eq_e = std.mem.indexOfScalar(u8, expected, '=') orelse return std.mem.eql(u8, expected, actual);
    const eq_a = std.mem.indexOfScalar(u8, actual, '=') orelse return false;
    const key = expected[0..eq_e];
    if (!std.mem.eql(u8, key, actual[0..eq_a])) return false;
    const tolerance: f64 = for (COUNT_KEYS) |k| {
        if (std.mem.eql(u8, k, key)) break COUNT_TOLERANCE;
    } else MEASURE_TOLERANCE;

    var ev = std.mem.splitScalar(u8, expected[eq_e + 1 ..], ',');
    var av = std.mem.splitScalar(u8, actual[eq_a + 1 ..], ',');
    while (true) {
        const e = ev.next();
        const a = av.next();
        if (e == null and a == null) return true;
        if (e == null or a == null) return false;
        const x = std.fmt.parseFloat(f64, e.?) catch return std.mem.eql(u8, e.?, a.?);
        const y = std.fmt.parseFloat(f64, a.?) catch return false;
        if (key.len == "genus".len and std.mem.eql(u8, key, "genus")) {
            if (x != y) return false;
        } else if (@abs(x - y) > tolerance * @max(@abs(x), @abs(y)) + 1e-9) return false;
    }
}

fn mismatch(expected: []const u8, actual: []const u8) error{TestExpectedEqual} {
    std.debug.print("snapshot line:\n  {s}\nnow:\n  {s}\n", .{ expected, actual });
    return error.TestExpectedEqual;
}

test "Examples: the snapshot compare tolerates platform noise, not real changes" {
    try testing.expect(tokensMatch("volume=1000", "volume=1000.0000001"));
    try testing.expect(!tokensMatch("volume=1000", "volume=1000.1"));
    try testing.expect(tokensMatch("min=1,2,3", "min=1,2,3.000000001"));
    try testing.expect(!tokensMatch("min=1,2,3", "min=1,2"));
    try testing.expect(tokensMatch("vertices=1000", "vertices=1009"));
    try testing.expect(!tokensMatch("vertices=1000", "vertices=1011"));
    try testing.expect(!tokensMatch("genus=0", "genus=1"));
    try testing.expect(!tokensMatch("volume=1", "area=1"));
    try testing.expect(!tokensMatch("manifold", "brep"));
    try testing.expect(!linesMatch("part 1 manifold", "part 1"));
    try testing.expect(linesMatch("part 1  manifold", "part 1 manifold"));
}
