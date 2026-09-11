const std = @import("std");
const builtin = @import("builtin");

// Because we link libc, we can directly bind to getenv to avoid
// any stdlib churn across Zig 0.16.0 versions.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

pub const PathError = error{
    HomeNotFound,
} || std.mem.Allocator.Error;

pub fn getHomeDir(allocator: std.mem.Allocator) PathError![]const u8 {
    const env_key: [*:0]const u8 = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";

    if (getenv(env_key)) |val| {
        return try allocator.dupe(u8, std.mem.span(val));
    }

    return error.HomeNotFound;
}
