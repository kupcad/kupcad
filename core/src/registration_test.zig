//! Every `*_test.zig` under src/ runs: each must be imported by root.zig (the module's test
//! block) or main.zig (the executable's, for tests that need its dependencies), or be a
//! test root of its own. Two files sat unregistered for months (the formatter's stability
//! check and the visitor's tests), passing by never running.

const std = @import("std");
const testing = std.testing;

/// Test roots the build runs on their own, and the trees with their own test setup.
const OWN_ROOTS = [_][]const u8{ "main_test.zig", "wasm_test.zig", "cli_process_test.zig" };
const SKIPPED_TREES = [_][]const u8{"locus/"};

test "Tests: every *_test.zig under src/ is registered in root.zig or main.zig" {
    var registered: std.ArrayList(u8) = .empty;
    defer registered.deinit(testing.allocator);
    for ([_][]const u8{ "src/root.zig", "src/main.zig" }) |registry| {
        const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, registry, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(source);
        try registered.appendSlice(testing.allocator, source);
    }

    var dir = try std.Io.Dir.cwd().openDir(testing.io, "src", .{ .iterate = true });
    defer dir.close(testing.io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var missing: usize = 0;
    while (try walker.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        var skip = false;
        for (OWN_ROOTS) |own| skip = skip or std.mem.eql(u8, entry.path, own);
        for (SKIPPED_TREES) |tree| skip = skip or std.mem.startsWith(u8, entry.path, tree);
        if (skip) continue;
        const quoted = try testing.allocator.print("\"{s}\"", .{entry.path});
        defer testing.allocator.free(quoted);
        if (std.mem.find(u8, registered.items, quoted) == null) {
            std.debug.print("unregistered test file: src/{s}\n", .{entry.path});
            missing += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}
