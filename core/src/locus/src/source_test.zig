//! The rules every source file under src/ follows, checked by reading the files (so they
//! run natively, not under WebAssembly): the layers and what each may import (the layout
//! table of docs/architecture.md §4), the float mode and no fused multiply-add where
//! topology is decided (§6), and no host services (file system, threads, process, printing:
//! §4's targets). Tests and test helpers may import anything; root.zig is the top and
//! has no rule.

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
    // An operation may import io/ for its trace (io/trace.zig); io imports no operation
    .{ .path = "sketch/", .may_import = &([_][]const u8{"io/"} ++ OPERATIONS ++ MODEL) },
    .{ .path = "construct/", .may_import = &([_][]const u8{"io/"} ++ OPERATIONS ++ MODEL) },
    .{ .path = "intersect/", .may_import = &([_][]const u8{"io/"} ++ OPERATIONS ++ MODEL) },
    .{ .path = "measure/", .may_import = &([_][]const u8{"io/"} ++ OPERATIONS ++ MODEL) },
    .{ .path = "query/", .may_import = &([_][]const u8{"io/"} ++ OPERATIONS ++ MODEL) },
    .{ .path = "mesh/", .may_import = &([_][]const u8{"io/"} ++ OPERATIONS ++ MODEL) },
    .{ .path = "io/", .may_import = &([_][]const u8{"io/"} ++ MODEL) },
    .{ .path = "boolean/", .may_import = &([_][]const u8{ "boolean/", "io/" } ++ OPERATIONS ++ MODEL) },
    .{ .path = "local/", .may_import = &([_][]const u8{ "local/", "io/" } ++ OPERATIONS ++ MODEL) },
};

/// The boolean's phases in their order (docs/architecture.md §7.4, boolean/pipeline.zig):
/// each may import only those before it, so the tables flow one way.
const BOOLEAN_PHASES = [_][]const u8{ "boolean/pave.zig", "boolean/imprint.zig", "boolean/classify.zig", "boolean/select.zig", "boolean/simplify.zig", "boolean/pipeline.zig" };

fn phaseOf(path: []const u8) ?usize {
    for (BOOLEAN_PHASES, 0..) |phase, i| if (std.mem.eql(u8, path, phase)) return i;
    return null;
}

/// The directories where topology is decided: no `@mulAdd` there, so every platform rounds
/// each product and sum the same way (§6, determinism).
const NO_FMA = [_][]const u8{ "intersect/", "boolean/", "sketch/", "mesh/" };

/// What a library that runs in a browser, a CLI and another program's process never touches
/// (§4): the host's file system, threads, process and console. `std.Io` is the 0.17 file
/// and process interface; printing is the host's decision, Locus returns diagnostics.
const HOST_SERVICES = [_][]const u8{ "std.fs.", "std.Thread", "std.process", "std.posix", "std.Io.Dir", "std.Io.File", "std.debug.print", "std.log" };

/// Where a tolerance may be written as a number: tolerance.zig and diagnostics.zig define
/// them, math/ holds numerical constants of its own. Everywhere else a comparison goes
/// through a body's `Tolerance` (README rule 3), and a named constant (`const X = 1e-6;`)
/// is the only other literal allowed.
const EPSILON_FREE_EXEMPT = [_][]const u8{ "math/", "tolerance.zig", "diagnostics.zig" };

/// The standard library's inverse trigonometry goes through math/trig.zig, whose barrier
/// keeps the wasm32 backend from a constant it cannot select (the file says how).
const TRIG_THROUGH_BARRIER = [_][]const u8{ "std.math.atan2(", "std.math.atan(" };
const TRIG_BARRIER = "math/trig.zig";

/// Test helpers that aren't named `*_test.zig`: like tests, they may import anything.
const TEST_HELPERS = [_][]const u8{
    // The malformed corpus's list, the files embedded (checker tests and fuzz seeds)
    "fixtures/malformed.zig",
};

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
        for (BASE) |prefix| allowed = allowed or std.mem.startsWith(u8, target, prefix);
        if (!allowed) {
            std.debug.print("src/{s} imports src/{s}, which the {s} layer may not\n", .{ path, target, rule.path });
            violations += 1;
        }
        if (phaseOf(path)) |from| if (phaseOf(target)) |to| if (to >= from) {
            std.debug.print("src/{s} imports src/{s}, a phase of the boolean after it\n", .{ path, target });
            violations += 1;
        };
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
    if (std.mem.eql(u8, path, SELF)) return;
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

