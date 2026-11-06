//! The rules every source file under src/ follows, checked by reading the files (so they
//! run natively, not under WebAssembly): the layers and what each may import (the layout
//! table of docs/architecture.md §4), the float mode and no fused multiply-add where
//! topology is decided (§6), and no host services (file system, threads, process, printing:
//! §4's targets). `legacy/` is exempt from all but its own layer rule and goes with M0.
//! Tests and test helpers may import anything; root.zig is the top and has no rule.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// What the files under `path` (relative to src/; a directory ends in `/`) may import besides
/// std, builtin, the build's named modules and BASE: paths under these prefixes. A file
/// follows the rule with the longest `path` it is under.
const Rule = struct { path: []const u8, may_import: []const []const u8 };

/// What every layer may import: the leaves nothing depends on.
const BASE = [_][]const u8{ "math/", "tolerance.zig", "diagnostics.zig", "parallel.zig" };
/// The operations, one layer: each may use the others.
const OPERATIONS = [_][]const u8{ "sketch/", "construct/", "intersect/", "measure/", "query/", "mesh/" };
const MODEL = [_][]const u8{ "topology/", "spatial/", "geometry/" };

const RULES = [_]Rule{
    .{ .path = "math/", .may_import = &.{} },
    .{ .path = "tolerance.zig", .may_import = &.{} },
    .{ .path = "diagnostics.zig", .may_import = &.{} },
    .{ .path = "parallel.zig", .may_import = &.{} },
    .{ .path = "geometry/", .may_import = &.{"geometry/"} },
    .{ .path = "topology/", .may_import = &.{ "topology/", "geometry/" } },
    .{ .path = "spatial/", .may_import = &.{ "spatial/", "geometry/" } },
    .{ .path = "sketch/", .may_import = &(OPERATIONS ++ MODEL) },
    .{ .path = "construct/", .may_import = &(OPERATIONS ++ MODEL) },
    .{ .path = "intersect/", .may_import = &(OPERATIONS ++ MODEL) },
    .{ .path = "measure/", .may_import = &(OPERATIONS ++ MODEL) },
    .{ .path = "query/", .may_import = &(OPERATIONS ++ MODEL) },
    .{ .path = "mesh/", .may_import = &(OPERATIONS ++ MODEL) },
    // Input and output import no operation
    .{ .path = "io/", .may_import = &([_][]const u8{"io/"} ++ MODEL) },
    .{ .path = "boolean/", .may_import = &([_][]const u8{ "boolean/", "io/" } ++ OPERATIONS ++ MODEL) },
    .{ .path = "local/", .may_import = &([_][]const u8{ "local/", "io/" } ++ OPERATIONS ++ MODEL) },
    .{ .path = "legacy/", .may_import = &.{ "legacy/", "tolerance.zig" } },
};

/// The directories where topology is decided: no `@mulAdd` there, so every platform rounds
/// each product and sum the same way (§6, determinism).
const NO_FMA = [_][]const u8{ "intersect/", "boolean/", "sketch/", "mesh/" };

/// What a library that runs in a browser, a CLI and another program's process never touches
/// (§4): the host's file system, threads, process and console. `std.Io` is the 0.17 file
/// and process interface; printing is the host's decision, Locus returns diagnostics.
const HOST_SERVICES = [_][]const u8{ "std.fs.", "std.Thread", "std.process", "std.posix", "std.Io.Dir", "std.Io.File", "std.debug.print", "std.log" };

/// Test helpers that aren't named `*_test.zig`: like tests, they may import anything.
const TEST_HELPERS = [_][]const u8{"legacy/testing/fixture.zig"};

const MAX_SOURCE = 1 << 22;

fn ruleFor(path: []const u8) ?Rule {
    var found: ?Rule = null;
    for (RULES) |rule| {
        if (!std.mem.startsWith(u8, path, rule.path)) continue;
        if (found == null or rule.path.len > found.?.path.len) found = rule;
    }
    return found;
}

fn isTest(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "_test.zig")) return true;
    for (TEST_HELPERS) |h| if (std.mem.eql(u8, path, h)) return true;
    return false;
}

/// `import` (a path relative to the file at `path`, both under src/) as a path under src/,
/// in `buf`; null when it leaves src/.
fn resolve(buf: []u8, path: []const u8, import: []const u8) ?[]const u8 {
    var parts: [32][]const u8 = undefined;
    var len: usize = 0;
    var dirs = std.mem.splitScalar(u8, std.fs.path.dirnamePosix(path) orelse "", '/');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        parts[len] = dir;
        len += 1;
    }
    var steps = std.mem.splitScalar(u8, import, '/');
    while (steps.next()) |step| {
        if (std.mem.eql(u8, step, ".")) continue;
        if (std.mem.eql(u8, step, "..")) {
            if (len == 0) return null;
            len -= 1;
            continue;
        }
        parts[len] = step;
        len += 1;
    }
    var w: std.Io.Writer = .fixed(buf);
    for (parts[0..len], 0..) |part, i| {
        if (i > 0) w.writeByte('/') catch return null;
        w.writeAll(part) catch return null;
    }
    return w.buffered();
}

