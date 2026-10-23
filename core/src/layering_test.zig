//! Every file under src/ imports only what its layer may: the source layout table in
//! docs/architecture.md, as `RULES`. Tests and test helpers may import anything; `cli/` and
//! the files at the top of src/ (api.zig, main.zig, wasm.zig) are the top and have no rule.
//! core/value.zig imported the lexer and the DAG builder, and the format writers the VM,
//! with nothing to say they shouldn't.

const std = @import("std");
const testing = std.testing;

/// What the files under `path` (relative to src/; a directory ends in `/`) may import
/// besides std and named modules: paths under these prefixes. A file follows the rule with
/// the longest `path` it is under.
const Rule = struct { path: []const u8, may_import: []const []const u8 };

const RULES = [_]Rule{
    .{ .path = "core/", .may_import = &.{ "core/", "locus/" } },
    .{ .path = "frontend/", .may_import = &.{ "frontend/", "core/" } },
    .{ .path = "vfs/", .may_import = &.{ "vfs/", "core/" } },
    .{ .path = "bindings/", .may_import = &.{ "bindings/", "core/" } },
    .{ .path = "kernel/", .may_import = &.{ "kernel/", "core/", "bindings/", "locus/" } },
    .{ .path = "vm/", .may_import = &.{ "vm/", "core/", "kernel/", "vfs/" } },
    .{ .path = "compiler/", .may_import = &.{ "compiler/", "core/", "frontend/", "vm/", "stdlib/manifest.zig" } },
    .{ .path = "stdlib/", .may_import = &.{ "stdlib/", "core/", "vm/", "kernel/", "compiler/", "exporters/" } },
    .{ .path = "exporters/", .may_import = &.{ "exporters/", "core/", "kernel/", "bindings/", "vm/" } },
    // The format writers take kernel handles and plain data; export.zig, model.zig and
    // parts.zig evaluate a VM's model for them
    .{ .path = "exporters/3d/", .may_import = &.{ "exporters/3d/", "exporters/zip.zig", "exporters/diagnostic.zig", "exporters/xml.zig", "core/", "kernel/", "bindings/" } },
    .{ .path = "exporters/2d/", .may_import = &.{ "exporters/2d/", "exporters/names.zig", "exporters/diagnostic.zig", "exporters/xml.zig", "core/", "kernel/" } },
    .{ .path = "exporters/2d/sketch_curves.zig", .may_import = &.{ "exporters/2d/", "core/", "kernel/", "vm/dag.zig" } },
    .{ .path = "exporters/names.zig", .may_import = &.{} },
    .{ .path = "exporters/diagnostic.zig", .may_import = &.{} },
    .{ .path = "exporters/xml.zig", .may_import = &.{"exporters/diagnostic.zig"} },
    .{ .path = "pkg/", .may_import = &.{ "pkg/", "core/", "vfs/", "log.zig" } },
    .{ .path = "tools/", .may_import = &.{ "tools/", "core/", "frontend/", "kernel/", "stdlib/", "vm/", "compiler/" } },
    .{ .path = "session/", .may_import = &.{ "session/", "core/", "frontend/", "compiler/", "vm/", "kernel/", "stdlib/", "vfs/", "api.zig" } },
};

/// Test helpers that aren't named `*_test.zig`: like tests, they may import anything.
const TEST_HELPERS = [_][]const u8{
    "test_support.zig",
    "frontend/test_utils.zig",
    "frontend/fuzz_corpus.zig",
    "frontend/fuzz_program.zig",
    "vm/vm_test_helpers.zig",
    "tools/lint/testing.zig",
};

fn ruleFor(path: []const u8) ?Rule {
    var found: ?Rule = null;
    for (RULES) |rule| {
        if (!std.mem.startsWith(u8, path, rule.path)) continue;
        if (found == null or rule.path.len > found.?.path.len) found = rule;
    }
    return found;
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

test "Layers: every file under src/ imports only what the source layout lets its layer" {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, "src", .{ .iterate = true });
    defer dir.close(testing.io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var violations: usize = 0;
    while (try walker.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        var helper = false;
        for (TEST_HELPERS) |h| helper = helper or std.mem.eql(u8, entry.path, h);
        if (helper) continue;
        const rule = ruleFor(entry.path) orelse continue;

        const source = try dir.readFileAlloc(testing.io, entry.path, testing.allocator, .limited(1 << 22));
        defer testing.allocator.free(source);
        const open = "@import(\"";
        var at: usize = 0;
        while (std.mem.findPos(u8, source, at, open)) |start| {
            const name_start = start + open.len;
            const name_end = std.mem.findScalarPos(u8, source, name_start, '"') orelse break;
            at = name_end;
            const import = source[name_start..name_end];
            // std, builtin and the build's named modules (tatfi, build_info)
            if (!std.mem.endsWith(u8, import, ".zig")) continue;
            var buf: [256]u8 = undefined;
            const target = resolve(&buf, entry.path, import) orelse {
                std.debug.print("src/{s} imports \"{s}\", outside src/\n", .{ entry.path, import });
                violations += 1;
                continue;
            };
            var allowed = false;
            for (rule.may_import) |prefix| allowed = allowed or std.mem.startsWith(u8, target, prefix);
            if (!allowed) {
                std.debug.print("src/{s} imports src/{s}, which the {s} layer may not\n", .{ entry.path, target, rule.path });
                violations += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), violations);
}

test "Layers: an import is resolved against its file, and the longest rule wins" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("core/value.zig", resolve(&buf, "stdlib/methods/x.zig", "../../core/value.zig").?);
    try testing.expectEqualStrings("exporters/zip.zig", resolve(&buf, "exporters/3d/threemf.zig", "../zip.zig").?);
    try testing.expectEqualStrings("api.zig", resolve(&buf, "session/session.zig", "../api.zig").?);
    try testing.expectEqualStrings("vm/dag.zig", resolve(&buf, "vm/vm.zig", "./dag.zig").?);
    try testing.expect(resolve(&buf, "core/x.zig", "../../vendor/y.zig") == null);
    try testing.expectEqualStrings("exporters/3d/", ruleFor("exporters/3d/obj.zig").?.path);
    try testing.expectEqualStrings("exporters/2d/sketch_curves.zig", ruleFor("exporters/2d/sketch_curves.zig").?.path);
    try testing.expectEqualStrings("exporters/", ruleFor("exporters/export.zig").?.path);
    try testing.expect(ruleFor("cli/lsp.zig") == null);
    try testing.expect(ruleFor("api.zig") == null);
}
