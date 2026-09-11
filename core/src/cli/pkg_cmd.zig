const std = @import("std");
const PackageManager = @import("../pkg/manager.zig").PackageManager;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const subcommand = args_iter.next() orelse {
        std.debug.print("Error: Missing subcommand.\nUsage: kupcad pkg <add|install|init> [args]\n", .{});
        return;
    };

    if (std.mem.eql(u8, subcommand, "add")) {
        const repo_url = args_iter.next() orelse {
            std.debug.print("Error: Missing repository URL.\nUsage: kupcad pkg add github.com/user/repo\n", .{});
            return;
        };

        var manager = try PackageManager.init(allocator, init.io, init.environ_map);
        defer manager.deinit();

        try manager.addPackage(repo_url);
    } else if (std.mem.eql(u8, subcommand, "install")) {
        std.debug.print("The 'install' command is not yet implemented.\n", .{});
        // We will build out the install reconciliation logic here next.
    } else if (std.mem.eql(u8, subcommand, "init")) {
        std.debug.print("The 'init' command is not yet implemented.\n", .{});
        // We can add the empty kupcad.json generator here.
    } else {
        std.debug.print("Error: Unknown subcommand '{s}'.\nUsage: kupcad pkg <add|install|init>\n", .{subcommand});
    }
}