/// Every `.zig` file under src/ with its source, through `visit(path, source)`.
fn walkSources(visit: *const fn (path: []const u8, source: []const u8) anyerror!void) !void {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, @import("test_paths").locus_dir ++ "/src", .{ .iterate = true });
    defer dir.close(testing.io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // As the rules name it: Windows walks `legacy\math.zig`
        const path = try testing.allocator.dupe(u8, entry.path);
        defer testing.allocator.free(path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const source = try dir.readFileAlloc(testing.io, entry.path, testing.allocator, .limited(MAX_SOURCE));
        defer testing.allocator.free(source);
        try visit(path, source);
    }
}

var violations: usize = 0;

fn checkLayers(path: []const u8, source: []const u8) !void {
    if (isTest(path)) return;
    const rule = ruleFor(path) orelse {
        // The top (root.zig, and check.zig over it) has no rule; anything else outside one
        // is a new file the layout doesn't know
        if (std.mem.eql(u8, path, "root.zig") or std.mem.eql(u8, path, "check.zig") or std.mem.eql(u8, path, SELF)) return;
        std.debug.print("src/{s} is outside every layer of the layout\n", .{path});
        violations += 1;
        return;
    };
    const open = "@import(\"";
    var at: usize = 0;
    while (std.mem.findPos(u8, source, at, open)) |start| {
        const name_start = start + open.len;
        const name_end = std.mem.findScalarPos(u8, source, name_start, '"') orelse break;
        at = name_end;
        const import = source[name_start..name_end];
        if (!std.mem.endsWith(u8, import, ".zig")) continue; // std, builtin, named modules
        var buf: [256]u8 = undefined;
        const target = resolve(&buf, path, import) orelse {
            std.debug.print("src/{s} imports \"{s}\", outside src/\n", .{ path, import });
            violations += 1;
            continue;
        };
        var allowed = false;
        for (rule.may_import) |prefix| allowed = allowed or std.mem.startsWith(u8, target, prefix);
        if (!std.mem.startsWith(u8, path, "legacy/")) for (BASE) |prefix| {
            allowed = allowed or std.mem.startsWith(u8, target, prefix);
        };
        if (!allowed) {
            std.debug.print("src/{s} imports src/{s}, which the {s} layer may not\n", .{ path, target, rule.path });
            violations += 1;
        }
    }
}

test "Layers: every file under src/ imports only what the layout lets its layer" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    violations = 0;
    try walkSources(checkLayers);
    try testing.expectEqual(@as(usize, 0), violations);
}

/// This file names what the rules forbid.
const SELF = "source_test.zig";

fn checkFloat(path: []const u8, source: []const u8) !void {
    if (std.mem.startsWith(u8, path, "legacy/") or std.mem.eql(u8, path, SELF)) return;
    // Strict is Zig's default and the only mode Locus runs in: nothing loosens it
    if (std.mem.find(u8, source, "@setFloatMode(.optimized)") != null) {
        std.debug.print("src/{s} sets the optimized float mode\n", .{path});
        violations += 1;
    }
    for (NO_FMA) |dir| {
        if (!std.mem.startsWith(u8, path, dir)) continue;
        if (std.mem.find(u8, source, "@mulAdd") != null) {
            std.debug.print("src/{s} uses @mulAdd, which decides topology differently per platform\n", .{path});
            violations += 1;
        }
    }
}

test "Floats: no file loosens the strict float mode, and none that decides topology fuses a multiply-add" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    violations = 0;
    try walkSources(checkFloat);
    try testing.expectEqual(@as(usize, 0), violations);
}

fn checkHostServices(path: []const u8, source: []const u8) !void {
    if (std.mem.startsWith(u8, path, "legacy/") or isTest(path) or std.mem.eql(u8, path, SELF)) return;
    for (HOST_SERVICES) |service| {
        if (std.mem.find(u8, source, service) != null) {
            std.debug.print("src/{s} uses {s}: Locus touches no file system, thread, process or console\n", .{ path, service });
            violations += 1;
        }
    }
}

test "Hosts: no file touches the file system, threads, the process or the console" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    violations = 0;
    try walkSources(checkHostServices);
    try testing.expectEqual(@as(usize, 0), violations);
}

test "Layers: an import is resolved against its file, and the longest rule wins" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("geometry/nurbs.zig", resolve(&buf, "topology/check.zig", "../geometry/nurbs.zig").?);
    try testing.expectEqualStrings("math/vec.zig", resolve(&buf, "tolerance.zig", "math/vec.zig").?);
    try testing.expectEqualStrings("boolean/pave.zig", resolve(&buf, "boolean/pipeline.zig", "./pave.zig").?);
    try testing.expect(resolve(&buf, "math/vec.zig", "../../core/x.zig") == null);
    try testing.expectEqualStrings("legacy/", ruleFor("legacy/operations/generators.zig").?.path);
    try testing.expectEqualStrings("io/", ruleFor("io/step_write.zig").?.path);
    try testing.expect(ruleFor("root.zig") == null);
}
