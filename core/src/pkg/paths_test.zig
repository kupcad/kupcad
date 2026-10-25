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

test "Paths: an empty KUPCAD_HOME is unset, a relative one refused, and no home is said" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    // Empty, it put the store at the file system's root
    try env_map.put("KUPCAD_HOME", "");
    try env_map.put("HOME", "/home/maker");
    const global_dir = try paths.getGlobalDir(testing.allocator, &env_map);
    defer testing.allocator.free(global_dir);
    try testing.expectEqualStrings("/home/maker/.kupcad", global_dir);
    // Relative, it moved with the directory a command started in
    try env_map.put("KUPCAD_HOME", "store");
    try testing.expectError(error.RelativeKupcadHome, paths.getGlobalDir(testing.allocator, &env_map));
    // With neither, nor an empty home, there is nowhere to keep packages
    if (@import("builtin").target.os.tag != .windows) {
        _ = env_map.swapRemove("KUPCAD_HOME");
        try env_map.put("HOME", "");
        try testing.expectError(error.HomeNotFound, paths.getGlobalDir(testing.allocator, &env_map));
        _ = env_map.swapRemove("HOME");
        try testing.expectError(error.HomeNotFound, paths.getGlobalDir(testing.allocator, &env_map));
    }
}
