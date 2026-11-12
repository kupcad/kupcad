//! The example models (../examples) built end to end and fingerprinted by what each one
//! leaves: a Solid part's engine, volume, surface area, bounds and genus, and its mesh's
//! vertices and triangles, and the parts list (each part's name, copies and material); a
//! drawing's Sketch's engine, area, bounds and vertices, and its Path's bounds and segments;
//! then the model written in its format (test_support.modelFormat: STEP for exact Solids, glb
//! for the rest, SVG for a drawing), and a drawing's shapes in it (each one's name and colours).
//! The fingerprints must match
//! examples.snap, measures within a relative tolerance and mesh counts within 1% (the last
//! bits of a sine differ between platforms' math libraries), so a change that alters a real
//! model shows up. `zig build test -Dupdate-snapshots` rewrites the snapshot from the
//! current output; review the diff before committing it.

const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");
const kernel = @import("kernel/kernel.zig");
const model_mod = @import("exporters/model.zig");
const path_mod = @import("core/path.zig");
const parts_mod = @import("exporters/parts.zig");
const material = @import("core/material.zig");
const test_support = @import("test_support.zig");
const examples = @import("examples");

const core_dir = @import("test_paths").core_dir;

const SNAPSHOT_PATH = core_dir ++ "/src/examples.snap";
const EXAMPLES_DIR = core_dir ++ "/../examples";
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

/// Runs `source` and writes one line per part of its model (a Solid, or a drawing's Sketch
/// or Path), then the export it gives.
fn fingerprint(allocator: std.mem.Allocator, source: []const u8, w: *std.Io.Writer) !void {
    var vm = try test_support.initVm();
    defer vm.deinit();
    const result = try test_support.runOn(&vm, source);
    if (result != .ok) {
        std.debug.print("run failed: {s}\n", .{vm.last_error orelse "(no message)"});
        return error.ExampleFailed;
    }

    var model = try model_mod.collectModel(allocator, &vm);
    defer model.deinit(allocator);
    if (model.shapeCount() == 0 and model.ghosts.len == 0) return error.ExampleHasNoModel;
    var parts = try model_mod.handlesOf(allocator, &vm, model.solids.items, model.ghosts);
    defer parts.deinit(allocator);

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
    }
    if (model.solids.items.len > 0) {
        const grouping = try parts_mod.group(&vm, allocator, model.solids.items);
        defer grouping.deinit(allocator);
        for (grouping.parts, 0..) |part, i| {
            var copies: usize = 0;
            for (grouping.copies) |copy| copies += @intFromBool(copy.part == i);
            try w.print("  group {d} name={s} copies={d}", .{ i + 1, part.name orelse "-", copies });
            if (part.material) |m| {
                const alpha: u8 = @intFromFloat(@round(std.math.clamp(m.alpha, 0, 1) * 255));
                try w.print(" material={s}", .{&material.hexRgba(.{ m.rgb[0], m.rgb[1], m.rgb[2], alpha })});
            }
            try w.writeAll("\n");
        }
    }
    for (model.sketches.items, 1..) |sketch, n| {
        const cs = try vm.ensureConcreteCrossSection(sketch);
        try w.print("  sketch {d} {s} area={d}", .{ n, cs.engine.scriptName(), kernel.crossSectionArea(cs) });
        if (kernel.crossSectionBounds(cs)) |b| try w.print(" min={d},{d} max={d},{d}", .{ b.min[0], b.min[1], b.max[0], b.max[1] });
        try w.print(" vertices={d}\n", .{kernel.crossSectionNumVerts(cs)});
    }
    for (model.paths.items, 1..) |val, n| {
        const p = val.asPath();
        const b = path_mod.bounds(p.start, p.segments);
        try w.print("  path {d} min={d},{d} max={d},{d} segments={d}\n", .{ n, b.min[0], b.min[1], b.max[0], b.max[1], p.segments.len });
    }

    const format = try test_support.modelFormat(allocator, &vm);
    const bytes = api.exportModelFromVm(allocator, &vm, format, .{}) catch |err| {
        std.debug.print("{t} export failed: {s} {s}\n", .{ format, @errorName(err), vm.last_error orelse "" });
        return err;
    };
    defer allocator.free(bytes);
    try w.print("  exports {t}\n", .{format});
    if (format == .svg) try drawnShapes(bytes, w);
}

/// A line per shape an SVG drawing draws: its id (the shape's name) and its fill and stroke.
fn drawnShapes(svg: []const u8, w: *std.Io.Writer) !void {
    var elements = std.mem.splitSequence(u8, svg, "<path");
    _ = elements.next(); // what comes before the first
    var n: usize = 0;
    while (elements.next()) |element| {
        n += 1;
        const tag = element[0 .. std.mem.findScalar(u8, element, '>') orelse element.len];
        try w.print("  drawn {d} id={s} fill={s} stroke={s}\n", .{ n, attribute(tag, "id") orelse "-", attribute(tag, "fill") orelse "-", attribute(tag, "stroke") orelse "-" });
    }
}

/// The value of the attribute `name` in an element's `tag` (each attribute after a space), or
/// null.
fn attribute(tag: []const u8, comptime name: []const u8) ?[]const u8 {
    const key = " " ++ name ++ "=\"";
    const start = (std.mem.find(u8, tag, key) orelse return null) + key.len;
    const end = std.mem.findScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..end];
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
    const eq_e = std.mem.findScalar(u8, expected, '=') orelse return std.mem.eql(u8, expected, actual);
    const eq_a = std.mem.findScalar(u8, actual, '=') orelse return false;
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

test "Examples: on the B-Rep engine each example builds or is refused by design, never failed in the kernel" {
    // What `kupcad dev brep-readiness` reports, held: a refusal names what the engine lacks
    // (NotImplementedError) or what the format can't hold; a GeometryError is a fault of
    // the kernel's (parabolic_dish and planetary_gearbox were, unseen by the case rig, until
    // M3's review, 2026-11-12)
    const readiness = @import("tools/dev/brep_readiness.zig");
    inline for (examples.names) |name| {
        errdefer std.debug.print("example {s}.kup\n", .{name});
        var outcome = try readiness.check(testing.allocator, testing.io, @embedFile("example/" ++ name), .none);
        defer outcome.deinit(testing.allocator);
        switch (outcome) {
            .builds => {},
            .refused => |message| {
                errdefer std.debug.print("refused: {s}\n", .{message});
                try testing.expect(!std.mem.startsWith(u8, message, "GeometryError"));
            },
            .failed => |err| {
                std.debug.print("failed: {s}\n", .{@errorName(err)});
                return error.TestUnexpectedResult;
            },
        }
    }
}
