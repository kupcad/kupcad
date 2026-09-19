const std = @import("std");
const topo_arena = @import("topology/arena.zig");
const geom_arena = @import("geometry/arena.zig");
const debug_dump = @import("debug_dump.zig").DebugDumper;

const FixtureData = struct {
    topology: topo_arena.TopologyArena,
    geometry: geom_arena.GeometryArena,
};

test "B-Rep: Recursive Fixture Suite" {
    const allocator = std.testing.allocator;
    const io = std.testing.io; // Fetch the VM/KupCAD IO handler

    const cwd = std.Io.Dir.cwd();

    // Ensure directory exists without panicking if it doesn't
    cwd.createDirPath(io, "fixtures/checks") catch {};

    var dir = try cwd.openDir(io, "fixtures/checks", .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, "_in.json")) continue;

        // Use the new IO signature with .unlimited
        const in_file = try dir.readFileAlloc(io, entry.name, allocator, .unlimited);
        defer allocator.free(in_file);

        const parsed = try std.json.parseFromSlice(FixtureData, allocator, in_file, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        defer parsed.deinit();

        var dest_t = topo_arena.TopologyArena.init();
        defer dest_t.deinit(allocator);
        var dest_g = geom_arena.GeometryArena.init();
        defer dest_g.deinit(allocator);

        // TODO: Execute target operation and compare with `_out.json`
    }
}
