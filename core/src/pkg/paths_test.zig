const std = @import("std");
const testing = std.testing;
const paths = @import("paths.zig");

test "Paths: resolves global dir using KUPCAD_HOME override" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();

    try env_map.put("KUPCAD_HOME", "/custom/cache/dir");

    const global_dir = try paths.getGlobalDir(testing.allocator, &env_map);
    defer testing.allocator.free(global_dir);

    try testing.expectEqualStrings("/custom/cache/dir", global_dir);
}