fn checkTrig(path: []const u8, source: []const u8) !void {
    if (isTest(path) or std.mem.eql(u8, path, SELF) or std.mem.eql(u8, path, TRIG_BARRIER)) return;
    for (TRIG_THROUGH_BARRIER) |call| {
        if (std.mem.find(u8, source, call) != null) {
            std.debug.print("src/{s} calls {s}: use math/trig.zig's, which the wasm32 backend compiles\n", .{ path, call });
            violations += 1;
        }
    }
}

test "Trigonometry: no file but math/trig.zig calls the standard library's atan or atan2" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    violations = 0;
    try walkSources(checkTrig);
    try testing.expectEqual(@as(usize, 0), violations);
}

fn checkHostServices(path: []const u8, source: []const u8) !void {
    if (isTest(path) or std.mem.eql(u8, path, SELF)) return;
    for (HOST_SERVICES) |service| {
        if (std.mem.find(u8, source, service) != null) {
            std.debug.print("src/{s} uses {s}: Locus touches no file system, thread, process or console\n", .{ path, service });
            violations += 1;
        }
    }
}

fn checkEpsilons(path: []const u8, source: []const u8) !void {
    if (isTest(path) or std.mem.eql(u8, path, SELF)) return;
    for (EPSILON_FREE_EXEMPT) |prefix| if (std.mem.startsWith(u8, path, prefix)) return;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 1;
    while (lines.next()) |line| : (number += 1) {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "const ") or std.mem.startsWith(u8, trimmed, "pub const ") or std.mem.startsWith(u8, trimmed, "//")) continue;
        if (hasNegativeExponent(line)) {
            std.debug.print("src/{s}:{d} writes a tolerance as a number: {s}\n", .{ path, number, trimmed });
            violations += 1;
        }
    }
}

/// Whether `line` holds a literal like `1e-5` or `2.5e-7`.
fn hasNegativeExponent(line: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, line, i, 'e')) |at| : (i = at + 1) {
        if (at == 0 or at + 2 >= line.len) continue;
        if (!std.ascii.isDigit(line[at - 1]) or line[at + 1] != '-' or !std.ascii.isDigit(line[at + 2])) continue;
        return true;
    }
    return false;
}

test "Tolerances: no file but tolerance.zig, diagnostics.zig and math/ writes an epsilon as a number" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    violations = 0;
    try walkSources(checkEpsilons);
    try testing.expectEqual(@as(usize, 0), violations);
    try testing.expect(hasNegativeExponent("    if (d < 1e-5) return;"));
    try testing.expect(hasNegativeExponent("x = 2.5e-7 * y"));
    try testing.expect(!hasNegativeExponent("const e = base - x;"));
    try testing.expect(!hasNegativeExponent("value * 1e5"));
}

test "Hosts: no file touches the file system, threads, the process or the console" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    violations = 0;
    try walkSources(checkHostServices);
    try testing.expectEqual(@as(usize, 0), violations);
}

test "Layers: the boolean's phases import only the phases before them" {
    try testing.expectEqual(@as(?usize, 0), phaseOf("boolean/pave.zig"));
    try testing.expectEqual(@as(?usize, 5), phaseOf("boolean/pipeline.zig"));
    try testing.expectEqual(@as(?usize, null), phaseOf("boolean/section.zig"));
}

test "Layers: an import is resolved against its file, and the longest rule wins" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("geometry/nurbs.zig", resolve(&buf, "topology/check.zig", "../geometry/nurbs.zig").?);
    try testing.expectEqualStrings("math/vec.zig", resolve(&buf, "tolerance.zig", "math/vec.zig").?);
    try testing.expectEqualStrings("boolean/pave.zig", resolve(&buf, "boolean/pipeline.zig", "./pave.zig").?);
    try testing.expect(resolve(&buf, "math/vec.zig", "../../core/x.zig") == null);
    try testing.expectEqualStrings("construct/", ruleFor("construct/primitives.zig").?.path);
    try testing.expectEqualStrings("io/", ruleFor("io/step_write.zig").?.path);
    try testing.expect(ruleFor("root.zig") == null);
}
