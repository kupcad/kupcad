//! Every `*_test.zig` under src/ runs: each must be imported by root.zig (the module's test
//! block) or main.zig (the executable's, for tests that need its dependencies), Locus's by
//! its own root (which root.zig imports), or be a test root of its own. Two files sat
//! unregistered for months (the formatter's stability check and the visitor's tests),
//! passing by never running.

const std = @import("std");
const testing = std.testing;
/// The core's folder, which the paths below are from (the build's, not the working directory).
const CORE_DIR = @import("test_paths").core_dir;

/// Test roots the build runs on their own.
const OWN_ROOTS = [_][]const u8{ "main_test.zig", "wasm_test.zig", "cli_process_test.zig", "capi_test.zig" };
/// Locus's tree, whose test files its root imports by paths from there.
const LOCUS_TREE = "locus/src/";

/// The sources of `registries` (paths from the build root), one after another.
fn sourcesOf(registries: []const []const u8) !std.ArrayList(u8) {
    var sources: std.ArrayList(u8) = .empty;
    errdefer sources.deinit(testing.allocator);
    for (registries) |registry| {
        const path = try std.fs.path.join(testing.allocator, &.{ CORE_DIR, registry });
        defer testing.allocator.free(path);
        const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(source);
        try sources.appendSlice(testing.allocator, source);
    }
    return sources;
}

test "Tests: every *_test.zig under src/ is registered in root.zig, main.zig or Locus's root" {
    var registered = try sourcesOf(&.{ "src/root.zig", "src/main.zig" });
    defer registered.deinit(testing.allocator);
    var locus = try sourcesOf(&.{"src/" ++ LOCUS_TREE ++ "root.zig"});
    defer locus.deinit(testing.allocator);

    var dir = try std.Io.Dir.cwd().openDir(testing.io, CORE_DIR ++ "/src", .{ .iterate = true });
    defer dir.close(testing.io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var missing: usize = 0;
    while (try walker.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        // As the registries name it: Windows walks `cli\lsp_test.zig`
        const path = try testing.allocator.dupe(u8, entry.path);
        defer testing.allocator.free(path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        var skip = false;
        for (OWN_ROOTS) |own| skip = skip or std.mem.eql(u8, path, own);
        if (skip) continue;
        const in_locus = std.mem.startsWith(u8, path, LOCUS_TREE);
        const quoted = try testing.allocator.print("\"{s}\"", .{if (in_locus) path[LOCUS_TREE.len..] else path});
        defer testing.allocator.free(quoted);
        if (std.mem.find(u8, (if (in_locus) locus else registered).items, quoted) == null) {
            std.debug.print("unregistered test file: src/{s}\n", .{path});
            missing += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}
