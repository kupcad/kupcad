const std = @import("std");
const PackageManager = @import("../pkg/manager.zig").PackageManager;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const repo_url = args_iter.next() orelse {
        std.debug.print("Error: Missing repository URL.\nUsage: kupcad add github.com/user/repo\n", .{});
        return;
    };

    var manager = try PackageManager.init(allocator, init.io);
    defer manager.deinit();

    try manager.addPackage(repo_url);
}
