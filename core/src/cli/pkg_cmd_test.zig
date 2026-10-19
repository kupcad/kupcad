const std = @import("std");
const testing = std.testing;
const pkg_cmd = @import("pkg_cmd.zig");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "pkg init: writes a manifest once, and refuses to overwrite an existing one" {
    // It overwrote kupcad.json, dependencies and all, and exited 0.
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const reporter: @import("reporter.zig").Reporter = .{ .io = testing.io, .capture = &out.writer };

    try testing.expectEqual(.success, try pkg_cmd.initManifest(testing.allocator, mem.vfs(), reporter));
    try testing.expectEqualStrings("Initialized kupcad.json\n", out.written());
    const fresh = try mem.vfs().readFile(testing.allocator, "kupcad.json");
    defer testing.allocator.free(fresh);

    try mem.vfs().writeFile("kupcad.json", "{ \"name\": \"mine\", \"version\": \"1.0.0\", \"dependencies\": { \"hw\": \"github.com/x/hw\" } }");
    out.clearRetainingCapacity();
    try testing.expectEqual(.failure, try pkg_cmd.initManifest(testing.allocator, mem.vfs(), reporter));
    try testing.expect(std.mem.startsWith(u8, out.written(), "Error: kupcad.json already exists here; nothing changed."));
    const kept = try mem.vfs().readFile(testing.allocator, "kupcad.json");
    defer testing.allocator.free(kept);
    try testing.expect(std.mem.find(u8, kept, "github.com/x/hw") != null);
}
